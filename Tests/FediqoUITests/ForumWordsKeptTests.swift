import Foundation
import Testing

@testable import FediqoCore
@testable import FediqoUI

/// A forum post's words, once read, are kept on this device with the post — #154.
@MainActor
@Suite("A forum post's words, kept with its row")
struct ForumWordsKeptTests {
    static let host = "bbs.example"
    static let tid = 88012
    static let address = "https://\(host)/forum.php?mod=viewthread&tid=\(tid)&mobile=2"
    static let forum = Source(host: host, kind: .discuz)
    static let key = NoteKey(host: host, id: "discuz:\(host):\(tid)")

    static func page(_ words: String) -> String {
        #"""
        <div class="comiis_postli" id="pid19101">
        <div class="comiis_postli_top"><h2><a href="home.php?mod=space&uid=71">小北</a></h2></div>
        <div class="comiis_postli_time"><span>22&nbsp;分钟前</span></div>
        <div class="comiis_a comiis_message_table cl">
        """# + words + "</div>\n</div>"
    }

    static let locked = page(#"<div class="locked">游客请<a href="member.php?mod=logging&action=login">登录</a>后查看回复内容</div>"#)

    static func row(opening: ForumOpening? = nil) -> Note {
        Note(
            id: key.id, source: forum, author: "小北", handle: "@小北@\(host)", body: "",
            title: "旧插座", postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [.board(id: "7")], opening: opening
        )
    }

    /// A session over a store holding the one row, as a launch would build it.
    static func session(
        _ http: any HTTPClient, holding note: Note = row()
    ) async -> (ShellSession, ItemStore, Saves) {
        let store = ItemStore(sources: [forum], notes: [note])
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            forums: ForumSessions(credentials: MemoryCredentials()),
            posts: ForumPosts(http: http)
        )
        let saves = Saves()
        session.persist = { saves.count += 1 }
        await session.reloadFromStore()
        return (session, store, saves)
    }

    static func ref(in session: ShellSession) -> ForumThreadRef? {
        session.notes.first.map(DummyItem.init).flatMap(ForumThreadRef.init)
    }

    @Test("The first read of a row's opening post is kept with the row, and saved")
    func theFirstReadIsKept() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.page("旧插座该换了。"))])
        let (session, store, saves) = await Self.session(http)
        let ref = try #require(Self.ref(in: session))
        #expect(session.posts.asks(ref), "the premise: a row nobody reached asks")

        await session.posts.fetch(ref)
        #expect(await spun { await store.note(Self.key)?.opening != nil }, "nothing was kept")
        #expect(await store.note(Self.key)?.opening?.words == "旧插座该换了。")
        #expect(await spun { saves.count > 0 }, "kept and never saved")
    }

    @Test("After a relaunch the kept words draw at once, with no request and no network")
    func aRelaunchDrawsTheKeptWords() async throws {
        let dark = FixtureHTTP()
        let kept = ForumOpening(words: "旧插座该换了。", avatarURL: URL(string: "https://\(Self.host)/a.png"))
        let (session, _, _) = await Self.session(dark, holding: Self.row(opening: kept))
        let ref = try #require(Self.ref(in: session))

        #expect(session.posts.reading(ref) == .words("旧插座该换了。"))
        #expect(session.posts.avatar(of: ref) == kept.avatarURL)
        #expect(!session.posts.asks(ref), "a row kept with its words would ask the forum again")
        #expect(await dark.requested.isEmpty)
    }

    @Test("Reading the row again replaces the kept words with what the forum says now")
    func aReloadReplacesThem() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.page("换好了。"))])
        let (session, store, _) = await Self.session(http, holding: Self.row(opening: ForumOpening(words: "旧的")))
        let ref = try #require(Self.ref(in: session))

        #expect(await session.posts.reload(ref, within: .seconds(5)))
        #expect(session.posts.reading(ref) == .words("换好了。"))
        #expect(await spun { await store.note(Self.key)?.opening?.words == "换好了。" })
    }

    @Test("Reading its board again makes a kept row ask once more when it is reached")
    func aBoardReloadMakesTheRowAsk() async throws {
        let (session, _, _) = await Self.session(FixtureHTTP(), holding: Self.row(opening: ForumOpening(words: "旧的")))
        let ref = try #require(Self.ref(in: session))
        #expect(!session.posts.asks(ref))
        let generation = session.posts.generation

        session.posts.revisit(host: Self.host)

        #expect(session.posts.asks(ref), "a board read again left its rows' words as they were")
        #expect(session.posts.generation > generation, "the rows on screen would not hear of it")
        #expect(session.posts.reading(ref) == .words("旧的"), "the kept words went before new ones came")
    }

    @Test("A withheld post is not kept, and a later read is still asked for")
    func withheldIsNotKept() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.locked)])
        let (session, store, _) = await Self.session(http)
        let ref = try #require(Self.ref(in: session))
        var handed: [ForumOpening] = []
        session.posts.keeping = { _, opening in handed.append(opening) }

        await session.posts.fetch(ref)
        #expect(session.posts.reading(ref) == .withheld, "the premise: the forum withheld it")
        #expect(handed.isEmpty, "the forum's notice was kept as the author's words")
        #expect(await store.note(Self.key)?.opening == nil)
        // Signed in, the same row is asked again as a member (#153's rule).
        session.posts.signedIn(host: Self.host)
        #expect(session.posts.asks(ref))
    }

    @Test("Clear keeps the rows and their words, and asks the forum for nothing")
    func clearKeepsTheWords() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.page("旧插座该换了。"))])
        let (session, store, _) = await Self.session(http)
        await session.posts.fetch(try #require(Self.ref(in: session)))
        #expect(await http.requested.count == 1)

        await session.clear(host: Self.host)

        #expect(session.posts.holding(host: Self.host) == (0, 0), "the cache Clear empties is not empty")
        let after = try #require(Self.ref(in: session), "Clear took the row")
        #expect(session.posts.reading(after) == .words("旧插座该换了。"), "Clear took the words with the cache")
        #expect(!session.posts.asks(after))
        #expect(await spun { await store.note(Self.key)?.opening?.words == "旧插座该换了。" })
        #expect(await http.requested.count == 1)
    }

    @Test("Remove takes the words with the rows")
    func removeTakesTheWords() async throws {
        let (session, store, _) = await Self.session(FixtureHTTP(), holding: Self.row(opening: ForumOpening(words: "旧的")))
        await session.remove(host: Self.host)
        #expect(await store.note(Self.key) == nil)
        #expect(session.notes.isEmpty)
        // And an opening landing after the row went is not a way back in.
        #expect(await !store.keep([Self.key: ForumOpening(words: "迟到的")]))
    }

    @Test("A row nobody reached is read for nothing, and nothing is kept for it")
    func unreachedRowsGrowNothing() async throws {
        let http = FixtureHTTP([Self.address: .text(Self.page("旧插座该换了。"))])
        let (session, store, saves) = await Self.session(http)
        for _ in 0..<20 { await Task.yield() }
        #expect(await http.requested.isEmpty)
        #expect(await store.note(Self.key)?.opening == nil)
        #expect(saves.count == 0)
    }
}

/// How many times the session asked for the store to be saved.
@MainActor
final class Saves {
    var count = 0
}
