/// What an applied run edit did to the page's objects.
final class RunChange {
    /// - Parameters:
    ///   - removed: How many text objects were removed.
    ///   - shiftX: How far the rest of the run moved, in page space.
    ///   - end: Where the new text ends along the run's baseline; `trimmedEnd` leaves out trailing spaces.
    ///   - hiddenBefore: Objects to hide in the original page to compare everything else.
    ///   - hiddenAfter: The same objects in the edited page.
    init(
        _ layout: TextRunLayout,
        _ edit: TextRunEdit,
        _ removed: Int,
        _ shiftX: Double,
        _ shiftY: Double,
        _ end: Double,
        _ trimmedEnd: Double,
        _ hiddenBefore: [Int],
        _ hiddenAfter: [Int]
    ) {
        self.layout = layout
        self.edit = edit
        self.removed = removed
        self.shiftX = shiftX
        self.shiftY = shiftY
        self.end = end
        self.trimmedEnd = trimmedEnd
        self.hiddenBefore = hiddenBefore
        self.hiddenAfter = hiddenAfter
    }

    let layout: TextRunLayout

    let edit: TextRunEdit

    let removed: Int

    let shiftX: Double

    let shiftY: Double

    let end: Double

    let trimmedEnd: Double

    let hiddenBefore: [Int]

    let hiddenAfter: [Int]

    var movedRest: Bool { shiftX != 0 || shiftY != 0 }
}
