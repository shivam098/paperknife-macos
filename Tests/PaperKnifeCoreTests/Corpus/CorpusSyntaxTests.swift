import CryptoKit
import Foundation
import XCTest
@testable import PaperKnifeCore

/// The conformance corpus (conformance/, see its README.md) as far as PaperKnife's own reader goes:
/// for every case, the decoded content and the fonts of each page of the document as opened, which
/// must be what the Windows engine observed (`initial.pages[i].content` and `.fonts`). The rest of
/// each case (runs, edits, steps) needs the document session.
final class CorpusSyntaxTests: XCTestCase {
    /// Numbers may differ this much between platforms (they are rounded to 0.01).
    private static let tolerance = 0.011

    override func setUp() {
        super.setUp()
        SyntaxTestSupport.useRepositoryFonts()
    }

    func testStoredCases_GiveTheStoredContentAndFonts() throws {
        let root = SyntaxTestSupport.repositoryRoot.appendingPathComponent("conformance")
        let cases = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cases"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { String.ordinalLess($0.lastPathComponent, $1.lastPathComponent) }
        XCTAssertFalse(cases.isEmpty, "The corpus hasn't been synced into conformance/.")
        var failures: [String] = []
        var pagesChecked = 0
        for url in cases {
            let id = url.deletingPathExtension().lastPathComponent
            guard let stored = try Self.json(Data(contentsOf: url)).object,
                let document = stored["document"]?.string,
                let pages = stored["initial"]?.object?["pages"]?.array else {
                failures.append("\(id): the case can't be read")
                continue
            }

            let observed = try Self.observe([UInt8](Data(contentsOf: root.appendingPathComponent(document))), pages.count)
            for (i, page) in pages.enumerated() {
                pagesChecked += 1
                let expectedContent = page.object?["content"] ?? .null
                let actualContent: Json = observed[i].content.map { .string($0) } ?? .null
                if let difference = Self.difference(expectedContent, actualContent, "$.initial.pages[\(i)].content") {
                    failures.append("\(id): \(difference)\(Self.contentDifference(root, expectedContent, observed[i].bytes))")
                }

                if let difference = Self.difference(page.object?["fonts"] ?? .null, observed[i].fonts, "$.initial.pages[\(i)].fonts") {
                    failures.append("\(id): \(difference)")
                }
            }

            // The documents a case appends are read too; their observations come with the steps.
            for (_, attachment) in stored["attachments"]?.object ?? [:] {
                if let path = attachment.string {
                    let bytes = [UInt8](try Data(contentsOf: root.appendingPathComponent(path)))
                    _ = try Self.observe(bytes, (try PdfFile.tryOpen(bytes)?.getPages()?.count) ?? 0)
                }
            }
        }

        XCTAssertGreaterThan(pagesChecked, 0)
        XCTAssertEqual(failures, [], failures.prefix(30).joined(separator: "\n"))
    }

    // MARK: - CorpusRecorder.State, for what PaperKnife's own reader observes

    private struct PageObservation {
        let content: String?
        let bytes: [UInt8]?
        let fonts: Json
    }

    /// Each page's decoded content (its SHA-256) and fonts, as CorpusRecorder.State records them.
    private static func observe(_ bytes: [UInt8], _ pageCount: Int) throws -> [PageObservation] {
        var file = try PdfFile.tryOpen(bytes)
        if file?.isEncrypted == true {
            file = nil
        }

        let nodes = try file?.getPages()
        var pages: [PageObservation] = []
        for page in 0..<pageCount {
            guard let file, let nodes, page < nodes.count else {
                pages.append(PageObservation(content: nil, bytes: nil, fonts: .null))
                continue
            }

            let content = try ContentPage.tryLoad(file, nodes, page)?.content
            pages.append(PageObservation(content: content.map(sha256), bytes: content, fonts: try fonts(file, nodes[page])))
        }

        return pages
    }

    /// The page's fonts in a form that doesn't depend on how a writer ordered or compressed them.
    private static func fonts(_ file: PdfFile, _ page: PdfPageNode) throws -> Json {
        var fonts: [Json] = []
        let entries = try file.resolveDict(page.resources?["Font"])?.entries.map { ($0.key, $0.value) } ?? []
        for (name, value) in entries.stableSorted(by: { String.ordinalLess($0.0, $1.0) }) {
            guard let font = try file.resolveDict(value) else {
                fonts.append(.object(["name": .string(name)]))
                continue
            }

            let descriptor = try file.resolveDict(font["FontDescriptor"])
            let key = ["FontFile", "FontFile2", "FontFile3"].first { descriptor?[$0] != nil }
            var program: CosStream?
            if let key, let descriptor {
                program = try file.resolve(descriptor[key]) as? CosStream
            }

            var widths: Json = .null
            if let array = try file.resolveArray(font["Widths"]) {
                widths = .array(try array.items.map { try number(file.resolveNumber($0)) })
            }

            var programLength: Json = .null
            if let program, let data = try file.decodeStream(program) {
                programLength = .number(Double(data.count))
            }

            var object: [String: Json] = [:]
            object["name"] = .string(name)
            object["subtype"] = string(try file.resolveName(font["Subtype"]))
            object["baseFont"] = string(try file.resolveName(font["BaseFont"]))
            object["firstChar"] = number(try file.resolveNumber(font["FirstChar"]))
            object["lastChar"] = number(try file.resolveNumber(font["LastChar"]))
            object["widths"] = widths
            object["encoding"] = try encoding(file, font["Encoding"])
            object["toUnicode"] = .bool(font["ToUnicode"] != nil)
            object["flags"] = number(try file.resolveNumber(descriptor?["Flags"]))
            object["fontFile"] = key.map { Json.string($0) } ?? Json.null
            object["programLength"] = programLength
            fonts.append(.object(object))
        }

        return .array(fonts)
    }

