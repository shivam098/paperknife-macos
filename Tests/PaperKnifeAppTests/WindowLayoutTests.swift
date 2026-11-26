import AppKit
import XCTest
@testable import PaperKnifeApp

final class WindowLayoutTests: XCTestCase {
    @MainActor
    func testHostingLayoutKeepsTheWindowMinimum() throws {
        _ = NSApplication.shared
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        // The hosting view schedules its window sizing update for the next run-loop pass.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertGreaterThanOrEqual(window.minSize.width, 960)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 600)
    }
}
