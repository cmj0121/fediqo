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
        let portrait: CGFloat = AttachmentDeck.shape(of: picture(1000, 1500))
        #expect(landscape == CGFloat(900) / CGFloat(1600))
        #expect(portrait == CGFloat(1.5))
    }

    /// The two shapes that would break a row: a slit nobody can see, and a card taller than the
    /// screen with the words above it pushed off the top.
    @Test("A shape past the bound is held at the bound")
    func theBoundHolds() {
        #expect(AttachmentDeck.shape(of: picture(4000, 500)) == AttachmentDeck.shapes.lowerBound)
        #expect(AttachmentDeck.shape(of: picture(1080, 1920)) == AttachmentDeck.shapes.upperBound)
    }

    /// The ordinary photographs are inside it, which is what makes the bound a bound rather than
    /// a second fixed shape.
    @Test("The shapes a camera makes are inside the bound")
    func theOrdinaryOnesAreTrue() {
        for (width, height) in [(3, 2), (2, 3), (16, 9), (4, 3), (3, 4), (1, 1)] {
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

    /// The rule S10 exists for. A card that could not take the shape does not get to choose
    /// which third of somebody's photograph was the important one.
    @Test("A picture whose shape is known is never cut")
    func aknownShapeIsNeverCut() {
        // `cropping` is false wherever the shape is known — inside the bound it changes nothing,
        // and outside it, it is the difference between letter-boxing and cutting.
        #expect(picture(1080, 1920).aspect != nil)
        #expect(picture(nil, nil).aspect == nil)
    }
}
