import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #90: opening a post shows the conversation around it, not the post alone.
@MainActor
@Suite("The conversation around a post")
struct ThreadAroundTests {
    private static let host = "one.example"

    init() {
        L10n.language = .english
    }

    /// One status as the wire sends it, answering `parent` where it answers anything.
    private static func status(_ id: String, _ text: String, answering parent: String? = nil) -> String {
        let reply = parent.map { #""in_reply_to_id":"\#($0)","# } ?? ""
        return """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)",\(reply)
         "created_at":"2024-01-01T00:00:00.000Z","content":"<p>\(text)</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func context(ancestors: [String], descendants: [String]) -> FixtureHTTP.Outcome {
        .text(#"{"ancestors":["# + ancestors.joined(separator: ",")
            + #"],"descendants":["# + descendants.joined(separator: ",") + "]}")
    }

    private static func note(_ id: String, statusID: String?, kind: ProtocolKind = .mastodon) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: Source(host: host, kind: kind),
            author: "Ada", handle: "@ada@\(host)", body: "the post",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.public], statusID: statusID
        )
    }

    /// A session holding one post on one Mastodon, and the thread route it will ask for.
    private func shell(
        _ routes: [String: FixtureHTTP.Outcome], kind: ProtocolKind = .mastodon, statusID: String? = "9"
    ) async -> (ShellSession, FixtureHTTP, DummyItem) {
        let http = FixtureHTTP(routes)
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: kind))
        let held = Self.note("9", statusID: statusID, kind: kind)
        await store.ingest([held])
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        return (session, http, DummyItem(held))
    }

    private static let threadPath = "/api/v1/statuses/9/context"

    @Test("Opening a post asks for its thread once, and the answers are what the pane draws")
    func opening() async throws {
        let (session, http, item) = await shell([
            Self.threadPath: Self.context(
                ancestors: [Self.status("7", "the start"), Self.status("8", "an answer", answering: "7")],
                descendants: [Self.status("10", "a reply", answering: "9")]
            ),
        ])

        await session.conversations.open(item, in: session)

        #expect(await http.paths == [Self.threadPath], "one request, and no timeline under it")
        let drawn = session.conversations.conversation(around: item)
        #expect(drawn.ancestors.map(\.body) == ["the start", "an answer"], "oldest first, above the post")
        #expect(drawn.post.id == item.id, "the row the reader pressed, not the source's copy of it")
        #expect(drawn.descendants.map(\.item.body) == ["a reply"])
        #expect(drawn.inOrder.count == 4, "the keys walk the whole conversation")

        // Asked once per post per run: a pane reopened draws what is already held.
        await session.conversations.open(item, in: session)
        #expect(await http.paths == [Self.threadPath])
    }

    @Test("An answer to an answer stands a generation deeper, and an unplaceable one stands at the first")
    func nesting() async throws {
        let (session, _, item) = await shell([
            Self.threadPath: Self.context(ancestors: [], descendants: [
                Self.status("10", "to the post", answering: "9"),
                Self.status("11", "to the answer", answering: "10"),
                Self.status("12", "to nothing this device can name"),
            ]),
        ])

        await session.conversations.open(item, in: session)

        let drawn = session.conversations.conversation(around: item)
        #expect(drawn.descendants.map(\.depth) == [1, 2, 1])
        #expect(drawn.depth(of: drawn.descendants[1].item.id) == 2, "no ancestors, so depth is its own")
    }

    @Test("Ancestors push the post and its answers down by their own count")
    func depthUnderAncestors() async throws {
        let (session, _, item) = await shell([
            Self.threadPath: Self.context(
                ancestors: [Self.status("7", "the start")],
                descendants: [Self.status("10", "a reply", answering: "9")]
            ),
        ])

        await session.conversations.open(item, in: session)

        let drawn = session.conversations.conversation(around: item)
        #expect(drawn.depth(of: item.id) == 1, "one generation above it")
        #expect(drawn.depth(of: drawn.descendants[0].item.id) == 2)
    }

    @Test("A post alone in its thread is empty, and is never left waiting")
    func alone() async throws {
        let (session, _, item) = await shell([
            Self.threadPath: Self.context(ancestors: [], descendants: []),
        ])

        await session.conversations.open(item, in: session)

        #expect(session.conversations.standing(of: item.id) == ShellConversationStanding.none)
        #expect(!session.conversations.standing(of: item.id).wantsPressing, "nothing to try again")
        #expect(session.conversations.conversation(around: item).inOrder.map(\.id) == [item.id])
    }

    @Test("A thread nothing answered can be tried again, and the second ask lands")
    func unreachableThenAgain() async throws {
        let (session, http, item) = await shell([Self.threadPath: .fail])

        await session.conversations.open(item, in: session)

        let standing = session.conversations.standing(of: item.id)
        #expect(standing == .absent(.unreachable))
        #expect(standing.wantsPressing, "the dark is the one nothing worth a second press")
        #expect(
            ShellConversations.Absence.unreachable.sentence(host: Self.host)
                == "The thread around this post did not arrive.",
            "it says so without naming a server that never answered"
        )

        // `open` is asked once per run; `again` is the reader saying to ask anyway.
        await session.conversations.open(item, in: session)
        #expect(await http.paths.count == 1, "opening again asks nothing")
        await session.conversations.again(item, in: session)
        #expect(await http.paths.count == 2)
    }

    @Test("A server that said no is not offered a second press, and is named")
    func refused() async throws {
        let (session, _, item) = await shell([Self.threadPath: .text("no", status: 403)])

        await session.conversations.open(item, in: session)

        let standing = session.conversations.standing(of: item.id)
        #expect(standing == .absent(.refused))
        #expect(!standing.wantsPressing, "a refusal does not change by being asked again")
        #expect(ShellConversations.Absence.refused.sentence(host: Self.host).contains(Self.host))
    }

    @Test("A post this device cannot name on its server has no thread to ask for")
    func unfindable() async throws {
        let (session, http, item) = await shell([:], statusID: nil)

        await session.conversations.open(item, in: session)

        #expect(session.conversations.standing(of: item.id) == .absent(.unfindable))
        #expect(await http.paths.isEmpty, "nothing was asked, because there was nothing to ask about")
        #expect(!session.conversations.standing(of: item.id).wantsPressing)
    }

    @Test("A forum thread is not this unit's, and its post is settled rather than left waiting")
    func forumIsSettled() async throws {
        let (session, http, item) = await shell([:], kind: .discuz)

        await session.conversations.open(item, in: session)

        #expect(session.conversations.standing(of: item.id) == ShellConversationStanding.none)
        #expect(await http.paths.isEmpty)
    }

    @Test("Clear lets go of that server's threads and nobody else's")
    func clearForgets() async throws {
        let (session, _, item) = await shell([
            Self.threadPath: Self.context(ancestors: [], descendants: [Self.status("10", "a reply", answering: "9")]),
        ])
        await session.conversations.open(item, in: session)
        #expect(session.conversations.standing(of: item.id) != .unasked)

        session.conversations.forget(host: "elsewhere.example")
        #expect(session.conversations.standing(of: item.id) != .unasked, "another server's Clear")

        session.conversations.forget(host: Self.host.uppercased())
        #expect(session.conversations.standing(of: item.id) == .unasked, "folded once, like every host")
    }

    @Test("An answer this device already holds is refreshed on the way past; one it never held is not admitted")
    func heldRowsOnly() async throws {
        let (session, _, item) = await shell([
            Self.threadPath: Self.context(ancestors: [], descendants: [
                Self.status("10", "an edited reply", answering: "9"),
                Self.status("11", "never held", answering: "9"),
            ]),
        ])
        await session.store.ingest([Self.note("10", statusID: "10")])
        await session.reloadFromStore()

        await session.conversations.open(item, in: session)

        #expect(session.notes.first { $0.id.hasSuffix("/10") }?.body == "an edited reply")
        #expect(!session.notes.contains { $0.id.hasSuffix("/11") }, "a reply never held stays out of All")
        #expect(
            session.conversations.conversation(around: item).descendants.map(\.item.body)
                == ["an edited reply", "never held"],
            "both are read in the thread; only one of them is a row"
        )
    }
}
