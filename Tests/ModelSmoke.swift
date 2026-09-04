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
        try scenario("selection extraction") { try selectionExtraction() }
        try scenario("selection move") { try selectionMove() }
        try scenario("selection resize") { try selectionResize() }
        try scenario("selection rotation") { try selectionRotation() }
        try scenario("selection delete") { try selectionDelete() }
        try scenario("selection clipping") { try selectionClipping() }
        try scenario("selection no-ops") { try selectionNoOps() }
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

        document.beginStroke()
        document.drawStroke(
            from: CGPoint(x: 4, y: 4),
            to: CGPoint(x: 4, y: 4),
            tool: .brush,
            color: .black,
            secondaryColor: .white
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

        // The selector: a non-shape tool with its own name, symbol and key.
        try expect(
            !PaintTool.select.isShape,
            "select drags out a marquee, not a shape: isShape must be false"
        )
        try expect(
            PaintTool.select.title == "Select",
            "select title is \"\(PaintTool.select.title)\", expected \"Select\""
        )
        try expect(
            PaintTool.select.symbolName == "cursorarrow.rays",
            "select symbol is \"\(PaintTool.select.symbolName)\", expected \"cursorarrow.rays\""
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

    // MARK: Selection scenarios

    /// The four quadrant colours of the marker every selection scenario moves
    /// around, plus the unrelated mark outside it and the secondary colour the
    /// model must vacate source areas with. Deliberately asymmetric: a flip, a
    /// transpose or a rotation the wrong way round changes at least two of the
    /// four samples, so no such mistake can look like success.
    private static let markerBottomLeft = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private static let markerBottomRight = NSColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1)
    private static let markerTopRight = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    private static let markerTopLeft = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    private static let outsideMark = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private static let selectionBackground = NSColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1)

    /// Canvas and marker geometry shared by the selection scenarios. The
    /// oblong marker is 8×12 so a transform that swaps the axes cannot pass;
    /// the square one exists for the rotation cases, where a quarter turn must
    /// land back on its own footprint.
    private let selectionCanvas = (width: 48, height: 36)
    private let markerRect = CGRect(x: 4, y: 6, width: 8, height: 12)
    private let squareMarkerRect = CGRect(x: 6, y: 6, width: 12, height: 12)
    private let outsideRect = CGRect(x: 40, y: 2, width: 4, height: 4)

    /// Extraction is a pure read of exactly the requested pixels, in the
    /// orientation the image format stores them, and never touches the
    /// document.
    private func selectionExtraction() throws {
        let document = try markerDocument(rect: markerRect)
        let revision = document.revision

        let image = try requireSelection(document, markerRect, "marker selection")
        try expectEqual(image.width, Int(markerRect.width), "selection image width")
        try expectEqual(image.height, Int(markerRect.height), "selection image height")

        // Row 0 of a `CGImage` is its *top* row, while the document counts
        // upward from the bottom: the extracted corners must line up with the
        // document's, so a crop taken upside down fails here.
        let pixels = try raster(image)
        try expectImagePixel(pixels, 0, 0, ModelSmokeRun.markerTopLeft, "extracted top-left")
        try expectImagePixel(
            pixels,
            image.width - 1,
            0,
            ModelSmokeRun.markerTopRight,
            "extracted top-right"
        )
        try expectImagePixel(
            pixels,
            0,
            image.height - 1,
            ModelSmokeRun.markerBottomLeft,
            "extracted bottom-left"
        )
        try expectImagePixel(
            pixels,
            image.width - 1,
            image.height - 1,
            ModelSmokeRun.markerBottomRight,
            "extracted bottom-right"
        )
        // Interior sample: the quadrant boundaries sit where the document puts
        // them, not half a selection away.
        try expectImagePixel(
            pixels,
            image.width / 2,
            image.height / 2,
            ModelSmokeRun.markerBottomRight,
            "extracted interior"
        )

        // Read only: no pixels changed, no revision bump, no history entry.
        try expectEqual(document.revision, revision, "revision after selectionImage")
        try expectFlags(document, undo: false, redo: false, dirty: false)
        try expectMarker(document, in: markerRect, "document after extraction")

        // A marquee dragged up and to the left describes the same pixels.
        let flipped = CGRect(
            x: markerRect.maxX,
            y: markerRect.maxY,
            width: -markerRect.width,
            height: -markerRect.height
        )
        let dragged = try requireSelection(document, flipped, "selection dragged up and left")
        try expectEqual(dragged.width, Int(markerRect.width), "normalised selection width")
        try expectEqual(dragged.height, Int(markerRect.height), "normalised selection height")
        let draggedPixels = try raster(dragged)
        try expectImagePixel(
            draggedPixels,
            0,
            0,
            ModelSmokeRun.markerTopLeft,
            "normalised top-left"
        )
        try expectImagePixel(
            draggedPixels,
            dragged.width - 1,
            dragged.height - 1,
            ModelSmokeRun.markerBottomRight,
            "normalised bottom-right"
        )

        // Fractional drags snap outward to whole pixels, so a selection never
        // carries a partial pixel.
        let fractional = CGRect(
            x: markerRect.minX + 0.3,
            y: markerRect.minY + 0.2,
            width: markerRect.width - 0.6,
            height: markerRect.height - 0.5
        )
        let snapped = try requireSelection(document, fractional, "fractional selection")
        try expectEqual(snapped.width, Int(markerRect.width), "snapped selection width")
        try expectEqual(snapped.height, Int(markerRect.height), "snapped selection height")

        // Overhanging the canvas keeps only the pixels that exist.
        let overhang = CGRect(x: -6, y: -6, width: 12, height: 12)
        let clamped = try requireSelection(document, overhang, "selection overhanging a corner")
        try expectEqual(clamped.width, 6, "clamped selection width")
        try expectEqual(clamped.height, 6, "clamped selection height")

        // Nothing selectable at all: nil, never a zero-sized image.
        let rejected = [
            CGRect(x: markerRect.minX, y: markerRect.minY, width: 0, height: markerRect.height),
            CGRect(x: markerRect.minX, y: markerRect.minY, width: markerRect.width, height: 0),
            CGRect(x: 100, y: 100, width: 8, height: 12),
            CGRect(x: -20, y: 6, width: 8, height: 12),
            CGRect(x: CGFloat.nan, y: 6, width: 8, height: 12),
            CGRect(x: 4, y: 6, width: CGFloat.infinity, height: 12),
        ]
        for request in rejected {
            try expect(
                document.selectionImage(in: request) == nil,
                "selectionImage(in: \(request)) must be nil, not an empty image"
            )
        }
        try expectEqual(document.revision, revision, "revision after rejected selections")
        try expectFlags(document, undo: false, redo: false, dirty: false)
    }

    /// Moving a selection: the pixels arrive exact and upright, the vacated
    /// area takes the secondary colour, and the whole move is one undo entry.
    private func selectionMove() throws {
        let document = try markerDocument(rect: markerRect)
        let revision = document.revision
        let image = try requireSelection(document, markerRect, "marker selection")
        let destination = markerRect.offsetBy(dx: 24, dy: -4)

        document.transformSelection(
            image,
            from: markerRect,
            to: destination,
            rotation: 0,
            background: ModelSmokeRun.selectionBackground
        )

        try expect(document.revision > revision, "a committed move must bump revision")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        // Whole pixels, no scaling: the marker must arrive exact, corners
        // included, so a one-pixel or flipped redraw fails.
        try expectMarker(document, in: destination, "moved marker")
        try expectPixel(
            document,
            Int(destination.minX),
            Int(destination.minY),
            ModelSmokeRun.markerBottomLeft,
            "moved marker corner"
        )
        try expectPixel(
            document,
            Int(destination.maxX) - 1,
            Int(destination.maxY) - 1,
            ModelSmokeRun.markerTopRight,
            "moved marker opposite corner"
        )

        // Paint semantics: the whole vacated rectangle takes Color 2.
        for point in [(4, 6), (11, 6), (4, 17), (11, 17), (7, 11)] {
            try expectPixel(
                document,
                point.0,
                point.1,
                ModelSmokeRun.selectionBackground,
                "vacated source pixel"
            )
        }
        try expectPixel(document, 3, 9, .white, "page just left of the vacated area")
        try expectPixel(document, 12, 9, .white, "page just right of the vacated area")
        try expectPixel(document, 6, 5, .white, "page just below the vacated area")
        try expectPixel(document, 6, 18, .white, "page just above the vacated area")
        try expectPixel(
            document,
            Int(outsideRect.minX) + 1,
            Int(outsideRect.minY) + 1,
            ModelSmokeRun.outsideMark,
            "unrelated content outside the selection"
        )

        // One history entry for the whole move: a single undo is pristine.
        document.undo()
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expectMarker(document, in: markerRect, "marker restored by undo")
        try expectPixel(
            document,
            Int(destination.minX) + 1,
            Int(destination.minY) + 1,
            .white,
            "destination cleared by undo"
        )

        document.redo()
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expectMarker(document, in: destination, "marker restored by redo")
        try expectPixel(
            document,
            6,
            9,
            ModelSmokeRun.selectionBackground,
            "source stays vacated after redo"
        )

        // Overlapping move: the source is vacated *before* the draw, so the
        // pixels that land back inside it survive and only the remainder shows
        // background. Clearing afterwards would erase half the marker.
        let overlapping = try markerDocument(rect: markerRect)
        let selection = try requireSelection(overlapping, markerRect, "marker selection")
        let shifted = markerRect.offsetBy(dx: markerRect.width / 2, dy: 0)
        overlapping.transformSelection(
            selection,
            from: markerRect,
            to: shifted,
            rotation: 0,
            background: ModelSmokeRun.selectionBackground
        )
        try expectMarker(overlapping, in: shifted, "marker after an overlapping move")
        try expectPixel(
            overlapping,
            5,
            9,
            ModelSmokeRun.selectionBackground,
            "strip vacated by an overlapping move"
        )
        try expectFlags(overlapping, undo: true, redo: false, dirty: true)
    }

    /// Resizing a selection stretches it into the destination rectangle on both
    /// axes independently, as one undo entry.
    private func selectionResize() throws {
        let document = try markerDocument(rect: markerRect)
        let image = try requireSelection(document, markerRect, "marker selection")
        // Three times wider, twice as tall: a transform that preserves the
        // aspect ratio, ignores the destination size or swaps the axes fails.
        let destination = CGRect(
            x: 16,
            y: 8,
            width: markerRect.width * 3,
            height: markerRect.height * 2
        )

        document.transformSelection(
            image,
            from: markerRect,
            to: destination,
            rotation: 0,
            background: ModelSmokeRun.selectionBackground
        )
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expectMarker(document, in: destination, "stretched marker", exact: false)

        // The stretch fills the destination: a pixel in from every corner still
        // belongs to that corner's quadrant.
        try expectNearestColor(
            document,
            Int(destination.minX) + 1,
            Int(destination.minY) + 1,
            ModelSmokeRun.markerBottomLeft,
            "stretched bottom-left corner"
        )
        try expectNearestColor(
            document,
            Int(destination.maxX) - 2,
            Int(destination.minY) + 1,
            ModelSmokeRun.markerBottomRight,
            "stretched bottom-right corner"
        )
        try expectNearestColor(
            document,
            Int(destination.minX) + 1,
            Int(destination.maxY) - 2,
            ModelSmokeRun.markerTopLeft,
            "stretched top-left corner"
        )
        try expectNearestColor(
            document,
            Int(destination.maxX) - 2,
            Int(destination.maxY) - 2,
            ModelSmokeRun.markerTopRight,
            "stretched top-right corner"
        )

        // ...and nothing spilled past it.
        try expectPixel(document, 15, 20, .white, "page left of the stretched marker")
        try expectPixel(document, 41, 20, .white, "page right of the stretched marker")
        try expectPixel(document, 22, 7, .white, "page below the stretched marker")
        try expectPixel(document, 22, 33, .white, "page above the stretched marker")

        try expectPixel(
            document,
            6,
            9,
            ModelSmokeRun.selectionBackground,
            "vacated source after the stretch"
        )
        try expectPixel(
            document,
            10,
            15,
            ModelSmokeRun.selectionBackground,
            "vacated source after the stretch"
        )
        try expectPixel(
            document,
            41,
            3,
            ModelSmokeRun.outsideMark,
            "unrelated content after the stretch"
        )

        document.undo()
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expectMarker(document, in: markerRect, "marker restored by undo")
        try expectPixel(document, 22, 14, .white, "destination cleared by undo")

        document.redo()
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expectMarker(document, in: destination, "stretched marker after redo", exact: false)

        // Shrinking is the same operation the other way round.
        let shrunk = try markerDocument(rect: markerRect)
        let selection = try requireSelection(shrunk, markerRect, "marker selection")
        let small = CGRect(x: 20, y: 20, width: 4, height: 6)
        shrunk.transformSelection(
            selection,
            from: markerRect,
            to: small,
            rotation: 0,
            background: ModelSmokeRun.selectionBackground
        )
        try expectMarker(shrunk, in: small, "shrunk marker", exact: false)
        try expectPixel(
            shrunk,
            6,
            9,
            ModelSmokeRun.selectionBackground,
            "vacated source after shrinking"
        )
        try expectFlags(shrunk, undo: true, redo: false, dirty: true)
    }

    /// Rotation turns counterclockwise around the destination's centre, at any
    /// angle, as one undo entry.
    private func selectionRotation() throws {
        let document = try markerDocument(rect: squareMarkerRect)
        let revision = document.revision
        let image = try requireSelection(document, squareMarkerRect, "square marker selection")
        let destination = squareMarkerRect.offsetBy(dx: 24, dy: 12)

        // A quarter turn counterclockwise carries the marker's bottom-left
        // quadrant to the destination's bottom-right. That is what makes the
        // direction of rotation observable rather than assumed.
        document.transformSelection(
            image,
            from: squareMarkerRect,
            to: destination,
            rotation: .pi / 2,
            background: ModelSmokeRun.selectionBackground
        )
        try expect(document.revision > revision, "a committed rotation must bump revision")
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expectMarker(
            document,
            in: destination,
            "marker turned a quarter counterclockwise",
            rotatedBy: 1,
            exact: false
        )
        try expectPixel(
            document,
            9,
            9,
            ModelSmokeRun.selectionBackground,
            "vacated source after the rotation"
        )
        try expectPixel(
            document,
            15,
            15,
            ModelSmokeRun.selectionBackground,
            "vacated source after the rotation"
        )

        document.undo()
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expectMarker(document, in: squareMarkerRect, "marker restored by undo")
        try expectPixel(
            document,
            Int(destination.midX),
            Int(destination.midY),
            .white,
            "destination cleared by undo"
        )

        document.redo()
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expectMarker(
            document,
            in: destination,
            "marker after redoing the rotation",
            rotatedBy: 1,
            exact: false
        )

        // The opposite sign turns the other way: stated separately so a
        // transform that rotates clockwise cannot satisfy both scenarios.
        let clockwise = try markerDocument(rect: squareMarkerRect)
        let clockwiseImage = try requireSelection(
            clockwise,
            squareMarkerRect,
            "square marker selection"
        )
        clockwise.transformSelection(
            clockwiseImage,
            from: squareMarkerRect,
            to: destination,
            rotation: -.pi / 2,
            background: ModelSmokeRun.selectionBackground
        )
        try expectMarker(
            clockwise,
            in: destination,
            "marker turned a quarter clockwise",
            rotatedBy: -1,
            exact: false
        )

        // Arbitrary angles are not a special case. At 45° the destination's own
        // corners fall outside the rotated marker while its edge midpoints are
        // overshot, so the committed pixels follow the turned outline instead
        // of the axis-aligned box.
        let diagonal = try markerDocument(rect: squareMarkerRect)
        let diagonalImage = try requireSelection(
            diagonal,
            squareMarkerRect,
            "square marker selection"
        )
        diagonal.transformSelection(
            diagonalImage,
            from: squareMarkerRect,
            to: destination,
            rotation: .pi / 4,
            background: ModelSmokeRun.selectionBackground
        )
        try expectFlags(diagonal, undo: true, redo: false, dirty: true)
        try expect(
            !(try isPage(diagonal, 28, 24)),
            "a 45° rotation must paint past the destination rectangle's left edge"
        )
        try expectPixel(
            diagonal,
            Int(destination.minX),
            Int(destination.minY),
            .white,
            "the destination's own corner falls outside a 45° rotation"
        )

        diagonal.undo()
        try expectFlags(diagonal, undo: false, redo: true, dirty: false)
        try expectMarker(diagonal, in: squareMarkerRect, "marker restored after a 45° rotation")
        try expect(
            try isPage(diagonal, 28, 24),
            "one undo must clear every pixel a 45° rotation painted"
        )
    }

    /// Deleting a selection repaints exactly its pixels with the secondary
    /// colour, once, as one undo entry.
    private func selectionDelete() throws {
        let document = try markerDocument(rect: markerRect)
        let revision = document.revision

        document.deleteSelection(in: markerRect, background: ModelSmokeRun.selectionBackground)
        try expect(document.revision > revision, "deleting a selection must bump revision")
        try expectFlags(document, undo: true, redo: false, dirty: true)

        // Every pixel of the selection, edges and corners included.
        for x in Int(markerRect.minX)..<Int(markerRect.maxX) {
            for y in Int(markerRect.minY)..<Int(markerRect.maxY) {
                try expectPixel(
                    document,
                    x,
                    y,
                    ModelSmokeRun.selectionBackground,
                    "deleted selection pixel"
                )
            }
        }
        try expectPixel(document, 3, 9, .white, "page left of the deleted selection")
        try expectPixel(document, 12, 9, .white, "page right of the deleted selection")
        try expectPixel(document, 6, 5, .white, "page below the deleted selection")
        try expectPixel(document, 6, 18, .white, "page above the deleted selection")
        try expectPixel(
            document,
            41,
            3,
            ModelSmokeRun.outsideMark,
            "unrelated content after a delete"
        )

        document.undo()
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expectMarker(document, in: markerRect, "marker restored by undo")

        document.redo()
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expectPixel(
            document,
            6,
            9,
            ModelSmokeRun.selectionBackground,
            "selection deleted again by redo"
        )

        // Clamped: a delete overhanging the canvas clears the pixels that exist
        // and nothing else.
        let clamped = try markerDocument(rect: markerRect)
        clamped.deleteSelection(
            in: CGRect(x: -4, y: -4, width: 8, height: 8),
            background: ModelSmokeRun.selectionBackground
        )
        try expectFlags(clamped, undo: true, redo: false, dirty: true)
        try expectPixel(
            clamped,
            0,
            0,
            ModelSmokeRun.selectionBackground,
            "clamped delete clears the canvas corner"
        )
        try expectPixel(
            clamped,
            3,
            3,
            ModelSmokeRun.selectionBackground,
            "clamped delete clears up to its edge"
        )
        try expectPixel(clamped, 4, 4, .white, "clamped delete stops at its edge")
        try expectMarker(clamped, in: markerRect, "marker untouched by a clamped delete")

        // Unusable geometry deletes nothing and records nothing.
        let untouched = try markerDocument(rect: markerRect)
        let quiet = untouched.revision
        let rejected = [
            CGRect(x: 4, y: 6, width: 0, height: 12),
            CGRect(x: 4, y: 6, width: 8, height: 0),
            CGRect(x: 100, y: 100, width: 8, height: 12),
            CGRect(x: CGFloat.nan, y: 6, width: 8, height: 12),
            CGRect(x: 4, y: CGFloat.infinity, width: 8, height: 12),
        ]
        for request in rejected {
            untouched.deleteSelection(
                in: request,
                background: ModelSmokeRun.selectionBackground
            )
            try expectEqual(
                untouched.revision,
                quiet,
                "revision after deleteSelection(in: \(request))"
            )
            try expectFlags(untouched, undo: false, redo: false, dirty: false)
        }
        try expectMarker(untouched, in: markerRect, "marker after rejected deletes")
    }

    /// A destination hanging off the canvas paints what fits, clears the whole
    /// source and leaves the canvas dimensions alone.
    private func selectionClipping() throws {
        let document = try markerDocument(rect: markerRect)
        let image = try requireSelection(document, markerRect, "marker selection")
        // Dragged off the top-left: only the marker's bottom-right quadrant
        // still lands on the canvas.
        let destination = CGRect(
            x: -4,
            y: 30,
            width: markerRect.width,
            height: markerRect.height
        )

        document.transformSelection(
            image,
            from: markerRect,
            to: destination,
            rotation: 0,
            background: ModelSmokeRun.selectionBackground
        )
        try expectSize(document, selectionCanvas.width, selectionCanvas.height)
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expectPixel(
            document,
            0,
            30,
            ModelSmokeRun.markerBottomRight,
            "clipped marker on the canvas"
        )
        try expectPixel(
            document,
            3,
            35,
            ModelSmokeRun.markerBottomRight,
            "clipped marker at the canvas edge"
        )
        try expectPixel(document, 4, 33, .white, "page just beyond the clipped marker")
        try expectPixel(document, 1, 29, .white, "page just below the clipped marker")

        // The source is vacated in full even though most of the selection never
        // reached the canvas.
        try expectPixel(
            document,
            6,
            9,
            ModelSmokeRun.selectionBackground,
            "vacated source after a clipped move"
        )
        try expectPixel(
            document,
            11,
            17,
            ModelSmokeRun.selectionBackground,
            "vacated source after a clipped move"
        )

        document.undo()
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expectMarker(document, in: markerRect, "marker restored after a clipped move")
        try expectPixel(document, 0, 30, .white, "clipped pixels cleared by undo")

        document.redo()
        try expectFlags(document, undo: true, redo: false, dirty: true)
        try expectPixel(
            document,
            0,
            30,
            ModelSmokeRun.markerBottomRight,
            "clipped marker after redo"
        )

        // A source rectangle that is itself off canvas has nothing to vacate,
        // and must still draw what lands on the page.
        let offCanvas = try markerDocument(rect: markerRect)
        let selection = try requireSelection(offCanvas, markerRect, "marker selection")
        let landing = CGRect(x: 20, y: 20, width: markerRect.width, height: markerRect.height)
        offCanvas.transformSelection(
            selection,
            from: CGRect(x: 100, y: 100, width: markerRect.width, height: markerRect.height),
            to: landing,
            rotation: 0,
            background: ModelSmokeRun.selectionBackground
        )
        try expectFlags(offCanvas, undo: true, redo: false, dirty: true)
        try expectMarker(offCanvas, in: landing, "marker drawn from an off-canvas source")
        try expectMarker(offCanvas, in: markerRect, "marker left alone by an off-canvas source")
    }

    /// Requests that cannot change a pixel change neither the bitmap nor the
    /// history: no revision bump, no undo entry, no dirty flag.
    private func selectionNoOps() throws {
        let document = try markerDocument(rect: markerRect)
        let image = try requireSelection(document, markerRect, "marker selection")
        let revision = document.revision

        // Put back exactly where it came from, unrotated.
        document.transformSelection(
            image,
            from: markerRect,
            to: markerRect,
            rotation: 0,
            background: ModelSmokeRun.selectionBackground
        )
        try expectEqual(document.revision, revision, "revision after an identity transform")
        try expectFlags(document, undo: false, redo: false, dirty: false)
        try expectMarker(document, in: markerRect, "marker after an identity transform")

        // The same identity, reached from a rectangle dragged the other way and
        // an angle far below one pixel of movement.
        document.transformSelection(
            image,
            from: markerRect,
            to: CGRect(
                x: markerRect.maxX,
                y: markerRect.maxY,
                width: -markerRect.width,
                height: -markerRect.height
            ),
            rotation: 1e-9,
            background: ModelSmokeRun.selectionBackground
        )
        try expectEqual(
            document.revision,
            revision,
            "revision after a normalised identity transform"
        )
        try expectFlags(document, undo: false, redo: false, dirty: false)

        // Degenerate, non-finite and wholly off-canvas geometry.
        let rejected: [(source: CGRect, destination: CGRect, rotation: CGFloat)] = [
            (markerRect, CGRect(x: 20, y: 20, width: 0, height: 12), 0),
            (markerRect, CGRect(x: 20, y: 20, width: 8, height: 0), 0),
            (markerRect, CGRect(x: CGFloat.nan, y: 20, width: 8, height: 12), 0),
            (markerRect, CGRect(x: 20, y: 20, width: CGFloat.infinity, height: 12), 0),
            (
                CGRect(x: CGFloat.nan, y: 6, width: 8, height: 12),
                CGRect(x: 20, y: 20, width: 8, height: 12),
                0
            ),
            (markerRect, CGRect(x: 20, y: 20, width: 8, height: 12), CGFloat.nan),
            (
                CGRect(x: 100, y: 100, width: 8, height: 12),
                CGRect(x: 200, y: 200, width: 8, height: 12),
                0
            ),
        ]
        for request in rejected {
            document.transformSelection(
                image,
                from: request.source,
                to: request.destination,
                rotation: request.rotation,
                background: ModelSmokeRun.selectionBackground
            )
            try expectEqual(
                document.revision,
                revision,
                "revision after transformSelection(from: \(request.source), "
                    + "to: \(request.destination), rotation: \(request.rotation))"
            )
            try expectFlags(document, undo: false, redo: false, dirty: false)
        }
        try expectMarker(document, in: markerRect, "marker after every rejected transform")
        try expectPixel(
            document,
            41,
            3,
            ModelSmokeRun.outsideMark,
            "unrelated content after every rejected transform"
        )

        // A real transform after all those rejections still records exactly one
        // entry, so nothing above left a half-open operation behind.
        document.transformSelection(
            image,
            from: markerRect,
            to: markerRect.offsetBy(dx: 20, dy: 10),
            rotation: 0,
            background: ModelSmokeRun.selectionBackground
        )
        try expectFlags(document, undo: true, redo: false, dirty: true)
        document.undo()
        try expectFlags(document, undo: false, redo: true, dirty: false)
        try expectMarker(document, in: markerRect, "marker restored after the one committed move")
    }

    // MARK: Selection helpers

    /// A solid, axis-aligned block of a fixture bitmap, in bottom-left based
    /// document pixels.
    private struct Block {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let color: NSColor
    }

    /// Top-left based, unpremultiplied readback of a `CGImage`, so extracted
    /// selection pixels can be inspected in the orientation the image itself
    /// stores them.
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

    /// Every colour the selection scenarios paint with. Interpolated pixels —
    /// anything scaled or rotated — are judged by which of these they are
    /// closest to, which identifies the quadrant without pinning an exact
    /// blend.
    private var selectionPalette: [(color: NSColor, name: String)] {
        [
            (ModelSmokeRun.markerBottomLeft, "marker bottom-left"),
            (ModelSmokeRun.markerBottomRight, "marker bottom-right"),
            (ModelSmokeRun.markerTopRight, "marker top-right"),
            (ModelSmokeRun.markerTopLeft, "marker top-left"),
            (ModelSmokeRun.outsideMark, "outside mark"),
            (ModelSmokeRun.selectionBackground, "selection background"),
            (.white, "page white"),
        ]
    }

    /// A document holding the asymmetric four-quadrant marker inside `rect`, an
    /// unrelated black block outside it and white everywhere else.
    ///
    /// Built as an image file and opened, so the fixture pixels are exact and
    /// the document starts with empty history and a clean dirty flag: every
    /// selection scenario can then count history entries from zero.
    private func markerDocument(
        rect: CGRect,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> PaintDocument {
        let originX = Int(rect.minX)
        let originY = Int(rect.minY)
        let halfWidth = Int(rect.width) / 2
        let halfHeight = Int(rect.height) / 2
        let blocks = [
            Block(
                x: originX,
                y: originY,
                width: halfWidth,
                height: halfHeight,
                color: ModelSmokeRun.markerBottomLeft
            ),
            Block(
                x: originX + halfWidth,
                y: originY,
                width: halfWidth,
                height: halfHeight,
                color: ModelSmokeRun.markerBottomRight
            ),
            Block(
                x: originX + halfWidth,
                y: originY + halfHeight,
                width: halfWidth,
                height: halfHeight,
                color: ModelSmokeRun.markerTopRight
            ),
            Block(
                x: originX,
                y: originY + halfHeight,
                width: halfWidth,
                height: halfHeight,
                color: ModelSmokeRun.markerTopLeft
            ),
            Block(
                x: Int(outsideRect.minX),
                y: Int(outsideRect.minY),
                width: Int(outsideRect.width),
                height: Int(outsideRect.height),
                color: ModelSmokeRun.outsideMark
            ),
        ]

        let document = try blockDocument(
            width: selectionCanvas.width,
            height: selectionCanvas.height,
            blocks: blocks,
            file: file,
            line: line
        )
        // The fixture must really be what the scenarios assume, otherwise their
        // expectations could pass for the wrong reason.
        try expectSize(
            document,
            selectionCanvas.width,
            selectionCanvas.height,
            file: file,
            line: line
        )
        try expectFlags(document, undo: false, redo: false, dirty: false, file: file, line: line)
        try expectMarker(document, in: rect, "fixture marker", file: file, line: line)
        try expectPixel(
            document,
            Int(outsideRect.minX) + 1,
            Int(outsideRect.minY) + 1,
            ModelSmokeRun.outsideMark,
            "fixture mark outside the selection",
            file: file,
            line: line
        )
        return document
    }

    /// Writes `blocks` into a white bitmap, then opens it as a document. TIFF
    /// is lossless, so the document holds exactly these pixels, and `open`
    /// leaves it with no history and no unsaved changes.
    private func blockDocument(
        width: Int,
        height: Int,
        blocks: [Block],
        file: String = #fileID,
        line: UInt = #line
    ) throws -> PaintDocument {
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
                message: "could not allocate a \(width)×\(height) fixture bitmap",
                file: file,
                line: line
            )
        }

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for block in blocks {
            let want = try srgbComponents(block.color, file: file, line: line)
            context.setFillColor(
                CGColor(
                    srgbRed: CGFloat(want.r),
                    green: CGFloat(want.g),
                    blue: CGFloat(want.b),
                    alpha: CGFloat(want.a)
                )
            )
            context.fill(
                CGRect(x: block.x, y: block.y, width: block.width, height: block.height)
            )
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paint-model-smoke-selection-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
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
                message: "could not create the selection fixture at \(url.path)",
                file: file,
                line: line
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not finalise the selection fixture at \(url.path)",
                file: file,
                line: line
            )
        }

        let document = PaintDocument(width: width, height: height)
        try document.open(url: url)
        return document
    }

    /// The marker's oriented fingerprint inside `rect`: the four quadrant
    /// colours, sampled at the quadrant centres.
    ///
    /// `quarterTurns` counts counterclockwise quarter turns of the content, so
    /// a rotated selection is described by the same four colours in a shifted
    /// order. `exact` compares colours outright — right for whole-pixel moves —
    /// while a scaled or rotated marker is identified by proximity instead.
    private func expectMarker(
        _ document: PaintDocument,
        in rect: CGRect,
        _ label: String,
        rotatedBy quarterTurns: Int = 0,
        exact: Bool = true,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let colors = [
            ModelSmokeRun.markerBottomLeft,
            ModelSmokeRun.markerBottomRight,
            ModelSmokeRun.markerTopRight,
            ModelSmokeRun.markerTopLeft,
        ]
        let corners = ["bottom-left", "bottom-right", "top-right", "top-left"]
        let centres = [
            CGPoint(x: rect.minX + rect.width / 4, y: rect.minY + rect.height / 4),
            CGPoint(x: rect.maxX - rect.width / 4, y: rect.minY + rect.height / 4),
            CGPoint(x: rect.maxX - rect.width / 4, y: rect.maxY - rect.height / 4),
            CGPoint(x: rect.minX + rect.width / 4, y: rect.maxY - rect.height / 4),
        ]
        let turns = ((quarterTurns % 4) + 4) % 4

        for index in centres.indices {
            let x = Int(centres[index].x.rounded(.down))
            let y = Int(centres[index].y.rounded(.down))
            let expected = colors[(index - turns + 4) % 4]
            let corner = "\(label): \(corners[index]) quadrant"
            if exact {
                try expectPixel(document, x, y, expected, corner, file: file, line: line)
            } else {
                try expectNearestColor(document, x, y, expected, corner, file: file, line: line)
            }
        }
    }

    /// Asserts the pixel is closer to `expected` than to any other colour the
    /// selection scenarios paint with. Used where interpolation legitimately
    /// blends edges, so the quadrant is still identified while a flip, a wrong
    /// scale or a rotation the wrong way round still fails.
    private func expectNearestColor(
        _ document: PaintDocument,
        _ x: Int,
        _ y: Int,
        _ expected: NSColor,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws {
        let actual = try pixel(document, x, y, file: file, line: line)
        let want = try srgbComponents(expected, file: file, line: line)
        let expectedDistance = colorDistance(actual, want)

        var nearest = (name: "", distance: Double.infinity)
        for entry in selectionPalette {
            let candidate = try srgbComponents(entry.color, file: file, line: line)
            let distance = colorDistance(actual, candidate)
            if distance < nearest.distance {
                nearest = (entry.name, distance)
            }
        }

        try expect(
            expectedDistance <= nearest.distance + 1e-9,
            "\(label) at (\(x), \(y)): \(format(actual)) is nearest \(nearest.name) "
                + "(\(fixed(nearest.distance))), expected \(format(want)) "
                + "(\(fixed(expectedDistance)))",
            file: file,
            line: line
        )
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

    private func requireSelection(
        _ document: PaintDocument,
        _ rect: CGRect,
        _ label: String,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> CGImage {
        guard let image = document.selectionImage(in: rect) else {
            throw SmokeFailure(
                scenario: scenario,
                message: "\(label): selectionImage(in: \(rect)) returned nil",
                file: file,
                line: line
            )
        }
        return image
    }

    /// Whole-image readback: one draw into a known layout, then plain byte
    /// access, so per-pixel checks do not re-rasterise the image.
    private func raster(
        _ image: CGImage,
        file: String = #fileID,
        line: UInt = #line
    ) throws -> Raster {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let base = context.data else {
            throw SmokeFailure(
                scenario: scenario,
                message: "could not read back a \(image.width)×\(image.height) selection",
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

    private func colorDistance(_ lhs: Pixel, _ rhs: Pixel) -> Double {
        let red = lhs.r - rhs.r
        let green = lhs.g - rhs.g
        let blue = lhs.b - rhs.b
        return (red * red + green * green + blue * blue).squareRoot()
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
