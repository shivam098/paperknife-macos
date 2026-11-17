# Contributing to PaperKnife for Mac

Implementation hasn't started yet. Until it does, the most helpful contributions are design
feedback on the [roadmap](docs/ROADMAP.md) and [architecture plan](docs/ARCHITECTURE.md),
opened as issues.

Every PaperKnife app follows the same rules ([product principles](https://github.com/shivam098/paperknife-windows/blob/main/docs/PRODUCT.md)):

1. **Nothing leaves the device.** No network calls, telemetry, analytics or advertising SDKs.
2. **Edits are verified** before they are kept, and refused with a clear reason otherwise.
3. **No faked edits**, such as shapes drawn over text.
4. **No documents we don't own** in the repository; tests generate their own PDFs.

By contributing, you agree that your contributions are licensed under the Apache License 2.0.
