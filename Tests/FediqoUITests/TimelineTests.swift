import Foundation
import FediqoCore
import Testing
@testable import FediqoUI

@Suite("Live stream")
@MainActor
struct TimelineStreamTests {
    init() {
        L10n.language = .english
    }

    @Test("All IDs match the store; Trends is origin; overlapping uri is one All row and a trend")
    func allAndTrendsFromStore() async {
        // Three public statuses out of order, and two trending ones — of which the middle status
        // is **both**, and the trending copy of it is deliberately different (another account,
        // other words) so that "one row, and the first payload wins" is a thing this can see.
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [
              {"id": "100", "uri": "https://first.example/users/ada/statuses/old",
               "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Oldest public</p>",
               "visibility": "public",
               "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}},
              {"id": "200", "uri": "https://first.example/users/ada/statuses/shared",
               "created_at": "2024-06-01T00:00:00.000Z", "content": "<p>Shared with trends</p>",
               "visibility": "public",
               "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}},
              {"id": "300", "uri": "https://first.example/users/bob/statuses/new",
               "created_at": "2024-12-01T00:00:00.000Z", "content": "<p>Newest public</p>",
               "visibility": "unlisted",
               "account": {"username": "bob", "acct": "bob@second.example", "display_name": "Bob"}}
            ]
            """#),
            "/api/v1/trends/statuses": .text(#"""
            [
              {"id": "200", "uri": "https://first.example/users/ada/statuses/shared",
               "created_at": "2024-06-01T00:00:00.000Z",
               "content": "<p>Shared with trends, later payload</p>", "visibility": "public",
               "account": {"username": "other", "acct": "other", "display_name": "Other"}},
              {"id": "400", "uri": "https://first.example/users/ada/statuses/trend-only",
               "created_at": "2024-09-01T00:00:00.000Z", "content": "<p>Trend only</p>",
               "visibility": "public",
               "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}
            ]
            """#),
        ]))
        session.hostname = "first.example"
        await session.add(from: .field)
        await session.confirm()
        #expect(session.timelineID == "all")

        let stored = await session.store.all()
        let all = DummyTimeline(id: "all").items(from: session.notes, among: [])
        let trends = DummyTimeline(id: "trends").items(from: session.notes, among: [])
        #expect(all.map(\.id) == stored.map(\.id))
        #expect(trends.map(\.id) == stored.filter { $0.origins.contains(.trending) }.map(\.id))
        #expect(trends.map(\.id) == [
            "https://first.example/users/ada/statuses/trend-only",
            "https://first.example/users/ada/statuses/shared",
        ])

        let shared = "https://first.example/users/ada/statuses/shared"
        #expect(all.filter { $0.id == shared }.count == 1)
        #expect(trends.contains { $0.id == shared })
        #expect(Set(all.map(\.id)).count == all.count)

        let publicOrder = [
            "https://first.example/users/ada/statuses/old",
            "https://first.example/users/ada/statuses/shared",
            "https://first.example/users/bob/statuses/new",
        ]
        #expect(all.map(\.id) != publicOrder)
        #expect(all.map(\.postedAt) == all.map(\.postedAt).sorted(by: >))
        #expect(trends.map(\.postedAt) == trends.map(\.postedAt).sorted(by: >))
        #expect(all.map(\.id).first == "https://first.example/users/bob/statuses/new")
        #expect(all.contains { $0.body == "Newest public" })
        // The public payload's words, not the trending one's: one uri is one row, and the first
        // answer in is the one kept.
        #expect(all.contains { $0.body == "Shared with trends" })
    }

    @Test("Source marks are unsigned hosts from the session")
    func sourceMarksAreUnsignedHosts() async {
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [{"id": "100", "uri": "https://first.example/users/ada/statuses/old",
              "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Oldest public</p>",
              "visibility": "public",
              "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}]
            """#),
            "/api/v1/trends/statuses": .text("[]"),
        ]))
        session.hostname = "first.example"
        await session.add(from: .field)
        await session.confirm()
        let marks = session.sources.map {
            DummySource.unsigned($0.host, kind: DummyItem.shape(of: $0.kind))
        }
        #expect(marks.map(\.host) == ["first.example"])
        #expect(marks.allSatisfy { $0.account == nil && $0.kind == .microblog && !$0.isSignedIn })
    }

