import AppKit
import Combine
import SwiftUI

// MARK: - Native canvas view

/// The editable canvas surface. Draws the document composite at `zoom`, converts
/// pointer events into document-space coordinates and funnels every mutation through
/// the document API so that undo checkpoints stay one-per-gesture.
///
/// The Select tool is a hand tool over entities, not an area tool: a click picks the
/// topmost entity under the pointer, a drag on its body moves it, the eight grips
/// resize it and the circular arrow past its top-right corner rotates it.
///
/// The selection frame is an oriented rectangle, never an axis-aligned box: the
/// selection remembers the entity's own local bounds together with the absolute
/// matrix that places them, so the outline is the transformed local rectangle and
/// stays glued to a rotated entity. Every drag builds one candidate *absolute*
/// transform, previews it by compositing the scene without the entity plus the entity
/// through that very matrix, and commits it as exactly one
/// `PaintDocument.setEntityTransform`, so the preview and the document agree, the
/// frame never inflates over repeated edits and a resize never shears.
final class PaintCanvasView: NSView {

    // MARK: Gesture state

    private enum Gesture {
        case idle
        case freehand
        case shape
        case entity(EntityDrag)
    }

    /// The eight resize grips, named in the entity's own local frame: the corners and
    /// edge midpoints of its local bounds, drawn wherever its transform puts them.
    private enum SelectionHandle: CaseIterable {
        case bottomLeft, bottom, bottomRight, left, right, topLeft, top, topRight
    }

    /// What a drag with the Select tool is doing to the selected entity. Every case
    /// only builds `candidateTransform`, an absolute replacement matrix; the document
    /// is mutated once, on mouse up.
    ///
    /// Each case carries `base`, the entity transform read at mouse down, so every
    /// update re-derives the candidate from that one starting frame instead of
    /// accumulating a matrix per mouse event.
    private enum EntityDrag {
        case move(grab: CGPoint, base: CGAffineTransform)
        /// `localOrigin` is the rectangle the grip edits in the entity's *own*
        /// coordinates, which is what keeps a resize square to a rotated frame.
        case resize(handle: SelectionHandle, localOrigin: CGRect, base: CGAffineTransform)
        case rotate(center: CGPoint, grabAngle: CGFloat, base: CGAffineTransform)
    }

    /// The selected entity: its identity, the tight bounds of its own untransformed
    /// geometry, the absolute matrix that places that geometry in the document, and
    /// the revision both were read at. Any edit the selection did not make bumps the
    /// revision, which is the cue to re-read the frame from the entity or to let the
    /// selection go when the entity is no longer there.
    ///
    /// Local bounds plus a matrix, rather than a world-space box, is the whole point:
    /// the box around a rotated entity is bigger than the entity, so re-reading it
    /// after every commit is what inflates the frame and shears the next resize.
    private struct Selection {
        var id: UUID
        var localBounds: CGRect
        var transform: CGAffineTransform
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
    /// The absolute transform the manipulation in flight would commit, `nil` at rest,
    /// so the preview and the commit are literally the same matrix.
    private var candidateTransform: CGAffineTransform?
    /// Everything except the selected entity, rendered once per revision so a drag
    /// re-composites only the entity under the pointer.
    private var sceneImage: CGImage?
    private var sceneImageRevision = -1
    private var sceneImageEntity: UUID?
    /// True while the closed-hand cursor is pushed for a move drag.
    private var pushedMoveCursor = false
    /// The identity the selection callback last handed out, so a report is emitted
    /// once per real transition rather than once per assignment: re-reading the same
    /// entity's committed transform after a drag is not a selection change.
    private var reportedSelection: UUID?
    /// True only while `apply` runs, which is inside a SwiftUI view update. A report
    /// raised there publishes SwiftUI state, which an update may not do, so it is
    /// handed over on the next pass of the run loop instead.
    private var isApplyingState = false

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
    /// Reports the selected entity, or `nil` whenever nothing is selected.
    var onSelectionChange: ((UUID?) -> Void)?

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
        isApplyingState = true
        defer { isApplyingState = false }

