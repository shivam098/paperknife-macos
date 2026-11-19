enum PsTokenKind {
    /// A literal name such as /FontName.
    case name

    /// A number, an operator or another regular token such as def or RD.
    case regular

    case arrayStart

    case arrayEnd

    /// A whole procedure, { ... }, including nested procedures.
    case procedure

    case string

    case hexString

    case dictStart

    case dictEnd

    /// The binary data after "n RD" or "n -|": exactly n bytes after one separator.
    case binary
}

/// A token's kind and where it is in the data.
struct PsToken {
    let kind: PsTokenKind

    let start: Int

    let length: Int

    init(_ kind: PsTokenKind, _ start: Int, _ length: Int) {
        self.kind = kind
        self.start = start
        self.length = length
    }

    func text(_ data: [UInt8]) -> String { Latin1.string(data[start..<(start + length)]) }

    func `is`(_ data: [UInt8], _ text: String) -> Bool {
        data.withUnsafeBufferPointer { matches($0, Array(text.utf16)) }
    }

    /// The token's value when it is a whole number written with digits only, as Type 1 lengths and indexes are.
    func integer(_ data: [UInt8]) -> Int? {
        data.withUnsafeBufferPointer { integer($0) }
    }

    /// `is` on the data's bytes: a regular token or a name whose Latin-1 text is `text`.
    fileprivate func matches(_ data: UnsafeBufferPointer<UInt8>, _ text: [UInt16]) -> Bool {
        guard (kind == .regular || kind == .name) && length == text.count else {
            return false
        }

        for i in 0..<length where UInt16(data[start + i]) != text[i] {
            return false
        }

        return true
    }

    fileprivate func integer(_ data: UnsafeBufferPointer<UInt8>) -> Int? {
        if kind != .regular || length < 1 || length > 9 {
            return nil
        }

        var value = 0
        for i in start..<(start + length) {
            if data[i] < UInt8(ascii: "0") || data[i] > UInt8(ascii: "9") {
                return nil
            }

            value = value * 10 + Int(data[i]) - 0x30
        }

        return value
    }
}

/// Splits PostScript, the language of Type 1 font programs, into tokens in a single pass, the way
/// FreeType's Type 1 parser reads it: comments are skipped, and a procedure, a string or the binary
/// data of a glyph or subroutine is one token.
enum PostScriptTokenizer {
    private static let rd: [UInt16] = Array("RD".utf16)
    private static let dashBar: [UInt16] = Array("-|".utf16)

    /// The tokens, or nil when the data is malformed or has more than `maxTokens` tokens. Reading
    /// stops at the operator `stopAt` (for example closefile, after which a font program may hold
    /// anything).
    static func tokenize(_ data: [UInt8], _ maxTokens: Int, _ stopAt: String? = nil) -> [PsToken]? {
        let stop = stopAt.map { Array($0.utf16) }
        return data.withUnsafeBufferPointer { tokenize($0, maxTokens, stop) }
    }

