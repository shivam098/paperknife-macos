#!/bin/bash
# Builds PaperKnife.app for Apple silicon and Intel Macs, checks it, and packs it for a release:
#   artifacts/app/PaperKnife.app                     the app
#   artifacts/release/PaperKnife-<version>-mac.dmg   a disk image: open it, drag PaperKnife to Applications
#   artifacts/release/PaperKnife-<version>-mac.zip   the same app, zipped
#   artifacts/release/SHA256SUMS.txt
# The app is signed ad hoc, not with a Developer ID, so the first time it is opened macOS asks the
# user to allow it (see README.md).
#
# Usage: scripts/package-app.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-0.0.0-dev}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "Version '$version' isn't of the form 1.2.3 or 1.2.3-label." >&2
    exit 1
fi

scripts/fetch-pdfium.sh

app=artifacts/app/PaperKnife.app
release=artifacts/release
rm -rf artifacts/app "$release"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources" "$release"

# One build per architecture, joined into one universal executable.
executables=()
for arch in arm64 x86_64; do
    triple="$arch-apple-macosx13.0"
    swift build -c release --product PaperKnife --triple "$triple"
    executables+=("$(swift build -c release --triple "$triple" --show-bin-path)/PaperKnife")
done

executable="$app/Contents/MacOS/PaperKnife"
lipo -create "${executables[@]}" -output "$executable"
lipo -info "$executable"

# The build finds PDFium where fetch-pdfium.sh put it; the app finds it in Contents/Frameworks.
# Remove the run paths that point into this machine's file system.
run_paths() {
    otool -l "$executable" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' | sort -u
}
run_paths | while read -r path; do
    case "$path" in
        @*|/usr/lib/swift) ;;
        *) install_name_tool -delete_rpath "$path" "$executable" ;;
    esac
done

echo "Run paths:"
run_paths | sed 's/^/  /'
echo "Libraries:"
otool -L "$executable" | awk '/^\t/ { print $1 }' | sort -u | while read -r library; do
    case "$library" in
        /System/Library/*|/usr/lib/*|@rpath/libpdfium.dylib) echo "  $library" ;;
        *) echo "The app links $library, which other Macs don't have." >&2; exit 1 ;;
    esac
done

sed -e "s/@VERSION@/$version/g" -e "s/@BUILD@/${version%%-*}/g" Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" Resources/AppIcon.iconset
cp third_party/pdfium/mac/lib/libpdfium.dylib "$app/Contents/Frameworks/"

# The fonts PaperKnife draws new letters in TeX documents with, and the glyph names it reads.
fonts="$app/Contents/Resources/Fonts"
for family in amsfonts cm-super lm; do
    mkdir -p "$fonts/$family"
    cp third_party/$family/fonts/*.pfb "$fonts/$family/"
done
cp third_party/agl/glyphlist.txt "$fonts/"

licenses="$app/Contents/Resources/licenses"
mkdir -p "$licenses"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$licenses/"
for component in pdfium amsfonts lm cm-super agl; do
    mkdir -p "$licenses/$component"
    cp -R "third_party/$component/licenses/." "$licenses/$component/"
done

# Sign the library first, then the app, which seals everything in it.
codesign --force --sign - "$app/Contents/Frameworks/libpdfium.dylib"
codesign --force --sign - "$app"
codesign --verify --strict --verbose=2 "$app"

"$executable" --self-check

ditto -c -k --sequesterRsrc --keepParent "$app" "$release/PaperKnife-$version-mac.zip"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/PaperKnife.app"
ln -s /Applications "$staging/Applications"
# hdiutil sometimes fails with "Resource busy" on build machines; try again.
for attempt in 1 2 3; do
    if hdiutil create -volname PaperKnife -srcfolder "$staging" -format UDZO -ov "$release/PaperKnife-$version-mac.dmg"; then
        break
    elif [ "$attempt" -eq 3 ]; then
        exit 1
    fi
    sleep 10
done

(cd "$release" && shasum -a 256 PaperKnife-* > SHA256SUMS.txt)
cat "$release/SHA256SUMS.txt"
du -sh "$app" "$release"/PaperKnife-*