        if newDocument !== document {
            cancelGesture()
            clearSelection()
            invalidateSceneImage()
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
            // Grips and the rotation control are view-space sized, so their cursor
            // rects move with the magnification even though the selection did not.
            window?.invalidateCursorRects(for: self)
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
                    self.refreshSelectionAfterExternalEdit()
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

        drawDocument(in: context)
        drawShapePreview(in: context)
        drawSelectionChrome(in: context)

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.stroke(canvasRect.insetBy(dx: 0.5, dy: 0.5))
    }

    /// With nothing selected the document's own composite is a single image. With a
    /// selection the scene is drawn without the selected entity and the entity is
    /// drawn above it through the candidate absolute transform, so what is on screen
    /// during a drag is exactly what `setEntityTransform` commits on mouse up.
    private func drawDocument(in context: CGContext) {
        guard let selection else {
            draw(image: document.cgImage, in: context)
            return
        }

        draw(image: sceneImage(excluding: selection.id), in: context)

        context.saveGState()
        context.clip(to: canvasRect)
        context.scaleBy(x: zoom, y: zoom)
        document.drawEntity(
            selection.id,
            in: context,
            using: candidateTransform ?? selection.transform
        )
        context.restoreGState()
    }

    private func draw(image: CGImage?, in context: CGContext) {
        guard let image else { return }
        context.saveGState()
        context.interpolationQuality = zoom >= 1 ? .none : .high
        context.draw(image, in: canvasRect)
        context.restoreGState()
    }

    /// The scene without the selected entity, rebuilt only when the document
    /// revision or the selected entity changes.
    private func sceneImage(excluding id: UUID) -> CGImage? {
        if let sceneImage, sceneImageRevision == document.revision, sceneImageEntity == id {
            return sceneImage
        }
        let image = document.renderedImage(excludingEntity: id)
        sceneImage = image
        sceneImageRevision = document.revision
        sceneImageEntity = id
        return image
    }

    private func invalidateSceneImage() {
        sceneImage = nil
        sceneImageRevision = -1
        sceneImageEntity = nil
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

    /// Controls are measured in view points, so the grips and the rotation control
    /// stay the same size on screen at every magnification.
    private static let handleSide: CGFloat = 8
    private static let handleHitSlop: CGFloat = 5
    /// How far past the transformed top-right corner the rotation control sits, along
    /// the frame's own outward centre-to-corner direction.
    private static let rotationControlOffset: CGFloat = 17
    private static let rotationControlRadius: CGFloat = 9
    private static let minimumSelectionSide: CGFloat = 2
    private static let rotationSnap: CGFloat = .pi / 12
    /// Pointer reach when picking an entity or a grip, in view points.
    private static let pickSlop: CGFloat = 4

    /// The frame every piece of chrome is built from: the entity's own local bounds
    /// plus the matrix in force, which is the candidate in flight or the resting
    /// transform. Nothing here is ever an axis-aligned world box.
    private var selectionFrame: (localBounds: CGRect, transform: CGAffineTransform)? {
        guard let selection else { return nil }
        return (selection.localBounds, candidateTransform ?? selection.transform)
    }

    private func viewPoint(for point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom, y: point.y * zoom)
    }

    /// A local-space point taken all the way to view space: through the frame's matrix
    /// into the document, then through the zoom.
    private func viewPoint(_ local: CGPoint, through transform: CGAffineTransform) -> CGPoint {
        viewPoint(for: local.applying(transform))
    }

    /// Where a grip sits in the entity's own coordinates: a corner or an edge midpoint
    /// of the local bounds. The frame's matrix decides where that lands on screen.
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

    /// The grip's screen box: an axis-aligned square of fixed view-space size centred
    /// on the transformed grip point, so the grips ride the rotated frame while
    /// staying the same size on screen at every magnification.
    private func handleViewRect(
        _ handle: SelectionHandle,
        in rect: CGRect,
        through transform: CGAffineTransform
    ) -> CGRect {
        let point = viewPoint(handlePoint(handle, in: rect), through: transform)
        return CGRect(
            x: point.x - Self.handleSide / 2,
            y: point.y - Self.handleSide / 2,
            width: Self.handleSide,
            height: Self.handleSide
        )
    }

