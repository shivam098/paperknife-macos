import Darwin
import Foundation

/// An immutable, fully serialized PDF held in memory. PDFium reads the bytes in place for as long
/// as a document loaded from the snapshot is open: they are an array that never changes, whose
/// storage is a heap block that doesn't move while the snapshot holds it.
public final class PdfSnapshot {
    /// The most bytes a C# array holds (`Array.MaxLength`), so the most a snapshot holds.
    static let maxLength = 0x7FFF_FFC7

    private let data: [UInt8]

    private init(_ data: [UInt8]) {
        self.data = data
    }

    public var length: Int { data.count }

    /// C#'s `Span`: the bytes.
    public var span: ArraySlice<UInt8> { data[...] }

    /// C#'s `Memory`: the bytes, without copying them.
    var memory: [UInt8] { data }

    /// Where the bytes are, for PDFium. Valid while the snapshot exists: a native array of bytes is
    /// one heap block, which the immutable `data` keeps alive and unchanged.
    var pointer: UnsafePointer<UInt8> { data.withUnsafeBufferPointer { $0.baseAddress! } }

    public static func fromFile(_ path: String) throws -> PdfSnapshot {
        try ArgumentException.throwIfNullOrEmpty(path, "path")
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let length = try file.seekToEnd()
        if length == 0 {
            throw PdfException(.invalidFormat, "The file is empty.")
        }

        if length > UInt64(maxLength) {
            throw PdfException(.operationFailed, "The file is too large to open (over 2 GB).")
        }

        try file.seek(toOffset: 0)
        let count = Int(length)
        let data = try [UInt8](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            // C#'s ReadExactly: the whole length, or an error.
            while initializedCount < count {
                let got = Darwin.read(file.fileDescriptor, buffer.baseAddress! + initializedCount, count - initializedCount)
                if got < 0 {
                    if errno == EINTR {
                        continue
                    }

                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                if got == 0 {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
                }

                initializedCount += got
            }
        }

        return PdfSnapshot(data)
    }

    public static func fromBytes<C: Collection>(_ bytes: C) throws -> PdfSnapshot where C.Element == UInt8 {
        if bytes.isEmpty {
            throw PdfException(.invalidFormat, "The file is empty.")
        }

        return PdfSnapshot(Array(bytes))
    }

    public func writeTo(_ destination: FileHandle) throws {
        try destination.write(contentsOf: data)
    }

    public func contentEquals(_ other: PdfSnapshot) -> Bool {
        self === other || data == other.data
    }

    static func fromStream(_ stream: FpdfFileWrite) throws -> PdfSnapshot { try fromBytes(stream.bytes) }
}
