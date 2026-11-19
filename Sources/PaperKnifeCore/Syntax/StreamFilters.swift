import CZlib

/// Decodes stream data (ISO 32000-1, 7.4) and encodes the streams PaperKnife writes.
enum StreamFilters {
    /// The most a single stream may decode to; larger streams are left to PDFium.
    static let maxDecodedLength = 64 * 1024 * 1024

    /// The decoded data, or nil when a filter isn't supported, the data is damaged or it decodes to
    /// more than `limit` bytes.
    static func decode(
        _ data: ArraySlice<UInt8>,
        _ filters: [String],
        _ parameters: [CosDict?],
        _ problem: inout String?,
        limit: Int = maxDecodedLength
    ) throws -> [UInt8]? {
        var current = Array(data)
        for i in 0..<filters.count {
            let p = i < parameters.count ? parameters[i] : nil
            let next: [UInt8]?
            switch filters[i] {
            case "FlateDecode", "Fl":
                next = try predict(inflate(current, limit), p)
            case "LZWDecode", "LZW":
                next = predict(lzw(current, integer(p, "EarlyChange", 1), limit), p)
            case "ASCIIHexDecode", "AHx":
                next = asciiHex(current)
            case "ASCII85Decode", "A85":
                next = ascii85(current, limit)
            case "RunLengthDecode", "RL":
                next = runLength(current, limit)
            default:
                next = nil
            }

            guard let next, next.count <= limit else {
                problem = "The stream's \(filters[i]) data can't be decoded."
                return nil
            }

            current = next
        }

        problem = nil
        return current
    }

    /// The data compressed as .NET's `ZLibStream` compresses it with `CompressionLevel.Optimal`.
    static func deflate(_ data: ArraySlice<UInt8>) throws -> [UInt8] {
        try ZLibWriter.compress(Array(data))
    }

    private static func integer(_ parameters: CosDict?, _ key: String, _ fallback: Int) -> Int {
        if let n = parameters?[key] as? CosNumber, n.isInteger {
            return DotNetMath.toInt32(n.value)
        }

        return fallback
    }

    /// The first `length` bytes of Flate data (fewer when it is shorter), or nil when it is damaged.
    static func inflatePrefix(_ data: ArraySlice<UInt8>, _ length: Int) throws -> [UInt8]? {
        guard length >= 0 else {
            throw DotNetThrows.overflow()
        }

        let z = try ZLibReader(Array(data))
        var output = [UInt8](repeating: 0, count: length)
        var read = 0
        do {
            while read < length {
                let count = try output.withUnsafeMutableBufferPointer { buffer in
                    try z.read(UnsafeMutableBufferPointer(rebasing: buffer[read..<length]))
                }

                if count <= 0 {
                    break
                }

                read += count
            }
        } catch is ZLibDataError {
            return nil
        }

        return read == length ? output : Array(output[0..<read])
    }

    private static func inflate(_ data: [UInt8], _ limit: Int) throws -> [UInt8]? {
        let z = try ZLibReader(data)
        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 81920)
        do {
            while true {
                let read = try buffer.withUnsafeMutableBufferPointer { try z.read($0) }
                if read <= 0 {
                    break
                }

                if output.count + read > limit {
                    return nil
                }

                output.append(contentsOf: buffer[0..<read])
            }
        } catch is ZLibDataError {
            return nil
        }

