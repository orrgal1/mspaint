import AppKit
import Combine
import SwiftUI

// MARK: - Native canvas view

/// The editable bitmap surface. Draws `PaintDocument.cgImage` at `zoom`, converts
/// pointer events into document-space coordinates and funnels every mutation through
/// the document API so that undo checkpoints stay one-per-gesture.
final class PaintCanvasView: NSView {

    // MARK: Gesture state

    private enum Gesture {
        case idle
        case freehand
        case shape
        case selection(SelectionDrag)
    }

    /// The eight resize grips of an axis-aligned selection.
    private enum SelectionHandle: CaseIterable {
        case bottomLeft, bottom, bottomRight, left, right, topLeft, top, topRight
    }

    /// What a drag made with the Select tool is doing. Every case previews only;
    /// the document is mutated once, on mouse up.
    private enum SelectionDrag {
        case marquee(anchor: CGPoint)
        case move(grab: CGPoint, origin: CGRect)
        case resize(handle: SelectionHandle, origin: CGRect)
        case rotate(center: CGPoint, grabAngle: CGFloat)
    }

    /// An opaque rectangular pixel selection: the document rectangle it was lifted
    /// from, the lifted pixels, and the document revision they were lifted at. Any
    /// edit the selection did not make bumps the revision and makes it stale.
    private struct Selection {
        var rect: CGRect
        var image: CGImage
        var revision: Int
    }

    private var gesture: Gesture = .idle
    private var usesSecondaryColor = false
    private var lastPoint: CGPoint = .zero
    private var shapeStart: CGPoint = .zero
    private var shapeEnd: CGPoint = .zero
    private var shiftHeld = false
    private var lastReportedCursor: CGPoint?
    private var revisionObserver: AnyCancellable?
    private var observedRevision = -1
    private var trackingArea: NSTrackingArea?

    // MARK: Selection state

    private var selection: Selection?
    /// Destination of the transform in flight, `nil` while the selection rests at
    /// `selection.rect`.
    private var transformRect: CGRect?
    /// Counterclockwise preview rotation in radians, always zero at rest.
    private var transformRotation: CGFloat = 0
    /// Rectangle of the marquee being dragged out, valid only during `.marquee`.
    private var marqueeRect: CGRect = .zero

    // MARK: Configuration

    private(set) var document: PaintDocument

    private var tool: PaintTool = .pencil
    private var primaryColor: NSColor = .black
    private var secondaryColor: NSColor = .white
    private var zoom: CGFloat = 1

    /// Reports the pointer position in document space, or `nil` once the pointer leaves.
    var onCursorChange: ((CGPoint?) -> Void)?
    /// Reports a sampled color; the flag is `true` when the right button sampled it.
    var onPickColor: ((NSColor, Bool) -> Void)?
    /// Requests a tool change from a bare-key shortcut handled by this view.
    var onSelectTool: ((PaintTool) -> Void)?

    init(document: PaintDocument) {
        self.document = document
        super.init(frame: NSRect(origin: .zero, size: document.canvasSize))
        wantsLayer = true
        observeRevision()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaintCanvasView is not decodable")
    }

    // MARK: Applying SwiftUI state

    func apply(
        document newDocument: PaintDocument,
        tool newTool: PaintTool,
        primaryColor newPrimary: NSColor,
        secondaryColor newSecondary: NSColor,
        zoom newZoom: CGFloat
    ) {
        if newDocument !== document {
            cancelGesture()
            clearSelection()
            document = newDocument
            observeRevision()
        }

        if newTool != tool {
            cancelGesture()
            tool = newTool
            if tool != .select {
                clearSelection()
            }
            window?.invalidateCursorRects(for: self)
        }

        primaryColor = newPrimary
        secondaryColor = newSecondary

        let clampedZoom = max(0.1, newZoom)
        if clampedZoom != zoom {
            zoom = clampedZoom
        }

        syncSize()
        needsDisplay = true
    }

