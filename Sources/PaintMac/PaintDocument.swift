import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Errors surfaced by document level file operations.
enum PaintDocumentError: LocalizedError {
    case allocationFailed(width: Int, height: Int)
    case unreadableImage(URL)
    case encodingFailed(URL)

    var errorDescription: String? {
        switch self {
        case let .allocationFailed(width, height):
            return "Could not allocate a \(width)×\(height) canvas."
        case let .unreadableImage(url):
            return "“\(url.lastPathComponent)” is not an image this app can open."
        case let .encodingFailed(url):
            return "Could not write PNG data to “\(url.lastPathComponent)”."
        }
    }
}

/// Owner of a single 32-bit RGBA bitmap plus its Core Graphics drawing context.
///
/// Core Graphics allocates and owns the backing store (`data: nil`), so the
/// pixels stay alive exactly as long as the context does and there is nothing
/// to free by hand. Row padding is whatever CG picked, hence every raw access
/// goes through `bytesPerRow`.
private final class PixelBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let byteCount: Int
    let bytes: UnsafeMutablePointer<UInt8>
    let context: CGContext

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrderDefault.rawValue
            ),
            let base = context.data
        else { return nil }

        self.width = width
        self.height = height
        bytesPerRow = context.bytesPerRow
        byteCount = context.bytesPerRow * height
        bytes = base.assumingMemoryBound(to: UInt8.self)
        self.context = context

        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        context.interpolationQuality = .high
    }

    /// Byte offset of the pixel at bottom-left based document coordinates.
    /// Row 0 of the backing store is the *top* row of a CG bitmap context.
    @inline(__always)
    func offset(x: Int, y: Int) -> Int {
        (height - 1 - y) * bytesPerRow + x * 4
    }

    @inline(__always)
    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }
}

/// A raw pixel snapshot used for undo/redo. Stores dimensions so history can
/// cross canvas resizes, and the logical state identifier so dirty tracking
/// survives time travel.
private struct PaintSnapshot {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]
    let stateID: Int

    var byteCount: Int { bytes.count }
}

@MainActor
final class PaintDocument: ObservableObject {
    // MARK: Published state

    /// Bumped on every visible pixel change; views observe this to redraw.
    @Published private(set) var revision: Int = 0
    @Published private(set) var canvasSize: CGSize = .zero
    @Published private(set) var isDirty: Bool = false
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false

    // MARK: Limits

    private static let maxHistoryStates = 30
    private static let maxHistoryBytes = 192 * 1024 * 1024
    private static let maxDimension = 8192
    /// Per-channel slack so flood fill does not leave a hard halo along
    /// anti-aliased strokes, while still stopping at real edges.
    private static let fillTolerance = 16

    // MARK: Storage

    private var buffer: PixelBuffer
    private var undoStack: [PaintSnapshot] = []
    private var redoStack: [PaintSnapshot] = []
    private var historyBytes: Int = 0

    /// Snapshot captured by `beginStroke()`, held for the whole drag so drag
    /// segments never copy the bitmap.
    private var pendingSnapshot: PaintSnapshot?
    private var pendingDidPaint = false

    private var cachedImage: CGImage?
    private var cachedImageRevision: Int = -1

    private var stateID: Int = 0
    private var nextStateID: Int = 1
    private var savedStateID: Int = 0

    // MARK: Init

    init(width: Int = 960, height: Int = 600) {
        let size = PaintDocument.clamp(width: width, height: height)
        guard let buffer = PixelBuffer(width: size.width, height: size.height) else {
            preconditionFailure("Unable to allocate a \(size.width)×\(size.height) bitmap")
        }
        self.buffer = buffer
        canvasSize = CGSize(width: buffer.width, height: buffer.height)
        fillEntireBitmap(with: .white)
        revision = 1
    }

    // MARK: Image access

    /// Immutable image for the current revision. Built once per revision, so a
    /// drag that emits many segments produces one copy per painted frame.
    var cgImage: CGImage? {
        if let cachedImage, cachedImageRevision == revision {
            return cachedImage
        }
        let image = buffer.context.makeImage()
        cachedImage = image
        cachedImageRevision = revision
        return image
    }