        return output
    }

    private static func predict(_ data: [UInt8]?, _ parameters: CosDict?) -> [UInt8]? {
        let predictor = integer(parameters, "Predictor", 1)
        guard let data, predictor != 1 else {
            return data
        }

        let colors = integer(parameters, "Colors", 1)
        let bits = integer(parameters, "BitsPerComponent", 8)
        let columns = integer(parameters, "Columns", 1)
        if colors < 1 || colors > 32 || ![1, 2, 4, 8, 16].contains(bits) || columns < 1 || columns > 1_000_000 {
            return nil
        }

        let bytesPerPixel = max(1, (colors * bits + 7) / 8)
        let rowLength = (colors * bits * columns + 7) / 8
        if rowLength > data.count {
            return data.isEmpty ? data : nil
        }

        if predictor == 2 {
            if bits != 8 {
                return nil
            }

            var result = data
            var row = 0
            while row + rowLength <= result.count {
                var i = row + bytesPerPixel
                while i < row + rowLength {
                    result[i] = result[i] &+ result[i - bytesPerPixel]
                    i += 1
                }

                row += rowLength
            }

            return result
        }

        if predictor < 10 {
            return nil
        }

        let rows = data.count / (rowLength + 1)
        var output = [UInt8](repeating: 0, count: rows * rowLength)
        var prior = [UInt8](repeating: 0, count: rowLength)
        for r in 0..<rows {
            let type = data[r * (rowLength + 1)]
            if type > 4 {
                return nil
            }

            let source = r * (rowLength + 1) + 1
            let target = r * rowLength
            for i in 0..<rowLength {
                let left = i >= bytesPerPixel ? Int(output[target + i - bytesPerPixel]) : 0
                let up = Int(prior[i])
                let upLeft = i >= bytesPerPixel ? Int(prior[i - bytesPerPixel]) : 0
                let add: Int
                switch type {
                case 1: add = left
                case 2: add = up
                case 3: add = (left + up) >> 1
                case 4: add = paeth(left, up, upLeft)
                default: add = 0
                }

                output[target + i] = UInt8(truncatingIfNeeded: Int(data[source + i]) + add)
            }

            prior.replaceSubrange(0..<rowLength, with: output[target..<(target + rowLength)])
        }

        return output
    }

    private static func paeth(_ left: Int, _ up: Int, _ upLeft: Int) -> Int {
        let p = left + up - upLeft
        let pa = abs(p - left)
        let pb = abs(p - up)
        let pc = abs(p - upLeft)
        return pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft
    }

    private static func asciiHex(_ data: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(data.count / 2)
        var high = -1
        for b in data {
            if b == UInt8(ascii: ">") {
                break
            }

            if PdfLexer.isWhitespace(b) {
                continue
            }

            if !PdfLexer.isHexDigit(b) {
                return nil
            }

            if high < 0 {
                high = PdfLexer.hexValue(b)
            } else {
                output.append(UInt8((high << 4) | PdfLexer.hexValue(b)))
                high = -1
            }
        }

        if high >= 0 {
            output.append(UInt8(high << 4))
        }

        return output
    }

    private static func ascii85(_ data: [UInt8], _ limit: Int) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(data.count)
        var value: UInt64 = 0
        var count = 0
        for b in data {
            if PdfLexer.isWhitespace(b) {
                continue
            }

            if b == UInt8(ascii: "~") {
                break
            }

            if b == UInt8(ascii: "z") && count == 0 {
                if output.count + 4 > limit {
                    return nil
                }

                output.append(contentsOf: [0, 0, 0, 0])
                continue
            }

            if b < UInt8(ascii: "!") || b > UInt8(ascii: "u") {
                return nil
            }

            value = value * 85 + UInt64(b - UInt8(ascii: "!"))
            count += 1
            if count == 5 {
                if value > UInt64(UInt32.max) {
                    return nil
                }

                output.append(contentsOf: [
                    UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                    UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
                ])
                value = 0
                count = 0
            }
        }

        if count == 1 {
            return nil
        }

        if count > 1 {
            for _ in count..<5 {
                value = value * 85 + 84
            }

            for i in 0..<(count - 1) {
                output.append(UInt8(truncatingIfNeeded: value >> UInt64(24 - 8 * i)))
            }
        }

        return output
    }

    private static func runLength(_ data: [UInt8], _ limit: Int) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(data.count * 2)
        var i = 0
        while i < data.count {
            let n = Int(data[i])
            i += 1
            if n == 128 {
                break
            }

            if output.count + 257 > limit {
                return nil
            }

            if n < 128 {
                if i + n + 1 > data.count {
                    return nil
                }

                output.append(contentsOf: data[i..<(i + n + 1)])
                i += n + 1
            } else {
                if i >= data.count {
                    return nil
                }

                output.append(contentsOf: repeatElement(data[i], count: 257 - n))
                i += 1
            }
        }

        return output
    }

    private static func lzw(_ data: [UInt8], _ earlyChange: Int, _ limit: Int) -> [UInt8]? {
        var output: [UInt8] = []
        var table: [[UInt8]] = []
        table.reserveCapacity(4096)
        func reset() {
            table.removeAll(keepingCapacity: true)
            for i in 0..<256 {
                table.append([UInt8(i)])
            }

            table.append([])
            table.append([])
        }

        reset()
        var width = 9
        var buffer = 0
        var bits = 0
        var position = 0
        var previous: [UInt8]?
        while true {
            while bits < width {
                if position >= data.count {
                    return output
                }

                buffer = ((buffer << 8) | Int(data[position])) & 0xFFFFFF
                position += 1
                bits += 8
            }

            let code = (buffer >> (bits - width)) & ((1 << width) - 1)
            bits -= width
            if code == 256 {
                reset()
                width = 9
                previous = nil
                continue
            }

            if code == 257 {
                return output
            }

            let entry: [UInt8]
            if code < table.count && code > 257 {
                entry = table[code]
            } else if code < 256 {
                entry = table[code]
            } else if code == table.count, let previous {
                entry = previous + [previous[0]]
            } else {
                return nil
            }

            output.append(contentsOf: entry)
            if output.count > limit {
                return nil
            }

            if let previous, table.count < 4096 {
                table.append(previous + [entry[0]])
            }

            previous = entry

            // C# adds in 32 bits, so a huge /EarlyChange wraps around.
            if Int32(table.count) &+ Int32(truncatingIfNeeded: earlyChange) >= Int32(1 << width) && width < 12 {
                width += 1
            }
        }
    }
}

/// zlib reported damaged data: .NET's `InvalidDataException`, which StreamFilters catches.
private struct ZLibDataError: Error {}

/// .NET's `ZLibStream` decompressing a byte array, as StreamFilters reads it: zlib's inflate with
/// a zlib header and an Adler-32 check (window bits 15), fed the input 8192 bytes at a time as
/// DeflateStream reads its base stream, and called as DeflateStream.ReadCore and Inflater call it.
/// So damaged data fails, truncated data ends where it ends, and bytes after the end are ignored.
private final class ZLibReader {
    private static let bufferSize = 8192

