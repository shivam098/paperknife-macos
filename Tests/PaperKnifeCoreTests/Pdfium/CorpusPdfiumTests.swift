import Foundation
import XCTest
@testable import PaperKnifeCore

/// The conformance corpus (conformance/README.md) as the PDFium layer observes it: every case's
/// document opens with its password, and its initial state has the stored page count, page sizes
/// and text runs, which are what `DocumentSession.GetTextRuns` and `GetPageSize` return: the
/// page's `GetTextRuns()`, `Width` and `Height`. This checks the text layout ("select a whole line,
/// not one character") on every corpus document.
final class CorpusPdfiumTests: XCTestCase {
    /// Numbers may differ this much between platforms (they are rounded to 0.01).
    private static let tolerance = 0.011

    /// A JSON value as the corpus compares it.
    private indirect enum Json {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([Json])
        case object([String: Json])
    }

    private struct CorpusError: Error, CustomStringConvertible {
        let description: String
    }

    func testStoredCases_GiveTheStoredPagesAndRuns() throws {
        let root = try Self.repositoryRoot()
        let cases = root.appendingPathComponent("conformance").appendingPathComponent("cases")
        let names = try FileManager.default.contentsOfDirectory(atPath: cases.path)
            .filter { $0.ordinalHasSuffix(".json") }
            .sorted(by: String.ordinalLess)
        XCTAssertFalse(names.isEmpty, "The corpus isn't in conformance/cases.")

        var failed = 0
        for name in names {
            do {
                if let difference = try Self.check(cases.appendingPathComponent(name), root) {
                    failed += 1
                    XCTFail("cases/\(name): \(difference)")
                }
            } catch {
                failed += 1
                XCTFail("cases/\(name): \(error)")
            }
        }

        print("Conformance corpus: \(names.count - failed) of \(names.count) cases give the stored pages and runs.")
    }

    /// The first difference between a case's stored initial pages and what the PDFium layer reads.
    private static func check(_ file: URL, _ root: URL) throws -> String? {
        guard let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
            let document = stored["document"] as? String,
            let initial = stored["initial"] as? [String: Any],
            let pages = initial["pages"] as? [[String: Any]]
        else {
            throw CorpusError(description: "The case doesn't have a document and an initial state.")
        }

        let password = stored["password"] as? String
        let snapshot = try PdfSnapshot.fromFile(root.appendingPathComponent("conformance").appendingPathComponent(document).path)
        let pdf = try PdfDocument.load(snapshot, password)
        defer { pdf.dispose() }

        let pageCount = try pdf.pageCount
        var observedPages: [Json] = []
        for index in 0..<pageCount {
            let page = try pdf.getPage(index)
            let width = try page.width
            let height = try page.height
            let runs = try page.getTextRuns()
            observedPages.append(.object([
                "width": .number(round(Double(width))),
                "height": .number(round(Double(height))),
                "runs": .array(runs.map { observe($0) }),
            ]))
        }

        let expectedPages = pages.map { page -> Json in
            .object(["width": json(page["width"]), "height": json(page["height"]), "runs": json(page["runs"])])
        }

        let expected = Json.object(["pageCount": json(initial["pageCount"]), "pages": .array(expectedPages)])
        let observed = Json.object(["pageCount": .number(Double(pageCount)), "pages": .array(observedPages)])
        return difference(expected, observed, "$.initial").map { "\($0) (\(document))" }
    }

    /// A run as `CorpusRecorder.Run` records it.
    private static func observe(_ run: PdfTextRun) -> Json {
        .object([
            "text": .string(run.text),
            "object": .number(Double(run.objectIndex)),
            "objects": .number(Double(run.objectCount)),
            "font": .string(run.fontName),
            "size": .number(round(Double(run.fontSize))),
            "embedded": .bool(run.isFontEmbedded),
            "subset": .bool(run.isFontSubset),
            "invisible": .bool(run.isInvisible),
            "bounds": .array([run.bounds.left, run.bounds.bottom, run.bounds.right, run.bounds.top].map { Json.number(round(Double($0))) }),
        ])
    }

    /// `CorpusRecorder.Round`: `Math.Round(value, 2, MidpointRounding.AwayFromZero)`.
    private static func round(_ value: Double) -> Double { DotNetMath.round(value, 2, awayFromZero: true) }

    /// A value JSONSerialization read, as the corpus compares it.
    private static func json(_ value: Any?) -> Json {
        guard let value, !(value is NSNull) else {
            return .null
        }

        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        }

        if let text = value as? String {
            return .string(text)
        }

        if let array = value as? [Any] {
            return .array(array.map { json($0) })
        }

        if let object = value as? [String: Any] {
            return .object(object.mapValues { json($0) })
        }

        return .string("(unreadable \(type(of: value)))")
    }

    /// The first place two corpus values differ, as `ConformanceTests.Difference` finds it: objects
    /// have the same keys, arrays the same items, numbers differ by at most the tolerance, and text
    /// is the same code units.
    private static func difference(_ expected: Json, _ actual: Json, _ path: String) -> String? {
        switch (expected, actual) {
        case (.null, .null):
            return nil
        case let (.object(a), .object(b)):
            for key in Set(a.keys).union(b.keys).sorted(by: String.ordinalLess) {
                guard let x = a[key], let y = b[key] else {
                    return "\(path).\(key) is \(a[key] == nil ? "unexpected" : "missing")"
                }

                if let found = difference(x, y, "\(path).\(key)") {
                    return found
                }
            }

            return nil
        case let (.array(a), .array(b)):
            if a.count != b.count {
                return "\(path) has \(b.count) items, not \(a.count): \(describe(actual)) instead of \(describe(expected))"
            }

            for i in 0..<a.count {
                if let found = difference(a[i], b[i], "\(path)[\(i)]") {
                    return found
                }
            }

            return nil
        case let (.number(a), .number(b)):
            return abs(a - b) <= tolerance ? nil : "\(path) is \(b), not \(a)"
        case let (.bool(a), .bool(b)) where a == b:
            return nil
        case let (.string(a), .string(b)) where a.ordinalEquals(b):
            return nil
        default:
            return "\(path) is \(describe(actual)), not \(describe(expected))"
        }
    }

    private static func describe(_ value: Json) -> String {
        let text: String
        switch value {
        case .null:
            text = "null"
        case let .bool(flag):
            text = flag ? "true" : "false"
        case let .number(number):
            text = "\(number)"
        case let .string(string):
            text = "\"" + string.unicodeScalars.map { $0.value < 0x20 || $0.value > 0x7E ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined() + "\""
        case let .array(items):
            text = "[" + items.map(describe).joined(separator: ", ") + "]"
        case let .object(entries):
            text = "{" + entries.keys.sorted(by: String.ordinalLess).map { "\"\($0)\": \(describe(entries[$0]!))" }.joined(separator: ", ") + "}"
        }

        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    /// The root of the package: the closest folder above this file with a Package.swift.
    private static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }

            directory = directory.deletingLastPathComponent()
        }

        throw CorpusError(description: "The repository root wasn't found above \(#filePath).")
    }
}
