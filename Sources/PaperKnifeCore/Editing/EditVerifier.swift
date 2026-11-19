/// Pixel comparison used to prove that an edit didn't change anything else on the page.
enum EditVerifier {
    /// Per-channel difference treated as anti-aliasing noise rather than a real change.
    static let channelTolerance = 24

    private static let targetPixelsPerPoint = 2.0
    private static let maxCheckPixels = 8_000_000.0

    /// Rendering size for verification: 144 dpi, scaled down for very large pages.
    static func checkSize(_ widthPoints: Float, _ heightPoints: Float) -> (width: Int, height: Int) {
        var scale = targetPixelsPerPoint
        let area = Double(widthPoints) * Double(heightPoints)
        if area * scale * scale > maxCheckPixels {
            scale = (maxCheckPixels / area).squareRoot()
        }

        return (
            max(1, DotNetMath.toInt32(DotNetMath.round(Double(widthPoints) * scale))),
            max(1, DotNetMath.toInt32(DotNetMath.round(Double(heightPoints) * scale))))
    }

    static func countChangedPixels(_ before: RenderedBitmap, _ after: RenderedBitmap) -> Int { countChanged(before, after, coverage: false) }

    /// Counts pixels whose coverage differs: the alpha channel of renderings on a transparent
    /// background, which shows content of any color.
    static func countChangedCoverage(_ before: RenderedBitmap, _ after: RenderedBitmap) -> Int { countChanged(before, after, coverage: true) }

    private static func countChanged(_ before: RenderedBitmap, _ after: RenderedBitmap, coverage: Bool) -> Int {
        if before.width != after.width || before.height != after.height {
            return before.width * before.height
        }

        let a = before.pixels
        let b = after.pixels
        var changed = 0
        for y in 0..<before.height {
            let row = y * before.stride
            for x in 0..<before.width {
                let i = row + (x * 4)
                let differs: Bool
                if coverage {
                    differs = abs(Int(a[i + 3]) - Int(b[i + 3])) > channelTolerance
                } else {
                    differs = abs(Int(a[i]) - Int(b[i])) > channelTolerance
                        || abs(Int(a[i + 1]) - Int(b[i + 1])) > channelTolerance
                        || abs(Int(a[i + 2]) - Int(b[i + 2])) > channelTolerance
                }

                if differs {
                    changed += 1
                }
            }
        }

        return changed
    }
}
