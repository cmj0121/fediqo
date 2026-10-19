import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #124: pressing a hashtag shows what this device holds under it, and asks the sources of the
/// timeline in front for more — which lands in the store first.
@MainActor
@Suite("Pressing a hashtag", .watched)
struct TagPressTests {
    private static let one = "one.example"
    private static let forum = "forum.example"
    private static let swift = PostTag("#Swift")!

    init() {
        L10n.language = .english
    }

    private static func status(_ id: String, _ text: String) -> String {
        """
        {"id":"\(id)","uri":"https://\(one)/users/ada/statuses/\(id)",
         "created_at":"2024-03-0\(id)T00:00:00.000Z","content":"<p>\(text)</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static let tagAddress = "https://\(one)/api/v1/timelines/tag/Swift?limit=40"
    /// What `one.example` knows under #swift: a post this device never held.
    private static let underTag = FixtureHTTP.Outcome.text("[" + status("7", "learning #swift today") + "]")

    private static func note(_ id: String, _ body: String, categories: Set<FediqoCore.Category> = [.public]) -> Note {
        Note(
            id: "https://\(one)/users/ada/statuses/\(id)", source: Source(host: one, kind: .mastodon),
            author: "Ada", handle: "@ada@\(one)", body: body,
            postedAt: Date(timeIntervalSince1970: Double(id) ?? 0), categories: categories
        )
    }

    private static var fromTheWire: NoteKey { note("7", "").key }

    /// A Mastodon read unsigned and a forum, with a post under #swift held and one that only
    /// says the word.
    private func shell(_ http: any HTTPClient) async -> ShellSession {
        let store = ItemStore()
        await store.add(Source(host: Self.one, kind: .mastodon))
        await store.add(Source(host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 1, name: "Dev")]))
        await store.ingest([
            Self.note("1", "hello #SWIFT friends"),
            Self.note("2", "swift is a bird"),
        ])
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: NoSender()),
            posts: ForumPosts(http: http)
        )
        session.deadlinesUnturned()
        await session.reloadFromStore()
        return session
    }

    // MARK: - What this device holds under it

    @Test("A tag's page is the posts held that carry it, whatever case it was typed in, and nothing that only says the word")
    func heldUnderTheTag() async {
        let session = await shell(FixtureHTTP([:]))
        #expect(session.heldPosts(under: Self.swift, latest: nil).map(\.id) == [Self.note("1", "").key.rowID])
        #expect(session.heldPosts(under: PostTag("#nothing")!, latest: nil).isEmpty)
    }

    @Test("A forum reply kept for its thread is not on a tag's page; a microblog answer read in a thread is")
    func keptForumReplyIsNotUnderTheTag() async {
        let session = await shell(FixtureHTTP([:]))
        let reply = Note(
            id: "discuz:\(Self.forum):40125:post:9101", source: Source(host: Self.forum, kind: .discuz),
            author: "tinbox", handle: "tinbox", body: "a reply about #swift",
            postedAt: Date(timeIntervalSince1970: 50), categories: []
        )
        #expect(DiscuzPost(held: reply) != nil, "the premise: a reply kept for its thread")
        await session.store.ingest([reply], ifSourceHere: Self.forum)
        await session.store.ingest([Self.note("8", "an answer, #swift", categories: [])], ifSourceHere: Self.one)
        await session.reloadFromStore()
        #expect(await session.store.note(reply.key) != nil, "held on this device")
        let ids = session.heldPosts(under: Self.swift, latest: nil).map(\.id)
        #expect(!ids.contains(reply.key.rowID), "a row that opens nowhere is not drawn as one")
        #expect(ids.contains(Self.note("8", "").key.rowID))
    }

    @Test("A press asks the Mastodon of the timeline in front; what it sends is held as items that stand in All, and the page renews")
    func asksAndRenews() async throws {
        let http = FixtureHTTP([Self.tagAddress: Self.underTag])
        let session = await shell(http)
        let following = Task { await session.followStore() }
        defer { following.cancel() }

        await session.reload.tag(Self.swift, timeline: .all, in: session)
        #expect(await http.requested.map(\.absoluteString) == [Self.tagAddress], "the forum is not asked")
        #expect(session.reload.tagAsk?.reach.asked == [Self.one])
        // No `by:` here or below: the page is renewed by the store's follower, which never ends.
        await met("the tag's page is renewed with no press, to two posts") { session.heldPosts(under: Self.swift, latest: nil).count == 2 }
        #expect(session.heldPosts(under: Self.swift, latest: nil).first?.id == Self.fromTheWire.rowID)
        #expect(await session.store.note(Self.fromTheWire)?.categories.isEmpty == true, "the store's answer, through no category")
        await met("All grows by what the tag brought") { session.notes.contains { $0.key == Self.fromTheWire } }
        #expect(session.held(Self.fromTheWire.rowID) != nil, "and it opens its conversation")
        #expect(session.reload.tagFailed.isEmpty)
        #expect(!session.reload.running, "said on the tag's page, not in the toast")
    }

    @Test("A tag written in another script is asked for by its own letters")
    func anyScript() async {
        let taiwan = PostTag("#台灣")!
        let http = FixtureHTTP(["/api/v1/timelines/tag/台灣": .text("[]")])
        let session = await shell(http)
        await session.reload.tag(taiwan, timeline: .all, in: session)
        #expect(await http.requested.first?.path == "/api/v1/timelines/tag/台灣")
        #expect(session.reload.tagFailed.isEmpty)
    }

    @Test("While on its way the page's toast says so and the page shows what was held; a failure is the toast's, and `r` asks again")
    func onItsWayFailingAndRetry() async throws {
        let gated = GatedHTTP([Self.tagAddress: .text("oops", status: 500)], holding: "/api/v1/timelines/tag/Swift")
        let guardTask = watching(gated.gate, "the posts under the hashtag, held on the wire")
        defer { guardTask.cancel() }
        let session = await shell(gated)

        let asking = Task { await session.reload.tag(Self.swift, timeline: .all, in: session) }
        await met("the source is asked for the hashtag", by: asking) { await gated.asks == 1 }
        #expect(session.reload.tagAsking == [Self.one])
        #expect(session.reload.tagPageAsk(of: Self.swift, on: .timeline, language: .english)
            == PageAsking(asking: "Asking one.example for #Swift…", stoppable: true))
        #expect(session.heldPosts(under: Self.swift, latest: nil).count == 1, "what was held, not waiting")

        await gated.gate.open()
        await asking.value
        #expect(session.reload.tagAsking.isEmpty)
        #expect(session.reload.tagFailed == [Self.one])
        let failed = session.reload.tagPageAsk(of: Self.swift, on: .timeline)
        #expect(failed == PageAsking(failed: [Self.one]))
        #expect(TimelineToast.asked(failed, note: nil, language: .english)?.text == "Could not reload one.example.")

        await session.reload.tagAgain(Self.swift, timeline: .all, in: session)
        #expect(await gated.asks == 2, "tried again")
    }

    @Test("A tag with nothing under it reads as empty, not as waiting")
    func emptyIsEmpty() async {
        let http = FixtureHTTP(["/api/v1/timelines/tag/nothing": .text("[]")])
        let session = await shell(http)
        let nothing = PostTag("#nothing")!
        await session.reload.tag(nothing, timeline: .all, in: session)
        #expect(session.heldPosts(under: nothing, latest: nil).isEmpty)
        #expect(session.reload.tagAsking.isEmpty)
        #expect(session.reload.tagPageAsk(of: nothing, on: .timeline) == PageAsking(), "nothing for the toast to say")
        #expect(TagPane.none(nothing) == "Nothing under #nothing has reached this device.")
    }

    @Test("Leaving ends the ask: nothing it had not brought lands")
    func leavingEndsTheAsk() async {
        let gated = GatedHTTP([Self.tagAddress: Self.underTag], holding: "/api/v1/timelines/tag/Swift")
        let guardTask = watching(gated.gate, "the posts under the hashtag, held on the wire")
        defer { guardTask.cancel() }
        let session = await shell(gated)
        let asking = Task { await session.reload.tag(Self.swift, timeline: .all, in: session) }
        await met("the source is asked for the hashtag", by: asking) { await gated.asks == 1 }
        session.reload.endTag()
        await asking.value
        #expect(session.reload.tagAsk == nil)
        await gated.gate.open()
        // No `by:`: the read that was ended is the reload's own task, which no check can name.
        await met("the ask ended is answered past the gate") { await gated.requested().contains(Self.tagAddress) }
        // Counted: what the ended read does with that answer is in that unnamed task too.
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await session.store.note(Self.fromTheWire) == nil)
    }

    // MARK: - Asked again, and stopped (decision 11)

    @Test("Stop on a hashtag's page calls its ask off: the toast says the wait, then that the reload stopped — never a failure — the page and whom it asked stay, what comes late lands nowhere, a second press then asks again and says nothing of the stop")
    func stopCallsTheAskOff() async throws {
        let gated = GatedHTTP([Self.tagAddress: Self.underTag], holding: "/api/v1/timelines/tag/Swift")
        let guardTask = watching(gated.gate, "the posts under the hashtag, held on the wire")
        defer { guardTask.cancel() }
        let session = await shell(gated)
        #expect(!session.reload.stopTag(Self.swift, on: .timeline), "nothing on the wire: nothing stopped")

        let asking = Task { await session.reload.tag(Self.swift, timeline: .all, in: session) }
        await met("the source is asked for the hashtag", by: asking) { await gated.asks == 1 }
        let ask = session.reload.tagPageAsk(of: Self.swift, on: .timeline)
        #expect(ask.stoppable && ReloadMark.shown(canReload: true, stoppable: ask.stoppable) == .stop, "the mark is Stop mid-ask")
        // A press while it runs asks nothing.
        await session.reload.tagAgain(Self.swift, timeline: .all, in: session)
        #expect(await gated.asks == 1)

        #expect(session.reload.stopTag(Self.swift, on: .timeline))
        await asking.value
        #expect(session.reload.tagPageAsk(of: Self.swift, on: .timeline) == PageAsking(stopped: true))
        #expect(TimelineToast.asked(PageAsking(stopped: true), note: nil, language: .english)?.text == "Reload stopped.")
        #expect(session.reload.tagFailed.isEmpty && session.reload.tagAsk?.reach.asked == [Self.one], "the page stays, and whom it asked")
        #expect(!session.reload.stopped && session.reload.line == nil, "the stream's toast says nothing of it")
        #expect(ReloadMark.shown(canReload: true, stoppable: false) == .reload)

        await gated.gate.open()
        // No `by:`: the read that was stopped is the reload's own task, which no check can name.
        await met("the ask stopped is answered past the gate") { await gated.requested().contains(Self.tagAddress) }
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await session.store.note(Self.fromTheWire) == nil, "what came late landed nowhere")

        await session.reload.tagAgain(Self.swift, timeline: .all, in: session)
        #expect(await gated.asks == 2, "asked again after the stop")
        #expect(await session.store.note(Self.fromTheWire) != nil)
        #expect(session.reload.tagPageAsk(of: Self.swift, on: .timeline) == PageAsking(), "and the stop is said no longer")
    }

    @Test("A hashtag's ask is its own page's and its side's: Escape and Stop on it leave a reload of the stream running, and its toast is the page's; the same hashtag open on Trends is not told of the timeline's ask, nor stops it")
    func theStopIsThePages() async throws {
        let gated = GatedHTTP([Self.tagAddress: Self.underTag], holding: "/api/v1/timelines/tag/Swift")
        let guardTask = watching(gated.gate, "the posts under the hashtag, held on the wire")
        defer { guardTask.cancel() }
        let session = await shell(gated)
        let running = Gate()
        let runningGuard = watching(running, "the stream's reload that is to run on")
        defer { runningGuard.cancel() }
        let stream = Task { await session.reload.run(.timeline) { await running.wait() } }
        await met("the stream's reload is running", by: stream) { session.reload.stoppable }
        let asking = Task { await session.reload.tag(Self.swift, timeline: .all, in: session) }
        await met("the source is asked for the hashtag", by: asking) { await gated.asks == 1 }

        let pages = ShellPersonPages()
        let front = try #require(TimelinePane.askInFront(.tag(Self.swift), rising: nil, of: pages, in: session))
        #expect(front == .tag(Self.swift))
        let toast = TimelinePane.banner(TimelinePane.ask(front, of: pages, in: session), note: nil, in: session)
        #expect(toast?.kind == .loading && toast?.text == "Asking one.example for #Swift…", "the page's words, not the stream's")
        #expect(TimelinePane.askInFront(nil, rising: nil, of: pages, in: session) == nil, "the stream in front: its own")

        session.stream = .trends
        #expect(TimelinePane.ask(front, of: pages, in: session) == PageAsking(), "Trends' page of it is not told")
        #expect(!TimelinePane.stop(front, of: pages, in: session), "nor stops it")
        session.stream = .timeline

        #expect(TimelinePane.stop(front, of: pages, in: session))
        await asking.value
        #expect(session.reload.stoppable && session.reload.running, "the stream's reload runs on")
        #expect(TimelinePane.ask(front, of: pages, in: session).stopped && !session.reload.stopped)
        #expect(session.reload.stop())
        await running.open()
        await stream.value
        await gated.gate.open()
    }

    @Test("The bar's mark and `r` are where a source of the timeline in front keeps tags, named for whom they ask; a pull is the press and then the wait")
    func theMarkAndThePull() async throws {
        let session = await shell(FixtureHTTP([Self.tagAddress: Self.underTag]))
        let reach = session.reload.tagReach(of: .all, in: session)
        #expect(reach.asked == [Self.one] && reach.tagless == [Self.forum], "the forum keeps no tags")
        #expect(TagPane.reloadName(Self.swift, asking: reach.asked, canReload: true, language: .english) == "Ask one.example again for #Swift")
        #expect(TagPane.reloadName(Self.swift, asking: reach.asked, canReload: true, language: .taiwanese) == "再向 one.example 詢問 #Swift")
        #expect(TagPane.reloadName(Self.swift, asking: reach.asked, canReload: false) == nil)
        #expect(TagPane.reloadName(Self.swift, asking: [], canReload: true) == nil, "nobody to ask: no mark")
        let onlyForum = ItemStore()
        await onlyForum.add(Source(host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 1, name: "Dev")]))
        let forum = ShellSession(http: FixtureHTTP([:]), store: onlyForum)
        await forum.reloadFromStore()
        #expect(forum.reload.tagReach(of: .all, in: forum).asked.isEmpty)

        var stopped = 0
        let acts = TagPane.acts(TagPageActs(onStop: { stopped += 1 }))
        acts.onStop?()
        #expect(stopped == 1 && TagPane.acts(TagPageActs()).onStop == nil, "Stop only where the page hands one")

        await PullsToReload.pull(
            offered: true, reload: {},
            settled: {
                await session.reload.tagAgain(Self.swift, timeline: .all, in: session)
                await session.reload.settled(.tag)
            }
        ) { _ in }
        #expect(session.reload.tagAsk?.tag == Self.swift && !session.reload.tagPageAsk(of: Self.swift, on: .timeline).stoppable)
        #expect(await session.store.note(Self.fromTheWire) != nil, "the pull asked, and it landed")
    }

    // MARK: - The press, by key and by touch

    @Test("t is the key, a pill's press is its touch path, and both walk the same step")
    func theKey() {
        #expect(DummyCommand.from("t") == .openTag)
        #expect(DummyCommand.from("t", typing: true) == nil)
        let line = DummyShortcut.all.first { $0.commands == [.openTag] }
        #expect(line?.keys == ["t"])
        #expect(line?.touch == .press)
        #expect(DummyCommand.walk.contains(.tag))
        #expect(DummyCommand.canWalk(whenOpen: [.tag]), "a row on a tag's page opens further")
        #expect(!DummyCommand.canWalk(whenOpen: [.viewer]))
        for key in ["shortcut.tag", "tag.asking", "tag.retry", "tag.retry.spoken", "tag.none"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("t opens the post's first tag, the next one on a tag's own page, and nothing behind a cover")
    func whichTagTOpens() {
        let item = DummyItem(Self.note("3", "#swift and #ios"))
        #expect(FediqoRootView.tagToOpen(in: item, lifted: false, standing: nil)?.text == "#swift")
        #expect(FediqoRootView.tagToOpen(in: item, lifted: false, standing: Self.swift)?.text == "#ios")
        #expect(FediqoRootView.tagToOpen(in: DummyItem(Self.note("4", "no tags")), lifted: false, standing: nil) == nil)
        let covered = Note(
            id: "https://\(Self.one)/users/ada/statuses/5", source: Source(host: Self.one, kind: .mastodon),
            author: "Ada", handle: "@ada@\(Self.one)", body: "#swift",
            postedAt: Date(timeIntervalSince1970: 5), categories: [.public], spoiler: "careful"
        )
        #expect(DummyItem(covered).covered)
        #expect(FediqoRootView.tagToOpen(in: DummyItem(covered), lifted: false, standing: nil) == nil)
        #expect(FediqoRootView.tagToOpen(in: DummyItem(covered), lifted: true, standing: nil)?.text == "#swift")
    }

    @Test("The same tag in another case, pressed on its own page, opens nothing")
    func sameTagOtherCase() {
        #expect(!FediqoRootView.opensAnew(PostTag("#SWIFT")!, standing: Self.swift))
        #expect(FediqoRootView.opensAnew(PostTag("#ios")!, standing: Self.swift))
        #expect(FediqoRootView.opensAnew(Self.swift, standing: nil))
    }

    @Test("Leaving a tag's page gives back the post the press was made from, on its row")
    func leavingGivesBackTheRow() {
        var walk = ShellWalk()
        let took = walk.walk(to: .tag(Self.swift), from: "row-3")
        #expect(took)
        #expect(walk.openedTag == Self.swift)
        let again = walk.walk(to: .tag(Self.swift), from: "row-9")
        #expect(!again, "the same page again is not a step")
        let left = walk.back()
        #expect(left?.lamp == "row-3")
        #expect(walk.isEmpty)
    }

    @Test("A pill pressed reaches the walk with its row, by the tag's own address, in any script")
    func thePressIsRouted() throws {
        let tags = ShellTags()
        var pressed: [(String, String?)] = []
        tags.placing = { tag, row in
            pressed.append((tag.text, row))
            return true
        }
        for tag in [Self.swift, PostTag("#台灣")!] {
            let url = try #require(ShellTags.url(for: tag))
            #expect(ShellTags.tag(in: url) == tag)
            #expect(!Host.allowsFetch(url), "never an address anything fetches")
        }
        #expect(ShellTags.tag(in: URL(string: "https://one.example/tags/swift")!) == nil)
        #expect(tags.press(Self.swift, from: "row-1"))
        let texts = pressed.map { $0.0 }
        let rows = pressed.map { $0.1 }
        #expect(texts == ["#Swift"])
        #expect(rows == ["row-1"])
    }

    @Test("Pressable, a pill takes the control's ink and the tag's address, and nothing else changes")
    func thePillsLook() {
        let plain = EmojiText.drawn(Self.swift)
        #expect(EmojiText.drawn(Self.swift, ink: nil) == plain, "outside the shell, #123's label exactly")
        #expect(EmojiText.drawn(Self.swift, ink: .green) != plain)
        let cut: [EmojiRun] = [.text("say "), .tag(Self.swift)]
        #expect(EmojiText.line(cut, [:], at: 0, baseline: 0)
            == EmojiText.line(cut, [:], at: 0, baseline: 0, tagInk: nil))
        #expect(EmojiText.tags(in: cut) == [Self.swift])
    }

    @Test("The page draws in light and dark: on its way, with its mark, and empty")
    func thePageDraws() throws {
        for scheme in [ColorScheme.light, .dark] {
            for (asking, reload) in [([Self.one], "Ask one.example again for #Swift"), ([], nil)] {
                let pane = TagPane(
                    said: TagPageSaid.made(of: Self.swift, held: 0, asking: asking), items: [], reload: reload,
                    catalogues: EmojiCatalogueStore(), posts: ForumPosts(http: FixtureHTTP([:])),
                    selectedID: .constant(nil),
                    decks: .constant(ShellDecks()), playback: ShellPlayback(),
                    onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                    jumpToTop: 0
                )
                .frame(width: 390, height: 400)
                .environment(\.colorScheme, scheme)
                #expect(ImageRenderer(content: pane).cgImage != nil)
            }
        }
    }
}

/// A signed-in door nobody holds a token for: never reached.
private struct NoSender: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw FixtureHTTPError.unmapped
    }
}
