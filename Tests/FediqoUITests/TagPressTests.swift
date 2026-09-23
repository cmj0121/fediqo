import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #124: pressing a hashtag shows what this device holds under it, and asks the sources of the
/// timeline in front for more — which lands in the store first.
@MainActor
@Suite("Pressing a hashtag")
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
        await session.reloadFromStore()
        return session
    }

    // MARK: - What this device holds under it

    @Test("A tag's page is the posts held that carry it, whatever case it was typed in, and nothing that only says the word")
    func heldUnderTheTag() async {
        let session = await shell(FixtureHTTP([:]))
        #expect(session.heldPosts(under: Self.swift).map(\.id) == [Self.note("1", "").key.rowID])
        #expect(session.heldPosts(under: PostTag("#nothing")!).isEmpty)
    }

    @Test("A press asks the Mastodon of the timeline in front; what it sends is held aside, and the page renews")
    func asksAndRenews() async throws {
        let http = FixtureHTTP([Self.tagAddress: Self.underTag])
        let session = await shell(http)
        let following = Task { await session.followStore() }
        defer { following.cancel() }

        await session.reload.tag(Self.swift, timeline: .all, in: session)
        #expect(await http.requested.map(\.absoluteString) == [Self.tagAddress], "the forum is not asked")
        #expect(session.reload.tagAsk?.asked == [Self.one])
        #expect(await spun { session.heldPosts(under: Self.swift).count == 2 }, "renewed with no press")
        #expect(session.heldPosts(under: Self.swift).first?.id == Self.fromTheWire.rowID)
        #expect(await session.store.note(Self.fromTheWire)?.holding == .aside, "the store's answer, held aside")
        #expect(!session.notes.contains { $0.key == Self.fromTheWire }, "All did not grow")
        #expect(session.held(Self.fromTheWire.rowID) != nil, "a row held aside still opens its conversation")
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

    @Test("While on its way the page says so and shows what was held; a failure says so there, and a retry asks again")
    func onItsWayFailingAndRetry() async throws {
        let gated = GatedHTTP([Self.tagAddress: .text("oops", status: 500)], holding: "/api/v1/timelines/tag/Swift")
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let session = await shell(gated)

        let asking = Task { await session.reload.tag(Self.swift, timeline: .all, in: session) }
        #expect(await spun { await gated.asks == 1 })
        #expect(session.reload.tagAsking == [Self.one])
        #expect(TagPane.said(asking: session.reload.tagAsking, failed: [], tag: Self.swift)
            == .asking("Asking one.example for #Swift…"))
        #expect(session.heldPosts(under: Self.swift).count == 1, "what was held, not waiting")

        await gated.gate.open()
        await asking.value
        #expect(session.reload.tagAsking.isEmpty)
        #expect(session.reload.tagFailed == [Self.one])
        #expect(TagPane.said(asking: [], failed: session.reload.tagFailed, tag: Self.swift)
            == .failed("Could not ask one.example for #Swift."))

        await session.reload.tag(Self.swift, timeline: .all, in: session)
        #expect(await gated.asks == 2, "tried again")
    }

    @Test("A tag with nothing under it reads as empty, not as waiting")
    func emptyIsEmpty() async {
        let http = FixtureHTTP(["/api/v1/timelines/tag/nothing": .text("[]")])
        let session = await shell(http)
        let nothing = PostTag("#nothing")!
        await session.reload.tag(nothing, timeline: .all, in: session)
        #expect(session.heldPosts(under: nothing).isEmpty)
        #expect(session.reload.tagAsking.isEmpty)
        #expect(TagPane.said(asking: [], failed: session.reload.tagFailed, tag: nothing) == nil)
        #expect(TagPane.none(nothing) == "Nothing under #nothing has reached this device.")
    }

    @Test("Leaving ends the ask: nothing it had not brought lands")
    func leavingEndsTheAsk() async {
        let gated = GatedHTTP([Self.tagAddress: Self.underTag], holding: "/api/v1/timelines/tag/Swift")
        let guardTask = hangGuard(gated.gate)
        defer { guardTask.cancel() }
        let session = await shell(gated)
        let asking = Task { await session.reload.tag(Self.swift, timeline: .all, in: session) }
        #expect(await spun { await gated.asks == 1 })
        session.reload.endTag()
        await asking.value
        #expect(session.reload.tagAsk == nil)
        await gated.gate.open()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await session.store.note(Self.fromTheWire) == nil)
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
        for key in ["shortcut.tag", "tag.asking", "tag.failed", "tag.retry", "tag.none"] {
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

    @Test("The page draws in light and dark: on its way, failed with a retry, and empty")
    func thePageDraws() throws {
        for scheme in [ColorScheme.light, .dark] {
            for (asking, failed) in [([Self.one], [String]()), ([], [Self.one]), ([], [])] {
                let pane = TagPane(
                    tag: Self.swift, items: [], asking: asking, failed: failed,
                    catalogues: EmojiCatalogueStore(), posts: ForumPosts(http: FixtureHTTP([:])),
                    selectedID: .constant(nil), marks: { _ in .constant(DummyMarks()) },
                    decks: .constant(ShellDecks()), playback: ShellPlayback(),
                    onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                    onRetry: {}, jumpToTop: 0, onToast: { _ in }, onBack: {}
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
