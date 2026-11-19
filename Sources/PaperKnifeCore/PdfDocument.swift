import CPDFium

/// A PDF loaded into PDFium. Public members only read; mutations are internal so that every change
/// goes through `DocumentSession`, which verifies it before committing.
public final class PdfDocument {
    private let source: PdfSnapshot?
    private var pages = OrderedDictionary<Int, PdfPage>()
    private var handleValue: FPDF_DOCUMENT?

    private init(_ handle: FPDF_DOCUMENT, _ source: PdfSnapshot?) {
        handleValue = handle
        self.source = source
    }

    /// C# closes a document only when it is disposed; Swift has no `using`, so a document no
    /// longer referenced is closed too. Cached pages refer to their document, so this happens only
    /// after `dispose()` or while no page is cached.
    deinit {
        dispose()
    }

    public var pageCount: Int {
        get throws {
            try PdfiumLibrary.withLock {
                Int(FPDF_GetPageCount(try handle))
            }
        }
    }

    /// Number of digital signatures. Editing a signed PDF invalidates its signatures.
    public var signatureCount: Int {
        get throws {
            try PdfiumLibrary.withLock {
                max(0, Int(FPDF_GetSignatureCount(try handle)))
            }
        }
    }

    /// Whether the author allows changing page content (always true for unprotected PDFs).
    public var allowsContentChanges: Bool {
        get throws {
            let permissions = try self.permissions
            return (permissions & PdfiumNative.permissionModifyContents) != 0
        }
    }

    /// Whether the author allows inserting, rotating or deleting pages. The separate "assemble"
    /// permission only exists from security handler revision 3; before that, it needs "modify".
    public var allowsPageChanges: Bool {
        get throws {
            if try allowsContentChanges {
                return true
            }

            if try securityHandlerRevision < 3 {
                return false
            }

            let permissions = try self.permissions
            return (permissions & PdfiumNative.permissionAssemble) != 0
        }
    }

    /// Whether the author allows copying this document's pages into another PDF.
    public var allowsCopyingPages: Bool {
        get throws {
            let permissions = try self.permissions
            if (permissions & PdfiumNative.permissionCopy) == 0 {
                return false
            }

            return try allowsPageChanges
        }
    }

    var isDisposed: Bool { handleValue == nil }

    var handle: FPDF_DOCUMENT {
        get throws {
            try ObjectDisposedException.throwIf(handleValue == nil, self)
            return handleValue!
        }
    }

    private var permissions: UInt32 {
        get throws {
            try PdfiumLibrary.withLock {
                UInt32(truncatingIfNeeded: FPDF_GetDocPermissions(try handle))
            }
        }
    }

    private var securityHandlerRevision: Int {
        get throws {
            try PdfiumLibrary.withLock {
                Int(FPDF_GetSecurityHandlerRevision(try handle))
            }
        }
    }

    public static func load(_ snapshot: PdfSnapshot, _ password: String? = nil) throws -> PdfDocument {
        PdfiumLibrary.ensureInitialized()
        return try PdfiumLibrary.withLock {
            // The password as UTF-8 and NUL-terminated, as C# passes it.
            let loaded: FPDF_DOCUMENT?
            if let password {
                loaded = password.utf8CString.withUnsafeBufferPointer {
                    FPDF_LoadMemDocument64(snapshot.pointer, snapshot.length, $0.baseAddress)
                }
            } else {
                loaded = FPDF_LoadMemDocument64(snapshot.pointer, snapshot.length, nil)
            }

            guard let handle = loaded else {
                throw PdfException.fromLastError()
            }

            return PdfDocument(handle, snapshot)
        }
    }

    /// Returns the page at `index`. Pages are cached and owned by the document.
    public func getPage(_ index: Int) throws -> PdfPage {
        try PdfiumLibrary.withLock {
            try ArgumentOutOfRangeException.throwIfNegative(index, "index")
            try ArgumentOutOfRangeException.throwIfGreaterThanOrEqual(index, Int(FPDF_GetPageCount(try handle)), "index")
            if let cached = pages[index] {
                return cached
            }

            guard let pageHandle = FPDF_LoadPage(handleValue, Int32(index)) else {
                throw PdfException(.pageError, "Page \(index + 1) couldn't be read.")
            }

            let page = PdfPage(self, pageHandle, index)
            pages[index] = page
            return page
        }
    }

    /// Serializes the document, including pending page edits, to a new snapshot.
    public func save() throws -> PdfSnapshot {
        try PdfiumLibrary.withLock {
            let handle = try self.handle
            for page in pages.values {
                try page.commitContent()
            }

            let stream = FpdfFileWrite()
            let saved = withExtendedLifetime(stream) {
                FPDF_SaveAsCopy(handle, stream.pointer, FPDF_DWORD(FPDF_NO_INCREMENTAL))
            }

            if saved == 0 || stream.bytes.isEmpty {
                throw PdfException(.operationFailed, "The PDF couldn't be saved.")
            }

            return try PdfSnapshot.fromStream(stream)
        }
    }

    public func dispose() {
        PdfiumLibrary.withLock {
            guard let handleValue else {
                return
            }

            // Closing pages without committing their content can't fail.
            try? closeAllPages(commit: false)
            withExtendedLifetime(source) {
                FPDF_CloseDocument(handleValue)
            }

            self.handleValue = nil
        }
    }

    static func createNew() throws -> PdfDocument {
        PdfiumLibrary.ensureInitialized()
        return try PdfiumLibrary.withLock {
            guard let handle = FPDF_CreateNewDocument() else {
                throw PdfException(.operationFailed, "A new PDF couldn't be created.")
            }

            return PdfDocument(handle, nil)
        }
    }

    func rotatePage(_ index: Int, _ quarterTurns: Int) throws {
        try PdfiumLibrary.withLock {
            let page = try getPage(index)
            let rotation = try page.rotation

            // Wrapping only adds multiples of 4, as C#'s int arithmetic does.
            try page.setRotation((((rotation &+ quarterTurns) % 4) + 4) % 4)
        }
    }

    func deletePage(_ index: Int) throws {
        try PdfiumLibrary.withLock {
            try closeAllPages(commit: true)
            FPDFPage_Delete(try handle, Int32(truncatingIfNeeded: index))
        }
    }

    func movePage(_ fromIndex: Int, _ toIndex: Int) throws -> Bool {
        try PdfiumLibrary.withLock {
            try closeAllPages(commit: true)
            var index = Int32(truncatingIfNeeded: fromIndex)
            return FPDF_MovePages(try handle, &index, 1, Int32(truncatingIfNeeded: toIndex)) != 0
        }
    }

    func importPages(_ source: PdfDocument, _ insertAt: Int, _ pageIndices: [Int]? = nil) throws -> Bool {
        try PdfiumLibrary.withLock {
            try closeAllPages(commit: true)
            let indices: [Int32]
            if let pageIndices {
                indices = pageIndices.map { Int32(truncatingIfNeeded: $0) }
            } else {
                let count = try source.pageCount
                if count < 0 {
                    // Enumerable.Range's exception.
                    throw ArgumentOutOfRangeException("count")
                }

                indices = (0..<count).map { Int32($0) }
            }

            if indices.isEmpty {
                return true
            }

            let destination = try handle
            let sourceHandle = try source.handle
            let imported = indices.withUnsafeBufferPointer {
                FPDF_ImportPagesByIndex(destination, sourceHandle, $0.baseAddress, UInt($0.count), Int32(truncatingIfNeeded: insertAt))
            }

            return imported != 0
        }
    }

    private func closeAllPages(commit: Bool) throws {
        for page in pages.values {
            if commit {
                try page.commitContent()
            }

            page.close()
        }

        pages.removeAll()
    }
}
