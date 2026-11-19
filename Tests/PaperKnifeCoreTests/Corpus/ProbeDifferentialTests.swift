import CryptoKit
import XCTest
@testable import PaperKnifeCore

/// A one-off differential check against the Windows engine: for every corpus document, what the
/// Syntax, Content and Fonts layers compute (operations, text-show state, font info by code, font
/// completions), dumped section by section exactly as a probe built from the C# sources dumps it,
/// must hash to the probe's digests (Tests/probe-digests.json).
final class ProbeDifferentialTests: XCTestCase {
    private static let firstTexts = [" ", "\u{A0}", "fi", "A"]
    private static let encodeTexts = ["Hello Kitty", "fi", "\u{A0}x", " ", "\u{E9}A"]

    override func setUp() {
        super.setUp()
        SyntaxTestSupport.useRepositoryFonts()
    }

    func testEveryCorpusDocumentGivesWhatTheWindowsEngineComputes() throws {
        let root = SyntaxTestSupport.repositoryRoot
        let data = try Data(contentsOf: root.appendingPathComponent("Tests").appendingPathComponent("probe-digests.json"))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let documents = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("conformance").appendingPathComponent("documents"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
            .sorted { String.ordinalLess($0.lastPathComponent, $1.lastPathComponent) }
        var seen = Set<String>()
        var failures: [String] = []
        for url in documents {
            let doc = url.deletingPathExtension().lastPathComponent
            for (name, body) in try Self.observe([UInt8](Data(contentsOf: url))) {
                let key = "\(doc)/\(name)"
                seen.insert(key)
                if expected[key] != Self.hash(Array(body.utf8)) {
                    failures.append(key)
                    if failures.count <= 4 {
                        print("== \(key) differs from \(expected[key] ?? "nothing"):\n\(body)== end of \(key)")
                    }
                }
            }
        }

        XCTAssertEqual(failures.count, 0, failures.prefix(40).joined(separator: "\n"))
        XCTAssertEqual(Set(expected.keys).subtracting(seen).sorted(), [])
        XCTAssertEqual(seen.count, expected.count)
    }

    // MARK: - Damaged inputs (the probe's Fuzz.cs, call for call)

    private static let maxFuzzedDocument = 100_000
    private static let documentMutations = 8
    private static let contentPages = 2
    private static let contentMutations = 6
    private static let contentFonts = 2
    private static let fontMutations = 40
    private static let filterCases = 800
    private static let syntaxCases = 1500
    private static let golden: UInt64 = 0x9E37_79B9_7F4A_7C15

    private static let alphabet = Array("()<>[]{}/%#\\ \n\r\t0123456789.+-abcdefRTnulsojmBIDEWHQq'\"".utf8) + [0x00, 0x80, 0xFF]

    private static let interesting: [UInt8] = [
        0x00, 0x09, 0x0A, 0x0D, 0x20, 0x25, 0x28, 0x29, 0x2F, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2D,
        0x2E, 0x30, 0x31, 0x39, 0x52, 0x6E, 0x66, 0xFF, 0x80, 0x5C, 0x45, 0x49, 0x54, 0x6A, 0x2B,
    ]

    private static let fuzzFonts = ["amsfonts/fonts/cmr10.pfb", "lm/fonts/lmr10.pfb", "cm-super/fonts/sfrm1000.pfb"]

    private static let filterNames = ["FlateDecode", "Fl", "LZWDecode", "ASCIIHexDecode", "ASCII85Decode", "RunLengthDecode", "AHx", "Other"]

    private static let predictors = [1, 2, 10, 11, 12, 13, 14, 15, 3]

    private static let colors = [1, 2, 3, 4]

    private static let bits = [1, 2, 4, 8, 16, 3]

    private static let columns = [1, 2, 3, 4, 5, 6, 7, 8]

    private static let earlyChanges = [0, 1]

    private static let extremes: [(Double, String)] = [
        (0, "0"), (-1, "-1"), (33, "33"), (1_000_001, "1000001"), (2_147_483_647, "2147483647"), (-2_147_483_647, "-2147483647"),
        (2_147_483_648, "2147483648"), (8, "8.0"), (4_294_967_304, "4294967304"),
    ]

    private static let limits = [64, 1000, StreamFilters.maxDecodedLength]

    func testDamagedInputsGiveWhatTheWindowsEngineComputes() throws {
        let root = SyntaxTestSupport.repositoryRoot
        let data = try Data(contentsOf: root.appendingPathComponent("Tests").appendingPathComponent("probe-fuzz-digests.json"))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        var seen = Set<String>()
        var failures: [String] = []
        func add(_ key: String, _ body: String) {
            let inserted = seen.insert(key).inserted
            XCTAssertTrue(inserted, "\(key) twice")
            if expected[key] != Self.hash(Array(body.utf8)) {
                failures.append(key)
                if failures.count <= 6 {
                    print("== \(key) differs from \(expected[key] ?? "nothing"):\n\(body)== end of \(key)")
                }
            }
        }

        let documents = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("conformance").appendingPathComponent("documents"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
            .sorted { String.ordinalLess($0.lastPathComponent, $1.lastPathComponent) }
        for (d, url) in documents.enumerated() {
            let original = [UInt8](try Data(contentsOf: url))
            if original.count > Self.maxFuzzedDocument {
                continue
            }

            let doc = url.deletingPathExtension().lastPathComponent
            for m in 0..<Self.documentMutations {
                let random = Random64(Self.seed(d + 1, m))
                Self.progress("\(doc)#\(m)")
                for (name, body) in try Self.observe(Self.mutateDocument(original, random), maxFonts: 3) {
                    add("\(doc)#\(m)/\(name)", body)
                }
            }

            Self.fuzzContent(doc, d, original, add)
        }

        let fonts = root.appendingPathComponent("third_party")
        for (f, path) in Self.fuzzFonts.enumerated() {
            let original = [UInt8](try Data(contentsOf: fonts.appendingPathComponent(path)))
            let reference = try XCTUnwrap(Type1Font.fromPfb(original[...]))
            for m in 0..<Self.fontMutations {
                let random = Random64(Self.seed(f + 101, m))
                Self.progress("font\(f)#\(m)")
                let mutated: [UInt8]
                switch m % 4 {
                case 0:
                    mutated = Self.overwrite(original, random, 6, reference.length1)
                case 1:
                    mutated = Self.mutatePrivate(original, random, false)
                case 2:
                    mutated = Self.mutatePrivate(original, random, true)
                default:
                    mutated = Self.mutate(original, random, original.count)
                }

                let s = Builder()
                Self.fontSummary(s, Type1Font.fromPfb(mutated[...]), reference)
                add("font\(f)#\(m)", s.text)
            }
        }

        for c in 0..<Self.filterCases {
            let random = Random64(Self.seed(c + 5000, 0))
            Self.progress("filter\(c)")
            let s = Builder()
            Self.fuzzFilter(s, random)
            add("filter\(c)", s.text)
        }

        for c in 0..<Self.syntaxCases {
            let random = Random64(Self.seed(c + 9000, 0))
            let length = 1 + random.below(60)
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length {
                bytes[i] = Self.alphabet[random.below(Self.alphabet.count)]
            }

            Self.progress("syntax\(c)")
            let s = Builder()
            Self.fuzzSyntax(s, bytes)
            add("syntax\(c)", s.text)
        }

        XCTAssertEqual(Self.alphabet.count, 57)
        XCTAssertEqual(failures.count, 0, failures.prefix(40).joined(separator: "\n"))
        XCTAssertEqual(Set(expected.keys).subtracting(seen).sorted(), [])
        XCTAssertEqual(seen.count, expected.count)
    }

    /// Unbuffered, so that a crash shows which case it was in.
    private static func progress(_ key: String) {
        FileHandle.standardError.write(Data("fuzz \(key)\n".utf8))
    }

    private static func seed(_ a: Int, _ b: Int) -> UInt64 { UInt64(a) &* golden &+ UInt64(b) }

    /// Damaged decoded content, read as the page would read it: operations, text layout and the
    /// completions of the first fonts.
    private static func fuzzContent(_ doc: String, _ d: Int, _ original: [UInt8], _ add: (String, String) -> Void) {
        var opened: PdfFile?
        var read: [PdfPageNode]?
        do {
            var problem: String?
            opened = try PdfFile.tryOpen(original, &problem)
            if let file = opened, !file.isEncrypted {
                read = try file.getPages()
            }
        } catch {
            return
        }

        guard let file = opened, let pages = read else {
            return
        }

        for i in 0..<min(pages.count, contentPages) {
            var loaded: ContentPage?
            var fontNames: [String] = []
            do {
                loaded = try ContentPage.tryLoad(file, pages, i)
                if let fonts = try file.resolveDict(pages[i].resources?["Font"]) {
                    fontNames = Array(fonts.entries.keys.stableSorted(by: { String.ordinalLess($0, $1) }).prefix(contentFonts))
                }
            } catch {
                continue
            }

            guard let page = loaded, !page.content.isEmpty else {
                continue
            }

            for m in 0..<contentMutations {
                let random = Random64(seed(d + 1, 1000 + (i * 100) + m))
                progress("\(doc)/p\(i)/content#\(m)")
                let mutated = mutate(page.content, random, page.content.count)
                let s = Builder()
                var ops: [ContentOp]?
                var layout: ContentTextLayout?
                do {
                    ops = try ContentParser.parse(mutated)
                    if let parsed = ops {
                        try writeOps(s, parsed)
                        let simulated = try TextShowSimulator.run(parsed, file, pages[i].resources)
                        layout = simulated
                        text(s, simulated)
                    } else {
                        s.add("ops null\n")
                    }
                } catch {
                    s.add("throws \(Self.name(of: error))\n")
                }

                if let ops, let layout {
                    let damaged = ContentPage(file: file, page: pages[i], streams: page.streams, content: mutated, ops: ops, text: layout)
                    for name in fontNames {
                        s.add("font \(S(name))\n")
                        do {
                            try completion(s, file, damaged, name)
                        } catch {
                            s.add("throws \(Self.name(of: error))\n")
                        }
                    }
                }

                add("\(doc)/p\(i)/content#\(m)", s.text)
            }
        }
    }

    private static func writeOps(_ s: Builder, _ ops: [ContentOp]) throws {
        for op in ops {
            s.add("op \(S(op.operator)) \(op.start) \(op.end)")
            for operand in op.operands {
                let text = try CosWriter.toText(operand)
                s.add(" \(S(text))")
            }

            s.add("\n")
        }
    }

    private static func kindNumber(_ kind: PdfTokenKind) -> Int {
        switch kind {
        case .end: return 0
        case .number: return 1
        case .name: return 2
        case .string: return 3
        case .arrayStart: return 4
        case .arrayEnd: return 5
        case .dictStart: return 6
        case .dictEnd: return 7
        case .keyword: return 8
        }
    }

    private static func fuzzSyntax(_ s: Builder, _ bytes: [UInt8]) {
        let lexer = PdfLexer(bytes)
        for _ in 0..<100 {
            let token = lexer.next()
            let tokenBytes = token.bytes.map { DotNetFormat.hex($0) } ?? "-"
            s.add("t \(kindNumber(token.kind)) \(token.start) \(token.end) \(S(token.text)) \(H(token.number)) \(tokenBytes)\n")
            if token.kind == .end {
                break
            }
        }

        do {
            let reader = PdfLexer(bytes)
            for _ in 0..<20 {
                guard let parsed = PdfObjectParser.read(reader) else {
                    s.add("object - \(reader.position)\n")
                    break
                }

                let text = try CosWriter.toText(parsed)
                s.add("object \(S(text)) \(reader.position)\n")
            }
        } catch {
            s.add("throws \(name(of: error))\n")
        }

        do {
            if let ops = try ContentParser.parse(bytes) {
                try writeOps(s, ops)
            } else {
                s.add("ops null\n")
            }
        } catch {
            s.add("throws \(name(of: error))\n")
        }
    }

    private static func fuzzFilter(_ s: Builder, _ random: Random64) {
        let filter = filterNames[random.below(filterNames.count)]
        var data = filterInput(filter, random)
        var filters = [filter]
        if random.below(4) == 0 {
            // The data hex-encoded, read through ASCIIHexDecode first.
            filters.insert(random.below(2) == 0 ? "AHx" : "ASCIIHexDecode", at: 0)
            data = Array(DotNetFormat.hex(data).utf8) + [UInt8(ascii: ">")]
        }

        var parameters: [CosDict?] = []
        let count = random.below(filters.count + 1)
        for _ in 0..<count {
            if random.below(3) == 0 {
                parameters.append(nil)
                continue
            }

            var entries = OrderedDictionary<String, CosObject>()
            entries["Predictor"] = parameter(random, predictors)
            entries["Colors"] = parameter(random, colors)
            entries["BitsPerComponent"] = parameter(random, bits)
            entries["Columns"] = parameter(random, columns)
            entries["EarlyChange"] = parameter(random, earlyChanges)
            parameters.append(CosDict(entries))
        }

        let limit = limits[random.below(limits.count)]
        s.add("case \(filters.joined(separator: ",")) \(parameters.count) \(limit) \(DotNetFormat.hex(data))\n")
        do {
            var problem: String?
            if let decoded = try StreamFilters.decode(data[...], filters, parameters, &problem, limit: limit) {
                s.add("\(decoded.count) \(hash(decoded))\n")
            } else {
                s.add("null \(S(problem))\n")
            }
        } catch {
            s.add("throws \(name(of: error))\n")
        }

        if (filter == "FlateDecode" || filter == "Fl") && filters.count == 1 {
            let length = random.below(50)
            do {
                if let prefix = try StreamFilters.inflatePrefix(data[...], length) {
                    s.add("prefix \(length) \(DotNetFormat.hex(prefix))\n")
                } else {
                    s.add("prefix \(length) null\n")
                }
            } catch {
                s.add("prefix throws \(name(of: error))\n")
            }
        }
    }

    private static func parameter(_ random: Random64, _ choices: [Int]) -> CosNumber {
        if random.below(6) == 0 {
            let (value, raw) = extremes[random.below(extremes.count)]
            return CosNumber(value, raw)
        }

        let choice = choices[random.below(choices.count)]
        return CosNumber(Double(choice), String(choice))
    }

    private static func fontSummary(_ s: Builder, _ font: Type1Font?, _ reference: Type1Font) {
        guard let font else {
            s.add("null\n")
            return
        }

        let matrix = font.fontMatrix.map { H($0) }.joined(separator: ",")
        s.add("font \(S(font.fontName)) \(matrix) \(font.paintType) \(font.lenIV) \(B(font.usesStandardEncoding)) \(font.length1) \(font.length2) \(font.length3) \(font.program.count)\n")
        var encoding = ""
        for (code, name) in font.encoding {
            encoding += "\(code)=\(S(name));"
        }

        s.add("encoding \(font.encoding.count) \(hash(Array(encoding.utf8)))\n")
        var glyphs = ""
        for (name, program) in font.charStrings {
            glyphs += "\(S(name)):\(DotNetFormat.hex(program));"
        }

        s.add("charstrings \(font.charStrings.count) \(hash(Array(glyphs.utf8)))\n")
        var subrs = ""
        for (index, program) in font.subrs.sorted(by: { $0.key < $1.key }) {
            subrs += "\(index):\(DotNetFormat.hex(program));"
        }

        s.add("subrs \(font.subrs.count) \(hash(Array(subrs.utf8)))\n")
        var values = ""
        for (key, value) in font.renderingValues.map({ ($0.key, $0.value) }).stableSorted(by: { String.ordinalLess($0.0, $1.0) }) {
            values += "\(S(key))=\(S(value));"
        }

        s.add("rendering \(font.renderingValues.count) \(hash(Array(values.utf8)))\n")
        s.add("widths")
        for name in font.charStrings.keys.prefix(12) {
            s.add(" \(D(font.width(name)))")
        }

        s.add("\n")
        let difference = font.differenceFrom(reference)
        s.add("difference \(S(difference))\n")
        let cleartext = Array(font.program[..<font.length1])
        let builtin = Type1Font.readEncoding(cleartext).map { "\(B($0.standard)) \($0.names.count)" } ?? "-"
        s.add("readencoding \(builtin) \(S(Type1Font.readFontName(cleartext)))\n")
    }

    private static func filterInput(_ filter: String, _ random: Random64) -> [UInt8] {
        let length = random.below(40)
        var payload = [UInt8](repeating: 0, count: length)
        switch filter {
        case "FlateDecode", "Fl":
            for i in 0..<length {
                payload[i] = UInt8(random.below(256))
            }

            let data = random.below(2) == 0 ? stored(payload) : [0x78, 0x9C] + payload
            return random.below(3) == 0 ? mutate(data, random, data.count) : data
        case "ASCIIHexDecode", "AHx":
            let hex = Array("0123456789abcdefABCDEF \n>xg".utf8)
            for i in 0..<length {
                payload[i] = hex[random.below(hex.count)]
            }

            return payload
        case "ASCII85Decode":
            for i in 0..<length {
                let r = random.below(100)
                payload[i] = r < 85 ? UInt8(33 + r) : r < 90 ? UInt8(ascii: "z") : r < 95 ? UInt8(ascii: " ") : r < 98 ? UInt8(ascii: "~") : UInt8(ascii: "v")
            }

            return payload
        default:
            for i in 0..<length {
                payload[i] = UInt8(random.below(256))
            }

            return payload
        }
    }

    // A zlib stream of one stored block: header, BFINAL with BTYPE 0, LEN, NLEN, the bytes and Adler-32.
    private static func stored(_ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        var bytes: [UInt8] = [
            0x78, 0x01, 0x01, UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: ~n),
            UInt8(truncatingIfNeeded: ~n >> 8),
        ]
        bytes += payload
        var a: UInt32 = 1
        var b: UInt32 = 0
        for x in payload {
            a = (a + UInt32(x)) % 65521
            b = (b + a) % 65521
        }

        let adler = (b << 16) | a
        bytes += [UInt8(truncatingIfNeeded: adler >> 24), UInt8(truncatingIfNeeded: adler >> 16), UInt8(truncatingIfNeeded: adler >> 8), UInt8(truncatingIfNeeded: adler)]
        return bytes
    }

    /// One to three bytes of `count` from `offset` changed in place.
    private static func overwrite(_ data: [UInt8], _ random: Random64, _ offset: Int, _ count: Int) -> [UInt8] {
        var bytes = data
        let edits = 1 + random.below(3)
        for _ in 0..<edits {
            let at = offset + random.below(count)
            if random.below(2) == 0 {
                bytes[at] ^= UInt8(1 + random.below(255))
            } else {
                bytes[at] = interesting[random.below(interesting.count)]
            }
        }

        return bytes
    }

    /// A PFB whose decrypted private part is damaged, then encrypted again, so that the parser meets the damage.
    private static func mutatePrivate(_ pfb: [UInt8], _ random: Random64, _ shifting: Bool) -> [UInt8] {
        var segments: [(type: UInt8, data: [UInt8])] = []
        var at = 0
        while at + 6 <= pfb.count && pfb[at] == 0x80 && (pfb[at + 1] == 1 || pfb[at + 1] == 2) {
            let length = Int(pfb[at + 2]) | Int(pfb[at + 3]) << 8 | Int(pfb[at + 4]) << 16 | Int(pfb[at + 5]) << 24
            segments.append((pfb[at + 1], Array(pfb[(at + 6)..<(at + 6 + length)])))
            at += 6 + length
        }

        let tail = Array(pfb[at...])
        guard let index = segments.firstIndex(where: { $0.type == 2 }) else {
            return pfb
        }

        let plain = eexec(segments[index].data, false)
        let damaged = shifting ? mutate(plain, random, plain.count) : overwrite(plain, random, 4, plain.count - 4)
        segments[index] = (2, eexec(damaged, true))
        var output: [UInt8] = []
        for (type, data) in segments {
            let n = data.count
            output += [0x80, type, UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 24)]
            output += data
        }

        output += tail
        return output
    }

