import CryptoKit
import Foundation
import XCTest
@testable import PaperKnifeCore

/// The conformance corpus (conformance/, see its README.md): every stored case replayed through a
/// `DocumentSession` from its stored documents and steps, as PaperKnife for Windows'
/// `ConformanceTests.StoredCase_GivesTheStoredObservations` does, with what the session observes
/// recorded as `CorpusRecorder` records it. The record must be the stored case, compared as the
/// README's "Comparing" says (see `CorpusComparison`).
final class ConformanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SyntaxTestSupport.useRepositoryFonts()
    }

    func testStoredCases_GiveTheStoredObservations() throws {
        let ids = try Corpus.caseIds()
        XCTAssertFalse(ids.isEmpty, "The corpus hasn't been synced into conformance/.")
        var passed = 0
        var notes: [String] = []
        for id in ids {
            do {
                if let difference = try Corpus.run(id, &notes) {
                    XCTFail("cases/\(id).json: \(difference)")
                } else {
                    passed += 1
                }
            } catch {
                XCTFail("cases/\(id).json: \(error)")
            }
        }

        for note in notes {
            print(note)
        }

        print("Conformance corpus: \(passed) of \(ids.count) cases give the stored observations.")
    }

    // MARK: - The README's rules for other systems

    func testContentComparison_PassesTheSameContent() {
        let content = Latin1.bytes("BT /F1 12 Tf 96.012 700 Td <48656C6C6F> Tj ET ")

        XCTAssertNil(CorpusComparison.tokenDifference(content, content))
    }

    func testContentComparison_PassesNumbersWithinATenThousandth() {
        let expected = Latin1.bytes("BT /F1 12 Tf 96.012 700 Td (Hello) Tj ET ")
        let actual = Latin1.bytes("BT /F1 12 Tf 96.01201 700 Td (Hello) Tj ET ")

        XCTAssertNil(CorpusComparison.tokenDifference(expected, actual))
    }

    func testContentComparison_FailsNumbersFurtherApart() {
        let expected = Latin1.bytes("BT /F1 12 Tf 96.012 700 Td (Hello) Tj ET ")
        let actual = Latin1.bytes("BT /F1 12 Tf 96.0102 700 Td (Hello) Tj ET ")

        XCTAssertNotNil(CorpusComparison.tokenDifference(expected, actual))
    }

    func testContentComparison_FailsAnExtraToken() {
        let expected = Latin1.bytes("BT /F1 12 Tf 96.012 700 Td (Hello) Tj ET ")
        let actual = Latin1.bytes("BT /F1 12 Tf 96.012 700 Td (Hello) Tj ET Q ")

        XCTAssertNotNil(CorpusComparison.tokenDifference(expected, actual))
        XCTAssertNotNil(CorpusComparison.tokenDifference(actual, expected))
    }

    func testContentComparison_FailsADifferentOperator() {
        let expected = Latin1.bytes("BT /F1 12 Tf 96.012 700 Td (Hello) Tj ET ")
        let actual = Latin1.bytes("BT /F1 12 Tf 96.012 700 TD (Hello) Tj ET ")

        XCTAssertNotNil(CorpusComparison.tokenDifference(expected, actual))
    }

    func testBoundsComparison_AllowsATenthOfTheSizeForTheStandardFontsOnly() {
        func run(_ font: String, _ embedded: Bool, _ right: Double) -> CorpusJson {
            .object([
                ("text", .string("Hello")), ("object", .number(0)), ("objects", .number(1)), ("font", .string(font)),
                ("size", .number(12)), ("embedded", .bool(embedded)), ("subset", .bool(false)), ("invisible", .bool(false)),
                ("bounds", .array([.number(72), .number(700), .number(right), .number(712)])),
            ])
        }

        let comparison = CorpusComparison(contents: Corpus.contentsFolder, decoded: [:])
        XCTAssertNil(comparison.difference(run("Helvetica", false, 100), run("Helvetica", false, 101.1), "$"))
        XCTAssertNotNil(comparison.difference(run("Helvetica", false, 100), run("Helvetica", false, 101.3), "$"))
        XCTAssertNotNil(comparison.difference(run("Helvetica", true, 100), run("Helvetica", true, 100.1), "$"))
        XCTAssertNil(comparison.difference(run("STSong-Light", false, 100), run("STSong-Light", false, 122.68), "$"))
        XCTAssertNotNil(comparison.difference(run("STSong-Light", false, 100), run("Helvetica", false, 100), "$"))
    }
}

// MARK: - Running the stored cases

private struct CorpusError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// A step of a case as the corpus stores it (C#'s CorpusStep records).
private enum CorpusAction {
    case replaceText(page: Int, run: String, text: String, contentEditing: Bool)
    case replaceObject(page: Int, objectIndex: Int, text: String)
    case rotatePage(page: Int, quarterTurns: Int)
    case deletePage(page: Int)
    case movePage(from: Int, to: Int)
    case appendDocument(document: String, password: String?)
    case undo
    case redo
}

