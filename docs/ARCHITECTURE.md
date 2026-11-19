# PaperKnife for Mac — architecture

PaperKnife for Mac follows the design of
[PaperKnife for Windows](https://github.com/shivam098/paperknife-windows/blob/main/docs/ARCHITECTURE.md),
whose engine it runs, ported to Swift.

## Structure

A Swift package (`Package.swift`, macOS 13 or later):

| Target | Responsibility |
|---|---|
| `CPDFium` | PDFium's C API. `scripts/fetch-pdfium.sh` downloads the pinned universal build (chromium/8152, without V8 or XFA) and checks its checksum; binaries aren't committed. |
| `CZlib` | The system's zlib, for Flate streams. |
| `PaperKnifeCore` | The engine, ported line by line from PaperKnife for Windows ([porting rules](PORTING.md)): PDF syntax, page content, fonts, the editing helpers, and `DocumentSession`, with its snapshots, undo history and verification. No UI code. |
| `PaperKnifeApp` | The app: an AppKit window (toolbar, menus, sheets, closing and quitting with unsaved changes) with SwiftUI views (pages, the page, the edit pane, the text on the page). `EditorModel` follows the Windows app's main window. |

`scripts/package-app.sh` builds the app for Apple silicon and Intel, joins them into one
universal app with PDFium in its Frameworks folder and the LaTeX fonts in its resources, signs it
ad hoc, and packs it into a disk image and a ZIP. `PaperKnife --self-check` checks a packed app
without opening a window; CI runs it on Apple silicon and Intel.

## Engine

- **PDFium** draws pages, reads their text and makes the edits PaperKnife can't make in a
  page's own drawing instructions. PDFium isn't thread-safe, so every call holds one lock, and
  the app makes its engine calls on one serial queue.
- **Edits are transactions**, as on Windows: change a copy, save it, read it again, verify it
  (character support, text round trip, object counts, pixel comparison of the page with the
  edited text hidden), then keep it or throw it away. Undo and redo restore earlier snapshots.
- **Behavior is the Windows engine's.** Every case of the shared
  [conformance corpus](../conformance/README.md) must give the same observations here: runs and
  their bounds, blockers, decoded content, fonts, results and messages.

## Files and privacy

- PaperKnife opens files the user picks or opens with it from Finder, and saves only with
  **Save As**: it writes a complete copy next to the destination, flushes it, then puts it in
  place, so a failed save leaves the destination as it was.
- The app has no networking code. It isn't sandboxed yet: the App Sandbox without the network
  entitlement, so that macOS itself blocks network access, is planned together with a Developer
  ID signature and notarization (see the [roadmap](ROADMAP.md)). Saving writes a temporary copy
  next to the destination, which needs more access than the sandbox gives to the chosen file.

## Testing

- `swift test` runs the engine's tests and the conformance corpus; CI runs them on macOS 15 and
  macOS 26.
- CI packs the app, runs its self-check on Apple silicon and Intel, and opens a PDF in it, clicks
  its text, types new text and checks that the edit is applied and verified.