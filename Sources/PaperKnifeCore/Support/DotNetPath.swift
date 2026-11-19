import Foundation

/// .NET's `Path` on Unix, for the paths `DocumentSession` opens, reports and writes. `getFullPath`
/// makes a path absolute and removes "." and ".." segments and repeated separators, as .NET does,
/// without resolving symbolic links (`NSString.standardizingPath` can also drop "/private").
enum DotNetPath {
    /// `Path.GetFullPath(path)`.
    static func getFullPath(_ path: String) throws -> String {
        try ArgumentException.throwIfNullOrEmpty(path, "path")
        if path.utf16.contains(0) {
            throw ArgumentException("Null character in path.", "path")
        }

        let rooted = path.utf16.first == separator ? path : combine(FileManager.default.currentDirectoryPath, path)
        let units = rooted.units
        let collapsed = removeRelativeSegments(units, units.first == separator ? 1 : 0)
        return collapsed.isEmpty ? "/" : String(units: collapsed)
    }

    /// `Path.GetDirectoryName(path)`: nil for the root, or a path without a folder.
    static func getDirectoryName(_ path: String) -> String? {
        let units = path.units
        if units.isEmpty {
            return nil
        }

        let rootLength = units[0] == separator ? 1 : 0
        var end = units.count
        if end <= rootLength {
            return nil
        }

        while end > rootLength {
            end -= 1
            if units[end] == separator {
                break
            }
        }

        // Trim off any remaining separators.
        while end > rootLength && units[end - 1] == separator {
            end -= 1
        }

        // PathInternal.NormalizeDirectorySeparators: one separator where there are several.
        var normalized: [UInt16] = []
        for i in 0..<end where !(units[i] == separator && i + 1 < end && units[i + 1] == separator) {
            normalized.append(units[i])
        }

        return String(units: normalized)
    }

    /// `Path.GetFileName(path)`: what follows the last separator.
    static func getFileName(_ path: String) -> String {
        let units = path.units
        let last = units.lastIndex(of: separator) ?? -1
        return String(units: units[(last + 1)...])
    }

    /// `Path.Combine(path1, path2)`.
    static func combine(_ path1: String, _ path2: String) -> String {
        if path2.isEmpty {
            return path1
        }

        if path1.isEmpty || path2.utf16.first == separator {
            return path2
        }

        return path1.utf16.last == separator ? path1 + path2 : path1 + "/" + path2
    }

    private static let separator: UInt16 = 0x2F

    /// PathInternal.RemoveRelativeSegments: "//", "/./" and "/../" removed from a rooted path.
    private static func removeRelativeSegments(_ path: [UInt16], _ rootLength: Int) -> [UInt16] {
        var skip = rootLength

        // The first separator past the root is collapsed too.
        if skip > 0 && path[skip - 1] == separator {
            skip -= 1
        }

        var result = Array(path[0..<skip])
        var i = skip
        while i < path.count {
            let c = path[i]
            if c == separator && i + 1 < path.count {
                // "parent//child" => "parent/child"
                if path[i + 1] == separator {
                    i += 1
                    continue
                }

                // "parent/./child" => "parent/child"
                if (i + 2 == path.count || path[i + 2] == separator) && path[i + 1] == 0x2E {
                    i += 2
                    continue
                }

                // "parent/child/../grandchild" => "parent/grandchild"
                if i + 2 < path.count && (i + 3 == path.count || path[i + 3] == separator) && path[i + 1] == 0x2E && path[i + 2] == 0x2E {
                    // Unwind back to the last separator, and if there isn't one, clear out everything.
                    var s = result.count - 1
                    while s >= skip {
                        if result[s] == separator {
                            result.removeSubrange(((i + 3 >= path.count && s == skip) ? s + 1 : s)...)
                            break
                        }

                        s -= 1
                    }

                    if s < skip {
                        result.removeSubrange(skip...)
                    }

                    i += 3
                    continue
                }
            }

            result.append(c)
            i += 1
        }

        return result
    }
}
