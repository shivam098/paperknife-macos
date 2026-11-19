# PaperKnife for Mac

**An offline, open-source PDF editor for the Mac.** Part of [PaperKnife](https://github.com/shivam098/paperknife-windows):
your documents never leave your computer — no uploads, no account, no telemetry.

## Download

Download `PaperKnife-<version>-mac.dmg` from the
**[Releases page](https://github.com/shivam098/paperknife-macos/releases/latest)**, open it and drag
PaperKnife to Applications. It runs on macOS 13 (Ventura) or later, on Apple silicon and Intel Macs.

PaperKnife isn't signed with an Apple Developer ID yet, so the first time you open it, macOS says
it can't check it for malicious software. To open it anyway, once:

- on macOS 15 (Sequoia) or later, try to open it, then go to **System Settings > Privacy &
  Security** and select **Open Anyway**;
- on macOS 13 or 14, Control-click PaperKnife in Applications, choose **Open**, then **Open**.

To check a download, compare `shasum -a 256 <file>` with `SHA256SUMS.txt` on the release.

## What it does

The same promises as every PaperKnife app ([product principles](https://github.com/shivam098/paperknife-windows/blob/main/docs/PRODUCT.md)):

- **Edit text in place.** Click any text to select its line or table cell, type, and press Return.
  PaperKnife keeps the original font, size, position and color, and changes only the characters
  you changed.
- **Verified edits.** After every edit PaperKnife reads the result again and compares the whole
  page; if anything else would change, it refuses the edit and says why, instead of damaging the
  document.
- **Hard PDFs too:** PDFs that draw every letter on its own, PDFs saved from browsers, and LaTeX
  PDFs, where it can even add letters the PDF's fonts didn't contain.
- **Pages:** rotate, delete and add pages from another PDF. Undo and redo, and Save As.

It runs the engine of PaperKnife for Windows, ported line by line, and passes the same
[conformance tests](conformance/README.md), so it edits the same PDFs the same way. Later:
reordering, extracting and merging pages, annotations, forms and text recognition (see the
[roadmap](docs/ROADMAP.md)).

## Technology

| Area | Choice |
|---|---|
| Language and UI | Swift: an AppKit window with SwiftUI views, built as a universal app (Apple silicon and Intel) |
| PDF engine | PaperKnife's engine, ported from PaperKnife for Windows ([porting rules](docs/PORTING.md)), on [PDFium](https://pdfium.googlesource.com/pdfium/) from the [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) universal build |
| Tests | The shared [conformance corpus](conformance/README.md), run on macOS 15 and 26 in CI, which also opens and edits a PDF in the packaged app |
| Privacy | No networking code. The app isn't sandboxed yet; the App Sandbox without network access is planned together with notarization |

See the [architecture](docs/ARCHITECTURE.md). Building needs a Mac with Xcode or the Swift
toolchain; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

Ideas and design feedback are welcome in issues. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE).