import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #334, the shell: pinning, quieting, translating a post, and who boosted and favourited it —
/// where each is offered in the post's `…` (and so in a hold on its row), the fixed order they
/// stand in, greyed with their lock's words where the sign-in lacks the part, what a press sends
/// and what it says when the source turns it away, the translation beside the words, and the keys.
///
/// Every wait is on an ask arriving (`PageServer`); every deadline is on a clock nobody turns.
@MainActor
@Suite("Pin, quiet, translate, and who boosted and favourited a post", .serialized, .watched)
struct PostActsTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let writes = "\(reads) write:statuses write:favourites"
    private static let whole = "\(writes) write:accounts read:mutes write:mutes read:blocks write:blocks"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let document = "/api/v2/instance"

    private static func instance(_ configuration: String) -> PageServer.Answer {
        PageServer.Answer(body: #"{"domain":"m.example","title":"M","version":"4.6.6","configuration":{\#(configuration)}}"#)
    }

    /// The reader's own post as the source answers about it, pinned or not.
    private static func own(pinned: Bool?, muted: Bool = false) -> String {
        let pin = pinned.map { #","pinned":\#($0)"# } ?? ""
        return #"""
        {"id":"13","uri":"https://m.example/13","created_at":"2023-11-14T22:13:33.000Z","content":"<p>mein Beitrag</p>",
         "visibility":"public","language":"de","muted":\#(muted)\#(pin),"account":{"acct":"me","display_name":"Me"}}
        """#
    }

    private func session(_ routes: [String: PageServer.Answer] = [:]) async -> (ShellSession, PageServer) {
        let base: [String: PageServer.Answer] = [
            Self.who: PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#),
            Self.document: Self.instance(#""accounts":{"max_pinned_statuses":5},"translation":{"enabled":true}"#),
        ]
        let server = PageServer(routes.merging(base) { mine, _ in mine })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        var mine = note("13", "@me@m.example", "mein Beitrag")
        mine.asked = .now()
        await session.store.ingest([
            note("11", "@ada@m.example", "ein Beitrag", counts: Counts(reblogs: 2, favourites: 3)), mine,
            Note(id: "f1", source: Self.forum, author: "Forumite", handle: "", body: "a thread", postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: []),
        ])
        await session.reloadFromStore()
        return (session, server)
    }

    private func note(_ id: String, _ handle: String, _ body: String, counts: Counts = Counts()) -> Note {
        var note = Note(
            id: "https://m.example/\(id)", source: Self.source, author: "Somebody", handle: handle, body: body,
            postedAt: Date(timeIntervalSince1970: 1_700_000_000 + (Double(id) ?? 0)), categories: [.public],
            pinned: handle == "@me@m.example" ? false : nil, muted: false, audience: .everyone, counts: counts,
            statusID: id, language: "de"
        )
        note.asked = .now()
        return note
    }

    private func signIn(_ session: ShellSession, holding scopes: String = PostActsTests.whole) async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    private func row(_ id: String, in session: ShellSession) throws -> DummyItem {
        try #require(session.notes.first { $0.statusID == id || $0.id == id }.map { DummyItem($0) })
    }

    // MARK: - Where they are offered

    @Test("Signed in to act, somebody else's post offers Translate, Boosted by, Favourited by and Quiet, and the reader's own Pin besides; with no sign-in only the two lists, which anyone may read; a forum's post none of it")
    func whereOffered() async throws {
        let (session, _) = await session()
        let pages = ShellPersonPages()
        let theirs = try row("11", in: session), mine = try row("13", in: session), forum = try row("f1", in: session)
        let open: (PeopleList) -> Void = { _ in }
        #expect(session.postOffer(on: forum, people: pages, openPeople: open) == nil, "a forum gains nothing")
        let unsigned = try #require(session.postOffer(on: theirs, people: pages, openPeople: open))
        #expect(unsigned.boostedBy != nil && unsigned.favouritedBy != nil)
        #expect(unsigned.translate == nil && unsigned.pin == nil && unsigned.quiet == nil)
        // A Mastodon translates for nobody unsigned: Translate is dim, and the head says to sign in.
        #expect(unsigned.translateSignedOut == Self.host)
        var acting = ItemActing()
        acting.post = unsigned
        let menu = ItemActs.more(on: theirs, acting: acting, language: .english)
        #expect(menu.items.first { $0.name == "Translate" }?.look == .dim(.notNow))
        #expect(menu.whys.contains(String(format: L10n.t("item.act.translate.signIn", language: .english), Self.host)))

        // A sign-in that only reads: Translate is offered, which needs reading alone; Pin and
        // Quiet are drawn with their locks.
        try await signIn(session, holding: Self.reads)
        let reading = try #require(session.postOffer(on: mine, people: pages, openPeople: open))
        #expect(reading.translate != nil && reading.translateSignedOut == nil)
        #expect(reading.pin?.lock != nil && reading.quiet?.lock != nil)

        try await signIn(session)
        let other = try #require(session.postOffer(on: theirs, people: pages, openPeople: open))
        #expect(other.translate != nil && other.quiet != nil && other.pin == nil, "somebody else's is not pinned")
        #expect(other.quiet?.on == false && other.quiet?.lock == nil)
        let own = try #require(session.postOffer(on: mine, people: pages, openPeople: open))
        #expect(own.pin?.on == false && own.pin?.lock == nil && own.quiet != nil)
    }

    @Test("The items stand in X0's fixed order, after the way out to the post and before Report; the people lists open a step of the walk; signed in without the account part, Pin is dim with its lock's words at the menu's head and its press only asks")
    func orderAndLocks() async throws {
        let (session, _) = await session()
        try await signIn(session)
        let pages = ShellPersonPages()
        let mine = try row("13", in: session)
        var opened: [PeopleList] = []
        var acting = session.acting(on: mine)
        acting.post = session.postOffer(on: mine, people: pages, openPeople: { opened.append($0) })
        acting.report = ItemActing.Report(lock: nil) {}
        let names = ItemActs.more(on: mine, acting: acting, leave: {}, language: .english).items.map(\.name)
        let order = ["Translate", "Boosted by…", "Favourited by…", "Pin to your page", "Quiet this conversation", "Report post…"]
        let places = order.compactMap { names.firstIndex(of: $0) }
        #expect(places.count == order.count && places == places.sorted(), "\(names)")
        let leave = try #require(names.firstIndex(of: mine.outwardName))
        #expect(leave < places[0])

        acting.post?.boostedBy?.press()
        acting.post?.favouritedBy?.press()
        #expect(opened.map(\.which) == [.boostedBy, .favouritedBy] && opened.allSatisfy { $0.accountID == "13" && $0.host == Self.host })
        #expect(opened.first?.asked == .boostedBy(post: "13") && opened.last?.asked == .favouritedBy(post: "13"))

        try await signIn(session, holding: Self.writes)
        let locked = try #require(session.postOffer(on: mine, people: pages, openPeople: { _ in }))
        #expect(locked.pin?.lock != nil && locked.quiet?.lock != nil)
        acting.post = locked
        let menu = ItemActs.more(on: mine, acting: acting, language: .english)
        let pin = try #require(menu.items.first { $0.name == "Pin to your page" })
        #expect(pin.look == .dim(.askAgain) && pin.symbol == SourceRow.permissionSymbol)
        #expect(menu.whys.contains(L10n.t("part.account.unasked", language: .english)))
        #expect(menu.whys.contains(L10n.t("part.blocks.unasked", language: .english)))
        locked.pin?.press()
        #expect(session.partAsks.open?.ticked == [.account], "the press only asks")
    }

    // MARK: - What a press sends

    @Test("Pin sends to the post's own id and the row is pinned as the source answered; quiet the same; pressed again each goes the other way")
    func pinAndQuietLand() async throws {
        let (session, server) = await session([
            "/api/v1/statuses/13/pin": PageServer.Answer(body: Self.own(pinned: true)),
            "/api/v1/statuses/13/unpin": PageServer.Answer(body: Self.own(pinned: false)),
            "/api/v1/statuses/13/mute": PageServer.Answer(body: Self.own(pinned: false, muted: true)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages()
        let mine = try row("13", in: session)
        await session.turn(.pin, on: mine, people: pages)
        #expect(session.note(ofRow: mine.id)?.pinned == true)
        #expect(session.postOffer(on: mine, people: pages, openPeople: { _ in })?.pin?.on == true)
        await session.turn(.pin, on: mine, people: pages)
        #expect(session.note(ofRow: mine.id)?.pinned == false)
        await session.turn(.quiet, on: mine, people: pages)
        #expect(session.note(ofRow: mine.id)?.muted == true)
        #expect(await server.sent.map(\.ask) == ["/api/v1/statuses/13/pin", "/api/v1/statuses/13/unpin", "/api/v1/statuses/13/mute"])
        #expect(session.toast == nil)
    }

    @Test("A pin turned away says the host's limit where the page is full — in whatever language the source wrote it — and the source's own words otherwise; the row stands as it was")
    func pinRefused() async throws {
        let full = PageServer.Answer(body: #"{"error":"校驗失敗：釘選嘟文的數量已達上限"}"#, status: 422)
        let (session, _) = await session([
            "/api/v1/statuses/13/pin": full,
            "/api/v1/statuses/13": PageServer.Answer(body: Self.own(pinned: false)),
        ])
        try await signIn(session)
        let pages = ShellPersonPages()
        await pages.postActs.hosts.hear(Self.host, in: session)
        let mine = try row("13", in: session)
        await session.turn(.pin, on: mine, people: pages)
        #expect(session.toast?.text == String(format: L10n.t("item.act.pin.full.limit"), Self.host, 5))
        #expect(session.note(ofRow: mine.id)?.pinned != true, "nothing was pinned")

        let theirs = PageServer.Answer(body: #"{"error":"Validation failed: Someone else's post cannot be pinned"}"#, status: 422)
        let (other, _) = await self.session([
            "/api/v1/statuses/13/pin": theirs,
            "/api/v1/statuses/13": PageServer.Answer(body: Self.own(pinned: nil)),
        ])
        try await signIn(other)
        await other.turn(.pin, on: try row("13", in: other), people: ShellPersonPages())
        #expect(other.toast?.text == String(format: L10n.t("item.act.refused.said"), Self.host, "Validation failed: Someone else's post cannot be pinned"))
        #expect(ShellSession.refused(.quiet, to: true, URLError(.timedOut), host: Self.host, language: .english)
            == "Could not quiet the conversation at m.example. It stands as it was.")
        #expect(ShellSession.refused(.pin, to: true, MastodonWriteError.pinLimit(5), host: Self.host, language: .taiwanese)
            == "你在 m.example 的頁面最多只能釘選 5 則貼文。請先取消釘選一則。")
    }

    // MARK: - Translating

    @Test("Translate asks in the reader's language and the translation stands beside the post with who made it and from what; pressed again the original stands alone; the post is untouched")
    func translated() async throws {
        let (session, server) = await session([
            "/api/v1/statuses/11/translate": PageServer.Answer(body: #"{"content":"<p>a post</p>","spoiler_text":"","detected_source_language":"de","provider":"DeepL.com"}"#),
        ])
        try await signIn(session)
        let pages = ShellPersonPages()
        let theirs = try row("11", in: session)
        await session.translate(theirs, people: pages)
        let offer = try #require(session.postOffer(on: theirs, people: pages, openPeople: { _ in }))
        guard case .shown(let said)? = offer.translation else { Issue.record("not shown: \(String(describing: offer.translation))"); return }
        #expect(said.body == "a post" && said.provider == "DeepL.com" && offer.translated)
        let asked = await server.sent.first { $0.ask.hasSuffix("/translate") }
        #expect(asked?.method == "POST" && asked?.body.hasPrefix("lang=") == true, "\(String(describing: asked))")
        #expect(TranslationBand.whoMadeIt(said, host: Self.host, language: .english) == "Translated from German by DeepL.com")
        #expect(session.note(ofRow: theirs.id)?.body == "ein Beitrag")
        await session.translate(theirs, people: pages)
        #expect(session.postOffer(on: theirs, people: pages, openPeople: { _ in })?.translation == nil)
    }

    @Test("A translation's not-found where the host's document said nothing of translating is remembered for the run, and Translate is offered there no more; where the document says it translates, it is a sentence and nothing more; a post already in the reader's language is offered none")
    func notFound() async throws {
        let missing = PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)
        let (silent, _) = await session([
            Self.document: Self.instance(#""accounts":{}"#), "/api/v1/statuses/11/translate": missing,
        ])
        try await signIn(silent)
        let pages = ShellPersonPages()
        let theirs = try row("11", in: silent)
        await silent.translate(theirs, people: pages)
        #expect(pages.postActs.hosts.has(.translation, at: Self.host) == .absent)
        #expect(silent.postOffer(on: theirs, people: pages, openPeople: { _ in })?.translate == nil)

        let (says, _) = await session(["/api/v1/statuses/11/translate": missing])
        try await signIn(says)
        let other = ShellPersonPages()
        await says.translate(try row("11", in: says), people: other)
        #expect(other.postActs.hosts.has(.translation, at: Self.host) == .present)
        let offer = try #require(says.postOffer(on: try row("11", in: says), people: other, openPeople: { _ in }))
        #expect(offer.translate != nil && offer.translation == .failed(String(format: L10n.t("translation.none"), Self.host)))
        #expect(ShellSession.untranslated(MastodonTranslationError.unavailable, host: Self.host, language: .english)
            == "m.example's translator did not answer. The original stands; try again later.")
    }

    // MARK: - Keys, lists and words

    @Test("Each is reached by a key, listed among the keys that act and reached by a finger in the `…` and a hold; the two lists are titled by whose post they are")
    func keysListsWords() {
        #expect(DummyCommand.from("i") == .pin && DummyCommand.from("z") == .quiet && DummyCommand.from("n") == .translate)
        #expect(DummyCommand.from("B", shift: true) == .boostedBy && DummyCommand.from("F", shift: true) == .favouritedBy)
        #expect(DummyShortcut.all.first { $0.name == "boostedBy" }?.commands == [.boostedBy, .favouritedBy])
        #expect(DummyCommand.from("b") == .boost && DummyCommand.from("f") == .favourite)
        #expect(DummyCommand.from("B") == .boost && DummyCommand.from("F") == .favourite, "Caps Lock is not Shift")
        #expect(DummyCommand.from("b", shift: true) == .boostedBy)
        for (name, group) in [("pin", DummyShortcutGroup.act), ("quiet", .act), ("translate", .read), ("boostedBy", .act)] {
            let line = DummyShortcut.all.first { $0.name == name }
            #expect(line?.group == group && line?.touch == .press && line?.also == .hold, "\(name)")
            #expect(L10n.t("shortcut.\(name)", language: .english) != "shortcut.\(name)", "\(name)")
            #expect(L10n.t("shortcut.\(name)", language: .taiwanese) != L10n.t("shortcut.\(name)", language: .english), "\(name)")
        }
        let list = PeopleList(.boostedBy, ofPost: "11", at: Self.host, by: "@ada@m.example", counted: 2)
        #expect(PeopleSaid.title(list, language: .english) == "Who boosted @ada@m.example's post" && list.counted == 2)
        #expect(PeopleSaid.title(PeopleList(.favouritedBy, ofPost: "11", at: Self.host, by: "@ada@m.example", counted: nil), language: .taiwanese)
            == "誰收藏了 @ada@m.example 的貼文")
        for key in ["item.act.translate", "item.act.boostedBy", "item.act.favouritedBy", "item.act.pin", "item.act.unpin",
                    "item.act.quiet", "item.act.unquiet", "translation.by.from", "people.boostedBy.none"] {
            #expect(L10n.t(key, language: .taiwanese) != key && L10n.t(key, language: .english) != key, "\(key)")
        }
    }
}
