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

    @Test("Both forums are drawn as forums, and every microblog as a microblog")
    func everyProtocolGetsAShape() {
        // **Enumerated over `allCases`, because the failure here is silent.** `shape(of:)` ends
        // in a `default`, so a forum added to `ProtocolKind` and forgotten here does not fail to
        // build: the source joins, the threads arrive, and every one of them is drawn as
        // somebody's words with its title nowhere. Listing the two forums and letting the
        // enumeration assert the rest is what makes the next one a test failure instead.
        let forums: Set<ProtocolKind> = [.discourse, .discuz]
        for kind in ProtocolKind.allCases {
            let item = DummyItem(Self.note(kind))
            let expected: DummySourceKind = forums.contains(kind) ? .forum : .microblog
            #expect(item.source.kind == expected, "\(kind.rawValue)")
        }
    }

    @Test("A Discuz! thread carries its title and its board into the row")
    func aDiscuzThreadIsAThread() {
        // The whole point of the shape: a forum row draws a name and a section, and a microblog
        // row draws neither because a microblog has neither.
        let item = DummyItem(Self.note(.discuz))
        #expect(item.source.kind == .forum)
        #expect(item.kind == .thread)
        #expect(item.title == "A named discussion")
        #expect(item.board == "A section")
        #expect(item.counts.replies == 3)

        // The same note from a microblog is the same words drawn as a note.
        let post = DummyItem(Self.note(.mastodon))
        #expect(post.source.kind == .microblog)
        #expect(post.kind == .note)
    }
}
