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

    // MARK: Configuration

    private(set) var document: PaintDocument

    private var tool: PaintTool = .pencil
    private var primaryColor: NSColor = .black
    private var secondaryColor: NSColor = .white
    private var lineWidth: CGFloat = 1
    private var zoom: CGFloat = 1

    /// Reports the pointer position in document space, or `nil` once the pointer leaves.
    var onCursorChange: ((CGPoint?) -> Void)?
    /// Reports a sampled color; the flag is `true` when the right button sampled it.
    var onPickColor: ((NSColor, Bool) -> Void)?
    /// Requests a tool change from a bare-key shortcut handled by this view.
    var onSelectTool: ((PaintTool) -> Void)?
    /// Requests a brush size nudge (in points) from the `[` and `]` shortcuts.
    var onBrushSizeDelta: ((Double) -> Void)?

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
        lineWidth newLineWidth: CGFloat,
        zoom newZoom: CGFloat
    ) {
        if newDocument !== document {
            cancelGesture()
            document = newDocument
            observeRevision()
        }

        if newTool != tool {
            cancelGesture()
            tool = newTool
            window?.invalidateCursorRects(for: self)
        }

        primaryColor = newPrimary
        secondaryColor = newSecondary
        lineWidth = max(1, newLineWidth)

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
        context.setLineWidth(max(1, lineWidth))
        context.setLineJoin(.miter)
        context.setLineCap(tool == .line ? .round : .square)
        context.addPath(path)
        context.strokePath()
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
        case .pencil, .brush, .eraser:
            gesture = .freehand
            lastPoint = point
            document.beginStroke()
            document.drawStroke(
                from: point,
                to: point,
                tool: tool,
                color: color,
                secondaryColor: alternate,
                lineWidth: lineWidth
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
                secondaryColor: alternate,
                lineWidth: lineWidth
            )
            lastPoint = point
        case .shape:
            shapeEnd = point
            needsDisplay = true
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
                    secondaryColor: alternate,
                    lineWidth: lineWidth
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
                lineWidth: lineWidth,
                constrained: shiftHeld
            )
        case .idle:
            break
        }

        gesture = .idle
        needsDisplay = true
    }

    /// Drops any in-flight gesture without committing pixels.
    private func cancelGesture() {
        switch gesture {
        case .freehand:
            document.cancelStroke()
        case .shape, .idle:
            break
        }
        gesture = .idle
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        cancelGesture()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            cancelGesture()
            return
        }
        if handleCanvasShortcut(event) { return }
        super.keyDown(with: event)
    }

    private static let escapeKeyCode: UInt16 = 53

    /// Modifiers that always belong to menus, text editing or system gestures.
    private static let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]

    /// Bare-key tool and brush size shortcuts, deliberately scoped to `keyDown` on the
    /// focused canvas. Registering them as application key equivalents would swallow
    /// plain letters typed into the text-insert and resize fields.
    private func handleCanvasShortcut(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, window.firstResponder === self else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: Self.reservedModifiers) else { return false }

        guard let typed = event.charactersIgnoringModifiers, typed.count == 1,
              let character = typed.lowercased().first
        else { return false }

        switch character {
        case "[", "{":
            onBrushSizeDelta?(-1)
            return true
        case "]", "}":
            onBrushSizeDelta?(1)
            return true
        default:
            guard let selected = PaintTool.allCases.first(where: { candidate in
                guard let shortcut = candidate.shortcut else { return false }
                return shortcut == character
            }) else { return false }
            onSelectTool?(selected)
            return true
        }
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

        document.addText(text, at: point, color: color, fontSize: max(9, lineWidth * 6))
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
    }

    private static func cursor(for tool: PaintTool) -> NSCursor {
        switch tool {
        case .text:
            return .iBeam
        case .fill, .eyedropper:
            return .pointingHand
        default:
            return .crosshair
        }
    }
}

// MARK: - SwiftUI bridge

struct PaintCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var document: PaintDocument
    @Binding var tool: PaintTool
    @Binding var primaryColor: Color
    @Binding var secondaryColor: Color
    @Binding var brushSize: Double
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
            lineWidth: CGFloat(brushSize),
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

        let brushBinding = $brushSize
        view.onBrushSizeDelta = { delta in
            let range = PaintSession.brushSizeRange
            let next = min(max(brushBinding.wrappedValue + delta, range.lowerBound), range.upperBound)
            if brushBinding.wrappedValue != next {
                brushBinding.wrappedValue = next
            }
        }
    }
}