    var pixelWidth: Int { buffer.width }
    var pixelHeight: Int { buffer.height }

    // MARK: Freehand strokes

    /// Opens a stroke transaction. Exactly one snapshot is taken here; the
    /// individual drag segments are pure drawing.
    func beginStroke() {
        if pendingSnapshot != nil {
            cancelStroke()
        }
        pendingSnapshot = makeSnapshot()
        pendingDidPaint = false
    }

    func drawStroke(
        from start: CGPoint,
        to end: CGPoint,
        tool: PaintTool,
        color: NSColor,
        secondaryColor: NSColor,
        lineWidth: CGFloat
    ) {
        let paint: NSColor
        let width: CGFloat
        let cap: CGLineCap

        switch tool {
        case .pencil:
            paint = color
            width = 1
            cap = .round
        case .brush:
            paint = color
            width = max(1, lineWidth)
            cap = .round
        case .thickBrush:
            paint = color
            width = max(lineWidth, tool.minimumStrokeWidth)
            cap = .round
        case .eraser:
            paint = secondaryColor
            width = max(1, lineWidth)
            cap = .square
        default:
            // Not freehand tools: they commit through their own entry points.
            return
        }

        let context = buffer.context
        context.saveGState()
        context.setShouldAntialias(true)
        context.setStrokeColor(PaintDocument.cgColor(paint))
        context.setFillColor(PaintDocument.cgColor(paint))
        context.setLineWidth(width)
        context.setLineCap(cap)
        context.setLineJoin(.round)

        let from = clampToCanvas(start)
        let to = clampToCanvas(end)
        if hypot(to.x - from.x, to.y - from.y) < 0.01 {
            // A single click still deposits one dab.
            let dab = CGRect(
                x: to.x - width / 2,
                y: to.y - width / 2,
                width: width,
                height: width
            )
            if cap == .square {
                context.fill(dab)
            } else {
                context.fillEllipse(in: dab)
            }
        } else {
            context.beginPath()
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        }
        context.restoreGState()

        pendingDidPaint = true
        didMutate()
    }

