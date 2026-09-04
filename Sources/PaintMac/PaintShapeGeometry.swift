import CoreGraphics
import Foundation

/// The single source of truth for every shape the toolbox can draw.
///
/// Both the committed pixels (`PaintDocument.addShape`) and the live canvas
/// preview build their geometry here, so what is previewed is exactly what is
/// stroked. Paths are expressed in document coordinates, whose y axis points up.
///
/// Most shapes are described once as normalized points in the unit square
/// (`0...1` on both axes, y up) and mapped into the standardized drag rectangle
/// with a single affine transform, which makes every drag direction work without
/// per-shape special cases.
enum PaintShapeGeometry {
    /// Applies the Shift-key constraint for `tool`.
    ///
    /// Lines snap to 45° increments, curves stay freely proportioned, and every
    /// other bounded shape is squared off. Non-shape tools pass through.
    static func constrainedEnd(tool: PaintTool, from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        switch tool {
        case .line:
            let length = hypot(dx, dy)
            guard length > 0 else { return to }
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: from.x + cos(angle) * length, y: from.y + sin(angle) * length)
        case .curve:
            return to
        case .pencil, .brush, .thickBrush, .eraser, .fill, .eyedropper, .text:
            return to
        case .rectangle, .roundedRectangle, .ellipse, .triangle, .rightTriangle,
            .diamond, .pentagon, .hexagon, .rightArrow, .leftArrow, .upArrow,
            .downArrow, .fourPointStar, .fivePointStar, .sixPointStar,
            .rectangularCallout, .roundedCallout, .ovalCallout, .heart, .lightning:
            let side = max(abs(dx), abs(dy))
            let sx: CGFloat = dx < 0 ? -1 : 1
            let sy: CGFloat = dy < 0 ? -1 : 1
            return CGPoint(x: from.x + side * sx, y: from.y + side * sy)
        }
    }

    /// The outline for `tool` dragged from `from` to `to`, in document coordinates.
    ///
    /// Returns `nil` for non-shape tools and for bounded shapes whose drag has not
    /// yet covered a meaningful area. Line and curve stay open; every other shape
    /// is closed.
    static func path(tool: PaintTool, from: CGPoint, to: CGPoint, constrained: Bool) -> CGPath? {
        guard tool.isShape else { return nil }
        let end = constrained ? constrainedEnd(tool: tool, from: from, to: to) : to

        switch tool {
        case .line:
            let path = CGMutablePath()
            path.move(to: from)
            path.addLine(to: end)
            return path
        case .curve:
            return curvePath(from: from, to: end)
        default:
            break
        }

        let rect = standardRect(from: from, to: end)
        guard rect.width >= minimumExtent || rect.height >= minimumExtent else { return nil }
        return boundedPath(tool: tool, in: rect)
    }

    // MARK: - Open shapes

    /// A deterministic single cubic bowed to the left of the drag direction, so
    /// dragging the same two points always yields the same curve.
    private static func curvePath(from: CGPoint, to: CGPoint) -> CGPath? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length >= minimumExtent else { return nil }

        let bow = length * 0.22
        let normalX = -dy / length * bow
        let normalY = dx / length * bow
        let path = CGMutablePath()
        path.move(to: from)
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x + dx / 3 + normalX, y: from.y + dy / 3 + normalY),
            control2: CGPoint(x: from.x + dx * 2 / 3 + normalX, y: from.y + dy * 2 / 3 + normalY)
        )
        return path
    }

    // MARK: - Bounded shapes

    private static func boundedPath(tool: PaintTool, in rect: CGRect) -> CGPath? {
        switch tool {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRectangle:
            let radius = min(rect.width, rect.height) * 0.2
            return CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .triangle:
            return closedPolygon(triangleUnit, in: rect)
        case .rightTriangle:
            return closedPolygon(rightTriangleUnit, in: rect)
        case .diamond:
            return closedPolygon(diamondUnit, in: rect)
        case .pentagon:
            return closedPolygon(pentagonUnit, in: rect)
        case .hexagon:
            return closedPolygon(hexagonUnit, in: rect)
        case .rightArrow:
            return closedPolygon(rightArrowUnit, in: rect)
        case .leftArrow:
            return closedPolygon(leftArrowUnit, in: rect)
        case .upArrow:
            return closedPolygon(upArrowUnit, in: rect)
        case .downArrow:
            return closedPolygon(downArrowUnit, in: rect)
        case .fourPointStar:
            return closedPolygon(fourPointStarUnit, in: rect)
        case .fivePointStar:
            return closedPolygon(fivePointStarUnit, in: rect)
        case .sixPointStar:
            return closedPolygon(sixPointStarUnit, in: rect)
        case .lightning:
            return closedPolygon(lightningUnit, in: rect)
        case .rectangularCallout:
            return closedPolygon(rectangularCalloutUnit, in: rect)
        case .roundedCallout:
            return roundedCalloutPath(in: rect)
        case .ovalCallout:
            return ovalCalloutPath(in: rect)
        case .heart:
            return heartPath(in: rect)
        case .line, .curve, .pencil, .brush, .thickBrush, .eraser, .fill, .eyedropper, .text:
            return nil
        }
    }

    /// Rounded speech balloon: body across the top three quarters, tail hanging
    /// below on the left. Built as one subpath so the outline reads as a balloon.
    private static func roundedCalloutPath(in rect: CGRect) -> CGPath {
        let body = calloutBody(in: rect)
        let radius = min(body.width * 0.25, body.height * 0.35)
        let tailStart = body.minX + body.width * 0.30
        let tailEnd = body.minX + body.width * 0.48
        let tailTip = CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: tailStart, y: body.minY))
        path.addLine(to: tailTip)
        path.addLine(to: CGPoint(x: tailEnd, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.minY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.minY),
            radius: radius
        )
        path.closeSubpath()
        return path
    }

    /// Oval balloon: the body ellipse is swept as an arc that stops short of the
    /// lower left, where the tail closes the outline.
    private static func ovalCalloutPath(in rect: CGRect) -> CGPath {
        let body = calloutBody(in: rect)
        let transform = CGAffineTransform(translationX: body.midX, y: body.midY)
            .scaledBy(x: body.width / 2, y: body.height / 2)

        // Leave a gap on the lower left of the ellipse for the tail to bridge.
        let gapStart = CGFloat.pi * 1.39  // where the arc ends, lower left
        let gapEnd = CGFloat.pi * 1.16  // where the arc starts, further left

        let path = CGMutablePath()
        path.addArc(
            center: .zero,
            radius: 1,
            startAngle: gapStart,
            endAngle: gapEnd + 2 * .pi,
            clockwise: false,
            transform: transform
        )
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// Shared balloon body: the top three quarters of the drag rectangle.
    private static func calloutBody(in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: rect.minY + rect.height * 0.25,
            width: rect.width,
            height: rect.height * 0.75
        )
    }

    /// Two mirrored cubics: bottom point, up around the left lobe to the notch,
    /// then around the right lobe back down.
    private static func heartPath(in rect: CGRect) -> CGPath {
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width, y: rect.height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.5, y: 0.02), transform: transform)
        path.addCurve(
            to: CGPoint(x: 0.5, y: 0.74),
            control1: CGPoint(x: -0.28, y: 0.60),
            control2: CGPoint(x: 0.20, y: 1.22),
            transform: transform
        )
        path.addCurve(
            to: CGPoint(x: 0.5, y: 0.02),
            control1: CGPoint(x: 0.80, y: 1.22),
            control2: CGPoint(x: 1.28, y: 0.60),
            transform: transform
        )
        path.closeSubpath()
        return path
    }

    // MARK: - Mapping helpers

    /// Smallest drag extent, in document points, that still produces a shape.
    private static let minimumExtent: CGFloat = 0.01

    private static func standardRect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        )
    }

    /// Maps unit-square points (y up) into `rect` and closes the outline.
    private static func closedPolygon(_ unitPoints: [CGPoint], in rect: CGRect) -> CGPath {
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width, y: rect.height)
        let path = CGMutablePath()
        path.addLines(between: unitPoints, transform: transform)
        path.closeSubpath()
        return path
    }

    // MARK: - Normalized point sets

    private static let triangleUnit: [CGPoint] = [
        CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0),
    ]

    private static let rightTriangleUnit: [CGPoint] = [
        CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0),
    ]

    private static let diamondUnit: [CGPoint] = [
        CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0.5, y: 0), CGPoint(x: 0, y: 0.5),
    ]

    private static let pentagonUnit: [CGPoint] = regularPolygon(sides: 5)

    /// Flat topped and bottomed hexagon with points at the left and right.
    private static let hexagonUnit: [CGPoint] = [
        CGPoint(x: 0.25, y: 1), CGPoint(x: 0.75, y: 1), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0.75, y: 0), CGPoint(x: 0.25, y: 0), CGPoint(x: 0, y: 0.5),
    ]

    private static let rightArrowUnit: [CGPoint] = [
        CGPoint(x: 0, y: 0.7), CGPoint(x: 0.6, y: 0.7), CGPoint(x: 0.6, y: 1),
        CGPoint(x: 1, y: 0.5), CGPoint(x: 0.6, y: 0), CGPoint(x: 0.6, y: 0.3),
        CGPoint(x: 0, y: 0.3),
    ]

    private static let leftArrowUnit: [CGPoint] = [
        CGPoint(x: 1, y: 0.7), CGPoint(x: 0.4, y: 0.7), CGPoint(x: 0.4, y: 1),
        CGPoint(x: 0, y: 0.5), CGPoint(x: 0.4, y: 0), CGPoint(x: 0.4, y: 0.3),
        CGPoint(x: 1, y: 0.3),
    ]

    private static let upArrowUnit: [CGPoint] = [
        CGPoint(x: 0.3, y: 0), CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0, y: 0.4),
        CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 0.4), CGPoint(x: 0.7, y: 0.4),
        CGPoint(x: 0.7, y: 0),
    ]

    private static let downArrowUnit: [CGPoint] = [
        CGPoint(x: 0.3, y: 1), CGPoint(x: 0.3, y: 0.6), CGPoint(x: 0, y: 0.6),
        CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.6), CGPoint(x: 0.7, y: 0.6),
        CGPoint(x: 0.7, y: 1),
    ]

    private static let fourPointStarUnit: [CGPoint] = star(tips: 4, innerRatio: 0.30)
    private static let fivePointStarUnit: [CGPoint] = star(tips: 5, innerRatio: 0.382)
    private static let sixPointStarUnit: [CGPoint] = star(tips: 6, innerRatio: 0.577)

    /// Zigzag bolt: top tip upper middle, jog left, bottom tip lower left, back
    /// up the right side.
    private static let lightningUnit: [CGPoint] = [
        CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.45), CGPoint(x: 0.429, y: 0.45),
        CGPoint(x: 0.214, y: 0), CGPoint(x: 1, y: 0.6), CGPoint(x: 0.571, y: 0.6),
        CGPoint(x: 0.857, y: 1),
    ]

    /// Rectangular balloon: body across the top three quarters, tail below left.
    private static let rectangularCalloutUnit: [CGPoint] = [
        CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0.25),
        CGPoint(x: 0.48, y: 0.25), CGPoint(x: 0.16, y: 0), CGPoint(x: 0.30, y: 0.25),
        CGPoint(x: 0, y: 0.25),
    ]

    // MARK: - Generators

    /// A regular polygon with one vertex pointing up, stretched to fill the unit
    /// square so it always fills the drag rectangle.
    private static func regularPolygon(sides: Int) -> [CGPoint] {
        let step = 2 * CGFloat.pi / CGFloat(sides)
        var points = [CGPoint]()
        points.reserveCapacity(sides)
        for index in 0..<sides {
            let angle = CGFloat.pi / 2 + CGFloat(index) * step
            points.append(CGPoint(x: cos(angle), y: sin(angle)))
        }
        return fitToUnitSquare(points)
    }

    /// A star with `tips` points, one pointing up, `innerRatio` controlling how
    /// deep the notches cut, stretched to fill the unit square.
    private static func star(tips: Int, innerRatio: CGFloat) -> [CGPoint] {
        let step = CGFloat.pi / CGFloat(tips)
        var points = [CGPoint]()
        points.reserveCapacity(tips * 2)
        for index in 0..<(tips * 2) {
            let radius: CGFloat = index % 2 == 0 ? 1 : innerRatio
            let angle = CGFloat.pi / 2 + CGFloat(index) * step
            points.append(CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
        }
        return fitToUnitSquare(points)
    }

    private static func fitToUnitSquare(_ points: [CGPoint]) -> [CGPoint] {
        guard var minX = points.first?.x, var minY = points.first?.y else { return points }
        var maxX = minX
        var maxY = minY
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return points }
        return points.map {
            CGPoint(x: ($0.x - minX) / width, y: ($0.y - minY) / height)
        }
    }
}
