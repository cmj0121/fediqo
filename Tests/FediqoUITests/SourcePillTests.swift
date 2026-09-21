import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #98 — the source pill on a row has a little room inside it.
///
/// What a test can reach: the room itself, that it is room on every side and not one number
/// applied to a shape with round ends, that a pill with that much room in it still fits the band
/// the meta line stands in, and that the pill still names the one host the row came through. What
/// it cannot: that a narrow row takes the letters and not the room, which is SwiftUI's own layout
/// and is named in the report rather than claimed here.
///
/// **The suite is `@MainActor`** for the reason `TouchTests` states.
@Suite("The source pill")
@MainActor
struct SourcePillTests {
    init() {
        L10n.language = .english
    }

    private static func row(host: String, kind: ProtocolKind = .mastodon) -> DummyItem {
        DummyItem(Note(
            id: "\(kind.rawValue):\(host):1",
            source: Source(host: host, kind: kind),
            author: "somebody",
            handle: "@somebody@\(host)",
            body: "",
            title: "A named discussion",
            board: "A section",
            postedAt: .distantPast,
            categories: [.public],
            url: nil,
            counts: Counts(replies: 3)
        ))
    }

    // MARK: - Room on every side

    /// The pill carried `tight` sideways and two hairs upright, which is a capsule drawn round the
    /// letters rather than round the word. Both figures grow, and both are steps off the shell's
    /// own spacing scale rather than numbers picked here.
    @Test("The host has room on every side, and more of it than it had")
    func theHostHasRoomOnEverySide() {
        #expect(DummyItemRow.Box.pillSideways > 0)
        #expect(DummyItemRow.Box.pillUpright > 0)
        // What it was. A change that left either figure where it stood would satisfy "there is
        // room" — there was room — and none of the issue.
        #expect(DummyItemRow.Box.pillSideways > ShellSpace.tight)
        #expect(DummyItemRow.Box.pillUpright > ShellSpace.hair * 2)
        // Off the scale and not invented. Every gap in this shell is one of six steps, and a pill
        // that padded itself with a seventh would be the private metrics table `ShellSpace` exists
        // to have ended.
        let scale = [
            ShellSpace.hair, ShellSpace.tight, ShellSpace.snug,
            ShellSpace.step, ShellSpace.pad, ShellSpace.room,
        ]
        #expect(scale.contains(DummyItemRow.Box.pillSideways))
        #expect(scale.contains(DummyItemRow.Box.pillUpright))
    }

    /// Sideways and upright are two numbers, and the sideways one is the larger.
    ///
    /// The ends of a capsule are round: room applied evenly on all four sides puts the first and
    /// last letters of the host under the curve, where the shape has already taken it back. A
    /// single figure would read as a host against the wall however large it was made.
    @Test("The room is shaped for a capsule and not for a rectangle")
    func theRoomIsShapedForACapsule() {
        #expect(DummyItemRow.Box.pillSideways > DummyItemRow.Box.pillUpright)
    }

    /// **The upright figure is the one with a ceiling**, and this is the ceiling.
    ///
    /// The pill stands on the meta line, the meta line stands in the avatar's band, and a pill
    /// taller than the face beside it makes the headline taller — and with it every row in a list
    /// the reader is scrolling, which is the one thing this row is not allowed to do. Room added
    /// until the capsule outgrew the band would be this issue paid for by #52's own rule.
    @Test("A pill with that much room in it still fits the band the meta line stands in")
    func thePillStillFitsTheHeadlineBand() {
        #if os(macOS)
        // The Mac is the platform that resolves points itself, so it is the platform that can be
        // asked what the host's own letters measure.
        let letters = ShellType.platformPoints(ShellType.mark.style)
        let pill = letters + DummyItemRow.Box.pillUpright * 2
        #expect(pill <= DummyItemRow.Box.avatar, """
            the source pill stands \(pill)pt tall in a \(DummyItemRow.Box.avatar)pt band
            """)
        // And it shares that band with the audience mark, which #97 made larger. The taller of
        // the two is what the line actually measures.
        #expect(max(pill, DummyItemRow.Box.vis) <= DummyItemRow.Box.avatar)
        #endif
    }

    /// The room is a measurement and not a colour, so it is the same room in light and in dark by
    /// construction — which is the honest reading of that acceptance line. What the scheme does
    /// decide is the plate the room is measured against, and there is one in both.
    ///
    /// The plate is a milled recess and a quiet one on purpose — `ShellChrome.well` measures about
    /// 1.2:1 against the page in either scheme, which is a wash the eye reads as a container and
    /// not a boundary it has to find. That is the token's own choice and not this issue's; what is
    /// pinned here is that the pill has a plate at all, in both schemes, for the room to be inside.
    @Test("There is a plate for the room to be inside, in light and in dark")
    func thereIsAPlateInBothSchemes() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(ShellChrome.well(scheme) != ShellChrome.page(scheme), "\(scheme)")
        }
        #expect(ShellChrome.well(.light) != ShellChrome.well(.dark))
    }

    // MARK: - It still names the one source

    /// One host, and the host — not the board a forum row sits in, not the author, not the
    /// protocol drawn as a page. A post two servers carry is two rows (#10), each naming its own,
    /// so there is never a second name to put here.
    @Test("The pill names the one server the row came through, whatever the protocol")
    func thePillNamesTheOneSource() {
        for kind in ProtocolKind.allCases {
            let item = Self.row(host: "example.test", kind: kind)
            #expect(DummyItemRow.spokenSource(item) == "example.test", "\(kind.rawValue)")
            #expect(DummyItemRow.spokenSource(item) != item.board, "\(kind.rawValue)")
            #expect(DummyItemRow.spokenSource(item) != item.title, "\(kind.rawValue)")
            #expect(DummyItemRow.spokenSource(item) != kind.rawValue, "\(kind.rawValue)")
        }
    }

    /// Two rows through two servers name two servers. The same note read through a second host is
    /// a second row (#10), and a pill that named the author's own instance instead would make the
    /// two rows say the same thing.
    @Test("Two rows through two hosts name two hosts")
    func twoRowsNameTwoHosts() {
        let first = Self.row(host: "one.example")
        let second = Self.row(host: "two.example")
        #expect(DummyItemRow.spokenSource(first) != DummyItemRow.spokenSource(second))
        #expect(DummyItemRow.spokenSource(second) == "two.example")
    }
}