    /// Commits the open transaction as a single undo checkpoint. A stroke that
    /// painted nothing leaves no history entry.
    func endStroke() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        guard pendingDidPaint else {
            pendingDidPaint = false
            return
        }
        pendingDidPaint = false
        pushUndo(snapshot)
        markMutated()
    }

    /// Aborts the open transaction, restoring the pixels captured by
    /// `beginStroke()` without recording history.
    func cancelStroke() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        let didPaint = pendingDidPaint
        pendingDidPaint = false
        guard didPaint else { return }
        restore(snapshot)
        didMutate()
        refreshFlags()
    }

    // MARK: Shapes

    func addShape(
        tool: PaintTool,
        from start: CGPoint,
        to end: CGPoint,
        color: NSColor,
        lineWidth: CGFloat,
        constrained: Bool
    ) {
        guard tool.isShape else { return }

        let from = clampToCanvas(start)
        let to = clampToCanvas(end)
        guard let path = PaintShapeGeometry.path(
            tool: tool,
            from: from,
            to: to,
            constrained: constrained
        ) else { return }

        let snapshot = makeSnapshot()
        let context = buffer.context
        context.saveGState()
        context.setShouldAntialias(true)
        context.setStrokeColor(PaintDocument.cgColor(color))
        context.setLineWidth(max(1, lineWidth))
        context.setLineJoin(.miter)
        context.setLineCap(tool == .line ? .round : .square)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()

        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    // MARK: Flood fill

    /// Scanline flood fill over the real RGBA bytes. Iterative (no recursion),
    /// bounds checked, and a no-op — with no history entry — when the click
    /// lands outside the canvas or the target already matches the fill colour.
    func floodFill(at point: CGPoint, color: NSColor) {
        guard let seed = pixelCoordinate(point) else { return }

        let replacement = PaintDocument.components(of: color)
        let target = readPixel(x: seed.x, y: seed.y)
        guard !PaintDocument.matches(target, replacement, tolerance: PaintDocument.fillTolerance)
        else { return }

        let snapshot = makeSnapshot()

        let width = buffer.width
        let height = buffer.height
        let bytesPerRow = buffer.bytesPerRow
        let bytes = buffer.bytes
        let tolerance = PaintDocument.fillTolerance

        @inline(__always)
        func rowStart(_ y: Int) -> Int { (height - 1 - y) * bytesPerRow }

        @inline(__always)
        func isTarget(_ base: Int) -> Bool {
            PaintDocument.matches(
                (bytes[base], bytes[base + 1], bytes[base + 2], bytes[base + 3]),
                target,
                tolerance: tolerance
            )
        }

        @inline(__always)
        func paint(_ base: Int) {
            bytes[base] = replacement.0
            bytes[base + 1] = replacement.1
            bytes[base + 2] = replacement.2
            bytes[base + 3] = replacement.3
        }

        var stack: [(x: Int, y: Int)] = [seed]
        stack.reserveCapacity(256)

        while let node = stack.popLast() {
            let row = rowStart(node.y)
            guard isTarget(row + node.x * 4) else { continue }

            var left = node.x
            while left > 0, isTarget(row + (left - 1) * 4) { left -= 1 }
            var right = node.x
            while right < width - 1, isTarget(row + (right + 1) * 4) { right += 1 }

            for x in left...right { paint(row + x * 4) }

            for neighbourY in [node.y - 1, node.y + 1] where neighbourY >= 0 && neighbourY < height {
                let neighbourRow = rowStart(neighbourY)
                var x = left
                while x <= right {
                    if isTarget(neighbourRow + x * 4) {
                        var runEnd = x
                        while runEnd < right, isTarget(neighbourRow + (runEnd + 1) * 4) { runEnd += 1 }
                        stack.append((x: runEnd, y: neighbourY))
                        x = runEnd + 2
                    } else {
                        x += 1
                    }
                }
            }
        }

        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    // MARK: Eyedropper

    func color(at point: CGPoint) -> NSColor? {
        guard let pixel = pixelCoordinate(point) else { return nil }
        let raw = readPixel(x: pixel.x, y: pixel.y)
        let alpha = CGFloat(raw.3) / 255
        guard alpha > 0 else {
            return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        }
        // Stored premultiplied; undo that so the picked colour is the real one.
        return NSColor(
            srgbRed: min(1, CGFloat(raw.0) / 255 / alpha),
            green: min(1, CGFloat(raw.1) / 255 / alpha),
            blue: min(1, CGFloat(raw.2) / 255 / alpha),
            alpha: alpha
        )
    }

    // MARK: Text

    func addText(_ string: String, at point: CGPoint, color: NSColor, fontSize: CGFloat) {
        let text = string
        guard !text.isEmpty else { return }

        let snapshot = makeSnapshot()
        let origin = clampToCanvas(point)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(1, fontSize)),
            .foregroundColor: color,
        ]

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: buffer.context, flipped: false)
        NSGraphicsContext.current = graphicsContext
        graphicsContext.shouldAntialias = true
        NSAttributedString(string: text, attributes: attributes).draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()

        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    // MARK: Whole-canvas operations

    func clear(color: NSColor) {
        let snapshot = makeSnapshot()
        fillEntireBitmap(with: color)
        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    /// Starts over: fresh white bitmap, empty history, clean state.
    func newDocument(width: Int, height: Int) {
        let size = PaintDocument.clamp(width: width, height: height)
        if let replacement = PixelBuffer(width: size.width, height: size.height) {
            buffer = replacement
            canvasSize = CGSize(width: replacement.width, height: replacement.height)
        }
        fillEntireBitmap(with: .white)
        resetHistory()
        didMutate()
        stateID = 0
        savedStateID = 0
        nextStateID = 1
        refreshFlags()
    }

    /// Non-destructive resize: existing pixels are preserved anchored to the
    /// top-left corner, new area is painted with `background`.
    func resize(width: Int, height: Int, background: NSColor) {
        let size = PaintDocument.clamp(width: width, height: height)
        guard size.width != buffer.width || size.height != buffer.height else { return }
        guard let replacement = PixelBuffer(width: size.width, height: size.height) else { return }

        let snapshot = makeSnapshot()
        let existing = buffer.context.makeImage()

        replacement.context.saveGState()
        replacement.context.setFillColor(PaintDocument.cgColor(background))
        replacement.context.fill(CGRect(x: 0, y: 0, width: replacement.width, height: replacement.height))
        if let existing {
            replacement.context.interpolationQuality = .none
            replacement.context.draw(
                existing,
                in: CGRect(
                    x: 0,
                    y: CGFloat(replacement.height - buffer.height),
                    width: CGFloat(buffer.width),
                    height: CGFloat(buffer.height)
                )
            )
            replacement.context.interpolationQuality = .high
        }
        replacement.context.restoreGState()

        buffer = replacement
        canvasSize = CGSize(width: replacement.width, height: replacement.height)
        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    // MARK: File I/O

    func open(url: URL) throws {
        guard let image = PaintDocument.loadImage(at: url) else {
            throw PaintDocumentError.unreadableImage(url)
        }
        let size = PaintDocument.clamp(width: image.width, height: image.height)
        guard let replacement = PixelBuffer(width: size.width, height: size.height) else {
            throw PaintDocumentError.allocationFailed(width: size.width, height: size.height)
        }

        replacement.context.saveGState()
        replacement.context.setFillColor(PaintDocument.cgColor(.white))
        replacement.context.fill(
            CGRect(x: 0, y: 0, width: replacement.width, height: replacement.height)
        )
        // Normalised into our own RGBA bitmap regardless of the file's colour
        // space, bit depth or alpha layout.
        replacement.context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: replacement.width, height: replacement.height)
        )
        replacement.context.restoreGState()

        buffer = replacement
        canvasSize = CGSize(width: replacement.width, height: replacement.height)
        resetHistory()
        didMutate()
        stateID = 0
        savedStateID = 0
        nextStateID = 1
        refreshFlags()
    }

    func savePNG(to url: URL) throws {
        guard let image = buffer.context.makeImage() else {
            throw PaintDocumentError.encodingFailed(url)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: buffer.width, height: buffer.height)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw PaintDocumentError.encodingFailed(url)
        }
        try data.write(to: url, options: .atomic)
        savedStateID = stateID
        refreshFlags()
    }

    /// Decodes `url` into a `CGImage` whose pixels are already laid out the way
    /// the file wants to be displayed. Camera JPEG/HEIC files carry an EXIF
    /// orientation tag that `CGImageSourceCreateImageAtIndex` deliberately
    /// ignores, so importing the raw image would open sideways or mirrored.
    private static func loadImage(at url: URL) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0,
           let image = orientedImage(from: source) {
            return image
        }
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// ImageIO bakes the orientation tag into the pixels when asked for a
    /// *transformed* thumbnail. Capping the thumbnail at the source's longest
    /// edge means nothing is downsampled: the result is the full resolution
    /// image, rotated, with the logical dimensions swapped for the 90° tags.
    /// Decoding is forced up front because the caller draws the image once,
    /// immediately, and then throws it away.
    private static func orientedImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let longestEdge = max(pixelWidth, pixelHeight)

        if longestEdge > 0,
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(
               source,
               0,
               [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: longestEdge,
                   kCGImageSourceShouldCacheImmediately: true
               ] as CFDictionary
           ),
           max(thumbnail.width, thumbnail.height) >= longestEdge {
            return thumbnail
        }

        // Some providers refuse thumbnail creation; decode the frame directly
        // and rotate it by hand so those files still open upright.
        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return applyOrientation(orientation, to: image)
    }

    /// Redraws `image` so an EXIF orientation tag becomes real pixel layout.
    /// Transforms are expressed in the destination's bottom-left user space,
    /// where `CGContext.draw` already places image row 0 along the top edge.
    private static func applyOrientation(_ orientation: Int, to image: CGImage) -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let sourceWidth = image.width
        let sourceHeight = image.height
        let swapsAxes = orientation >= 5
        let width = swapsAxes ? sourceHeight : sourceWidth
        let height = swapsAxes ? sourceWidth : sourceHeight
        guard let buffer = PixelBuffer(width: width, height: height) else { return image }

        let context = buffer.context
        let w = CGFloat(width)
        let h = CGFloat(height)
        switch orientation {
        case 2: // Mirror horizontal.
            context.translateBy(x: w, y: 0)
            context.scaleBy(x: -1, y: 1)
        case 3: // Rotate 180°.
            context.translateBy(x: w, y: h)
            context.rotate(by: .pi)
        case 4: // Mirror vertical.
            context.translateBy(x: 0, y: h)
            context.scaleBy(x: 1, y: -1)
        case 5: // Mirror horizontal, then rotate 270° clockwise.
            context.concatenate(CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h))
        case 6: // Rotate 90° clockwise.
            context.translateBy(x: 0, y: h)
            context.rotate(by: -.pi / 2)
        case 7: // Mirror horizontal, then rotate 90° clockwise.
            context.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        default: // 8: rotate 270° clockwise.
            context.translateBy(x: w, y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        )
        return context.makeImage() ?? image
    }

    // MARK: Undo / redo

    func undo() {
        cancelStroke()
        guard let snapshot = undoStack.popLast() else { return }
        historyBytes -= snapshot.byteCount
        let current = makeSnapshot()
        redoStack.append(current)
        historyBytes += current.byteCount
        restore(snapshot)
        didMutate()
        refreshFlags()
    }

    func redo() {
        cancelStroke()
        guard let snapshot = redoStack.popLast() else { return }
        historyBytes -= snapshot.byteCount
        let current = makeSnapshot()
        undoStack.append(current)
        historyBytes += current.byteCount
        restore(snapshot)
        didMutate()
        refreshFlags()
    }

    private func pushUndo(_ snapshot: PaintSnapshot) {
        undoStack.append(snapshot)
        historyBytes += snapshot.byteCount
        if !redoStack.isEmpty {
            historyBytes -= redoStack.reduce(0) { $0 + $1.byteCount }
            redoStack.removeAll(keepingCapacity: true)
        }
        trimHistory()
    }

    private func trimHistory() {
        while undoStack.count > PaintDocument.maxHistoryStates {
            historyBytes -= undoStack.removeFirst().byteCount
        }
        while historyBytes > PaintDocument.maxHistoryBytes, undoStack.count > 1 {
            historyBytes -= undoStack.removeFirst().byteCount
        }
        while historyBytes > PaintDocument.maxHistoryBytes, !redoStack.isEmpty {
            historyBytes -= redoStack.removeFirst().byteCount
        }
    }

    private func resetHistory() {
        undoStack.removeAll(keepingCapacity: false)
        redoStack.removeAll(keepingCapacity: false)
        historyBytes = 0
        pendingSnapshot = nil
        pendingDidPaint = false
    }

    // MARK: Snapshots

    private func makeSnapshot() -> PaintSnapshot {
        PaintSnapshot(
            width: buffer.width,
            height: buffer.height,
            bytesPerRow: buffer.bytesPerRow,
            bytes: [UInt8](UnsafeBufferPointer(start: buffer.bytes, count: buffer.byteCount)),
            stateID: stateID
        )
    }

    private func restore(_ snapshot: PaintSnapshot) {
        if snapshot.width != buffer.width || snapshot.height != buffer.height {
            guard let replacement = PixelBuffer(width: snapshot.width, height: snapshot.height)
            else { return }
            buffer = replacement
            canvasSize = CGSize(width: replacement.width, height: replacement.height)
        }

        if snapshot.bytesPerRow == buffer.bytesPerRow, snapshot.byteCount == buffer.byteCount {
            snapshot.bytes.withUnsafeBufferPointer { source in
                buffer.bytes.update(from: source.baseAddress!, count: source.count)
            }
        } else {
            // Row stride changed between allocations: copy row by row.
            let rowBytes = min(snapshot.bytesPerRow, buffer.bytesPerRow)
            snapshot.bytes.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                for row in 0..<buffer.height {
                    let from = row * snapshot.bytesPerRow
                    guard from + rowBytes <= source.count else { break }
                    buffer.bytes.advanced(by: row * buffer.bytesPerRow)
                        .update(from: base.advanced(by: from), count: rowBytes)
                }
            }
        }

        stateID = snapshot.stateID
    }

    // MARK: Pixels

    private func fillEntireBitmap(with color: NSColor) {
        let context = buffer.context
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(PaintDocument.cgColor(color))
        context.fill(CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        context.restoreGState()
        didMutate()
    }

    @inline(__always)
    private func readPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let base = buffer.offset(x: x, y: y)
        return (
            buffer.bytes[base],
            buffer.bytes[base + 1],
            buffer.bytes[base + 2],
            buffer.bytes[base + 3]
        )
    }

    /// Integer pixel for a document point, or nil when the point is off canvas.
    private func pixelCoordinate(_ point: CGPoint) -> (x: Int, y: Int)? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard buffer.contains(x: x, y: y) else { return nil }
        return (x, y)
    }

    /// Keeps drawing coordinates inside the bitmap so a drag that leaves the
    /// view still produces a well defined edge stroke.
    private func clampToCanvas(_ point: CGPoint) -> CGPoint {
        let x = point.x.isFinite ? point.x : 0
        let y = point.y.isFinite ? point.y : 0
        return CGPoint(
            x: min(max(x, 0), CGFloat(buffer.width)),
            y: min(max(y, 0), CGFloat(buffer.height))
        )
    }

    private static func components(of color: NSColor) -> (UInt8, UInt8, UInt8, UInt8) {
        let srgb = color.usingColorSpace(.sRGB) ?? NSColor.black
        let alpha = srgb.alphaComponent
        // Stored premultiplied, matching the bitmap layout.
        let scale: (CGFloat) -> UInt8 = { value in
            UInt8(max(0, min(255, (value * alpha * 255).rounded())))
        }
        return (
            scale(srgb.redComponent),
            scale(srgb.greenComponent),
            scale(srgb.blueComponent),
            UInt8(max(0, min(255, (alpha * 255).rounded())))
        )
    }

    @inline(__always)
    private static func matches(
        _ lhs: (UInt8, UInt8, UInt8, UInt8),
        _ rhs: (UInt8, UInt8, UInt8, UInt8),
        tolerance: Int
    ) -> Bool {
        abs(Int(lhs.0) - Int(rhs.0)) <= tolerance
            && abs(Int(lhs.1) - Int(rhs.1)) <= tolerance
            && abs(Int(lhs.2) - Int(rhs.2)) <= tolerance
            && abs(Int(lhs.3) - Int(rhs.3)) <= tolerance
    }

    private static func cgColor(_ color: NSColor) -> CGColor {
        (color.usingColorSpace(.sRGB) ?? color).cgColor
    }

    private static func clamp(width: Int, height: Int) -> (width: Int, height: Int) {
        (
            width: min(max(width, 1), maxDimension),
            height: min(max(height, 1), maxDimension)
        )
    }

    // MARK: Bookkeeping

    /// Marks the pixels changed: invalidates the cached image and wakes views.
    private func didMutate() {
        cachedImage = nil
        revision &+= 1
    }

    /// Records a new logical state (one per committed operation) and republishes
    /// the derived flags.
    private func markMutated() {
        stateID = nextStateID
        nextStateID &+= 1
        refreshFlags()
    }

    private func refreshFlags() {
        let dirty = stateID != savedStateID
        if isDirty != dirty { isDirty = dirty }
        let undoable = !undoStack.isEmpty
        if canUndo != undoable { canUndo = undoable }
        let redoable = !redoStack.isEmpty
        if canRedo != redoable { canRedo = redoable }
    }
}
