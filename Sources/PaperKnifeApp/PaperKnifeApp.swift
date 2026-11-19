import AppKit
import Foundation
import PaperKnifeCore

@main
enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--self-check" {
            exit(selfCheck())
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    /// Checks, without opening a window, that this copy of the app works (see `SelfCheck`).
    private static func selfCheck() -> Int32 {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(not in an app bundle)"
        #if arch(arm64)
        let architecture = "Apple silicon"
        #else
        let architecture = "Intel"
        #endif
        print("PaperKnife \(version) self-check on \(architecture), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("App: \(Bundle.main.bundlePath)")
        let result = SelfCheck.run(fonts: AppResources.fonts)
        result.lines.forEach { print($0) }
        print(result.passed ? "Passed." : "Failed.")
        return result.passed ? 0 : 1
    }
}

/// Where the app bundle keeps what the engine reads.
enum AppResources {
    /// The fonts PaperKnife draws new letters with, and the Adobe Glyph List.
    static var fonts: URL {
        Bundle.main.resourceURL!.appendingPathComponent("Fonts", isDirectory: true)
    }
}
