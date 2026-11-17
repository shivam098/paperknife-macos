# PaperKnife for Mac

**An offline, open-source PDF editor for the Mac.** Part of [PaperKnife](https://github.com/shivam098/paperknife-windows):
your documents never leave your computer — no uploads, no account, no telemetry.

> **Status: planning.** No app code yet. Windows is the lead implementation; macOS development
> starts once the editing model and shared test corpus are proven there (Windows milestone M1).
> See the [roadmap](docs/ROADMAP.md) and [architecture plan](docs/ARCHITECTURE.md).

## Planned features

The same promises as every PaperKnife app ([product principles](https://github.com/shivam098/paperknife-windows/blob/main/docs/PRODUCT.md)):

- Edit existing text in place, keeping the original font, size, position and color.
- Verify every change before keeping it, and refuse with a clear reason instead of damaging the
  document.
- Organize pages: rotate, delete, reorder, merge and split, including dragging pages between
  windows.
- Later: annotations, form filling, compression and on-device text recognition.

## Planned technology

| Area | Choice |
|---|---|
| Language and UI | Swift, SwiftUI with AppKit where needed, a document-based app with menus, multiple windows and keyboard shortcuts |
| Viewing | PDFKit |
| Editing and verification | [PDFium](https://pdfium.googlesource.com/pdfium/) from the [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) universal macOS build |
| Privacy | App Sandbox without the network entitlement: macOS itself prevents the app from going online |
| Distribution | Mac App Store and a notarized download |

Building requires a Mac with Xcode.

## Contributing

Ideas and design feedback are welcome in issues. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE).
