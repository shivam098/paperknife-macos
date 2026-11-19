# Porting PaperKnife's engine to Swift

PaperKnife for Mac uses a port of the engine of
[PaperKnife for Windows](https://github.com/shivam098/paperknife-windows) (`src/PaperKnife.Core`):
the same types, algorithms, checks and messages, so every shortcoming fixed there stays fixed here.
The [conformance corpus](../conformance/README.md) checks that the port observes exactly what the
Windows engine observes; `conformance/SOURCE` names the Windows commit the corpus and the port
follow.

## Layout and names

- `Sources/PaperKnifeCore` mirrors `src/PaperKnife.Core`: the same folders (`Syntax`, `Content`,
  `Fonts`, `Editing`, `Pdfium`) and one Swift file per C# file, with the same name. `Support`
  holds the helpers below.
- Types keep their C# names (`PdfFile`, `CosDict`, `ContentPage`, `FontCompletion`,
  `DocumentSession`). Members use the C# name in lower camel case (`GetTextRuns` →
  `getTextRuns`, `TryOpen` → `tryOpen`) with the C# parameters in the same order. Port the
  comments too.
- C# `internal` stays internal (Swift's default); tests use `@testable import PaperKnifeCore`.
  C# `public` is `public`.
- PDFium is called directly through the `CPDFium` module, and zlib through `CZlib`.

## Semantics that must not change

Swift differs from C# in ways that compile fine and give different results. Ported code follows
these rules everywhere.

1. **Strings are UTF-16 in C#.** Wherever C# measures, indexes, slices or iterates a string, or
   looks at its chars, work on UTF-16 code units: `s.units` (`[UInt16]`), `s.length`,
   `s.substring(start, length)`, `String(units:)`. Never use Swift's `count`, `Character` or
   `String.Index` for C# string logic: they count grapheme clusters. A Swift string can't hold an
   unpaired surrogate, which a C# string can: `String(units:)` makes it U+FFFD. So where C# joins
   chars or strings that may be halves of a pair, join code units and make the string once (as
   `Encodings.glyphToUnicode` does). Where a C# string keeps one (a ToUnicode range that steps
   into the surrogates, a `uniD800` glyph name), the port has U+FFFD instead, and
   `normalizedFormKC` doesn't throw as .NET's `Normalize` does.
2. **C# compares strings by code unit (ordinal); Swift by canonical equivalence.** In Swift
   `"\u{E9}" == "e\u{301}"`; in C# they differ. Use `ordinalEquals`, `ordinalCompare`,
   `String.ordinalLess`, `ordinalHasPrefix`, `ordinalHasSuffix`, `ordinalIndexOf`,
   `ordinalLastIndexOf`, `ordinalContains`, `ordinalReplacing` and `split(onUnit:)` for C#
   string operations. Key dictionaries and sets of text by `OrdinalString`. PDF names and
   operators decoded from Latin-1 can't differ only by canonical equivalence, so `String` keys are
   fine for them.
3. **Characters.** `char.IsWhiteSpace`, `char.IsControl`, surrogate checks,
   `CharUnicodeInfo.GetUnicodeCategory` and `char.ConvertFromUtf32` are in `DotNetChar` and take
   UTF-16 code units. `Trim`, `TrimStart` and `TrimEnd` are `dotNetTrim…` (Swift's whitespace set
   differs). `Normalize(FormC)` and `Normalize(FormKC)` are `normalizedFormC` and
   `normalizedFormKC`.
4. **Ordered collections.** C#'s `Dictionary` and `HashSet` enumerate in insertion order (an entry
   added after a removal takes the freed place); Swift's `Dictionary` and `Set` in no particular
   order. Use `OrderedDictionary` and `OrderedSet` wherever the C# code enumerates a dictionary or
   set, or passes it on to code that does. LINQ `OrderBy`/`ThenBy` are stable sorts:
   `stableSorted(by:)`. LINQ `Distinct` keeps first occurrences: `distinctInOrder()`. A C#
   `List.Sort` or `Array.Sort` with equal keys is unstable in .NET; flag such code rather than
   guess.
