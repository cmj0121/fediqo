import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #197: a hashtag's page answers to the timeline in front, as a search does, and asks only the
/// sources that know what a tag is.
///
/// Read through `ShellSession.heldPosts(under:)`, the one call the page and the keys both read, so
/// what is asserted is what the reader is shown. Every source answers through a fixture.
@MainActor
@Suite("A hashtag's page answers to the timeline in front")
struct TagTimelineTests {
    private static let one = "one.example"
    private static let forum = "forum.example"
    private static let board = "board.example"
    private static let swift = PostTag("#swift")!

    private static let mastodonTag = "/api/v1/timelines/tag/swift"
    private static let forumTag = "/tag/swift.json"

    private static func note(_ id: String, _ body: String) -> Note {
        Note(
            id: "https://\(one)/users/ada/statuses/\(id)", source: Source(host: one, kind: .mastodon),
            author: "Ada", handle: "@ada@\(one)", body: body,
            postedAt: Date(timeIntervalSince1970: Double(id) ?? 0), categories: [.public]
        )
    }

    /// One topic, as the forum's front page and its tag's listing both send it: no words of its
    /// own carry the tag, which the forum keeps beside them.
    private static let listing = #"""
    {"users":[{"id":1,"username":"wren","name":"Wren","avatar_template":null}],
     "topic_list":{"topics":[{"id":41207,"title":"Retry defaults","slug":"retry-defaults",
       "created_at":"2026-04-02T09:12:41.508Z","posts_count":3,"reply_count":2,"like_count":1,
       "category_id":6,"tags":["swift"],"posters":[{"description":"Original Poster","user_id":1}]}]}}
    """#
    private static let site = #"{"categories":[{"id":6,"name":"Dev"}]}"#
    private static let topicKey = Note(
        id: "discourse:\(forum):41207", source: Source(host: forum, kind: .discourse), author: "",
        handle: "", body: "", postedAt: .distantPast, categories: []
    ).key

    /// A Mastodon read unsigned, a Discourse and a Discuz!, with two posts under #swift held — one
    /// that says "friends" and one that does not.
    private func shell(_ http: any HTTPClient) async -> ShellSession {
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon))
        await store.add(Source(host: Self.forum, kind: .discourse))
        await store.add(Source(host: Self.board, kind: .discuz, boards: [BoardSubscription(fid: 1, name: "Dev")]))
        await store.ingest([Self.note("1", "hello #swift friends"), Self.note("2", "#swift alone")])
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: Unreached()),
            posts: ForumPosts(http: http)
        )
        await session.reloadFromStore()
        return session
    }

    /// A written timeline of one keyword rule, put in front.
    private func friends(in session: ShellSession) throws -> TimelineQuery {
        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = "Friends"
        draft.rules = [try #require(Rule.keyword("friends", in: .every))]
        session.commit(draft)
        session.timelineID = .written(draft.id)
        return .written(draft.id)
    }

    private static func said(_ key: String, _ hosts: [String]) -> String {
        String(format: L10n.t(key), hosts.joined(separator: ", "))
    }

    // MARK: - Acceptance

    @Test("On a written timeline with a keyword rule, the page shows only what that rule lets through")
    func rulesHold() async throws {
        let session = await shell(FixtureHTTP([:]))
        session.timelineID = .all
        #expect(session.heldPosts(under: Self.swift).count == 2)
        _ = try friends(in: session)
        #expect(session.heldPosts(under: Self.swift).map(\.id) == [Self.note("1", "").key.rowID])
        session.timelineID = .trends
        #expect(session.heldPosts(under: Self.swift).isEmpty, "no post under the tag is a trend")
    }

    @Test("On Trends nothing is asked, and the page says why of each source")
    func trendsAsksNobody() async {
        let http = FixtureHTTP([:])
        let session = await shell(http)
        await session.reload.tag(Self.swift, timeline: .trends, in: session)
        #expect(await http.requested.isEmpty)
        #expect(!session.reload.running)
        #expect(session.reload.tagAsking.isEmpty)
        let reach = session.reload.tagAsk?.reach
        #expect(reach?.asked == [])
        #expect(reach?.partial.contains(Self.one) == true)
        #expect(reach?.sentence?.contains(Self.said("tag.reach.partial", reach?.partial ?? [])) == true)
    }

    @Test("A forum that tags its topics is asked, and what it sends shows once, as its front page's row")
    func forumTopicIsOneRow() async throws {
        let http = FixtureHTTP([
            Self.mastodonTag: .text("[]"), Self.forumTag: .text(Self.listing),
            "/latest.json": .text(Self.listing), "/site.json": .text(Self.site),
        ])
        let session = await shell(http)
        session.timelineID = .all
        // The front page first, as a reload would have landed it.
        let front = try await DiscourseClient(http: http, host: Self.forum)
            .latest(source: Source(host: Self.forum, kind: .discourse))
        await session.store.ingest(front, ifSourceHere: Self.forum)
        await session.reloadFromStore()

        await session.reload.tag(Self.swift, timeline: .all, in: session)
        await session.reloadFromStore()
        #expect(await http.paths.contains(Self.forumTag), "the forum asked under the tag")
        #expect(!(await http.requested.contains { $0.host == Self.board }), "the Discuz! is not")
        #expect(session.reload.tagAsk?.reach.asked == [Self.one, Self.forum])
        #expect(session.reload.tagAsk?.reach.tagless == [Self.board])
        let under = session.heldPosts(under: Self.swift).map(\.id)
        #expect(under.filter { $0 == Self.topicKey.rowID }.count == 1, "once")
        #expect(session.searchable.filter { $0.key == Self.topicKey }.count == 1, "one row in the store")
        #expect(await session.store.note(Self.topicKey)?.holding == .arrived, "the front page's own row")
        #expect(session.reload.tagFailed.isEmpty)
    }

    @Test("A topic sent only under the tag is held aside, and All does not grow by it")
    func forumTopicHeldAside() async {
        let http = FixtureHTTP([
            Self.mastodonTag: .text("[]"), Self.forumTag: .text(Self.listing), "/site.json": .text(Self.site),
        ])
        let session = await shell(http)
        await session.reload.tag(Self.swift, timeline: .all, in: session)
        await session.reloadFromStore()
        #expect(await session.store.note(Self.topicKey)?.holding == .aside)
        #expect(await session.store.note(Self.topicKey)?.board == "Dev", "named as the front page names it")
        #expect(!session.notes.contains { $0.key == Self.topicKey })
        #expect(session.heldPosts(under: Self.swift).map(\.id).contains(Self.topicKey.rowID))
    }

    @Test("A forum with tags turned off says so, is not a failure, and is not asked again")
    func tagsOff() async {
        let http = FixtureHTTP([
            Self.mastodonTag: .text("[]"), Self.forumTag: .text("", status: 404), "/tags.json": .text("", status: 404),
        ])
        let session = await shell(http)
        await session.reload.tag(Self.swift, timeline: .all, in: session)
        let reach = session.reload.tagAsk?.reach
        #expect(reach?.tagsOff == [Self.forum])
        #expect(reach?.asked == [Self.one])
        #expect(reach?.sentence?.contains(Self.said("tag.reach.tagsOff", [Self.forum])) == true)
        #expect(reach?.sentence?.contains(Self.said("tag.reach.tagless", [Self.board])) == true)
        #expect(session.reload.tagFailed.isEmpty)

        await session.reload.tag(Self.swift, timeline: .all, in: session)
        #expect(await http.paths.filter { $0 == Self.forumTag }.count == 1, "not asked a second time")
        #expect(session.reload.tagAsk?.reach.tagsOff == [Self.forum])
    }

    @Test("A tag the forum has never used is nothing under it, not tags off and not a failure")
    func unusedTag() async {
        let http = FixtureHTTP([
            Self.mastodonTag: .text("[]"), Self.forumTag: .text("", status: 404), "/tags.json": .text(#"{"tags":[]}"#),
        ])
        let session = await shell(http)
        await session.reload.tag(Self.swift, timeline: .all, in: session)
        #expect(session.reload.tagAsk?.reach.tagsOff == [])
        #expect(session.reload.tagAsk?.reach.asked == [Self.one, Self.forum])
        #expect(session.reload.tagFailed.isEmpty)
    }

    @Test("A forum that fails says so where the answer would be, and can be tried again")
    func forumFails() async {
        let http = FixtureHTTP([Self.mastodonTag: .text("[]"), Self.forumTag: .text("", status: 500)])
        let session = await shell(http)
        await session.reload.tag(Self.swift, timeline: .all, in: session)
        #expect(session.reload.tagFailed == [Self.forum])
        #expect(TagPane.said(asking: [], failed: session.reload.tagFailed, tag: Self.swift)
            == .failed(String(format: L10n.t("tag.failed"), Self.forum, Self.swift.text)))
        await session.reload.tag(Self.swift, timeline: .all, in: session)
        #expect(await http.paths.filter { $0 == Self.forumTag }.count == 2, "tried again")
    }

    // MARK: - Switching timeline with the page open

    @Test("Switching timeline asks the new timeline's sources, and only those, and the reach follows")
    func switchingReasks() async throws {
        let http = FixtureHTTP([Self.mastodonTag: .text("[]"), Self.forumTag: .text("[]", status: 500)])
        let session = await shell(http)
        session.timelineID = .all
        await session.reload.tag(Self.swift, timeline: .all, in: session)
        let first = await http.requested.count

        await session.reload.tagSwitched(to: .all, in: session)
        #expect(await http.requested.count == first, "the same timeline is not asked again")

        session.timelineID = .trends
        await session.reload.tagSwitched(to: .trends, in: session)
        #expect(await http.requested.count == first, "Trends' sources are not asked")
        #expect(session.reload.tagAsk?.reach.asked == [], "the line is Trends', not All's")
        #expect(session.reload.tagFailed.isEmpty, "All's failure is not Trends' to say")

        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = "Mine"
        draft.rules = [try #require(Rule.source(Self.one))]
        session.commit(draft)
        session.timelineID = .written(draft.id)
        await session.reload.tagSwitched(to: .written(draft.id), in: session)
        let asked = await http.paths.dropFirst(first)
        #expect(Array(asked) == [Self.mastodonTag], "only the new timeline's own source")
        #expect(session.reload.tagAsk?.reach.asked == [Self.one])
        #expect(session.reload.tagAsk?.tag == Self.swift)
    }

    @Test("A switch answered after another asks nothing of a timeline no longer in front")
    func lateSwitchAsksNothing() async throws {
        let http = FixtureHTTP([Self.mastodonTag: .text("[]")])
        let session = await shell(http)
        session.timelineID = .trends
        await session.reload.tag(Self.swift, timeline: .trends, in: session)
        let query = try friends(in: session)
        session.timelineID = .trends
        await session.reload.tagSwitched(to: query, in: session)
        #expect(await http.requested.isEmpty)
        #expect(session.reload.tagAsk?.timeline == .trends)
    }

    @Test("With the page closed, a switch asks nothing")
    func closedAsksNothing() async throws {
        let http = FixtureHTTP([Self.mastodonTag: .text("[]")])
        let session = await shell(http)
        await session.reload.tag(Self.swift, timeline: .trends, in: session)
        session.reload.endTag()
        session.timelineID = .all
        await session.reload.tagSwitched(to: .all, in: session)
        #expect(await http.requested.isEmpty)
    }

    @Test("A switch keeps a tag's page in front, alone; any other walk ends")
    func theWalkKeepsTheTag() {
        var walk = ShellWalk()
        _ = walk.walk(to: .thread("a"), from: "row-1")
        _ = walk.walk(to: .tag(Self.swift), from: "a")
        #expect(walk.timelineSwitched() == Self.swift)
        #expect(walk.depth == 1)
        #expect(walk.openedTag == Self.swift)
        #expect(walk.back()?.lamp == nil, "the row it was pressed on is on a list that is gone")

        _ = walk.walk(to: .tag(Self.swift), from: "row-1")
        _ = walk.walk(to: .thread("b"), from: "row-2")
        #expect(walk.timelineSwitched() == nil)
        #expect(walk.isEmpty)
    }

    // MARK: - Said, and drawn

    @Test("Every reason a source was not asked is said in every language")
    func strings() {
        for key in ["tag.reach.asked", "tag.reach.partial", "tag.reach.tagless", "tag.reach.tagsOff"] {
            for language in [DummyLanguage.english, .taiwanese] {
                let sentence = L10n.t(key, language: language)
                #expect(sentence != key, "\(key) is missing in \(language)")
                #expect(String(format: sentence, "forum.example").contains("forum.example"))
            }
        }
    }

    @Test("The reach draws on the page, wrapped, in light and in dark, at a phone's width")
    func reachIsDrawn() throws {
        let reach = ShellReload.TagReach(
            asked: [Self.one], partial: ["two.example"], tagless: [Self.board], tagsOff: [Self.forum]
        ).sentence
        func height(_ reach: String?, _ scheme: ColorScheme) throws -> CGFloat {
            let pane = TagPane(
                tag: Self.swift, items: [], reach: reach,
                catalogues: EmojiCatalogueStore(), posts: ForumPosts(http: FixtureHTTP([:])),
                selectedID: .constant(nil), marks: { _ in .constant(DummyMarks()) },
                decks: .constant(ShellDecks()), playback: ShellPlayback(),
                onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                onRetry: {}, jumpToTop: 0, onToast: { _ in }, onBack: {}
            )
            .frame(width: 320)
            .environment(\.colorScheme, scheme)
            return CGFloat(try #require(ImageRenderer(content: pane).cgImage).height)
        }
        for scheme in [ColorScheme.light, .dark] {
            #expect(try height(reach, scheme) > height(nil, scheme) + 20, "wrapped over lines rather than cut")
        }
    }
}

/// A signed-in door nobody holds a token for: never reached.
private struct Unreached: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw FixtureHTTPError.unmapped
    }
}
