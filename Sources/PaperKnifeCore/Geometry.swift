/// A rectangle in PDF page space: points (1/72 inch), origin at the bottom-left, y pointing up.
public struct PdfRect: Equatable {
    public var left: Float
    public var bottom: Float
    public var right: Float
    public var top: Float

    public init(_ left: Float, _ bottom: Float, _ right: Float, _ top: Float) {
        self.left = left
        self.bottom = bottom
        self.right = right
        self.top = top
    }

    public var width: Float { right - left }

    public var height: Float { top - bottom }

    public var area: Double { Double(DotNetMath.maximum(0, width)) * Double(DotNetMath.maximum(0, height)) }

    public func contains(_ x: Double, _ y: Double) -> Bool {
        x >= Double(left) && x <= Double(right) && y >= Double(bottom) && y <= Double(top)
    }

    public func intersects(_ other: PdfRect) -> Bool {
        left < other.right && other.left < right && bottom < other.top && other.bottom < top
    }

    public func union(_ other: PdfRect) -> PdfRect {
        PdfRect(
            DotNetMath.minimum(left, other.left),
            DotNetMath.minimum(bottom, other.bottom),
            DotNetMath.maximum(right, other.right),
            DotNetMath.maximum(top, other.top))
    }

    public func inflate(_ amount: Float) -> PdfRect { PdfRect(left - amount, bottom - amount, right + amount, top + amount) }

    /// A C# record's equality, which compares floats with `float.Equals`: NaN equals NaN.
    public static func == (a: PdfRect, b: PdfRect) -> Bool {
        DotNetMath.equals(a.left, b.left) && DotNetMath.equals(a.bottom, b.bottom)
            && DotNetMath.equals(a.right, b.right) && DotNetMath.equals(a.top, b.top)
    }
}

/// A rectangle in rendered-bitmap pixels: origin at the top-left, y pointing down.
public struct PixelRect: Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var right: Int { x + width }

    public var bottom: Int { y + height }

    public func contains(_ x: Int, _ y: Int) -> Bool { x >= self.x && x < right && y >= self.y && y < bottom }

    public func inflate(_ amount: Int) -> PixelRect { PixelRect(x - amount, y - amount, width + (2 * amount), height + (2 * amount)) }
}

/// Displayed page size in points, after the page's rotation is applied.
public struct PageSize: Equatable {
    public var width: Float
    public var height: Float

    public init(_ width: Float, _ height: Float) {
        self.width = width
        self.height = height
    }

    /// A C# record's equality, which compares floats with `float.Equals`: NaN equals NaN.
    public static func == (a: PageSize, b: PageSize) -> Bool {
        DotNetMath.equals(a.width, b.width) && DotNetMath.equals(a.height, b.height)
    }
}
