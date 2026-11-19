/// An opaque page rendering in 32-bit BGRA (alpha is always 255, so it is also premultiplied).
public final class RenderedBitmap {
    init(_ width: Int, _ height: Int, _ stride: Int, _ pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.stride = stride
        self.pixels = pixels
    }

    public let width: Int

    public let height: Int

    public let stride: Int

    public let pixels: [UInt8]
}

/// A piece of text as PaperKnife edits it: one or more consecutive top-level text objects that sit
/// next to each other on one baseline and look the same, usually a line or a table cell. Most
/// PDFs draw such text with one object, but some draw every character or word separately.
/// A class with a C# record's equality, so a run also has an identity, as in C#.
public final class PdfTextRun: Equatable, CustomStringConvertible {
    public init(
        _ pageIndex: Int,
        _ objectIndex: Int,
        _ objectCount: Int,
        _ text: String,
        _ bounds: PdfRect,
        _ fontName: String,
        _ isFontEmbedded: Bool,
        _ isFontSubset: Bool,
        _ fontSize: Float,
        _ isInvisible: Bool
    ) {
        self.pageIndex = pageIndex
        self.objectIndex = objectIndex
        self.objectCount = objectCount
        self.text = text
        self.bounds = bounds
        self.fontName = fontName
        self.isFontEmbedded = isFontEmbedded
        self.isFontSubset = isFontSubset
        self.fontSize = fontSize
        self.isInvisible = isInvisible
    }

    public let pageIndex: Int

    /// Index of the run's first page object; the run spans `objectCount` consecutive objects.
    public let objectIndex: Int

    public let objectCount: Int

    /// The text, without trailing whitespace.
    public let text: String

    public let bounds: PdfRect

    public let fontName: String

    public let isFontEmbedded: Bool

    public let isFontSubset: Bool

    public let fontSize: Float

    public let isInvisible: Bool

    public var description: String {
        "PdfTextRun { PageIndex = \(pageIndex), ObjectIndex = \(objectIndex), ObjectCount = \(objectCount), Text = \(text), "
            + "Bounds = \(bounds), FontName = \(fontName), IsFontEmbedded = \(isFontEmbedded), IsFontSubset = \(isFontSubset), "
            + "FontSize = \(fontSize), IsInvisible = \(isInvisible) }"
    }

    /// A C# record's equality: strings compared ordinally, floats with `float.Equals`.
    public static func == (a: PdfTextRun, b: PdfTextRun) -> Bool {
        a.pageIndex == b.pageIndex && a.objectIndex == b.objectIndex && a.objectCount == b.objectCount
            && a.text.ordinalEquals(b.text) && a.bounds == b.bounds && a.fontName.ordinalEquals(b.fontName)
            && a.isFontEmbedded == b.isFontEmbedded && a.isFontSubset == b.isFontSubset
            && DotNetMath.equals(a.fontSize, b.fontSize) && a.isInvisible == b.isInvisible
    }
}

/// How many top-level objects of each kind a page contains.
public struct PageObjectCounts: Equatable, CustomStringConvertible {
    public var text: Int
    public var path: Int
    public var image: Int
    public var shading: Int
    public var form: Int
    public var other: Int

    public init(_ text: Int, _ path: Int, _ image: Int, _ shading: Int, _ form: Int, _ other: Int) {
        self.text = text
        self.path = path
        self.image = image
        self.shading = shading
        self.form = form
        self.other = other
    }

    public var description: String {
        "\(text) text, \(path) path, \(image) image, \(shading) shading, \(form) form, \(other) other"
    }
}