5. **Integers.** C# `int` is 32-bit and wraps on overflow (this project has overflow checking
   off); Swift's `Int` is 64-bit and traps. Use `Int` where values stay small, and Swift's
   wrapping operators (`&+`, `&-`, `&*`) on `Int32`/`UInt32` wherever the C# code relies on
   wrapping. Swift also traps on out-of-range array indexes, where C# throws an exception that the
   code may catch: check bounds explicitly in those places.
6. **Floating point.** Keep `float` as `Float` and `double` as `Double` exactly where C# uses them;
   PDFium works in `float`, and `TextShowSimulator` sums line positions in `float` on purpose.
   C# casts to integers saturate and give 0 for NaN; Swift's trap: use `DotNetMath.toInt32` and
   `toInt64`. `Math.Round(x)` rounds ties to even and `Math.Round(x, digits[, mode])` scales by a
   power of 10: use `DotNetMath.round` and `roundAwayFromZero`.
7. **Formatting and parsing numbers.** `CosWriter.Number` is
   `DotNetMath.formatUpTo10Decimals(DotNetMath.round(value, 10))`, with "-0" written as "0". Parse
   only the syntax the C# code accepts: `DotNetParse.hexInt32` for `AllowHexSpecifier`,
   `DotNetParse.int32` for `int.TryParse`, `DotNetParse.signedInt32` for `AllowLeadingSign` alone,
   and `DotNetParse.double` for `double.TryParse` with `NumberStyles.Float` (the C# lexer checks
   the characters of a number first). `ToString("D10")` and `Convert.ToHexString` are
   `DotNetFormat.d` and `DotNetFormat.hex`; a `(uint)` cast of a double is `DotNetMath.toUInt32`.
8. **Bytes and text encodings.** Use `[UInt8]` (and `ArraySlice<UInt8>` where C# uses spans) for
   file data. `Encoding.Latin1` is `Latin1.string` and `Latin1.bytes`. Big-endian UTF-16 and UTF-8
   decoding must replace invalid sequences the way .NET does (U+FFFD).
9. **Exceptions.** Where C# throws and catches (for example `PdfException`, or the read failures
   `DocumentSession` turns into refusals), Swift throws and catches errors that keep the same
   meaning and messages.
10. **Messages.** Copy every message shown to users exactly, typographic quotes (“ ” ’) included:
    the corpus compares them.
11. **PDFium.** All calls go through `PdfiumLibrary` under one global lock, as C#'s
    `lock (PdfiumLibrary.Sync)` does, because PDFium isn't thread-safe.
12. **Fonts.** The fonts the Windows app compiles in or ships in `Fonts\` (AMS Computer Modern,
    Latin Modern, CM-Super) and the Adobe Glyph List are files in the app bundle's
    `Resources/Fonts` (`amsfonts`, `cm-super` and `lm` folders, and `glyphlist.txt`).
    `BundledFonts.fontDirectories` and `Encodings.glyphListURL` say where they are: by default the
    bundle, and tests point them at `third_party/`. The folders are searched in turn, each in
    ordinal order of the paths, which gives the fonts the precedence they have on Windows.
13. **Reading files.** PaperKnife's own reader (`PdfFile`, `ContentPage`, `PdfFontInfo`,
    `FontCompletion`) throws where the C# one throws, with the exceptions `DocumentSession` turns
    into refusals (`IsReadFailure`: `ArgumentException`, `IndexOutOfRangeException`,
    `InvalidOperationException`, `NullReferenceException`, `OverflowException` and the like).
    `DotNetThrows` makes each one as the C# expression throws it. Flate data is inflated as .NET's
    `ZLibStream` inflates it: data zlib refuses is damaged (`StreamFilters.isDamaged`: .NET's
    `InvalidDataException`, and the `ZLibException` it throws for data that asks for a preset
    dictionary), truncated data gives what it holds, and bytes after the end are ignored.
    `Encoding.BigEndianUnicode.GetString` is `Utf16BigEndian.string`.

## Tests

- `ConformanceTests` runs every case in `conformance/cases` as `conformance/README.md` describes.
- `CorpusSyntaxTests` checks, until the document session is ported, what PaperKnife's own reader
  observes in every case: each page's decoded content and fonts.
- Unit tests port the Windows tests the corpus doesn't cover (file syntax, Type 1 fonts, PDF
  tools), and `DotNetSupportTests` checks the helpers above against values computed with .NET.
