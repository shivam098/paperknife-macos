import CPDFium
import Foundation

enum PdfiumLibrary {
    /// PDFium keeps global state and is not thread-safe, so every native call in the process is
    /// serialized on this (reentrant) lock.
    static let sync = NSRecursiveLock()

    private static var initialized = false

    /// C#'s `lock (PdfiumLibrary.Sync) { ... }`: runs `body` while holding the lock.
    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        sync.lock()
        defer { sync.unlock() }
        return try body()
    }

    static func ensureInitialized() {
        withLock {
            if initialized {
                return
            }

            FPDF_InitLibrary()
            initialized = true
        }
    }
}
