import Foundation
import Testing
import SwiftUI
import FediqoCore
@testable import FediqoUI

/// A stack of photographs, and whether it looks like one (#95).
///
/// The thing worth asserting here is not a number of points. It is that **the fan comes out of
/// the card and never out of the room around it**: every caller reserves `AttachmentDeck.side`
/// and no caller reserves a point more, so a deck that drew wider than that drew where nobody had
/// left it room — which is what this turned out to be. On a phone the sheets and the counter were
/// both outside the measured box, and a post with three pictures said nothing about two of them.
@Suite("A stack of photographs")
@MainActor
struct AttachmentDeckTests {
    private let side = AttachmentDeck.side

    /// The rule the drawing rests on. Whatever the fan costs, the card pays it.
    @Test("The whole stack keeps to the width the card was given", arguments: [1, 2, 3, 4, 9])
    func theStackKeepsToItsCard(count: Int) {
        let face = AttachmentDeck.faceSide(under: count, on: side)
        #expect(face + AttachmentDeck.overhang(under: count, on: side) == side)
        #expect(face <= side)
    }

    /// One picture is one picture, with nothing taken off it and nothing laid over it.
    @Test("One attachment is drawn whole")
    func oneIsWhole() {
        #expect(AttachmentDeck.overhang(under: 1, on: side) == 0)
        #expect(AttachmentDeck.faceSide(under: 1, on: side) == side)
    }

    /// And an empty deck is not a negative one.
    @Test("No attachments fan out by nothing")
    func noneFanOutByNothing() {
        #expect(AttachmentDeck.overhang(under: 0, on: side) == 0)
    }

    /// More than one has to be visible as more than one, so each of the ones underneath steps out
    /// by a whole leaf and the second is further out than the first.
    @Test("Each one underneath steps out further than the one above it")
    func eachStepsOutFurther() {
        let one = AttachmentDeck.overhang(under: 2, on: side)
        let two = AttachmentDeck.overhang(under: 3, on: side)
        #expect(one > 0)
        #expect(two > one)
    }

    /// Past three the edges stop being distinguishable, so a post with nine pictures does not
    /// eat nine leaves out of the photograph.
    @Test("The fan stops rather than growing with the deck")
    func theFanIsBounded() {
        let four = AttachmentDeck.overhang(under: 4, on: side)
        #expect(AttachmentDeck.overhang(under: 9, on: side) == four)
        #expect(AttachmentDeck.overhang(under: 40, on: side) == four)
    }

    /// **The regression that started this.** The leaf was three points, fixed, when the card was
    /// 200 wide; #79 doubled the card and left it there, so the stack halved in visibility on the
    /// day the picture grew. A share of the card cannot go stale that way.
    @Test("The step follows the card rather than staying behind it")
    func theStepFollowsTheCard() {
        #expect(AttachmentDeck.leaf(on: 400) == AttachmentDeck.leaf(on: 200) * 2)
        // And it is enough of the card to see: three points in four hundred is not.
        #expect(AttachmentDeck.leaf(on: 400) > 6)
    }

    /// A narrow row draws a narrower card, and the fan narrows with it rather than eating a
    /// fixed number of points out of a picture that has fewer to give.
    @Test("A narrower card fans out by less")
    func anarrowerCardFansLess() {
        #expect(AttachmentDeck.overhang(under: 3, on: 200) < AttachmentDeck.overhang(under: 3, on: 400))
        #expect(AttachmentDeck.faceSide(under: 3, on: 200) > 0)
    }
}
