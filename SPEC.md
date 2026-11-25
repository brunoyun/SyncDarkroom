# SyncDarkroom — iPad photo editor for a Synctrain-synced folder

## Platform
- Native SwiftUI app, iPadOS 17+, Swift 6, project generated with XcodeGen.
- Rendering: Core Image (Metal-backed `CIContext`); RAW via `CIRAWFilter`.
- Distribution: AltStore source. GitHub Actions builds an **unsigned IPA** on each `v*` tag
  and attaches it to a GitHub Release; `altstore/source.json` lists versions (served raw or via GitHub Pages).
  AltStore re-signs on device.

## Folder access (Synctrain)
- User picks the Synctrain folder once via `UIDocumentPickerViewController` (folder mode).
- Store a **security-scoped bookmark**; resolve it at launch and refresh if stale.
- Use `NSFileCoordinator` for all reads/writes so Synctrain's File Provider sees changes.
- Watch the folder (`NSFilePresenter` + periodic rescan on foreground) to pick up files Synctrain pulls in.

## Library
- Thumbnail grid of the folder with subfolder navigation; auto-refresh on changes.
- Sort by date / name; filter by file type (JPEG, HEIC, PNG, RAW) and edited/unedited.
- EXIF panel (camera, lens, exposure, ISO, date, dimensions).
- Before/after compare: split slider and side-by-side.

## Editing
**Core**
- Light & color: exposure, contrast, highlights, shadows, whites, blacks, temperature, tint,
  saturation, vibrance, clarity, sharpen, noise reduction, vignette.
- Crop & geometry: aspect presets, free crop, rotate 90°, straighten, flip, perspective (vertical/horizontal).
- Tone curves (RGB + R/G/B) and HSL (8 color bands × hue/sat/lum).
- Presets: built-in looks, save user presets (stored in the folder so they sync), copy/paste settings.

**Advanced**
- RAW develop (DNG, CR2/CR3, NEF, ARW, RAF, ORF… whatever `CIRAWFilter` supports).
- Masks: brush (Apple Pencil pressure), linear and radial gradient; each mask carries its own adjustments.
- Healing / clone brush.
- Apple Pencil markup: PencilKit drawing, text, shapes as a top layer.
- Batch: apply a preset to a selection and export them all.
- Undo/redo throughout.

## Saving
- Never touch the original. Each edit writes its own copy next to it: `IMG_0001_edit.jpg`, then
  `IMG_0001-2_edit.jpg`, … (JPEG or HEIC, quality setting), with EXIF preserved. A new edit never overwrites
  an existing copy.
- Each copy's recipe is a sidecar `.syncdarkroom/<copy name>.json` (hidden folder inside the synced folder), so
  edits stay adjustable and sync between devices without conflicts. Opening an original starts a new edit;
  opening an edited copy reloads its recipe on top of the original and updates that copy.

## Status
All seven phases below are implemented (see README.md for install and release steps).

## Build phases
1. Project skeleton, folder picker + bookmark, library grid, viewer, EXIF.
2. Edit pipeline (recipe model → Core Image graph), light/color, crop/geometry, export copy + sidecar, undo.
3. Curves, HSL, presets, copy/paste, before/after.
4. RAW develop.
5. Masks, healing/clone, Pencil markup.
6. Batch editing.
7. GitHub Actions unsigned-IPA workflow + AltStore `source.json`.