    private static func encoding(_ file: PdfFile, _ entry: CosObject?) throws -> Json {
        let value = try file.resolve(entry)
        if value == nil {
            return .null
        }

        if let name = value as? CosName {
            return .string(name.value)
        }

        guard let dict = value as? CosDict else {
            return .string("(other)")
        }

        var differences: [String: Json] = [:]
        var next = 0
        for item in try file.resolveArray(dict["Differences"])?.items ?? [] {
            let resolved = try file.resolve(item)
            if let number = resolved as? CosNumber {
                next = DotNetMath.toInt32(number.value)
            } else if let glyph = resolved as? CosName {
                differences[String(next)] = .string(glyph.value)
                next = Int(Int32(next) &+ 1)
            }
        }

        return .object(["base": string(try file.resolveName(dict["BaseEncoding"])), "differences": .object(differences)])
    }

    private static func string(_ value: String?) -> Json { value.map { .string($0) } ?? .null }

    /// A number as the corpus keeps it: rounded to 4 decimals, half away from zero.
    private static func number(_ value: Double?) -> Json { value.map { .number(DotNetMath.round($0, 4, awayFromZero: true)) } ?? .null }

    private static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Comparing as ConformanceTests.Difference does

    private indirect enum Json {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([Json])
        case object([String: Json])

        var object: [String: Json]? {
            if case let .object(value) = self {
                return value
            }

            return nil
        }

        var array: [Json]? {
            if case let .array(value) = self {
                return value
            }

            return nil
        }

        var string: String? {
            if case let .string(value) = self {
                return value
            }

            return nil
        }
    }

    private static func json(_ data: Data) throws -> Json { convert(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }

    private static func convert(_ value: Any) -> Json {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let text as String:
            return .string(text)
        case let items as [Any]:
            return .array(items.map(convert))
        case let entries as [String: Any]:
            return .object(entries.mapValues(convert))
        default:
            return .string("\(value)")
        }
    }

    /// Where two observations first differ, or nil: objects with the same keys, arrays with the same
    /// items, numbers within the tolerance, and everything else exactly the same.
    private static func difference(_ expected: Json, _ actual: Json, _ path: String) -> String? {
        switch (expected, actual) {
        case (.null, .null):
            return nil
        case let (.object(a), .object(b)):
            for key in Set(a.keys).union(b.keys).sorted(by: String.ordinalLess) {
                guard let x = a[key], let y = b[key] else {
                    return "\(path).\(key) is \(a[key] != nil ? "missing" : "unexpected")"
                }

                if let found = Self.difference(x, y, "\(path).\(key)") {
                    return found
                }
            }

            return nil
        case let (.array(a), .array(b)):
            if a.count != b.count {
                return "\(path) has \(b.count) items, not \(a.count)"
            }

            for i in 0..<a.count {
                if let found = Self.difference(a[i], b[i], "\(path)[\(i)]") {
                    return found
                }
            }

            return nil
        case let (.number(x), .number(y)):
            return abs(x - y) <= tolerance ? nil : "\(path) is \(y), not \(x)"
        case let (.bool(x), .bool(y)) where x == y:
            return nil
        case let (.string(x), .string(y)) where x.ordinalEquals(y):
            return nil
        default:
            return "\(path) is \(actual), not \(expected)"
        }
    }

    /// Where decoded content first differs from the content the corpus keeps for the expected hash.
    private static func contentDifference(_ root: URL, _ expected: Json, _ actual: [UInt8]?) -> String {
        guard let hash = expected.string, let actual,
            let stored = try? [UInt8](Data(contentsOf: root.appendingPathComponent("contents/\(hash.prefix(12)).content"))) else {
            return ""
        }

        let common = zip(stored, actual).prefix { $0 == $1 }.count
        let context = { (bytes: [UInt8]) in Latin1.string(bytes[max(0, common - 20)..<min(bytes.count, common + 40)]) }
        return " (first difference at byte \(common) of \(stored.count): expected “\(context(stored))”, got “\(context(actual))”)"
    }
}