private struct CorpusStep {
    let action: CorpusAction

    /// The longest the step may take, for steps that guard against slow handling of crafted input.
    let maxMilliseconds: Int?
}

/// A case of the corpus (C#'s CorpusCase): what it is, what it guards against, and its steps.
private struct CorpusCase {
    let id: String
    let title: String
    let guards: String
    let steps: [CorpusStep]
    let password: String?
}

private enum Corpus {
    static let root = SyntaxTestSupport.repositoryRoot.appendingPathComponent("conformance")

    static let contentsFolder = root.appendingPathComponent("contents")

    /// The stored cases, in ordinal order of their ids.
    static func caseIds() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cases").path)
            .filter { $0.ordinalHasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted(by: String.ordinalLess)
    }

    /// `StoredCase_GivesTheStoredObservations`: the case run from its stored documents and steps;
    /// where the record first differs from the stored case, or nil.
    static func run(_ id: String, _ notes: inout [String]) throws -> String? {
        let stored = try CorpusJson.parse([UInt8](Data(contentsOf: root.appendingPathComponent("cases").appendingPathComponent("\(id).json"))))
        guard stored["format"]?.int == CorpusRecorder.format else {
            return "the case's format isn't \(CorpusRecorder.format)"
        }

        func load(_ name: String) throws -> PdfSnapshot {
            try PdfSnapshot.fromBytes([UInt8](Data(contentsOf: root.appendingPathComponent(name))))
        }

        var attachments: [(name: String, snapshot: PdfSnapshot)] = []
        for (name, value) in stored["attachments"]?.entries ?? [] {
            let snapshot = try load(value.requireString())
            attachments.append((name: name, snapshot: snapshot))
        }

        let corpusCase = CorpusCase(
            id: id,
            title: try stored.require("title").requireString(),
            guards: try stored.require("guards").requireString(),
            steps: try stored.require("steps").requireArray().map(step),
            password: stored["password"]?.string)
        let document = try load(try stored.require("document").requireString())
        var decoded: [String: [UInt8]] = [:]
        let observed = try CorpusRecorder.record(corpusCase, document, attachments, &decoded)
        let comparison = CorpusComparison(contents: contentsFolder, decoded: decoded)
        let difference = comparison.difference(stored, observed, "$")
        notes += comparison.notes.map { "cases/\(id).json: platform difference: \($0)" }
        return difference.map { "\($0). The case guards against this: \(corpusCase.guards)" }
    }

    /// A step as the corpus stores it.
    private static func step(_ json: CorpusJson) throws -> CorpusStep {
        let action: CorpusAction
        switch try json.require("action").requireString() {
        case "replaceText":
            action = .replaceText(
                page: try json.require("page").requireInt(),
                run: try json.require("run").requireString(),
                text: try json.require("text").requireString(),
                contentEditing: json["contentEditing"]?.bool ?? true)
        case "replaceObject":
            action = .replaceObject(
                page: try json.require("page").requireInt(), objectIndex: try json.require("object").requireInt(),
                text: try json.require("text").requireString())
        case "rotatePage":
            action = .rotatePage(page: try json.require("page").requireInt(), quarterTurns: try json.require("quarterTurns").requireInt())
        case "deletePage":
            action = .deletePage(page: try json.require("page").requireInt())
        case "movePage":
            action = .movePage(from: try json.require("from").requireInt(), to: try json.require("to").requireInt())
        case "appendDocument":
            action = .appendDocument(document: try json.require("document").requireString(), password: json["password"]?.string)
        case "undo":
            action = .undo
        case "redo":
            action = .redo
        case let other:
            throw CorpusError("Unknown action \(other).")
        }

        return CorpusStep(action: action, maxMilliseconds: json["maxMilliseconds"]?.int)
    }
}

/// CorpusRecorder: runs a case with the engine and records what it observes, in the format the
/// corpus stores.
private enum CorpusRecorder {
    static let format = 1