    private static func tokenize(_ data: UnsafeBufferPointer<UInt8>, _ maxTokens: Int, _ stopAt: [UInt16]?) -> [PsToken]? {
        var tokens: [PsToken] = []
        var i = 0
        while true {
            skipSpaceAndComments(data, &i)
            if i >= data.count {
                return tokens
            }

            if tokens.count >= maxTokens {
                return nil
            }

            let start = i
            switch data[i] {
            case UInt8(ascii: "/"):
                i += 1
                if i < data.count && data[i] == UInt8(ascii: "/") {
                    i += 1
                }

                while i < data.count && isRegular(data[i]) {
                    i += 1
                }

                tokens.append(PsToken(.name, start, i - start))
            case UInt8(ascii: "["):
                tokens.append(PsToken(.arrayStart, i, 1))
                i += 1
            case UInt8(ascii: "]"):
                tokens.append(PsToken(.arrayEnd, i, 1))
                i += 1
            case UInt8(ascii: "{"):
                if !skipProcedure(data, &i) {
                    return nil
                }

                tokens.append(PsToken(.procedure, start, i - start))
            case UInt8(ascii: "("):
                if !skipString(data, &i) {
                    return nil
                }

                tokens.append(PsToken(.string, start, i - start))
            case UInt8(ascii: "<") where i + 1 < data.count && data[i + 1] == UInt8(ascii: "<"):
                tokens.append(PsToken(.dictStart, i, 2))
                i += 2
            case UInt8(ascii: "<"):
                if !skipHexString(data, &i) {
                    return nil
                }

                tokens.append(PsToken(.hexString, start, i - start))
            case UInt8(ascii: ">") where i + 1 < data.count && data[i + 1] == UInt8(ascii: ">"):
                tokens.append(PsToken(.dictEnd, i, 2))
                i += 2
            case UInt8(ascii: ">"), UInt8(ascii: ")"), UInt8(ascii: "}"):
                return nil
            default:
                while i < data.count && isRegular(data[i]) {
                    i += 1
                }

                let token = PsToken(.regular, start, i - start)
                if let stopAt, token.matches(data, stopAt) {
                    return tokens
                }

                tokens.append(token)

                // "n RD" (or "n -|") is followed by one separator and n bytes of binary data.
                if (token.matches(data, rd) || token.matches(data, dashBar)) && tokens.count >= 2,
                    let length = tokens[tokens.count - 2].integer(data) {
                    if length > data.count - i - 1 {
                        return nil
                    }

                    tokens.append(PsToken(.binary, i + 1, length))
                    i += 1 + length
                }
            }
        }
    }

    static func isWhite(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }

    private static func isRegular(_ b: UInt8) -> Bool {
        if isWhite(b) {
            return false
        }

        switch b {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"),
            UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "/"), UInt8(ascii: "%"):
            return false
        default:
            return true
        }
    }

    private static func skipSpaceAndComments(_ data: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
        while i < data.count {
            if isWhite(data[i]) {
                i += 1
            } else if data[i] == UInt8(ascii: "%") {
                skipComment(data, &i)
            } else {
                return
            }
        }
    }

    private static func skipComment(_ data: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
        while i < data.count && data[i] != 13 && data[i] != 10 {
            i += 1
        }
    }

    private static func skipProcedure(_ data: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> Bool {
        var depth = 0
        while i < data.count {
            switch data[i] {
            case UInt8(ascii: "{"):
                depth += 1
                i += 1
            case UInt8(ascii: "}"):
                i += 1
                depth -= 1
                if depth == 0 {
                    return true
                }
            case UInt8(ascii: "("):
                if !skipString(data, &i) {
                    return false
                }
            case UInt8(ascii: "<") where i + 1 < data.count && data[i + 1] == UInt8(ascii: "<"):
                i += 2
            case UInt8(ascii: "<"):
                if !skipHexString(data, &i) {
                    return false
                }
            case UInt8(ascii: "%"):
                skipComment(data, &i)
            default:
                i += 1
            }
        }

        return false
    }

    private static func skipString(_ data: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> Bool {
        var depth = 0
        while i < data.count {
            let b = data[i]
            i += 1
            if b == UInt8(ascii: "\\") {
                i += 1
            } else if b == UInt8(ascii: "(") {
                depth += 1
            } else if b == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 {
                    return true
                }
            }
        }

        return false
    }

    // <hex digits>, or the ASCII85 form <~ ... ~>.
    private static func skipHexString(_ data: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> Bool {
        i += 1
        if i < data.count && data[i] == UInt8(ascii: "~") {
            var j = i
            while j + 1 < data.count {
                if data[j] == UInt8(ascii: "~") && data[j + 1] == UInt8(ascii: ">") {
                    i = j + 2
                    return true
                }

                j += 1
            }

            return false
        }

        while i < data.count {
            let b = data[i]
            i += 1
            if b == UInt8(ascii: ">") {
                return true
            }

            if !isWhite(b) && !PdfLexer.isHexDigit(b) {
                return false
            }
        }

        return false
    }
}
