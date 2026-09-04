import AppKit
import SwiftUI

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var session: PaintSession

    var body: some View {
        VStack(spacing: 0) {
            QuickAccessBar(session: session, document: session.document)
            Divider()
            RibbonBar(session: session)
            Divider()
            CanvasWorkspace(session: session, document: session.document)
            Divider()
            StatusBar(session: session, document: session.document)
        }
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle(session.windowTitle)
        .sheet(isPresented: $session.isPresentingResize) {
            ResizeSheet(session: session)
        }
    }
}

// MARK: - Quick access bar

private struct QuickAccessBar: View {
    @ObservedObject var session: PaintSession
    @ObservedObject var document: PaintDocument

    var body: some View {
        HStack(spacing: 4) {
            quickButton("New", "doc", shortcut: "⌘N") { session.newDocument() }
            quickButton("Open", "folder", shortcut: "⌘O") { session.openImage() }
            quickButton("Save", "square.and.arrow.down", shortcut: "⌘S") { session.save() }

            Divider().frame(height: 16).padding(.horizontal, 4)

            quickButton("Undo", "arrow.uturn.backward", shortcut: "⌘Z") { session.undo() }
                .disabled(!document.canUndo)
            quickButton("Redo", "arrow.uturn.forward", shortcut: "⇧⌘Z") { session.redo() }
                .disabled(!document.canRedo)

            Spacer(minLength: 12)

            Text(session.documentName)
                .font(.system(size: 12, weight: .semibold))
            if document.isDirty {
                Text("Edited")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.bar)
    }

    private func quickButton(
        _ title: String,
        _ symbol: String,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
    }
}

// MARK: - Ribbon

private struct RibbonBar: View {
    @ObservedObject var session: PaintSession

    private static let shapeSpacing: CGFloat = 4
    private static let shapeRows = [
        GridItem(.fixed(ToolButton.shapeSide), spacing: shapeSpacing),
        GridItem(.fixed(ToolButton.shapeSide), spacing: shapeSpacing),
    ]
    private static let shapeColumns = (PaintTool.shapeTools.count + 1) / 2
    /// The lazy grid is nested in a horizontal scroll view, so its footprint is
    /// stated explicitly instead of being inferred from the visible rect.
    private static let shapeGridSize = CGSize(
        width: CGFloat(shapeColumns) * ToolButton.shapeSide
            + CGFloat(max(shapeColumns - 1, 0)) * shapeSpacing,
        height: ToolButton.shapeSide * 2 + shapeSpacing
    )

    var body: some View {
        // The catalog is wider than the 760pt minimum window, so the scroller
        // stays visible to advertise the off-screen groups.
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                RibbonGroup(title: "Tools") {
                    HStack(spacing: 4) {
                        ForEach(PaintTool.drawingTools) { tool in
                            ToolButton(tool: tool, session: session)
                        }
                    }
                }
                ribbonDivider
                RibbonGroup(title: "Shapes") {
                    LazyHGrid(rows: Self.shapeRows, spacing: Self.shapeSpacing) {
                        ForEach(PaintTool.shapeTools) { tool in
                            ToolButton(tool: tool, session: session)
                        }
                    }
                    .frame(width: Self.shapeGridSize.width, height: Self.shapeGridSize.height)
                }
                ribbonDivider
                RibbonGroup(title: "Colors") {
                    ColorsControl(session: session)
                }
                ribbonDivider
                RibbonGroup(title: "Image") {
                    HStack(spacing: 4) {
                        RibbonActionButton(
                            title: "Resize",
                            symbol: "arrow.up.left.and.arrow.down.right",
                            help: "Resize the image (⌘R)"
                        ) { session.requestResize() }
                        RibbonActionButton(
                            title: "Clear",
                            symbol: "rectangle.dashed",
                            help: "Fill the whole image with Color 2 (⇧⌘N)"
                        ) { session.clearCanvas() }
                        RibbonActionButton(
                            title: "Export",
                            symbol: "square.and.arrow.up",
                            help: "Save a PNG copy (⇧⌘S)"
                        ) { session.saveAs() }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
        .frame(height: 108)
        .background(.bar)
    }

    private var ribbonDivider: some View {
        Divider().padding(.vertical, 2)
    }
}

private struct RibbonGroup<Content: View>: View {
    private let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 6) {
            content
                .frame(maxHeight: .infinity)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}

private struct ToolButton: View {
    /// Shape buttons are deliberately smaller than the drawing tools so the
    /// whole 22 shape catalog fits into two ribbon rows.
    static let shapeSide: CGFloat = 26
    private static let drawingSide: CGFloat = 34

    let tool: PaintTool
    /// Selection goes through the session so ribbon buttons and the Tools menu
    /// share one code path.
    @ObservedObject var session: PaintSession

    private var isSelected: Bool { session.tool == tool }
    private var side: CGFloat { tool.isShape ? Self.shapeSide : Self.drawingSide }
    private var tint: Color { isSelected ? Color.accentColor : Color.primary }

    var body: some View {
        Button {
            session.select(tool)
        } label: {
            glyph
                .frame(width: side, height: side)
                .overlay(alignment: .bottomTrailing) {
                    if tool == .thickBrush { thickBadge }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.22))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var glyph: some View {
        if tool.isShape {
            // SF Symbols has no coverage for most Paint shapes, so the button
            // draws the very geometry the tool will commit to the canvas.
            ShapeGlyph(tool: tool, tint: tint)
                .padding(5)
        } else {
            Image(systemName: tool.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(tint)
        }
    }

    /// Thick Brush wears the paintbrush symbol like Brush does, so the badge is
    /// what makes the two unmistakable side by side in the ribbon.
    private var thickBadge: some View {
        Text("XL")
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 2.5)
            .padding(.vertical, 0.5)
            .background(Capsule(style: .continuous).fill(Color.accentColor))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.85), lineWidth: 0.5))
            .padding(1)
            .accessibilityHidden(true)
    }

