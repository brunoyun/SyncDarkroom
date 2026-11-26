# SyncDarkroom

An iPad photo editor that works directly on a folder kept in sync by
[Synctrain](https://synctrain.app) (Syncthing). Editing never touches the original: every edit is
saved as a new `_edit` copy next to it, and its adjustable settings are stored in
`.syncdarkroom/` inside the folder, so they sync to your other devices too. Only three actions
change or remove existing files, each on request: Delete, Rotate 90° (rewrites just the
orientation tag) and Replace Original (asks for confirmation first).

**Features:** folder library with live refresh, drag-select and a month/year scrubber · share
photos to Mail, Messages, WhatsApp and other apps · world map of your photos with zoomable groups, a
density heat map and date filters · search by description (CLIP), metadata, objects and people,
with face naming and merging · folder statistics · finder for screenshots, photos of screens,
documents, duplicates and blurry shots (results cached, photos can be ignored) · light, color,
detail · tone curves ·
HSL color mixer · presets (built-in + your own, synced) · copy/paste settings · before/after
compare · crop (with pinch and twist), rotate, straighten, perspective · lossless 90° rotation ·
RAW develop (white balance, tone, noise, lens correction) · brush/linear/radial masks ·
heal/clone · Apple Pencil markup, text and shapes · batch edits · replace the original with an edit.

Requires iPadOS 17 or later.

## Install with AltStore

1. Install [AltStore](https://altstore.io) on your iPad.
2. In AltStore → **Browse** → **Sources** → **+**, add:

   ```
   https://raw.githubusercontent.com/<owner>/<repo>/main/altstore/source.json
   ```

3. Install **SyncDarkroom** from the source. AltStore signs it with your Apple ID; with a
   free Apple ID it must be refreshed every 7 days (AltStore does this automatically when
   AltServer/AltStore can reach your computer).
4. Open SyncDarkroom → **Choose Folder** → Browse → Synctrain → pick your photo folder.

You can also download `SyncDarkroom.ipa` from the
[latest release](../../releases/latest) and open it with AltStore.

## Publishing a release

The [Release workflow](.github/workflows/release.yml) runs on GitHub's `macos-26` runners:

```bash
git tag -a v0.2.0 -m "What's new in this version"
```

```bash
git push origin v0.2.0
```

It builds an unsigned IPA, attaches it to a GitHub release named after the tag, and commits
the new version to `altstore/source.json` on the default branch (the tag message becomes the
release notes shown in AltStore). You can also start it from the **Actions** tab with a
version number. The repository must be **public** so AltStore can read the source and IPA.

## Building locally

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
```

```bash
scripts/fetch_models.sh && xcodegen generate && open SyncDarkroom.xcodeproj
```

To build the same unsigned IPA the workflow produces (output: `build/SyncDarkroom.ipa`):

```bash
scripts/build_ipa.sh 0.1.0 1
```

Debug builds accept `-debugRootPath <folder>`, `-debugEditFile <name>` and `-debugTab
library|map|search` launch arguments for simulator testing without the folder picker. Apple
Vision doesn't run in the simulator, so object and face results only appear on a device.

## How files are stored

| Path | Contents |
| --- | --- |
| `IMG_1234_edit.jpg`, `IMG_1234-2_edit.jpg` | Edited copies (one per edit; never overwritten by a new edit) |
| `.syncdarkroom/<copy name>.json` | The recipe for that copy: settings, crop, masks, heals, markup |
| `.syncdarkroom/presets/*.json` | Your presets |
| `.syncdarkroom/cleanup-ignored.json` | Photos ignored in "Find Photos to Delete" |

Search analysis (objects, faces, CLIP embeddings), people names and place names are kept on the
iPad only (Application Support), not in the synced folder.

## On-device models

Search runs entirely on the iPad:

- **Smart search:** Apple's [MobileCLIP-S0](https://huggingface.co/apple/coreml-mobileclip)
  (Apple Sample Code License) with OpenAI's CLIP tokenizer (MIT). `scripts/fetch_models.sh`
  downloads them into `Models/` at a pinned revision and checks their SHA-256; they're bundled
  into the app but not kept in git.
- **Face recognition:** OpenCV Zoo's [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface)
  (Apache-2.0), converted to Core ML by `scripts/convert_sface.py`
  (`SyncDarkroom/Resources/ML/sface.mlpackage`). Faces are found and aligned with Apple Vision.
- **Objects, screens, documents, blur and near-duplicates:** Apple Vision.

See [SPEC.md](SPEC.md) for the design.
