// Framework-free behavioural smoke test for the Paint document model.
//
// This toolchain (Apple CommandLineTools, no Xcode) ships neither XCTest nor
// Swift Testing, so the model is verified by compiling `PaintTypes.swift` and
// `PaintDocument.swift` together with this file into one throwaway executable.
// See `test-model.sh`. Every check asserts observable bitmap, history, dirty or
// file behaviour; the process exits non-zero on the first failed expectation.

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

// MARK: - Shape catalogue expectations

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

/// The freehand and sampling tools, in palette order. Thick Brush sits between
/// Brush and Eraser: spelled out literally so a dropped or misplaced entry
/// fails here rather than agreeing with whatever the enum happens to say.
private let expectedDrawingTools: [PaintTool] = [
    .pencil, .brush, .thickBrush, .eraser, .fill, .eyedropper, .text,
]

/// The floor every tool imposes on a requested stroke width. Thick Brush is
/// thick by construction; everything else may go down to a single pixel.
private let expectedMinimumStrokeWidths: [PaintTool: CGFloat] = [.thickBrush: 64]

/// The bare-key shortcuts that shipped before the catalogue grew. Every other
/// tool must report `nil` rather than claim a key of its own.
private let expectedShortcuts: [PaintTool: Character] = [
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

@MainActor
final class ModelSmokeRun {
    private var scenario = "<none>"
    private var checks = 0

    // MARK: Entry

    func run() throws {
        try scenario("initial document") { try initialDocument() }
        try scenario("brush stroke checkpoint") { try brushStrokeCheckpoint() }
        try scenario("thick brush stroke") { try thickBrushStroke() }
        try scenario("cancelled stroke") { try cancelledStroke() }
        try scenario("no-op fill") { try noOpFill() }
        try scenario("bounded flood fill") { try boundedFloodFill() }
        try scenario("colour pick") { try colourPick() }
        try scenario("shape catalogue") { try shapeCatalogue() }
        try scenario("shape geometry") { try shapeGeometry() }
        try scenario("shape shift constraints") { try shapeConstraints() }
        try scenario("shape silhouettes") { try shapeSilhouettes() }
        try scenario("shape rendering and history") { try shapeRendering() }
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
        color: NSColor = .black,
        lineWidth: CGFloat = 1
    ) {
        document.beginStroke()
        document.drawStroke(
            from: point,
            to: point,
            tool: tool,
            color: color,
            secondaryColor: .white,
            lineWidth: lineWidth
        )
        document.endStroke()
    }

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
                secondaryColor: .white,
                lineWidth: 6
            )
        }
        document.endStroke()

        try expect(document.revision > revisionBefore, "painting must bump revision")
        try expectInk(document, 20, 32, "brush ink")
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
    /// The stroke is requested at 4pt — the width an ordinary brush would honour
    /// literally — so this fails if the model ever stops enforcing the tool's
    /// own minimum for callers that reach `drawStroke` directly.
    private func thickBrushStroke() throws {
        let document = PaintDocument(width: 160, height: 160)
        let revisionBefore = document.revision
        let minimum = Int(PaintTool.thickBrush.minimumStrokeWidth)

        // One transaction, three drag segments along a horizontal line: history
        // must gain exactly one entry, and the painted band must be as tall as
        // the tool's minimum regardless of the requested width.
        document.beginStroke()
        for step in 0..<3 {
            let x = 48.0 + Double(step) * 8.0
            document.drawStroke(
                from: CGPoint(x: x, y: 80),
                to: CGPoint(x: x + 8, y: 80),
                tool: .thickBrush,
                color: .black,
                secondaryColor: .white,
                lineWidth: 4
            )
        }
        document.endStroke()

        try expect(document.revision > revisionBefore, "thick brush must bump revision")
        try expectInk(document, 60, 80, "thick brush core")
        try expectInk(document, 60, 80 - minimum / 2 + 1, "thick brush band, one edge")
        try expectInk(document, 60, 80 + minimum / 2 - 1, "thick brush band, other edge")

        let thickRun = try verticalInkRun(document, column: 60)
        try expect(
            thickRun >= minimum,
            "thick brush cross-section is \(thickRun)px of solid ink, expected at least \(minimum)px"
        )
        try expectPixel(document, 60, 4, .white, "canvas above the thick band")
        try expectPixel(document, 4, 80, .white, "canvas beside the thick band")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        // The same 4pt request through the ordinary brush stays thin, so the
        // width above comes from the tool and not from a global floor.
        let thin = PaintDocument(width: 160, height: 160)
        thin.beginStroke()
        for step in 0..<3 {
            let x = 48.0 + Double(step) * 8.0
            thin.drawStroke(
                from: CGPoint(x: x, y: 80),
                to: CGPoint(x: x + 8, y: 80),
                tool: .brush,
                color: .black,
                secondaryColor: .white,
                lineWidth: 4
            )
        }
        thin.endStroke()
        let thinRun = try verticalInkRun(thin, column: 60)
        try expect(
            thinRun >= 1 && thinRun <= 8,
            "ordinary 4pt brush cross-section is \(thinRun)px of solid ink, expected 1...8px"
        )

        // One checkpoint for the whole drag: a single undo reaches the pristine
        // bitmap, and redo brings the full-width band back.
        document.undo()
        try expectPixel(document, 60, 80, .white, "undone thick brush core")
        try expectEqual(
            try verticalInkRun(document, column: 60),
            0,
            "solid ink pixels remaining after undo"
        )
        try expectFlags(document, undo: false, redo: true, dirty: false)

        document.redo()
        try expectInk(document, 60, 80, "redone thick brush core")
        let redoneRun = try verticalInkRun(document, column: 60)
        try expect(
            redoneRun >= minimum,
            "redone thick brush cross-section is \(redoneRun)px, expected at least \(minimum)px"
        )
        try expectFlags(document, undo: true, redo: false, dirty: true)
    }

    private func cancelledStroke() throws {
        let document = PaintDocument(width: 32, height: 32)
        dab(document, at: CGPoint(x: 16, y: 16), tool: .brush, lineWidth: 8)
        try expectInk(document, 16, 16, "committed dab")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        document.beginStroke()
        document.drawStroke(
            from: CGPoint(x: 4, y: 4),
            to: CGPoint(x: 4, y: 4),
            tool: .brush,
            color: .black,
            secondaryColor: .white,
            lineWidth: 8
        )
        try expectInk(document, 4, 4, "in-flight ink before cancel")

        document.cancelStroke()
        try expectPixel(document, 4, 4, .white, "cancelled ink")
        try expectInk(document, 16, 16, "earlier committed dab survives cancel")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        // A cancelled stroke recorded nothing, so one undo reaches the pristine bitmap.
        document.undo()
        try expectPixel(document, 16, 16, .white, "pristine after single undo")
        try expectFlags(document, undo: false, redo: true, dirty: false)
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
        document.beginStroke()
        document.drawStroke(
            from: CGPoint(x: 10.5, y: 0),
            to: CGPoint(x: 10.5, y: 21),
            tool: .pencil,
            color: .black,
            secondaryColor: .white,
            lineWidth: 1
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
        dab(document, at: CGPoint(x: 16, y: 16), tool: .brush, color: ink, lineWidth: 10)

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

    // MARK: Shape scenarios

    /// The catalogue itself: exactly the promised shapes, in order, classified
    /// correctly, and without disturbing the shortcuts that already shipped.
    private func shapeCatalogue() throws {
        try expectEqual(PaintTool.shapeTools.count, 22, "shape catalogue size")
        try expect(
            PaintTool.shapeTools == expectedShapeCatalogue,
            "shapeTools is \(names(PaintTool.shapeTools)), expected \(names(expectedShapeCatalogue))"
        )
        try expectEqual(PaintTool.drawingTools.count, 7, "drawing tool count")
        try expect(
            PaintTool.drawingTools == expectedDrawingTools,
            "drawingTools is \(names(PaintTool.drawingTools)), "
                + "expected \(names(expectedDrawingTools))"
        )
        // Position, not just membership: Thick Brush must sit between Brush and
        // Eraser in the ribbon rather than being appended out of the way.
        try expectEqual(
            PaintTool.drawingTools.firstIndex(of: .thickBrush) ?? -1,
            2,
            "thickBrush position in drawingTools"
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

        for tool in PaintTool.allCases {
            let expected = expectedMinimumStrokeWidths[tool] ?? 1
            try expect(
                tool.minimumStrokeWidth == expected,
                "\(tool.rawValue) minimumStrokeWidth is \(tool.minimumStrokeWidth), "
                    + "expected \(expected)"
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
                lineWidth: 3,
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
                lineWidth: 3,
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
                lineWidth: 3,
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

    // MARK: Shape helpers

    private func names(_ tools: [PaintTool]) -> String {
        "[" + tools.map(\.rawValue).joined(separator: ", ") + "]"
    }

    private func describe(_ shortcut: Character?) -> String {
        shortcut.map { "\"\($0)\"" } ?? "nil"
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
