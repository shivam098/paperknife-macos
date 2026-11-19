import Foundation

/// The full fonts PaperKnife ships to draw new letters in subset fonts of PDFs made with TeX, the
/// versions TeX distributions embed, all unmodified: the Type 1 Computer Modern fonts of the
/// American Mathematical Society (amsfonts 3.04, SIL Open Font License 1.1), Latin Modern (lm
/// 2.004, GUST Font License) and CM-Super (0.3.4, GNU GPL with a font exception). The Windows app
/// compiles the AMS fonts in and ships the others in a Fonts folder; this one ships all of them as
/// files in its bundle's Resources/Fonts (amsfonts, cm-super and lm, with the Adobe Glyph List).
/// See third_party/amsfonts, third_party/lm and third_party/cm-super.
enum BundledFonts {
    private static let lock = NSLock()
    private static var configuredDirectories: [URL]?
    private static var sources: [OrdinalString: URL]?
    private static var cache: [OrdinalString: Type1Font?] = [:]

    /// The fonts' folder in the app bundle: Contents/Resources/Fonts.
    static var bundleRoot: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Fonts", isDirectory: true)
    }

    /// The folders whose .pfb files are the fonts, searched one after the other, each with its
    /// subfolders in ordinal order of the paths; where two files give the same name, the first
    /// counts. By default the bundle's fonts folder, where that order (amsfonts, cm-super, lm) is
    /// the precedence the Windows app gives them. Setting it finds the fonts again when one is next
    /// needed.
    static var fontDirectories: [URL] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return configuredDirectories ?? [bundleRoot]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            configuredDirectories = newValue
            sources = nil
            cache = [:]
        }
    }

    /// The full font with this PostScript name (for example "CMBX10", "LMRoman10-Regular" or
    /// "SFRM1000"), or nil when PaperKnife doesn't ship it.
    static func findType1(_ postScriptName: String) -> Type1Font? {
        lock.lock()
        defer { lock.unlock() }
        if sources == nil {
            sources = findSources(configuredDirectories ?? [bundleRoot])
        }

        let key = OrdinalString(postScriptName)
        guard let url = sources?[key] else {
            return nil
        }

        if let cached = cache[key] {
            return cached
        }

        var font: Type1Font?
        if let data = read(url, headerOnly: false), let parsed = Type1Font.fromPfb(data[...]), parsed.fontName.ordinalEquals(postScriptName) {
            font = parsed
        }

        cache.updateValue(font, forKey: key)
        return font
    }

    /// Every font by the name its program gives itself, which isn't always its file name (Latin
    /// Modern's lmr10.pfb is LMRoman10-Regular). A name from a PDF is only ever looked up here,
    /// never turned into a path.
    private static func findSources(_ directories: [URL]) -> [OrdinalString: URL] {
        var sources: [OrdinalString: URL] = [:]
        for directory in directories {
            for url in pfbFiles(directory) {
                if let header = read(url, headerOnly: true), let name = Type1Font.readFontName(header), sources[OrdinalString(name)] == nil {
                    sources[OrdinalString(name)] = url
                }
            }
        }

        return sources
    }

    /// The .pfb files in a folder and its subfolders, in ordinal order of their paths.
    private static func pfbFiles(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "pfb" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }

        return files.stableSorted { String.ordinalLess($0.path, $1.path) }
    }

    /// A PFB file, or with `headerOnly` its first, cleartext part; nil when it can't be read.
    private static func read(_ url: URL, headerOnly: Bool) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        guard let length = try? handle.seekToEnd(), length <= UInt64(Type1Font.maxProgram + 64), (try? handle.seek(toOffset: 0)) != nil else {
            return nil
        }

        if !headerOnly {
            return readExactly(handle, Int(length))
        }

        guard let segment = readExactly(handle, 6) else {
            return nil
        }

        let size = Int(Int32(bitPattern: UInt32(segment[2]) | UInt32(segment[3]) << 8 | UInt32(segment[4]) << 16 | UInt32(segment[5]) << 24))
        if segment[0] != 0x80 || segment[1] != 1 || size <= 0 || size > Type1Font.maxCleartext {
            return nil
        }

        return readExactly(handle, size)
    }

    /// Exactly `count` bytes, or nil when the file ends first, as .NET's ReadExactly fails then.
    private static func readExactly(_ handle: FileHandle, _ count: Int) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            guard let data = try? handle.read(upToCount: count - bytes.count), !data.isEmpty else {
                return nil
            }

            bytes += data
        }

        return bytes
    }
}
