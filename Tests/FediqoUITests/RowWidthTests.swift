import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// The one width this app measures rather than fits into, and the only threshold S9 allows.
///
/// It is tested rather than looked at because looking at it cannot reach it. The widths a
/// screenshot can be taken at are 440 and 1024 and a Mac window, and every one of them lands
/// on the same side of this number at every text scale the app offers — so a build where the
/// reader's scale never reached the comparison would photograph identically to one where it
/// did. The band that would show the difference is an iPad in Split View, and nothing in this
/// repository can photograph one.
@Suite("The width a row needs for two columns")
@MainActor
struct RowWidthTests {
    /// The reader this app ships to. `TextScale.larger`, and on iOS it multiplies whatever
    /// Dynamic Type the phone was already set to rather than replacing it.
    private let ships = TextScale.larger.factor

    @Test("At the scale it was measured for, it is the number it always was")
    func unchangedForRegular() {
        #expect(Size.wideRows(at: TextScale.regular.factor) == 560)
    }

    /// The whole of unit 3 in one assertion. A threshold that does not move with the text is
    /// a threshold that is right for exactly one reader, which is what S9 says is wrong with
    /// one — and this app's own default is not that reader.
    @Test("It moves with the reader's text size")
    func movesWithTheScale() {
        let small = Size.wideRows(at: TextScale.small.factor)
        let regular = Size.wideRows(at: TextScale.regular.factor)
        let larger = Size.wideRows(at: ships)

        #expect(small < regular)
        #expect(regular < larger)
        // Not a token amount, either: the reader this app ships to needs a third as much
        // width again as the one the old constant was written for.
        #expect(larger > regular * 1.3)
    }

    /// The deck's share is a picture, and a picture is the size it is at every text size. Only
    /// the words are multiplied, so the difference between two scales is the words' share
    /// alone — which is what pins the shape of the sum without repeating its terms here.
    @Test("Only the words follow the scale; the picture beside them does not")
    func thePictureDoesNotGrow() {
        let words = Size.wideRows(at: 2.0) - Size.wideRows(at: 1.0)
        let fixed = Size.wideRows(at: 1.0) - words

        #expect(words > 0)
        #expect(fixed == AttachmentDeck.side + Space.gap)
    }

    /// What the change is actually for. 440 was under the old number and is under this one, so
    /// no phone moves; 1024 is over both, so no iPad moves. The band between them is the whole
    /// of the behaviour change, and it is the case #80 names — what a screen should do at 700
    /// points that is different from both 440 and 1024.
    @Test("A phone and a 13-inch iPad keep the answers they had; 700 points does not")
    func onlyTheBandBetweenThemMoves() {
        let phone: CGFloat = 440
        let pad: CGFloat = 1024
        let between: CGFloat = 700

        #expect(phone < Size.wideRows(at: ships))
        #expect(phone < 560)

        #expect(pad >= Size.wideRows(at: ships))
        #expect(pad >= 560)

        #expect(between >= 560)
        #expect(between < Size.wideRows(at: ships))
    }
}
