# OpenDicomViewer Help

A native macOS DICOM viewer with multi-panel layouts, MPR reconstruction, measurement annotations, and clinical-grade tools.

---

## Getting Started

### Opening Files

- **Open Button** -- Click the **Open** button in the sidebar to select a DICOM file (`.dcm`) or a folder containing DICOM files.
- **Drag & Drop** -- Drag a folder or DICOM file from Finder directly onto the viewer area. The app will scan for all DICOM series automatically.
- **Sidebar Series List** -- Once loaded, all discovered series appear in the sidebar. Click a series to display it in the active panel. Drag a series from the sidebar onto any panel to assign it.

### Sidebar

The sidebar shows all loaded series with thumbnails, descriptions, and image counts. A small grid icon next to each series indicates which panel(s) are displaying it. Click the sidebar toggle button to show/hide the sidebar.

---

## Panel Layouts

OpenDicomViewer supports up to four simultaneous panels for comparing series or viewing MPR reconstructions.

| Layout       | Key | Description                     |
|--------------|-----|---------------------------------|
| Single (1x1) | `1` | One panel (default)            |
| Side by Side (2x1) | `2` | Two panels, left and right |
| Stacked (1x2) | `3` | Two panels, top and bottom    |
| Quad (2x2)   | `4` | Four panels in a grid          |

Layout buttons are also available in the **floating toolbar** at the top-right of the viewer, and in the **Layout** menu bar.

### Active Panel

Click on a panel to make it the **active panel** (highlighted with a blue border). All keyboard shortcuts and tool actions apply to the active panel. Press **Tab** to cycle focus between panels.

### Fullscreen Panel

**Double-click** any panel to toggle fullscreen mode for that panel. Double-click again to return to the grid layout.

---

## Series Navigation

| Action             | Input                      |
|--------------------|----------------------------|
| Next image (slice) | `Down Arrow` / Scroll Down |
| Previous image     | `Up Arrow` / Scroll Up     |
| Next series        | `Right Arrow`              |
| Previous series    | `Left Arrow`               |
| Skip 10 images forward  | `Page Down`          |
| Skip 10 images backward | `Page Up`            |
| Jump to first image | `Home`                    |
| Jump to last image  | `End`                     |

A **scrollbar** on the right side of each panel provides visual position feedback and can be dragged for rapid navigation. Hovering over the scrollbar shows a thumbnail preview.

---

## Window / Level

Window Width (WW) and Window Center (WL) control the brightness and contrast of the displayed image.

| Action             | Input                                |
|--------------------|--------------------------------------|
| Adjust W/L         | **Right-click drag** on any panel    |
|                    | Or select the **W/L tool** and left-drag |
| Auto W/L           | Press `A`                            |
| ROI-based W/L      | Select **ROI W/L tool** (`O`), then draw a rectangle |

- **Right-drag horizontally** adjusts Window Width (contrast).
- **Right-drag vertically** adjusts Window Center (brightness).
- Sensitivity scales dynamically based on the current window width for fine or coarse control.
- The current WW/WL values are displayed at the bottom-left of each panel.

A **histogram** is shown in the bottom toolbar of each panel with a yellow indicator representing the current window range.

---

## Tools

Select a tool from the **floating tool palette** on the left side of the viewer, the **Tools** menu, or with keyboard shortcuts.

| Tool         | Key | Description                                       |
|--------------|-----|---------------------------------------------------|
| **Select**   | `V` | Default pointer — click to activate panels |
| **Pan**      | `P` | Left-click drag to pan the image                  |
| **W/L**      | `W` | Left-click drag to adjust Window/Level            |
| **Zoom**     | `Z` | Left-click drag up/down to zoom in/out, or scroll |
| **ROI W/L**  | `O` | Draw a rectangle; W/L auto-adjusts to the ROI     |
| **ROI Stats**| `S` | Draw a rectangle; displays Mean, SD, Min, Max, N  |
| **Ruler**    | `D` | Click two points to measure distance (mm or px)   |
| **Angle**    | `N` | Click three points to measure an angle (degrees)  |
| **Eraser**   | `E` | Click near an annotation to delete it              |

### Select Tool

The **Select** tool (`V`) is the default tool. Click a panel to make it the active panel.

### Modifier Overrides

Regardless of which tool is active, you can use modifier keys to temporarily access common actions:

| Input                        | Action                          |
|------------------------------|-------------------------------- |
| **Option/Control + Left-drag** | Pan the image                 |
| **Option/Control + Right-drag** | Adjust Window/Level          |
| **Option/Control + Scroll**    | Zoom in/out                   |

