import Foundation
import Testing
import SwiftUI
import FediqoCore
@testable import FediqoUI

/// What shape a picture is drawn at (#101, S10).
///
/// The decision is that a card takes the picture's own shape within a bound, and that **nothing
/// outside the bound is cut** — the card takes the nearest shape it is allowed and the picture is
/// fitted into it. So a reader looking at a row and a reader looking at the opened picture are
/// looking at the same photograph, which is the half of this that S5 would ask for anyway.
@Suite("What shape a picture is drawn at")
@MainActor
struct PictureShapeTests {
    private func picture(_ width: Int?, _ height: Int?) -> FediqoCore.Attachment {
        FediqoCore.Attachment(kind: .image, url: URL(string: "https://one.example/p.png"),
                   previewURL: URL(string: "https://one.example/p.png"), alt: "",
                   width: width, height: height)
    }

    // MARK: - the shape a server sent

    @Test("A landscape photograph is drawn landscape, and a portrait one portrait")
    func itTakesTheShapeItWasGiven() {
        let landscape: CGFloat = AttachmentDeck.shape(of: picture(1600, 900))
        let portrait: CGFloat = AttachmentDeck.shape(of: picture(1000, 1200))
        #expect(landscape == CGFloat(900) / CGFloat(1600))
        #expect(portrait == CGFloat(1.2))
    }

    /// The two shapes that would break a row: a slit nobody can see, and a card taller than the
    /// screen with the words above it pushed off the top.
    @Test("A shape past the bound is held at the bound")
    func theBoundHolds() {
        #expect(AttachmentDeck.shape(of: picture(4000, 500)) == AttachmentDeck.shapes.lowerBound)
        #expect(AttachmentDeck.shape(of: picture(1080, 1920)) == AttachmentDeck.shapes.upperBound)
    }

    /// **A row is a row.** The tallest a card gets is about a square and a quarter, because a
    /// timeline is a list somebody is going down and one post taking the whole of it is one post
    /// deciding how much of their reading it gets.
    @Test("The tallest a row can be is still plainly a row")
    func arowStaysARow() {
        #expect(AttachmentDeck.shapes.upperBound == 1.25)
        // A 9:16 screenshot, which is the shape that started this: cut to the bound rather than
        // drawn at 1.78 of the card's width.
        #expect(AttachmentDeck.shape(of: picture(1080, 1920)) == 1.25)
    }

    /// The other half of cutting one: the row says there is more, so it is not claiming that
    /// the middle of somebody's photograph is the whole of it (S5).
    @Test("A picture the card had to cut is marked, and one it did not is not")
    func cuttingIsSaid() {
        #expect(AttachmentDeck.cuts(picture(1080, 1920)))
        #expect(AttachmentDeck.cuts(picture(4000, 500)))
        #expect(!AttachmentDeck.cuts(picture(1000, 1250)))
        #expect(!AttachmentDeck.cuts(picture(1600, 900)))
        // Nothing to cut and nothing to say where nobody sent a shape: the card has its own.
        #expect(!AttachmentDeck.cuts(picture(nil, nil)))
    }

    /// The ordinary photographs are inside it, which is what makes the bound a bound rather than
    /// a second fixed shape.
    @Test("The shapes a camera makes are inside the bound")
    func theOrdinaryOnesAreTrue() {
        for (width, height) in [(3, 2), (16, 9), (4, 3), (4, 5), (1, 1)] {
            let wanted = CGFloat(height) / CGFloat(width)
            #expect(AttachmentDeck.shape(of: picture(width * 400, height * 400)) == wanted,
                    "\(width):\(height) should be drawn true")
        }
    }

    // MARK: - the shape nobody sent

    /// A server that did not say has not said square, and it has not said anything else either.
    /// The card has its own shape then, which is what this app did before it could know better.
    @Test("A shape nobody sent leaves the card its own")
    func silenceLeavesTheCardItsOwn() {
        #expect(AttachmentDeck.shape(of: picture(nil, nil)) == AttachmentDeck.ratio)
        let nothing: FediqoCore.Attachment? = nil
        #expect(AttachmentDeck.shape(of: nothing) == AttachmentDeck.ratio)
    }

    /// Half a shape is not a shape, and a zero is a server that said something useless rather
    /// than one that said a picture is nothing high.
    @Test("Half a shape, or a zero, is a shape nobody sent")
    func halfAShapeIsNone() {
        #expect(picture(1600, nil).aspect == nil)
        #expect(picture(nil, 900).aspect == nil)
        #expect(picture(1600, 0).aspect == nil)
        #expect(picture(0, 900).aspect == nil)
        #expect(AttachmentDeck.shape(of: picture(1600, 0)) == AttachmentDeck.ratio)
    }

    /// Height over width, the same terms the card's own shape is written in, so the two can be
    /// compared without anybody remembering which way round they are.
    @Test("The aspect is height over width, as the card's own shape is")
    func aspectIsHeightOverWidth() {
        #expect(picture(1000, 680).aspect == 0.68)
        #expect(AttachmentDeck.ratio == 0.68)
    }

    // MARK: - what is never done

    /// The rule S10 exists for: a card takes the shape it can, and where it cannot it says so
    /// rather than passing off the middle of somebody's photograph as the whole of it.
    @Test("A picture inside the bound is not cut at all")
    func insideTheBoundNothingIsCut() {
        // Card shape and picture shape are one number, so there is nothing to crop away.
        let portrait = picture(1000, 1250)
        #expect(AttachmentDeck.shape(of: portrait) == portrait.aspect)
        #expect(!AttachmentDeck.cuts(portrait))
    }
}
