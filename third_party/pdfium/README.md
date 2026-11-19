# PDFium

PaperKnife for Mac uses [PDFium](https://pdfium.googlesource.com/pdfium/) chromium/8152, the
universal (arm64 and x86_64) build without V8 or XFA from
[pdfium-binaries](https://github.com/bblanchon/pdfium-binaries), so JavaScript in PDFs never runs.
PaperKnife for Windows and Android use the same version.

- `scripts/fetch-pdfium.sh` downloads `pdfium-mac-univ.tgz`, checks its SHA-256 and puts the
  library in `mac/` (not committed). The app bundle carries it in `Contents/Frameworks`.
- `Sources/CPDFium/include` has the PDFium headers PaperKnife uses, unmodified from the same build.
- [`licenses/`](licenses/) holds the license texts of PDFium and the libraries compiled into it,
  as the build ships them, and the MIT license of pdfium-binaries
  (`pdfium-binaries-LICENSE.txt`).
