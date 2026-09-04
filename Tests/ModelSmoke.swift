// Framework-free behavioural smoke test for the Paint document model.
//
// This toolchain (Apple CommandLineTools, no Xcode) ships neither XCTest nor
// Swift Testing, so the model is verified by compiling `PaintTypes.swift`,
// `PaintShapeGeometry.swift`, `PaintEntity.swift` and `PaintDocument.swift`
// together with this file into one throwaway executable.
// See `test-model.sh`. Every check asserts observable bitmap, entity, history,
// dirty or file behaviour; the process exits non-zero on the first failed
// expectation.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Failure plumbing

struct SmokeFailure: Error, CustomStringConvertible {
    let scenario: String
    let message: String
    let file: String
    let line: UInt

    var description: String {
        "FAIL [\(scenario)] \(message)  (\(file):\(line))"
    }
}

private typealias Pixel = (r: Double, g: Double, b: Double, a: Double)

/// Default per-channel slack for colour comparisons: one unit of 8-bit
/// precision plus rounding, which is tight enough to catch a wrong colour and
/// loose enough to survive premultiplied round-tripping.
///
/// File scope, not a static member of the `@MainActor` type below: Swift 6
/// evaluates default arguments in a nonisolated context, so an actor-isolated
/// static would be unusable there. An immutable `Double` global is concurrency
/// safe under both language modes.
private let channelSlack = 2.0 / 255.0

/// Per-channel ceiling for "this pixel holds dark ink". A one-pixel-wide dab
/// lands its antialiased centre around 0.29 rather than a flat 0.0, so the
/// ceiling sits above that while still rejecting white (1.0) or any washed-out
/// remnant of an undone stroke by a wide margin.
private let inkChannelCeiling = 0.35

/// Per-channel floor for "this pixel was cleared back to the page". Used to
/// measure the Eraser, whose band is only visible against inked pixels; the
/// floor sits well above any antialiased fringe of the surrounding ink.
private let clearChannelFloor = 0.65

/// Slack, in whole pixels, allowed when comparing a painted cross-section
/// against the tool's declared `strokeWidth`. Antialiasing can shave a row off
/// either edge, so the band is measured proportionally: tight enough that a
/// tool drawing at any other tool's width fails, loose enough that rasterising
/// a correct width never does.
private func paintedWidthSlack(_ expected: Int) -> Int {
    max(1, expected / 8)
}

// MARK: - Tool catalogue expectations

/// Every tool this build must expose, counted literally: eight non-shape tools
/// plus the twenty-two shapes. A tool added or dropped without updating the
/// tables below fails here first.
private let expectedToolCount = 30

/// The shape catalogue this build must expose, in palette order. Spelled out
/// literally rather than derived from `PaintTool`, so dropping, renaming or
/// reordering a shape fails here instead of quietly agreeing with itself.
private let expectedShapeCatalogue: [PaintTool] = [
    .line, .curve, .rectangle, .roundedRectangle, .ellipse,
    .triangle, .rightTriangle, .diamond, .pentagon, .hexagon,
    .rightArrow, .leftArrow, .upArrow, .downArrow,
    .fourPointStar, .fivePointStar, .sixPointStar,
    .rectangularCallout, .roundedCallout, .ovalCallout,
    .heart, .lightning,
]

/// The non-shape tools, in palette order. Select leads the ribbon, exactly as
/// Paint puts its selector before the pencil, and Thick Brush sits between
/// Brush and Eraser: spelled out literally so a dropped or misplaced entry
/// fails here rather than agreeing with whatever the enum happens to say.
private let expectedDrawingTools: [PaintTool] = [
    .select, .pencil, .brush, .thickBrush, .eraser, .fill, .eyedropper, .text,
]

/// The one width every tool draws with, spelled out literally instead of read
/// back from `PaintTool`, so a tool that silently changes thickness fails here
/// rather than agreeing with itself. Width is embodied by the tool: Pencil is a
/// single pixel, Brush is the medium stroke, Thick Brush is the broad marker,
/// Eraser matches Brush exactly, and Text and every shape share one fine
/// outline. Select, Fill and Eyedropper never stroke, so their value is unused.
private let expectedStrokeWidths: [PaintTool: CGFloat] = [
    .select: 1, .pencil: 1, .fill: 1, .eyedropper: 1,
    .brush: 16, .eraser: 16,
    .thickBrush: 64,
    .text: 4,
    .line: 4, .curve: 4, .rectangle: 4, .roundedRectangle: 4, .ellipse: 4,
    .triangle: 4, .rightTriangle: 4, .diamond: 4, .pentagon: 4, .hexagon: 4,
    .rightArrow: 4, .leftArrow: 4, .upArrow: 4, .downArrow: 4,
    .fourPointStar: 4, .fivePointStar: 4, .sixPointStar: 4,
    .rectangularCallout: 4, .roundedCallout: 4, .ovalCallout: 4,
    .heart: 4, .lightning: 4,
]

/// The bare-key shortcuts this build must expose. Every other tool must report
/// `nil` rather than claim a key of its own; Select owns "s".
private let expectedShortcuts: [PaintTool: Character] = [
    .select: "s",
    .pencil: "p", .brush: "b", .eraser: "e", .fill: "f", .eyedropper: "k",
    .text: "t", .line: "l", .rectangle: "r", .ellipse: "o",
]

// MARK: - Path introspection

/// Structural summary of a `CGPath`, collected through `applyWithBlock`.
///
/// Every shape expectation below is phrased against this rather than against
/// the geometry source, so the assertions describe the outline that will
/// actually be stroked and keep holding however the path is constructed.
private struct PathTrace {
    /// On-curve points in path order: the destination of every move, line and
    /// curve segment.
    var vertices: [CGPoint] = []
    /// Every emitted point, Bezier control points included.
    var allPoints: [CGPoint] = []
    var elementCount = 0
    var moveCount = 0
    var lineCount = 0
    var quadCount = 0
    var curveCount = 0
    var closeCount = 0

    var isClosed: Bool { closeCount > 0 }
    var segmentCount: Int { lineCount + quadCount + curveCount }
}

private func trace(_ path: CGPath) -> PathTrace {
    var result = PathTrace()
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        result.elementCount += 1
        switch element.type {
        case .moveToPoint:
            result.moveCount += 1
            result.vertices.append(element.points[0])
            result.allPoints.append(element.points[0])
        case .addLineToPoint:
            result.lineCount += 1
            result.vertices.append(element.points[0])
            result.allPoints.append(element.points[0])
        case .addQuadCurveToPoint:
            result.quadCount += 1
            result.allPoints.append(element.points[0])
            result.vertices.append(element.points[1])
            result.allPoints.append(element.points[1])
        case .addCurveToPoint:
            result.curveCount += 1
            result.allPoints.append(element.points[0])
            result.allPoints.append(element.points[1])
            result.vertices.append(element.points[2])
            result.allPoints.append(element.points[2])
        case .closeSubpath:
            result.closeCount += 1
        @unknown default:
            break
        }
    }
    return result
}

/// Drops repeated points, so a path that returns to its start or emits a
/// zero-length segment still reports its true corner count.
private func distinctPoints(_ points: [CGPoint], epsilon: CGFloat = 0.25) -> [CGPoint] {
    var unique: [CGPoint] = []
    for point in points {
        let duplicate = unique.contains {
            abs($0.x - point.x) <= epsilon && abs($0.y - point.y) <= epsilon
        }
        if !duplicate { unique.append(point) }
    }
    return unique
}

/// Counts the turn directions around a closed polygon. A convex outline turns
/// one way only; a spiky one — arrow, star, bolt — turns both ways.
private func turnDirections(_ points: [CGPoint]) -> (left: Int, right: Int) {
    guard points.count >= 3 else { return (0, 0) }
    var left = 0
    var right = 0
    for index in points.indices {
        let a = points[index]
        let b = points[(index + 1) % points.count]
        let c = points[(index + 2) % points.count]
        let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        if cross > 0.001 {
            left += 1
        } else if cross < -0.001 {
            right += 1
        }
    }
    return (left, right)
}

private func perpendicularDistance(
    _ point: CGPoint,
    from start: CGPoint,
    to end: CGPoint
) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = hypot(dx, dy)
    guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
    return abs(dy * (point.x - start.x) - dx * (point.y - start.y)) / length
}

private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, _ epsilon: CGFloat) -> Bool {
    abs(lhs - rhs) <= epsilon
}

private func nearlyEqual(_ lhs: CGPoint, _ rhs: CGPoint, _ epsilon: CGFloat) -> Bool {
    nearlyEqual(lhs.x, rhs.x, epsilon) && nearlyEqual(lhs.y, rhs.y, epsilon)
}

private func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect, _ epsilon: CGFloat) -> Bool {
    nearlyEqual(lhs.minX, rhs.minX, epsilon)
        && nearlyEqual(lhs.minY, rhs.minY, epsilon)
        && nearlyEqual(lhs.width, rhs.width, epsilon)
        && nearlyEqual(lhs.height, rhs.height, epsilon)
}

// MARK: - Oriented selection frame geometry

/// The quadrilateral an oriented selection frame draws: the four corners of a
/// *local* rectangle pushed through the entity's matrix, in the rectangle's own
/// order — bottom-left, bottom-right, top-right, top-left.
///
/// Every frame expectation below is phrased against this rather than against an
/// axis-aligned box, because an axis-aligned box is precisely what a rotated
/// frame must not degrade into.
private func frameCorners(_ rect: CGRect, _ transform: CGAffineTransform) -> [CGPoint] {
    [
        CGPoint(x: rect.minX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY),
        CGPoint(x: rect.minX, y: rect.maxY),
    ].map { $0.applying(transform) }
}

/// |cos| of the angle between the two frame edges meeting at the first corner:
/// zero while the frame's own axes are still perpendicular, and the direct
/// measure of shear once they are not.
private func frameShear(_ corners: [CGPoint]) -> CGFloat {
    guard corners.count == 4 else { return 1 }
    let ux = corners[1].x - corners[0].x
    let uy = corners[1].y - corners[0].y
    let vx = corners[3].x - corners[0].x
    let vy = corners[3].y - corners[0].y
    let lengths = hypot(ux, uy) * hypot(vx, vy)
    guard lengths > 0 else { return 1 }
    return abs(ux * vx + uy * vy) / lengths
}

/// World length of the frame's local x axis.
private func frameWidth(_ corners: [CGPoint]) -> CGFloat {
    hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
}

/// World length of the frame's local y axis.
private func frameHeight(_ corners: [CGPoint]) -> CGFloat {
    hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
}

/// Direction of the frame's local x axis, in radians.
private func frameAngle(_ corners: [CGPoint]) -> CGFloat {
    atan2(corners[1].y - corners[0].y, corners[1].x - corners[0].x)
}

