# Third-party notices

PaperKnife for Mac is licensed under the [Apache License 2.0](LICENSE). It ships with, or is
built from, the third-party software below. Their license and notice texts are in
[`third_party/`](third_party/), and the app carries them in
`PaperKnife.app/Contents/Resources/licenses/<component>/`.

## Shipped with the app

| Component | Version | License |
|---|---|---|
| [PDFium](https://pdfium.googlesource.com/pdfium/) (`Contents/Frameworks/libpdfium.dylib`) | chromium/8152 | BSD-3-Clause, with Foxit-contributed code under Apache-2.0 ([text](third_party/pdfium/licenses/pdfium.txt)) |
| [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) (the prebuilt universal PDFium, `pdfium-mac-univ.tgz`) | 8152 | MIT, for its build scripts ([text](third_party/pdfium/licenses/pdfium-binaries-LICENSE.txt)) |
| [AMS Type 1 Computer Modern fonts](https://ctan.org/pkg/amsfonts) (`cm*.pfb` in `Contents/Resources/Fonts/amsfonts`, unmodified; see [`third_party/amsfonts`](third_party/amsfonts/README.md)) | amsfonts 3.04 | SIL Open Font License 1.1 ([text](third_party/amsfonts/licenses/OFL.txt), [FAQ](third_party/amsfonts/licenses/OFL-FAQ.txt)); Copyright (c) 1997, 2009, American Mathematical Society |
| [Latin Modern Type 1 fonts](https://ctan.org/pkg/lm) (`lm*.pfb` in `Contents/Resources/Fonts/lm`, unmodified; see [`third_party/lm`](third_party/lm/README.md)) | 2.004 (lm 2.005) | GUST Font License 1.0, which is the LaTeX Project Public License 1.3c with a request to rename modified versions ([text](third_party/lm/licenses/GUST-FONT-LICENSE.TXT), [README](third_party/lm/licenses/README-Latin-Modern.TXT), [file list](third_party/lm/licenses/MANIFEST-Latin-Modern.TXT)); Copyright 2003–2009 B. Jackowski and J. M. Nowacki |
| [CM-Super Type 1 fonts](https://ctan.org/pkg/cm-super) (`sf*.pfb` in `Contents/Resources/Fonts/cm-super`, unmodified, a separate work; see [`third_party/cm-super`](third_party/cm-super/README.md)) | 0.3.4 | GNU General Public License, version 2 or later, with an exception for including the fonts in PostScript or PDF documents ([text](third_party/cm-super/licenses/COPYING), [exception](third_party/cm-super/licenses/README)); Copyright (c) 2001, 2002, 2008 Vladimir Volovich. Source: `fonts/ps-type1/cm-super` on [CTAN](https://ctan.org/pkg/cm-super) |
| [Adobe Glyph List](https://github.com/adobe-type-tools/agl-aglfn) (`Contents/Resources/Fonts/glyphlist.txt`, unmodified; see [`third_party/agl`](third_party/agl/README.md)) | 2.0 | BSD-3-Clause ([text](third_party/agl/licenses/LICENSE.txt)); Copyright 2002-2019 Adobe |

### Libraries compiled into PDFium

| Library | License | Text |
|---|---|---|
| Abseil | Apache-2.0 | [abseil.txt](third_party/pdfium/licenses/abseil.txt) |
| Anti-Grain Geometry 2.3 | AGG 2.3 license | [agg23.txt](third_party/pdfium/licenses/agg23.txt) |
| dragonbox | Apache-2.0 with LLVM exception, or Boost-1.0 | [Apache](third_party/pdfium/licenses/dragonbox-Apache2-LLVM.txt), [Boost](third_party/pdfium/licenses/dragonbox-Boost.txt) |
| fast_float | MIT | [fast_float.txt](third_party/pdfium/licenses/fast_float.txt) |
| FreeType | FreeType License (FTL) | [freetype.txt](third_party/pdfium/licenses/freetype.txt) |
| HarfBuzz | "Old MIT" | [harfbuzz.txt](third_party/pdfium/licenses/harfbuzz.txt) |
| Highway | Apache-2.0 | [highway.txt](third_party/pdfium/licenses/highway.txt) |
| ICU | Unicode License v3 | [icu.txt](third_party/pdfium/licenses/icu.txt) |
| Little CMS | MIT | [lcms.txt](third_party/pdfium/licenses/lcms.txt) |
| libjpeg-turbo | IJG and BSD-3-Clause | [libjpeg_turbo.md](third_party/pdfium/licenses/libjpeg_turbo.md), [libjpeg_turbo.ijg](third_party/pdfium/licenses/libjpeg_turbo.ijg) |
| OpenJPEG | BSD-2-Clause | [libopenjpeg.txt](third_party/pdfium/licenses/libopenjpeg.txt) |
| libpng | PNG Reference Library License v2 | [libpng.txt](third_party/pdfium/licenses/libpng.txt) |
| LLVM libc | Apache-2.0 with LLVM exception | [llvm-libc.txt](third_party/pdfium/licenses/llvm-libc.txt) |
| simdutf | MIT | [simdutf.txt](third_party/pdfium/licenses/simdutf.txt) |
| zlib | zlib License | [zlib.txt](third_party/pdfium/licenses/zlib.txt) |

Portions of this software are copyright © The FreeType Project (https://freetype.org). All rights reserved.

This software is based in part on the work of the Independent JPEG Group.

## Part of macOS

The app uses the Swift runtime, SwiftUI, AppKit and zlib (`/usr/lib/libz.1.dylib`) that come
with macOS; it doesn't ship copies of them.

## Used only to build and test

| Component | License |
|---|---|
| [Xcode](https://developer.apple.com/xcode/), with its Swift toolchain and XCTest | Apple's Xcode license; [Swift](https://swift.org) itself is Apache-2.0 with the Runtime Library Exception |

The [conformance corpus](conformance/README.md), copied from PaperKnife for Windows, stores PDFs
that PaperKnife's tests generated. They embed subsets or complete copies of the fonts above and
of DejaVu Sans (Bitstream Vera Fonts license, with DejaVu's changes in the public domain:
[text](conformance/licenses/DejaVu-LICENSE.txt)). No third-party documents are stored in this
repository.
