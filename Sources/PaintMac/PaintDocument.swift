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

/// One undo/redo state: the raw background pixels plus the entity list drawn on
/// top of them. Dimensions are stored so history can cross canvas resizes, and
/// the logical state identifier so dirty tracking survives time travel.
///
/// Entities are value types whose point arrays are copy-on-write, so a snapshot
/// that leaves them untouched shares their storage with the live document and
/// costs nothing beyond the array spine.
private struct PaintSnapshot {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]
    let entities: [PaintEntity]
    let stateID: Int

    /// Only the bitmap counts against the history budget: entity storage is
    /// shared between snapshots, so charging for it on every state would trim
    /// history far more aggressively than the real memory use warrants.
    var byteCount: Int { bytes.count }
}

@MainActor
final class PaintDocument: ObservableObject {
    // MARK: Published state

    /// Bumped on every visible change; views observe this to redraw.
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

    /// The opaque background: imported images, flood fill results and the
    /// canvas colour. Everything the toolbox draws afterwards lives in
    /// `entities` and is composited over this on demand.
    private var buffer: PixelBuffer
    /// Retained drawings in back-to-front paint order.
    private var entities: [PaintEntity] = []
    /// The stroke entity an open freehand drag is still growing.
    private var pendingStrokeID: UUID?

    private var undoStack: [PaintSnapshot] = []
    private var redoStack: [PaintSnapshot] = []
    private var historyBytes: Int = 0

    /// Snapshot captured by `beginStroke()`, held for the whole drag so drag
    /// segments never copy the bitmap.
    private var pendingSnapshot: PaintSnapshot?

    /// Scratch bitmap the composite is rendered into. Reused across revisions;
    /// reallocated only when the canvas changes size.
    private var scratch: PixelBuffer?

    private var cachedBackground: CGImage?
    private var cachedImage: CGImage?
    private var cachedImageRevision: Int = -1
    private var cachedExcludedImage: CGImage?
    private var cachedExcludedID: UUID?
    private var cachedExcludedRevision: Int = -1

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

    /// Immutable composite — background plus every entity — for the current
    /// revision. Built once per revision, so a drag that emits many segments
    /// produces one copy per painted frame.
    var cgImage: CGImage? {
        renderedImage(excludingEntity: nil)
    }

    /// The composite with one entity left out, which is what the canvas draws
    /// under a live selection drag. Passing `nil` yields the full composite.
    func renderedImage(excludingEntity id: UUID?) -> CGImage? {
        guard let id else {
            if let cachedImage, cachedImageRevision == revision { return cachedImage }
            let image = composite(excluding: nil)
            cachedImage = image
            cachedImageRevision = revision
            return image
        }
        if let cachedExcludedImage, cachedExcludedRevision == revision, cachedExcludedID == id {
            return cachedExcludedImage
        }
        let image = composite(excluding: id)
        cachedExcludedImage = image
        cachedExcludedID = id
        cachedExcludedRevision = revision
        return image
    }

    var pixelWidth: Int { buffer.width }
    var pixelHeight: Int { buffer.height }

    // MARK: Freehand strokes

    /// Opens a stroke transaction. Exactly one snapshot is taken here; the
    /// individual drag segments only grow the stroke entity.
    func beginStroke() {
        if pendingSnapshot != nil {
            cancelStroke()
        }
        pendingSnapshot = makeSnapshot()
        pendingStrokeID = nil
    }

    /// Extends the open stroke by one segment. The first segment of a drag
    /// creates the entity; every later one appends a point to it, so the whole
    /// gesture becomes a single selectable stroke.
    func drawStroke(
        from start: CGPoint,
        to end: CGPoint,
        tool: PaintTool,
        color: NSColor,
        secondaryColor: NSColor
    ) {
        let paint: NSColor

        switch tool {
        case .pencil, .brush, .thickBrush:
            paint = color
        case .eraser:
            // Erasing lays down the canvas colour as an unselectable stroke.
            paint = secondaryColor
        default:
            // Not freehand tools: they commit through their own entry points.
            return
        }

        let from = clampToCanvas(start)
        let to = clampToCanvas(end)

        if let index = pendingStrokeIndex() {
            entities[index].appendStrokePoint(to)
        } else {
            var entity = PaintEntity(
                content: .stroke(tool: tool, points: [from], color: paint)
            )
            // A click that never moves stays a one-point stroke, which renders
            // and hit tests as a single dab.
            if hypot(to.x - from.x, to.y - from.y) >= 0.01 {
                entity.appendStrokePoint(to)
            }
            pendingStrokeID = entity.id
            entities.append(entity)
        }

        didMutate()
    }