/// Axis-aligned hull of a frame: what a world-space measurement collapses the
/// frame to, and the yardstick the tightness checks are compared against.
private func frameHull(_ corners: [CGPoint]) -> CGRect {
    guard let first = corners.first else { return .null }
    var minX = first.x
    var maxX = first.x
    var minY = first.y
    var maxY = first.y
    for corner in corners.dropFirst() {
        minX = min(minX, corner.x)
        maxX = max(maxX, corner.x)
        minY = min(minY, corner.y)
        maxY = max(maxY, corner.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

private func frameArea(_ corners: [CGPoint]) -> CGFloat {
    frameWidth(corners) * frameHeight(corners)
}

private func unitVector(from start: CGPoint, to end: CGPoint) -> CGPoint {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = hypot(dx, dy)
    guard length > 0 else { return CGPoint(x: 1, y: 0) }
    return CGPoint(x: dx / length, y: dy / length)
}

private func offsetPoint(_ point: CGPoint, _ direction: CGPoint, _ distance: CGFloat) -> CGPoint {
    CGPoint(x: point.x + direction.x * distance, y: point.y + direction.y * distance)
}

private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
    CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
}

/// Which local edges a handle drag moves: a corner names one horizontal and one
/// vertical edge, an edge handle names exactly one.
private struct FrameEdges {
    var left = false
    var right = false
    var bottom = false
    var top = false
}

/// The resize an oriented selector performs, spelled out here exactly as the
/// model's contract states it: the world pointer is mapped back through the
/// entity's current matrix, the named local edges move to it, and the resulting
/// local rectangle map composes *before* that matrix.
///
/// Stated this way the resize can only ever scale along the entity's own axes,
/// which is what `orientedLocalResize` verifies — and what the world-hull
/// pipeline below cannot do.
private func localResizeTransform(
    _ localBounds: CGRect,
    under transform: CGAffineTransform,
    pointer: CGPoint,
    edges: FrameEdges
) -> CGAffineTransform {
    let local = pointer.applying(transform.inverted())
    var minX = localBounds.minX
    var maxX = localBounds.maxX
    var minY = localBounds.minY
    var maxY = localBounds.maxY
    if edges.left { minX = local.x }
    if edges.right { maxX = local.x }
    if edges.bottom { minY = local.y }
    if edges.top { maxY = local.y }
    let edited = CGRect(
        x: min(minX, maxX),
        y: min(minY, maxY),
        width: abs(maxX - minX),
        height: abs(maxY - minY)
    )
    return PaintEntity.mapTransform(from: localBounds, to: edited).concatenating(transform)
}

/// The resize the pre-fix selector performed, kept as a control: measure the
/// entity's *world* hull, stretch that hull axis-aligned, and compose the map
/// after the entity's matrix. On anything rotated this is a shear, and repeated
/// use feeds the hull's own slack back into the geometry.
private func worldHullResizeTransform(
    _ worldHull: CGRect,
    under transform: CGAffineTransform,
    to destination: CGRect
) -> CGAffineTransform {
    transform.concatenating(PaintEntity.mapTransform(from: worldHull, to: destination))
}

@MainActor
final class ModelSmokeRun {
    private var scenario = "<none>"
    private var checks = 0

    // MARK: Entry

    func run() throws {
        try scenario("initial document") { try initialDocument() }
        try scenario("brush stroke checkpoint") { try brushStrokeCheckpoint() }
        try scenario("thick brush stroke") { try thickBrushStroke() }
        try scenario("embodied stroke widths") { try embodiedStrokeWidths() }
        try scenario("cancelled stroke") { try cancelledStroke() }
        try scenario("no-op fill") { try noOpFill() }
        try scenario("bounded flood fill") { try boundedFloodFill() }
        try scenario("colour pick") { try colourPick() }
        try scenario("tool catalogue") { try shapeCatalogue() }
        try scenario("shape geometry") { try shapeGeometry() }
        try scenario("shape shift constraints") { try shapeConstraints() }
        try scenario("shape silhouettes") { try shapeSilhouettes() }
        try scenario("shape rendering and history") { try shapeRendering() }
        try scenario("entity creation and z-order") { try entityCreation() }
        try scenario("entity hit testing") { try entityHitTesting() }
        try scenario("shared entity transforms") { try sharedEntityTransforms() }
        try scenario("entity move") { try entityMove() }
        try scenario("entity resize") { try entityResize() }
        try scenario("entity rotation") { try entityRotation() }
        try scenario("entity local frame") { try entityLocalFrame() }
        try scenario("oriented frame under rotation") { try orientedFrameUnderRotation() }
        try scenario("oriented local resize") { try orientedLocalResize() }
        try scenario("rotate resize cycles") { try rotateResizeCycles() }
        try scenario("absolute transform replacement") { try absoluteTransformReplacement() }
        try scenario("entity preview matches commit") { try entityPreviewMatchesCommit() }
        try scenario("entity delete") { try entityDelete() }
        try scenario("entity no-ops") { try entityNoOps() }
        try scenario("entity flattening") { try entityFlattening() }
        try scenario("entities in files") { try entitiesInFiles() }
        try scenario("resize and undo across dimensions") { try resizeAcrossDimensions() }
        try scenario("png save and reopen") { try pngSaveAndReopen() }
        try scenario("oriented image import") { try orientedImageImport() }
        try scenario("new document reset") { try newDocumentReset() }
    }

    var checkCount: Int { checks }

    private func scenario(_ name: String, _ body: () throws -> Void) throws {
        scenario = name
        try body()
    }

    // MARK: Expectations

    private func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        checks += 1
        guard condition else {
            throw SmokeFailure(scenario: scenario, message: message(), file: file, line: line)
        }
    }

    private func expectEqual(
        _ actual: Int,
        _ expected: Int,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        try expect(
            actual == expected,
            "\(label): expected \(expected), got \(actual)",
            file: file,
            line: line
        )
    }

    private func expectSize(
        _ document: PaintDocument,
        _ width: Int,
        _ height: Int,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        try expect(
            document.pixelWidth == width && document.pixelHeight == height,
            "bitmap is \(document.pixelWidth)×\(document.pixelHeight), expected \(width)×\(height)",
            file: file,
            line: line
        )
        try expect(
            document.canvasSize == CGSize(width: width, height: height),
            "canvasSize is \(document.canvasSize), expected \(width)×\(height)",
            file: file,
            line: line
        )
    }

    private func expectFlags(
        _ document: PaintDocument,
        undo: Bool,
        redo: Bool,
        dirty: Bool,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        try expect(
            document.canUndo == undo,
            "canUndo is \(document.canUndo), expected \(undo)",
            file: file,
            line: line
        )
        try expect(
            document.canRedo == redo,
            "canRedo is \(document.canRedo), expected \(redo)",
            file: file,
            line: line
        )
        try expect(
            document.isDirty == dirty,
            "isDirty is \(document.isDirty), expected \(dirty)",
            file: file,
            line: line
        )
    }

    // MARK: Pixel helpers

    /// Reads the pixel through the eyedropper entry point, which is the model's
    /// only public pixel accessor, sampling the centre of the pixel.
    private func pixel(
        _ document: PaintDocument,
        _ x: Int,
        _ y: Int,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> Pixel {
        let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
        guard let picked = document.color(at: point),
              let srgb = picked.usingColorSpace(.sRGB)
        else {
            throw SmokeFailure(
                scenario: scenario,
                message: "no colour readable at pixel (\(x), \(y))",
                file: file,
                line: line
            )
        }
        return (
            Double(srgb.redComponent),
            Double(srgb.greenComponent),
            Double(srgb.blueComponent),
            Double(srgb.alphaComponent)
        )
    }

    private func expectPixel(
        _ document: PaintDocument,
        _ x: Int,
        _ y: Int,
        _ expected: NSColor,
        _ label: String,
        slack: Double = channelSlack,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let actual = try pixel(document, x, y, file: file, line: line)
        guard let want = expected.usingColorSpace(.sRGB) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "expected colour has no sRGB representation",
                file: file,
                line: line
            )
        }
        let close = abs(actual.r - Double(want.redComponent)) <= slack
            && abs(actual.g - Double(want.greenComponent)) <= slack
            && abs(actual.b - Double(want.blueComponent)) <= slack
            && abs(actual.a - Double(want.alphaComponent)) <= slack
        try expect(
            close,
            "\(label) at (\(x), \(y)): got \(format(actual)), expected "
                + "(\(fixed(Double(want.redComponent))), \(fixed(Double(want.greenComponent))), "
                + "\(fixed(Double(want.blueComponent))), \(fixed(Double(want.alphaComponent))))",
            file: file,
            line: line
        )
    }

    /// Ink checks use a channel ceiling instead of an exact colour so a
    /// legitimately anti-aliased edge cannot make the suite flaky, while a
    /// missing or erased stroke still fails.
    private func expectInk(
        _ document: PaintDocument,
        _ x: Int,
        _ y: Int,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let actual = try pixel(document, x, y, file: file, line: line)
        try expect(
            actual.r <= inkChannelCeiling
                && actual.g <= inkChannelCeiling
                && actual.b <= inkChannelCeiling
                && actual.a >= 0.99,
            "\(label) at (\(x), \(y)) is not dark ink: \(format(actual))",
            file: file,
            line: line
        )
    }

    /// True when the pixel holds fully opaque dark ink, by the same standard
    /// `expectInk` applies.
    private func isInk(_ document: PaintDocument, _ x: Int, _ y: Int) throws -> Bool {
        let sample = try pixel(document, x, y)
        return sample.r <= inkChannelCeiling
            && sample.g <= inkChannelCeiling
            && sample.b <= inkChannelCeiling
            && sample.a >= 0.99
    }

    /// Longest run of consecutive fully inked pixels down column `x`. Measures
    /// the painted cross-section of a horizontal stroke, so a tool that renders
    /// thinner than promised reports a smaller number instead of merely missing
    /// one sampled pixel.
    private func verticalInkRun(_ document: PaintDocument, column x: Int) throws -> Int {
        var longest = 0
        var current = 0
        for y in 0..<document.pixelHeight {
            if try isInk(document, x, y) {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    /// Longest run of consecutive cleared pixels down column `x`. The Eraser
    /// paints the page colour, so its band is measured against an inked canvas
    /// exactly as the ink tools are measured against a blank one.
    private func verticalClearRun(_ document: PaintDocument, column x: Int) throws -> Int {
        var longest = 0
        var current = 0
        for y in 0..<document.pixelHeight {
            let sample = try pixel(document, x, y)
            if sample.r >= clearChannelFloor
                && sample.g >= clearChannelFloor
                && sample.b >= clearChannelFloor {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    /// Asserts a measured cross-section matches the width the tool embodies.
    /// Phrased against `tool.strokeWidth` and the literal table together, so
    /// neither a wrong constant nor a renderer ignoring it can pass.
    private func expectPaintedWidth(
        _ measured: Int,
        _ tool: PaintTool,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let declared = Int(tool.strokeWidth)
        try expect(
            declared == Int(expectedStrokeWidths[tool] ?? -1),
            "\(tool.rawValue) strokeWidth is \(tool.strokeWidth), expected "
                + "\(describe(expectedStrokeWidths[tool]))",
            file: file,
            line: line
        )
        try expect(
            abs(measured - declared) <= paintedWidthSlack(declared),
            "\(label): \(tool.rawValue) painted a \(measured)px cross-section, expected "
                + "about \(declared)px — the width it embodies "
                + "(±\(paintedWidthSlack(declared))px)",
            file: file,
            line: line
        )
    }

    private func fixed(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func format(_ pixel: Pixel) -> String {
        "(\(fixed(pixel.r)), \(fixed(pixel.g)), \(fixed(pixel.b)), \(fixed(pixel.a)))"
    }

    // MARK: Drawing helpers

    private func dab(
        _ document: PaintDocument,
        at point: CGPoint,
        tool: PaintTool = .pencil,
        color: NSColor = .black
    ) {
        document.beginStroke()
        document.drawStroke(
            from: point,
            to: point,
            tool: tool,
            color: color,
            secondaryColor: .white
        )
        document.endStroke()
    }

    /// One transaction of three horizontal drag segments centred on `centerY`,
    /// wide enough that column `sampleColumn` lands in the middle of the band
    /// rather than under an end cap. `centerY` sits on a pixel boundary so an
    /// even-width band covers whole rows.
    private func horizontalDrag(
        _ document: PaintDocument,
        tool: PaintTool,
        centerY: Double,
        color: NSColor = .black,
        secondaryColor: NSColor = .white
    ) {
        document.beginStroke()
        for step in 0..<3 {
            let x = 60.0 + Double(step) * 12.0
            document.drawStroke(
                from: CGPoint(x: x, y: centerY),
                to: CGPoint(x: x + 12, y: centerY),
                tool: tool,
                color: color,
                secondaryColor: secondaryColor
            )
        }
        document.endStroke()
    }

    /// Column that `horizontalDrag` guarantees is interior to the painted band.
    private let sampleColumn = 78

    // MARK: Scenarios

    private func initialDocument() throws {
        let document = PaintDocument()
        try expectSize(document, 960, 600)
        try expectFlags(document, undo: false, redo: false, dirty: false)
        try expect(document.revision > 0, "revision should be published after init")
        try expect(document.cgImage != nil, "a fresh document must produce an image")
        for point in [(0, 0), (959, 599), (480, 300), (0, 599), (959, 0)] {
            try expectPixel(document, point.0, point.1, .white, "fresh canvas")
        }
    }

    private func brushStrokeCheckpoint() throws {
        let document = PaintDocument(width: 64, height: 64)
        let revisionBefore = document.revision

        // One transaction, many drag segments: history must gain exactly one entry.
        document.beginStroke()
        for step in 0..<5 {
            let x = 8.0 + Double(step) * 4.0
            document.drawStroke(
                from: CGPoint(x: x, y: 32),
                to: CGPoint(x: x + 4, y: 32),
                tool: .brush,
                color: .black,
                secondaryColor: .white
            )
        }
        document.endStroke()

        try expect(document.revision > revisionBefore, "painting must bump revision")
        try expectInk(document, 20, 32, "brush ink")
        try expectPaintedWidth(
            try verticalInkRun(document, column: 20),
            .brush,
            "brush band"
        )
        try expectPixel(document, 2, 2, .white, "untouched pixel")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        document.undo()
        try expectPixel(document, 20, 32, .white, "undone brush ink")
        try expectFlags(document, undo: false, redo: true, dirty: false)

        document.redo()
        try expectInk(document, 20, 32, "redone brush ink")
        try expectFlags(document, undo: true, redo: false, dirty: true)
    }

    /// Thick Brush must be unmistakably thick and behave like Brush otherwise.
    ///
    /// Nothing here requests a width: `drawStroke` takes none, so the band on
    /// the bitmap can only come from the tool. The measured cross-section is
    /// checked against `PaintTool.thickBrush.strokeWidth`, which fails if the
    /// broad marker ever renders at the medium brush's width or vice versa.
    private func thickBrushStroke() throws {
        let document = PaintDocument(width: 200, height: 200)
        let revisionBefore = document.revision
        let thickness = Int(PaintTool.thickBrush.strokeWidth)

        // One transaction, three drag segments along a horizontal line: history
        // must gain exactly one entry, and the painted band must be as tall as
        // the tool itself is.
        horizontalDrag(document, tool: .thickBrush, centerY: 100)

        try expect(document.revision > revisionBefore, "thick brush must bump revision")
        try expectInk(document, sampleColumn, 100, "thick brush core")
        try expectInk(document, sampleColumn, 100 - thickness / 2 + 1, "thick brush band, one edge")
        try expectInk(
            document,
            sampleColumn,
            100 + thickness / 2 - 1,
            "thick brush band, other edge"
        )

        let thickRun = try verticalInkRun(document, column: sampleColumn)
        try expectPaintedWidth(thickRun, .thickBrush, "thick brush band")
        try expectPixel(document, sampleColumn, 4, .white, "canvas above the thick band")
        try expectPixel(document, 4, 100, .white, "canvas beside the thick band")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        // The identical drag through the ordinary brush stays four times
        // narrower: thickness belongs to the tool, not to a shared setting.
        let medium = PaintDocument(width: 200, height: 200)
        horizontalDrag(medium, tool: .brush, centerY: 100)
        let mediumRun = try verticalInkRun(medium, column: sampleColumn)
        try expectPaintedWidth(mediumRun, .brush, "ordinary brush band")
        try expect(
            thickRun > mediumRun * 3,
            "thick brush painted \(thickRun)px against the brush's \(mediumRun)px; "
                + "Thick Brush must be dramatically broader"
        )

        // One checkpoint for the whole drag: a single undo reaches the pristine
        // bitmap, and a single redo brings the full-width band back.
        document.undo()
        try expectPixel(document, sampleColumn, 100, .white, "undone thick brush core")
        try expectEqual(
            try verticalInkRun(document, column: sampleColumn),
            0,
            "solid ink pixels remaining after one undo"
        )
        try expectFlags(document, undo: false, redo: true, dirty: false)

        document.redo()
        try expectInk(document, sampleColumn, 100, "redone thick brush core")
        try expectPaintedWidth(
            try verticalInkRun(document, column: sampleColumn),
            .thickBrush,
            "redone thick brush band"
        )
        try expectFlags(document, undo: true, redo: false, dirty: true)
    }

    /// Every tool that puts marks on the bitmap paints exactly the width it
    /// embodies — 1pt Pencil, 16pt Brush, 64pt Thick Brush, 16pt Eraser and
    /// 4pt shapes — measured off the rendered pixels rather than trusted from
    /// the enum. No entry point accepts a width, so a document that paints the
    /// wrong band has no setting left to blame.
    private func embodiedStrokeWidths() throws {
        // Pencil: a single pixel. Its centre line sits mid-pixel so an
        // odd-width band covers one whole row instead of straddling two.
        let pencil = PaintDocument(width: 200, height: 200)
        horizontalDrag(pencil, tool: .pencil, centerY: 100.5)
        try expectInk(pencil, sampleColumn, 100, "pencil ink")
        try expectPaintedWidth(
            try verticalInkRun(pencil, column: sampleColumn),
            .pencil,
            "pencil band"
        )

        // Brush and Eraser are the same stroke in two colours: the declared
        // widths must be identical, and so must the painted bands.
        try expect(
            PaintTool.brush.strokeWidth == PaintTool.eraser.strokeWidth,
            "eraser strokeWidth is \(PaintTool.eraser.strokeWidth) but brush is "
                + "\(PaintTool.brush.strokeWidth); the Eraser must match the Brush exactly"
        )

        let brush = PaintDocument(width: 200, height: 200)
        horizontalDrag(brush, tool: .brush, centerY: 100)
        let brushRun = try verticalInkRun(brush, column: sampleColumn)
        try expectPaintedWidth(brushRun, .brush, "brush band")

        // The Eraser paints the page colour, so it is measured as a cleared
        // band cut through an inked canvas.
        let eraser = PaintDocument(width: 200, height: 200)
        eraser.floodFill(at: CGPoint(x: 0.5, y: 0.5), color: .black)
        try expectInk(eraser, sampleColumn, 100, "inked canvas before erasing")
        horizontalDrag(eraser, tool: .eraser, centerY: 100)
        let eraserRun = try verticalClearRun(eraser, column: sampleColumn)
        try expectPaintedWidth(eraserRun, .eraser, "eraser band")
        try expectEqual(eraserRun, brushRun, "eraser band against the brush band")

        // Shapes: one fine outline shared by the whole catalogue. Measured on
        // the horizontal edges of a rectangle and on a horizontal line, both
        // sampled away from any corner or cap.
        let rectangle = PaintDocument(width: 200, height: 200)
        rectangle.addShape(
            tool: .rectangle,
            from: CGPoint(x: 20, y: 40),
            to: CGPoint(x: 180, y: 160),
            color: .black,
            constrained: false
        )
        try expectPaintedWidth(
            try verticalInkRun(rectangle, column: 100),
            .rectangle,
            "rectangle edge"
        )

        let line = PaintDocument(width: 200, height: 200)
        line.addShape(
            tool: .line,
            from: CGPoint(x: 20, y: 100),
            to: CGPoint(x: 180, y: 100),
            color: .black,
            constrained: false
        )
        try expectPaintedWidth(try verticalInkRun(line, column: 100), .line, "line shape")
    }

    private func cancelledStroke() throws {
        let document = PaintDocument(width: 32, height: 32)
        dab(document, at: CGPoint(x: 16, y: 16), tool: .brush)
        try expectInk(document, 16, 16, "committed dab")
        try expectFlags(document, undo: true, redo: false, dirty: true)
        let committed = document.selectableEntityIDs
        try expectEqual(committed.count, 1, "entities after the committed dab")

        document.beginStroke()
        document.drawStroke(
            from: CGPoint(x: 4, y: 4),
            to: CGPoint(x: 4, y: 4),
            tool: .brush,
            color: .black,
            secondaryColor: .white
        )
        try expectInk(document, 4, 4, "in-flight ink before cancel")

        // The open drag is already one live entity, sitting on top of what was
        // committed before it.
        let inFlight = document.selectableEntityIDs
        try expectEqual(inFlight.count, 2, "entities during an open stroke")
        try expect(
            Array(inFlight.prefix(1)) == committed,
            "an open stroke must not disturb the entities beneath it"
        )
        try expectEntity(
            document,
            at: CGPoint(x: 4, y: 4),
            tolerance: 1,
            inFlight[1],
            "the in-flight stroke"
        )

        document.cancelStroke()
        try expectPixel(document, 4, 4, .white, "cancelled ink")
        try expectInk(document, 16, 16, "earlier committed dab survives cancel")
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expect(
            document.selectableEntityIDs == committed,
            "cancelStroke must drop the pending entity and keep every other one"
        )
        try expectNoEntity(
            document,
            at: CGPoint(x: 4, y: 4),
            tolerance: 2,
            "the cancelled stroke"
        )

        // A cancelled stroke recorded nothing, so one undo reaches the pristine bitmap.
        document.undo()
        try expectPixel(document, 16, 16, .white, "pristine after single undo")
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expect(
            document.selectableEntityIDs.isEmpty,
            "undoing the dab removes its entity"
        )
    }

    private func noOpFill() throws {
        let document = PaintDocument(width: 16, height: 16)
        let revision = document.revision

        document.floodFill(at: CGPoint(x: 8.5, y: 8.5), color: .white)
        try expectFlags(document, undo: false, redo: false, dirty: false)
        try expectEqual(document.revision, revision, "revision after same-colour fill")

        for offCanvas in [CGPoint(x: -1.5, y: 8.5), CGPoint(x: 8.5, y: 40), CGPoint(x: 16, y: 16)] {
            document.floodFill(at: offCanvas, color: .red)
            try expectFlags(document, undo: false, redo: false, dirty: false)
            try expectEqual(document.revision, revision, "revision after off-canvas fill")
        }
        try expectPixel(document, 8, 8, .white, "canvas untouched by no-op fills")
    }

    private func boundedFloodFill() throws {
        let document = PaintDocument(width: 21, height: 21)

        // Solid one-pixel divider down column 10, splitting the canvas in two.
        // Pencil is the one-pixel tool by construction, so the divider is one
        // pixel wide without anyone asking for it.
        document.beginStroke()
        document.drawStroke(
            from: CGPoint(x: 10.5, y: 0),
            to: CGPoint(x: 10.5, y: 21),
            tool: .pencil,
            color: .black,
            secondaryColor: .white
        )
        document.endStroke()
        try expectInk(document, 10, 0, "divider bottom")
        try expectInk(document, 10, 10, "divider middle")
        try expectInk(document, 10, 20, "divider top")

        document.floodFill(at: CGPoint(x: 2.5, y: 2.5), color: .red)

        try expectPixel(document, 2, 2, .red, "seed pixel")
        try expectPixel(document, 0, 0, .red, "left region corner")
        try expectPixel(document, 0, 20, .red, "left region opposite corner")
        try expectPixel(document, 9, 13, .red, "left region beside divider")
        try expectPixel(document, 11, 13, .white, "right region beside divider")
        try expectPixel(document, 15, 15, .white, "right region interior")
        try expectPixel(document, 20, 0, .white, "right region corner")
        try expectInk(document, 10, 10, "divider survives the fill")

        // The fill is a single checkpoint layered on top of the stroke.
        try expectFlags(document, undo: true, redo: false, dirty: true)
        document.undo()
        try expectPixel(document, 2, 2, .white, "fill undone")
        try expectInk(document, 10, 10, "divider still present after undoing the fill")
        try expectFlags(document, undo: true, redo: true, dirty: true)
    }

    private func colourPick() throws {
        let document = PaintDocument(width: 32, height: 32)
        let ink = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        dab(document, at: CGPoint(x: 16, y: 16), tool: .brush, color: ink)

        guard let picked = document.color(at: CGPoint(x: 16.5, y: 16.5))?
            .usingColorSpace(.sRGB)
        else {
            throw SmokeFailure(
                scenario: scenario,
                message: "eyedropper returned no colour over painted pixels",
                file: #fileID,
                line: #line
            )
        }
        try expect(
            abs(Double(picked.redComponent) - 0.2) <= channelSlack
                && abs(Double(picked.greenComponent) - 0.4) <= channelSlack
                && abs(Double(picked.blueComponent) - 0.6) <= channelSlack
                && abs(Double(picked.alphaComponent) - 1.0) <= channelSlack,
            "picked colour is (\(fixed(Double(picked.redComponent))), "
                + "\(fixed(Double(picked.greenComponent))), "
                + "\(fixed(Double(picked.blueComponent))), "
                + "\(fixed(Double(picked.alphaComponent)))), expected (0.200, 0.400, 0.600, 1.000)"
        )

        try expectPixel(document, 0, 0, .white, "unpainted pixel picks white")
        try expect(
            document.color(at: CGPoint(x: 40, y: 5)) == nil,
            "eyedropper must return nil off canvas"
        )
        try expect(
            document.color(at: CGPoint(x: 5, y: -3)) == nil,
            "eyedropper must return nil for negative coordinates"
        )
    }

    // MARK: Catalogue scenarios

    /// The catalogue itself: exactly the promised tools, in order, classified
    /// correctly, and without disturbing the shortcuts that already shipped.
    private func shapeCatalogue() throws {
        try expectEqual(PaintTool.allCases.count, expectedToolCount, "tool catalogue size")
        try expectEqual(PaintTool.shapeTools.count, 22, "shape catalogue size")
        try expect(
            PaintTool.shapeTools == expectedShapeCatalogue,
            "shapeTools is \(names(PaintTool.shapeTools)), expected \(names(expectedShapeCatalogue))"
        )
        try expectEqual(
            PaintTool.drawingTools.count,
            expectedDrawingTools.count,
            "drawing tool count"
        )
        try expect(
            PaintTool.drawingTools == expectedDrawingTools,
            "drawingTools is \(names(PaintTool.drawingTools)), "
                + "expected \(names(expectedDrawingTools))"
        )
        // Position, not just membership: the selector opens the ribbon and
        // Thick Brush sits between Brush and Eraser, rather than either being
        // appended out of the way.
        try expectEqual(
            PaintTool.drawingTools.firstIndex(of: .select) ?? -1,
            expectedDrawingTools.firstIndex(of: .select) ?? -2,
            "select position in drawingTools"
        )
        try expectEqual(
            PaintTool.drawingTools.firstIndex(of: .select) ?? -1,
            0,
            "select must be the first tool in the ribbon"
        )
        try expect(
            (PaintTool.drawingTools.firstIndex(of: .select) ?? .max)
                < (PaintTool.drawingTools.firstIndex(of: .pencil) ?? -1),
            "select must come before pencil in drawingTools, got "
                + names(PaintTool.drawingTools)
        )
        try expectEqual(
            PaintTool.drawingTools.firstIndex(of: .thickBrush) ?? -1,
            expectedDrawingTools.firstIndex(of: .thickBrush) ?? -2,
            "thickBrush position in drawingTools"
        )
        try expect(
            (PaintTool.drawingTools.firstIndex(of: .brush) ?? .max)
                < (PaintTool.drawingTools.firstIndex(of: .thickBrush) ?? -1)
                && (PaintTool.drawingTools.firstIndex(of: .thickBrush) ?? .max)
                    < (PaintTool.drawingTools.firstIndex(of: .eraser) ?? -1),
            "thickBrush must sit between Brush and Eraser, got "
                + names(PaintTool.drawingTools)
        )
        try expect(
            !PaintTool.thickBrush.isShape,
            "thickBrush must be a freehand tool, not a shape"
        )
        try expect(
            PaintTool.thickBrush.title == "Thick Brush",
            "thickBrush title is \"\(PaintTool.thickBrush.title)\", expected \"Thick Brush\""
        )
        try expect(
            PaintTool.thickBrush.shortcut == nil,
            "thickBrush must carry no bare-key shortcut, got "
                + describe(PaintTool.thickBrush.shortcut)
        )

        // The selector: a hand tool, not a shape and not a marquee.
        try expect(
            !PaintTool.select.isShape,
            "select picks up existing content, it does not drag out a shape: "
                + "isShape must be false"
        )
        try expect(
            PaintTool.select.title == "Select",
            "select title is \"\(PaintTool.select.title)\", expected \"Select\""
        )
        try expect(
            PaintTool.select.symbolName == "hand.point.up.left.fill",
            "select symbol is \"\(PaintTool.select.symbolName)\", expected "
                + "\"hand.point.up.left.fill\" — the tool points at objects rather than "
                + "dragging out an area"
        )
        try expect(
            PaintTool.select.shortcut == "s",
            "select shortcut is \(describe(PaintTool.select.shortcut)), expected \"s\""
        )
        try expect(
            PaintTool.select.strokeWidth == 1,
            "select strokeWidth is \(PaintTool.select.strokeWidth); the selector never strokes, "
                + "so it declares the neutral single pixel"
        )

        // Width is embodied by the tool: every case must declare exactly the
        // width the table above spells out, and the table must cover the enum,
        // so a new tool cannot slip in without a deliberate width.
        try expectEqual(
            expectedStrokeWidths.count,
            PaintTool.allCases.count,
            "tools covered by the stroke-width table"
        )
        for tool in PaintTool.allCases {
            guard let expected = expectedStrokeWidths[tool] else {
                throw SmokeFailure(
                    scenario: scenario,
                    message: "\(tool.rawValue) has no expected stroke width",
                    file: #fileID,
                    line: #line
                )
            }
            try expect(
                tool.strokeWidth == expected,
                "\(tool.rawValue) strokeWidth is \(tool.strokeWidth), expected \(expected)"
            )
            try expect(
                tool.strokeWidth > 0,
                "\(tool.rawValue) strokeWidth is \(tool.strokeWidth); every tool needs a real width"
            )
        }

        // The relationships that make the widths meaningful, stated on their
        // own so a table edited into agreement with a regression still fails.
        try expect(
            PaintTool.eraser.strokeWidth == PaintTool.brush.strokeWidth,
            "eraser strokeWidth is \(PaintTool.eraser.strokeWidth), expected exactly the "
                + "brush's \(PaintTool.brush.strokeWidth)"
        )
        try expect(
            PaintTool.thickBrush.strokeWidth == PaintTool.brush.strokeWidth * 4,
            "thickBrush strokeWidth is \(PaintTool.thickBrush.strokeWidth); the broad marker "
                + "must dwarf the brush's \(PaintTool.brush.strokeWidth)"
        )
        try expect(
            PaintTool.pencil.strokeWidth == 1,
            "pencil strokeWidth is \(PaintTool.pencil.strokeWidth), expected a single pixel"
        )
        for tool in PaintTool.shapeTools {
            try expect(
                tool.strokeWidth == 4,
                "\(tool.rawValue) strokeWidth is \(tool.strokeWidth); every shape outlines at 4pt"
            )
        }

        for tool in PaintTool.shapeTools {
            try expect(tool.isShape, "\(tool.rawValue) is in shapeTools but isShape is false")
        }
        for tool in PaintTool.drawingTools {
            try expect(!tool.isShape, "\(tool.rawValue) is a drawing tool but isShape is true")
        }
        try expect(
            PaintTool.allCases.filter(\.isShape) == PaintTool.shapeTools,
            "isShape disagrees with shapeTools: \(names(PaintTool.allCases.filter(\.isShape)))"
        )

        // The two lists partition the enum: nothing missing, nothing listed twice.
        let partition = PaintTool.drawingTools + PaintTool.shapeTools
        try expectEqual(partition.count, PaintTool.allCases.count, "tools covered by both lists")
        try expectEqual(Set(partition).count, partition.count, "distinct tools across both lists")
        try expect(
            Set(partition) == Set(PaintTool.allCases),
            "drawingTools + shapeTools do not cover every PaintTool case"
        )

        for tool in PaintTool.allCases {
            try expect(
                tool.shortcut == expectedShortcuts[tool],
                "\(tool.rawValue) shortcut is \(describe(tool.shortcut)), "
                    + "expected \(describe(expectedShortcuts[tool]))"
            )
        }
        let assigned = PaintTool.allCases.compactMap(\.shortcut)
        try expectEqual(assigned.count, expectedShortcuts.count, "tools carrying a shortcut")
        try expectEqual(Set(assigned).count, assigned.count, "distinct shortcut characters")

        var titles = Set<String>()
        for tool in PaintTool.allCases {
            try expect(
                !tool.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(tool.rawValue) has no title"
            )
            try expect(titles.insert(tool.title).inserted, "duplicate tool title \"\(tool.title)\"")
            try expect(!tool.symbolName.isEmpty, "\(tool.rawValue) has no symbol name")
        }

        // Only meaningful where SF Symbols resolve at all: a run that cannot
        // load the catalogue skips the check instead of failing on it.
        if NSImage(systemSymbolName: "pencil", accessibilityDescription: nil) != nil {
            for tool in PaintTool.allCases {
                try expect(
                    NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil) != nil,
                    "\(tool.rawValue) symbol \"\(tool.symbolName)\" does not exist on this system"
                )
            }
        }
    }

    /// Every shape produces real, deterministic, in-bounds geometry from any
    /// drag direction — and only shapes produce geometry at all.
    private func shapeGeometry() throws {
        let rect = CGRect(x: 12, y: 10, width: 76, height: 60)
        let drags: [(CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)),
        ]

        for tool in PaintTool.shapeTools {
            var boxes: [CGRect] = []
            for (index, drag) in drags.enumerated() {
                let path = try requirePath(tool, from: drag.0, to: drag.1, label: "drag \(index)")
                try expect(!path.isEmpty, "\(tool.rawValue): drag \(index) produced an empty path")

                let info = trace(path)
                try expect(info.moveCount >= 1, "\(tool.rawValue): drag \(index) never moves")
                try expect(
                    info.segmentCount >= 1,
                    "\(tool.rawValue): drag \(index) has no drawable segments"
                )
                if tool == .line || tool == .curve {
                    try expect(!info.isClosed, "\(tool.rawValue) must stay an open outline")
                } else {
                    try expect(info.isClosed, "\(tool.rawValue) must be a closed outline")
                }

                let box = path.boundingBoxOfPath
                try expect(
                    box.width >= 1 && box.height >= 1,
                    "\(tool.rawValue): drag \(index) collapses to \(box)"
                )
                boxes.append(box)

                // Same drag, same geometry: the preview and the committed pixels
                // are two separate calls and have to agree.
                let repeated = trace(
                    try requirePath(tool, from: drag.0, to: drag.1, label: "repeat \(index)")
                )
                try expect(
                    repeated.vertices.count == info.vertices.count
                        && zip(repeated.vertices, info.vertices)
                            .allSatisfy { nearlyEqual($0.0, $0.1, 0.0001) },
                    "\(tool.rawValue): drag \(index) is not deterministic"
                )
            }

            // The curve deliberately bows away from its chord; everything else
            // has to stay inside the rectangle the user dragged out.
            if tool != .curve {
                let bounds = rect.insetBy(dx: -0.75, dy: -0.75)
                for (index, box) in boxes.enumerated() {
                    try expect(
                        bounds.contains(box),
                        "\(tool.rawValue): drag \(index) escapes the dragged rectangle: "
                            + "\(box) vs \(rect)"
                    )
                }
            }

            // Bounded shapes are laid out on the normalised rectangle, so they
            // fill it and look identical whichever corner the drag started from.
            if tool != .line, tool != .curve {
                for (index, box) in boxes.enumerated() {
                    try expect(
                        box.width >= rect.width * 0.75 && box.height >= rect.height * 0.75,
                        "\(tool.rawValue): drag \(index) only covers \(box.size) of \(rect.size)"
                    )
                    try expect(
                        nearlyEqual(box, boxes[0], 0.5),
                        "\(tool.rawValue): drag \(index) yields \(box) but the forward drag "
                            + "yields \(boxes[0])"
                    )
                }
            }
        }

        // A drag that never moved has no bounded shape to describe.
        let stationary = CGPoint(x: 40, y: 40)
        for tool in PaintTool.shapeTools where tool != .line && tool != .curve {
            try expect(
                PaintShapeGeometry.path(
                    tool: tool,
                    from: stationary,
                    to: stationary,
                    constrained: false
                ) == nil,
                "\(tool.rawValue): a zero-area drag must produce no path"
            )
        }

        // Non-shape tools own no geometry and no constraint behaviour.
        let origin = CGPoint(x: rect.minX, y: rect.minY)
        for tool in PaintTool.drawingTools {
            for constrained in [false, true] {
                try expect(
                    PaintShapeGeometry.path(
                        tool: tool,
                        from: origin,
                        to: stationary,
                        constrained: constrained
                    ) == nil,
                    "\(tool.rawValue) is not a shape but produced a path "
                        + "(constrained: \(constrained))"
                )
            }
            let passthrough = PaintShapeGeometry.constrainedEnd(
                tool: tool,
                from: origin,
                to: stationary
            )
            try expect(
                nearlyEqual(passthrough, stationary, 0.0001),
                "\(tool.rawValue) must pass the drag end through unchanged, got \(passthrough)"
            )
        }
    }

    /// Shift behaviour: 45° snapping for the line, squaring for bounded shapes,
    /// and an explicit exemption for the curve.
    private func shapeConstraints() throws {
        let origin = CGPoint(x: 20, y: 20)
        let quarter = CGFloat.pi / 4

        for target in [
            CGPoint(x: 80, y: 25), CGPoint(x: 25, y: 80), CGPoint(x: -40, y: 22),
            CGPoint(x: 18, y: -30), CGPoint(x: 70, y: 62), CGPoint(x: -25, y: 75),
        ] {
            let snapped = PaintShapeGeometry.constrainedEnd(tool: .line, from: origin, to: target)
            let length = hypot(target.x - origin.x, target.y - origin.y)
            let snappedLength = hypot(snapped.x - origin.x, snapped.y - origin.y)
            try expect(
                abs(snappedLength - length) <= 0.001,
                "line snapping changed the drag length: \(snappedLength) vs \(length)"
            )

            let angle = atan2(snapped.y - origin.y, snapped.x - origin.x)
            let steps = angle / quarter
            try expect(
                abs(steps - steps.rounded()) <= 0.001,
                "line snapped to \(angle * 180 / .pi)°, which is not a multiple of 45°"
            )
            let nearest = (atan2(target.y - origin.y, target.x - origin.x) / quarter).rounded()
                * quarter
            try expect(
                abs(cos(angle) - cos(nearest)) <= 0.001
                    && abs(sin(angle) - sin(nearest)) <= 0.001,
                "line snapped to \(angle * 180 / .pi)° rather than the nearest spoke "
                    + "\(nearest * 180 / .pi)°"
            )
        }

        let free = CGPoint(x: 91, y: 33)
        let curveEnd = PaintShapeGeometry.constrainedEnd(tool: .curve, from: origin, to: free)
        try expect(
            nearlyEqual(curveEnd, free, 0.0001),
            "the curve stays freely proportioned under Shift, got \(curveEnd)"
        )

        for tool in PaintTool.shapeTools where tool != .line && tool != .curve {
            for target in [
                CGPoint(x: 80, y: 40), CGPoint(x: 80, y: -20),
                CGPoint(x: -40, y: 40), CGPoint(x: -30, y: -50),
            ] {
                let end = PaintShapeGeometry.constrainedEnd(tool: tool, from: origin, to: target)
                let dx = end.x - origin.x
                let dy = end.y - origin.y
                try expect(
                    abs(abs(dx) - abs(dy)) <= 0.001,
                    "\(tool.rawValue): Shift produced a \(dx)×\(dy) drag, which is not square"
                )
                try expect(abs(dx) > 0.001, "\(tool.rawValue): Shift collapsed the drag")
                try expect(
                    dx.sign == (target.x - origin.x).sign
                        && dy.sign == (target.y - origin.y).sign,
                    "\(tool.rawValue): Shift flipped the drag direction"
                )

                let box = try requirePath(
                    tool,
                    from: origin,
                    to: target,
                    constrained: true,
                    label: "constrained"
                ).boundingBoxOfPath
                let span = max(box.width, box.height)
                try expect(
                    abs(box.width - box.height) <= span * 0.15,
                    "\(tool.rawValue): the Shift-constrained outline measures \(box.size)"
                )
            }
        }
    }

    /// Shape-by-shape silhouette checks, phrased against the emitted outline so
    /// a shape that has collapsed into its neighbour is caught.
    private func shapeSilhouettes() throws {
        let rect = CGRect(x: 20, y: 15, width: 100, height: 100)
        let from = CGPoint(x: rect.minX, y: rect.minY)
        let to = CGPoint(x: rect.maxX, y: rect.maxY)
        let tolerance = rect.width * 0.02

        // Open shapes.
        let lineInfo = trace(try requirePath(.line, from: from, to: to))
        try expect(!lineInfo.isClosed, "the line must stay open")
        try expect(
            lineInfo.curveCount == 0 && lineInfo.quadCount == 0,
            "the line must be straight"
        )
        try expectEqual(distinctPoints(lineInfo.vertices).count, 2, "line endpoint count")

        let curveInfo = trace(try requirePath(.curve, from: from, to: to))
        try expect(!curveInfo.isClosed, "the curve must stay open")
        try expect(
            curveInfo.curveCount >= 1,
            "the curve must be a cubic Bezier; found \(curveInfo.curveCount) cubic segments"
        )
        guard let curveStart = curveInfo.vertices.first,
              let curveFinish = curveInfo.vertices.last
        else {
            throw SmokeFailure(
                scenario: scenario,
                message: "the curve emitted no points",
                file: #fileID,
                line: #line
            )
        }
        try expect(nearlyEqual(curveStart, from, 0.5), "the curve starts at \(curveStart)")
        try expect(nearlyEqual(curveFinish, to, 0.5), "the curve ends at \(curveFinish)")
        let bow = curveInfo.allPoints
            .map { perpendicularDistance($0, from: from, to: to) }
            .max() ?? 0
        try expect(bow >= 1, "the curve is indistinguishable from a straight line (bow \(bow))")

        // Rounded versus square corners.
        let plainRectangle = trace(try requirePath(.rectangle, from: from, to: to))
        try expect(
            plainRectangle.curveCount == 0 && plainRectangle.quadCount == 0,
            "the rectangle must have square corners"
        )
        let rounded = trace(try requirePath(.roundedRectangle, from: from, to: to))
        try expect(
            rounded.curveCount + rounded.quadCount >= 4,
            "the rounded rectangle needs four rounded corners, found "
                + "\(rounded.curveCount + rounded.quadCount)"
        )
        let ellipse = trace(try requirePath(.ellipse, from: from, to: to))
        try expect(ellipse.lineCount == 0, "the ellipse must have no straight edges")
        try expect(ellipse.curveCount + ellipse.quadCount >= 4, "the ellipse must be curved")

        // Straight-edged polygons: exact corner counts and convex outlines.
        for (tool, corners) in [
            (PaintTool.triangle, 3), (.rightTriangle, 3), (.diamond, 4),
            (.pentagon, 5), (.hexagon, 6),
        ] {
            let info = trace(try requirePath(tool, from: from, to: to))
            try expect(info.isClosed, "\(tool.rawValue) must be closed")
            try expect(
                info.curveCount == 0 && info.quadCount == 0,
                "\(tool.rawValue) must be a straight-edged polygon"
            )
            let vertices = distinctPoints(info.vertices)
            try expectEqual(vertices.count, corners, "\(tool.rawValue) corner count")
            let turns = turnDirections(vertices)
            try expect(
                min(turns.left, turns.right) == 0,
                "\(tool.rawValue) should be convex, but turns \(turns.left) one way "
                    + "and \(turns.right) the other"
            )
        }

        try expectCorners(
            distinctPoints(trace(try requirePath(.triangle, from: from, to: to)).vertices),
            [
                CGPoint(x: rect.midX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
            ],
            tolerance: tolerance,
            "triangle"
        )
        try expectCorners(
            distinctPoints(trace(try requirePath(.diamond, from: from, to: to)).vertices),
            [
                CGPoint(x: rect.midX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.midY),
                CGPoint(x: rect.midX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.midY),
            ],
            tolerance: tolerance,
            "diamond"
        )

        // The right triangle needs one vertical and one horizontal leg.
        let legs = distinctPoints(
            trace(try requirePath(.rightTriangle, from: from, to: to)).vertices
        )
        var vertical = false
        var horizontal = false
        for first in legs.indices {
            for second in legs.indices where second > first {
                if abs(legs[first].x - legs[second].x) <= tolerance { vertical = true }
                if abs(legs[first].y - legs[second].y) <= tolerance { horizontal = true }
            }
        }
        try expect(vertical && horizontal, "rightTriangle has no right angle: \(legs)")

        // Arrows: one corner at the head, a shaft behind it, a notched outline.
        for (tool, tip) in [
            (PaintTool.rightArrow, CGPoint(x: rect.maxX, y: rect.midY)),
            (.leftArrow, CGPoint(x: rect.minX, y: rect.midY)),
            (.upArrow, CGPoint(x: rect.midX, y: rect.maxY)),
            (.downArrow, CGPoint(x: rect.midX, y: rect.minY)),
        ] {
            let info = trace(try requirePath(tool, from: from, to: to))
            try expect(info.isClosed, "\(tool.rawValue) must be closed")
            let vertices = distinctPoints(info.vertices)
            try expect(
                vertices.count >= 7,
                "\(tool.rawValue) has \(vertices.count) corners; an arrow needs at least 7"
            )
            let head = vertices.filter { hypot($0.x - tip.x, $0.y - tip.y) <= rect.width * 0.12 }
            try expectEqual(head.count, 1, "\(tool.rawValue) corners at the head \(tip)")
            let turns = turnDirections(vertices)
            try expect(
                turns.left > 0 && turns.right > 0,
                "\(tool.rawValue) is convex; an arrow notches where the head meets the shaft"
            )
        }

        // Stars: alternating long and short spokes.
        for (tool, corners) in [
            (PaintTool.fourPointStar, 8), (.fivePointStar, 10), (.sixPointStar, 12),
        ] {
            let info = trace(try requirePath(tool, from: from, to: to))
            try expect(info.isClosed, "\(tool.rawValue) must be closed")
            let vertices = distinctPoints(info.vertices)
            try expectEqual(vertices.count, corners, "\(tool.rawValue) corner count")

            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radii = vertices.map { hypot($0.x - centre.x, $0.y - centre.y) }
            let outer = radii.max() ?? 0
            let inner = radii.min() ?? 0
            try expect(
                inner > 0 && outer >= inner * 1.4,
                "\(tool.rawValue) has no spikes: longest spoke \(outer), shortest \(inner)"
            )
            let turns = turnDirections(vertices)
            try expect(
                turns.left > 0 && turns.right > 0,
                "\(tool.rawValue) is convex; a star alternates in and out"
            )
        }

        // Callouts: the plain body plus a tail, measured against the plain body.
        for (callout, body) in [
            (PaintTool.rectangularCallout, PaintTool.rectangle),
            (.roundedCallout, .roundedRectangle),
            (.ovalCallout, .ellipse),
        ] {
            let calloutInfo = trace(try requirePath(callout, from: from, to: to))
            let bodyInfo = trace(try requirePath(body, from: from, to: to))
            try expect(calloutInfo.isClosed, "\(callout.rawValue) must be closed")

            let calloutCorners = distinctPoints(calloutInfo.vertices).count
            let bodyCorners = distinctPoints(bodyInfo.vertices).count
            try expect(
                calloutCorners >= bodyCorners + 2,
                "\(callout.rawValue) has \(calloutCorners) corners against "
                    + "\(body.rawValue)'s \(bodyCorners): no tail"
            )
            try expect(
                calloutInfo.segmentCount > bodyInfo.segmentCount,
                "\(callout.rawValue) adds no segments over a plain \(body.rawValue)"
            )
            try expect(
                calloutInfo.lineCount > bodyInfo.lineCount,
                "\(callout.rawValue)'s tail contributes no straight edges"
            )
        }

        // Heart: two curved lobes, a notch between them, a point at the bottom.
        let heart = trace(try requirePath(.heart, from: from, to: to))
        try expect(heart.isClosed, "the heart must be closed")
        try expect(
            heart.curveCount + heart.quadCount >= 2,
            "the heart needs at least two curved lobes, found "
                + "\(heart.curveCount + heart.quadCount)"
        )
        let heartCorners = distinctPoints(heart.vertices)
        guard let lowest = heartCorners.min(by: { $0.y < $1.y }) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "the heart emitted no points",
                file: #fileID,
                line: #line
            )
        }
        try expect(
            abs(lowest.x - rect.midX) <= rect.width * 0.2,
            "the heart's point sits at \(lowest); a heart tapers to the bottom centre"
        )
        try expect(
            heartCorners.contains { abs($0.x - rect.midX) <= rect.width * 0.12 && $0.y > rect.midY },
            "the heart has no notch between its lobes"
        )
        let upperHalf = heart.allPoints.filter { $0.y >= rect.midY }
        try expect(
            upperHalf.contains { $0.x < rect.midX - rect.width * 0.15 }
                && upperHalf.contains { $0.x > rect.midX + rect.width * 0.15 },
            "the heart is not lobed to either side of its centre line"
        )

        // Lightning: a closed zigzag that doubles back on itself.
        let bolt = trace(try requirePath(.lightning, from: from, to: to))
        try expect(bolt.isClosed, "the lightning bolt must be closed")
        try expect(
            bolt.lineCount >= 4,
            "the lightning bolt needs a zigzag; it has \(bolt.lineCount) straight edges"
        )
        let boltCorners = distinctPoints(bolt.vertices)
        try expect(
            boltCorners.count >= 5,
            "the lightning bolt has \(boltCorners.count) corners; a bolt needs at least 5"
        )
        let boltTurns = turnDirections(boltCorners)
        try expect(
            boltTurns.left > 0 && boltTurns.right > 0,
            "the lightning bolt is convex; a bolt doubles back on itself"
        )
    }

    /// Every shape reaches the bitmap as exactly one undoable checkpoint that a
    /// single undo removes completely and a single redo puts back.
    ///
    /// No call passes a width: `addShape` takes none, and the whole catalogue
    /// outlines at the fixed 4pt every shape tool embodies.
    private func shapeRendering() throws {
        let start = CGPoint(x: 6, y: 5)
        let end = CGPoint(x: 54, y: 43)

        for tool in PaintTool.shapeTools {
            let document = PaintDocument(width: 60, height: 48)
            let revision = document.revision
            try expectEqual(try inkPixels(document).total, 0, "\(tool.rawValue): fresh canvas ink")

            document.addShape(
                tool: tool,
                from: start,
                to: end,
                color: .black,
                constrained: false
            )

            try expect(document.revision > revision, "\(tool.rawValue): addShape must bump revision")
            try expectFlags(document, undo: true, redo: false, dirty: true)

            let painted = try inkPixels(document)
            try expect(
                painted.total >= 20,
                "\(tool.rawValue): only \(painted.total) pixels changed; the shape did not render"
            )
            try expect(
                painted.dark >= 8,
                "\(tool.rawValue): only \(painted.dark) pixels took the stroke colour"
            )

            document.undo()
            try expectFlags(document, undo: false, redo: true, dirty: false)
            try expectEqual(try inkPixels(document).total, 0, "\(tool.rawValue): ink after one undo")

            document.redo()
            try expectFlags(document, undo: true, redo: false, dirty: true)
            try expectEqual(
                try inkPixels(document).total,
                painted.total,
                "\(tool.rawValue): ink after redo"
            )
        }

        // Drawing tools are not shapes: addShape must leave the document alone.
        for tool in PaintTool.drawingTools {
            let document = PaintDocument(width: 24, height: 24)
            let revision = document.revision
            document.addShape(
                tool: tool,
                from: CGPoint(x: 4, y: 4),
                to: CGPoint(x: 20, y: 20),
                color: .black,
                constrained: false
            )
            try expectEqual(document.revision, revision, "\(tool.rawValue): revision after addShape")
            try expectFlags(document, undo: false, redo: false, dirty: false)
            try expectEqual(try inkPixels(document).total, 0, "\(tool.rawValue): ink after addShape")
        }

        // A bounded shape with no area records nothing at all.
        for tool in PaintTool.shapeTools where tool != .line && tool != .curve {
            let document = PaintDocument(width: 24, height: 24)
            document.addShape(
                tool: tool,
                from: CGPoint(x: 12, y: 12),
                to: CGPoint(x: 12, y: 12),
                color: .black,
                constrained: false
            )
            try expectFlags(document, undo: false, redo: false, dirty: false)
            try expectEqual(
                try inkPixels(document).total,
                0,
                "\(tool.rawValue): ink from a zero-area drag"
            )
        }
    }

    // MARK: Entity scenarios

    /// The canvas every entity scenario that shares the fixture below draws on.
    private let entityCanvas = (width: 80, height: 60)

    /// The four fixture entities, spelled out as literal geometry so every
    /// bounds and hit-test expectation can be derived by hand instead of being
    /// read back out of the model. Freehand coordinates sit at pixel centres so
    /// the one-pixel pencil covers whole rows.
    private let fixtureRect = (from: CGPoint(x: 8, y: 8), to: CGPoint(x: 32, y: 28))
    private let fixtureLine = (from: CGPoint(x: 44, y: 10), to: CGPoint(x: 72, y: 26))
    private let fixtureDoodle = [
        CGPoint(x: 10.5, y: 40.5), CGPoint(x: 18.5, y: 48.5),
        CGPoint(x: 26.5, y: 42.5), CGPoint(x: 34.5, y: 50.5),
    ]
    private let fixtureTextOrigin = CGPoint(x: 46, y: 44)
    private let fixtureText = "Ab"
    private let fixtureFontSize: CGFloat = 12

    /// Every committed drawing is one independently selectable entity, appended
    /// in z-order and checkpointed once. The eraser deliberately is not one.
    private func entityCreation() throws {
        let document = PaintDocument(width: entityCanvas.width, height: entityCanvas.height)
        try expect(document.selectableEntityIDs.isEmpty, "a fresh document holds no entities")
        try expectNoEntity(document, at: CGPoint(x: 20, y: 20), tolerance: 4, "a blank canvas")

        document.addShape(
            tool: .rectangle,
            from: fixtureRect.from,
            to: fixtureRect.to,
            color: .black,
            constrained: false
        )
        let afterRect = document.selectableEntityIDs
        try expectEqual(afterRect.count, 1, "entities after a shape")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        document.addShape(
            tool: .line,
            from: fixtureLine.from,
            to: fixtureLine.to,
            color: .black,
            constrained: false
        )
        let afterLine = document.selectableEntityIDs
        try expectEqual(afterLine.count, 2, "entities after a line")

        doodle(document, fixtureDoodle)
        let afterDoodle = document.selectableEntityIDs
        try expectEqual(afterDoodle.count, 3, "entities after a freehand doodle")

        document.addText(
            fixtureText,
            at: fixtureTextOrigin,
            color: .black,
            fontSize: fixtureFontSize
        )
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 4, "entities after text")

        // Appended, never reordered: each list is the previous one plus one new
        // identifier, so the entity drawn last is the topmost.
        try expect(
            Array(afterLine.prefix(1)) == afterRect,
            "the line must be appended above the shape, not inserted"
        )
        try expect(
            Array(afterDoodle.prefix(2)) == afterLine,
            "the doodle must be appended above the line, not inserted"
        )
        try expect(
            Array(ids.prefix(3)) == afterDoodle,
            "the text must be appended above the doodle, not inserted"
        )
        try expectEqual(Set(ids).count, 4, "distinct entity identifiers")

        // Each entity knows the tight box of the ink it deposits: the drawn
        // geometry padded by the width its tool embodies.
        try expectBounds(
            document,
            ids[0],
            CGRect(x: 6, y: 6, width: 28, height: 24),
            "rectangle bounds"
        )
        try expectBounds(
            document,
            ids[1],
            CGRect(x: 42, y: 8, width: 32, height: 20),
            "line bounds"
        )
        try expectBounds(
            document,
            ids[2],
            CGRect(x: 10, y: 40, width: 25, height: 11),
            "doodle bounds"
        )
        try expectBounds(
            document,
            ids[3],
            CGRect(origin: fixtureTextOrigin, size: textSize(fixtureText, fixtureFontSize)),
            "text bounds"
        )

        // The eraser paints the page colour instead of adding content, so it is
        // the one stroke the model refuses to make selectable.
        try expectInk(document, 18, 48, "doodle ink before erasing")
        doodle(document, [CGPoint(x: 10, y: 44), CGPoint(x: 34, y: 44)], tool: .eraser)
        try expect(
            document.selectableEntityIDs == ids,
            "an eraser stroke must add no selectable entity"
        )
        try expectPixel(document, 18, 48, .white, "the eraser cleared the doodle")
        try expectNoEntity(
            document,
            at: CGPoint(x: 38, y: 38),
            tolerance: 4,
            "pixels only the eraser painted"
        )

        // Five checkpoints: four entities and the eraser stroke, in that order.
        document.undo()
        try expect(
            document.selectableEntityIDs == ids,
            "undoing the eraser stroke must leave the entities alone"
        )
        try expectInk(document, 18, 48, "doodle ink restored by undoing the eraser")
        document.undo()
        try expect(
            document.selectableEntityIDs == afterDoodle,
            "one undo must remove exactly the topmost entity"
        )
        document.undo()
        document.undo()
        document.undo()
        try expect(
            document.selectableEntityIDs.isEmpty,
            "unwinding every checkpoint must remove every entity"
        )
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expectPixel(document, 20, 8, .white, "the canvas is blank again")
    }

    /// A click selects the topmost entity it lands on — interior, outline,
    /// stroked band or text box — and empty canvas selects nothing.
    private func entityHitTesting() throws {
        let fixture = try entityFixture()
        let document = fixture.document
        let rectangle = fixture.ids[0]
        let line = fixture.ids[1]
        let doodleID = fixture.ids[2]
        let text = fixture.ids[3]

        // A closed shape is selected by its interior as well as its outline,
        // exactly as a filled-looking object should behave.
        try expectEntity(
            document,
            at: CGPoint(x: 12, y: 12),
            tolerance: 1,
            rectangle,
            "the rectangle's interior"
        )
        try expectEntity(
            document,
            at: CGPoint(x: 8, y: 20),
            tolerance: 1,
            rectangle,
            "the rectangle's outline"
        )

        // Open geometry is selected by its stroked band, and the tolerance is
        // really the slack: 8pt clear of the line misses, a generous tolerance
        // reaches.
        try expectEntity(
            document,
            at: CGPoint(x: 58, y: 18),
            tolerance: 1,
            line,
            "the line's body"
        )
        try expectNoEntity(
            document,
            at: CGPoint(x: 54, y: 25),
            tolerance: 2,
            "8pt clear of the line"
        )
        try expectEntity(
            document,
            at: CGPoint(x: 54, y: 25),
            tolerance: 12,
            line,
            "the same point with a 12pt tolerance"
        )

        try expectEntity(
            document,
            at: CGPoint(x: 18, y: 48),
            tolerance: 2,
            doodleID,
            "the doodle's stroke"
        )
        try expectNoEntity(
            document,
            at: CGPoint(x: 18, y: 56),
            tolerance: 2,
            "clear of the doodle"
        )

        let glyphs = textSize(fixtureText, fixtureFontSize)
        try expectEntity(
            document,
            at: CGPoint(
                x: fixtureTextOrigin.x + glyphs.width / 2,
                y: fixtureTextOrigin.y + glyphs.height / 2
            ),
            tolerance: 0,
            text,
            "the text's box"
        )

        for empty in [CGPoint(x: 2, y: 2), CGPoint(x: 70, y: 12), CGPoint(x: 76, y: 4)] {
            try expectNoEntity(document, at: empty, tolerance: 2, "empty canvas at \(empty)")
        }

        // Where entities overlap the click takes the topmost one, which is the
        // one drawn last.
        document.addShape(
            tool: .ellipse,
            from: CGPoint(x: 20, y: 16),
            to: CGPoint(x: 44, y: 36),
            color: .black,
            constrained: false
        )
        let stacked = document.selectableEntityIDs
        try expectEqual(stacked.count, 5, "entities after the overlapping ellipse")
        let ellipse = stacked[4]
        try expectEntity(
            document,
            at: CGPoint(x: 26, y: 22),
            tolerance: 1,
            ellipse,
            "where the ellipse covers the rectangle"
        )
        try expectEntity(
            document,
            at: CGPoint(x: 12, y: 12),
            tolerance: 1,
            rectangle,
            "where the ellipse does not reach"
        )

        // The eraser sits on top of everything and is still never selected: the
        // click falls through to the entity underneath.
        doodle(document, [CGPoint(x: 10, y: 12), CGPoint(x: 30, y: 12)], tool: .eraser)
        try expect(
            document.selectableEntityIDs == stacked,
            "an eraser stroke must stay unselectable"
        )
        try expectEntity(
            document,
            at: CGPoint(x: 20, y: 12),
            tolerance: 1,
            rectangle,
            "an erased part of the rectangle"
        )
        try expectNoEntity(
            document,
            at: CGPoint(x: 36, y: 5),
            tolerance: 1,
            "pixels only the eraser painted"
        )
    }

    /// The world-space matrices the canvas previews with and the model commits
    /// through are one shared, deterministic definition.
    private func sharedEntityTransforms() throws {
        let move = PaintEntity.moveTransform(dx: 12, dy: -5)
        try expect(
            move == CGAffineTransform(translationX: 12, y: -5),
            "moveTransform must be a pure translation, got \(move)"
        )

        // A handle drag means one thing: the old selection rectangle becomes
        // the new one, on each axis independently.
        let source = CGRect(x: 10, y: 10, width: 20, height: 10)
        let destination = CGRect(x: 40, y: 25, width: 60, height: 20)
        let map = PaintEntity.mapTransform(from: source, to: destination)
        let mapped = source.applying(map)
        try expect(
            nearlyEqual(mapped, destination, 1e-6),
            "mapTransform must carry the source onto the destination, got \(mapped)"
        )
        try expect(
            nearlyEqual(map.a, 3, 1e-9) && nearlyEqual(map.d, 2, 1e-9),
            "mapTransform must scale the axes independently (3×, 2×), got a=\(map.a) d=\(map.d)"
        )
        try expect(
            PaintEntity.mapTransform(
                from: CGRect(x: 10, y: 10, width: 0, height: 10),
                to: destination
            ) == .identity,
            "a degenerate source rectangle defines no resize"
        )

        // Positive angles turn counterclockwise in this bottom-left space and
        // leave the pivot alone, which is what makes a rotation handle
        // predictable.
        let pivot = CGPoint(x: 22, y: 14)
        let quarter = PaintEntity.rotationTransform(by: .pi / 2, around: pivot)
        let heldPivot = pivot.applying(quarter)
        try expect(
            nearlyEqual(heldPivot, pivot, 1e-6),
            "the pivot must be fixed by its own rotation, got \(heldPivot)"
        )
        let turned = CGPoint(x: 34, y: 18).applying(quarter)
        try expect(
            nearlyEqual(turned, CGPoint(x: 18, y: 26), 1e-6),
            "a quarter turn must carry the right-hand end upward, got \(turned)"
        )
        try expect(
            PaintEntity.rotationTransform(by: 0, around: pivot) == .identity,
            "a zero rotation is no edit"
        )
        try expect(
            PaintEntity.rotationTransform(by: .nan, around: pivot) == .identity,
            "a non-finite rotation is no edit"
        )

        // The guards the model's no-op rules are phrased against.
        try expect(PaintEntity.isIdentity(.identity), "the identity must read as the identity")
        try expect(!PaintEntity.isIdentity(move), "a translation is not the identity")
        try expect(PaintEntity.isInvertible(map), "a resize matrix must be invertible")
        let unusable: [CGAffineTransform] = [
            CGAffineTransform(scaleX: 0, y: 1),
            CGAffineTransform(scaleX: 1, y: 0),
            CGAffineTransform(a: 2, b: 1, c: 4, d: 2, tx: 0, ty: 0),
            CGAffineTransform(translationX: .nan, y: 4),
            CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0),
        ]
        for transform in unusable {
            try expect(
                !PaintEntity.isInvertible(transform),
                "\(transform) collapses or breaks the geometry and must not be invertible"
            )
        }

        // Composition order: the entity's own accumulated transform first, the
        // world transform second. Any other order previews an edit somewhere
        // the commit will not put it.
        var entity = PaintEntity(
            content: .shape(
                tool: .rectangle,
                from: .zero,
                to: CGPoint(x: 10, y: 10),
                color: .black
            )
        )
        entity.applyWorldTransform(PaintEntity.moveTransform(dx: 20, dy: 0))
        let placed = entity.bounds()
        try expect(
            nearlyEqual(placed, CGRect(x: 18, y: -2, width: 14, height: 14), 1e-6),
            "the moved rectangle's ink box is \(placed), expected (18.0, -2.0, 14.0, 14.0)"
        )
        let world = CGAffineTransform(scaleX: 2, y: 3)
        let previewed = entity.bounds(applying: world)
        try expect(
            nearlyEqual(previewed, placed.applying(world), 1e-6),
            "a world transform must act on the entity where it already is: got \(previewed), "
                + "expected \(placed.applying(world))"
        )
        try expect(
            entity.hitTest(CGPoint(x: 25, y: 5), tolerance: 0),
            "the moved rectangle must be hit where it now is"
        )
        try expect(
            !entity.hitTest(CGPoint(x: 5, y: 5), tolerance: 0),
            "the moved rectangle must not be hit where it was originally drawn"
        )
        entity.applyWorldTransform(world)
        let committed = entity.bounds()
        try expect(
            nearlyEqual(committed, previewed, 1e-6),
            "committing a world transform must land exactly where it previewed: got "
                + "\(committed), previewed \(previewed)"
        )
    }

    /// Dragging a selected entity moves that entity and nothing else, as one
    /// undo entry, exactly where the preview said it would go.
    private func entityMove() throws {
        let document = PaintDocument(width: 80, height: 60)
        document.addShape(
            tool: .line,
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 34, y: 18),
            color: .black,
            constrained: false
        )
        document.addShape(
            tool: .rectangle,
            from: CGPoint(x: 8, y: 40),
            to: CGPoint(x: 30, y: 56),
            color: .black,
            constrained: false
        )
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 2, "entities before the move")
        let moving = ids[0]
        let neighbour = ids[1]
        let before = try requireBounds(document, moving, .identity, "the line's bounds")
        let neighbourBefore = try requireBounds(
            document,
            neighbour,
            .identity,
            "the neighbour's bounds"
        )
        try expectInk(document, 22, 14, "line ink before the move")
        try expect(try isPage(document, 52, 38), "the destination is blank before the move")

        let move = PaintEntity.moveTransform(dx: 30, dy: 24)
        let expected = before.offsetBy(dx: 30, dy: 24)
        let preview = try requireBounds(document, moving, move, "the previewed bounds")
        try expect(
            nearlyEqual(preview, expected, 1e-6),
            "the drag preview must report \(expected), got \(preview)"
        )

        let revision = document.revision
        document.transformEntity(moving, by: move)
        try expect(document.revision > revision, "a committed move must bump revision")
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expect(
            document.selectableEntityIDs == ids,
            "moving an entity must not disturb the entity list or its order"
        )
        let landed = try requireBounds(document, moving, .identity, "the moved bounds")
        try expect(
            nearlyEqual(landed, expected, 1e-6),
            "the commit must land where the preview showed: got \(landed), expected \(expected)"
        )
        try expectInk(document, 52, 38, "line ink at its new place")
        try expect(try isPage(document, 22, 14), "the line's old place must be blank")
        try expectEntity(
            document,
            at: CGPoint(x: 52, y: 38),
            tolerance: 1,
            moving,
            "the moved line"
        )
        try expectNoEntity(
            document,
            at: CGPoint(x: 22, y: 14),
            tolerance: 1,
            "the line's old place"
        )

        // Entities move independently: the neighbour did not come along.
        let neighbourAfter = try requireBounds(
            document,
            neighbour,
            .identity,
            "the neighbour's bounds after the move"
        )
        try expect(
            nearlyEqual(neighbourAfter, neighbourBefore, 1e-9),
            "the unselected entity must not move: \(neighbourAfter) vs \(neighbourBefore)"
        )
        try expectInk(document, 19, 40, "the neighbour's ink is untouched")

        // One checkpoint for the whole move.
        document.undo()
        try expectFlags(document, undo: true, redo: true, dirty: true)
        let restored = try requireBounds(document, moving, .identity, "the restored bounds")
        try expect(
            nearlyEqual(restored, before, 1e-6),
            "one undo must restore the original placement, got \(restored)"
        )
        try expectInk(document, 22, 14, "line ink restored by undo")
        try expect(try isPage(document, 52, 38), "the moved pixels are gone after undo")

        document.redo()
        try expectInk(document, 52, 38, "line ink after redo")
        try expect(try isPage(document, 22, 14), "the old place stays blank after redo")
    }

    /// A handle drag stretches the entity into the new frame on each axis
    /// independently, and the committed pixels follow the frame.
    private func entityResize() throws {
        let document = PaintDocument(width: 160, height: 120)
        document.addShape(
            tool: .rectangle,
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 30, y: 20),
            color: .black,
            constrained: false
        )
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 1, "one entity to resize")
        let id = ids[0]
        let before = try requireBounds(document, id, .identity, "the shape's bounds")
        try expect(
            nearlyEqual(before, CGRect(x: 8, y: 8, width: 24, height: 14), 1e-6),
            "the shape's ink box is \(before), expected (8.0, 8.0, 24.0, 14.0)"
        )

        // Three times as wide, twice as tall: a resize that keeps the aspect
        // ratio, ignores the frame or swaps the axes cannot pass.
        let destination = CGRect(
            x: 40,
            y: 24,
            width: before.width * 3,
            height: before.height * 2
        )
        let resize = PaintEntity.mapTransform(from: before, to: destination)
        let preview = try requireBounds(document, id, resize, "the previewed frame")
        try expect(
            nearlyEqual(preview, destination, 1e-6),
            "the resize preview must fill \(destination), got \(preview)"
        )

        document.transformEntity(id, by: resize)
        let landed = try requireBounds(document, id, .identity, "the resized bounds")
        try expect(
            nearlyEqual(landed, destination, 1e-6),
            "the commit must fill exactly the previewed frame: got \(landed)"
        )
        try expectFlags(document, undo: true, redo: false, dirty: true)

        // WYSIWYG: the outline is stretched into the frame and stops there.
        try expectInk(document, 76, 28, "the stretched bottom edge")
        try expectInk(document, 76, 47, "the stretched top edge")
        try expectInk(document, 46, 38, "the stretched left edge")
        try expectInk(document, 105, 38, "the stretched right edge")
        try expect(try isPage(document, 76, 38), "the stretched outline is not filled in")
        try expect(
            try isPage(document, 76, 60),
            "a uniform scale would have put the top edge here: the axes must stretch "
                + "independently"
        )
        try expect(try isPage(document, 20, 10), "the shape's original place is blank")

        // One checkpoint.
        document.undo()
        let restored = try requireBounds(document, id, .identity, "the restored bounds")
        try expect(
            nearlyEqual(restored, before, 1e-6),
            "one undo must restore the original frame, got \(restored)"
        )
        try expectInk(document, 20, 10, "the original outline is back")
        try expect(try isPage(document, 76, 28), "the stretched pixels are gone")

        document.redo()
        try expectInk(document, 76, 28, "the stretched outline after redo")
    }

    /// The rotation control turns the entity about its own centre, in the
    /// direction the shared matrix promises, at any angle, as one undo entry.
    private func entityRotation() throws {
        let document = PaintDocument(width: 80, height: 60)
        // An L: not symmetric under a half turn, so which way the entity turned
        // is visible in the pixels rather than merely assumed.
        doodle(
            document,
            [
                CGPoint(x: 10.5, y: 10.5),
                CGPoint(x: 30.5, y: 10.5),
                CGPoint(x: 30.5, y: 26.5),
            ]
        )
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 1, "one entity to rotate")
        let id = ids[0]
        let before = try requireBounds(document, id, .identity, "the doodle's bounds")
        try expect(
            nearlyEqual(before, CGRect(x: 10, y: 10, width: 21, height: 17), 1e-6),
            "the doodle's ink box is \(before), expected (10.0, 10.0, 21.0, 17.0)"
        )
        try expectInk(document, 20, 10, "the horizontal arm before the turn")

        let pivot = CGPoint(x: before.midX, y: before.midY)
        let quarter = PaintEntity.rotationTransform(by: .pi / 2, around: pivot)
        // A quarter turn swaps the frame's extents about the pivot.
        let expected = CGRect(
            x: pivot.x - before.height / 2,
            y: pivot.y - before.width / 2,
            width: before.height,
            height: before.width
        )
        let preview = try requireBounds(document, id, quarter, "the previewed rotation")
        try expect(
            nearlyEqual(preview, expected, 0.01),
            "the rotation preview must report \(expected), got \(preview)"
        )

        document.transformEntity(id, by: quarter)
        let landed = try requireBounds(document, id, .identity, "the rotated bounds")
        try expect(
            nearlyEqual(landed, preview, 0.01),
            "the commit must land where the preview showed: got \(landed), previewed \(preview)"
        )
        try expectFlags(document, undo: true, redo: false, dirty: true)

        // Counterclockwise: the arm that pointed right now points up.
        try expectInk(document, 28, 14, "the turned vertical arm")
        try expectInk(document, 14, 28, "the turned horizontal arm")
        try expect(
            try isPage(document, 14, 8),
            "a clockwise quarter turn would have put the horizontal arm here"
        )
        try expect(try isPage(document, 10, 10), "the doodle's old corner is blank")

        document.undo()
        let unturned = try requireBounds(document, id, .identity, "the restored bounds")
        try expect(
            nearlyEqual(unturned, before, 1e-6),
            "one undo must restore the original orientation, got \(unturned)"
        )
        try expectInk(document, 20, 10, "the horizontal arm is back")
        try expect(try isPage(document, 28, 14), "the turned pixels are gone")

        // Arbitrary angles are not a special case: the ink lands where the
        // shared rotation says it does.
        let tilted = PaintDocument(width: 80, height: 60)
        tilted.addShape(
            tool: .rectangle,
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 56, y: 40),
            color: .black,
            constrained: false
        )
        let tiltedIDs = tilted.selectableEntityIDs
        try expectEqual(tiltedIDs.count, 1, "one entity to tilt")
        let box = try requireBounds(tilted, tiltedIDs[0], .identity, "the rectangle's bounds")
        try expectInk(tilted, 56, 40, "the rectangle's corner before the tilt")
        let hinge = CGPoint(x: box.midX, y: box.midY)
        let tilt = PaintEntity.rotationTransform(by: 0.4, around: hinge)
        let tiltPreview = try requireBounds(tilted, tiltedIDs[0], tilt, "the previewed tilt")
        tilted.transformEntity(tiltedIDs[0], by: tilt)
        let tiltLanded = try requireBounds(tilted, tiltedIDs[0], .identity, "the tilted bounds")
        try expect(
            nearlyEqual(tiltLanded, tiltPreview, 1e-6),
            "an arbitrary angle must commit exactly what it previewed: got \(tiltLanded), "
                + "previewed \(tiltPreview)"
        )
        let edge = CGPoint(x: 38, y: 20).applying(tilt)
        try expectInk(
            tilted,
            Int(edge.x.rounded(.down)),
            Int(edge.y.rounded(.down)),
            "the tilted bottom edge's midpoint"
        )
        try expect(try isPage(tilted, 56, 40), "the untilted corner is blank")
    }

    /// A selection is `{ localBounds, transform }`: the entity's own tight,
    /// untransformed ink rectangle plus the matrix that places it. Both halves
    /// are readable and independent, which is what lets a frame be rebuilt
    /// after a commit instead of re-measured from the world.
    private func entityLocalFrame() throws {
        let document = PaintDocument(width: 200, height: 160)
        // 80 × 32: deliberately not square, so an axis swap or a squared-off
        // frame cannot pass unnoticed.
        document.addShape(
            tool: .rectangle,
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 100, y: 52),
            color: .black,
            constrained: false
        )
        let id = try onlyEntity(document)

        let local = try requireLocalBounds(document, id, "the untouched local frame")
        try expect(
            nearlyEqual(local, CGRect(x: 18, y: 18, width: 84, height: 36), 1e-6),
            "the local frame is \(local), expected the 4pt outline's box (18.0, 18.0, 84.0, 36.0)"
        )
        let start = try requireTransform(document, id, "the untouched matrix")
        try expect(start == .identity, "a freshly drawn entity carries no edit, got \(start)")
        // With nothing applied the local frame and the world ink box are one
        // rectangle: the frame is the entity's own measurement, not a second,
        // looser one taken in world space.
        let world = try requireBounds(document, id, .identity, "the world ink box")
        try expect(
            nearlyEqual(world, local, 1e-9),
            "an unedited entity's world box must be its local frame: \(world) vs \(local)"
        )

        // The local frame is a property of the ink, not of the matrix.
        var entity = PaintEntity(
            content: .shape(
                tool: .rectangle,
                from: .zero,
                to: CGPoint(x: 40, y: 10),
                color: .black
            )
        )
        let untouched = entity.localBounds
        try expect(
            nearlyEqual(untouched, CGRect(x: -2, y: -2, width: 44, height: 14), 1e-6),
            "the local frame is \(untouched), expected (-2.0, -2.0, 44.0, 14.0)"
        )
        entity.applyWorldTransform(
            PaintEntity.rotationTransform(by: 0.6, around: CGPoint(x: 5, y: 5))
        )
        try expect(
            nearlyEqual(entity.localBounds, untouched, 1e-9),
            "a rotated entity must still measure the same local frame, got \(entity.localBounds)"
        )

        // `bounds(using:)` answers for exactly the matrix handed in, ignoring
        // the one the entity stores — that is what makes it usable as the
        // preview half of a replacement edit.
        let probe = CGAffineTransform(translationX: 30, y: 7)
        try expect(
            nearlyEqual(entity.bounds(using: probe), untouched.offsetBy(dx: 30, dy: 7), 1e-6),
            "bounds(using:) must ignore the stored matrix, got \(entity.bounds(using: probe))"
        )
        try expect(
            nearlyEqual(entity.bounds(using: .identity), untouched, 1e-9),
            "bounds(using: .identity) must be the local frame, got "
                + "\(entity.bounds(using: .identity))"
        )
        try expect(
            entity.bounds(using: CGAffineTransform(scaleX: 0, y: 0)).isNull,
            "a collapsed matrix frames nothing"
        )
        try expect(
            PaintEntity(
                content: .text(value: "", origin: .zero, color: .black, fontSize: 12)
            ).localBounds.isNull,
            "an entity that draws nothing has no local frame"
        )

        // Unknown identifiers have neither frame nor matrix, and a degenerate
        // candidate matrix has no measurable box.
        let stranger = UUID()
        try expect(document.entityLocalBounds(stranger) == nil, "an unknown entity has no frame")
        try expect(document.entityTransform(stranger) == nil, "an unknown entity has no matrix")
        try expect(
            document.entityBounds(stranger, using: .identity) == nil,
            "an unknown entity measures nothing"
        )
        try expect(
            document.entityBounds(id, using: CGAffineTransform(scaleX: 0, y: 0)) == nil,
            "a collapsed candidate matrix measures nothing"
        )

        // An edit changes the matrix and only the matrix, so the frame the
        // selector draws afterwards is the same rectangle in a new place.
        let move = PaintEntity.moveTransform(dx: 12, dy: -4)
        document.transformEntity(id, by: move)
        let moved = try requireTransform(document, id, "the matrix after a move")
        try expect(
            moved == start.concatenating(move),
            "the document must report the matrix it stores, got \(moved)"
        )
        let keptLocal = try requireLocalBounds(document, id, "the local frame after a move")
        try expect(
            nearlyEqual(keptLocal, local, 1e-9),
            "a move must not touch the local frame: got \(keptLocal), expected \(local)"
        )
        let framed = frameCorners(keptLocal, moved)
        let movedBox = try requireBounds(document, id, .identity, "the moved ink box")
        try expect(
            nearlyEqual(frameHull(framed), movedBox, 1e-6),
            "under a translation the frame and the ink box still coincide: \(frameHull(framed)) "
                + "vs \(movedBox)"
        )
    }

    /// Rotating an entity turns its frame and nothing else: the frame stays the
    /// entity's own local rectangle seen through the entity's matrix, so it is
    /// still tight and still square-cornered at any angle, before and after the
    /// commit. Rebuilding it from a world-space hull instead — the pre-fix
    /// behaviour — slackens it the moment the entity leaves the axes.
    private func orientedFrameUnderRotation() throws {
        let angles: [CGFloat] = [15 * .pi / 180, 30 * .pi / 180, 37 * .pi / 180, 1.1]
        for angle in angles {
            for fixture in try orientedFixtures() {
                let document = fixture.document
                let id = fixture.id
                let label = "\(fixture.label) turned \(angle) rad"

                let local = try requireLocalBounds(document, id, "\(label): the local frame")
                let start = try requireTransform(document, id, "\(label): the starting matrix")
                let upright = frameCorners(local, start)
                let centre = CGPoint(x: local.midX, y: local.midY).applying(start)
                let candidate = start.concatenating(
                    PaintEntity.rotationTransform(by: angle, around: centre)
                )

                let turned = frameCorners(local, candidate)
                try expect(
                    nearlyEqual(frameWidth(turned), frameWidth(upright), 1e-6)
                        && nearlyEqual(frameHeight(turned), frameHeight(upright), 1e-6),
                    "\(label): a rotation must turn the frame, not resize it: "
                        + "\(frameWidth(turned))×\(frameHeight(turned)), expected "
                        + "\(frameWidth(upright))×\(frameHeight(upright))"
                )
                try expect(
                    frameShear(turned) <= 1e-9,
                    "\(label): the rotated frame's axes must stay perpendicular, |cos| = "
                        + "\(frameShear(turned))"
                )
                try expect(
                    nearlyEqual(frameAngle(turned), frameAngle(upright) + angle, 1e-9),
                    "\(label): the frame must be oriented with the entity: got angle "
                        + "\(frameAngle(turned)), expected \(frameAngle(upright) + angle)"
                )

                // The hull a world-space measurement would frame really is
                // slacker at this angle, so the tightness checks above are not
                // quietly passing on an axis-aligned coincidence.
                let hull = frameHull(turned)
                try expect(
                    hull.width * hull.height > frameArea(turned) * 1.02,
                    "\(label): the axis-aligned hull must be visibly slacker than the oriented "
                        + "frame (hull area \(hull.width * hull.height), frame area "
                        + "\(frameArea(turned))), otherwise this angle proves nothing"
                )

                // The preview measures the candidate matrix itself, and the ink
                // it reports sits inside the frame that frames it.
                let previewBox = try requireBounds(
                    document,
                    id,
                    using: candidate,
                    "\(label): the previewed ink box"
                )
                try expect(
                    hull.insetBy(dx: -0.01, dy: -0.01).contains(previewBox),
                    "\(label): the oriented frame must contain the ink it frames: ink "
                        + "\(previewBox), frame hull \(hull)"
                )

                let revision = document.revision
                document.setEntityTransform(id, to: candidate)
                try expect(
                    document.revision > revision,
                    "\(label): a committed rotation must bump revision"
                )
                try expectFlags(document, undo: true, redo: false, dirty: true)
                let committed = try requireTransform(document, id, "\(label): the committed matrix")
                try expect(
                    committed == candidate,
                    "\(label): the commit must store exactly the matrix that previewed: got "
                        + "\(committed), expected \(candidate)"
                )

                // After the commit the frame is re-read, not re-measured: the
                // same local rectangle through the new matrix. Replacing it with
                // the committed world hull is the defect this covers.
                let keptLocal = try requireLocalBounds(
                    document,
                    id,
                    "\(label): the local frame after the commit"
                )
                try expect(
                    nearlyEqual(keptLocal, local, 1e-9),
                    "\(label): a rotation must leave the local frame untouched: got \(keptLocal), "
                        + "expected \(local)"
                )
                let refreshed = frameCorners(keptLocal, committed)
                try expect(
                    nearlyEqual(frameWidth(refreshed), frameWidth(upright), 1e-6)
                        && nearlyEqual(frameHeight(refreshed), frameHeight(upright), 1e-6)
                        && frameShear(refreshed) <= 1e-9,
                    "\(label): the refreshed frame must still be the tight, turned rectangle: "
                        + "\(frameWidth(refreshed))×\(frameHeight(refreshed)), |cos| = "
                        + "\(frameShear(refreshed))"
                )
                let committedBox = try requireBounds(
                    document,
                    id,
                    .identity,
                    "\(label): the committed ink box"
                )
                try expect(
                    nearlyEqual(committedBox, previewBox, 1e-9),
                    "\(label): the commit must ink exactly what the preview measured: got "
                        + "\(committedBox), previewed \(previewBox)"
                )

                // One history step per commit, restoring the matrix verbatim.
                document.undo()
                let undone = try requireTransform(document, id, "\(label): the matrix after undo")
                try expect(
                    undone == start,
                    "\(label): one undo must restore the replaced matrix: got \(undone), expected "
                        + "\(start)"
                )
                document.redo()
                let redone = try requireTransform(document, id, "\(label): the matrix after redo")
                try expect(
                    redone == candidate,
                    "\(label): redo must reinstate the replacement, got \(redone)"
                )
            }
        }
    }

    /// Resizing a rotated entity scales along the entity's own axes: the pointer
    /// is mapped back through the current matrix, the named local edges move to
    /// it, and the local map composes *before* that matrix. The frame therefore
    /// stretches without ever losing its right angles.
    ///
    /// The pre-fix pipeline — stretch the world hull, compose after — is run
    /// side by side as a control, because it shears, and a check that could not
    /// tell the two apart would prove nothing.
    private func orientedLocalResize() throws {
        let angle: CGFloat = 37 * .pi / 180
        for fixture in try orientedFixtures() {
            let document = fixture.document
            let id = fixture.id
            let label = fixture.label

            let local = try requireLocalBounds(document, id, "\(label): the local frame")
            let upright = try requireTransform(document, id, "\(label): the starting matrix")
            let centre = CGPoint(x: local.midX, y: local.midY).applying(upright)
            document.setEntityTransform(
                id,
                to: upright.concatenating(
                    PaintEntity.rotationTransform(by: angle, around: centre)
                )
            )
            let transform = try requireTransform(document, id, "\(label): the rotated matrix")
            let rotated = frameCorners(local, transform)
            let axisX = unitVector(from: rotated[0], to: rotated[1])
            let axisY = unitVector(from: rotated[0], to: rotated[3])

            // Drag the right-hand edge handle straight out along the frame's own
            // x axis: a pure local-x stretch, and nothing else.
            let edgePointer = offsetPoint(midpoint(rotated[1], rotated[2]), axisX, 30)
            let stretch = localResizeTransform(
                local,
                under: transform,
                pointer: edgePointer,
                edges: FrameEdges(right: true)
            )
            let stretched = frameCorners(local, stretch)
            try expect(
                frameShear(stretched) <= 1e-9,
                "\(label): resizing a rotated entity must not shear its frame, |cos| = "
                    + "\(frameShear(stretched))"
            )
            try expect(
                nearlyEqual(frameWidth(stretched), frameWidth(rotated) + 30, 1e-6),
                "\(label): the dragged axis must follow the pointer: got "
                    + "\(frameWidth(stretched)), expected \(frameWidth(rotated) + 30)"
            )
            try expect(
                nearlyEqual(frameHeight(stretched), frameHeight(rotated), 1e-6),
                "\(label): the untouched axis must keep its length: got "
                    + "\(frameHeight(stretched)), expected \(frameHeight(rotated))"
            )
            try expect(
                nearlyEqual(frameAngle(stretched), frameAngle(rotated), 1e-9),
                "\(label): a resize must not turn the frame: got angle \(frameAngle(stretched)), "
                    + "expected \(frameAngle(rotated))"
            )
            try expect(
                nearlyEqual(stretched[0], rotated[0], 1e-6)
                    && nearlyEqual(stretched[3], rotated[3], 1e-6),
                "\(label): the edge opposite the handle must stay anchored: \(stretched[0]) and "
                    + "\(stretched[3]) vs \(rotated[0]) and \(rotated[3])"
            )
            try expect(
                nearlyEqual(stretched[1], offsetPoint(rotated[1], axisX, 30), 1e-6),
                "\(label): the dragged corner must land under the pointer: got \(stretched[1]), "
                    + "expected \(offsetPoint(rotated[1], axisX, 30))"
            )

            // Control: the pre-fix pipeline on the same gesture. Stretching the
            // world hull and composing after the matrix shears a rotated entity,
            // which is what makes the perpendicularity check above meaningful.
            let hull = try requireBounds(document, id, .identity, "\(label): the rotated hull")
            let sheared = frameCorners(
                local,
                worldHullResizeTransform(
                    hull,
                    under: transform,
                    to: CGRect(
                        x: hull.minX,
                        y: hull.minY,
                        width: hull.width + 30,
                        height: hull.height
                    )
                )
            )
            try expect(
                frameShear(sheared) > 0.1,
                "\(label): the world-hull resize must visibly shear, otherwise the oriented "
                    + "checks prove nothing: |cos| = \(frameShear(sheared))"
            )

            // A corner handle drags both local axes at once, by different
            // amounts: still no shear, still no rotation, and genuinely
            // non-uniform in the entity's own space.
            let cornerPointer = offsetPoint(offsetPoint(rotated[2], axisX, 40), axisY, 10)
            let corner = localResizeTransform(
                local,
                under: transform,
                pointer: cornerPointer,
                edges: FrameEdges(right: true, top: true)
            )
            let grown = frameCorners(local, corner)
            try expect(
                frameShear(grown) <= 1e-9,
                "\(label): a corner drag must not shear the frame, |cos| = \(frameShear(grown))"
            )
            try expect(
                nearlyEqual(frameWidth(grown), frameWidth(rotated) + 40, 1e-6)
                    && nearlyEqual(frameHeight(grown), frameHeight(rotated) + 10, 1e-6),
                "\(label): a corner drag must move both axes to the pointer: got "
                    + "\(frameWidth(grown))×\(frameHeight(grown)), expected "
                    + "\(frameWidth(rotated) + 40)×\(frameHeight(rotated) + 10)"
            )
            let scaleX = frameWidth(grown) / frameWidth(rotated)
            let scaleY = frameHeight(grown) / frameHeight(rotated)
            try expect(
                abs(scaleX - scaleY) > 0.05,
                "\(label): the corner drag must be non-uniform to be worth checking: \(scaleX) "
                    + "vs \(scaleY)"
            )
            try expect(
                nearlyEqual(grown[0], rotated[0], 1e-6),
                "\(label): the corner opposite the handle is the anchor: got \(grown[0]), "
                    + "expected \(rotated[0])"
            )
            try expect(
                nearlyEqual(frameAngle(grown), frameAngle(rotated), 1e-9),
                "\(label): a corner drag must not turn the frame: got angle \(frameAngle(grown))"
            )

            // Committing keeps the local frame and costs exactly one step.
            let previewBox = try requireBounds(
                document,
                id,
                using: corner,
                "\(label): the previewed resize"
            )
            document.setEntityTransform(id, to: corner)
            let committed = try requireTransform(document, id, "\(label): the resized matrix")
            try expect(
                committed == corner,
                "\(label): the commit must store exactly the candidate matrix, got \(committed)"
            )
            let keptLocal = try requireLocalBounds(
                document,
                id,
                "\(label): the local frame after the resize"
            )
            try expect(
                nearlyEqual(keptLocal, local, 1e-9),
                "\(label): a resize must leave the local frame alone — the frame is re-read as "
                    + "{ localBounds, transform }, never re-measured from the world hull: got "
                    + "\(keptLocal), expected \(local)"
            )
            let committedBox = try requireBounds(
                document,
                id,
                .identity,
                "\(label): the resized ink box"
            )
            try expect(
                nearlyEqual(committedBox, previewBox, 1e-9),
                "\(label): the resize must ink exactly what it previewed: got \(committedBox), "
                    + "previewed \(previewBox)"
            )
            document.undo()
            let undone = try requireTransform(document, id, "\(label): the matrix after undo")
            try expect(
                undone == transform,
                "\(label): one undo must reverse the whole resize: got \(undone), expected "
                    + "\(transform)"
            )
            document.redo()
            let redone = try requireTransform(document, id, "\(label): the matrix after redo")
            try expect(
                redone == corner,
                "\(label): redo must reinstate the resize, got \(redone)"
            )
        }
    }

    /// Rotate, resize, repeat. Every cycle must land the frame the drag asked
    /// for — exactly, with square corners — because the frame is rebuilt from
    /// the entity's unchanged local rectangle every time.
    ///
    /// The pre-fix pipeline runs in lockstep as a control: it re-measures a
    /// world hull that is slacker than the true frame the moment the entity is
    /// off-axis, feeds that slack back in on the next cycle, and so both shears
    /// and inflates. That divergence is the regression this scenario pins down.
    private func rotateResizeCycles() throws {
        let document = PaintDocument(width: 320, height: 260)
        let from = CGPoint(x: 60, y: 80)
        let to = CGPoint(x: 160, y: 120)
        document.addShape(tool: .rectangle, from: from, to: to, color: .black, constrained: false)
        let id = try onlyEntity(document)

        let local = try requireLocalBounds(document, id, "the local frame")
        let start = try requireTransform(document, id, "the starting matrix")
        var expectedWidth = frameWidth(frameCorners(local, start))
        let expectedHeight = frameHeight(frameCorners(local, start))

        // The control carries the same ink through the same gestures, resized
        // the pre-fix way.
        var control = PaintEntity(
            content: .shape(tool: .rectangle, from: from, to: to, color: .black)
        )
        try expect(
            nearlyEqual(control.localBounds, local, 1e-9),
            "the control must measure the same local frame as the document's entity: "
                + "\(control.localBounds) vs \(local)"
        )

        let step: CGFloat = 15 * .pi / 180
        for cycle in 1...4 {
            let before = try requireTransform(document, id, "cycle \(cycle): the matrix")
            let centre = CGPoint(x: local.midX, y: local.midY).applying(before)
            document.setEntityTransform(
                id,
                to: before.concatenating(PaintEntity.rotationTransform(by: step, around: centre))
            )
            let turned = try requireTransform(document, id, "cycle \(cycle): the rotated matrix")
            let rotated = frameCorners(local, turned)
            try expect(
                nearlyEqual(frameWidth(rotated), expectedWidth, 1e-6)
                    && nearlyEqual(frameHeight(rotated), expectedHeight, 1e-6),
                "cycle \(cycle): rotation must not inflate the frame: got "
                    + "\(frameWidth(rotated))×\(frameHeight(rotated)), expected "
                    + "\(expectedWidth)×\(expectedHeight)"
            )
            try expect(
                frameShear(rotated) <= 1e-9,
                "cycle \(cycle): rotation must not shear the frame, |cos| = \(frameShear(rotated))"
            )

            // Stretch the local x axis by a tenth, through the same pointer
            // arithmetic a handle drag produces.
            let pointer = offsetPoint(
                midpoint(rotated[1], rotated[2]),
                unitVector(from: rotated[0], to: rotated[1]),
                expectedWidth * 0.1
            )
            document.setEntityTransform(
                id,
                to: localResizeTransform(
                    local,
                    under: turned,
                    pointer: pointer,
                    edges: FrameEdges(right: true)
                )
            )
            expectedWidth *= 1.1
            let resizedMatrix = try requireTransform(
                document,
                id,
                "cycle \(cycle): the resized matrix"
            )
            let resized = frameCorners(local, resizedMatrix)
            try expect(
                nearlyEqual(frameWidth(resized), expectedWidth, 1e-6),
                "cycle \(cycle): the frame must be exactly the width the drag asked for: got "
                    + "\(frameWidth(resized)), expected \(expectedWidth)"
            )
            try expect(
                nearlyEqual(frameHeight(resized), expectedHeight, 1e-6),
                "cycle \(cycle): the untouched axis must not creep: got "
                    + "\(frameHeight(resized)), expected \(expectedHeight)"
            )
            try expect(
                frameShear(resized) <= 1e-9,
                "cycle \(cycle): repeated rotate-resize cycles must not shear the frame, |cos| = "
                    + "\(frameShear(resized))"
            )
            let cycleLocal = try requireLocalBounds(
                document,
                id,
                "cycle \(cycle): the local frame"
            )
            try expect(
                nearlyEqual(cycleLocal, local, 1e-9),
                "cycle \(cycle): the local frame must survive every cycle untouched: got "
                    + "\(cycleLocal), expected \(local)"
            )

            // The control's cycle: rotate about its re-measured hull's centre,
            // then stretch that hull axis-aligned by the same tenth.
            let controlHull = control.bounds()
            control.applyWorldTransform(
                PaintEntity.rotationTransform(
                    by: step,
                    around: CGPoint(x: controlHull.midX, y: controlHull.midY)
                )
            )
            let turnedHull = control.bounds()
            control.transform = worldHullResizeTransform(
                turnedHull,
                under: control.transform,
                to: CGRect(
                    x: turnedHull.minX,
                    y: turnedHull.minY,
                    width: turnedHull.width * 1.1,
                    height: turnedHull.height
                )
            )
        }

        // Four cycles in: the oriented frame is exactly the rectangle the drags
        // asked for, and the ink it frames is inside it.
        let finalMatrix = try requireTransform(document, id, "the matrix after four cycles")
        let finalFrame = frameCorners(local, finalMatrix)
        try expect(
            nearlyEqual(frameWidth(finalFrame), expectedWidth, 1e-6)
                && nearlyEqual(frameHeight(finalFrame), expectedHeight, 1e-6),
            "four cycles must compound to \(expectedWidth)×\(expectedHeight), got "
                + "\(frameWidth(finalFrame))×\(frameHeight(finalFrame))"
        )
        let finalHull = frameHull(finalFrame)
        let finalInk = try requireBounds(document, id, .identity, "the ink after four cycles")
        try expect(
            finalHull.insetBy(dx: -0.01, dy: -0.01).contains(finalInk),
            "the frame must still contain its ink: ink \(finalInk), frame hull \(finalHull)"
        )

        // ...whereas the world-hull control has sheared and inflated, so the
        // equalities above are discriminating rather than tautological.
        let controlFrame = frameCorners(local, control.transform)
        try expect(
            frameShear(controlFrame) > 0.2,
            "the world-hull control must have sheared badly by now, |cos| = "
                + "\(frameShear(controlFrame))"
        )
        let controlBox = control.bounds()
        try expect(
            controlBox.width * controlBox.height > expectedWidth * expectedHeight * 1.5,
            "the world-hull control must have inflated well past the requested frame: hull area "
                + "\(controlBox.width * controlBox.height) vs requested "
                + "\(expectedWidth * expectedHeight)"
        )
        try expect(
            abs(frameWidth(controlFrame) - expectedWidth) > 1,
            "the world-hull control must not land the frame the drags asked for: got "
                + "\(frameWidth(controlFrame)), requested \(expectedWidth)"
        )

        // Eight commits, eight undo steps, unwinding to the original matrix.
        for _ in 0..<8 {
            document.undo()
        }
        let unwound = try requireTransform(document, id, "the matrix after unwinding")
        try expect(
            unwound == start,
            "each rotate and each resize must be one undo step: got \(unwound), expected \(start)"
        )
        let unwoundLocal = try requireLocalBounds(
            document,
            id,
            "the local frame after unwinding"
        )
        try expect(
            nearlyEqual(unwoundLocal, local, 1e-9),
            "unwinding must leave the local frame as it always was, got \(unwoundLocal)"
        )
    }

    /// A replacement matrix previews and commits the very same pixels, and a
    /// replacement that cannot change anything changes nothing at all.
    private func absoluteTransformReplacement() throws {
        let document = PaintDocument(width: 120, height: 100)
        document.addShape(
            tool: .rectangle,
            from: CGPoint(x: 8, y: 8),
            to: CGPoint(x: 40, y: 30),
            color: .black,
            constrained: false
        )
        doodle(
            document,
            [
                CGPoint(x: 14.5, y: 44.5),
                CGPoint(x: 40.5, y: 62.5),
                CGPoint(x: 62.5, y: 48.5),
            ]
        )
        document.addText("Ab", at: CGPoint(x: 78, y: 70), color: .black, fontSize: 12)
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 3, "entities before the replacement")
        let selected = ids[1]

        // The entity already carries an edit, so the candidate has to be built
        // from the matrix it stores rather than from nothing.
        document.transformEntity(selected, by: PaintEntity.moveTransform(dx: 6, dy: -3))
        let local = try requireLocalBounds(document, selected, "the doodle's local frame")
        let placed = try requireTransform(document, selected, "the doodle's matrix")

        // Rotate, then stretch one local edge: the composed matrix a selector
        // hands over at mouse-up.
        let centre = CGPoint(x: local.midX, y: local.midY).applying(placed)
        let rotated = placed.concatenating(
            PaintEntity.rotationTransform(by: 15 * .pi / 180, around: centre)
        )
        let corners = frameCorners(local, rotated)
        let pointer = offsetPoint(
            midpoint(corners[1], corners[2]),
            unitVector(from: corners[0], to: corners[1]),
            10
        )
        let candidate = localResizeTransform(
            local,
            under: rotated,
            pointer: pointer,
            edges: FrameEdges(right: true)
        )
        try expect(
            frameShear(frameCorners(local, candidate)) <= 1e-9,
            "the candidate must keep the frame's axes perpendicular, |cos| = "
                + "\(frameShear(frameCorners(local, candidate)))"
        )
        let previewBounds = try requireBounds(
            document,
            selected,
            using: candidate,
            "the previewed ink box"
        )

        // What the canvas paints while the gesture is live: the scene without
        // the entity, plus the entity under exactly the candidate matrix.
        let backdropImage = try requireImage(
            document.renderedImage(excludingEntity: selected),
            "the scene without the selected entity"
        )
        let context = try canvasContext(document.pixelWidth, document.pixelHeight)
        context.draw(
            backdropImage,
            in: CGRect(x: 0, y: 0, width: document.pixelWidth, height: document.pixelHeight)
        )
        document.drawEntity(selected, in: context, using: candidate)
        let preview = try raster(try requireImage(context.makeImage(), "the replacement preview"))

        document.setEntityTransform(selected, to: candidate)
        let committedBounds = try requireBounds(
            document,
            selected,
            .identity,
            "the committed ink box"
        )
        try expect(
            nearlyEqual(committedBounds, previewBounds, 1e-9),
            "the commit must measure exactly what the preview did: got \(committedBounds), "
                + "previewed \(previewBounds)"
        )
        let committed = try raster(try requireImage(document.cgImage, "the committed image"))
        let drift = try rasterDifference(preview, committed, slack: 4)
        let pixels = preview.width * preview.height
        try expect(
            drift.differing * 500 <= pixels,
            "an absolute preview and its commit must compose to the same pixels: "
                + "\(drift.differing) of \(pixels) differ (worst channel \(drift.worst))"
        )

        // Replacements that cannot change anything: no matrix, no history, no
        // pixels.
        let matrix = try requireTransform(document, selected, "the matrix a no-op must preserve")
        let revision = document.revision
        let undoable = document.canUndo
        let redoable = document.canRedo
        let before = try raster(try requireImage(document.cgImage, "the image before the no-ops"))
        let rejected: [(transform: CGAffineTransform, description: String)] = [
            (matrix, "the matrix the entity already stores"),
            (CGAffineTransform(scaleX: 0, y: 1), "a matrix that collapses the x axis"),
            (CGAffineTransform(scaleX: 1, y: 0), "a matrix that collapses the y axis"),
            (CGAffineTransform(a: 2, b: 1, c: 4, d: 2, tx: 0, ty: 0), "a singular matrix"),
            (CGAffineTransform(translationX: .nan, y: 4), "a non-finite translation"),
            (CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0), "a non-finite scale"),
        ]
        for rejection in rejected {
            document.setEntityTransform(selected, to: rejection.transform)
            let held = try requireTransform(
                document,
                selected,
                "the matrix after \(rejection.description)"
            )
            try expect(
                held == matrix,
                "\(rejection.description) must not be committed: the entity now holds \(held)"
            )
            try expectEqual(
                document.revision,
                revision,
                "revision after \(rejection.description)"
            )
            try expect(
                document.canUndo == undoable && document.canRedo == redoable,
                "history flags after \(rejection.description): canUndo \(document.canUndo), "
                    + "canRedo \(document.canRedo)"
            )
        }
        document.setEntityTransform(UUID(), to: CGAffineTransform(translationX: 5, y: 5))
        try expectEqual(document.revision, revision, "revision after an unknown identifier")
        let untouched = try requireTransform(
            document,
            selected,
            "the matrix after an unknown identifier"
        )
        try expect(
            untouched == matrix,
            "an unknown identifier must transform nothing, got \(untouched)"
        )
        let after = try raster(try requireImage(document.cgImage, "the image after the no-ops"))
        try expectEqual(
            try rasterDifference(before, after).differing,
            0,
            "pixels a rejected replacement changed"
        )

        // The identity is not a no-op: it is how an entity is put back where it
        // was drawn, and it commits like any other replacement.
        document.setEntityTransform(selected, to: .identity)
        try expect(
            document.revision > revision,
            "resetting a transformed entity to the identity is a real edit"
        )
        let reset = try requireTransform(document, selected, "the matrix after the reset")
        try expect(reset == .identity, "the reset must store the identity, got \(reset)")
        let keptLocal = try requireLocalBounds(
            document,
            selected,
            "the local frame after the reset"
        )
        try expect(
            nearlyEqual(keptLocal, local, 1e-9),
            "no replacement may rewrite the local frame: got \(keptLocal), expected \(local)"
        )
        let resetBox = try requireBounds(document, selected, .identity, "the ink box after reset")
        try expect(
            nearlyEqual(resetBox, local, 1e-9),
            "with the identity stored the ink box is the local frame: got \(resetBox)"
        )
        document.undo()
        let restored = try requireTransform(
            document,
            selected,
            "the matrix after undoing the reset"
        )
        try expect(
            restored == candidate,
            "one undo must restore the matrix the reset replaced, got \(restored)"
        )
    }

    /// The live drag preview and the committed document are the same pixels:
    /// the scene without the selected entity, plus that entity through the drag
    /// matrix, composed in one order only.
    private func entityPreviewMatchesCommit() throws {
        let document = PaintDocument(width: 80, height: 60)
        document.addShape(
            tool: .rectangle,
            from: CGPoint(x: 6, y: 6),
            to: CGPoint(x: 30, y: 26),
            color: .black,
            constrained: false
        )
        doodle(
            document,
            [
                CGPoint(x: 12.5, y: 34.5),
                CGPoint(x: 22.5, y: 44.5),
                CGPoint(x: 30.5, y: 36.5),
            ]
        )
        document.addText("Ab", at: CGPoint(x: 58, y: 44), color: .black, fontSize: 12)
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 3, "entities before the drag")
        let selected = ids[1]

        // The entity already carries an earlier edit, so the drag matrix has to
        // compose on top of it instead of replacing it.
        document.transformEntity(selected, by: PaintEntity.moveTransform(dx: 4, dy: -2))
        let placed = try requireBounds(document, selected, .identity, "the moved doodle")
        try expectInk(document, 26, 42, "the doodle where the earlier edit left it")

        let centre = CGPoint(x: placed.midX, y: placed.midY)
        let drag = PaintEntity.rotationTransform(by: 0.35, around: centre)
            .concatenating(CGAffineTransform(translationX: 6, y: 3))
        let previewBounds = try requireBounds(document, selected, drag, "the previewed drag")

        // The backdrop a live drag paints under the entity really is the scene
        // without it: the entity's own ink gone, everything else identical.
        let full = try requireImage(document.cgImage, "the document image")
        let backdropImage = try requireImage(
            document.renderedImage(excludingEntity: selected),
            "the scene without the selected entity"
        )
        let backdrop = try raster(backdropImage)
        let composite = try raster(full)
        try expectImagePixel(
            backdrop,
            26,
            document.pixelHeight - 1 - 42,
            .white,
            "the selected entity must be absent from the backdrop"
        )
        try expectImagePixel(
            backdrop,
            18,
            document.pixelHeight - 1 - 6,
            .black,
            "the entity below must still draw into the backdrop"
        )
        try expectEqual(
            try rasterDifference(backdrop, composite, ignoring: placed).differing,
            0,
            "pixels outside the excluded entity's own bounds"
        )
        try expect(
            try rasterDifference(backdrop, composite).differing > 0,
            "excluding the selected entity must actually remove its ink"
        )
        let everything = try raster(
            try requireImage(
                document.renderedImage(excludingEntity: nil),
                "the scene with every entity"
            )
        )
        try expectEqual(
            try rasterDifference(everything, composite).differing,
            0,
            "pixels where renderedImage(excludingEntity: nil) differs from the document image"
        )
        let strangerExcluded = try raster(
            try requireImage(
                document.renderedImage(excludingEntity: UUID()),
                "the scene excluding an unknown entity"
            )
        )
        try expectEqual(
            try rasterDifference(strangerExcluded, composite).differing,
            0,
            "pixels an unknown identifier excluded"
        )

        // What the canvas paints during the drag...
        let context = try canvasContext(document.pixelWidth, document.pixelHeight)
        context.draw(
            backdropImage,
            in: CGRect(x: 0, y: 0, width: document.pixelWidth, height: document.pixelHeight)
        )
        document.drawEntity(selected, in: context, applying: drag)
        let preview = try raster(try requireImage(context.makeImage(), "the drag preview"))

        // ...and what the model commits when the mouse comes up.
        document.transformEntity(selected, by: drag)
        let committedBounds = try requireBounds(
            document,
            selected,
            .identity,
            "the committed bounds"
        )
        try expect(
            nearlyEqual(committedBounds, previewBounds, 1e-6),
            "the commit must land exactly where the preview showed: got \(committedBounds), "
                + "previewed \(previewBounds)"
        )
        let committed = try raster(try requireImage(document.cgImage, "the committed image"))
        let drift = try rasterDifference(preview, committed, slack: 4)
        let pixels = preview.width * preview.height
        try expect(
            drift.differing * 500 <= pixels,
            "the preview and the commit must compose to the same pixels: \(drift.differing) "
                + "of \(pixels) differ (worst channel \(drift.worst))"
        )
    }

    /// Delete removes exactly one entity, as one undo entry, and leaves behind
    /// exactly the scene the drag backdrop already showed.
    private func entityDelete() throws {
        let fixture = try entityFixture()
        let document = fixture.document
        let ids = fixture.ids
        let doomed = ids[2]
        let remaining = [ids[0], ids[1], ids[3]]

        try expectInk(document, 18, 48, "the doodle's ink before the delete")
        let backdrop = try raster(
            try requireImage(
                document.renderedImage(excludingEntity: doomed),
                "the scene without the doodle"
            )
        )

        let revision = document.revision
        document.deleteEntity(doomed)
        try expect(document.revision > revision, "deleting an entity must bump revision")
        try expect(
            document.selectableEntityIDs == remaining,
            "delete must remove exactly one entity and keep the rest in z-order"
        )
        try expect(
            document.entityBounds(doomed, applying: .identity) == nil,
            "a deleted entity has no bounds"
        )
        try expect(try isPage(document, 18, 48), "the deleted entity's ink is gone")
        try expectNoEntity(
            document,
            at: CGPoint(x: 18, y: 48),
            tolerance: 2,
            "the deleted entity"
        )
        try expectInk(document, 20, 8, "the entity below survives the delete")
        let after = try raster(try requireImage(document.cgImage, "the image after the delete"))
        try expectEqual(
            try rasterDifference(backdrop, after).differing,
            0,
            "pixels where a delete differs from the preview backdrop that predicted it"
        )

        document.undo()
        try expect(
            document.selectableEntityIDs == ids,
            "one undo must restore the deleted entity, identifier and z-order included"
        )
        try expectInk(document, 18, 48, "the deleted ink is back")
        document.redo()
        try expect(
            document.selectableEntityIDs == remaining,
            "redo must remove the same entity again"
        )

        // One checkpoint each, and the canvas empties out.
        for id in remaining {
            document.deleteEntity(id)
        }
        try expect(document.selectableEntityIDs.isEmpty, "every entity deleted")
        try expect(try isPage(document, 20, 8), "the canvas is blank once every entity is gone")
        document.undo()
        document.undo()
        document.undo()
        try expect(
            document.selectableEntityIDs == remaining,
            "three undos must reverse exactly the three deletes"
        )
    }

    /// Requests that cannot change anything change neither the entities, the
    /// pixels nor the history.
    private func entityNoOps() throws {
        let fixture = try entityFixture()
        let document = fixture.document
        let ids = fixture.ids
        let id = ids[0]
        let bounds = try requireBounds(document, id, .identity, "the rectangle's bounds")
        let revision = document.revision

        let rejected: [CGAffineTransform] = [
            .identity,
            CGAffineTransform(translationX: 0, y: 0),
            CGAffineTransform(scaleX: 0, y: 1),
            CGAffineTransform(scaleX: 1, y: 0),
            CGAffineTransform(a: 2, b: 1, c: 4, d: 2, tx: 0, ty: 0),
            CGAffineTransform(translationX: .nan, y: 4),
            CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0),
        ]
        for transform in rejected {
            document.transformEntity(id, by: transform)
            try expectEqual(
                document.revision,
                revision,
                "revision after transformEntity(by: \(transform))"
            )
            try expectFlags(document, undo: true, redo: false, dirty: true)
            let unchanged = try requireBounds(document, id, .identity, "the bounds")
            try expect(
                nearlyEqual(unchanged, bounds, 1e-9),
                "transformEntity(by: \(transform)) must change nothing, bounds became \(unchanged)"
            )
        }

        // Unknown identifiers are not errors, they are nothing.
        let stranger = UUID()
        document.transformEntity(stranger, by: PaintEntity.moveTransform(dx: 10, dy: 10))
        document.deleteEntity(stranger)
        try expectEqual(
            document.revision,
            revision,
            "revision after operating on an unknown identifier"
        )
        try expect(
            document.selectableEntityIDs == ids,
            "an unknown identifier must change no entity"
        )
        try expect(
            document.entityBounds(stranger, applying: .identity) == nil,
            "an unknown identifier has no bounds"
        )

        let base = try requireImage(document.cgImage, "the document image")
        let context = try canvasContext(document.pixelWidth, document.pixelHeight)
        context.draw(
            base,
            in: CGRect(x: 0, y: 0, width: document.pixelWidth, height: document.pixelHeight)
        )
        document.drawEntity(stranger, in: context, applying: .identity)
        let drawn = try raster(try requireImage(context.makeImage(), "the unchanged composite"))
        try expectEqual(
            try rasterDifference(try raster(base), drawn).differing,
            0,
            "pixels drawn for an unknown identifier"
        )

        // Four fixture checkpoints and nothing since, so none of the rejections
        // left a half-open operation behind: one real edit plus five undos
        // reaches the pristine document.
        document.transformEntity(id, by: PaintEntity.moveTransform(dx: 6, dy: 6))
        try expectFlags(document, undo: true, redo: false, dirty: true)
        for _ in 0..<5 {
            document.undo()
        }
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expect(
            document.selectableEntityIDs.isEmpty,
            "unwinding every checkpoint must remove every entity"
        )
    }

    /// Flood fill, clear and a new document flatten or drop the entities; the
    /// pixels they were made of survive where they should, and resizing keeps
    /// the entities anchored exactly like the background.
    private func entityFlattening() throws {
        let document = PaintDocument(width: 40, height: 40)
        document.addShape(
            tool: .rectangle,
            from: CGPoint(x: 6, y: 6),
            to: CGPoint(x: 34, y: 34),
            color: .black,
            constrained: false
        )
        doodle(document, [CGPoint(x: 2.5, y: 36.5), CGPoint(x: 8.5, y: 38.5)])
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 2, "entities before the fill")
        try expectInk(document, 20, 6, "the outline before the fill")
        try expectEntity(
            document,
            at: CGPoint(x: 20, y: 6),
            tolerance: 1,
            ids[0],
            "the outline before the fill"
        )

        // Filling flattens the composite into the background first, so the fill
        // is bounded by the entities' own pixels and nothing stays selectable.
        // Had the entities still been floating above the background, the fill
        // would have flooded the whole page.
        document.floodFill(at: CGPoint(x: 20, y: 20), color: .red)
        try expect(document.selectableEntityIDs.isEmpty, "flood fill must flatten every entity")
        try expectPixel(document, 20, 20, .red, "the filled interior")
        try expectInk(document, 20, 6, "the flattened outline keeps its pixels")
        try expectInk(document, 5, 37, "the flattened doodle keeps its pixels")
        try expectPixel(document, 2, 2, .white, "the fill stopped at the flattened outline")
        try expectNoEntity(
            document,
            at: CGPoint(x: 20, y: 6),
            tolerance: 2,
            "flattened pixels"
        )

        // One checkpoint, and the entities come back exactly as they were.
        document.undo()
        try expect(
            document.selectableEntityIDs == ids,
            "undoing the fill must restore the same entities in the same order"
        )
        try expectPixel(document, 20, 20, .white, "the fill is undone")
        try expectEntity(
            document,
            at: CGPoint(x: 20, y: 6),
            tolerance: 1,
            ids[0],
            "the outline after undoing the fill"
        )
        document.redo()
        try expect(document.selectableEntityIDs.isEmpty, "redoing the fill flattens again")
        document.undo()

        // Clearing the canvas takes the entities with it, as one checkpoint.
        document.clear(color: .white)
        try expect(document.selectableEntityIDs.isEmpty, "clear must remove every entity")
        try expectPixel(document, 20, 6, .white, "clear wipes the entity pixels")
        document.undo()
        try expect(
            document.selectableEntityIDs == ids,
            "undoing a clear must restore the entities"
        )
        try expectInk(document, 20, 6, "the outline is back after undoing the clear")

        // A new document starts from nothing at all.
        document.newDocument(width: 32, height: 24)
        try expect(document.selectableEntityIDs.isEmpty, "newDocument must remove every entity")
        try expectFlags(document, undo: false, redo: false, dirty: false)

        // Resizing keeps the entities and anchors their content to the top-left
        // exactly as it anchors the background pixels.
        let resized = PaintDocument(width: 20, height: 20)
        resized.addShape(
            tool: .rectangle,
            from: CGPoint(x: 4, y: 4),
            to: CGPoint(x: 14, y: 14),
            color: .black,
            constrained: false
        )
        let resizedIDs = resized.selectableEntityIDs
        try expectEqual(resizedIDs.count, 1, "one entity before the resize")
        let box = try requireBounds(resized, resizedIDs[0], .identity, "the bounds before")
        resized.resize(width: 20, height: 40, background: .red)
        try expect(
            resized.selectableEntityIDs == resizedIDs,
            "resizing must keep the entities"
        )
        let anchored = try requireBounds(resized, resizedIDs[0], .identity, "the bounds after")
        let expected = box.offsetBy(dx: 0, dy: 20)
        try expect(
            nearlyEqual(anchored, expected, 1e-6),
            "entity content must stay anchored to the top-left like the background pixels: "
                + "got \(anchored), expected \(expected)"
        )
        try expectInk(resized, 9, 24, "the entity's edge after the resize")
        try expectPixel(resized, 2, 2, .red, "the new area takes the background colour")
        resized.undo()
        let unresized = try requireBounds(resized, resizedIDs[0], .identity, "the bounds restored")
        try expect(
            nearlyEqual(unresized, box, 1e-6),
            "undoing the resize must restore the entity placement, got \(unresized)"
        )
    }

    /// Entities are part of what the app shows, samples and writes out: the
    /// eyedropper, the rasterised image and the saved PNG all include them, and
    /// opening a file starts over with pixels only.
    private func entitiesInFiles() throws {
        let ink = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let document = PaintDocument(width: 40, height: 30)
        document.addShape(
            tool: .rectangle,
            from: CGPoint(x: 6, y: 8),
            to: CGPoint(x: 34, y: 24),
            color: ink,
            constrained: false
        )
        doodle(
            document,
            [CGPoint(x: 4.5, y: 3.5), CGPoint(x: 16.5, y: 3.5)],
            color: ink
        )
        try expectEqual(document.selectableEntityIDs.count, 2, "entities to save")

        // Colour sampling reads the entity's own colour, not the background
        // underneath it.
        try expectPixel(document, 20, 7, ink, "the shape's colour under the eyedropper")
        try expectPixel(document, 10, 3, ink, "the doodle's colour under the eyedropper")

        // ...and so does the image the app draws and saves.
        let image = try raster(try requireImage(document.cgImage, "the document image"))
        try expectImagePixel(
            image,
            20,
            document.pixelHeight - 1 - 7,
            ink,
            "the shape in the rasterised image"
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paint-model-smoke-entities-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.savePNG(to: url)
        try expectFlags(document, undo: true, redo: false, dirty: false)

        try document.open(url: url)
        try expectSize(document, 40, 30)
        try expect(
            document.selectableEntityIDs.isEmpty,
            "opening a file must start with pixels and no entities"
        )
        try expectFlags(document, undo: false, redo: false, dirty: false)
        try expectPixel(document, 20, 7, ink, "the saved file holds the shape's pixels")
        try expectPixel(document, 10, 3, ink, "the saved file holds the doodle's pixels")
        try expectNoEntity(
            document,
            at: CGPoint(x: 20, y: 7),
            tolerance: 2,
            "imported pixels"
        )
    }

    // MARK: Entity helpers

    /// Top-left based, unpremultiplied readback of a `CGImage`, so rendered
    /// pixels can be inspected in the orientation the image itself stores them.
    private struct Raster {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let base = y * bytesPerRow + x * 4
            let alpha = Double(bytes[base + 3]) / 255
            guard alpha > 0 else { return (0, 0, 0, 0) }
            return (
                min(1, Double(bytes[base]) / 255 / alpha),
                min(1, Double(bytes[base + 1]) / 255 / alpha),
                min(1, Double(bytes[base + 2]) / 255 / alpha),
                alpha
            )
        }
    }

    /// The four fixture entities on the shared canvas, in z-order.
    private func entityFixture(
        file: String = #fileID,
        line: UInt = #line
    ) throws -> (document: PaintDocument, ids: [UUID]) {
        let document = PaintDocument(width: entityCanvas.width, height: entityCanvas.height)
        document.addShape(
            tool: .rectangle,
            from: fixtureRect.from,
            to: fixtureRect.to,
            color: .black,
            constrained: false
        )
        document.addShape(
            tool: .line,
            from: fixtureLine.from,
            to: fixtureLine.to,
            color: .black,
            constrained: false
        )
        doodle(document, fixtureDoodle)
        document.addText(
            fixtureText,
            at: fixtureTextOrigin,
            color: .black,
            fontSize: fixtureFontSize
        )
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 4, "entity fixture size", file: file, line: line)
        return (document, ids)
    }

    /// One freehand transaction along `points`, exactly as a drag arrives:
    /// begin, one segment per mouse move, end.
    private func doodle(
        _ document: PaintDocument,
        _ points: [CGPoint],
        tool: PaintTool = .pencil,
        color: NSColor = .black
    ) {
        guard let first = points.first else { return }
        document.beginStroke()
        if points.count == 1 {
            document.drawStroke(
                from: first,
                to: first,
                tool: tool,
                color: color,
                secondaryColor: .white
            )
        }
        var previous = first
        for point in points.dropFirst() {
            document.drawStroke(
                from: previous,
                to: point,
                tool: tool,
                color: color,
                secondaryColor: .white
            )
            previous = point
        }
        document.endStroke()
    }

    /// The laid-out size of a text entity's glyphs, measured the same way the
    /// entity measures itself, so text bounds can be predicted here.
    private func textSize(_ value: String, _ fontSize: CGFloat) -> CGSize {
        NSAttributedString(
            string: value,
            attributes: [.font: NSFont.systemFont(ofSize: max(1, fontSize))]
        ).size()
    }

    /// Three deliberately asymmetric entities — a wide rectangle, a slanted
    /// line and a bent pencil doodle — each alone on its own canvas.
    ///
    /// Asymmetry is the point: a square would hide an axis swap, and a frame
    /// that quietly re-measured itself in world space would still look right on
    /// something symmetric.
    private func orientedFixtures(
        file: String = #fileID,
        line: UInt = #line
    ) throws -> [(label: String, document: PaintDocument, id: UUID)] {
        var fixtures: [(label: String, document: PaintDocument, id: UUID)] = []

        let rectangle = PaintDocument(width: 260, height: 220)
        rectangle.addShape(
            tool: .rectangle,
            from: CGPoint(x: 60, y: 80),
            to: CGPoint(x: 160, y: 120),
            color: .black,
            constrained: false
        )
        fixtures.append(
            (
                label: "the 100×40 rectangle",
                document: rectangle,
                id: try onlyEntity(rectangle, file: file, line: line)
            )
        )

        let slant = PaintDocument(width: 260, height: 220)
        slant.addShape(
            tool: .line,
            from: CGPoint(x: 50, y: 50),
            to: CGPoint(x: 170, y: 110),
            color: .black,
            constrained: false
        )
        fixtures.append(
            (
                label: "the slanted line",
                document: slant,
                id: try onlyEntity(slant, file: file, line: line)
            )
        )

        let bent = PaintDocument(width: 260, height: 220)
        doodle(
            bent,
            [
                CGPoint(x: 50.5, y: 60.5),
                CGPoint(x: 100.5, y: 90.5),
                CGPoint(x: 150.5, y: 70.5),
                CGPoint(x: 170.5, y: 120.5),
            ]
        )
        fixtures.append(
            (
                label: "the bent doodle",
                document: bent,
                id: try onlyEntity(bent, file: file, line: line)
            )
        )

        return fixtures
    }

    private func onlyEntity(
        _ document: PaintDocument,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> UUID {
        let ids = document.selectableEntityIDs
        try expectEqual(ids.count, 1, "entities on a single-entity fixture", file: file, line: line)
        guard let id = ids.first else {
            throw SmokeFailure(
                scenario: scenario,
                message: "the fixture holds no selectable entity",
                file: file,
                line: line
            )
        }
        return id
    }

    /// The local half of a selection: the entity's own untransformed ink
    /// rectangle, which an oriented frame is built from.
    private func requireLocalBounds(
        _ document: PaintDocument,
        _ id: UUID,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> CGRect {
        guard let bounds = document.entityLocalBounds(id) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "\(label): entityLocalBounds returned nil",
                file: file,
                line: line
            )
        }
        return bounds
    }

    /// The matrix half of a selection.
    private func requireTransform(
        _ document: PaintDocument,
        _ id: UUID,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> CGAffineTransform {
        guard let transform = document.entityTransform(id) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "\(label): entityTransform returned nil",
                file: file,
                line: line
            )
        }
        return transform
    }

    /// Ink measured under exactly `absolute`, which is what a replacement edit
    /// previews with.
    private func requireBounds(
        _ document: PaintDocument,
        _ id: UUID,
        using absolute: CGAffineTransform,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> CGRect {
        guard let bounds = document.entityBounds(id, using: absolute) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "\(label): entityBounds(using: \(absolute)) returned nil",
                file: file,
                line: line
            )
        }
        return bounds
    }

    private func requireBounds(
        _ document: PaintDocument,
        _ id: UUID,
        _ additional: CGAffineTransform,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> CGRect {
        guard let bounds = document.entityBounds(id, applying: additional) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "\(label): entityBounds(applying: \(additional)) returned nil",
                file: file,
                line: line
            )
        }
        return bounds
    }

    private func expectBounds(
        _ document: PaintDocument,
        _ id: UUID,
        _ expected: CGRect,
        _ label: String,
        epsilon: CGFloat = 1e-3,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let actual = try requireBounds(document, id, .identity, label, file: file, line: line)
        try expect(
            nearlyEqual(actual, expected, epsilon),
            "\(label): got \(actual), expected \(expected)",
            file: file,
            line: line
        )
    }

    private func expectEntity(
        _ document: PaintDocument,
        at point: CGPoint,
        tolerance: CGFloat,
        _ expected: UUID,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let picked = document.entityID(at: point, tolerance: tolerance)
        try expect(
            picked == expected,
            "\(label): clicking \(point) with tolerance \(tolerance) selected "
                + "\(picked.map(\.uuidString) ?? "nothing"), expected \(expected.uuidString)",
            file: file,
            line: line
        )
    }

    private func expectNoEntity(
        _ document: PaintDocument,
        at point: CGPoint,
        tolerance: CGFloat,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let picked = document.entityID(at: point, tolerance: tolerance)
        try expect(
            picked == nil,
            "\(label): clicking \(point) with tolerance \(tolerance) must select nothing, "
                + "selected \(picked.map(\.uuidString) ?? "nothing")",
            file: file,
            line: line
        )
    }

    /// True when the pixel is untouched page white.
    private func isPage(
        _ document: PaintDocument,
        _ x: Int,
        _ y: Int,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> Bool {
        let sample = try pixel(document, x, y, file: file, line: line)
        return sample.r >= 0.99 && sample.g >= 0.99 && sample.b >= 0.99 && sample.a >= 0.99
    }

    private func requireImage(
        _ image: CGImage?,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> CGImage {
        guard let image else {
            throw SmokeFailure(
                scenario: scenario,
                message: "\(label): no image was produced",
                file: file,
                line: line
            )
        }
        return image
    }

    /// A bitmap context laid out exactly like the document's own, so a preview
    /// composed here is comparable to the committed pixels byte for byte.
    private func canvasContext(
        _ width: Int,
        _ height: Int,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not allocate a \(width)×\(height) readback context",
                file: file,
                line: line
            )
        }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        context.interpolationQuality = .high
        return context
    }

    /// Whole-image readback: one draw into a known layout, then plain byte
    /// access, so per-pixel checks do not re-rasterise the image.
    private func raster(
        _ image: CGImage,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> Raster {
        let context = try canvasContext(image.width, image.height, file: file, line: line)
        guard let base = context.data else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not read back a \(image.width)×\(image.height) image",
                file: file,
                line: line
            )
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        let byteCount = context.bytesPerRow * image.height
        let bytes = [UInt8](
            UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self),
                count: byteCount
            )
        )
        return Raster(
            width: image.width,
            height: image.height,
            bytesPerRow: context.bytesPerRow,
            bytes: bytes
        )
    }

    /// How far two same-sized rasters disagree: the number of pixels whose
    /// channels differ by more than `slack`, and the worst single-channel
    /// difference. `ignored` names a document-space rectangle to skip, widened
    /// by a pixel so an antialiased fringe along its edge does not count.
    private func rasterDifference(
        _ lhs: Raster,
        _ rhs: Raster,
        ignoring ignored: CGRect = .null,
        slack: Int = 2,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> (differing: Int, worst: Int) {
        try expect(
            lhs.width == rhs.width && lhs.height == rhs.height,
            "raster sizes differ: \(lhs.width)×\(lhs.height) vs \(rhs.width)×\(rhs.height)",
            file: file,
            line: line
        )
        let skip = ignored.isNull ? ignored : ignored.insetBy(dx: -1, dy: -1)
        var differing = 0
        var worst = 0
        for row in 0..<lhs.height {
            // Raster rows count down from the top; document pixels count up.
            let y = Double(lhs.height - 1 - row) + 0.5
            let leftBase = row * lhs.bytesPerRow
            let rightBase = row * rhs.bytesPerRow
            for column in 0..<lhs.width {
                if skip.contains(CGPoint(x: Double(column) + 0.5, y: y)) { continue }
                var pixelDiffers = false
                for channel in 0..<4 {
                    let difference = abs(
                        Int(lhs.bytes[leftBase + column * 4 + channel])
                            - Int(rhs.bytes[rightBase + column * 4 + channel])
                    )
                    worst = max(worst, difference)
                    if difference > slack { pixelDiffers = true }
                }
                if pixelDiffers { differing += 1 }
            }
        }
        return (differing, worst)
    }

    private func expectImagePixel(
        _ raster: Raster,
        _ x: Int,
        _ y: Int,
        _ expected: NSColor,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let actual = raster.pixel(x, y)
        let want = try srgbComponents(expected, file: file, line: line)
        let close = abs(actual.r - want.r) <= channelSlack
            && abs(actual.g - want.g) <= channelSlack
            && abs(actual.b - want.b) <= channelSlack
            && abs(actual.a - want.a) <= channelSlack
        try expect(
            close,
            "\(label) at image pixel (\(x), \(y)): got \(format(actual)), "
                + "expected \(format(want))",
            file: file,
            line: line
        )
    }

    private func srgbComponents(
        _ color: NSColor,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> Pixel {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "colour has no sRGB representation",
                file: file,
                line: line
            )
        }
        return (
            Double(srgb.redComponent),
            Double(srgb.greenComponent),
            Double(srgb.blueComponent),
            Double(srgb.alphaComponent)
        )
    }

    // MARK: Shape helpers

    private func names(_ tools: [PaintTool]) -> String {
        "[" + tools.map(\.rawValue).joined(separator: ", ") + "]"
    }

    private func describe(_ shortcut: Character?) -> String {
        shortcut.map { "\"\($0)\"" } ?? "nil"
    }

    private func describe(_ width: CGFloat?) -> String {
        width.map { "\($0)" } ?? "nil"
    }

    private func requirePath(
        _ tool: PaintTool,
        from: CGPoint,
        to: CGPoint,
        constrained: Bool = false,
        label: String = "",
        file: String = #fileID,
        line: UInt = #line
    ) throws -> CGPath {
        guard let path = PaintShapeGeometry.path(
            tool: tool,
            from: from,
            to: to,
            constrained: constrained
        ) else {
            let suffix = label.isEmpty ? "" : " (\(label))"
            throw SmokeFailure(
                scenario: scenario,
                message: "\(tool.rawValue): PaintShapeGeometry produced no path\(suffix)",
                file: file,
                line: line
            )
        }
        return path
    }

    private func expectCorners(
        _ corners: [CGPoint],
        _ expected: [CGPoint],
        tolerance: CGFloat,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        for point in expected {
            try expect(
                corners.contains { nearlyEqual($0, point, tolerance) },
                "\(label) has no corner at \(point); corners are \(corners)",
                file: file,
                line: line
            )
        }
    }

    /// Counts pixels that differ from the white background, and how many took
    /// the full stroke colour, straight out of the document's rendered image.
    /// One bulk read keeps the per-shape sweep cheap.
    private func inkPixels(
        _ document: PaintDocument,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> (total: Int, dark: Int) {
        guard let image = document.cgImage else {
            throw SmokeFailure(
                scenario: scenario,
                message: "the document produced no image",
                file: file,
                line: line
            )
        }
        let width = image.width
        let height = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let base = context.data else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not read back a \(width)×\(height) bitmap",
                file: file,
                line: line
            )
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0
        var dark = 0
        for row in 0..<height {
            let bytes = base.advanced(by: row * context.bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let red = bytes[column * 4]
                let green = bytes[column * 4 + 1]
                let blue = bytes[column * 4 + 2]
                if red < 250 || green < 250 || blue < 250 { total += 1 }
                if red < 90 && green < 90 && blue < 90 { dark += 1 }
            }
        }
        return (total, dark)
    }

    private func resizeAcrossDimensions() throws {
        let document = PaintDocument(width: 10, height: 10)
        dab(document, at: CGPoint(x: 1.5, y: 1.5))
        try expectInk(document, 1, 1, "seed ink")

        // Resizing to the current size changes nothing and records no history.
        document.resize(width: 10, height: 10, background: .red)
        try expectSize(document, 10, 10)
        try expectPixel(document, 5, 5, .white, "no-op resize left the canvas alone")

        document.resize(width: 20, height: 20, background: .red)
        try expectSize(document, 20, 20)
        try expectInk(document, 1, 11, "content preserved anchored to the top-left")
        try expectPixel(document, 5, 15, .white, "old white area preserved")
        try expectPixel(document, 15, 5, .red, "new area painted with background")
        try expectPixel(document, 2, 3, .red, "new area below old content")
        try expectPixel(document, 19, 19, .red, "new area top-right")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        document.undo()
        try expectSize(document, 10, 10)
        try expectInk(document, 1, 1, "ink restored at the old dimensions")
        try expectPixel(document, 5, 5, .white, "old canvas restored")
        try expectFlags(document, undo: true, redo: true, dirty: true)

        document.redo()
        try expectSize(document, 20, 20)
        try expectInk(document, 1, 11, "ink after redoing the resize")
        try expectPixel(document, 15, 5, .red, "background after redoing the resize")

        // Two checkpoints total (stroke, resize): the no-op resize added none.
        document.undo()
        document.undo()
        try expectSize(document, 10, 10)
        try expectPixel(document, 1, 1, .white, "pristine canvas after unwinding history")
        try expectFlags(document, undo: false, redo: true, dirty: false)
    }

    private func pngSaveAndReopen() throws {
        let document = PaintDocument(width: 24, height: 18)
        dab(document, at: CGPoint(x: 3.5, y: 4.5))
        try expectInk(document, 3, 4, "ink before saving")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paint-model-smoke-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try document.savePNG(to: url)
        try expect(
            FileManager.default.fileExists(atPath: url.path),
            "savePNG did not create \(url.path)"
        )
        let bytes = [UInt8](try Data(contentsOf: url).prefix(8))
        try expect(
            bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "saved file is not a PNG; first bytes were \(bytes)"
        )
        // Saving clears dirty state without disturbing history.
        try expectFlags(document, undo: true, redo: false, dirty: false)

        dab(document, at: CGPoint(x: 20.5, y: 15.5))
        try expectFlags(document, undo: true, redo: false, dirty: true)

        try document.open(url: url)
        try expectSize(document, 24, 18)
        try expectFlags(document, undo: false, redo: false, dirty: false)
        try expectInk(document, 3, 4, "reopened ink")
        try expectPixel(document, 20, 15, .white, "pixel painted after the save is not in the file")
        try expectPixel(document, 23, 17, .white, "reopened background")
    }

    /// EXIF orientation 6 means the stored pixels must be rotated 90° clockwise
    /// for display, so a correct import swaps the source dimensions and lands
    /// the stored top-left pixel in the canvas' top-right corner. The fixture
    /// is generated with ImageIO here, then re-read, so the case is
    /// deterministic and needs no checked-in binary.
    private func orientedImageImport() throws {
        let storedWidth = 12
        let storedHeight = 8
        let marks: [(x: Int, y: Int, color: NSColor)] = [
            (0, 0, NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            (storedWidth - 1, 0, NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            (0, storedHeight - 1, NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            (storedWidth - 1, storedHeight - 1, NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)),
            (3, 2, NSColor(srgbRed: 0, green: 0.6, blue: 0.8, alpha: 1)),
        ]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paint-model-smoke-oriented-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeOrientedFixture(
            storedWidth: storedWidth,
            storedHeight: storedHeight,
            marks: marks,
            orientation: 6,
            to: url
        )

        // The fixture must genuinely carry the tag and the unrotated stored
        // size, otherwise the expectations below could pass for the wrong
        // reason.
        let fixture = try fixtureProperties(url)
        try expectEqual(fixture.orientation, 6, "fixture EXIF orientation")
        try expectEqual(fixture.width, storedWidth, "fixture stored pixel width")
        try expectEqual(fixture.height, storedHeight, "fixture stored pixel height")

        let document = PaintDocument(width: 5, height: 5)
        dab(document, at: CGPoint(x: 2.5, y: 2.5))
        try expectFlags(document, undo: true, redo: false, dirty: true)
        let revision = document.revision

        try document.open(url: url)

        // Swapped dimensions at full source resolution: neither the rotation
        // nor any downsampling shortcut may change the pixel count.
        try expectSize(document, storedHeight, storedWidth)
        try expect(document.revision > revision, "opening an image must bump revision")
        try expectFlags(document, undo: false, redo: false, dirty: false)

        for mark in marks {
            let target = orientationSixTarget(
                storedX: mark.x,
                storedY: mark.y,
                storedWidth: storedWidth,
                storedHeight: storedHeight
            )
            try expectPixel(
                document,
                target.x,
                target.y,
                mark.color,
                "stored pixel (\(mark.x), \(mark.y)) rotated into place"
            )
        }
        try expectPixel(document, 4, 5, .white, "unmarked pixel of the oriented import")
    }

    // MARK: Oriented fixture helpers

    /// Document-space location of a stored pixel once orientation 6 has been
    /// applied. Stored coordinates are top-left based like the image file;
    /// document coordinates count upward from the bottom-left, so a clockwise
    /// quarter turn maps stored (x, y) to (height - 1 - y, width - 1 - x).
    private func orientationSixTarget(
        storedX: Int,
        storedY: Int,
        storedWidth: Int,
        storedHeight: Int
    ) -> (x: Int, y: Int) {
        (x: storedHeight - 1 - storedY, y: storedWidth - 1 - storedX)
    }

    /// Writes a white bitmap with the given top-left based marks as a TIFF
    /// tagged with `orientation`. TIFF is lossless and carries the orientation
    /// tag natively, so the document reads back exactly these pixels.
    private func writeOrientedFixture(
        storedWidth: Int,
        storedHeight: Int,
        marks: [(x: Int, y: Int, color: NSColor)],
        orientation: Int,
        to url: URL,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: storedWidth,
            height: storedHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not allocate a \(storedWidth)×\(storedHeight) fixture bitmap",
                file: file,
                line: line
            )
        }

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: storedWidth, height: storedHeight))
        for mark in marks {
            guard let srgb = mark.color.usingColorSpace(.sRGB) else {
                throw SmokeFailure(
                    scenario: scenario,
                    message: "fixture mark colour has no sRGB representation",
                    file: file,
                    line: line
                )
            }
            context.setFillColor(
                CGColor(
                    srgbRed: srgb.redComponent,
                    green: srgb.greenComponent,
                    blue: srgb.blueComponent,
                    alpha: srgb.alphaComponent
                )
            )
            context.fill(
                CGRect(x: mark.x, y: storedHeight - 1 - mark.y, width: 1, height: 1)
            )
        }

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  "public.tiff" as CFString,
                  1,
                  nil
              )
        else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not create the fixture at \(url.path)",
                file: file,
                line: line
            )
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not finalise the fixture at \(url.path)",
                file: file,
                line: line
            )
        }
    }

    /// Reads the orientation tag and the *stored* pixel dimensions straight
    /// back out of the fixture file.
    private func fixtureProperties(
        _ url: URL,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> (orientation: Int, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not read image properties back from \(url.lastPathComponent)",
                file: file,
                line: line
            )
        }
        return (orientation: orientation, width: width, height: height)
    }

    private func newDocumentReset() throws {
        let document = PaintDocument(width: 40, height: 30)
        dab(document, at: CGPoint(x: 5.5, y: 5.5))
        document.floodFill(at: CGPoint(x: 20.5, y: 20.5), color: .red)
        document.undo()
        try expectFlags(document, undo: true, redo: true, dirty: true)

        let revision = document.revision
        document.newDocument(width: 640, height: 480)

        try expectSize(document, 640, 480)
        try expectFlags(document, undo: false, redo: false, dirty: false)
        try expect(document.revision > revision, "newDocument must bump revision")
        for point in [(0, 0), (639, 479), (320, 240), (5, 5)] {
            try expectPixel(document, point.0, point.1, .white, "new document canvas")
        }

        document.undo()
        try expectSize(document, 640, 480)
        try expectFlags(document, undo: false, redo: false, dirty: false)
    }
}

// MARK: - Entry point

@main
struct ModelSmoke {
    @MainActor
    static func main() {
        let run = ModelSmokeRun()
        do {
            try run.run()
        } catch let failure as SmokeFailure {
            FileHandle.standardError.write(Data("\(failure)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(
                Data("FAIL unexpected error: \(error)\n".utf8)
            )
            exit(1)
        }
        print("model smoke: OK — \(run.checkCount) checks passed")
    }
}
