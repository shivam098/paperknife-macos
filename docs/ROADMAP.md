# PaperKnife for Mac — roadmap

macOS development starts after Windows milestone M1, so it can reuse a proven editing model and
the shared test corpus. Each milestone ends with a notarized build.

## X0 — Foundation

- Xcode project for a sandboxed SwiftUI document-based app, Apache-2.0 notices and an
  acknowledgements window, CI on macOS that builds the app and runs tests.
- A script that downloads the pinned universal PDFium build, checks its checksum and packages it.
- Open PDFs from Finder, the Open dialog or drag and drop (including password-protected files);
  view them with PDFKit.
- A CI check that the app's entitlements don't include network access.

## X1 — Verified text editing

- Port the Windows editing model: immutable snapshots, transactional edits, verification
  (character support, round trip, object counts, pixel comparison), undo and redo through the
  standard Edit menu.
- Click text to select it, edit it, see a clear explanation when an edit is refused.
- Run the shared corpus and compare results with Windows.

## X2 — Pages

- Thumbnail sidebar with drag to reorder, rotate, delete, extract, merge and split, including
  dragging pages between documents.

## X3 — Annotations and forms

- Highlights, notes, shapes and form filling.

## X4 — Toolbox

- Compress, images to PDF and PDF to images; import from a scanner or iPhone with Continuity
  Camera.

## X5 — Text recognition

- Make scanned pages searchable with the Vision framework, on the device.

## Distribution

- Mac App Store, plus a notarized download for people who prefer not to use the store.