    /// The case as the corpus stores it. The decoded content of each page observed is kept in
    /// `decoded`, by its hash, for the comparison.
    static func record(
        _ corpusCase: CorpusCase, _ document: PdfSnapshot, _ attachments: [(name: String, snapshot: PdfSnapshot)],
        _ decoded: inout [String: [UInt8]]
    ) throws -> CorpusJson {
        var attachmentFiles: [(String, CorpusJson)] = []
        for (name, snapshot) in attachments.stableSorted(by: { String.ordinalLess($0.name, $1.name) }) {
            attachmentFiles.append((name, .string(keep("documents", ".pdf", Array(snapshot.span)))))
        }

        var result: [(String, CorpusJson)] = [
            ("format", .number(Double(format))),
            ("id", .string(corpusCase.id)),
            ("title", .string(corpusCase.title)),
            ("guards", .string(corpusCase.guards)),
            ("document", .string(keep("documents", ".pdf", Array(document.span)))),
        ]
        if let password = corpusCase.password {
            result.append(("password", .string(password)))
        }

        if !attachmentFiles.isEmpty {
            result.append(("attachments", .object(attachmentFiles)))
        }

        let session = try DocumentSession.fromSnapshot(document, corpusCase.password)
        defer {
            session.dispose()
        }

        var history = [Array(document.span)]
        result.append(("initial", try state(session, &history, 0, &decoded)))

        var steps: [CorpusJson] = []
        for (i, step) in corpusCase.steps.enumerated() {
            var json = try describe(step, session)
            let started = DispatchTime.now().uptimeNanoseconds
            let outcome = try perform(step, session, attachments)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            if let limit = step.maxMilliseconds, elapsed > limit {
                throw CorpusError("\(corpusCase.id) step \(i + 1) took \(elapsed) ms, more than \(limit) ms.")
            }

            let after = try state(session, &history, i + 1, &decoded)
            json.append(("expect", .object([("result", outcome), ("state", after)])))
            steps.append(.object(json))
        }

        result.append(("steps", .array(steps)))
        return .object(result)
    }

    /// The step as the corpus stores it, with the run it names as PaperKnife reads it.
    private static func describe(_ step: CorpusStep, _ session: DocumentSession) throws -> [(String, CorpusJson)] {
        var json: [(String, CorpusJson)]
        switch step.action {
        case let .replaceText(page, run, text, contentEditing):
            let found = try findRun(session, page, run)
            json = [
                ("action", .string("replaceText")), ("page", .number(Double(page))), ("run", .string(found.text)), ("text", .string(text)),
                ("contentEditing", .bool(contentEditing)),
            ]
        case let .replaceObject(page, objectIndex, text):
            json = [("action", .string("replaceObject")), ("page", .number(Double(page))), ("object", .number(Double(objectIndex))), ("text", .string(text))]
        case let .rotatePage(page, quarterTurns):
            json = [("action", .string("rotatePage")), ("page", .number(Double(page))), ("quarterTurns", .number(Double(quarterTurns)))]
        case let .deletePage(page):
            json = [("action", .string("deletePage")), ("page", .number(Double(page)))]
        case let .movePage(from, to):
            json = [("action", .string("movePage")), ("from", .number(Double(from))), ("to", .number(Double(to)))]
        case let .appendDocument(document, password):
            json = [("action", .string("appendDocument")), ("document", .string(document))]
            if let password {
                json.append(("password", .string(password)))
            }
        case .undo:
            json = [("action", .string("undo"))]
        case .redo:
            json = [("action", .string("redo"))]
        }

        if let limit = step.maxMilliseconds {
            json.append(("maxMilliseconds", .number(Double(limit))))
        }

        return json
    }

    private static func perform(_ step: CorpusStep, _ session: DocumentSession, _ attachments: [(name: String, snapshot: PdfSnapshot)]) throws -> CorpusJson {
        switch step.action {
        case let .replaceText(page, run, text, contentEditing):
            session.useContentEditing = contentEditing
            defer {
                session.useContentEditing = true
            }

            return try result(session.replaceText(page, findRun(session, page, run).objectIndex, text))
        case let .replaceObject(page, objectIndex, text):
            return try result(session.replaceText(page, objectIndex, text))
        case let .rotatePage(page, quarterTurns):
            return try result(session.rotatePage(page, quarterTurns))
        case let .deletePage(page):
            return try result(session.deletePage(page))
        case let .movePage(from, to):
            return try result(session.movePage(from, to))
        case let .appendDocument(document, password):
            guard let attachment = attachments.first(where: { $0.name.ordinalEquals(document) }) else {
                throw CorpusError("The case has no attachment named \(document).")
            }

            return try result(session.appendDocument(attachment.snapshot, password))
        case .undo:
            let done = try session.undo()
            return .object([("done", .bool(done))])
        case .redo:
            let done = try session.redo()
            return .object([("done", .bool(done))])
        }
    }

    /// The run with exactly this text on a page, or with text equivalent to it when there is no exact one.
    private static func findRun(_ session: DocumentSession, _ page: Int, _ text: String) throws -> PdfTextRun {
        let runs = try session.getTextRuns(page)
        let exact = runs.filter { $0.text.ordinalEquals(text) }
        let matches = try exact.count > 0 ? exact : runs.filter { try TextEquivalence.areEquivalent($0.text, text) }
        guard matches.count == 1 else {
            throw CorpusError("\(matches.count) runs on page \(page + 1) read “\(text)”; a step must name exactly one.")
        }

        return matches[0]
    }

