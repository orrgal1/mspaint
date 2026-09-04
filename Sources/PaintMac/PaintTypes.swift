import CoreGraphics
import Foundation

/// The drawing tools offered by the toolbox, in palette order.
///
/// Freehand and sampling tools come first, followed by the shape catalog in the
/// order the shape picker renders it. `PaintTool.shapeTools` and
/// `PaintTool.drawingTools` are the canonical groupings; UI code should prefer
/// them over re-deriving membership.
enum PaintTool: String, CaseIterable, Identifiable {
    // Drawing tools.
    case pencil
    case brush
    case thickBrush
    case eraser
    case fill
    case eyedropper
    case text

    // Shapes, in catalog order.
    case line
    case curve
    case rectangle
    case roundedRectangle
    case ellipse
    case triangle
    case rightTriangle
    case diamond
    case pentagon
    case hexagon
    case rightArrow
    case leftArrow
    case upArrow
    case downArrow
    case fourPointStar
    case fivePointStar
    case sixPointStar
    case rectangularCallout
    case roundedCallout
    case ovalCallout
    case heart
    case lightning

    var id: String { rawValue }

    /// The freehand and sampling tools, in palette order.
    static let drawingTools: [PaintTool] = [
        .pencil, .brush, .thickBrush, .eraser, .fill, .eyedropper, .text,
    ]

    /// The shape catalog, in the order the shape picker renders it.
    static let shapeTools: [PaintTool] = [
        .line, .curve, .rectangle, .roundedRectangle, .ellipse,
        .triangle, .rightTriangle, .diamond, .pentagon, .hexagon,
        .rightArrow, .leftArrow, .upArrow, .downArrow,
        .fourPointStar, .fivePointStar, .sixPointStar,
        .rectangularCallout, .roundedCallout, .ovalCallout,
        .heart, .lightning,
    ]

    /// True for every tool drawn by dragging out a shape from `PaintShapeGeometry`.
    var isShape: Bool {
        switch self {
        case .pencil, .brush, .thickBrush, .eraser, .fill, .eyedropper, .text:
            return false
        case .line, .curve, .rectangle, .roundedRectangle, .ellipse,
            .triangle, .rightTriangle, .diamond, .pentagon, .hexagon,
            .rightArrow, .leftArrow, .upArrow, .downArrow,
            .fourPointStar, .fivePointStar, .sixPointStar,
            .rectangularCallout, .roundedCallout, .ovalCallout,
            .heart, .lightning:
            return true
        }
    }

    /// Human readable name shown in the toolbox, shape picker and menus.
    var title: String {
        switch self {
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .thickBrush: return "Thick Brush"
        case .eraser: return "Eraser"
        case .fill: return "Fill With Color"
        case .eyedropper: return "Pick Color"
        case .text: return "Text"
        case .line: return "Line"
        case .curve: return "Curve"
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded Rectangle"
        case .ellipse: return "Ellipse"
        case .triangle: return "Triangle"
        case .rightTriangle: return "Right Triangle"
        case .diamond: return "Diamond"
        case .pentagon: return "Pentagon"
        case .hexagon: return "Hexagon"
        case .rightArrow: return "Right Arrow"
        case .leftArrow: return "Left Arrow"
        case .upArrow: return "Up Arrow"
        case .downArrow: return "Down Arrow"
        case .fourPointStar: return "Four-Point Star"
        case .fivePointStar: return "Five-Point Star"
        case .sixPointStar: return "Six-Point Star"
        case .rectangularCallout: return "Rectangular Callout"
        case .roundedCallout: return "Rounded Callout"
        case .ovalCallout: return "Oval Callout"
        case .heart: return "Heart"
        case .lightning: return "Lightning"
        }
    }

    /// SF Symbol used for the tool button. Shape buttons normally draw their own
    /// geometry preview; these names are the fallback and all exist on macOS 13.
    var symbolName: String {
        switch self {
        case .pencil: return "pencil"
        case .brush: return "paintbrush.pointed.fill"
        case .thickBrush: return "paintbrush.fill"
        case .eraser: return "eraser.fill"
        case .fill: return "drop.fill"
        case .eyedropper: return "eyedropper"
        case .text: return "textformat"
        case .line: return "line.diagonal"
        case .curve: return "scribble"
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "capsule"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .rightTriangle: return "triangle"
        case .diamond: return "diamond"
        case .pentagon: return "pentagon"
        case .hexagon: return "hexagon"
        case .rightArrow: return "arrow.right"
        case .leftArrow: return "arrow.left"
        case .upArrow: return "arrow.up"
        case .downArrow: return "arrow.down"
        case .fourPointStar: return "sparkle"
        case .fivePointStar: return "star"
        case .sixPointStar: return "staroflife"
        case .rectangularCallout: return "bubble.left"
        case .roundedCallout: return "message"
        case .ovalCallout: return "ellipsis.bubble"
        case .heart: return "heart"
        case .lightning: return "bolt"
        }
    }

    /// Single character keyboard shortcut, unique across all tools. The shapes
    /// added beyond the original three are reachable from the shape picker only,
    /// so they deliberately carry no bare-key shortcut, and Thick Brush leaves
    /// the letter keys to the tools that already own them.
    var shortcut: Character? {
        switch self {
        case .pencil: return "p"
        case .brush: return "b"
        case .thickBrush: return nil
        case .eraser: return "e"
        case .fill: return "f"
        case .eyedropper: return "k"
        case .text: return "t"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .curve, .roundedRectangle, .triangle, .rightTriangle, .diamond,
            .pentagon, .hexagon, .rightArrow, .leftArrow, .upArrow, .downArrow,
            .fourPointStar, .fivePointStar, .sixPointStar,
            .rectangularCallout, .roundedCallout, .ovalCallout,
            .heart, .lightning:
            return nil
        }
    }

    /// The one stroke width the tool always draws with. Width is a property of
    /// the tool itself, so there is nothing to configure: Pencil is a single
    /// pixel, Brush is the medium stroke, Thick Brush is the deliberately broad
    /// marker, Eraser matches Brush exactly, and text and shapes share a fine
    /// outline. Fill and Eyedropper never stroke, so their value is unused.
    var strokeWidth: CGFloat {
        switch self {
        case .pencil, .fill, .eyedropper: return 1
        case .brush, .eraser: return 16
        case .thickBrush: return 64
        case .text,
            .line, .curve, .rectangle, .roundedRectangle, .ellipse,
            .triangle, .rightTriangle, .diamond, .pentagon, .hexagon,
            .rightArrow, .leftArrow, .upArrow, .downArrow,
            .fourPointStar, .fivePointStar, .sixPointStar,
            .rectangularCallout, .roundedCallout, .ovalCallout,
            .heart, .lightning:
            return 4
        }
    }
}
