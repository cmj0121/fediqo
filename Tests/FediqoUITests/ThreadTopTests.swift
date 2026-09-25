import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// `g` in a conversation goes to the top of the conversation as drawn: the first ancestor, or the
/// opened post where there is none — the same first row `k` climbs to, so `j` from there walks
/// on down.
///
/// The keys are the root's own rules — `FediqoRootView.jumpedToTop` and `FediqoRootView.moved` —
/// over the rows the root hands them, `DummyConversation.inOrder`. How the pane scrolls is for a
/// running app.
///
/// `@MainActor` on the suite, for the reason `LinkTests` gives at length.
@MainActor
@Suite("g in a conversation goes to its first row")
struct ThreadTopTests {
    private static let host = "one.example"

    private static func item(_ id: String) -> DummyItem {
        DummyItem(Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@\(host)", body: "post \(id)",
            postedAt: Date(timeIntervalSince1970: Double(id) ?? 0), categories: [.public]
        ))
    }

    /// What the root holds and hands its key rules: the rows in front, the step the walk is
    /// standing on, the lamp and the jump.
    private final class Root {
        let rows: [String]
        let standing: ShellStep?
        var place = ShellPlace.timeline
        var lamp: String?
        var jump = 0

        init(_ conversation: DummyConversation, lamp: String?) {
            rows = conversation.inOrder.map(\.id)
            standing = .thread(conversation.post.id)
            self.lamp = lamp
        }

        init(rows: [String], standing: ShellStep?, lamp: String?) {
            self.rows = rows
            self.standing = standing
            self.lamp = lamp
        }

        func g() -> Bool {
            FediqoRootView.jumpedToTop(
                in: rows.isEmpty ? nil : rows, standing: standing, place: place,
                selected: &lamp, jump: &jump
            )
        }

        func j() -> Bool {
            guard let next = FediqoRootView.moved(
                in: rows, from: lamp, by: 1, open: [.thread, .selection]
            ) else { return false }
            lamp = next
            return true
        }
    }

    /// Two ancestors above the opened post, and one answer under it.
    private static var withAncestors: DummyConversation {
        DummyConversation(
            ancestors: [item("1"), item("2")],
            post: item("3"),
            descendants: [DummyThreadEntry(item: item("4"), depth: 1)]
        )
    }

    @Test("With ancestors above, g lights the first ancestor and jumps")
    func gLightsTheFirstAncestor() {
        let conversation = Self.withAncestors
        let root = Root(conversation, lamp: Self.item("4").id)
        #expect(root.g())
        #expect(root.lamp == conversation.ancestors.first?.id)
        #expect(root.jump == 1)
    }

    @Test("With no ancestors, g lights the opened post")
    func gLightsTheOpenedPostWhereItIsFirst() {
        let conversation = DummyConversation(
            ancestors: [], post: Self.item("3"),
            descendants: [DummyThreadEntry(item: Self.item("4"), depth: 1)]
        )
        let root = Root(conversation, lamp: Self.item("4").id)
        #expect(root.g())
        #expect(root.lamp == conversation.post.id)
        #expect(root.jump == 1)
    }

    @Test("On the opened post with ancestors above, g still moves to the first ancestor")
    func gMovesOffTheOpenedPost() {
        let conversation = Self.withAncestors
        let root = Root(conversation, lamp: conversation.post.id)
        #expect(root.g())
        #expect(root.lamp == conversation.ancestors.first?.id)
        #expect(root.lamp != conversation.post.id)
    }

    @Test("g lands where k climbs to, and j from there goes to the next row")
    func jAfterGGoesDown() {
        let conversation = Self.withAncestors
        let climbed = Root(conversation, lamp: conversation.post.id)
        while let up = FediqoRootView.moved(
            in: climbed.rows, from: climbed.lamp, by: -1, open: [.thread, .selection]
        ), up != climbed.lamp {
            climbed.lamp = up
        }

        let root = Root(conversation, lamp: conversation.post.id)
        #expect(root.g())
        #expect(root.lamp == climbed.lamp)
        #expect(root.j())
        #expect(root.lamp == conversation.inOrder[1].id)
    }

    @Test("The stream still goes to its first row; a page read out of a post does not move")
    func otherListsKeepTheirTop() {
        let rows = ["a", "b", "c"]
        let stream = Root(rows: rows, standing: nil, lamp: "c")
        #expect(stream.g())
        #expect(stream.lamp == "a")
        #expect(stream.jump == 1)

        let link = Root(rows: [], standing: .link(URL(string: "https://example.test/a")!), lamp: "c")
        #expect(!link.g())
        #expect(link.lamp == "c")
        #expect(link.jump == 0)

        let elsewhere = Root(rows: rows, standing: nil, lamp: "c")
        elsewhere.place = .preferences
        #expect(!elsewhere.g())
        #expect(elsewhere.jump == 0)
    }
}