    private static func result(_ result: EditResult) -> CorpusJson {
        .object([
            ("status", .string(result.status.rawValue)),
            ("rejection", .string(result.rejection.rawValue)),
            ("message", .string(result.message)),
            ("details", strings(result.details)),
            ("warnings", strings(result.warnings)),
            ("unsupportedCharacters", strings(result.unsupportedCharacters)),
            ("run", result.textRun.map(run) ?? .null),
        ])
    }

    /// The document as a reader sees it after a step: its pages, their text runs, decoded content
    /// and fonts, the undo state, and whether its bytes are those of an earlier state or extend the
    /// previous one.
    private static func state(
        _ session: DocumentSession, _ history: inout [[UInt8]], _ stepIndex: Int, _ decoded: inout [String: [UInt8]]
    ) throws -> CorpusJson {
        let bytes = Array(session.currentSnapshot.span)
        let pageCount = try session.pageCount
        var state: [(String, CorpusJson)] = [
            ("pageCount", .number(Double(pageCount))),
            ("modified", .bool(session.isModified)),
            ("canUndo", .bool(session.canUndo)),
            ("canRedo", .bool(session.canRedo)),
        ]
        if stepIndex > 0 {
            let same = history.firstIndex(of: bytes)
            state.append(("sameAs", same.map { CorpusJson.number(Double($0)) } ?? CorpusJson.null))
            state.append(("appended", .bool(bytes.starts(with: history[history.count - 1]))))
            history.append(bytes)
        }

        var file = try PdfFile.tryOpen(bytes)
        if file?.isEncrypted == true {
            file = nil
        }

        let nodes = try file?.getPages()
        var pages: [CorpusJson] = []
        for page in 0..<pageCount {
            let size = try session.getPageSize(page)
            let runs = try session.getTextRuns(page)
            let blockers = try session.getTextEditBlockers(page)
            var json: [(String, CorpusJson)] = [
                ("width", .number(round(Double(size.width)))),
                ("height", .number(round(Double(size.height)))),
                ("runs", .array(runs.map(run))),
                ("blockers", strings(blockers)),
            ]

            // Decoded content as PaperKnife's own reader gives it, or null when it doesn't read the page.
            var content: [UInt8]?
            var fonts = CorpusJson.null
            if let file, let nodes, page < nodes.count {
                content = try ContentPage.tryLoad(file, nodes, page)?.content
                fonts = try CorpusRecorder.fonts(file, nodes[page])
            }

            if let content {
                let hash = sha256(content)
                decoded[hash] = content
                json.append(("content", .string(hash)))
            } else {
                json.append(("content", .null))
            }

            json.append(("fonts", fonts))
            pages.append(.object(json))
        }

        state.append(("pages", .array(pages)))
        return .object(state)
    }

    private static func run(_ run: PdfTextRun) -> CorpusJson {
        let bounds = [run.bounds.left, run.bounds.bottom, run.bounds.right, run.bounds.top]
        return .object([
            ("text", .string(run.text)),
            ("object", .number(Double(run.objectIndex))),
            ("objects", .number(Double(run.objectCount))),
            ("font", .string(run.fontName)),
            ("size", .number(round(Double(run.fontSize)))),
            ("embedded", .bool(run.isFontEmbedded)),
            ("subset", .bool(run.isFontSubset)),
            ("invisible", .bool(run.isInvisible)),
            ("bounds", .array(bounds.map { CorpusJson.number(round(Double($0))) })),
        ])
    }

    /// The page's fonts in a form that doesn't depend on how a writer ordered or compressed them.
    private static func fonts(_ file: PdfFile, _ page: PdfPageNode) throws -> CorpusJson {
        var fonts: [CorpusJson] = []
        let entries = try file.resolveDict(page.resources?["Font"])?.entries.map { ($0.key, $0.value) } ?? []
        for (name, value) in entries.stableSorted(by: { String.ordinalLess($0.0, $1.0) }) {
            guard let font = try file.resolveDict(value) else {
                fonts.append(.object([("name", .string(name))]))
                continue
            }

            let descriptor = try file.resolveDict(font["FontDescriptor"])
            let key = ["FontFile", "FontFile2", "FontFile3"].first(where: { descriptor?[$0] != nil })
            var program: CosStream?
            if let key, let descriptor {
                program = try file.resolve(descriptor[key]) as? CosStream
            }

            var widths = CorpusJson.null
            if let array = try file.resolveArray(font["Widths"]) {
                widths = .array(try array.items.map { try number(file.resolveNumber($0)) })
            }

            var programLength = CorpusJson.null
            if let program, let data = try file.decodeStream(program) {
                programLength = .number(Double(data.count))
            }

            fonts.append(.object([
                ("name", .string(name)),
                ("subtype", string(try file.resolveName(font["Subtype"]))),
                ("baseFont", string(try file.resolveName(font["BaseFont"]))),
                ("firstChar", number(try file.resolveNumber(font["FirstChar"]))),
                ("lastChar", number(try file.resolveNumber(font["LastChar"]))),
                ("widths", widths),
                ("encoding", try encoding(file, font["Encoding"])),
                ("toUnicode", .bool(font["ToUnicode"] != nil)),
                ("flags", number(try file.resolveNumber(descriptor?["Flags"]))),
                ("fontFile", string(key)),
                ("programLength", programLength),
            ]))
        }

        return .array(fonts)
    }