    /// The selection outline: the local bounds pushed through the frame's matrix and
    /// then the zoom, so it is the transformed quadrilateral itself rather than the box
    /// around it. That is what keeps the frame snug on a rotated entity instead of
    /// growing on every edit.
    private func selectionOutlinePath(
        for rect: CGRect,
        through transform: CGAffineTransform
    ) -> CGPath {
        var total = transform.concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
        return CGPath(rect: rect, transform: &total)
    }

    /// The corner the rotation control hangs off: the frame's local top-right, in view
    /// space, wherever the matrix has put it.
    private func rotationAnchorViewPoint(
        for rect: CGRect,
        through transform: CGAffineTransform
    ) -> CGPoint {
        viewPoint(CGPoint(x: rect.maxX, y: rect.maxY), through: transform)
    }

    /// The rotation control sits just beyond that corner, along the outward direction
    /// from the frame's centre through it, so it follows the entity's own orientation.
    /// It is pulled back inside the canvas when the selection is flush with an edge so
    /// it stays reachable.
    private func rotationControlViewPoint(
        for rect: CGRect,
        through transform: CGAffineTransform
    ) -> CGPoint {
        let corner = rotationAnchorViewPoint(for: rect, through: transform)
        let centre = viewPoint(CGPoint(x: rect.midX, y: rect.midY), through: transform)
        let dx = corner.x - centre.x
        let dy = corner.y - centre.y
        // A collapsed frame has no outward direction; the plain diagonal is the honest
        // fallback there.
        let direction = dx == 0 && dy == 0 ? CGFloat.pi / 4 : atan2(dy, dx)
        let reach = Self.rotationControlOffset
        let inset = Self.rotationControlRadius + 1
        return CGPoint(
            x: clamp(corner.x + reach * cos(direction), inset, canvasRect.maxX - inset),
            y: clamp(corner.y + reach * sin(direction), inset, canvasRect.maxY - inset)
        )
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }

    // MARK: Selection chrome

    /// Outline, resize grips and the rotation control, every one of them built from
    /// the oriented frame. The grips are drawn at rest only: during a drag the outline
    /// alone tracks the candidate.
    private func drawSelectionChrome(in context: CGContext) {
        guard tool == .select, let frame = selectionFrame else { return }
        let (local, transform) = frame

        drawMarchingAnts(
            around: selectionOutlinePath(for: local, through: transform),
            in: context
        )

        drawRotationControl(
            from: rotationAnchorViewPoint(for: local, through: transform),
            at: rotationControlViewPoint(for: local, through: transform),
            in: context
        )

        guard case .idle = gesture else { return }
        drawHandles(for: local, through: transform, in: context)
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

    private func drawHandles(
        for rect: CGRect,
        through transform: CGAffineTransform,
        in context: CGContext
    ) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        for handle in SelectionHandle.allCases {
            let box = handleViewRect(handle, in: rect, through: transform)
            context.fill(box)
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }
        context.restoreGState()
    }

    /// The rotation affordance: a stem out of the corner ending in a white disc that
    /// carries a circular arrow, so the control says "rotate" on sight.
    private func drawRotationControl(from corner: CGPoint, at center: CGPoint, in context: CGContext) {
        let radius = Self.rotationControlRadius

        context.saveGState()
        context.setShouldAntialias(true)
        context.setLineCap(.round)

        context.move(to: corner)
        context.addLine(to: center)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2.5)
        context.strokePath()
        context.move(to: corner)
        context.addLine(to: center)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        context.strokePath()