    @Test("Empty Trends is a different key than empty All")
    func emptyTrendsCopy() async {
        // A server whose public timeline answers and whose trending read does not: the two
        // panes have to have two different things to say about the two different emptinesses.
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [{"id": "100", "uri": "https://first.example/users/ada/statuses/old",
              "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Oldest public</p>",
              "visibility": "public",
              "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}]
            """#),
            "/api/v1/trends/statuses": .fail,
        ]))
        session.hostname = "first.example"
        await session.add(from: .field)
        await session.confirm()
        #expect(!DummyTimeline(id: "all").items(from: session.notes, among: []).isEmpty)
        #expect(DummyTimeline(id: "trends").items(from: session.notes, among: []).isEmpty)
        #expect(DummyTimeline(id: "all").emptyKey == "timeline.empty")
        #expect(DummyTimeline(id: "trends").emptyKey == "timeline.empty.trends")
        // emptyKey is a stem: the pane asks for its .title and its .detail.
        for part in ["title", "detail"] {
            let trends = "timeline.empty.trends.\(part)"
            let all = "timeline.empty.\(part)"
            #expect(L10n.t(trends, language: .english) != L10n.t(all, language: .english))
            #expect(L10n.t(trends, language: .english) != trends)
            #expect(L10n.t(trends, language: .taiwanese) != trends)
        }
    }

    @Test("j/k walks live list IDs, not DummyItem.stored")
    func liveIDsNotStored() async {
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [
              {"id": "100", "uri": "https://first.example/users/ada/statuses/old",
               "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Oldest public</p>",
               "visibility": "public",
               "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}},
              {"id": "300", "uri": "https://first.example/users/bob/statuses/new",
               "created_at": "2024-12-01T00:00:00.000Z", "content": "<p>Newest public</p>",
               "visibility": "public",
               "account": {"username": "bob", "acct": "bob", "display_name": "Bob"}}
            ]
            """#),
            "/api/v1/trends/statuses": .text("[]"),
        ]))
        session.hostname = "first.example"
        await session.add(from: .field)
        await session.confirm()
        let ids = DummyTimeline(id: session.timelineID ?? "all").items(from: session.notes, among: []).map(\.id)
        #expect(!ids.isEmpty)
        #expect(DummyItem.stored.isEmpty)
        #expect(ids != DummyItem.stored.map(\.id))
        #expect(DummyCommand.stepped(ids, from: nil, by: 1) == ids.first)
        #expect(DummyCommand.stepped(ids, from: ids.first, by: 1) == ids.dropFirst().first)
        #expect(DummyCommand.stepped(ids, from: ids.last, by: 1) == ids.last)
    }

    @Test("A Note maps to a DummyItem with a literal body and 1:1 audience")
    func noteMapsToDummyItem() {
        let source = Source(host: "first.example", kind: .mastodon)
        let posted = Date(timeIntervalSince1970: 1_700_000_000)
        let somebody = Note(
            id: "https://first.example/users/ada/statuses/1",
            source: source,
            author: "Ada",
            handle: "@ada@first.example",
            body: "item.note.public.body",
            postedAt: posted,
            origins: [.publicTimeline],
            reply: Reply(handle: nil),
            boostedBy: "Bob",
            audience: .followers,
            avatarURL: URL(string: "https://first.example/a.png"),
            counts: Counts(replies: 4, reblogs: 5, favourites: 6)
        )
        let item = DummyItem(somebody, among: [])
        #expect(item.body == "item.note.public.body")
        #expect(item.body != L10n.t("item.note.public.body", language: .english))
        #expect(item.answering == .somebody)
        #expect(item.boostedBy == "Bob")
        #expect(item.audience == .followers)
        #expect(item.hasAvatar)
        #expect(!item.hasThumb)
        #expect(item.kind == .note)
        #expect(item.source == DummySource.unsigned("first.example", kind: .microblog))
        #expect(item.counts.replies == 4)
        #expect(item.counts.reblogs == 5)
        #expect(item.counts.favourites == 6)
        #expect(item.handle == "@ada@first.example")
        #expect(item.dummyConversation().inOrder.map(\.id) == [item.id])
        #expect(item.dummyConversation().descendants.isEmpty)

        let named = DummyItem(
            Note(
                id: "n2",
                source: source,
                author: "Ada",
                handle: "@ada@first.example",
                body: "hi",
                postedAt: posted,
                origins: [.trending],
                reply: Reply(handle: "@bob@second.example"),
                audience: .everyone,
                avatarURL: nil,
                attachments: [Attachment(kind: .image, previewURL: URL(string: "https://first.example/p.jpg"))]
            )
        , among: [])
        #expect(named.answering == .handle("@bob@second.example"))
        #expect(named.audience == .everyone)
        #expect(!named.hasAvatar)
        #expect(named.hasThumb)
        #expect(named.attachments.map(\.displayURL) == [URL(string: "https://first.example/p.jpg")])

        // `hasThumb` used to mean "the first attachment had a preview_url" and now means "the
        // post brought something with an address". The widening is deliberate: an audio clip a
        // server sent no cover art for used to leave the slot empty and now fills it, which is
        // what the deck wants. Pinned here so the change cannot drift back unnoticed.
        let unillustrated = DummyItem(
            Note(
                id: "n5",
                source: source,
                author: "Ada",
                handle: "@ada@first.example",
                body: "listen",
                postedAt: posted,
                origins: [.publicTimeline],
                attachments: [
                    Attachment(kind: .audio, url: URL(string: "https://first.example/clip.mp3")),
                ]
            )
        , among: [])
        #expect(unillustrated.hasThumb)
        #expect(unillustrated.attachments[0].previewURL == nil)

        let root = DummyItem(
            Note(
                id: "n3",
                source: source,
                author: "Ada",
                handle: "@ada@first.example",
                body: "root",
                postedAt: posted,
                origins: [.publicTimeline],
                audience: .unlisted
            )
        , among: [])
        #expect(root.answering == .nothing)
        #expect(root.audience == .unlisted)
        #expect(!root.hasAvatar)
        #expect(!root.hasThumb)

        let mentioned = DummyItem(
            Note(
                id: "n4",
                source: source,
                author: "Ada",
                handle: "@ada@first.example",
                body: "d",
                postedAt: posted,
                origins: [.publicTimeline],
                audience: .mentioned
            )
        , among: [])
        #expect(mentioned.audience == .mentioned)
    }
}
