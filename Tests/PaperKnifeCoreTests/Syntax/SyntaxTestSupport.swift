import Foundation
@testable import PaperKnifeCore

/// What the Syntax, Content and Fonts tests share: where the repository's files are, the fonts the
/// app bundle ships (from third_party/).
enum SyntaxTestSupport {
    /// The package root, found from this file's path.
    static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            let parent = url.deletingLastPathComponent()
            precondition(parent.path != url.path, "The repository root wasn't found.")
            url = parent
        }

        return url
    }()

    /// third_party/'s font folders, in the precedence the app bundle's layout gives them.
    static var fontDirectories: [URL] {
        let thirdParty = repositoryRoot.appendingPathComponent("third_party")
        return ["amsfonts", "cm-super", "lm"].map { thirdParty.appendingPathComponent($0).appendingPathComponent("fonts") }
    }

    /// Points BundledFonts and Encodings at third_party/, which has the files the app bundle ships.
    static func useRepositoryFonts() {
        if BundledFonts.fontDirectories != fontDirectories {
            BundledFonts.fontDirectories = fontDirectories
        }

        let glyphList = repositoryRoot.appendingPathComponent("third_party").appendingPathComponent("agl").appendingPathComponent("glyphlist.txt")
        if Encodings.glyphListURL != glyphList {
            Encodings.glyphListURL = glyphList
        }
    }
}
