#!/bin/bash
# Downloads the PDFium build PaperKnife uses into third_party/pdfium/mac and checks its checksum:
# chromium/8152 from https://github.com/bblanchon/pdfium-binaries, the universal (arm64 and x86_64)
# build without V8 or XFA, so JavaScript in PDFs never runs. PaperKnife for Windows and Android use
# the same PDFium version, so all apps read, edit and verify documents alike.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE="chromium/8152"
ASSET="pdfium-mac-univ.tgz"
SHA256="fc22d1d86246f4ec4e706cd5dc2b46737c7e33ad0f080fefe2e44e1011bb88f0"
DEST="third_party/pdfium/mac"

if [ -f "$DEST/lib/libpdfium.dylib" ] && [ "$(cat "$DEST/.sha256" 2>/dev/null)" = "$SHA256" ]; then
    echo "PDFium $RELEASE is already in $DEST."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 -o "$work/$ASSET" "https://github.com/bblanchon/pdfium-binaries/releases/download/${RELEASE//\//%2F}/$ASSET"
echo "$SHA256  $work/$ASSET" | shasum -a 256 -c -

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$work/$ASSET" -C "$DEST" lib VERSION
echo "$SHA256" > "$DEST/.sha256"
echo "PDFium $RELEASE is in $DEST."
