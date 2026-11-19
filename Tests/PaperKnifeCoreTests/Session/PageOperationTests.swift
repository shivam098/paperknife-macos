import XCTest
@testable import PaperKnifeCore

/// The test of PageOperationTests.cs the conformance corpus can't express: saving. The corpus
/// covers the page operations themselves (pages-*).
final class PageOperationTests: XCTestCase {
    func testSaveAs_WritesTheVerifiedSnapshotAndLeavesNoTemporaryFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paperknife-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let session = try DocumentSession.fromSnapshot(TestPdfs.numberedPages(2))
        defer {
            session.dispose()
        }

        try session.rotatePage(1, 1)
        let path = folder.appendingPathComponent("out.pdf").path

        try session.saveAs(path: path)

        XCTAssertFalse(session.isModified)
        XCTAssertEqual(session.filePath, path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(session.currentSnapshot.span))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["out.pdf"])
        let reopened = try DocumentSession.open(path: path)
        defer {
            reopened.dispose()
        }

        XCTAssertEqual(try reopened.getPageSize(1), PageSize(792, 612))
    }
}