        let disc = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: disc)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: disc.insetBy(dx: 0.5, dy: 0.5))

        // The circular arrow itself: an arc that stops short of a full turn, with a
        // solid head seated on its leading end and pointing along the turn.
        let arcRadius = max(1.5, radius - 3.4)
        let start: CGFloat = -0.85
        let head: CGFloat = 3.9
        context.setLineWidth(1.3)
        context.beginPath()
        context.addArc(
            center: center,
            radius: arcRadius,
            startAngle: start,
            endAngle: head - 0.5,
            clockwise: false
        )
        context.strokePath()

        let seat = CGPoint(
            x: center.x + arcRadius * cos(head),
            y: center.y + arcRadius * sin(head)
        )
        let along = head + .pi / 2
        let apex: CGFloat = 2.6
        let spread: CGFloat = 2.1
        context.beginPath()
        context.move(to: CGPoint(
            x: seat.x + apex * cos(along),
            y: seat.y + apex * sin(along)
        ))
        context.addLine(to: CGPoint(
            x: seat.x + spread * cos(head),
            y: seat.y + spread * sin(head)
        ))
        context.addLine(to: CGPoint(
            x: seat.x - spread * cos(head),
            y: seat.y - spread * sin(head)
        ))
        context.closePath()
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
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
        case .entity(let drag):
            updateEntityDrag(drag, at: point)
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
        case .entity(let drag):
            updateEntityDrag(drag, at: point)
            commitEntityDrag()
        case .idle:
            break
        }

        gesture = .idle
        needsDisplay = true
    }

    /// Drops any in-flight gesture without committing pixels. A selection transform
    /// only ever lived in the candidate, so dropping it restores the resting frame.
    private func cancelGesture() {
        switch gesture {
        case .freehand:
            document.cancelStroke()
        case .entity:
            candidateTransform = nil
            releaseMoveCursor()
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

    /// Select-tool mouse down. The rotation control, a resize grip and the body of
    /// the current selection come first, then the topmost entity under the pointer.
    /// Empty canvas deselects; nothing here ever starts an area marquee.
    private func beginSelectionGesture(at point: CGPoint, viewPoint: CGPoint) {
        if let current = selection {
            let local = current.localBounds
            let base = current.transform
            if hitsRotationControl(viewPoint, for: local, through: base) {
                let centre = CGPoint(x: local.midX, y: local.midY).applying(base)
                begin(.rotate(
                    center: centre,
                    grabAngle: angle(from: centre, to: point),
                    base: base
                ))
                return
            }
            if let handle = handle(at: viewPoint, for: local, through: base) {
                begin(.resize(handle: handle, localOrigin: local, base: base))
                return
            }
            // The body is the ink, not a box around it: asking the model keeps a drag
            // on a rotated entity honest, where the frame's bounding box would both
            // grab empty canvas beside it and still lose the parts poking out.
            if document.entityHitTest(current.id, at: point, tolerance: pickTolerance) {
                begin(.move(grab: point, base: base))
                return
            }
        }

        guard let id = document.entityID(at: point, tolerance: pickTolerance) else {
            clearSelection()
            return
        }
        guard select(id), let base = selection?.transform else { return }
        begin(.move(grab: point, base: base))
    }

    private func begin(_ drag: EntityDrag) {
        candidateTransform = nil
        gesture = .entity(drag)
        if case .move = drag, !pushedMoveCursor {
            NSCursor.closedHand.push()
            pushedMoveCursor = true
        }
        needsDisplay = true
    }

    /// Makes `id` the selection, reading the tight bounds of its own untransformed
    /// geometry together with the matrix that places them. An entity that draws
    /// nothing cannot be selected.
    @discardableResult
    private func select(_ id: UUID) -> Bool {
        guard
            let localBounds = document.entityLocalBounds(id),
            let transform = document.entityTransform(id)
        else {
            clearSelection()
            return false
        }
        if selection?.id != id {
            invalidateSceneImage()
        }
        selection = Selection(
            id: id,
            localBounds: localBounds,
            transform: transform,
            revision: document.revision
        )
        candidateTransform = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        reportSelection()
        return true
    }

    /// Every entity drag is preview only: nothing here touches the document. Each case
    /// builds the whole absolute matrix the commit will store, always from the frame
    /// the gesture started at, so dragging back to where it began restores the
    /// original exactly instead of leaving accumulated rounding behind.
    private func updateEntityDrag(_ drag: EntityDrag, at point: CGPoint) {
        switch drag {
        case let .move(grab, base):
            // Translation and rotation are world-space gestures, so they compose
            // after everything the entity already carries.
            candidateTransform = base.concatenating(
                PaintEntity.moveTransform(dx: point.x - grab.x, dy: point.y - grab.y)
            )
        case let .resize(handle, localOrigin, base):
            candidateTransform = resizeTransform(
                handle: handle,
                localOrigin: localOrigin,
                base: base,
                to: point
            )
        case let .rotate(centre, grabAngle, base):
            var rotation = angle(from: centre, to: point) - grabAngle
            if shiftHeld {
                rotation = (rotation / Self.rotationSnap).rounded() * Self.rotationSnap
            }
            candidateTransform = base.concatenating(
                PaintEntity.rotationTransform(by: rotation, around: centre)
            )
        }
        needsDisplay = true
    }

    /// Mouse up: the candidate becomes exactly one document transform, the scene
    /// behind the entity is rebuilt and the committed matrix is read back under the
    /// same local bounds. The geometry never changed — only the matrix — so the frame
    /// that was on screen a moment ago is the frame that stays, which is what keeps a
    /// rotate-resize-rotate run stable instead of inflating it step by step.
    private func commitEntityDrag() {
        let candidate = candidateTransform
        candidateTransform = nil
        releaseMoveCursor()
        needsDisplay = true

        guard let current = selection, let candidate else { return }
        guard PaintEntity.isInvertible(candidate), candidate != current.transform else {
            return
        }

        document.setEntityTransform(current.id, to: candidate)
        invalidateSceneImage()

        guard let committed = document.entityTransform(current.id) else {
            clearSelection()
            return
        }
        selection = Selection(
            id: current.id,
            localBounds: current.localBounds,
            transform: committed,
            revision: document.revision
        )
        window?.invalidateCursorRects(for: self)
    }

    private func clearSelection() {
        releaseMoveCursor()
        candidateTransform = nil
        guard selection != nil else { return }
        selection = nil
        invalidateSceneImage()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        reportSelection()
    }

    /// Hands the selected identity to `onSelectionChange`, once per transition.
    ///
    /// A report raised from `apply` is deferred, because the observer publishes
    /// SwiftUI state and a view update may not. The deferred pass re-reads the
    /// selection instead of replaying a captured identity, so a late delivery still
    /// describes the selection as it actually stands.
    private func reportSelection() {
        guard !isApplyingState else {
            DispatchQueue.main.async { [weak self] in self?.deliverSelection() }
            return
        }
        deliverSelection()
    }

    private func deliverSelection() {
        let id = selection?.id
        guard id != reportedSelection else { return }
        reportedSelection = id
        onSelectionChange?(id)
    }

    /// Any edit the selection did not make — undo, redo, a canvas resize, a recolor
    /// driven from the colour wells — bumps the revision under the selection, so the
    /// frame is re-read from the entity itself: its own local bounds and its own
    /// matrix, which is what an external transform change has to be picked up from
    /// and what a repaint leaves untouched. Re-reading the entity's *local* frame is
    /// safe where re-measuring a world box would inflate it.
    ///
    /// Only an entity that is gone, or one that no longer draws anything, drops the
    /// selection: `select` fails exactly then. Selectability cannot change under an
    /// identity — an entity's tool and geometry are fixed at creation and a recolor
    /// keeps both — so an entity the pick let through stays pickable.
    private func refreshSelectionAfterExternalEdit() {
        guard let current = selection, current.revision != document.revision else { return }
        if case .entity = gesture {
            cancelGesture()
        }
        select(current.id)
    }

    /// Delete and Backspace remove the selected entity in one undoable step and
    /// leave nothing selected.
    @discardableResult
    private func deleteSelectedEntity() -> Bool {
        guard let current = selection else { return false }
        if case .entity = gesture {
            cancelGesture()
        }
        document.deleteEntity(current.id)
        clearSelection()
        return true
    }

    /// The closed hand is pushed for the duration of a move drag, because cursor
    /// rects are not consulted while the mouse is down.
    private func releaseMoveCursor() {
        guard pushedMoveCursor else { return }
        pushedMoveCursor = false
        NSCursor.pop()
    }

    // MARK: Selection hit testing

    /// Pointer reach in document space, so picking an entity stays a constant
    /// distance on screen at every magnification.
    private var pickTolerance: CGFloat { max(0.5, Self.pickSlop / zoom) }

    private func hitsRotationControl(
        _ viewPoint: CGPoint,
        for rect: CGRect,
        through transform: CGAffineTransform
    ) -> Bool {
        let center = rotationControlViewPoint(for: rect, through: transform)
        let reach = Self.rotationControlRadius + Self.handleHitSlop
        return hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= reach
    }

    /// The grip nearest the pointer within the grip's own reach, measured in view
    /// points against the *transformed* grip positions, so the targets ride the
    /// rotated frame and stay the same size at every zoom.
    private func handle(
        at viewPoint: CGPoint,
        for rect: CGRect,
        through transform: CGAffineTransform
    ) -> SelectionHandle? {
        let reach = Self.handleSide / 2 + Self.handleHitSlop
        var best: (handle: SelectionHandle, distance: CGFloat)?
        for candidate in SelectionHandle.allCases {
            let point = self.viewPoint(handlePoint(candidate, in: rect), through: transform)
            let dx = abs(viewPoint.x - point.x)
            let dy = abs(viewPoint.y - point.y)
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

    // MARK: Selection resize

    /// A grip drag, resolved entirely in the entity's own coordinates.
    ///
    /// The pointer is clamped to the canvas, mapped back through the frame the drag
    /// started at, and only then allowed to move the local edges the grip owns. The
    /// resulting local rectangle map is composed *before* the entity transform, so the
    /// scaling runs along the entity's own axes: a rotated shape grows along its own
    /// width and height, its local axes stay orthogonal, and no number of
    /// resize-and-rotate cycles can shear it.
    private func resizeTransform(
        handle: SelectionHandle,
        localOrigin: CGRect,
        base: CGAffineTransform,
        to point: CGPoint
    ) -> CGAffineTransform {
        guard PaintEntity.isInvertible(base) else { return base }
        let local = clampedToCanvas(point).applying(base.inverted())
        guard local.x.isFinite, local.y.isFinite else { return base }

        let target = resizedLocalRect(localOrigin, handle: handle, to: local, under: base)
        let map = PaintEntity.mapTransform(from: localOrigin, to: target)
        guard PaintEntity.isInvertible(map) else { return base }
        return map.concatenating(base)
    }

    /// Only the local edges the grip owns move, and they never cross to within the
    /// minimum extent of the opposite edge, so the local map stays invertible.
    ///
    /// The floor is `minimumSelectionSide` document points divided back through the
    /// frame's own scale, so a shrunken entity is still allowed to be small while a
    /// magnified one cannot be squashed below a couple of visible points.
    private func resizedLocalRect(
        _ rect: CGRect,
        handle: SelectionHandle,
        to point: CGPoint,
        under transform: CGAffineTransform
    ) -> CGRect {
        let minimum = minimumLocalSide(under: transform)

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .bottomLeft, .left, .topLeft:
            minX = min(point.x, maxX - minimum)
        case .bottomRight, .right, .topRight:
            maxX = max(point.x, minX + minimum)
        case .bottom, .top:
            break
        }

        switch handle {
        case .bottomLeft, .bottom, .bottomRight:
            minY = min(point.y, maxY - minimum)
        case .topLeft, .top, .topRight:
            maxY = max(point.y, minY + minimum)
        case .left, .right:
            break
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `minimumSelectionSide` document points expressed in local units, through the
    /// frame's area scale.
    private func minimumLocalSide(under transform: CGAffineTransform) -> CGFloat {
        let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        guard scale.isFinite, scale > 0 else { return Self.minimumSelectionSide }
        return Self.minimumSelectionSide / scale
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            cancelOperation(nil)
            return
        }
        if Self.deleteKeyCodes.contains(event.keyCode), deleteSelectedEntity() {
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

    /// Every tool keeps its own icon artwork, Select included: its glyph is a hand,
    /// so the canvas already reads as a hand tool. Over the selected entity the
    /// system open hand takes over, and a move drag pushes the closed hand.
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: Self.cursor(for: tool))

        guard tool == .select, let frame = selectionFrame else { return }
        let (local, transform) = frame

        // Cursor rects are axis-aligned, so the body rect can only be the box around
        // the oriented outline; every gesture decision uses the outline itself.
        addSelectionCursorRect(
            selectionOutlinePath(for: local, through: transform).boundingBoxOfPath,
            cursor: .openHand
        )
        for handle in SelectionHandle.allCases {
            guard let cursor = Self.cursor(for: handle, through: transform) else { continue }
            addSelectionCursorRect(
                handleViewRect(handle, in: local, through: transform),
                cursor: cursor
            )
        }

        let control = rotationControlViewPoint(for: local, through: transform)
        let radius = Self.rotationControlRadius
        addSelectionCursorRect(
            CGRect(
                x: control.x - radius,
                y: control.y - radius,
                width: radius * 2,
                height: radius * 2
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
    /// cursors are not public API, so the corners keep the Select tool's own artwork,
    /// and an edge grip claims a direction only while the entity's own axis still
    /// points that way. A rotated frame drags along a rotated axis, so it falls back
    /// to the tool cursor rather than promising a resize the drag will not perform.
    private static func cursor(
        for handle: SelectionHandle,
        through transform: CGAffineTransform
    ) -> NSCursor? {
        // The grip moves along the local axis it owns, which is that axis' image
        // under the frame's matrix.
        let axis: CGPoint
        switch handle {
        case .left, .right:
            axis = CGPoint(x: transform.a, y: transform.b)
        case .top, .bottom:
            axis = CGPoint(x: transform.c, y: transform.d)
        case .bottomLeft, .bottomRight, .topLeft, .topRight:
            return nil
        }
        let horizontal = abs(axis.x)
        let vertical = abs(axis.y)
        guard horizontal.isFinite, vertical.isFinite, horizontal + vertical > 0 else {
            return nil
        }
        if vertical <= horizontal * axisCursorTolerance { return .resizeLeftRight }
        if horizontal <= vertical * axisCursorTolerance { return .resizeUpDown }
        return nil
    }

    /// How far off an axis an edge grip may sit and still borrow the axis-aligned
    /// resize cursor: a shade under three degrees.
    private static let axisCursorTolerance: CGFloat = 0.05

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
    /// The canvas talks to the session rather than to loose bindings, because a
    /// sampled or chosen Color 1 is not a plain state write: it goes through
    /// `PaintSession.setPrimaryColor`, which also repaints the selected entity.
    @ObservedObject var session: PaintSession
    @ObservedObject var document: PaintDocument

    func makeNSView(context: Context) -> PaintCanvasView {
        let view = PaintCanvasView(document: document)
        install(on: view)
        return view
    }

    func updateNSView(_ view: PaintCanvasView, context: Context) {
        install(on: view)
        view.apply(
            document: document,
            tool: session.tool,
            primaryColor: NSColor(session.primaryColor),
            secondaryColor: NSColor(session.secondaryColor),
            zoom: CGFloat(session.zoom)
        )
    }

    private func install(on view: PaintCanvasView) {
        let session = self.session

        view.onCursorChange = { point in
            if session.cursorPosition != point {
                session.cursorPosition = point
            }
        }

        view.onPickColor = { sampled, isSecondary in
            let picked = Color(nsColor: sampled)
            if isSecondary {
                session.secondaryColor = picked
            } else {
                session.setPrimaryColor(picked)
            }
        }

        view.onSelectTool = { selected in
            if session.tool != selected {
                session.tool = selected
            }
        }

        view.onSelectionChange = { id in
            if session.selectedEntityID != id {
                session.selectedEntityID = id
            }
        }
    }
}
