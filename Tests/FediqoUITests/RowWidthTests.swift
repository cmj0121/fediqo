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

    /// The sum rather than a total. This used to assert 560 — the number the threshold had been
    /// for every reader — and #79 doubled the deck, which was always going to move it. What is
    /// worth pinning is what it is made of: a literal here would only ever be re-typed to
    /// whatever the code now says, which is a test agreeing with itself.
    @Test("It is the deck, the gap, and what is left for the words")
    func isTheSumOfItsShares() {
        #expect(Size.wideRows(at: 1.0) == AttachmentDeck.side + Space.gap + 348)
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
        // Not a token amount either. Stated as points rather than as a ratio: the ratio shrank
        // when #79 doubled the deck, because the deck's share does not scale — which is the
        // design working, and an assertion that failed for it was asserting the wrong thing.
        #expect(larger - regular > 200)
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

    /// Where the two arrangements part, and how much room is left on the widest iPad the stores
    /// sell.
    ///
    /// **This used to be the assertion that would fail first**, and it did its job: it said that
    /// at 400 across the deck left a 13-inch iPad clearing the threshold by less than the rail
    /// beside the list is wide, so twenty points more anywhere moved every iPad to the stacked
    /// arrangement. Then the deck went to 200 — not for this, but so that a row with a picture
    /// is nearly a row without one — and the margin went with it.
    ///
    /// So the guard turns round. It now says the iPad has room to spare, and a change that takes
    /// the spare back is a change that puts every iPad on the edge again.
    @Test("A phone stacks, an iPad does not, and there is room to spare")
    func whereTheArrangementsPart() {
        let needed = Size.wideRows(at: ships)

        #expect(440 < needed)
        #expect(700 < needed)
        #expect(1024 >= needed)
        // Two hundred points of room on the widest iPad there is, where there were fewer than
        // a hundred while the deck was twice this size.
        #expect(1024 - needed > 200)
    }
}
