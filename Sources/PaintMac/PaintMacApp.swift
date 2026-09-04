import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session

/// Owns the document plus every piece of UI state the editor needs, and performs
/// the native file / canvas actions that are driven from menus and the ribbon.
@MainActor
final class PaintSession: ObservableObject {
    let document: PaintDocument

    @Published var tool: PaintTool = .pencil
    @Published var primaryColor: Color = .black
    @Published var secondaryColor: Color = .white
    @Published var zoom: Double = 1
    @Published var cursorPosition: CGPoint?
    @Published var isPresentingResize = false
    @Published private(set) var fileURL: URL?

    static let zoomRange: ClosedRange<Double> = 0.25...2
    static let dimensionRange: ClosedRange<Int> = 1...4096

    init() {
        document = PaintDocument()
    }

    // MARK: Titles

    var documentName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var windowTitle: String {
        document.isDirty ? "\(documentName) — Edited" : documentName
    }

    // MARK: Tools, zoom

    func select(_ tool: PaintTool) {
        self.tool = tool
    }

    func zoomIn() { setZoom(zoom + 0.25) }
    func zoomOut() { setZoom(zoom - 0.25) }
    func resetZoom() { setZoom(1) }

    func setZoom(_ value: Double) {
        zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    // MARK: History

    func undo() { document.undo() }
    func redo() { document.redo() }

    // MARK: Canvas actions

    func clearCanvas() {
        document.clear(color: NSColor(secondaryColor))
    }

    func requestResize() {
        isPresentingResize = true
    }

    func resizeCanvas(width: Int, height: Int) {
        let clampedWidth = min(max(width, Self.dimensionRange.lowerBound), Self.dimensionRange.upperBound)
        let clampedHeight = min(max(height, Self.dimensionRange.lowerBound), Self.dimensionRange.upperBound)
        document.resize(width: clampedWidth, height: clampedHeight, background: .white)
        isPresentingResize = false
    }

    // MARK: File actions

    func newDocument() {
        guard confirmDiscardingChanges(because: "creating a new image") else { return }
        let size = document.canvasSize
        document.newDocument(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        fileURL = nil
        resetZoom()
    }

    func openImage() {
        guard confirmDiscardingChanges(because: "opening another image") else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.open(url: url)
            fileURL = url
            resetZoom()
        } catch {
            present(error, title: "Couldn’t Open “\(url.lastPathComponent)”")
        }
    }

    @discardableResult
    func save() -> Bool {
        if let url = fileURL, url.pathExtension.lowercased() == "png" {
            return writePNG(to: url)
        }
        return saveAs()
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save Image as PNG"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = documentName + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writePNG(to: url)
    }

    @discardableResult
    private func writePNG(to url: URL) -> Bool {
        do {
            try document.savePNG(to: url)
            fileURL = url
            return true
        } catch {
            present(error, title: "Couldn’t Save “\(url.lastPathComponent)”")
            return false
        }
    }

    /// Returns `true` when it is safe to throw away the current image, either
    /// because nothing is unsaved, because the user saved, or because the user
    /// explicitly chose to discard. `false` means the caller must abort.
    func confirmDiscardingChanges(because reason: String) -> Bool {
        guard document.isDirty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes to “\(documentName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them before \(reason)."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "d"
        alert.buttons[1].keyEquivalentModifierMask = [.command]
        alert.buttons[2].keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func present(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        let suggestion = (error as? LocalizedError)?.recoverySuggestion
        alert.informativeText = [error.localizedDescription, suggestion]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - App delegate

@MainActor
final class PaintAppDelegate: NSObject, NSApplicationDelegate {
    var session: PaintSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        return session.confirmDiscardingChanges(because: "quitting Paint") ? .terminateNow : .terminateCancel
    }
}

// MARK: - App

@main
struct PaintMacApp: App {
    @NSApplicationDelegateAdaptor(PaintAppDelegate.self) private var appDelegate
    @StateObject private var session = PaintSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .onAppear { appDelegate.session = session }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            PaintCommands(session: session, document: session.document)
        }
    }
}

// MARK: - Menu commands

private struct PaintCommands: Commands {
    @ObservedObject var session: PaintSession
    @ObservedObject var document: PaintDocument

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { session.newDocument() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { session.openImage() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { session.save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { session.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            // ⌘W is the standard Close Window shortcut on macOS, so Resize takes
            // the safe ⌘R slot instead of shadowing it.
            Button("Resize Image…") { session.requestResize() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Clear Image") { session.clearCanvas() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { session.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!document.canUndo)
            Button("Redo") { session.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!document.canRedo)
        }

        CommandMenu("Tools") {
            ForEach(PaintTool.drawingTools) { tool in
                Button(tool.title) { session.select(tool) }
            }
            Menu("Shapes") {
                ForEach(PaintTool.shapeTools) { tool in
                    Button(tool.title) { session.select(tool) }
                }
            }
            Divider()
            Button("Zoom In") { session.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { session.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { session.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Swap Colors") {
                let primary = session.primaryColor
                session.primaryColor = session.secondaryColor
                session.secondaryColor = primary
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
        }
    }
}
