/// Whole-document tools that create new PDFs and never modify their inputs.
public enum PdfTools {
    /// Combines documents, in order, into a new PDF.
    public static func merge(_ documents: [PdfSnapshot]) throws -> PdfSnapshot {
        if documents.isEmpty {
            throw ArgumentException("Choose at least one PDF to merge.", "documents")
        }

        return try PdfiumLibrary.withLock {
            let output = try PdfDocument.createNew()
            defer { output.dispose() }
            for snapshot in documents {
                let source = try PdfDocument.load(snapshot)
                defer { source.dispose() }
                try throwIfCopyingRestricted(source)
                if !(try output.importPages(source, try output.pageCount)) {
                    throw PdfException(.operationFailed, "A document couldn't be merged.")
                }
            }

            return try output.save()
        }
    }

    /// Copies the given pages, in the given order, into a new PDF.
    public static func extractPages(_ document: PdfSnapshot, _ pageIndices: [Int], _ password: String? = nil) throws -> PdfSnapshot {
        if pageIndices.isEmpty {
            throw ArgumentException("Choose at least one page.", "pageIndices")
        }

        return try PdfiumLibrary.withLock {
            let source = try PdfDocument.load(document, password)
            defer { source.dispose() }
            try throwIfCopyingRestricted(source)
            let pageCount = try source.pageCount
            for index in pageIndices {
                try ArgumentOutOfRangeException.throwIfNegative(index, "pageIndices")
                try ArgumentOutOfRangeException.throwIfGreaterThanOrEqual(index, pageCount, "pageIndices")
            }

            let output = try PdfDocument.createNew()
            defer { output.dispose() }
            if !(try output.importPages(source, 0, pageIndices)) {
                throw PdfException(.operationFailed, "The pages couldn't be extracted.")
            }

            return try output.save()
        }
    }

    // Copying pages into a new, unprotected PDF would strip the author's restrictions.
    private static func throwIfCopyingRestricted(_ source: PdfDocument) throws {
        if !(try source.allowsCopyingPages) {
            throw PdfException(.restricted, "The author of this PDF restricted copying its pages.")
        }
    }
}