    private static func encoding(_ file: PdfFile, _ entry: CosObject?) throws -> CorpusJson {
        switch try file.resolve(entry) {
        case nil:
            return .null
        case let name as CosName:
            return .string(name.value)
        case let dict as CosDict:
            // A JsonObject: a code named again keeps its place and takes the new glyph.
            var differences: [(String, CorpusJson)] = []
            var next = 0
            for item in try file.resolveArray(dict["Differences"])?.items ?? [] {
                let resolved = try file.resolve(item)
                if let number = resolved as? CosNumber {
                    next = DotNetMath.toInt32(number.value)
                } else if let glyph = resolved as? CosName {
                    let code = String(next)
                    if let index = differences.firstIndex(where: { $0.0 == code }) {
                        differences[index].1 = .string(glyph.value)
                    } else {
                        differences.append((code, .string(glyph.value)))
                    }

                    next = Int(Int32(truncatingIfNeeded: next) &+ 1)
                }
            }

            return .object([("base", string(try file.resolveName(dict["BaseEncoding"]))), ("differences", .object(differences))])
        default:
            return .string("(other)")
        }
    }

    /// Keeps a file under its folder, named by the first 12 hex digits of its SHA-256.
    private static func keep(_ folder: String, _ fileExtension: String, _ bytes: [UInt8]) -> String {
        "\(folder)/\(sha256(bytes).prefix(12))\(fileExtension)"
    }

    private static func strings(_ values: [String]) -> CorpusJson { .array(values.map { CorpusJson.string($0) }) }

    private static func string(_ value: String?) -> CorpusJson { value.map { .string($0) } ?? .null }

    /// `Math.Round(value, 2, MidpointRounding.AwayFromZero)`.
    private static func round(_ value: Double) -> Double { DotNetMath.round(value, 2, awayFromZero: true) }

    /// A number as the corpus keeps it: rounded to 4 decimals, half away from zero.
    private static func number(_ value: Double?) -> CorpusJson { value.map { .number(DotNetMath.round($0, 4, awayFromZero: true)) } ?? .null }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Comparing

/// Compares a stored case with its record as ConformanceTests.Difference does, as
/// conformance/README.md's "Comparing" says: objects have the same keys, in the same order;
/// arrays the same items in the same order; numbers may differ by up to 0.011; everything else,
/// messages included, is the same. On a system other than Windows, `PlatformDifferences` relaxes
/// the bounds of runs whose font isn't embedded and the content of pages that have such runs.
final class CorpusComparison {
    /// Numbers may differ this much between platforms (they are rounded to 0.01).
    static let tolerance = 0.011

    /// The corpus's contents folder: the decoded content of pages, by the first 12 digits of its hash.
    let contents: URL

    /// The decoded content of each page the record observed, by its hash.
    let decoded: [String: [UInt8]]

    /// The values the rules for other systems let differ, and how.
    private(set) var notes: [String] = []

    init(contents: URL, decoded: [String: [UInt8]]) {
        self.contents = contents
        self.decoded = decoded
    }

    /// Where the record first differs from the stored case, or nil.
    func difference(_ expected: CorpusJson, _ actual: CorpusJson, _ path: String) -> String? {
        switch (expected, actual) {
        case (.null, .null):
            return nil
        case let (.object(a), .object(b)):
            let aKeys = a.map { $0.0 }
            let bKeys = b.map { $0.0 }
            for key in aKeys + bKeys.filter({ key in !aKeys.contains { $0.ordinalEquals(key) } }) {
                let inA = aKeys.contains { $0.ordinalEquals(key) }
                let inB = bKeys.contains { $0.ordinalEquals(key) }
                if !inA || !inB {
                    return "\(path).\(key) is \(inA ? "missing" : "unexpected")"
                }
            }

            if !aKeys.elementsEqual(bKeys, by: { $0.ordinalEquals($1) }) {
                return "\(path) has its keys in the order \(bKeys), not \(aKeys)"
            }

            for i in 0..<a.count {
                let (key, x) = a[i]
                let y = b[i].1
                let at = "\(path).\(key)"
                switch PlatformDifferences.compare(self, a, key, x, y, at) {
                case .compared(let found):
                    if let found {
                        return found
                    }
                case .notApplicable:
                    if let found = difference(x, y, at) {
                        return found
                    }
                }
            }

            return nil
        case let (.array(a), .array(b)):
            if a.count != b.count {
                return "\(path) has \(b.count) items, not \(a.count): \(actual.shortened) instead of \(expected.shortened)"
            }

            for i in 0..<a.count {
                if let found = difference(a[i], b[i], "\(path)[\(i)]") {
                    return found
                }
            }

            return nil
        case let (.number(x), .number(y)):
            return abs(x - y) <= Self.tolerance ? nil : "\(path) is \(actual.shortened), not \(expected.shortened)"
        case let (.bool(x), .bool(y)) where x == y:
            return nil
        case let (.string(x), .string(y)) where x.ordinalEquals(y):
            return nil
        default:
            return "\(path) is \(actual.shortened), not \(expected.shortened)\(contentDifference(path, expected, actual))"
        }
    }

