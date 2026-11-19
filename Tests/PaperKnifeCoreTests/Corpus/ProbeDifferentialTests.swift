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

    private final class Builder {
        var text = ""

        func add(_ line: String) {
            text += line
        }
    }

    private static func observe(_ bytes: [UInt8]) throws -> [(String, String)] {
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

            for (name, value) in fonts.entries.map({ ($0.key, $0.value) }).stableSorted(by: { String.ordinalLess($0.0, $1.0) }) {
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