These overrides work with any active tool, so you don't need to switch tools for quick panning or zooming.

### Measurement Details

- **Ruler**: Click to set the start point, then click again to set the end point. If pixel spacing metadata is available, the distance is shown in millimeters; otherwise, in pixels. A dashed cyan preview line is shown while placing.
- **Angle**: Click three points -- the first arm endpoint, the vertex, and the second arm endpoint. The angle in degrees is displayed at the vertex. A dashed green preview is shown while placing.
- **ROI Stats**: Drag a rectangle over the region of interest. Statistics (Mean, Standard Deviation, Min, Max, pixel count) are computed from raw pixel data and displayed as a persistent annotation.
- **Eraser**: Click near any annotation (ruler, angle, or ROI stats) to remove it. The closest annotation within 15 pixels is deleted.

---

## Display Transforms

| Action                     | Key        | Description                              |
|----------------------------|------------|------------------------------------------|
| Invert (Negative)          | `I`        | Toggle image inversion                   |
| Rotate Clockwise 90deg     | `]` or `.` | Rotate the image 90 degrees clockwise    |
| Rotate Counter-Clockwise   | `[` or `,` | Rotate the image 90 degrees counter-clockwise |
| Flip Horizontal            | `H`        | Mirror the image left-to-right           |
| Flip Vertical              | *(menu)*   | Mirror the image top-to-bottom           |
| Fit to Window              | `F`        | Reset zoom/pan to fit the image in the panel |
| Reset View                 | `R`        | Reset zoom, pan, rotation, flip, and auto-adjust W/L |

Rotate and flip buttons are also available in each panel's **volume toolbar** (top-left corner).

---

## MPR (Multi-Planar Reconstruction)

When a volumetric series (CT/MR with sufficient slices) is loaded, additional display modes become available in the **volume toolbar** at the top-left of each panel:

| Mode          | Description                                             |
|---------------|---------------------------------------------------------|
| **Slice**     | Standard 2D axial slice view (default)                  |
| **Sagittal**  | Reconstructed sagittal plane (left-right cross-section) |
| **Coronal**   | Reconstructed coronal plane (front-back cross-section)  |
| **MIP**       | Maximum Intensity Projection                            |

### MIP Controls

When MIP mode is active, additional controls appear in the volume toolbar:

- **Projection Mode**: Choose between MIP (maximum), MinIP (minimum), or Average intensity projection.
- **Slab Thickness**: Adjust the number of slices included in the projection using the slider.
- Scroll through the volume to move the slab position.

### MPR Layout Shortcut

Use **Layout > MPR Layout** (Cmd+Shift+M) from the menu bar to automatically set up a quad layout with Axial, Sagittal, Coronal, and MIP views of the same series.

---

## Cross-Reference Lines

Press `X` or click the cross icon in the floating toolbar to toggle **cross-reference lines**. When enabled, each panel displays colored lines indicating the slice positions of other panels that share the same study. This is useful for correlating anatomy across axial, sagittal, and coronal views.

Cross-reference lines are only visible when multiple panels are active.

---

## DICOM Tags Inspector

Press `T` or click the tag icon in the floating toolbar to open the **DICOM Tags Inspector** sidebar. This displays all DICOM metadata tags (Tag ID, VR, Name, Value) for the image currently displayed in the active panel.

---

## Synchronized Scrolling

Press `L` or click the link icon in the floating toolbar to toggle **synchronized scrolling**. When enabled, scrolling through slices in one panel automatically scrolls all other panels that have series assigned.

---

## Group Selection

Hold **Shift** to reveal a selection overlay on each panel (multi-panel mode only). Click panels to toggle them for synchronized scrolling. Selected panels show an **orange overlay**; unselected panels show a dark overlay with instructional text. Release Shift to dismiss the overlays — selected panels retain their **orange border**.

| Action                 | Input              | Description                             |
|------------------------|--------------------|-----------------------------------------|
| Show selection overlay | Hold `Shift`       | Reveals clickable overlay on each panel |
| Toggle panel in group  | Click (while Shift held) | Add/remove a panel from the scroll group |
| Clear group selection  | `Escape`           | Remove all panels from the group        |

Group-selected panels scroll simultaneously. If only one panel remains selected, the group is automatically cleared.

---

## HU Readout

Move your mouse cursor over any image to see a real-time readout in the **top-right corner** of the panel:

- **HU value**: The raw pixel/Hounsfield Unit value at the cursor position
- **Pixel coordinates**: `[x, y]` position in image pixel space
- **Patient coordinates**: `x, y, z` position in patient coordinate space (when spatial metadata is available)

---

## Orientation Labels

When DICOM orientation metadata is available, anatomical direction labels are displayed on each edge of the image:

- **R** / **L** -- Right / Left
- **A** / **P** -- Anterior / Posterior
- **S** / **I** -- Superior / Inferior

These labels automatically update when you rotate or flip the image.

---

## Menu Bar Commands

### View Menu

| Command                          | Shortcut |
|----------------------------------|----------|
| Auto Window/Level                | `A`      |
| Invert                           | `I`      |
| Fit to Window                    | `F`      |
| Reset View                       | `R`      |
| Rotate Clockwise 90deg          | `]`      |
| Rotate Counter-Clockwise 90deg  | `[`      |
| Flip Horizontal                  | `H`      |
| Flip Vertical                    | --       |
| Cross-Reference Lines            | `X`      |
| DICOM Tags Inspector             | `T`      |

### Layout Menu

| Command                  | Shortcut      |
|--------------------------|---------------|
| Single Panel             | `Cmd+1`       |
| Side by Side             | `Cmd+2`       |
| Stacked                  | `Cmd+3`       |
| Four Panels              | `Cmd+4`       |
| MPR Layout               | `Cmd+Shift+M` |
| Synchronized Scrolling   | `Cmd+Shift+L` |

---

## Complete Keyboard Shortcuts Reference

### Navigation

| Shortcut     | Action                     |
|--------------|----------------------------|
| `Up`         | Previous image (slice)     |
| `Down`       | Next image (slice)         |
| `Left`       | Previous series            |
| `Right`      | Next series                |
| `Page Up`    | Skip 10 images backward    |
| `Page Down`  | Skip 10 images forward     |
| `Home`       | Jump to first image        |
| `End`        | Jump to last image         |
| `Scroll`     | Navigate slices            |
| `Tab`        | Cycle active panel         |

### Layout

| Shortcut     | Action                     |
|--------------|----------------------------|
| `1`          | Single panel (1x1)         |
| `2`          | Side by side (2x1)         |
| `3`          | Stacked (1x2)              |
| `4`          | Quad (2x2)                 |
| Double-click | Toggle panel fullscreen    |

### Tools

| Shortcut | Tool                        |
|----------|-----------------------------|
| `V`      | Select (default pointer)    |
| `P`      | Pan                         |
| `W`      | Window/Level                |
| `Z`      | Zoom                        |
| `O`      | ROI Window/Level            |
| `S`      | ROI Statistics              |
| `D`      | Ruler (distance)            |
| `N`      | Angle                       |
| `E`      | Eraser                      |

### Display

| Shortcut     | Action                            |
|--------------|-----------------------------------|
| `I`          | Invert (negative)                 |
| `]` or `.`   | Rotate clockwise 90deg           |
| `[` or `,`   | Rotate counter-clockwise 90deg   |
| `H`          | Flip horizontal                   |
| `F`          | Fit to window                     |
| `R`          | Reset view (zoom, pan, W/L)       |
| `A`          | Auto Window/Level                 |

### Overlays & Multi-Panel

| Shortcut     | Action                            |
|--------------|-----------------------------------|
| `T`          | Toggle DICOM Tags Inspector       |
| `X`          | Toggle cross-reference lines      |
| `L`          | Toggle synchronized scrolling     |
| `Shift` (hold) | Show group selection overlay     |
| `Escape`     | Clear group selection             |

### Mouse Actions

| Input                         | Action                          |
|-------------------------------|---------------------------------|
| Left-click                    | Activate panel / Tool action    |
| Left-drag                     | Tool-dependent (Pan, W/L, Zoom, ROI, drag-to-select, etc.) |
| Right-drag                    | Adjust Window/Level             |
| Scroll wheel                  | Navigate slices                 |
| Option/Control + Left-drag    | Pan (any tool)                  |
| Option/Control + Right-drag   | Adjust Window/Level (any tool)  |
| Option/Control + Scroll       | Zoom in/out                     |
| Shift (hold)                  | Show group selection overlay (click panels to toggle) |
| Double-click                  | Toggle fullscreen panel         |
| Drag from sidebar             | Assign series to panel          |
| Drag from Finder              | Open DICOM file/folder          |
