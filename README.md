# Paint for macOS

A native, open-source **Microsoft Paint–style drawing app for macOS**, built entirely with **SwiftUI, AppKit, and Core Graphics**.

Paint provides the familiar simplicity of classic MS Paint in a fast Mac desktop application: freehand drawing, brushes, an eraser, flood fill, text, colors, image resizing, 22 shapes, and editable canvas entities that can be selected, moved, resized, rotated, recolored, and undone.

> Looking for a lightweight native macOS drawing program, pixel editor, or MS Paint alternative for Mac? This project is designed for exactly that use case.

## Features

- Native macOS interface with a Paint-style ribbon, toolbox, palette, canvas, and status bar
- Pencil, Brush, Thick Brush, Eraser, Fill, Eyedropper, and Text tools
- 22 built-in shapes, including lines, curves, rectangles, ellipses, triangles, arrows, stars, callouts, a heart, and a lightning bolt
- Hand selection tool for editable shapes, lines, text, and freehand strokes
- Move, eight-handle resize, and Google Drawings–style rotation controls
- Hold **Shift** while rotating to snap to 15° increments
- Recolor the selected entity by choosing Color 1
- Undo and redo for drawing, transforms, recoloring, deletion, fill, clear, and canvas changes
- Primary and secondary colors with palette, color wells, eyedropper, and color swapping
- Zoom from 25% to 200%
- Resizable canvas up to 4096 × 4096 pixels
- Open PNG, JPEG, TIFF, BMP, GIF, HEIC, and other macOS-supported image formats
- Save and export as PNG
- Native keyboard shortcuts and custom tool cursors
- Retina/high-resolution display support

## Requirements

- macOS 13 Ventura or newer
- Swift 5.10 or newer
- Xcode Command Line Tools or Xcode

The application has no third-party runtime dependencies.

## Build and Run

Clone the repository and package the native app:

```bash
git clone https://github.com/orrgal1/mspaint.git
cd mspaint
bash build-app.sh
open Paint.app
```

To install it in Applications:

```bash
ditto Paint.app /Applications/Paint.app
open /Applications/Paint.app
```

The build script compiles an optimized release executable, assembles `Paint.app`, creates its `Info.plist`, and applies an ad-hoc local signature.

For a development build:

```bash
swift run Paint
```

## Using the Entity Selector

1. Draw a shape, line, text item, or freehand stroke.
2. Choose the **Select** hand tool.
3. Click the entity you want to edit.
4. Drag the entity to move it, use the eight handles to resize it, or drag the circular control to rotate it.
5. Choose a Color 1 swatch to recolor the selected entity.
6. Press **Delete** or **Backspace** to remove it, or **Escape** to cancel or deselect.

Entities remain editable during the current document session. Opening an image creates a raster background, and saving to PNG produces a standard flattened image.

## Keyboard Shortcuts

| Action | Shortcut |
| --- | --- |
| New image | `⌘N` |
| Open image | `⌘O` |
| Save | `⌘S` |
| Save As | `⇧⌘S` |
| Undo | `⌘Z` |
| Redo | `⇧⌘Z` |
| Resize image | `⌘R` |
| Clear image | `⇧⌘N` |
| Zoom in / out | `⌘+` / `⌘-` |
| Actual size | `⌘0` |
| Swap colors | `⇧⌘X` |
| Delete selected entity | `Delete` or `Backspace` |
| Cancel or deselect | `Escape` |
| Snap rotation | Hold `Shift` while rotating |

Drawing tools also expose single-key shortcuts through the app’s **Tools** menu.

## Testing

Run the behavioral model smoke suite:

```bash
bash test-model.sh
```

The test harness compiles the document model with AppKit and Core Graphics, then exercises drawing, shapes, text, entity selection and transforms, recoloring, flood fill, image operations, and undo/redo behavior.

Also verify the complete application build with:

```bash
swift build
```

## Architecture

| Component | Responsibility |
| --- | --- |
| SwiftUI | Window, ribbon, controls, palette, status bar, and application state |
| AppKit `NSView` | Native mouse, keyboard, cursor, and canvas interaction |
| Core Graphics | Bitmap rendering, paths, transforms, compositing, and PNG output |
| `PaintDocument` | Canvas bitmap, editable entities, file operations, and undo/redo history |
| `PaintEntity` | Selectable stroke, shape, and text geometry with color and affine transforms |

The project intentionally stays small and dependency-free: one Swift Package executable, a native app packaging script, and a framework-free behavioral test harness.

## Contributing

Issues and pull requests are welcome. When changing document or entity behavior, add an observable regression scenario to `Tests/ModelSmoke.swift` and run both verification commands before submitting.
