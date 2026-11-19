# Contributing to PaperKnife for Mac

PaperKnife for Mac runs the engine of [PaperKnife for Windows](https://github.com/shivam098/paperknife-windows),
ported to Swift, in a SwiftUI app. Every PaperKnife app follows the same rules
([product principles](https://github.com/shivam098/paperknife-windows/blob/main/docs/PRODUCT.md)):

1. **Nothing leaves the device.** No network calls, telemetry, analytics or advertising SDKs.
2. **Edits are verified** before they are kept, and refused with a clear reason otherwise.
3. **No faked edits**, such as shapes drawn over text.
4. **No documents we don't own** in the repository: tests generate their PDFs, and the
   conformance corpus stores only PDFs PaperKnife's tests generated.

## Getting started

You need a Mac with Xcode 16 or later. Then:

```bash
scripts/fetch-pdfium.sh   # downloads PDFium and checks its checksum (once)
swift build
swift test
```

The engine follows PaperKnife for Windows' engine line by line; [docs/PORTING.md](docs/PORTING.md)
lists the rules that keep its behavior the same. The tests run the
[conformance corpus](conformance/README.md): the cases PaperKnife for Windows records, which this
app must pass too. Don't change it here. Change the cases in paperknife-windows, then copy the
corpus with `pwsh scripts/sync-conformance.ps1 -Windows ../paperknife-windows`.

## The app

`scripts/package-app.sh 0.1.0` builds `artifacts/app/PaperKnife.app` for Apple silicon and
Intel, checks it with `PaperKnife --self-check` (PDFium loads from the app, and the fonts are in
it), then packs `PaperKnife-0.1.0-mac.dmg`, `PaperKnife-0.1.0-mac.zip` and `SHA256SUMS.txt` into
`artifacts/release/`. CI does the same on every push and runs the packed app on an older macOS
and on Intel.

The app icon is drawn by `scripts/make-icon.ps1` (PowerShell on Windows) into
`Resources/AppIcon.iconset`.

Never change `CFBundleIdentifier` in `Resources/Info.plist`: macOS uses it to recognize the app
across updates.

## Releasing

1. Write the release notes as `docs/releases/v<version>.md`.
2. Tag the commit and push the tag, for example `git tag v0.1.0` and `git push origin v0.1.0`.
3. The [Release workflow](.github/workflows/release.yml) runs CI with that version and publishes
   the disk image, the ZIP and their checksums as a GitHub release. Tags with a suffix, such as
   `v0.1.0-beta.1`, become pre-releases.

The app is signed ad hoc. Signing it with a Developer ID and notarizing it, so macOS opens it
without asking, needs an Apple Developer account. When a shipped dependency changes, update its
license texts in `third_party/` and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

By contributing, you agree that your contributions are licensed under the Apache License 2.0.
