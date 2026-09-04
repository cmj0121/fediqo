import Foundation
import Testing
import SwiftUI
import FediqoCore
@testable import FediqoUI

/// How a picture goes into a row (#101, S10).
///
/// **Every row that carries one is the same height.** A timeline is a list somebody is going down,
/// and a list whose rows are all different heights is one the eye has to re-find its place in on
/// every post. So the card is one shape whatever shape the picture is, the picture is scaled to
/// fill it and cut where it does not fit — never stretched — and where enough was lost to matter
/// the row says so rather than passing off the middle of somebody's photograph as the whole of it.
@Suite("How a picture goes into a row")
@MainActor
struct PictureShapeTests {
    private func picture(_ width: Int?, _ height: Int?) -> FediqoCore.Attachment {
        FediqoCore.Attachment(kind: .image, url: URL(string: "https://one.example/p.png"),
                              previewURL: URL(string: "https://one.example/p.png"), alt: "",
                              width: width, height: height)
    }

    // MARK: - one height

    /// The whole of what was asked for: a row with a picture is a row with a picture, whatever
    /// the picture is. Asserted on the number every card is drawn from, because there is only one
    /// of it — a card that read the picture's shape would be a second number by another name.
    @Test("Every card is the same shape, whatever it holds")
    func onecardShape() {
        #expect(AttachmentDeck.ratio == 0.68)
        #expect(AttachmentDeck.height == AttachmentDeck.side * AttachmentDeck.ratio)
    }

    /// **A row with a picture is nearly a row without one.** The card is as tall as the words are
    /// allowed to be, so the picture beside them does not decide the row's height on its own —
    /// measured in the timeline at 275 points against 210, where a card twice this gave 410
    /// against 215. Asserted as the relation rather than as the number, because the number is
    /// only right while the two agree.
    @Test("A card is as tall as the words are allowed to be")
    func acardIsAsTallAsTheWords() {
        #expect(AttachmentDeck.tall == PostRow.words)
        // The arithmetic cannot be written where the number is — `Size.card` is out among the
        // tokens because a `View`'s statics are isolated to the main actor and the threshold
        // that needs it is not — so this is what holds the number to the arithmetic.
        #expect(Size.card == (AttachmentDeck.tall / AttachmentDeck.ratio).rounded())
        #expect(AttachmentDeck.side == Size.card)
    }

    /// The page that is one post draws a bigger picture than the column a list reserves — and
    /// still a bounded one, which is the whole of the choice.
    ///
    /// `Size.card` is a *share of a row in a list*, and drawing the reader's picture at the
    /// scanning size on a page whose only job is that one post was half of #120. The other half
    /// is what happens if the bound comes off: a picture that simply takes a wide window's width
    /// is 600 points down, and it pushes the buttons and the conversation off the bottom — the
    /// fault this number exists to fix, arriving again in better clothes.
    @Test("The page that is one post draws a bigger picture, and still a bounded one")
    func theOpenedPostIsNotAList() {
        #expect(Size.openedCard > Size.card)
        // Every picture in this repository is taken on an 800-point window, and the post's own
        // words, its buttons and the first reply have to be on it as well.
        #expect(Size.openedCard * AttachmentDeck.ratio < 800 / 2)
    }

    // MARK: - what is lost, and when it is worth saying

    /// How much of a picture survives the cut, as the share of its longer dimension still on the
    /// screen. One is a picture the card's own shape; the further from the card, the less of it.
    @Test("A picture the card's own shape loses nothing")
    func thecardsOwnShapeLosesNothing() {
        #expect(AttachmentDeck.shown(of: picture(1000, 680)) == 1)
        #expect(!AttachmentDeck.cuts(picture(1000, 680)))
    }

    /// The shapes a camera makes, in the order of how much they cost. A 3:2 photograph loses a
    /// hair; a phone screenshot loses most of itself.
    @Test("The further from the card, the less of the picture is left")
    func thefurtherTheLess() {
        let threeByTwo = AttachmentDeck.shown(of: picture(3000, 2000))
        let square = AttachmentDeck.shown(of: picture(1000, 1000))
        let screenshot = AttachmentDeck.shown(of: picture(1080, 1920))

        #expect(threeByTwo > square)
        #expect(square > screenshot)
        #expect(screenshot < 0.5)
    }

    /// A mark on every picture would be noise standing where a fact should be, so it is drawn
    /// where something was actually lost.
    @Test("A picture is marked when enough of it is gone, and not before")
    func markedWhenEnoughIsGone() {
        #expect(!AttachmentDeck.cuts(picture(3000, 2000)))
        #expect(!AttachmentDeck.cuts(picture(1600, 900)))
        #expect(AttachmentDeck.cuts(picture(1000, 1000)))
        #expect(AttachmentDeck.cuts(picture(1080, 1920)))
        #expect(AttachmentDeck.cuts(picture(4000, 500)))
        #expect(AttachmentDeck.mostOfIt == 0.8)
    }

    // MARK: - the shape nobody sent

    /// A server that did not say has not said anything, so there is nothing to claim was lost.
    /// The picture fills the card as it always did, and the row says nothing about it.
    @Test("A shape nobody sent is not a picture anybody can say was cut")
    func silenceIsNotALoss() {
        #expect(AttachmentDeck.shown(of: picture(nil, nil)) == 1)
        #expect(!AttachmentDeck.cuts(picture(nil, nil)))
        let nothing: FediqoCore.Attachment? = nil
        #expect(!AttachmentDeck.cuts(nothing))
    }

    /// Half a shape is not a shape, and a zero is a server that said something useless rather
    /// than one that said a picture is nothing high.
    @Test("Half a shape, or a zero, is a shape nobody sent")
    func halfAShapeIsNone() {
        #expect(picture(1600, nil).aspect == nil)
        #expect(picture(nil, 900).aspect == nil)
        #expect(picture(1600, 0).aspect == nil)
        #expect(picture(0, 900).aspect == nil)
        #expect(!AttachmentDeck.cuts(picture(1600, 0)))
    }

    /// Height over width, the same terms the card is written in, so the two can be compared
    /// without anybody remembering which way round they are.
    @Test("The aspect is height over width, as the card is")
    func aspectIsHeightOverWidth() {
        #expect(picture(1000, 680).aspect == 0.68)
        #expect(AttachmentDeck.ratio == 0.68)
    }
}