    fileprivate func note(_ note: String) {
        notes.append(note)
    }

    /// Where decoded content first differs from the content the corpus keeps for the expected
    /// hash, to show with a difference in a page's `content`.
    private func contentDifference(_ path: String, _ expected: CorpusJson, _ actual: CorpusJson) -> String {
        guard path.ordinalHasSuffix(".content"), let hash = expected.string, let actualHash = actual.string,
            let stored = try? [UInt8](Data(contentsOf: contents.appendingPathComponent("\(hash.prefix(12)).content"))),
            let content = decoded[actualHash] else {
            return ""
        }

        let common = zip(stored, content).prefix { $0 == $1 }.count
        let context = { (bytes: [UInt8]) in Latin1.string(bytes[max(0, common - 20)..<min(bytes.count, common + 40)]) }
        return " (first difference at byte \(common) of \(stored.count): expected “\(context(stored))”, got “\(context(content))”)"
    }

    /// Where two decoded contents first differ, token by token as `PdfLexer` reads them: numbers
    /// may differ by up to 0.0001, and every other token must be the same.
    static func tokenDifference(_ expected: [UInt8], _ actual: [UInt8]) -> String? {
        let a = PdfLexer(expected)
        let b = PdfLexer(actual)
        var index = 0
        while true {
            let x = a.next()
            let y = b.next()
            if x.kind == .end && y.kind == .end {
                return nil
            }

            if x.kind == .number && y.kind == .number {
                if abs(x.number - y.number) > 0.0001 {
                    return "token \(index) is \(y.text), not \(x.text)"
                }
            } else if x.kind != y.kind || !expected[x.start..<x.end].elementsEqual(actual[y.start..<y.end]) {
                return "token \(index) is “\(Latin1.string(actual[y.start..<y.end]))”, not “\(Latin1.string(expected[x.start..<x.end]))”"
            }

            index += 1
        }
    }
}

/// The README's rules for systems other than Windows, where PDFium draws a font that isn't
/// embedded with a font of the system it runs on:
/// - the `bounds` of a run whose font isn't embedded may differ by up to a tenth of the run's
///   `size` for one of the standard 14 fonts, and aren't compared for other fonts;
/// - a page's `content` may differ when the page has such a run, if its decoded content has the
///   same tokens as the corpus's `contents/<hash>.content`, numbers within 0.0001.
/// They apply to the initial state and to the state and result after every step alike.
private enum PlatformDifferences {
    enum Outcome {
        /// The rule compared the values: the difference, or nil when the rule allows them.
        case compared(String?)

        /// The rule doesn't apply: the values are compared as everywhere else.
        case notApplicable
    }

    #if os(Windows)
    static let otherSystem = false
    #else
    static let otherSystem = true
    #endif

    static let standard14: Set<String> = [
        "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique", "Helvetica", "Helvetica-Bold", "Helvetica-Oblique",
        "Helvetica-BoldOblique", "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic", "Symbol", "ZapfDingbats",
    ]

    /// Compares the value at `key` of an expected object (a run, a page, or anything else) with
    /// the observed one, when a rule applies to it.
    static func compare(
        _ comparison: CorpusComparison, _ object: [(String, CorpusJson)], _ key: String, _ expected: CorpusJson, _ actual: CorpusJson,
        _ path: String
    ) -> Outcome {
        guard otherSystem else {
            return .notApplicable
        }

        if key == "bounds" && isRun(object) && value(object, "embedded")?.bool == false {
            return compareBounds(comparison, object, expected, actual, path)
        }

        if key == "content" && value(object, "runs") != nil {
            return compareContent(comparison, object, expected, actual, path)
        }

        return .notApplicable
    }