    private let stream: UnsafeMutablePointer<z_stream>
    private let buffer: UnsafeMutablePointer<UInt8>
    private let input: [UInt8]
    private var inputPosition = 0
    private var initialized = false
    private var finished = false

    init(_ input: [UInt8]) throws {
        self.input = input
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        buffer = .allocate(capacity: Self.bufferSize)
        let status = inflateInit2_(stream, 15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw ZLibException(ZLibMessages.forInit(status))
        }

        initialized = true
    }

    deinit {
        if initialized {
            inflateEnd(stream)
        }

        stream.deinitialize(count: 1)
        stream.deallocate()
        buffer.deallocate()
    }

    /// DeflateStream.ReadCore: inflates into `destination`, giving zlib more input as it needs it.
    /// 0 at the end of the data or of the compressed stream.
    func read(_ destination: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
        while true {
            let bytesRead = try inflate(destination)
            if bytesRead != 0 || finished {
                return bytesRead
            }

            if stream.pointee.avail_in == 0 {
                let n = min(Self.bufferSize, input.count - inputPosition)
                if n <= 0 {
                    // Truncated data: .NET doesn't validate it unless an app switch asks it to.
                    return bytesRead
                }

                input.withUnsafeBufferPointer { source in
                    buffer.update(from: source.baseAddress! + inputPosition, count: n)
                }

                inputPosition += n
                stream.pointee.next_in = buffer
                stream.pointee.avail_in = UInt32(n)
                finished = false
            }

            if destination.isEmpty {
                return bytesRead
            }
        }
    }

    /// Inflater.Inflate: one call of zlib's inflate, without flushing.
    private func inflate(_ destination: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
        if destination.isEmpty {
            return 0
        }

        stream.pointee.next_out = destination.baseAddress
        stream.pointee.avail_out = UInt32(destination.count)
        let status = CZlib.inflate(stream, Z_NO_FLUSH)
        switch status {
        case Z_OK, Z_BUF_ERROR:
            break
        case Z_STREAM_END:
            finished = true
        case Z_DATA_ERROR:
            throw ZLibDataError()
        default:
            // Z_NEED_DICT among them: .NET throws a ZLibException, which nothing catches as damaged data.
            throw ZLibException(ZLibMessages.forInflate(status))
        }

        return destination.count - Int(stream.pointee.avail_out)
    }
}

/// .NET's `ZLibStream` compressing with `CompressionLevel.Optimal`: zlib's default level (6), window
/// bits 15 and memory level 8, written as ZLibStream.Write and Dispose drive zlib.
private enum ZLibWriter {
    static func compress(_ data: [UInt8]) throws -> [UInt8] {
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer {
            stream.deinitialize(count: 1)
            stream.deallocate()
        }

        let status = deflateInit2_(
            stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw ZLibException(ZLibMessages.forInit(status))
        }

        defer {
            deflateEnd(stream)
        }

        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 8192)

        // One deflate call into the buffer; whether the stream is complete.
        func deflate(_ flush: Int32) throws -> Bool {
            var produced = 0
            let result = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                stream.pointee.next_out = out.baseAddress
                stream.pointee.avail_out = UInt32(out.count)
                let result = CZlib.deflate(stream, flush)
                produced = out.count - Int(stream.pointee.avail_out)
                return result
            }

            switch result {
            case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
                break
            case Z_STREAM_ERROR:
                throw ZLibException("The stream state of the underlying compression routine is inconsistent.")
            default:
                throw ZLibException("The underlying compression routine returned an unexpected result.")
            }

            output.append(contentsOf: buffer[0..<produced])
            return result == Z_STREAM_END
        }

        try data.withUnsafeBufferPointer { source in
            // Write: the input, compressed without flushing.
            if !source.isEmpty {
                stream.pointee.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
                stream.pointee.avail_in = UInt32(source.count)
                while stream.pointee.avail_in != 0 {
                    _ = try deflate(Z_NO_FLUSH)
                }
            }

            // Dispose: the rest, and the end of the stream.
            while try !deflate(Z_FINISH) {}
        }

        return output
    }
}

/// The messages of .NET's `ZLibException`s.
private enum ZLibMessages {
    static func forInit(_ status: Int32) -> String {
        switch status {
        case Z_MEM_ERROR: return "The underlying compression routine could not reserve sufficient memory."
        case Z_VERSION_ERROR: return "The version of the underlying compression routine does not match expected version."
        case Z_STREAM_ERROR: return "The underlying compression routine received incorrect initialization parameters."
        default: return "The underlying compression routine returned an unexpected result."
        }
    }

    static func forInflate(_ status: Int32) -> String {
        switch status {
        case Z_MEM_ERROR: return "The underlying compression routine could not reserve sufficient memory."
        case Z_STREAM_ERROR: return "The stream state of the underlying compression routine is inconsistent."
        default: return "The underlying compression routine returned an unexpected result."
        }
    }
}
