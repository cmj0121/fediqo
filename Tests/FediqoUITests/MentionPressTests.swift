import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #310: somebody mentioned in a post's words is a press that opens their page — one step of the
/// walk, for somebody this device never met as well — and only whoever the source said the post
/// mentions is one.
@MainActor
@Suite("Pressing somebody mentioned in a post's words", .watched)
struct MentionPressTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let ada = "@ada@m.example"
    private static let cyd = "@cyd@two.example"
    private static let mentioned = PostMention(text: "@ada", handle: ada)

    init() {
        L10n.language = .english
    }

    private static func note(_ body: String, mentions: [String], source: Source = source) -> Note {
        Note(
            id: "https://\(source.host)/users/bob/statuses/1", source: source, author: "Bob",
            handle: source.kind == .mastodon ? "@bob@\(source.host)" : "", body: body,
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], mentions: mentions
        )
    }

    // MARK: - What is drawn

    @Test("Somebody mentioned is drawn as a press: their letters as written, in the control's ink and underlined — told by more than colour")
    func drawnAsAPress() throws {
        let ink = ShellChrome.selectInk(.light)
        let url = try #require(ShellMentions.url(for: Self.ada))
        var letters = AttributedString("@ada")
        letters.link = url
        letters.foregroundColor = ink
        letters.underlineStyle = .single
        #expect(EmojiText.drawn(Self.mentioned, ink: ink) == Text(letters))

        let cut = EmojiRun.prose(in: "hi @ada and @eve", emojis: [], mentions: [Self.ada])
        #expect(EmojiText.line(cut, [:], at: 0, baseline: -4, nameInk: ink)
            == Text(verbatim: "") + Text(verbatim: "hi ") + EmojiText.drawn(Self.mentioned, ink: ink)
            + Text(verbatim: " and @eve"), "an @word the source did not list is letters")
    }

    @Test("Where a press opens nothing — outside the shell — they are the letters and nothing more")
    func lettersWhereNothingOpens() {
        let cut = EmojiRun.prose(in: "hi @ada", emojis: [], mentions: [Self.ada])
        #expect(EmojiText.line(cut, [:], at: 0, baseline: -4)
            == Text(verbatim: "") + Text(verbatim: "hi ") + Text(verbatim: "@ada"))
    }

    @Test("A row's words are drawn with whom its post mentions; a boost's with the boosted post's, a quoted post's with its own")
    func theRowCarriesThem() {
        let post = Self.note("hi @ada", mentions: [Self.ada])
        #expect(DummyItem(post).mentions == [Self.ada])
        let boost = Note(
            id: "https://m.example/users/cyd/statuses/2", source: Self.source, author: "Cyd", handle: "@cyd@m.example",
            body: "", postedAt: post.postedAt, categories: [.public], refs: [Reference(kind: .reblogs, id: post.id)]
        )
        #expect(DummyItem(boost, reblogging: post).mentions == [Self.ada])
        #expect(QuotedPost(post).mentions == [Self.ada])
    }

    @Test("A covered post's words, a label, and a forum post's words name nobody")
    func whereNobodyIsNamed() {
        let cache = EmojiCache(http: FixtureHTTP())
        let covered = EmojiText.words("hi @ada", emojis: [], host: Self.host, covered: true, mentions: [Self.ada])
        #expect(!covered.linked && covered.mentions.isEmpty)
        let label = EmojiText("@ada@m.example", emojis: [], host: Self.host, role: .meta, cache: cache)
        #expect(label.mentions.isEmpty)

        let forum = Self.note("@ada 你好 https://e.test/a", mentions: [], source: Source(host: "forum.example", kind: .discuz))
        let item = DummyItem(forum)
        #expect(item.mentions.isEmpty)
        #expect(cache.proseRuns(in: item.body, from: [], mentions: item.mentions) == cache.proseRuns(in: item.body, from: []))
        #expect(EmojiText.mentions(in: cache.proseRuns(in: item.body, from: [], mentions: item.mentions)).isEmpty)
    }

    @Test("The same words under another list are another cut, and each is remembered as itself")
    func rememberedByTheList() {
        let cache = EmojiCache(http: FixtureHTTP())
        let plain = cache.proseRuns(in: "hi @ada", from: [])
        let named = cache.proseRuns(in: "hi @ada", from: [], mentions: [Self.ada])
        #expect(plain == [.text("hi @ada")])
        #expect(named == [.text("hi "), .mention(Self.mentioned)])
        #expect(cache.proseRuns(in: "hi @ada", from: []) == plain)
        #expect(cache.proseRuns(in: "hi @ada", from: [], mentions: [Self.ada]) == named)
    }

    // MARK: - What a listener is given

    @Test("Through VoiceOver the words are read as written, and each person named is one action that says who, by their whole handle")
    func spokenAndNamed() {
        let cut = EmojiRun.prose(in: "@ada, @cyd@two.example and @ada", emojis: [], mentions: [Self.ada, Self.cyd])
        #expect(EmojiText.spoken(cut) == Text(verbatim: "@ada, @cyd@two.example and @ada"))
        let handles = MentionWays.handles(in: EmojiText.mentions(in: cut))
        #expect(handles == [Self.ada, Self.cyd], "somebody named twice is one action")
        for language in [DummyLanguage.english, .taiwanese] {
            let said = MentionWays.name(of: Self.ada, language: language)
            #expect(said.contains(Self.ada) && said != Self.ada)
        }
    }

    @Test("The action's name is one line and no longer than a handle is, whatever a source listed")
    func theNameIsOneLine() {
        #expect(MentionWays.name(of: "@ada\n@m.example") == MentionWays.name(of: LineText.oneLine("@ada\n@m.example")))
        #expect(!MentionWays.name(of: "@ada\n@m.example").contains("\n"))
        let long = "@" + String(repeating: "a", count: 2000) + "@m.example"
        #expect(MentionWays.name(of: long).count < 500)
        #expect(!MentionWays.name(of: long).contains("@m.example"))
    }

    // MARK: - Where the press goes

    @Test("A mention pressed reaches the walk with who, through which source and on which row, by an address nothing fetches")
    func thePressIsRouted() throws {
        let mentions = ShellMentions()
        #expect(!mentions.press(Self.ada, at: Self.host, from: "row-1"), "nothing set, nothing opened")
        var pressed: [[String?]] = []
        mentions.placing = { handle, host, row in
            pressed.append([handle, host, row])
            return true
        }
        for handle in [Self.ada, Self.cyd] {
            let url = try #require(ShellMentions.url(for: handle))
            #expect(ShellMentions.handle(in: url) == handle)
            #expect(!Host.allowsFetch(url), "never an address anything fetches")
            #expect(ShellTags.tag(in: url) == nil)
        }
        #expect(ShellMentions.handle(in: URL(string: "https://m.example/@ada")!) == nil)
        #expect(mentions.press(Self.ada, at: Self.host, from: "row-1"))
        #expect(pressed == [[Self.ada, Self.host, "row-1"]])
    }

    @Test("The address carries a handle there and back as it was listed", arguments: [
        "@ada@m.example", "@Ada@One.Example", "@a.d-a_1@two.example", "@ada@例え.jp", "@ada@h.example:3000",
    ])
    func theAddressRoundTrips(handle: String) throws {
        #expect(PostMention.bounded([handle]) == [handle], "the premise: a handle a post may be kept as mentioning")
        let url = try #require(ShellMentions.url(for: handle))
        #expect(ShellMentions.handle(in: url) == handle)
        #expect(!Host.allowsFetch(url))
    }

    @Test("Only somebody the line names is opened, and through the source the line was read through: an address naming anybody else opens nobody")
    func onlyWhoTheLineNames() throws {
        let mentions = ShellMentions()
        var pressed: [[String?]] = []
        mentions.placing = { handle, host, row in
            pressed.append([handle, host, row])
            return true
        }
        let line = [Self.mentioned]
        let theirs = try #require(ShellMentions.url(for: Self.ada))
        let forged = try #require(URL(string: "fediqo-mention://person/@eve@x"))
        #expect(ShellMentions.handle(in: forged) == "@eve@x", "the premise: it is spelled as a mention's address")
        #expect(ShellMentions.listed(in: forged, among: line) == nil)
        #expect(ShellMentions.listed(in: theirs, among: line) == Self.ada)
        #expect(ShellMentions.listed(in: theirs, among: []) == nil)

        #expect(ShellMentions.answer(forged, among: line, at: Self.host, from: "row-1", by: mentions) == false)
        #expect(pressed.isEmpty, "nobody was asked for")
        #expect(ShellMentions.answer(theirs, among: line, at: Self.host, from: "row-1", by: mentions) == true)
        #expect(pressed == [[Self.ada, Self.host, "row-1"]], "who, the line's own source, the line's own row")
        #expect(ShellMentions.answer(theirs, among: line, at: Self.host, from: nil, by: nil) == false)
        // Not a mention's address: nothing said, and the next rule answers.
        #expect(ShellMentions.answer(URL(string: "https://m.example/@ada")!, among: line, at: Self.host, from: nil, by: mentions) == nil)
        #expect(pressed.count == 1)
    }

    @Test("A server's name is one name however it is cased: both spellings are one person, one page, and one step")
    func theHostIsFolded() throws {
        let one = try #require(DummyPerson(handle: "@ada@M.Example", host: Self.host))
        let other = try #require(DummyPerson(handle: Self.ada, host: Self.host))
        #expect(one == other && one.id == other.id && one.handle == Self.ada)
        #expect(DummyPerson(handle: "@Ada@M.Example", host: Self.host)?.handle == "@Ada@m.example", "the name is kept as sent")
        var walk = ShellWalk()
        #expect(FediqoRootView.walkToMentioned("@ada@M.EXAMPLE", at: Self.host, from: "row-1", on: &walk) != nil)
        #expect(FediqoRootView.walkToMentioned(Self.ada, at: Self.host, from: "row-2", on: &walk) == nil)
        #expect(walk.depth == 1)
    }

    @Test("The press is one step of the walk onto their page — the page a row of theirs opens — and leaving gives the row back")
    func oneStepOfTheWalk() throws {
        var walk = ShellWalk()
        let took = try #require(FediqoRootView.walkToMentioned(Self.ada, at: Self.host, from: "row-3", on: &walk))
        #expect(took.row == "row-3" && walk.depth == 1)
        #expect(walk.openedPerson == took.who)
        let theirs = Note(
            id: "https://m.example/users/ada/statuses/9", source: Self.source, author: "Ada", handle: Self.ada,
            body: "", postedAt: Date(timeIntervalSince1970: 0), categories: []
        )
        #expect(took.who.id == DummyPerson(making: theirs)?.id, "one person, however they were met")
        #expect(took.who.wrote(theirs))

        #expect(FediqoRootView.walkToMentioned(Self.ada, at: Self.host, from: "row-9", on: &walk) == nil,
                "their page already in front is not a step")
        #expect(FediqoRootView.walkToMentioned("", at: Self.host, from: "row-9", on: &walk) == nil)
        #expect(walk.back()?.lamp == "row-3")
        #expect(walk.isEmpty)
    }

    @Test("Somebody never seen before: the page opened from a mention asks their source who they are by the handle it listed, and then for their posts — with nothing of theirs held")
    func somebodyNeverSeen() async throws {
        let lookup = "/api/v1/accounts/lookup?acct=cyd@two.example"
        let statuses = "/api/v1/accounts/77/statuses"
        let server = PageServer([
            lookup: PageServer.Answer(body: #"{"id":"77","acct":"cyd@two.example","display_name":"Cyd","note":"<p>Far away</p>"}"#),
            statuses: PageServer.Answer(body: #"""
            [{"id":"5","uri":"https://two.example/users/cyd/statuses/5","created_at":"2026-10-01T00:00:00.000Z",
              "content":"<p>from afar</p>","visibility":"public","account":{"acct":"cyd@two.example","display_name":"Cyd"}}]
            """#),
        ])
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        #expect(session.notes.isEmpty, "the premise: nobody has been met")

        var walk = ShellWalk()
        let who = try #require(FediqoRootView.walkToMentioned(Self.cyd, at: Self.host, from: nil, on: &walk)).who
        let pages = ShellPersonPages()
        await pages.opened(who, in: session)
        #expect(await server.asked == [lookup])
        #expect(pages.said(of: who, in: session)?.person?.accountID == "77")

        var lamp: String?
        _ = pages.turn(who, to: .posts, lamp: &lamp, in: session)
        await pages.fronted(who, in: session)
        #expect(await server.asked == [lookup, statuses])
        #expect(pages.said(of: who, in: session)?.posts?.map(\.statusID) == ["5"])
    }
}