    private static func compareBounds(
        _ comparison: CorpusComparison, _ run: [(String, CorpusJson)], _ expected: CorpusJson, _ actual: CorpusJson, _ path: String
    ) -> Outcome {
        guard let font = value(run, "font")?.string, let size = value(run, "size")?.number else {
            return .notApplicable
        }

        if !standard14.contains(font) {
            if comparison.difference(expected, actual, path) != nil {
                comparison.note("\(path) is \(actual.shortened), not \(expected.shortened); not compared, as the font “\(font)” isn't embedded")
            }

            return .compared(nil)
        }

        guard let a = expected.array, let b = actual.array, a.count == 4, b.count == 4 else {
            return .notApplicable
        }

        let allowed = max(size / 10, CorpusComparison.tolerance)
        var largest = 0.0
        for i in 0..<4 {
            guard let x = a[i].number, let y = b[i].number else {
                return .notApplicable
            }

            if !(abs(x - y) <= allowed) {
                return .compared("\(path) is \(actual.shortened), not \(expected.shortened), more than a tenth of the size of the font “\(font)”, which isn't embedded, apart")
            }

            largest = max(largest, abs(x - y))
        }

        if largest > CorpusComparison.tolerance {
            comparison.note("\(path) is \(actual.shortened), not \(expected.shortened): \(largest) apart, as the font “\(font)” isn't embedded")
        }

        return .compared(nil)
    }

    private static func compareContent(
        _ comparison: CorpusComparison, _ page: [(String, CorpusJson)], _ expected: CorpusJson, _ actual: CorpusJson, _ path: String
    ) -> Outcome {
        guard let hash = expected.string, let actualHash = actual.string, !hash.ordinalEquals(actualHash),
            let runs = value(page, "runs")?.array, runs.contains(where: { $0["embedded"]?.bool == false }) else {
            return .notApplicable
        }

        let file = "contents/\(hash.prefix(12)).content"
        guard let stored = try? [UInt8](Data(contentsOf: comparison.contents.appendingPathComponent("\(hash.prefix(12)).content"))) else {
            return .compared("\(path) is \(actual.shortened), not \(expected.shortened), and the corpus has no \(file) to compare it with")
        }

        guard let content = comparison.decoded[actualHash] else {
            return .compared("\(path) is \(actual.shortened), not \(expected.shortened), and the record has no content with that hash")
        }

        if let difference = CorpusComparison.tokenDifference(stored, content) {
            return .compared("\(path) is \(actual.shortened), not \(expected.shortened): its \(difference) in \(file)")
        }

        comparison.note("\(path) is \(actual.shortened), not \(expected.shortened); the tokens of \(file) match, numbers within 0.0001")
        return .compared(nil)
    }

    /// Whether an object is a run as the corpus records one.
    private static func isRun(_ object: [(String, CorpusJson)]) -> Bool {
        ["text", "object", "objects", "font", "size", "embedded", "subset", "invisible", "bounds"].allSatisfy { value(object, $0) != nil }
    }

