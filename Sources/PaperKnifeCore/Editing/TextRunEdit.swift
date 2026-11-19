/// The smallest change to a run's text objects that gives it new text. The objects `first` to
/// `last` (positions in the run) are replaced by one object drawing `newText`, which may be empty;
/// objects before them keep their place, and objects after them keep their characters and move
/// along the baseline as a block.
struct TextRunEdit: Equatable, CustomStringConvertible {
    var first: Int
    var last: Int
    var newText: String

    init(_ first: Int, _ last: Int, _ newText: String) {
        self.first = first
        self.last = last
        self.newText = newText
    }

    var description: String { "TextRunEdit { First = \(first), Last = \(last), NewText = \(newText) }" }

    /// A C# record struct's equality: the text compared ordinally.
    static func == (a: TextRunEdit, b: TextRunEdit) -> Bool {
        a.first == b.first && a.last == b.last && a.newText.ordinalEquals(b.newText)
    }

    /// Removes all `count` objects of a run, spaces drawn at its end included.
    static func deleteAll(_ count: Int) -> TextRunEdit { TextRunEdit(0, count - 1, "") }

    /// Whether this edit removes every object of a run of `count` objects.
    func deletesAll(_ count: Int) -> Bool { first == 0 && last == count - 1 && newText.length == 0 }

    /// - Parameters:
    ///   - pieces: The text of each object in the run, in order.
    ///   - separators: The text between consecutive objects: a space PDFium found in the gap, or nothing.
    ///   - newText: The run's new text, without trailing whitespace.
    static func plan(_ pieces: [String], _ separators: [String], _ newText: String) throws -> TextRunEdit {
        try ArgumentOutOfRangeException.throwIfZero(pieces.count, "pieces.Count")
        var starts = [Int](repeating: 0, count: pieces.count)
        var ends = [Int](repeating: 0, count: pieces.count)
        var builder: [UInt16] = []
        for i in 0..<pieces.count {
            starts[i] = builder.count
            builder.append(contentsOf: pieces[i].utf16)
            ends[i] = builder.count
            if i < separators.count {
                builder.append(contentsOf: separators[i].utf16)
            }
        }

        let old = builder

        // Trailing whitespace isn't part of the editable text; it stays as it is (C#'s TrimEnd).
        var trimmedLength = old.count
        while trimmedLength > 0 && DotNetChar.isWhiteSpace(old[trimmedLength - 1]) {
            trimmedLength -= 1
        }

        let target = newText.units + old[trimmedLength...]

        var prefix = 0
        let limit = min(old.count, target.count)
        while prefix < limit && old[prefix] == target[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < limit - prefix && old[old.count - (suffix + 1)] == target[target.count - (suffix + 1)] {
            suffix += 1
        }

        // Never split a surrogate pair between the kept and the changed text.
        if prefix > 0 && DotNetChar.isHighSurrogate(old[prefix - 1]) {
            prefix -= 1
        }

        if suffix > 0 && DotNetChar.isLowSurrogate(old[old.count - suffix]) {
            suffix -= 1
        }

        // The object containing a position, or the one before the gap containing it.
        func pieceAtOrBefore(_ position: Int) -> Int {
            var piece = 0
            while piece + 1 < starts.count && starts[piece + 1] <= position {
                piece += 1
            }

            return piece
        }

        // The object containing a position, or the one after the gap containing it.
        func pieceAtOrAfter(_ position: Int) -> Int {
            var piece = 0
            while piece + 1 < ends.count && ends[piece] <= position {
                piece += 1
            }

            return piece
        }

        let first: Int
        let last: Int
        let changedEnd = old.count - suffix
        if changedEnd > prefix {
            first = pieceAtOrBefore(prefix)
            last = pieceAtOrAfter(changedEnd - 1)
        } else {
            // Pure insertion: it joins the object it follows, or the next object after a gap.
            first = prefix == 0 ? 0 : pieceAtOrAfter(prefix - 1)
            last = first
        }

        let newEnd = ends[last] + (target.count - old.count)
        return TextRunEdit(first, last, String(units: target[starts[first]..<newEnd]))
    }
}
