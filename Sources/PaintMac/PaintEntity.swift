import AppKit
import CoreGraphics
import Foundation

/// One independently selectable thing on the canvas.
///
/// Everything the toolbox commits after the background bitmap is an entity: a
/// freehand stroke, a shape dragged out of `PaintShapeGeometry`, or a run of
/// text. Entities are value types so `PaintDocument` history is a plain array
/// copy, and their geometry is stored in document coordinates (y up) exactly as
/// the user drew it. Editing never rewrites that geometry; it only replaces
/// `transform`, so a shape resized and rotated a dozen times is still the same
/// original path drawn through a single matrix.
///
/// Rendering, bounds and hit testing all funnel through one local `Geometry`
/// description and one composed matrix, which is why the selection outline, the
/// live drag preview and the committed pixels cannot disagree.
struct PaintEntity: Identifiable {
    /// What the entity actually is. `points` is the drag path in document
    /// coordinates; `from`/`to` is the already Shift-constrained drag rectangle
    /// of a shape; text carries the lower-left origin it was placed at.
    enum Content {
        case stroke(tool: PaintTool, points: [CGPoint], color: NSColor)
        case shape(tool: PaintTool, from: CGPoint, to: CGPoint, color: NSColor)
        case text(value: String, origin: CGPoint, color: NSColor, fontSize: CGFloat)
    }

    /// Stable across every edit, so selection survives transforms and undo.
    let id: UUID
    var content: Content
    /// Accumulated world-space edit matrix, applied to the stored geometry.
    var transform: CGAffineTransform

    init(id: UUID = UUID(), content: Content, transform: CGAffineTransform = .identity) {
        self.id = id
        self.content = content
        self.transform = transform
    }

    // MARK: - Authoring

    /// Extends a freehand stroke by one point. No-op for shapes and text.
    ///
    /// The payload is handed an empty array before the append so the enum stops
    /// referencing the point buffer: `points` is then uniquely referenced and
    /// grows in place instead of copying the whole stroke on every mouse move.
    mutating func appendStrokePoint(_ point: CGPoint) {
        guard case let .stroke(tool, points, color) = content else { return }
        var mutablePoints = points
        content = .stroke(tool: tool, points: [], color: color)
        mutablePoints.append(point)
        content = .stroke(tool: tool, points: mutablePoints, color: color)
    }

    /// Composes `additional` on top of the edits already applied.
    mutating func applyWorldTransform(_ additional: CGAffineTransform) {
        transform = transform.concatenating(additional)
    }

    /// Eraser strokes paint the background colour rather than adding content, so
    /// they are deliberately not selectable; everything else is.
    var isSelectable: Bool {
        switch content {
        case let .stroke(tool, _, _):
            return tool != .eraser
        case .shape, .text:
            return true
        }
    }

    var color: NSColor {
        switch content {
        case let .stroke(_, _, color): return color
        case let .shape(_, _, _, color): return color
        case let .text(_, _, color, _): return color
        }
    }

    // MARK: - Rendering

    /// Draws the entity into `context` with its own transform followed by
    /// `additional` (the live drag preview matrix; `.identity` when committed).
    func draw(in context: CGContext, applying additional: CGAffineTransform = .identity) {
        draw(in: context, using: transform.concatenating(additional))
    }

    /// Draws the entity into `context` under exactly `absolute`, ignoring the
    /// transform the entity currently stores.
    ///
    /// This is the preview half of a replacement edit: the caller has already
    /// built the entire matrix it intends to commit, so composing anything on
    /// top of it here would show the user a different result than the one that
    /// eventually lands.
    func draw(in context: CGContext, using absolute: CGAffineTransform) {
        let geometry = self.geometry
        if case .empty = geometry { return }

        context.saveGState()
        context.setShouldAntialias(true)
        context.concatenate(absolute)

        let paint = PaintEntity.cgColor(color)
        switch geometry {
        case let .stroked(path, lineWidth, cap, join, _):
            context.setStrokeColor(paint)
            context.setLineWidth(lineWidth)
            context.setLineCap(cap)
            context.setLineJoin(join)
            context.beginPath()
            context.addPath(path)
            context.strokePath()
        case let .dab(rect, round):
            context.setFillColor(paint)
            if round {
                context.fillEllipse(in: rect)
            } else {
                context.fill(rect)
            }
        case .text:
            drawText(in: context)
        case .empty:
            break
        }

        context.restoreGState()
    }