    private static func value(_ object: [(String, CorpusJson)], _ key: String) -> CorpusJson? {
        object.first(where: { $0.0.ordinalEquals(key) })?.1
    }
}

// MARK: - JSON

/// A JSON value as the corpus stores it, with every object's keys in their order.
indirect enum CorpusJson {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CorpusJson])
    case object([(String, CorpusJson)])

    subscript(_ key: String) -> CorpusJson? {
        entries?.first(where: { $0.0.ordinalEquals(key) })?.1
    }

    var entries: [(String, CorpusJson)]? {
        if case let .object(entries) = self {
            return entries
        }

        return nil
    }

    var array: [CorpusJson]? {
        if case let .array(items) = self {
            return items
        }

        return nil
    }

    var string: String? {
        if case let .string(value) = self {
            return value
        }

        return nil
    }

    var number: Double? {
        if case let .number(value) = self {
            return value
        }

        return nil
    }

    var int: Int? { number.flatMap { Int(exactly: $0) } }

    var bool: Bool? {
        if case let .bool(value) = self {
            return value
        }

        return nil
    }

    fileprivate func require(_ key: String) throws -> CorpusJson {
        guard let value = self[key] else {
            throw CorpusError("The case has no \(key).")
        }

        return value
    }

    fileprivate func requireString() throws -> String {
        guard let value = string else {
            throw CorpusError("\(shortened) isn't a string.")
        }

        return value
    }

    fileprivate func requireInt() throws -> Int {
        guard let value = int else {
            throw CorpusError("\(shortened) isn't a whole number.")
        }

        return value
    }

    fileprivate func requireArray() throws -> [CorpusJson] {
        guard let value = array else {
            throw CorpusError("\(shortened) isn't an array.")
        }

        return value
    }

    /// The value in compact JSON, cut to 300 characters, for messages.
    var shortened: String {
        let text = self.text
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    private var text: String {
        switch self {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .number(value):
            return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : "\(value)"
        case let .string(value):
            return CorpusJson.quoted(value)
        case let .array(items):
            return "[" + items.map { $0.text }.joined(separator: ",") + "]"
        case let .object(entries):
            return "{" + entries.map { CorpusJson.quoted($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    private static func quoted(_ value: String) -> String {
        var text = "\""
        for unit in value.utf16 {
            switch unit {
            case 0x22: text += "\\\""
            case 0x5C: text += "\\\\"
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x09: text += "\\t"
            case 0..<0x20, 0xD800...0xDFFF:
                text += "\\u" + String(format: "%04X", UInt32(unit))
            default:
                text += String(units: [unit])
            }
        }

        return text + "\""
    }

    /// Reads JSON (RFC 8259), keeping the order of every object's keys.
    static func parse(_ bytes: [UInt8]) throws -> CorpusJson {
        var parser = JsonParser(bytes)
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.position == bytes.count else {
            throw CorpusError("There is more after the JSON value, at byte \(parser.position).")
        }

        return value
    }
}

private struct JsonParser {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func skipWhitespace() {
        while position < bytes.count && (bytes[position] == 0x20 || bytes[position] == 0x09 || bytes[position] == 0x0A || bytes[position] == 0x0D) {
            position += 1
        }
    }

    mutating func value() throws -> CorpusJson {
        skipWhitespace()
        guard position < bytes.count else {
            throw failure("a value")
        }

        switch bytes[position] {
        case UInt8(ascii: "{"):
            return try object()
        case UInt8(ascii: "["):
            return try array()
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            try literal("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try literal("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try literal("null")
            return .null
        default:
            return try number()
        }
    }

    private mutating func object() throws -> CorpusJson {
        position += 1
        var entries: [(String, CorpusJson)] = []
        skipWhitespace()
        if position < bytes.count && bytes[position] == UInt8(ascii: "}") {
            position += 1
            return .object(entries)
        }

        while true {
            skipWhitespace()
            guard position < bytes.count && bytes[position] == UInt8(ascii: "\"") else {
                throw failure("a key")
            }

            let key = try string()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            let item = try value()
            entries.append((key, item))
            skipWhitespace()
            if position < bytes.count && bytes[position] == UInt8(ascii: ",") {
                position += 1
                continue
            }

            try expect(UInt8(ascii: "}"))
            return .object(entries)
        }
    }

    private mutating func array() throws -> CorpusJson {
        position += 1
        var items: [CorpusJson] = []
        skipWhitespace()
        if position < bytes.count && bytes[position] == UInt8(ascii: "]") {
            position += 1
            return .array(items)
        }

        while true {
            items.append(try value())
            skipWhitespace()
            if position < bytes.count && bytes[position] == UInt8(ascii: ",") {
                position += 1
                continue
            }

            try expect(UInt8(ascii: "]"))
            return .array(items)
        }
    }

    /// A string's UTF-16 code units, as C# keeps them; an unpaired surrogate becomes U+FFFD.
    private mutating func string() throws -> String {
        position += 1
        var units: [UInt16] = []
        while true {
            guard position < bytes.count else {
                throw failure("the end of a string")
            }

            let b = bytes[position]
            if b == UInt8(ascii: "\"") {
                position += 1
                return String(units: units)
            }

            if b == UInt8(ascii: "\\") {
                guard position + 1 < bytes.count else {
                    throw failure("an escape")
                }

                let e = bytes[position + 1]
                position += 2
                switch e {
                case UInt8(ascii: "\""): units.append(0x22)
                case UInt8(ascii: "\\"): units.append(0x5C)
                case UInt8(ascii: "/"): units.append(0x2F)
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"):
                    guard position + 4 <= bytes.count, let unit = UInt16(String(decoding: bytes[position..<(position + 4)], as: UTF8.self), radix: 16) else {
                        throw failure("four hexadecimal digits")
                    }

                    units.append(unit)
                    position += 4
                default:
                    throw failure("an escape")
                }

                continue
            }

            if b < 0x80 {
                units.append(UInt16(b))
                position += 1
                continue
            }

            // A UTF-8 sequence: its lead byte says how long it is.
            let length = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
            let end = min(bytes.count, position + length)
            units.append(contentsOf: String(decoding: bytes[position..<end], as: UTF8.self).utf16)
            position = end
        }
    }

    private mutating func number() throws -> CorpusJson {
        let start = position
        while position < bytes.count && Self.isNumberByte(bytes[position]) {
            position += 1
        }

        guard position > start, let value = Double(String(decoding: bytes[start..<position], as: UTF8.self)) else {
            throw failure("a value")
        }

        return .number(value)
    }

    private static func isNumberByte(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "-") || b == UInt8(ascii: "+") || b == UInt8(ascii: ".")
            || b == UInt8(ascii: "e") || b == UInt8(ascii: "E")
    }

    private mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard position + expected.count <= bytes.count, bytes[position..<(position + expected.count)].elementsEqual(expected) else {
            throw failure(text)
        }

        position += expected.count
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard position < bytes.count && bytes[position] == byte else {
            throw failure("“\(Latin1.string([byte]))”")
        }

        position += 1
    }

    private func failure(_ expected: String) -> CorpusError {
        CorpusError("The JSON doesn't have \(expected) at byte \(position).")
    }
}