    private var helpText: String {
        guard let shortcut = tool.shortcut else { return tool.title }
        return "\(tool.title) (\(String(shortcut).uppercased()))"
    }
}

/// Miniature preview of a shape tool, stroked from the shared geometry so the
/// icon can never drift from what the tool draws.
private struct ShapeGlyph: View {
    let tool: PaintTool
    let tint: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let inset: CGFloat = 0.75
            guard let path = PaintShapeGeometry.path(
                tool: tool,
                from: CGPoint(x: inset, y: inset),
                to: CGPoint(x: size.width - inset, y: size.height - inset),
                constrained: false
            ) else { return }
            // Document space is y-up while Canvas is y-down, so the geometry is
            // flipped instead of being duplicated for icon use.
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            context.stroke(
                Path(path).applying(flip),
                with: .color(tint),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}

private struct RibbonActionButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(width: 54, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22))
        )
        .help(help)
    }
}

private struct ColorsControl: View {
    @ObservedObject var session: PaintSession

    private static let palette: [Color] = [
        0x000000, 0x7F7F7F, 0x880015, 0xED1C24, 0xFF7F27, 0xFFF200, 0x22B14C,
        0x00A2E8, 0x3F48CC, 0xA349A4,
        0xFFFFFF, 0xC3C3C3, 0xB97A57, 0xFFAEC9, 0xFFC90E, 0xEFE4B0, 0xB5E61D,
        0x99D9EA, 0x7092BE, 0xC8BFE7,
    ].map(Color.init(rgbHex:))

    var body: some View {
        HStack(spacing: 12) {
            colorWell(label: "Color 1", selection: primaryColorSelection)
            colorWell(label: "Color 2", selection: $session.secondaryColor)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(16), spacing: 3), count: 10),
                spacing: 3
            ) {
                ForEach(Array(Self.palette.enumerated()), id: \.offset) { entry in
                    SwatchButton(color: entry.element, session: session)
                }
            }
            .frame(width: 187)
        }
    }

    /// The well writes Color 1 the same way every other chooser does, so picking a
    /// colour there repaints the selected entity instead of only arming the next
    /// stroke.
    private var primaryColorSelection: Binding<Color> {
        Binding(
            get: { session.primaryColor },
            set: { session.setPrimaryColor($0) }
        )
    }

    private func colorWell(label: String, selection: Binding<Color>) -> some View {
        VStack(spacing: 3) {
            ColorPicker(label, selection: selection, supportsOpacity: false)
                .labelsHidden()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SwatchButton: View {
    let color: Color
    @ObservedObject var session: PaintSession

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35))
            )
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onTapGesture { session.setPrimaryColor(color) }
            .highPriorityGesture(
                TapGesture().modifiers(.option).onEnded { session.secondaryColor = color }
            )
            .contextMenu {
                Button("Set as Color 1") { session.setPrimaryColor(color) }
                Button("Set as Color 2") { session.secondaryColor = color }
            }
            .help("Click to set Color 1, ⌥-click to set Color 2")
    }
}

