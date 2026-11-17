# PaperKnife for Mac — architecture plan

This is a plan, not a description of existing code. It follows the design proven in
[PaperKnife for Windows](https://github.com/shivam098/paperknife-windows/blob/main/docs/ARCHITECTURE.md).

## Structure

| Part | Responsibility |
|---|---|
| `PaperKnifeCore` (Swift package) | Snapshots, the document session, verification rules and undo history, on top of a small Swift wrapper around the PDFium C API. No UI code. |
| `PaperKnife` (app target) | SwiftUI document-based app with AppKit where SwiftUI falls short (for example the PDFKit view and page drag and drop). |
| `third_party/pdfium` | Script that downloads the pinned universal PDFium build. Binaries aren't committed. |

## PDF engines

- **PDFKit** displays documents and thumbnails.
- **PDFium** (from [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries), the universal
  build without V8) performs edits and renders the pages used for verification. PDFKit can add
  annotations but can't change the text drawn on a page.
- All PDFium calls go through one Swift `actor`, which serializes them because PDFium isn't
  thread-safe.

Because PDFKit and PDFium can render the same page slightly differently, verification always
compares PDFium renderings with each other, never with what PDFKit shows.

## Editing model

The same transaction as on Windows: apply the change to a scratch copy, save it, reload it,
verify it (character support, text round trip, object counts per type, pixel comparison of the page with
the edited text hidden), then commit or discard. Undo and redo integrate with the window's
`UndoManager`, so the standard Edit menu and shortcuts work.

## Files and sandbox

- The app runs in the App Sandbox with access only to files the user picks
  (`com.apple.security.files.user-selected.read-write`).
- It has **no** `com.apple.security.network.client` entitlement, so macOS blocks all network
  access. CI checks the signed app's entitlements.
- The document architecture writes files atomically and supports versions and autosave in
  place; "Save As" keeps the original untouched.

## Testing

- Unit tests for `PaperKnifeCore` and the shared corpus run on CI, with results compared with the
  Windows app.

## Open questions

- Minimum macOS version (proposal: the two most recent major versions at launch).
- Whether `PaperKnifeCore` should live in its own repository so the iOS app can use the same
  Swift package, instead of each app keeping its own copy.