    /// Text goes through AppKit so the committed pixels match what the text tool
    /// previewed; the CTM already carries both transforms.
    private func drawText(in context: CGContext) {
        guard case let .text(value, origin, color, fontSize) = content, !value.isEmpty else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphicsContext
        graphicsContext.shouldAntialias = true
        PaintEntity.attributedText(value, color: color, fontSize: fontSize).draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Bounds

    /// Tight bounding box of the ink in the entity's *own* untransformed
    /// coordinates, independent of `transform`. `.null` when it draws nothing.
    ///
    /// This is the rectangle an oriented selection frame is built from: kept in
    /// local space, the frame's corners can be pushed through the entity matrix
    /// and stay glued to the entity's own axes. Re-measuring a world-space box
    /// instead is what makes a rotated frame slacken and inflate.
    var localBounds: CGRect {
        inkBounds(under: .identity)
    }

    /// Tight world-space bounding box of the ink the entity actually deposits,
    /// with its own transform followed by `additional`. `.null` when it draws
    /// nothing.
    func bounds(applying additional: CGAffineTransform = .identity) -> CGRect {
        inkBounds(under: transform.concatenating(additional))
    }

    /// Tight bounding box of the ink under exactly `absolute`, ignoring the
    /// transform the entity currently stores — the measurement that matches
    /// what `draw(in:using:)` puts on screen for the same matrix.
    func bounds(using absolute: CGAffineTransform) -> CGRect {
        inkBounds(under: absolute)
    }

    /// The one measurement every bounds accessor funnels through.
    ///
    /// The ink outline is built in local space *first* and only then
    /// transformed, which is exactly the order the renderer works in: the CTM
    /// distorts the stroke, so caps and mitre spikes scale with the shape.
    /// Boxing the outline rather than padding a rectangle is what keeps a
    /// rotated selection frame snug instead of growing on every rotation.
    ///
    /// An identity matrix — the local measurement, taken on every frame of a
    /// resize — short-circuits both the path copy and, for a dab, the path
    /// itself, so the common case allocates nothing beyond the stroke outline.
    private func inkBounds(under total: CGAffineTransform) -> CGRect {
        var total = total
        let localOutline: CGPath
        switch geometry {
        case let .stroked(path, lineWidth, cap, join, _):
            localOutline = path.copy(
                strokingWithWidth: max(lineWidth, PaintEntity.minimumHitWidth),
                lineCap: cap,
                lineJoin: join,
                miterLimit: PaintEntity.miterLimit
            )
        case let .dab(rect, round):
            // An untransformed dab already *is* its own tightest box.
            if total.isIdentity { return PaintEntity.usableBox(rect) }
            localOutline =
                round
                ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
        case let .text(rect):
            // A rectangle's transformed corner hull is already the tightest
            // axis-aligned box, so text needs no outline pass.
            return PaintEntity.usableBox(rect.applying(total).standardized)
        case .empty:
            return .null
        }
        if total.isIdentity { return PaintEntity.usableBox(localOutline.boundingBoxOfPath) }
        guard let mapped = localOutline.copy(using: &total) else { return .null }
        return PaintEntity.usableBox(mapped.boundingBoxOfPath)
    }

    /// Rejects the degenerate boxes no caller can frame, hit or draw.
    private static func usableBox(_ box: CGRect) -> CGRect {
        box.isNull || box.isInfinite || box.isEmpty ? .null : box
    }

    // MARK: - Hit testing

    /// True when `point` (world space) lands on the entity within `tolerance`
    /// world-space slack.
    ///
    /// The point is mapped back through the composed matrix instead of the ink
    /// being rasterized, so this stays exact under rotation and non-uniform
    /// scale and costs no pixels.
    func hitTest(
        _ point: CGPoint,
        tolerance: CGFloat,
        applying additional: CGAffineTransform = .identity
    ) -> Bool {
        let total = transform.concatenating(additional)
        let determinant = total.a * total.d - total.b * total.c
        guard abs(determinant) > PaintEntity.degenerateDeterminant else { return false }

        let local = point.applying(total.inverted())
        // One matrix maps a world circle to a local ellipse; the geometric mean
        // of the scales is the honest single-number slack for that ellipse.
        let slack = max(tolerance, 0) / sqrt(abs(determinant))

        switch geometry {
        case let .stroked(path, lineWidth, cap, join, closed):
            if closed, path.contains(local, using: .winding) { return true }
            let width = max(lineWidth + slack * 2, PaintEntity.minimumHitWidth)
            let outline = path.copy(
                strokingWithWidth: width,
                lineCap: cap,
                lineJoin: join,
                miterLimit: PaintEntity.miterLimit
            )
            return outline.contains(local, using: .winding)
        case let .dab(rect, round):
            let padded = rect.insetBy(dx: -slack, dy: -slack)
            guard padded.contains(local) else { return false }
            guard round else { return true }
            let rx = padded.width / 2
            let ry = padded.height / 2
            guard rx > 0, ry > 0 else { return false }
            let nx = (local.x - padded.midX) / rx
            let ny = (local.y - padded.midY) / ry
            return nx * nx + ny * ny <= 1
        case let .text(rect):
            return rect.insetBy(dx: -slack, dy: -slack).contains(local)
        case .empty:
            return false
        }
    }

    // MARK: - Shared world-space edits

    /// Straight drag of the selection.
    static func moveTransform(dx: CGFloat, dy: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: dx, y: dy)
    }