    private static func eexec(_ data: [UInt8], _ encrypt: Bool) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count)
        var r: UInt32 = 55665
        for i in 0..<data.count {
            let b = data[i] ^ UInt8(truncatingIfNeeded: r >> 8)
            let cipher = encrypt ? b : data[i]
            output[i] = b
            r = ((UInt32(cipher) &+ r) &* 52845 &+ 22719) & 0xFFFF
        }

        return output
    }

    /// One to three edits; offsets mostly stay put so that the cross-reference table still finds the objects.
    private static func mutateDocument(_ data: [UInt8], _ random: Random64) -> [UInt8] {
        var bytes = data
        let edits = 1 + random.below(3)
        var e = 0
        while e < edits && !bytes.isEmpty {
            let at = random.below(bytes.count)
            let kind = random.below(10)
            if kind < 4 {
                bytes[at] ^= UInt8(1 + random.below(255))
            } else if kind < 7 {
                bytes[at] = interesting[random.below(interesting.count)]
            } else if kind < 9 {
                let n = min(1 + random.below(8), bytes.count - at)
                for i in 0..<n {
                    bytes[at + i] = interesting[random.below(interesting.count)]
                }
            } else {
                shift(&bytes, at, random)
            }

            e += 1
        }

        return bytes
    }

    private static func mutate(_ data: [UInt8], _ random: Random64, _ positions: Int) -> [UInt8] {
        var bytes = data
        let edits = 1 + random.below(3)
        var e = 0
        while e < edits && !bytes.isEmpty {
            let at = random.below(min(bytes.count, positions))
            switch random.below(4) {
            case 0:
                bytes[at] ^= UInt8(1 + random.below(255))
            case 1:
                bytes[at] = interesting[random.below(interesting.count)]
            default:
                shift(&bytes, at, random)
            }

            e += 1
        }

        return bytes
    }

    private static func shift(_ bytes: inout [UInt8], _ at: Int, _ random: Random64) {
        switch random.below(3) {
        case 0:
            let count = min(1 + random.below(16), bytes.count - at)
            bytes.removeSubrange(at..<(at + count))
        case 1:
            let n = 1 + random.below(8)
            var insert = [UInt8](repeating: 0, count: n)
            for i in 0..<n {
                insert[i] = interesting[random.below(interesting.count)]
            }

            bytes.insert(contentsOf: insert, at: at)
        default:
            if bytes.count > 64 {
                bytes.removeSubrange(at...)
            }
        }
    }

    /// xorshift64*.
    private final class Random64 {
        private var state: UInt64

        init(_ seed: UInt64) {
            state = seed == 0 ? ProbeDifferentialTests.golden : seed
        }

        func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }

        func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private final class Builder {
        var text = ""

        func add(_ line: String) {
            text += line
        }
    }

    private static func observe(_ bytes: [UInt8], maxFonts: Int = .max) throws -> [(String, String)] {
        var sections: [(String, String)] = []
        var s = Builder()
        var opened: PdfFile?
        do {
            var problem: String?
            opened = try PdfFile.tryOpen(bytes, &problem)
            s.add("problem \(S(problem))\n")
            if let file = opened {
                s.add("encrypted \(B(file.isEncrypted))\nsize \(file.size)\nstartxref \(file.startXref)\nxrefstream \(B(file.hasXrefStream))\n")
            }
        } catch {
            s.add("throws \(name(of: error))\n")
            opened = nil
        }

        sections.append(("open", s.text))
        guard let file = opened, !file.isEncrypted else {
            return sections
        }

        var pages: [PdfPageNode]?
        s = Builder()
        do {
            pages = try file.getPages()
            if let pages {
                for page in pages {
                    s.add("page \(page.number) \(page.generation) \(B(page.resources != nil))\n")
                }
            } else {
                s.add("null\n")
            }
        } catch {
            s.add("throws \(name(of: error))\n")
            pages = nil
        }

        sections.append(("pages", s.text))
        guard let pages else {
            return sections
        }

        for i in 0..<pages.count {
            var content: ContentPage?
            s = Builder()
            do {
                content = try ContentPage.tryLoad(file, pages, i)
                if let content {
                    s.add("streams")
                    for r in content.streams {
                        s.add(" \(r.number) \(r.generation)")
                    }

                    s.add("\ncontent \(hash(content.content))\n")
                    for op in content.ops {
                        s.add("op \(S(op.operator)) \(op.start) \(op.end)")
                        for operand in op.operands {
                            let text = try CosWriter.toText(operand)
                            s.add(" \(S(text))")
                        }

                        s.add("\n")
                    }
                } else {
                    s.add("null\n")
                }
            } catch {
                s.add("throws \(name(of: error))\n")
                content = nil
            }

            sections.append(("p\(i)/ops", s.text))
            if let content {
                s = Builder()
                text(s, content.text)
                sections.append(("p\(i)/text", s.text))
            }

            let fonts: CosDict?
            do {
                fonts = try file.resolveDict(pages[i].resources?["Font"])
            } catch {
                sections.append(("p\(i)/fonts", "throws \(name(of: error))\n"))
                continue
            }

            guard let fonts else {
                continue
            }

            for (name, value) in fonts.entries.map({ ($0.key, $0.value) }).stableSorted(by: { String.ordinalLess($0.0, $1.0) }).prefix(maxFonts) {
                s = Builder()
                do {
                    if let dict = try file.resolveDict(value) {
                        info(s, try PdfFontInfo.load(file, dict))
                    } else {
                        s.add("null\n")
                    }
                } catch {
                    s.add("throws \(Self.name(of: error))\n")
                }

                sections.append(("p\(i)/font/\(S(name))", s.text))
                guard let content else {
                    continue
                }

                s = Builder()
                do {
                    try completion(s, file, content, name)
                } catch {
                    s.add("throws \(Self.name(of: error))\n")
                }

                sections.append(("p\(i)/copy/\(S(name))", s.text))
            }
        }

        return sections
    }

    private static func text(_ s: Builder, _ layout: ContentTextLayout) {
        for block in layout.blocks {
            s.add("block \(block.begin) \(block.end) \(B(block.irregular))\n")
        }

        for show in layout.shows {
            let (px, py) = show.pageStart
            s.add("show \(show.opIndex) \(show.block) \(H(show.x)) \(H(show.y)) \(B(show.positionKnown)) \(S(show.fontName)) \(H(show.fontSize)) ")
            s.add("\(H(show.charSpace)) \(H(show.wordSpace)) \(H(show.horizontalScale)) \(H(show.rise)) \(H(show.initialKerning)) ")
            s.add("\(B(show.inReplacedText)) \(show.ordinal) \(H(show.glyphX)) \(H(px)) \(H(py)) \(B(show.font != nil))\n")
            s.add("matrix \(M(show.ctm)) \(M(show.textMatrix)) \(M(show.objectMatrix)) \(M(show.glyphMatrix)) \(M(show.opMatrix))\n")
            for (bytes, kerning) in show.segments {
                s.add("seg \(DotNetFormat.hex(bytes)) \(H(kerning))\n")
            }

            s.add("codes")
            for (code, kerning) in show.codes() {
                s.add(" \(code):\(H(kerning))")
            }

            s.add("\n")
        }

        s.add("objects")
        for show in layout.objectShows {
            s.add(" \(show.opIndex)")
        }

        s.add("\n")
    }

    private static func info(_ s: Builder, _ info: PdfFontInfo) {
        s.add("info \(S(info.subtype)) \(info.codeLength) \(B(info.isType3))\n")
        for code in UInt32(0)..<256 {
            let unicode = info.unicode(code)
            s.add("c \(code) \(D(info.width(code))) \(S(unicode)) \(S(info.glyphName(code))) \(B(info.hasGlyph(code))) \(B(info.vouches(code, unicode ?? "A")))\n")
        }

        for text in firstTexts {
            s.add("first \(S(text)) \(U(info.firstCodeFor(text))) \(U(info.codeFor(text, [])))\n")
        }

        for text in encodeTexts {
            var missing: [String] = []
            let codes = info.encode(text, [], &missing)
            s.add("encode \(S(text)) [\(codes.map { String($0) }.joined(separator: " "))] [\(missing.map { S($0) }.joined(separator: " "))]\n")
        }

        s.add("split \(info.splitCodes([0x41, 0x42, 0x43] as [UInt8]).map { String($0) }.joined(separator: " "))\n")
        do {
            let joined = try info.joinCodes([0x41, 0x4243])
            s.add("join \(DotNetFormat.hex(joined))\n")
        } catch {
            s.add("join throws \(name(of: error))\n")
        }
    }

    private static func completion(_ s: Builder, _ file: PdfFile, _ page: ContentPage, _ name: String) throws {
        let selects = try FontCompletion.selectsGlyphsByName(page, name)
        s.add("selects \(B(selects))\n")
        var difference: String?
        let created = try FontCompletion.tryCreate(page, name, &difference)
        s.add("difference \(S(difference))\n")
        guard let completion = created else {
            s.add("null\n")
            return
        }

        s.add("copy \(S(completion.resourceName)) \(B(completion.reused)) \(S(completion.fontName))\n")
        let info = completion.info
        s.add("info \(S(info.subtype)) \(info.codeLength)\n")
        for code in UInt32(0)..<256 {
            let unicode = info.unicode(code)
            let draws = completion.draws(code, unicode ?? "A")
            s.add("c \(code) \(D(info.width(code))) \(S(unicode)) \(S(info.glyphName(code))) \(B(draws)) \(B(info.vouches(code, unicode ?? "A")))\n")
        }

        let updates = try completion.updates()
        for update in updates {
            if let stream = update as? StreamUpdate {
                s.add("update \(stream.number) \(stream.generation) stream \(hash(stream.data))")
                for (key, value) in stream.entries ?? OrderedDictionary() {
                    let text = try CosWriter.toText(value)
                    s.add(" \(S(key))=\(S(text))")
                }

                s.add("\n")
            } else if let value = update as? ValueUpdate {
                let text = try CosWriter.toText(value.value)
                s.add("update \(value.number) \(value.generation) value \(S(text))\n")
            }
        }

        let values = updates.filter { $0 is ValueUpdate }
        if !values.isEmpty {
            let appended = try IncrementalUpdate.append(file, values)
            s.add("append \(hash(appended))\n")
        }
    }

    private static func name(of error: Error) -> String { String(describing: type(of: error)) }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    private static func hex(_ value: UInt64, _ digits: Int) -> String {
        var bytes = [UInt8](repeating: 0x30, count: digits)
        var rest = value
        for i in stride(from: digits - 1, through: 0, by: -1) {
            bytes[i] = hexDigits[Int(rest & 15)]
            rest >>= 4
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private static func H(_ value: Double) -> String { hex(value.bitPattern, 16) }

    private static func D(_ value: Double?) -> String { value.map { H($0) } ?? "-" }

    private static func U(_ value: UInt32?) -> String { value.map { String($0) } ?? "-" }

    private static func B(_ value: Bool) -> String { value ? "1" : "0" }

    private static func M(_ m: PdfMatrix) -> String { "\(H(m.a)),\(H(m.b)),\(H(m.c)),\(H(m.d)),\(H(m.e)),\(H(m.f))" }

    private static func S(_ text: String?) -> String {
        guard let text else {
            return "-"
        }

        return "u" + text.utf16.map { hex(UInt64($0), 4) }.joined()
    }

    private static func hash(_ bytes: [UInt8]) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
