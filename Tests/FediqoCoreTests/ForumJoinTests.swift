import Foundation
import Testing

@testable import FediqoCore

/// Adding a forum: what the reader's button actually calls, and what it does with each answer.
@Suite("Forum join")
struct ForumJoinTests {
    private static func forumHTTP(
        latest: FixtureHTTP.Outcome = .body(Fixtures.json("discourse-latest"))
    ) -> FixtureHTTP {
        FixtureHTTP([
            "/": .body(Fixtures.html("discourse")),
            "/latest.json": latest,
            "/site.json": .body(Fixtures.json("discourse-site")),
        ])
    }

    @Test("A forum is detected, read, and added with its topics in the store")
    func aForumJoins() async throws {
        let store = ItemStore()
        let http = Self.forumHTTP()
        try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
            .join(host: "install-f.example")

        let sources = await store.sources()
        #expect(sources.map(\.host) == ["install-f.example"])
        // The source carries what the host actually speaks, because that is what decides the
        // shape of the row — a forum is drawn as a thread, a microblog as a note.
        #expect(sources.first?.kind == .discourse)

        let notes = await store.all()
        #expect(notes.count == 3)
        #expect(notes.allSatisfy { $0.title?.isEmpty == false })
        #expect(notes.contains { $0.board == "Ideas" })
    }

    @Test("The host is asked what it speaks once, not once per protocol")
    func theHostIsAskedOnce() async throws {
        let store = ItemStore()
        let http = Self.forumHTTP()
        try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
            .join(host: "install-f.example")

        // The front page is read once for the detector and never again. A dispatcher that let
        // each protocol re-detect would double this against every server, for nothing.
        #expect(await http.paths.filter { $0 == "/" }.count == 1)
        #expect(await Set(http.paths) == ["/", "/latest.json", "/site.json"])
    }

    @Test("A forum that answers the detector and then refuses is not left behind as a source")
    func aRefusedForumIsNotAdded() async throws {
        let store = ItemStore()
        let http = Self.forumHTTP(latest: .text("<html>checking your browser</html>", status: 403))

        await #expect(throws: JoinError.refused(403)) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "install-f.example")
        }

        // Nothing added. A source in the list whose timeline can never load is worse than a
        // failed join: the reader has to work out for themselves why one of their servers is
        // permanently blank.
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("A refusal is its own message, never confused with a host that is not a forum")
    func aRefusalIsToldApart() async throws {
        for status in [401, 403, 429, 503] {
            let store = ItemStore()
            let http = Self.forumHTTP(latest: .text("", status: status))
            await #expect(throws: JoinError.refused(status)) {
                try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                    .join(host: "install-f.example")
            }
        }

        // 404 is a host that does not serve a front page, which is a different sentence to a
        // reader: check the address, rather than "that server turned us away".
        let store = ItemStore()
        let http = Self.forumHTTP(latest: .text("", status: 404))
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "install-f.example")
        }
    }

    @Test("A microblog still joins through the same door, and still gets its catalogue")
    func aMicroblogStillJoins() async throws {
        let store = ItemStore()
        let catalogues = EmojiCatalogueStore()
        try await SourceJoin(http: JoinTests.joinHTTP(), store: store, catalogues: catalogues)
            .join(host: "first.example")

        #expect(await store.sources().map(\.kind) == [.mastodon])
        #expect(await store.all().isEmpty == false)
    }

    @Test("A host that speaks neither is refused by name")
    func anUnsupportedHostIsRefusedByName() async throws {
        let store = ItemStore()
        let http = FixtureHTTP(["/": .body(Fixtures.html("pleroma"))])
        await #expect(throws: JoinError.unsupportedKind(.pleroma)) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "pleroma.example")
        }
        #expect(await store.sources().isEmpty)
    }
}
