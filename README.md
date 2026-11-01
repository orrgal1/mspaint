# Paint for macOS

A native, open-source **Microsoft Paint–style drawing app for macOS**, built entirely with **SwiftUI, AppKit, and Core Graphics**.

Paint provides the familiar simplicity of classic MS Paint in a fast Mac desktop application: freehand drawing, brushes, an eraser, flood fill, text, colors, image resizing, 22 shapes, a rectangular pixel selection with the classic opaque/transparent drop modes, and editable canvas entities that can be selected, moved, resized, rotated, recolored, and undone.

> Looking for a lightweight native macOS drawing program, pixel editor, or MS Paint alternative for Mac? This project is designed for exactly that use case.

## Features

- Native macOS interface with a Paint-style ribbon, toolbox, palette, canvas, and status bar
- Pencil, Brush, Thick Brush, Eraser, Fill, Eyedropper, and Text tools
- 22 built-in shapes, including lines, curves, rectangles, ellipses, triangles, arrows, stars, callouts, a heart, and a lightning bolt
- Rectangular Select tool: drag a marquee over any pixels and carry them as a floating selection
- Opaque and transparent selection drop modes — transparent leaves out every pixel matching Color 2, exactly like classic MS Paint
- Clipboard interop: Cut, Copy, Paste, Select All, and Paste From File; selections copy out as bitmaps any app can paste, and images from any app paste onto the canvas
- Hand selection tool for editable shapes, lines, text, and freehand strokes
- Move, eight-handle resize, and Google Drawings–style rotation controls
- Hold **Shift** while rotating to snap to 15° increments
- Recolor the selected entity by choosing Color 1
- Undo and redo for drawing, transforms, recoloring, deletion, selection moves, fill, clear, and canvas changes
- Primary and secondary colors with palette, color wells, eyedropper, and color swapping
- Zoom from 25% to 200%
- Resizable canvas up to 4096 × 4096 pixels, via the Resize dialog or the classic Paint corner and edge grips
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

## Using the Rectangular Selection

1. Choose the **Rectangular Select** tool and drag a rectangle over the pixels you want.
2. Drag inside the rectangle to carry the pixels as a floating selection; the vacated area fills with Color 2.
3. With the tool active, the ribbon shows the classic pair of drop modes:
   - **Opaque** drops every captured pixel.
   - **Transparent** treats pixels matching Color 2 as see-through, so the canvas shows through them — pick the color to drop with Color 2 (the eyedropper is the fastest way).
4. Drop the selection by clicking outside it, pressing **Escape**, or switching tools; the whole move is one undo step.
5. Press **Delete** or **Backspace** to fill the rectangle with Color 2 instead of moving it.
6. Use the Edit menu to **Cut** (⌘X, copy then delete), **Copy** (⌘C), **Paste** (⌘V), **Paste From File**, and **Select All** (⌘A, frames the whole canvas). A pasted image lands at the canvas top-left as a floating selection, and the Rectangular Select tool becomes active to carry it, as in classic Paint. The float never touches the canvas until it is dropped: what is underneath stays intact while you drag it into place, and the merge happens only when you click outside it, switch tools, or press Escape. Merged pixels land in front of the drawing they cover. When the pasted image is larger than the canvas, the app asks whether to expand the canvas to fit it or paste only the part that fits. Deleting a pasted selection that has not been dropped yet just discards it.

Any entity the rectangle covers is flattened into the bitmap when the pixels move, like classic Paint; entities clear of the rectangle stay editable.

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
| Cut selection | `⌘X` |
| Copy selection | `⌘C` |
| Paste | `⌘V` |
| Select all | `⌘A` |
| Delete selection or entity | `Delete` or `Backspace` |
| Cancel or deselect | `Escape` |
| Snap rotation | Hold `Shift` while rotating |

Drawing tools also expose single-key shortcuts through the app’s **Tools** menu.

## Testing

Run the behavioral model smoke suite:

```bash
bash test-model.sh
```

The test harness compiles the document model with AppKit and Core Graphics, then exercises drawing, shapes, text, entity selection and transforms, recoloring, flood fill, opaque and transparent selection moves, image pasting, image operations, and undo/redo behavior.

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