    /// The matrix that maps `source` onto `destination`, which is what a handle
    /// drag means: the old selection rectangle becomes the new one. Degenerate
    /// source rectangles have no such matrix, so they resolve to no edit.
    static func mapTransform(from source: CGRect, to destination: CGRect) -> CGAffineTransform {
        let source = source.standardized
        let destination = destination.standardized
        guard
            source.width > minimumMappableExtent,
            source.height > minimumMappableExtent,
            !destination.isNull,
            !destination.isInfinite
        else { return .identity }

        return CGAffineTransform(translationX: destination.minX, y: destination.minY)
            .scaledBy(x: destination.width / source.width, y: destination.height / source.height)
            .translatedBy(x: -source.minX, y: -source.minY)
    }

    /// Rotation by `angle` radians about a world-space pivot.
    static func rotationTransform(by angle: CGFloat, around center: CGPoint) -> CGAffineTransform {
        guard angle.isFinite, angle != 0 else { return .identity }
        return CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
    }

    /// True for a matrix that would change nothing if applied.
    static func isIdentity(_ transform: CGAffineTransform) -> Bool {
        transform.isIdentity
    }

    /// False for matrices that collapse or blow up the geometry, which must be
    /// rejected rather than baked into an entity.
    static func isInvertible(_ transform: CGAffineTransform) -> Bool {
        guard
            transform.a.isFinite, transform.b.isFinite, transform.c.isFinite,
            transform.d.isFinite, transform.tx.isFinite, transform.ty.isFinite
        else { return false }
        return abs(transform.a * transform.d - transform.b * transform.c) > degenerateDeterminant
    }

    // MARK: - Local geometry

    /// The entity reduced to one drawable, measurable, hit-testable description
    /// in its own untransformed coordinates.
    private enum Geometry {
        case stroked(path: CGPath, lineWidth: CGFloat, cap: CGLineCap, join: CGLineJoin, closed: Bool)
        /// A single click of a freehand tool: one dab, no path to stroke.
        case dab(rect: CGRect, round: Bool)
        case text(rect: CGRect)
        case empty
    }

    private var geometry: Geometry {
        switch content {
        case let .stroke(tool, points, _):
            let cap = PaintEntity.strokeCap(for: tool)
            let width = tool.strokeWidth
            guard let first = points.first else { return .empty }
            guard points.count > 1 else {
                return .dab(
                    rect: CGRect(
                        x: first.x - width / 2,
                        y: first.y - width / 2,
                        width: width,
                        height: width
                    ),
                    round: cap == .round
                )
            }
            let path = CGMutablePath()
            path.addLines(between: points)
            return .stroked(path: path, lineWidth: width, cap: cap, join: .round, closed: false)
        case let .shape(tool, from, to, _):
            // The stored endpoints are already constrained, so re-applying the
            // Shift rule here would double-snap an edited shape.
            guard
                let path = PaintShapeGeometry.path(
                    tool: tool,
                    from: from,
                    to: to,
                    constrained: false
                )
            else { return .empty }
            return .stroked(
                path: path,
                lineWidth: tool.strokeWidth,
                cap: tool == .line ? .round : .square,
                join: .miter,
                closed: PaintEntity.isClosedShape(tool)
            )
        case let .text(value, origin, _, fontSize):
            guard !value.isEmpty else { return .empty }
            let size = PaintEntity.attributedText(value, color: .black, fontSize: fontSize).size()
            guard size.width > 0, size.height > 0 else { return .empty }
            return .text(rect: CGRect(origin: origin, size: size))
        }
    }

    /// Matches `PaintDocument`'s freehand caps: the marker tools round their
    /// ends, the eraser stays square so it clears full pixels.
    private static func strokeCap(for tool: PaintTool) -> CGLineCap {
        tool == .eraser ? .square : .round
    }

    /// Line and curve stay open; every other shape in the catalog encloses an
    /// area, and clicking that area selects it.
    private static func isClosedShape(_ tool: PaintTool) -> Bool {
        switch tool {
        case .line, .curve:
            return false
        default:
            return tool.isShape
        }
    }

    private static func attributedText(
        _ value: String,
        color: NSColor,
        fontSize: CGFloat
    ) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.systemFont(ofSize: max(1, fontSize)),
                .foregroundColor: color,
            ]
        )
    }

    private static func cgColor(_ color: NSColor) -> CGColor {
        (color.usingColorSpace(.sRGB) ?? color).cgColor
    }

    /// Below this the matrix has no usable inverse and the entity has no area.
    private static let degenerateDeterminant: CGFloat = 1e-12
    /// Smallest source extent that still defines a resize mapping.
    private static let minimumMappableExtent: CGFloat = 1e-6
    /// Hairline strokes still need a clickable band.
    private static let minimumHitWidth: CGFloat = 0.01
    /// Core Graphics' own default, so hit testing and bounds see the same
    /// mitre spikes the renderer draws.
    private static let miterLimit: CGFloat = 10
}