    /// Commits the open transaction as a single undo checkpoint. A stroke that
    /// drew nothing leaves no history entry.
    func endStroke() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        guard pendingStrokeID != nil else { return }
        pendingStrokeID = nil
        pushUndo(snapshot)
        markMutated()
    }

    /// Aborts the open transaction, dropping the stroke entity captured by
    /// `beginStroke()` without recording history.
    func cancelStroke() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        guard pendingStrokeID != nil else { return }
        pendingStrokeID = nil
        restore(snapshot)
        didMutateBackground()
        refreshFlags()
    }

    /// The pending stroke is the entity most recently appended, so the common
    /// case is a direct index instead of a search.
    private func pendingStrokeIndex() -> Int? {
        guard let id = pendingStrokeID else { return nil }
        if let last = entities.last, last.id == id { return entities.count - 1 }
        return entities.firstIndex { $0.id == id }
    }

    // MARK: Shapes

    func addShape(
        tool: PaintTool,
        from start: CGPoint,
        to end: CGPoint,
        color: NSColor,
        constrained: Bool
    ) {
        guard tool.isShape else { return }

        let from = clampToCanvas(start)
        let dragged = clampToCanvas(end)
        // The Shift rule is resolved once, here: the entity stores the final
        // endpoints so later edits never re-snap the shape.
        let to = constrained
            ? PaintShapeGeometry.constrainedEnd(tool: tool, from: from, to: dragged)
            : dragged
        guard PaintShapeGeometry.path(
            tool: tool,
            from: from,
            to: to,
            constrained: false
        ) != nil else { return }

        let snapshot = makeSnapshot()
        entities.append(
            PaintEntity(content: .shape(tool: tool, from: from, to: to, color: color))
        )
        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    // MARK: Flood fill

    /// Scanline flood fill over the real RGBA bytes. Iterative (no recursion),
    /// bounds checked, and a no-op — with no history entry — when the click
    /// lands outside the canvas or the target already matches the fill colour.
    ///
    /// Filling is the one operation that cannot respect entities: it reasons
    /// about pixels, so the current composite is flattened into the background
    /// first and the entity list is cleared. Undo brings the entities back.
    func floodFill(at point: CGPoint, color: NSColor) {
        guard let seed = pixelCoordinate(point) else { return }

        let replacement = PaintDocument.components(of: color)
        let snapshot = makeSnapshot()
        flattenEntitiesIntoBackground()

        let target = readPixel(buffer, x: seed.x, y: seed.y)
        guard !PaintDocument.matches(target, replacement, tolerance: PaintDocument.fillTolerance)
        else {
            // Nothing to fill: undo the flatten so the click changed nothing.
            if !snapshot.entities.isEmpty {
                restore(snapshot)
                didMutateBackground()
            }
            return
        }

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
        didMutateBackground()
        markMutated()
    }

    /// Bakes every entity into the background bitmap and drops the entity list.
    /// Records no history of its own: the caller owns the checkpoint.
    private func flattenEntitiesIntoBackground() {
        guard !entities.isEmpty else { return }
        let context = buffer.context
        for entity in entities {
            entity.draw(in: context)
        }
        entities.removeAll(keepingCapacity: false)
        pendingStrokeID = nil
        cachedBackground = nil
    }

    // MARK: Eyedropper

    /// Samples the composite, so picking from a shape, a doodle or a run of
    /// text returns the colour the user can actually see.
    func color(at point: CGPoint) -> NSColor? {
        guard let pixel = pixelCoordinate(point) else { return nil }
        let raw = readPixel(compositedBuffer(excluding: nil), x: pixel.x, y: pixel.y)
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
        guard !string.isEmpty else { return }

        let snapshot = makeSnapshot()
        entities.append(
            PaintEntity(
                content: .text(
                    value: string,
                    origin: clampToCanvas(point),
                    color: color,
                    fontSize: fontSize
                )
            )
        )
        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    // MARK: Entities

    /// Every entity a click can pick up, in back-to-front paint order. Eraser
    /// strokes are deliberately absent: erasing is a mark on the drawing, not a
    /// thing on it.
    var selectableEntityIDs: [UUID] {
        var ids: [UUID] = []
        ids.reserveCapacity(entities.count)
        for entity in entities where entity.isSelectable {
            ids.append(entity.id)
        }
        return ids
    }

    /// Topmost selectable entity under `point`, or nil for empty canvas.
    func entityID(at point: CGPoint, tolerance: CGFloat) -> UUID? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let slack = tolerance.isFinite ? max(0, tolerance) : 0
        for entity in entities.reversed() where entity.isSelectable {
            if entity.hitTest(point, tolerance: slack) { return entity.id }
        }
        return nil
    }

    /// Whether `point` lands on one specific entity's ink, within `tolerance`
    /// world-space slack. Selection asks this about the entity it already
    /// holds, so a body drag follows the shape the user can see rather than
    /// the axis-aligned box around it, and keeps its grip on a rotated entity
    /// even when another one is stacked above. False for unknown entities.
    func entityHitTest(_ id: UUID, at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard point.x.isFinite, point.y.isFinite, let entity = entity(with: id) else {
            return false
        }
        return entity.hitTest(point, tolerance: tolerance.isFinite ? max(0, tolerance) : 0)
    }

    /// World-space bounds of an entity with `additional` applied on top of its
    /// own transform — the live drag matrix during a transform, `.identity`
    /// once it is committed. Nil for unknown entities and for ones that draw
    /// nothing.
    func entityBounds(_ id: UUID, applying additional: CGAffineTransform) -> CGRect? {
        guard let entity = entity(with: id) else { return nil }
        let bounds = entity.bounds(applying: additional)
        guard !bounds.isNull, !bounds.isInfinite else { return nil }
        return bounds
    }

    /// Tight bounds of the entity's ink in its own untransformed coordinates —
    /// the rectangle the selection frame is built from, so the frame stays a
    /// quadrilateral carried by the entity's matrix instead of an axis-aligned
    /// box re-measured (and inflated) on every edit. Nil for unknown entities
    /// and for ones that draw nothing.
    func entityLocalBounds(_ id: UUID) -> CGRect? {
        guard let entity = entity(with: id) else { return nil }
        let bounds = entity.localBounds
        guard !bounds.isNull, !bounds.isInfinite else { return nil }
        return bounds
    }

    /// The entity's current matrix from local to document space. Selection
    /// holds on to this so a drag can compose against the exact transform the
    /// frame was drawn with. Nil for unknown entities.
    func entityTransform(_ id: UUID) -> CGAffineTransform? {
        entity(with: id)?.transform
    }

    /// The colour an entity currently paints with, so a caller can tell a real
    /// recolour from a no-op without reaching into the entity list. Nil for
    /// unknown identifiers.
    func entityColor(_ id: UUID) -> NSColor? {
        entity(with: id)?.color
    }

    /// World-space bounds the entity would occupy under `absolute` as its whole
    /// transform, ignoring the one it currently carries. This is the query for
    /// a candidate matrix a drag has already composed in full.
    func entityBounds(_ id: UUID, using absolute: CGAffineTransform) -> CGRect? {
        guard let entity = entity(with: id) else { return nil }
        let bounds = entity.bounds(using: absolute)
        guard !bounds.isNull, !bounds.isInfinite else { return nil }
        return bounds
    }

    /// Draws one entity into an arbitrary context — the canvas uses this for
    /// the transform preview, which never touches the model.
    func drawEntity(_ id: UUID, in context: CGContext, applying additional: CGAffineTransform) {
        guard let entity = entity(with: id) else { return }
        entity.draw(in: context, applying: additional)
    }

    /// Draws one entity under `absolute` as its whole transform, replacing the
    /// one it carries. The live preview of a resize or rotation hands over the
    /// very matrix it will commit, so the pixels under the frame and the pixels
    /// after the commit cannot disagree.
    func drawEntity(_ id: UUID, in context: CGContext, using absolute: CGAffineTransform) {
        guard let entity = entity(with: id) else { return }
        entity.draw(in: context, using: absolute)
    }

    /// Commits a move, resize or rotation as exactly one undoable step.
    /// Identity, non-finite and degenerate matrices change nothing and record
    /// nothing, as do unknown identifiers.
    func transformEntity(_ id: UUID, by additional: CGAffineTransform) {
        guard !PaintEntity.isIdentity(additional),
              PaintEntity.isInvertible(additional),
              let index = entities.firstIndex(where: { $0.id == id })
        else { return }

        let snapshot = makeSnapshot()
        entities[index].applyWorldTransform(additional)
        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    /// Replaces an entity's transform outright as exactly one undoable step.
    ///
    /// A drag composes its edit in the space it belongs in — world space for a
    /// move or rotation, the entity's own local space for a resize — and hands
    /// the finished matrix over here. Committing the result rather than an
    /// extra world-space factor is what keeps a rotated shape's axes square:
    /// nothing is ever re-derived from an axis-aligned box.
    ///
    /// Non-finite and degenerate matrices are rejected, and a replacement equal
    /// to the transform already stored changes nothing, so neither leaves a
    /// history entry.
    func setEntityTransform(_ id: UUID, to absolute: CGAffineTransform) {
        guard PaintEntity.isInvertible(absolute),
              let index = entities.firstIndex(where: { $0.id == id }),
              entities[index].transform != absolute
        else { return }

        let snapshot = makeSnapshot()
        entities[index].transform = absolute
        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    /// Repaints one entity as exactly one undoable step, leaving its geometry,
    /// tool, text, transform and identity untouched.
    ///
    /// This is what choosing a colour with something selected means: the pick
    /// lands on the selection instead of only arming the next stroke. Unknown
    /// identifiers, entities the user cannot select in the first place — eraser
    /// strokes — and a colour equivalent to the one already stored all change
    /// nothing, so none of them leaves a history entry or dirties the document.
    func recolorEntity(_ id: UUID, to color: NSColor) {
        guard let index = entities.firstIndex(where: { $0.id == id }),
              entities[index].isSelectable,
              !PaintEntity.isSameColor(entities[index].color, color)
        else { return }

        let snapshot = makeSnapshot()
        entities[index].replaceColor(color)
        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    /// Removes an entity as one undoable step. Unknown identifiers are no-ops.
    func deleteEntity(_ id: UUID) {
        guard let index = entities.firstIndex(where: { $0.id == id }) else { return }

        let snapshot = makeSnapshot()
        entities.remove(at: index)
        if pendingStrokeID == id { pendingStrokeID = nil }
        pushUndo(snapshot)
        didMutate()
        markMutated()
    }

    private func entity(with id: UUID) -> PaintEntity? {
        for entity in entities where entity.id == id { return entity }
        return nil
    }

    // MARK: Whole-canvas operations

    func clear(color: NSColor) {
        let snapshot = makeSnapshot()
        entities.removeAll(keepingCapacity: false)
        pendingStrokeID = nil
        fillEntireBitmap(with: color)
        pushUndo(snapshot)
        markMutated()
    }

    /// Starts over: fresh white bitmap, no entities, empty history, clean state.
    func newDocument(width: Int, height: Int) {
        let size = PaintDocument.clamp(width: width, height: height)
        if let replacement = PixelBuffer(width: size.width, height: size.height) {
            buffer = replacement
            canvasSize = CGSize(width: replacement.width, height: replacement.height)
        }
        entities.removeAll(keepingCapacity: false)
        fillEntireBitmap(with: .white)
        resetHistory()
        didMutateBackground()
        stateID = 0
        savedStateID = 0
        nextStateID = 1
        refreshFlags()
    }

    /// Non-destructive resize: existing content is preserved anchored to the
    /// top-left corner, new area is painted with `background`. Entities travel
    /// with the background — the canvas grows downward in this bottom-left
    /// coordinate space, so they shift by the height difference — and are
    /// clipped by the new canvas when drawn.
    func resize(width: Int, height: Int, background: NSColor) {
        let size = PaintDocument.clamp(width: width, height: height)
        guard size.width != buffer.width || size.height != buffer.height else { return }
        guard let replacement = PixelBuffer(width: size.width, height: size.height) else { return }

        let snapshot = makeSnapshot()
        let existing = backgroundImage()

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

        let shift = CGFloat(replacement.height - buffer.height)
        if shift != 0 {
            let translation = PaintEntity.moveTransform(dx: 0, dy: shift)
            for index in entities.indices {
                entities[index].applyWorldTransform(translation)
            }
        }

        buffer = replacement
        canvasSize = CGSize(width: replacement.width, height: replacement.height)
        pushUndo(snapshot)
        didMutateBackground()
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
        entities.removeAll(keepingCapacity: false)
        resetHistory()
        didMutateBackground()
        stateID = 0
        savedStateID = 0
        nextStateID = 1
        refreshFlags()
    }

    func savePNG(to url: URL) throws {
        guard let image = cgImage else {
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
        didMutateBackground()
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
        didMutateBackground()
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
        pendingStrokeID = nil
    }

    // MARK: Snapshots

    private func makeSnapshot() -> PaintSnapshot {
        PaintSnapshot(
            width: buffer.width,
            height: buffer.height,
            bytesPerRow: buffer.bytesPerRow,
            bytes: [UInt8](UnsafeBufferPointer(start: buffer.bytes, count: buffer.byteCount)),
            entities: entities,
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

        entities = snapshot.entities
        pendingStrokeID = nil
        stateID = snapshot.stateID
    }

    // MARK: Compositing

    /// Background plus every entity except `excluded`, rendered into the shared
    /// scratch bitmap. Returns the background buffer itself when there is
    /// nothing to draw over it, so the common case allocates and copies nothing.
    private func compositedBuffer(excluding excluded: UUID?) -> PixelBuffer {
        guard entities.contains(where: { $0.id != excluded }), let target = scratchBuffer() else {
            return buffer
        }

        let context = target.context
        let canvas = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        context.saveGState()
        context.setBlendMode(.copy)
        if let background = backgroundImage() {
            context.draw(background, in: canvas)
        } else {
            context.setFillColor(PaintDocument.cgColor(.white))
            context.fill(canvas)
        }
        context.restoreGState()

        for entity in entities where entity.id != excluded {
            entity.draw(in: context)
        }
        return target
    }

    private func composite(excluding excluded: UUID?) -> CGImage? {
        let source = compositedBuffer(excluding: excluded)
        if source === buffer { return backgroundImage() }
        return source.context.makeImage()
    }

    /// The background bitmap as an image, cached until the pixels change.
    private func backgroundImage() -> CGImage? {
        if let cachedBackground { return cachedBackground }
        let image = buffer.context.makeImage()
        cachedBackground = image
        return image
    }

    private func scratchBuffer() -> PixelBuffer? {
        if let scratch, scratch.width == buffer.width, scratch.height == buffer.height {
            return scratch
        }
        let replacement = PixelBuffer(width: buffer.width, height: buffer.height)
        scratch = replacement
        return replacement
    }

    // MARK: Pixels

    private func fillEntireBitmap(with color: NSColor) {
        let context = buffer.context
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(PaintDocument.cgColor(color))
        context.fill(CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        context.restoreGState()
        didMutateBackground()
    }

    @inline(__always)
    private func readPixel(_ source: PixelBuffer, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let base = source.offset(x: x, y: y)
        return (
            source.bytes[base],
            source.bytes[base + 1],
            source.bytes[base + 2],
            source.bytes[base + 3]
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

    /// Marks the composite changed: invalidates the cached images and wakes
    /// views. The background image cache survives, because entity edits do not
    /// touch the bitmap.
    private func didMutate() {
        cachedImage = nil
        cachedExcludedImage = nil
        cachedExcludedID = nil
        revision &+= 1
    }

    /// `didMutate` plus the background bitmap itself changed.
    private func didMutateBackground() {
        cachedBackground = nil
        didMutate()
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
