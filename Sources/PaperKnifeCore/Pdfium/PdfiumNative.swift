import CPDFium
import Foundation

/// PDFium's `FPDF_FILEWRITE` at the start of a heap block, followed by a reference to this object,
/// which keeps the bytes PDFium writes, as C#'s MemoryStream does. PDFium only reads the struct's
/// two fields and hands the struct's pointer back to the callback, which finds this object after it.
final class FpdfFileWrite {
    /// Where the reference to this object follows the struct in the block.
    private static let ownerOffset: Int = {
        let alignment = MemoryLayout<UnsafeRawPointer>.alignment
        return (MemoryLayout<FPDF_FILEWRITE>.stride + alignment - 1) / alignment * alignment
    }()

    private static let writeBlock: @convention(c) (UnsafeMutablePointer<FPDF_FILEWRITE>?, UnsafeRawPointer?, UInt) -> Int32 = {
        writer, data, size in
        guard let writer else {
            return 0
        }

        let owner = UnsafeRawPointer(writer).load(fromByteOffset: FpdfFileWrite.ownerOffset, as: UnsafeRawPointer.self)
        return Unmanaged<FpdfFileWrite>.fromOpaque(owner).takeUnretainedValue().write(data, size) ? 1 : 0
    }

    private let block: UnsafeMutableRawPointer

    /// What PDFium has written so far.
    private(set) var bytes: [UInt8] = []

    init() {
        block = UnsafeMutableRawPointer.allocate(
            byteCount: FpdfFileWrite.ownerOffset + MemoryLayout<UnsafeRawPointer>.size,
            alignment: Swift.max(MemoryLayout<FPDF_FILEWRITE>.alignment, MemoryLayout<UnsafeRawPointer>.alignment))
        block.initializeMemory(as: FPDF_FILEWRITE.self, repeating: FPDF_FILEWRITE(version: 1, WriteBlock: FpdfFileWrite.writeBlock), count: 1)
        block.storeBytes(
            of: UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()), toByteOffset: FpdfFileWrite.ownerOffset, as: UnsafeRawPointer.self)
    }

    deinit {
        block.deallocate()
    }

    /// The struct to hand to PDFium, valid while this object exists.
    var pointer: UnsafeMutablePointer<FPDF_FILEWRITE> { block.assumingMemoryBound(to: FPDF_FILEWRITE.self) }

    /// C#'s `stream.Write`. Returns false, which PDFium treats as a failed write, where C# throws:
    /// for a block larger than `int.MaxValue` bytes, or past the most bytes a C# array holds.
    private func write(_ data: UnsafeRawPointer?, _ size: UInt) -> Bool {
        guard size <= UInt(Int32.max), bytes.count + Int(size) <= PdfSnapshot.maxLength else {
            return false
        }

        if size == 0 {
            return true
        }

        guard let data else {
            return false
        }

        bytes.append(contentsOf: UnsafeRawBufferPointer(start: data, count: Int(size)))
        return true
    }
}

/// PDFium's `FS_MATRIX`: maps text or object space to page space, `[a b c d e f]`.
typealias FsMatrix = FS_MATRIX

/// PDFium's `FS_RECTF`. Note the field order: left, top, right, bottom.
typealias FsRectF = FS_RECTF

/// Swift calls PDFium's C API (chromium/8152) directly, through the `CPDFium` module, and uses the
/// constants and types its headers define (`FPDF_ERR_FILE`, `FPDF_ANNOT`, `FS_MATRIX` and so on).
/// PDFium is not thread-safe: call it only while holding `PdfiumLibrary`'s lock. This keeps the
/// constants PaperKnife needs that the headers don't define. On macOS, C `unsigned long`
/// (`FPDF_DWORD`) is 64 bits wide where it is 32 on Windows; the values PDFium returns in it fit
/// 32 bits, and are read as `UInt32` where the C# code reads `uint`.
enum PdfiumNative {
    /// Permission bit 4 (ISO 32000-1, table 22): modify the contents of the document.
    static let permissionModifyContents: UInt32 = 1 << 3

    /// Permission bit 5: copy or otherwise extract text and graphics.
    static let permissionCopy: UInt32 = 1 << 4

    /// Permission bit 11 (security handler revision 3 and later): assemble the document.
    static let permissionAssemble: UInt32 = 1 << 10
}