// MARK: - Workspace

private struct CanvasWorkspace: View {
    @ObservedObject var session: PaintSession
    @ObservedObject var document: PaintDocument

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                canvas
                    .padding(28)
                    .frame(
                        minWidth: proxy.size.width,
                        minHeight: proxy.size.height,
                        alignment: .center
                    )
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var canvas: some View {
        PaintCanvasRepresentable(session: session, document: document)
            .frame(
                width: max(document.canvasSize.width * session.zoom, 1),
                height: max(document.canvasSize.height * session.zoom, 1)
            )
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @ObservedObject var session: PaintSession
    @ObservedObject var document: PaintDocument

    var body: some View {
        HStack(spacing: 14) {
            Label(cursorText, systemImage: "scope")
                .frame(minWidth: 130, alignment: .leading)
            Divider().frame(height: 12)
            Label(sizeText, systemImage: "aspectratio")
                .frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: 8)
            zoomControl
        }
        .font(.system(size: 11).monospacedDigit())
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }

    private var cursorText: String {
        guard let point = session.cursorPosition else { return "—" }
        return "\(Int(point.x.rounded())), \(Int(point.y.rounded())) px"
    }

    private var sizeText: String {
        "\(Int(document.canvasSize.width.rounded())) × \(Int(document.canvasSize.height.rounded())) px"
    }

    private var zoomControl: some View {
        HStack(spacing: 6) {
            Button { session.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out (⌘−)")

            Slider(value: $session.zoom, in: PaintSession.zoomRange)
                .controlSize(.mini)
                .frame(width: 96)

            Button { session.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in (⌘+)")

            Button {
                session.resetZoom()
            } label: {
                Text("\(Int((session.zoom * 100).rounded()))%")
                    .frame(minWidth: 38, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .help("Click for actual size (⌘0)")
        }
    }
}

// MARK: - Resize sheet

private struct ResizeSheet: View {
    @ObservedObject var session: PaintSession

    @State private var width: Int
    @State private var height: Int
    @State private var maintainAspectRatio = true

    private let originalAspect: Double

    init(session: PaintSession) {
        self.session = session
        let size = session.document.canvasSize
        let currentWidth = max(Int(size.width.rounded()), 1)
        let currentHeight = max(Int(size.height.rounded()), 1)
        _width = State(initialValue: currentWidth)
        _height = State(initialValue: currentHeight)
        originalAspect = Double(currentHeight) / Double(currentWidth)
    }

    private var isValid: Bool {
        PaintSession.dimensionRange.contains(width) && PaintSession.dimensionRange.contains(height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize Image")
                .font(.headline)
            Text("New area is filled with white; existing pixels keep their position.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Width:")
                    dimensionField(value: $width, label: "Width")
                    Text("px").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Height:")
                    dimensionField(value: $height, label: "Height")
                    Text("px").foregroundStyle(.secondary)
                }
            }

            Toggle("Maintain aspect ratio", isOn: $maintainAspectRatio)

            if !isValid {
                Label(
                    "Enter a width and height between \(PaintSession.dimensionRange.lowerBound) and \(PaintSession.dimensionRange.upperBound) pixels.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { session.isPresentingResize = false }
                    .keyboardShortcut(.cancelAction)
                Button("Resize") { session.resizeCanvas(width: width, height: height) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: width) { newValue in
            guard maintainAspectRatio, PaintSession.dimensionRange.contains(newValue) else { return }
            let linked = Int((Double(newValue) * originalAspect).rounded())
            let clamped = min(max(linked, PaintSession.dimensionRange.lowerBound), PaintSession.dimensionRange.upperBound)
            if height != clamped { height = clamped }
        }
    }

    private func dimensionField(value: Binding<Int>, label: String) -> some View {
        TextField(label, value: value, format: .number)
            .labelsHidden()
            .frame(width: 92)
            .multilineTextAlignment(.trailing)
    }
}

// MARK: - Helpers

private extension Color {
    init(rgbHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