    private func observeRevision() {
        observedRevision = document.revision
        revisionObserver = document.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.syncSize()
                if self.document.revision != self.observedRevision {
                    self.observedRevision = self.document.revision
                    self.discardStaleSelection()
                    self.needsDisplay = true
                }
            }
    }

    private func syncSize() {
        let target = scaledCanvasSize
        if frame.size != target {
            setFrameSize(target)
            invalidateIntrinsicContentSize()
        }
    }

    /// Exact, unrounded canvas extent so that `point / zoom` maps back to the same pixel
    /// grid the document draws into.
    private var scaledCanvasSize: NSSize {
        let size = document.canvasSize
        return NSSize(
            width: max(1, size.width * zoom),
            height: max(1, size.height * zoom)
        )
    }

    override var intrinsicContentSize: NSSize { scaledCanvasSize }

    override var isOpaque: Bool { true }

    override var isFlipped: Bool { false }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    private var canvasRect: CGRect {
        CGRect(origin: .zero, size: scaledCanvasSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(canvasRect)

        if let image = document.cgImage {
            context.saveGState()
            context.interpolationQuality = zoom >= 1 ? .none : .high
            context.draw(image, in: canvasRect)
            context.restoreGState()
        }

        drawShapePreview(in: context)
        drawSelection(in: context)

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.stroke(canvasRect.insetBy(dx: 0.5, dy: 0.5))
    }

    /// Previews the exact path `PaintDocument.addShape` will stroke: endpoints are
    /// clamped into the canvas, the shared geometry is evaluated in document space and
    /// the context is simply scaled by `zoom`, so preview and committed pixels agree.
    /// The stroke style mirrors `PaintDocument.addShape` for the same reason.
    private func drawShapePreview(in context: CGContext) {
        guard case .shape = gesture else { return }

        let start = clampedToCanvas(shapeStart)
        let end = clampedToCanvas(shapeEnd)
        guard let path = PaintShapeGeometry.path(
            tool: tool,
            from: start,
            to: end,
            constrained: shiftHeld
        ) else { return }

        let color = usesSecondaryColor ? secondaryColor : primaryColor

        context.saveGState()
        context.setShouldAntialias(true)
        context.scaleBy(x: zoom, y: zoom)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(tool.strokeWidth)
        context.setLineJoin(.miter)
        context.setLineCap(tool == .line ? .round : .square)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Selection geometry

    /// Controls are measured in view points and divided by `zoom` only where the
    /// math happens in document space, so grips stay the same size on screen at
    /// every magnification.
    private static let handleSide: CGFloat = 8
    private static let handleHitSlop: CGFloat = 5
    private static let rotationHandleDistance: CGFloat = 22
    private static let rotationHandleRadius: CGFloat = 5
    private static let minimumSelectionSide: CGFloat = 4
    private static let rotationSnap: CGFloat = .pi / 12

    /// The rectangle the selection currently occupies on screen: the transform in
    /// flight when there is one, otherwise where the pixels were lifted from.
    private var activeSelectionRect: CGRect? {
        guard let selection else { return nil }
        return transformRect ?? selection.rect
    }

    private func viewRect(for rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * zoom,
            y: rect.minY * zoom,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
    }

    private func handlePoint(_ handle: SelectionHandle, in rect: CGRect) -> CGPoint {
        let x: CGFloat
        switch handle {
        case .bottomLeft, .left, .topLeft: x = rect.minX
        case .bottom, .top: x = rect.midX
        case .bottomRight, .right, .topRight: x = rect.maxX
        }
        let y: CGFloat
        switch handle {
        case .bottomLeft, .bottom, .bottomRight: y = rect.minY
        case .left, .right: y = rect.midY
        case .topLeft, .top, .topRight: y = rect.maxY
        }
        return CGPoint(x: x, y: y)
    }

    /// Rotation grip, in view space, above the top edge and pulled back inside the
    /// canvas when the selection is flush with the top so it stays reachable.
    private func rotationHandleViewPoint(for rect: CGRect) -> CGPoint {
        let frame = viewRect(for: rect)
        let limit = max(0, canvasRect.maxY - Self.rotationHandleRadius - 1)
        return CGPoint(
            x: frame.midX,
            y: min(frame.maxY + Self.rotationHandleDistance, limit)
        )
    }

    // MARK: Selection drawing

    /// Draws the marquee, or the selection: the source area vacated with Color 2 and
    /// the lifted pixels drawn transformed above it, exactly the way
    /// `PaintDocument.transformSelection` will commit them, plus the grips.
    private func drawSelection(in context: CGContext) {
        if case .selection(.marquee) = gesture {
            drawMarchingAnts(around: CGPath(rect: viewRect(for: marqueeRect), transform: nil), in: context)
            return
        }

        guard let selection, let destination = activeSelectionRect else { return }

        let isTransforming = destination != selection.rect || transformRotation != 0
        let frame = viewRect(for: destination)

        if isTransforming {
            context.saveGState()
            context.clip(to: canvasRect)
            context.setFillColor(secondaryColor.cgColor)
            context.fill(viewRect(for: selection.rect))
            context.interpolationQuality = .high
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: transformRotation)
            context.draw(
                selection.image,
                in: CGRect(
                    x: -frame.width / 2,
                    y: -frame.height / 2,
                    width: frame.width,
                    height: frame.height
                )
            )
            context.restoreGState()
        }

        var transform = CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: transformRotation)
            .translatedBy(x: -frame.midX, y: -frame.midY)
        let outline = CGPath(rect: frame, transform: &transform)
        drawMarchingAnts(around: outline, in: context)

        guard case .idle = gesture else { return }
        drawHandles(for: destination, in: context)
    }

    /// A white underlay with a black dash on top, so the border reads over any paint.
    private func drawMarchingAnts(around path: CGPath, in context: CGContext) {
        context.saveGState()
        context.setShouldAntialias(false)
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.strokePath()
        context.restoreGState()
    }

    private func drawHandles(for rect: CGRect, in context: CGContext) {
        let frame = viewRect(for: rect)
        let rotation = rotationHandleViewPoint(for: rect)

        context.saveGState()
        context.setShouldAntialias(true)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.setLineWidth(1)

        context.move(to: CGPoint(x: frame.midX, y: frame.maxY))
        context.addLine(to: rotation)
        context.strokePath()

        for handle in SelectionHandle.allCases {
            let point = handlePoint(handle, in: rect)
            let box = CGRect(
                x: point.x * zoom - Self.handleSide / 2,
                y: point.y * zoom - Self.handleSide / 2,
                width: Self.handleSide,
                height: Self.handleSide
            )
            context.fill(box)
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }

        let knob = CGRect(
            x: rotation.x - Self.rotationHandleRadius,
            y: rotation.y - Self.rotationHandleRadius,
            width: Self.rotationHandleRadius * 2,
            height: Self.rotationHandleRadius * 2
        )
        context.fillEllipse(in: knob)
        context.strokeEllipse(in: knob.insetBy(dx: 0.5, dy: 0.5))
        context.restoreGState()
    }

    // MARK: Coordinate conversion

    private func documentPoint(for event: NSEvent) -> CGPoint {
        documentPoint(forViewPoint: convert(event.locationInWindow, from: nil))
    }

    private func documentPoint(forViewPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / zoom, y: point.y / zoom)
    }

    // MARK: Mouse handling

    override func mouseDown(with event: NSEvent) {
        beginGesture(with: event, secondary: false)
    }

    override func mouseDragged(with event: NSEvent) {
        continueGesture(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        finishGesture(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        beginGesture(with: event, secondary: true)
    }

    override func rightMouseDragged(with event: NSEvent) {
        continueGesture(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        finishGesture(with: event)
    }

    private func beginGesture(with event: NSEvent, secondary: Bool) {
        window?.makeFirstResponder(self)

        let point = documentPoint(for: event)
        reportCursor(point)

        usesSecondaryColor = secondary
        shiftHeld = event.modifierFlags.contains(.shift)

        if tool == .select {
            beginSelectionGesture(
                at: point,
                viewPoint: convert(event.locationInWindow, from: nil)
            )
            return
        }

        if tool.isShape {
            gesture = .shape
            shapeStart = point
            shapeEnd = point
            needsDisplay = true
            return
        }

        let color = secondary ? secondaryColor : primaryColor
        let alternate = secondary ? primaryColor : secondaryColor

        switch tool {
        case .pencil, .brush, .thickBrush, .eraser:
            gesture = .freehand
            lastPoint = point
            document.beginStroke()
            document.drawStroke(
                from: point,
                to: point,
                tool: tool,
                color: color,
                secondaryColor: alternate
            )
        case .fill:
            gesture = .idle
            document.floodFill(at: point, color: color)
        case .eyedropper:
            gesture = .idle
            if let sampled = document.color(at: point) {
                onPickColor?(sampled, secondary)
            }
        case .text:
            gesture = .idle
            presentTextEntry(at: point, color: color)
        default:
            gesture = .idle
        }
    }

    private func continueGesture(with event: NSEvent) {
        let point = documentPoint(for: event)
        reportCursor(point)
        shiftHeld = event.modifierFlags.contains(.shift)

        switch gesture {
        case .freehand:
            let color = usesSecondaryColor ? secondaryColor : primaryColor
            let alternate = usesSecondaryColor ? primaryColor : secondaryColor
            guard point != lastPoint else { return }
            document.drawStroke(
                from: lastPoint,
                to: point,
                tool: tool,
                color: color,
                secondaryColor: alternate
            )
            lastPoint = point
        case .shape:
            shapeEnd = point
            needsDisplay = true
        case .selection(let drag):
            updateSelectionDrag(drag, at: point)
        case .idle:
            break
        }
    }

    private func finishGesture(with event: NSEvent) {
        let point = documentPoint(for: event)
        reportCursor(point)
        shiftHeld = event.modifierFlags.contains(.shift)

        switch gesture {
        case .freehand:
            if point != lastPoint {
                let color = usesSecondaryColor ? secondaryColor : primaryColor
                let alternate = usesSecondaryColor ? primaryColor : secondaryColor
                document.drawStroke(
                    from: lastPoint,
                    to: point,
                    tool: tool,
                    color: color,
                    secondaryColor: alternate
                )
            }
            document.endStroke()
        case .shape:
            shapeEnd = point
            let color = usesSecondaryColor ? secondaryColor : primaryColor
            document.addShape(
                tool: tool,
                from: shapeStart,
                to: shapeEnd,
                color: color,
                constrained: shiftHeld
            )
        case .selection(let drag):
            updateSelectionDrag(drag, at: point)
            commitSelectionDrag(drag)
        case .idle:
            break
        }

        gesture = .idle
        needsDisplay = true
    }

    /// Drops any in-flight gesture without committing pixels. A selection transform
    /// only ever lived in the preview, so dropping it restores the resting selection.
    private func cancelGesture() {
        switch gesture {
        case .freehand:
            document.cancelStroke()
        case .selection:
            transformRect = nil
            transformRotation = 0
            marqueeRect = .zero
        case .shape, .idle:
            break
        }
        gesture = .idle
        needsDisplay = true
    }

    /// Escape: abandon the gesture in flight, and when nothing is in flight drop the
    /// resting selection.
    override func cancelOperation(_ sender: Any?) {
        if case .idle = gesture, selection != nil {
            clearSelection()
            return
        }
        cancelGesture()
    }

    // MARK: Selection interaction

    /// Select-tool mouse down: grab the rotation grip, a resize grip or the body of
    /// the resting selection, otherwise drop it and start a new marquee.
    private func beginSelectionGesture(at point: CGPoint, viewPoint: CGPoint) {
        if let rect = activeSelectionRect {
            if hitsRotationHandle(viewPoint, for: rect) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                gesture = .selection(.rotate(
                    center: center,
                    grabAngle: angle(from: center, to: point)
                ))
                transformRect = rect
                transformRotation = 0
                needsDisplay = true
                return
            }
            if let handle = handle(at: viewPoint, for: rect) {
                gesture = .selection(.resize(handle: handle, origin: rect))
                transformRect = rect
                needsDisplay = true
                return
            }
            if rect.contains(point) {
                gesture = .selection(.move(grab: point, origin: rect))
                transformRect = rect
                needsDisplay = true
                return
            }
            clearSelection()
        }

        let anchor = clampedToCanvas(point)
        gesture = .selection(.marquee(anchor: anchor))
        marqueeRect = CGRect(origin: anchor, size: .zero)
        needsDisplay = true
    }

    /// Every selection drag is preview only: nothing here touches the document.
    private func updateSelectionDrag(_ drag: SelectionDrag, at point: CGPoint) {
        switch drag {
        case .marquee(let anchor):
            marqueeRect = snappedRect(
                CGRect(
                    x: anchor.x,
                    y: anchor.y,
                    width: clampedToCanvas(point).x - anchor.x,
                    height: clampedToCanvas(point).y - anchor.y
                )
            )
        case .move(let grab, let origin):
            transformRect = movedRect(
                origin,
                by: CGPoint(x: point.x - grab.x, y: point.y - grab.y)
            )
        case .resize(let handle, let origin):
            transformRect = resizedRect(origin, handle: handle, to: point)
        case .rotate(let center, let grabAngle):
            var rotation = angle(from: center, to: point) - grabAngle
            if shiftHeld {
                rotation = (rotation / Self.rotationSnap).rounded() * Self.rotationSnap
            }
            transformRotation = rotation
        }
        needsDisplay = true
    }

    /// Mouse up. A marquee lifts pixels without touching the document; every other
    /// drag commits exactly one `transformSelection`, then the selection is recaptured
    /// where it landed so it stays live for the next transform.
    private func commitSelectionDrag(_ drag: SelectionDrag) {
        defer {
            transformRect = nil
            transformRotation = 0
            marqueeRect = .zero
        }

        if case .marquee = drag {
            captureSelection(in: marqueeRect)
            return
        }

        guard let current = selection, let destination = transformRect else { return }
        let rotation = transformRotation
        guard destination != current.rect || rotation != 0 else { return }

        document.transformSelection(
            current.image,
            from: current.rect,
            to: destination,
            rotation: rotation,
            background: secondaryColor
        )
        captureSelection(in: rotatedBounds(of: destination, rotation: rotation))
    }

    /// Lifts the pixels of `rect`; no mutation, no history. A rectangle too small to
    /// hold a pixel simply leaves nothing selected.
    private func captureSelection(in rect: CGRect) {
        let area = snappedRect(rect)
        guard area.width >= 1, area.height >= 1,
            let image = document.selectionImage(in: area)
        else {
            clearSelection()
            return
        }
        selection = Selection(rect: area, image: image, revision: document.revision)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func clearSelection() {
        guard selection != nil || transformRect != nil else { return }
        selection = nil
        transformRect = nil
        transformRotation = 0
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Any edit the selection did not make — undo, redo, another tool, a canvas
    /// resize — leaves the lifted pixels describing a document that no longer exists.
    private func discardStaleSelection() {
        guard let current = selection, current.revision != document.revision else { return }
        if case .selection = gesture {
            cancelGesture()
        }
        clearSelection()
    }

    /// Delete and Backspace erase the selected pixels with Color 2, in one undoable
    /// step, and leave nothing selected.
    @discardableResult
    private func deleteSelection() -> Bool {
        guard let current = selection else { return false }
        if case .selection = gesture {
            cancelGesture()
        }
        document.deleteSelection(in: current.rect, background: secondaryColor)
        clearSelection()
        return true
    }

    // MARK: Selection hit testing

    private func hitsRotationHandle(_ viewPoint: CGPoint, for rect: CGRect) -> Bool {
        let center = rotationHandleViewPoint(for: rect)
        let reach = Self.rotationHandleRadius + Self.handleHitSlop
        return abs(viewPoint.x - center.x) <= reach && abs(viewPoint.y - center.y) <= reach
    }

    /// The grip nearest the pointer within the grip's own reach, measured in view
    /// points so the target stays the same size at every zoom.
    private func handle(at viewPoint: CGPoint, for rect: CGRect) -> SelectionHandle? {
        let reach = Self.handleSide / 2 + Self.handleHitSlop
        var best: (handle: SelectionHandle, distance: CGFloat)?
        for candidate in SelectionHandle.allCases {
            let point = handlePoint(candidate, in: rect)
            let dx = abs(viewPoint.x - point.x * zoom)
            let dy = abs(viewPoint.y - point.y * zoom)
            guard dx <= reach, dy <= reach else { continue }
            let distance = dx + dy
            if let best, best.distance <= distance { continue }
            best = (candidate, distance)
        }
        return best?.handle
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    // MARK: Selection rectangles

    /// Selection rectangles live on whole document pixels and inside the canvas, the
    /// same normalization `PaintDocument` applies, so the lifted image, the preview
    /// and the committed pixels all describe one area.
    private func snappedRect(_ rect: CGRect) -> CGRect {
        guard rect.minX.isFinite, rect.minY.isFinite,
            rect.width.isFinite, rect.height.isFinite
        else { return .zero }

        let normalized = CGRect(
            x: min(rect.minX, rect.maxX),
            y: min(rect.minY, rect.maxY),
            width: abs(rect.width),
            height: abs(rect.height)
        )
        let clamped = normalized.integral.intersection(
            CGRect(origin: .zero, size: document.canvasSize)
        )
        return clamped.isNull ? .zero : clamped
    }

    /// Moves by whole pixels and keeps the rectangle wholly on the canvas, so the
    /// document's own clamp never squeezes the committed image.
    private func movedRect(_ rect: CGRect, by delta: CGPoint) -> CGRect {
        let size = document.canvasSize
        let x = (rect.minX + delta.x).rounded()
        let y = (rect.minY + delta.y).rounded()
        return CGRect(
            x: min(max(0, x), max(0, size.width - rect.width)),
            y: min(max(0, y), max(0, size.height - rect.height)),
            width: rect.width,
            height: rect.height
        )
    }

    /// Axis-aligned resize: only the edges the grip owns move, they stop at the canvas
    /// border and never cross to within `minimumSelectionSide` of the opposite edge.
    private func resizedRect(
        _ rect: CGRect,
        handle: SelectionHandle,
        to point: CGPoint
    ) -> CGRect {
        let size = document.canvasSize
        let minimum = Self.minimumSelectionSide
        let target = clampedToCanvas(point)
        let x = target.x.rounded()
        let y = target.y.rounded()

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .bottomLeft, .left, .topLeft:
            minX = max(0, min(x, maxX - minimum))
        case .bottomRight, .right, .topRight:
            maxX = min(size.width, max(x, minX + minimum))
        case .bottom, .top:
            break
        }

        switch handle {
        case .bottomLeft, .bottom, .bottomRight:
            minY = max(0, min(y, maxY - minimum))
        case .topLeft, .top, .topRight:
            maxY = min(size.height, max(y, minY + minimum))
        case .left, .right:
            break
        }

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    /// Bounding box of the rectangle rotated about its own center: the area
    /// `transformSelection` paints into, and therefore the area to recapture.
    private func rotatedBounds(of rect: CGRect, rotation: CGFloat) -> CGRect {
        guard rotation != 0 else { return rect }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: rotation)
            .translatedBy(x: -center.x, y: -center.y)
        return rect.applying(transform)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            cancelOperation(nil)
            return
        }
        if Self.deleteKeyCodes.contains(event.keyCode), deleteSelection() {
            return
        }
        if handleCanvasShortcut(event) { return }
        super.keyDown(with: event)
    }

    private static let escapeKeyCode: UInt16 = 53

    /// Delete and Forward Delete, which both erase the selection.
    private static let deleteKeyCodes: Set<UInt16> = [51, 117]

    /// Modifiers that always belong to menus, text editing or system gestures.
    private static let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]

    /// Bare-key tool shortcuts, deliberately scoped to `keyDown` on the focused
    /// canvas. Registering them as application key equivalents would swallow plain
    /// letters typed into the text-insert and resize fields.
    private func handleCanvasShortcut(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, window.firstResponder === self else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: Self.reservedModifiers) else { return false }

        guard let typed = event.charactersIgnoringModifiers, typed.count == 1,
              let character = typed.lowercased().first
        else { return false }

        guard let selected = PaintTool.allCases.first(where: { candidate in
            guard let shortcut = candidate.shortcut else { return false }
            return shortcut == character
        }) else { return false }
        onSelectTool?(selected)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if shift != shiftHeld {
            shiftHeld = shift
            if case .shape = gesture {
                needsDisplay = true
            }
        }
        super.flagsChanged(with: event)
    }

    // MARK: Canvas clamp

    /// The document's clamp: `[0, width] × [0, height]` in document space.
    private func clampedToCanvas(_ point: CGPoint) -> CGPoint {
        let size = document.canvasSize
        let x = point.x.isFinite ? point.x : 0
        let y = point.y.isFinite ? point.y : 0
        return CGPoint(
            x: min(max(x, 0), size.width),
            y: min(max(y, 0), size.height)
        )
    }

    // MARK: Text entry

    /// Text is scaled from the Text tool's own outline width, the same way every
    /// other tool derives its footprint from `PaintTool.strokeWidth`, with a floor
    /// that keeps inserted glyphs legible.
    private static let textFontSize: CGFloat = max(12, PaintTool.text.strokeWidth * 6)

    private func presentTextEntry(at point: CGPoint, color: NSColor) {
        let alert = NSAlert()
        alert.messageText = "Insert Text"
        alert.informativeText = "The text is drawn at the click position using the current color."
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Text"
        field.stringValue = ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue
        guard !text.isEmpty else { return }

        document.addText(text, at: point, color: color, fontSize: Self.textFontSize)
    }

    // MARK: Cursor tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        reportCursor(documentPoint(for: event))
    }

    override func mouseEntered(with event: NSEvent) {
        reportCursor(documentPoint(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        reportCursor(nil)
    }

    private func reportCursor(_ point: CGPoint?) {
        let value: CGPoint? = point.map { raw in
            let size = document.canvasSize
            return CGPoint(
                x: min(max(raw.x.rounded(.down), 0), max(0, size.width - 1)),
                y: min(max(raw.y.rounded(.down), 0), max(0, size.height - 1))
            )
        }
        guard value != lastReportedCursor else { return }
        lastReportedCursor = value
        onCursorChange?(value)
    }

    // MARK: Cursors

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: Self.cursor(for: tool))

        guard tool == .select, let rect = activeSelectionRect else { return }

        addSelectionCursorRect(viewRect(for: rect), cursor: .openHand)
        for handle in SelectionHandle.allCases {
            guard let cursor = Self.cursor(for: handle) else { continue }
            let point = handlePoint(handle, in: rect)
            addSelectionCursorRect(
                CGRect(
                    x: point.x * zoom - Self.handleSide / 2,
                    y: point.y * zoom - Self.handleSide / 2,
                    width: Self.handleSide,
                    height: Self.handleSide
                ),
                cursor: cursor
            )
        }
        let rotation = rotationHandleViewPoint(for: rect)
        addSelectionCursorRect(
            CGRect(
                x: rotation.x - Self.rotationHandleRadius,
                y: rotation.y - Self.rotationHandleRadius,
                width: Self.rotationHandleRadius * 2,
                height: Self.rotationHandleRadius * 2
            ),
            cursor: .pointingHand
        )
    }

    private func addSelectionCursorRect(_ rect: CGRect, cursor: NSCursor) {
        let visible = rect.intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        addCursorRect(visible, cursor: cursor)
    }

    /// Only the grips a standard cursor describes honestly: the diagonal resize
    /// cursors are not public API, so the corners keep the Select tool's own artwork.
    private static func cursor(for handle: SelectionHandle) -> NSCursor? {
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .bottomLeft, .bottomRight, .topLeft, .topRight:
            return nil
        }
    }

    /// Always the tool's own artwork: the cache covers every case of `PaintTool`, and
    /// the miss branch renders the same icon rather than degrading to a system cursor.
    private static func cursor(for tool: PaintTool) -> NSCursor {
        if let cached = toolCursors[tool] { return cached }
        return makeCursor(for: tool)
    }

    /// One immutable cursor per tool, rendered once and reused for the rest of the
    /// session. Selecting a tool invalidates the canvas cursor rects, so rendering
    /// on demand would redraw the very same artwork on every hover.
    private static let toolCursors: [PaintTool: NSCursor] = {
        var cursors = [PaintTool: NSCursor](minimumCapacity: PaintTool.allCases.count)
        for tool in PaintTool.allCases {
            cursors[tool] = PaintCanvasView.makeCursor(for: tool)
        }
        return cursors
    }()

    /// Cursor artwork: a compact 32pt square carrying the aiming cross on the hot
    /// spot near the top left corner and the tool's own icon below and right of it,
    /// drawn white over a black rim so both read on light and dark canvases.
    private static let cursorSide: CGFloat = 32
    private static let cursorHotSpot = NSPoint(x: 4, y: 4)
    private static let cursorGlyphBox = CGRect(x: 11, y: 3, width: 18, height: 18)
    private static let cursorRimWidth: CGFloat = 3
    private static let cursorCoreWidth: CGFloat = 1.4

    private static func makeCursor(for tool: PaintTool) -> NSCursor {
        let image = NSImage(
            size: NSSize(width: cursorSide, height: cursorSide),
            flipped: false
        ) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            PaintCanvasView.drawAimingMark(in: context)
            PaintCanvasView.drawGlyph(for: tool, in: context)
            return true
        }
        return NSCursor(image: image, hotSpot: cursorHotSpot)
    }

    /// The aiming cross, centred exactly on the hot spot. `hotSpot` is measured from
    /// the top left, the image draws from the bottom left, hence the flip.
    private static func drawAimingMark(in context: CGContext) {
        let center = CGPoint(x: cursorHotSpot.x, y: cursorSide - cursorHotSpot.y)
        let arm: CGFloat = 4
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        strokeHighContrast(path, in: context, cap: .butt)
    }

    /// Shapes draw the very outline they will stroke onto the canvas, from the shared
    /// `PaintShapeGeometry`; every other tool draws its own SF Symbol.
    private static func drawGlyph(for tool: PaintTool, in context: CGContext) {
        if tool.isShape,
            let path = PaintShapeGeometry.path(
                tool: tool,
                from: CGPoint(x: cursorGlyphBox.minX, y: cursorGlyphBox.minY),
                to: CGPoint(x: cursorGlyphBox.maxX, y: cursorGlyphBox.maxY),
                constrained: false
            )
        {
            strokeHighContrast(path, in: context, cap: .round)
            return
        }

        if let symbol = symbolImage(for: tool) {
            drawSymbol(symbol, in: cursorGlyphBox)
            return
        }

        strokeHighContrast(strokeWidthDisc(for: tool), in: context, cap: .round)
    }

    private static func symbolImage(for tool: PaintTool) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: tool.symbolName,
            accessibilityDescription: tool.title
        ) else { return nil }
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        ) ?? symbol
        configured.isTemplate = true
        return configured
    }

    /// Fits the symbol into the glyph box and rings it with a black rim, so a white
    /// icon stays legible against white paint.
    private static func drawSymbol(_ image: NSImage, in box: CGRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }

        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGRect(
            x: box.midX - size.width * scale / 2,
            y: box.midY - size.height * scale / 2,
            width: size.width * scale,
            height: size.height * scale
        )

        let rim = tinted(image, with: .black)
        let offset: CGFloat = 1.25
        let offsets: [CGFloat] = [-offset, 0, offset]
        for dx in offsets {
            for dy in offsets where dx != 0 || dy != 0 {
                rim.draw(in: fitted.offsetBy(dx: dx, dy: dy))
            }
        }
        tinted(image, with: .white).draw(in: fitted)
    }

    /// A flat single-color copy of a template symbol, so rim and core come from the
    /// same artwork.
    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        let copy = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        copy.isTemplate = false
        return copy
    }

    /// Fallback artwork for a tool whose symbol will not load: a disc sized by the
    /// tool's own stroke width, so the cursor still says something true about it.
    private static func strokeWidthDisc(for tool: PaintTool) -> CGPath {
        let diameter = min(cursorGlyphBox.width, max(5, tool.strokeWidth))
        let rect = CGRect(
            x: cursorGlyphBox.midX - diameter / 2,
            y: cursorGlyphBox.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        return CGPath(ellipseIn: rect, transform: nil)
    }

    private static func strokeHighContrast(_ path: CGPath, in context: CGContext, cap: CGLineCap) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setLineCap(cap)
        context.setLineJoin(.round)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(cursorRimWidth)
        context.addPath(path)
        context.strokePath()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(cursorCoreWidth)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - SwiftUI bridge

struct PaintCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var document: PaintDocument
    @Binding var tool: PaintTool
    @Binding var primaryColor: Color
    @Binding var secondaryColor: Color
    @Binding var zoom: Double
    @Binding var cursorPosition: CGPoint?

    func makeNSView(context: Context) -> PaintCanvasView {
        let view = PaintCanvasView(document: document)
        install(on: view)
        return view
    }

    func updateNSView(_ view: PaintCanvasView, context: Context) {
        install(on: view)
        view.apply(
            document: document,
            tool: tool,
            primaryColor: NSColor(primaryColor),
            secondaryColor: NSColor(secondaryColor),
            zoom: CGFloat(zoom)
        )
    }

    private func install(on view: PaintCanvasView) {
        let cursorBinding = $cursorPosition
        view.onCursorChange = { point in
            if cursorBinding.wrappedValue != point {
                cursorBinding.wrappedValue = point
            }
        }

        let primaryBinding = $primaryColor
        let secondaryBinding = $secondaryColor
        view.onPickColor = { sampled, isSecondary in
            let picked = Color(nsColor: sampled)
            if isSecondary {
                secondaryBinding.wrappedValue = picked
            } else {
                primaryBinding.wrappedValue = picked
            }
        }

        let toolBinding = $tool
        view.onSelectTool = { selected in
            if toolBinding.wrappedValue != selected {
                toolBinding.wrappedValue = selected
            }
        }
    }
}
