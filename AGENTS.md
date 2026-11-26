# Agent instructions

PaperKnife for Mac is an offline, open-source PDF editor in Swift: an AppKit and SwiftUI app
around the engine of [PaperKnife for Windows](https://github.com/shivam098/paperknife-windows),
ported line by line and checked against the shared conformance corpus.

**On a real Mac?** Start with [docs/HANDOFF-mac.md](docs/HANDOFF-mac.md): where the project stands, and how to finish testing and set the app up.

- Build and test: `scripts/fetch-pdfium.sh` (once), then `swift build` and `swift test` (62
  tests; one of them runs all 128 conformance cases). Build, check and pack the app:
  `scripts/package-app.sh 0.0.0-dev`.
- Engine code follows the Windows engine line by line ([docs/PORTING.md](docs/PORTING.md)). Don't
  edit `conformance/` here: it is copied from paperknife-windows
  ([CONTRIBUTING.md](CONTRIBUTING.md)).
- Commit as `shivam098 <39924466+shivam098@users.noreply.github.com>`.
- One PR per change, CI green and an independent review before merging (squash). PR descriptions start with the owner's Agent assessment block (docs/HANDOFF-mac.md, section 7).
