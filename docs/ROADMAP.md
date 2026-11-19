# PaperKnife for Mac — roadmap

## Done in 0.5.1

- A Swift package with the engine of PaperKnife for Windows, ported line by line, which passes
  every case of the shared conformance corpus.
- The app: open PDFs (also password-protected ones), select text by clicking it, edit or delete
  it with verification and a clear reason when an edit is refused, rotate, delete and add pages,
  undo and redo, Save As.
- A universal app for Apple silicon and Intel, packed as a disk image and a ZIP by CI from a tag.

## Next

- Developer ID signing and notarization, so macOS opens the app without a warning, and the App
  Sandbox without the network entitlement, so macOS itself keeps PaperKnife offline.
- A thumbnail sidebar with drag to reorder; extract, merge and split, including dragging pages
  between documents.

## Later

- Highlights, notes, shapes and form filling.
- Compress, images to PDF and PDF to images; import from a scanner or iPhone with Continuity
  Camera.
- Make scanned pages searchable with the Vision framework, on the device.
- The Mac App Store, alongside the download.