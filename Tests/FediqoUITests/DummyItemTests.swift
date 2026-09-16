import Foundation
import FediqoCore
import Testing

@testable import FediqoUI

/// Which shape of row each protocol gets — the one place `ProtocolKind` turns into something the
/// timeline can draw.
@Suite("Row shape")
@MainActor
struct DummyItemTests {
    init() {
        L10n.language = .english
    }

    private static func note(_ kind: ProtocolKind) -> Note {
        Note(
            id: "\(kind.rawValue):host:1",
            source: Source(host: "example.test", kind: kind),
            author: "somebody",
            handle: "@somebody@example.test",
            body: "",
            title: "A named discussion",
            board: "A section",
            postedAt: .distantPast,
            origins: [.publicTimeline],
            counts: Counts(replies: 3)
        )
    }

    @Test("Every protocol is drawn as exactly one shape, and none of them as a board")
    func everyProtocolGetsAShape() {
        // **Every protocol written out, rather than "these two are forums and the rest are
        // microblogs".** The shorter spelling agreed with the code by construction: a protocol
        // added to `ProtocolKind` and left out of the set was *expected* to be a microblog, which
        // is the exact wrong answer the incident behind `shape(of:)` produced — a whole Discuz!
        // forum drawn as microblog posts with every title missing. The no-`default:` rule makes
        // the compiler stop at the switch; this makes the suite stop as well, because a new
        // protocol has no entry here, `expected[kind]` is nothing, and nothing matches no shape.
        // Saying it twice is the price of the second question being asked at all.
        let expected: [ProtocolKind: DummySourceKind] = [
            .mastodon: .microblog,
            .pleroma: .microblog,
            .akkoma: .microblog,
            .misskey: .microblog,
            .pixelfed: .microblog,
            .lemmy: .microblog,
            .friendica: .microblog,
            .gotosocial: .microblog,
            .unknown: .microblog,
            .discourse: .forum,
            .discuz: .forum,
            .peertube: .video,
        ]
        let unshaped = Set(ProtocolKind.allCases).subtracting(expected.keys)
        #expect(unshaped.isEmpty, "no shape stated for \(unshaped.map(\.rawValue).sorted())")

        for kind in ProtocolKind.allCases {
            let item = DummyItem(Self.note(kind), among: [])
            #expect(item.source.kind == expected[kind], "\(kind.rawValue)")
            // `.board` is a query inside a source, never a shape a protocol has. `shape(of:)`
            // returning it would draw a whole host as one section of itself, and no switch would
            // complain, because `.board` is a case the row already knows how to draw.
            #expect(item.source.kind != .board, "\(kind.rawValue)")
        }
    }

    @Test("A film is not drawn as somebody's words")
    func aPeerTubeNoteIsAVideo() {
        // Pinned while it is still unreachable — `.peertube` is refused at every join door, so
        // nothing here can arrive from a real server yet. It is pinned because the alternative
        // answers, `.note` and `.thread`, are both plausible and both silently wrong, and M2's
        // PeerTube unit should be changing a stated expectation rather than discovering one.
        let item = DummyItem(Self.note(.peertube), among: [])
        #expect(item.source.kind == .video)
        #expect(item.kind == .video)
    }

    @Test("A Discuz! thread carries its title and its board into the row")
    func aDiscuzThreadIsAThread() {
        // The whole point of the shape: a forum row draws a name and a section, and a microblog
        // row draws neither because a microblog has neither.
        let item = DummyItem(Self.note(.discuz), among: [])
        #expect(item.source.kind == .forum)
        #expect(item.kind == .thread)
        #expect(item.title == "A named discussion")
        #expect(item.board == "A section")
        #expect(item.counts.replies == 3)

        // The same note from a microblog is the same words drawn as a note.
        let post = DummyItem(Self.note(.mastodon), among: [])
        #expect(post.source.kind == .microblog)
        #expect(post.kind == .note)
    }
}
