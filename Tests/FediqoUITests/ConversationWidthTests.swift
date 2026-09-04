import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// The width a conversation needs for two columns (#121).
///
/// It is tested rather than looked at for the reason `RowWidthTests` gives about the timeline's:
/// the widths a screenshot can be taken at land on one side or the other, and the band that
/// would show the difference is a window nothing in this repository can photograph.
@Suite("The width a conversation needs")
@MainActor
struct ConversationWidthTests {
    private let ships = TextScale.larger.factor

    /// The threshold is made of the column it is measuring for, so a page reserving a bigger
    /// picture asks for more room — which is the whole of what this change is.
    @Test("A wider column needs a wider page")
    func awiderColumn() {
        #expect(Size.wideRows(at: 1.0, card: Size.openedCard)
                > Size.wideRows(at: 1.0, card: Size.card))
        #expect(Size.wideRows(at: 1.0, card: Size.openedCard)
                - Size.wideRows(at: 1.0, card: Size.card) == Size.openedCard - Size.card)
    }

    /// The timeline's threshold is what it always was. A default that had quietly become the
    /// bigger column would have moved every list in the app.
    @Test("The timeline's threshold has not moved")
    func thetimelineIsUnchanged() {
        for scale in [1.0, ships] {
            #expect(Size.wideRows(at: scale) == Size.wideRows(at: scale, card: Size.card))
        }
    }

    /// It moves with the reader's text size for the same reason the timeline's does: the column
    /// is a picture and a picture is one size at every text size, and the rest is words.
    @Test("It still moves with the reader's text size")
    func movesWithTheScale() {
        #expect(Size.wideRows(at: 1.0, card: Size.openedCard)
                < Size.wideRows(at: ships, card: Size.openedCard))
    }

    /// The reply furthest in has the least room, so it is the one the page has to fit — the
    /// indent is taken off before the arrangement is decided rather than after.
    @Test("The deepest reply is what the page is measured against")
    func thedeepestReply() {
        #expect(PostPage.deepestIndent > 0)
        #expect(PostPage.deepestIndent == 4 * Space.withinGroup)
    }

    /// **The trade, written down.** Keeping the bigger picture costs exactly the difference
    /// between the two columns, so a conversation reaches two columns on a wider window than the
    /// timeline does. That is the price of #120's decision, and it is a number rather than a
    /// surprise.
    @Test("A conversation reaches two columns later than the timeline, by the size of the picture")
    func laterByThePicture() {
        let costs = Size.wideRows(at: ships, card: Size.openedCard) - Size.wideRows(at: ships)
        #expect(costs == Size.openedCard - Size.card)
    }
}
