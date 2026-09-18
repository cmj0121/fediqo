import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

#if os(macOS)
import AppKit
import SwiftUI
#endif

/// Unit F6: the reader's own complaint, answered.
///
/// > the nested border is not well handled … only show the title, and no first article, which I
/// > expected you can load the first post (without thread) … give the options to load other
/// > threads
///
/// Three things are pinned here and they are the three the reader asked for: the boards under
/// boards drawn as boards under boards and pickable on their own (D29); a row's first post
/// fetched when the row is scrolled to, cached, and **bounded** (D30); and the way in to the rest
/// of the topic (D31). What `DiscuzClient` does with a thread page has its own suite in Core;
/// this one is about who asks for it, what is kept, what the reader is shown while it is coming,
/// and — the assertion the whole unit stands on — that none of it moves the row.
@MainActor
@Suite("Drawn as it arrives")
struct ForumPostsTests {
    private static let host = "install-c.example"
    private static let tid = 70241

    init() {
        L10n.language = .english
    }

    // MARK: - Addresses and values

    /// The address `DiscuzClient` builds for one thread. Written out rather than assembled,
    /// because a route that silently stopped matching would make every test here pass by
    /// answering `unmapped` — which is the failure mode a route table has.
    private static func threadAddress(_ host: String = host, _ tid: Int = tid) -> String {
        "https://\(host)/forum.php?mod=viewthread&tid=\(tid)&mobile=2"
    }

    private static func post(
        pid: Int = 1,
        floor: Int? = 1,
        author: String = "tinbox",
        body: String = "",
        quoted: String? = nil,
        withheld: Bool = false
    ) -> DiscuzPost {
        DiscuzPost(
            pid: pid, tid: tid, floor: floor, author: author,
            handle: "@\(author)@\(host)", body: body, quoted: quoted, isWithheld: withheld
        )
    }

    private static func ref(_ tid: Int = tid, host: String = host) -> ForumThreadRef {
        ForumThreadRef(host: host, tid: tid)
    }

    // MARK: - Which rows have a thread behind them

    /// **The one place `"discuz:<host>:<tid>"` is read back, checked against the one place it is
    /// written.** The two halves are in different modules and nothing but this holds them
    /// together: `DiscuzThread.asNote` is internal to Core, so the id is built by running a real
    /// `DiscuzClient` over a real board page and the ref is read off the `DummyItem` a row would
    /// actually be handed. A change to either spelling fails here rather than turning every forum
    /// row's post fetch off in silence.
    @Test("The id a thread is stored under is the id a row reads its number back out of")
    func theIdSpellingStillAgrees() async throws {
        // One board listing, written the way a Discuz! thread table is written — a
        // `<tbody id="normalthread_N">` around a title anchor marked `xst` and a person-cell
        // wrapped in `<cite>`. The number in the `<tbody>` id is the only thing this test is
        // about: it has to come out the other end as the number a row reads back.
        let http = FixtureHTTP([
            "https://\(Self.host)/forum.php?mod=forumdisplay&fid=34": .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=34">工具箱讨论区</a></h1>
            <table id="threadlisttableid">
            <tbody id="normalthread_40125"><tr>
            <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">工具箱一键下载安装</a></th>
            <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
            <td class="num"><a href="forum.php?mod=viewthread&tid=40125" class="xi2">7</a><em>120</em></td>
            </tr></tbody>
            </table></body></html>
            """#),
        ])
        let source = Source(host: Self.host, kind: .discuz)
        let notes = try await DiscuzClient(http: http, host: Self.host).board(34, source: source)
        let first = try #require(notes.first)

        let ref = try #require(ForumThreadRef(DummyItem(first)))
        #expect(ref.host == Self.host)
        #expect(ref.tid == 40125)
        // And the row agrees with the ref, because the row is what asks.
        #expect(Self.row(DummyItem(first)).thread == ref)
    }

    /// A row that is not a Discuz! thread has no thread behind it, and every one of these would
    /// otherwise be a request to somebody for a page that does not exist.
    ///
    /// **A Discourse thread is the case that matters.** Both forums draw as `.forum` because the
    /// shape is where the protocol stops mattering — which is exactly why the *prefix* is what is
    /// checked here and not the shape.
    @Test("Only a Discuz! thread has a thread to fetch")
    func nothingElseIsAThread() {
        func ref(_ id: String) -> ForumThreadRef? {
            ForumThreadRef(Self.item(id: id))
        }
        #expect(ref("discuz:\(Self.host):\(Self.tid)") != nil)
        #expect(ref("discourse:forum.example:12") == nil)
        #expect(ref("109252111") == nil)
        #expect(ref("") == nil)
        // A number that is not a number, a thread number that is not positive, and a host that
        // is not there — three shapes a stranger's markup or a fixture can produce, and none of
        // them names a page.
        #expect(ref("discuz:\(Self.host):nine") == nil)
        #expect(ref("discuz:\(Self.host):0") == nil)
        #expect(ref("discuz:\(Self.host):-3") == nil)
        #expect(ref("discuz::5") == nil)
        // Not folded into two by splitting wrong: a host with a colon in it is not a host.
        #expect(ref("discuz:a:b:5") == nil)

        // Decision 21: folded once, where it enters.
        #expect(ref("discuz:Install-C.EXAMPLE:7")?.host == "install-c.example")
    }

    /// The row's `id` names its source as well as its note (#10), so it is no longer the Discuz!
    /// spelling this reads back. A ref read off `id` instead of `noteID` would find no thread
    /// behind any row, and every forum post would open to nothing.
    @Test("A thread is still found when the row's id carries its host")
    func aHostPrefixedRowStillHasItsThread() throws {
        let item = Self.item(id: "discuz:\(Self.host):\(Self.tid)", kind: .discuz)
        #expect(item.id == NoteKey(host: Self.host, id: item.noteID).rowID)
        #expect(item.id != item.noteID)
        let ref = try #require(ForumThreadRef(item))
        #expect(ref.host == Self.host)
        #expect(ref.tid == Self.tid)
    }

    // MARK: - What a post is worth to a row

    /// **Withheld is asked before empty, and that ordering is the whole of this function.**
    ///
    /// A withheld post has an empty `body` *by construction* — Core takes the forum's notice out
    /// rather than putting the forum's sentence under the author's name — so a reader that asked
    /// `body.isEmpty` first would file every withheld post under "they wrote nothing". On
    /// `install-a.example` that is 19 replies in 20, which is not an edge case but the ordinary
    /// experience of a signed-out reader on that forum.
    @Test("A withheld post is not an empty one, and the order of the two tests is what says so")
    func withheldIsNotEmpty() {
        #expect(ForumReading.of(Self.post(body: "", withheld: true)) == .withheld)
        #expect(ForumReading.of(Self.post(body: "")) == .silent)
        #expect(ForumReading.of(Self.post(body: "hello")) == .words("hello"))
        // And the four say four different things out loud, none of them the empty string.
        let spoken = [ForumReading.coming, .withheld, .silent, .absent(.refused)]
            .map(ForumPostBand.spoken)
        #expect(Set(spoken).count == 4)
        #expect(spoken.allSatisfy { !$0.isEmpty && $0 != "item.forum.coming" })
    }

    /// Every one of Core's answers is given words here rather than inheriting somebody else's.
    ///
    /// Listed rather than enumerated over `allCases` because `DiscuzRequestError` has payloads
    /// and is not `CaseIterable`. What stops this list going stale is the `switch` in
    /// `ForumPosts.absence(for:)`, which has **no `default:`** — a ninth Core case breaks the
    /// build there, and this is then the list somebody has to come and extend.
    @Test("Every way a forum can say no gets its own sentence, and none of them is the same one")
    func everyRefusalHasWords() {
        let refused: [DiscuzRequestError] = [
            .challenged, .restricted, .refused(403), .http(500), .invalidURL,
        ]
        for error in refused {
            #expect(ForumPosts.absence(for: error) == .refused, "\(error)")
        }
        let unreadable: [DiscuzRequestError] = [.undecodable, .noThreads, .noBoards, .noPosts]
        for error in unreadable {
            #expect(ForumPosts.absence(for: error) == .unreadable, "\(error)")
        }
        // Anything that is not one of Core's answers is the network, not the forum — and a
        // cancellation is this device giving up, which is the one kind of nothing worth re-asking.
        #expect(ForumPosts.absence(for: CancellationError()) == .unreachable)
        #expect(ForumPosts.absence(for: FixtureHTTPError.unreachable) == .unreachable)
        #expect(ForumPosts.Absence.unreachable.asksAgain)
        #expect(![ForumPosts.Absence.refused, .unreadable, .crowded].contains { $0.asksAgain })

        // Four sentences, four strings, and every one of them shipped.
        let said: [ForumPosts.Absence] = [.refused, .unreadable, .unreachable, .crowded]
        let sentences = said.map(ForumPostBand.sentence)
        #expect(Set(sentences).count == 4)
        #expect(sentences.allSatisfy { !$0.hasPrefix("item.forum.") })
    }

    // MARK: - The fetch

    @Test("A row's first post is fetched once, kept, and not fetched again")
    func oneFetchAndThenItIsKept() async throws {
        // Discuz!'s own touch template, cut to the three things a post is: the `plc` box with the
        // `pid`, the `authi` list that carries the floor and the author, and the `message` the
        // words are in. The words are asserted below, so the words are written here.
        let http = FixtureHTTP([Self.threadAddress(): .text(#"""
        <div class="plc cl" id="pid9101">
        <ul class="authi"><li class="mtit">1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
        <div class="message">工具箱一键下载安装，脚本在附件里。</div>
        </div>
        """#)])
        let posts = ForumPosts(http: http)
        let ref = Self.ref()

        #expect(posts.reading(ref) == .coming)
        await posts.fetch(ref)

        guard case .words(let text) = posts.reading(ref) else {
            Issue.record("the opening post did not arrive: \(posts.reading(ref))")
            return
        }
        #expect(text.contains("工具箱"))
        #expect(await http.requested.count == 1)

        // Asked again, for a row scrolled back to: nothing goes on the wire.
        await posts.fetch(ref)
        #expect(await http.requested.count == 1)
        #expect(posts.holding(host: Self.host).count == 1)
        #expect(posts.holding(host: Self.host).bytes > 0)
        // And nothing is held for a forum this never read.
        #expect(posts.holding(host: "install-d.example") == (0, 0))
    }

    /// Two rows can stand on one thread — a globally pinned thread is in every board's listing —
    /// and two rows must not be two requests.
    @Test("Two rows wanting one thread wait on one request")
    func twoRowsShareOneFetch() async throws {
        let http = FixtureHTTP([Self.threadAddress(): .text(#"""
        <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
        <div class="message">一句话。</div></div>
        """#)])
        let posts = ForumPosts(http: http)
        let ref = Self.ref()

        async let first: Void = posts.fetch(ref)
        async let second: Void = posts.fetch(ref)
        _ = await (first, second)

        #expect(await http.requested.count == 1)
    }

    @Test("A thread the forum refuses is written off, and not asked for again")
    func arefusalIsRemembered() async throws {
        let http = FixtureHTTP([Self.threadAddress(): .body(Data(), status: 403)])
        let posts = ForumPosts(http: http)
        let ref = Self.ref()

        await posts.fetch(ref)
        #expect(posts.reading(ref) == .absent(.refused))
        await posts.fetch(ref)
        #expect(await http.requested.count == 1)
    }

    /// The other kind of nothing, and the one that is *not* permanent: a dark network is a fact
    /// about this moment, so the mark is lifted the instant anything at all gets through.
    @Test("A thread nothing answered for is asked again once something answers")
    func unreachableIsLiftedWhenAnythingLands() async throws {
        let http = FixtureHTTP([
            Self.threadAddress(): .fail,
            Self.threadAddress(Self.host, 99): .text(#"""
            <div class="plc" id="pid9109"><ul class="authi"><li>1<sup>#</sup></li>
            <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
            <div class="message">另一篇。</div></div>
            """#),
        ])
        let posts = ForumPosts(http: http)
        let dark = Self.ref()

        await posts.fetch(dark)
        #expect(posts.reading(dark) == .absent(.unreachable))
        let before = posts.generation

        // Something else got through, so the network is back and the write-off is void.
        await posts.fetch(Self.ref(99))
        #expect(posts.reading(dark) == .coming)
        #expect(posts.generation > before)
    }

    // MARK: - Bounded

    /// **The count bound, held from both sides.** A ceiling asserted with no floor is one of the
    /// three defects this branch wrote its first convention about: `<= held` alone passes for a
    /// cache that keeps nothing at all.
    @Test("The cache stops at its count bound, and keeps what it is allowed to keep")
    func theCountBoundHolds() {
        let posts = ForumPosts()
        for tid in 1...(ForumPosts.held + 40) {
            let ref = Self.ref(tid)
            // Read first, so this newcomer has a stamp and can outrank the ones before it — which
            // is what a band on screen does on every pass.
            _ = posts.reading(ref)
            posts.keep([Self.post(pid: tid, body: "words \(tid)")],
                       for: ForumPosts.Key(ref, .opening),
                       startedAt: posts.interest[ForumPosts.Key(ref, .opening)] ?? 0)
        }
        let holding = posts.holding(host: Self.host)
        #expect(holding.count == ForumPosts.held)
        #expect(holding.bytes > 0)
        // Oldest first: the thread nobody has looked at since the start is the one that went.
        #expect(posts.reading(Self.ref(1)) == .coming)
        // And the newest is still there.
        guard case .words = posts.reading(Self.ref(ForumPosts.held + 40)) else {
            Issue.record("the newest post was not kept")
            return
        }
    }

    /// **The byte bound, and the branch that makes admission terminate.** A newcomer that cannot
    /// be fitted without dropping something a band has wanted *since this fetch began* is
    /// declined rather than admitted — because admitting it starts the loop where what is dropped
    /// is re-asked for and re-asking drops another.
    @Test("A post that can only fit by dropping one on screen is declined, not admitted")
    func aCrowdedPostIsDeclinedRatherThanEvicting() {
        let posts = ForumPosts()
        // A third of the budget each, counted the way the cache counts — in **bytes**, not in
        // characters. Written in ASCII on purpose so the arithmetic in this test is the
        // arithmetic in the cache; `theCostIsBytesAndNotCharacters` is where the difference
        // between the two is pinned, and a forum whose posts are Chinese is where it bites.
        let big = String(repeating: "x", count: ForumPosts.budget / 3)

        // Two large posts, both read on the way in, so both carry a fresh stamp.
        for tid in 1...2 {
            let ref = Self.ref(tid)
            _ = posts.reading(ref)
            posts.keep([Self.post(pid: tid, body: big)], for: ForumPosts.Key(ref, .opening),
                       startedAt: posts.interest[ForumPosts.Key(ref, .opening)] ?? 0)
        }
        #expect(posts.holding(host: Self.host).count == 2)

        // A third, commissioned before either of those was last wanted — a fetch whose row has
        // since scrolled away, arriving behind two rows that are still being drawn.
        let late = Self.ref(3)
        posts.keep([Self.post(pid: 3, body: big + big)], for: ForumPosts.Key(late, .opening),
                   startedAt: 1)

        #expect(posts.reading(late) == .absent(.crowded))
        // And it did not take either of the two with it.
        #expect(posts.holding(host: Self.host).count == 2)
        #expect(posts.heldBytes <= ForumPosts.budget)
        // `.crowded` is not re-asked by itself. See `ForumPosts.Absence.crowded`.
        #expect(!ForumPosts.Absence.crowded.asksAgain)
    }

    /// The bound the whole scheme rests on, stated as an assertion rather than as a paragraph:
    /// the largest entry that can ever arrive has to fit beside another one, or a full cache
    /// declines a legal newcomer forever.
    @Test("The budget is at least twice the largest response the transport will take")
    func theBudgetFitsTwoOfTheLargestThingThatCanArrive() {
        #expect(ForumPosts.budget >= 2 * ForumPosts.maxBytes)
        // And the ceiling is a working size rather than a last line: seven times the largest
        // thread page measured on the four installs, and a sixty-fourth of the transport default.
        #expect(ForumPosts.maxBytes > 274_457)
        #expect(ForumPosts.maxBytes < 128 * 1024 * 1024)
        // Interest outlives entries by the ratio `trimInterest` depends on.
        #expect(ForumPosts.remembered >= 2 * ForumPosts.held)
    }

    /// **What a post weighs is bytes, not characters**, and on these forums that is a factor of
    /// three: every install measured is a Chinese-language board, and a post of a thousand
    /// characters is three thousand bytes of storage. A budget counted in characters would be
    /// three times the memory it claimed, on exactly the forums this unit was built for.
    ///
    /// The quotation and the author's name are counted too — they are the other two strings that
    /// came off a stranger's page and whose length a stranger therefore chooses.
    @Test("What a held post costs is its bytes, and everything a stranger wrote is counted")
    func theCostIsBytesAndNotCharacters() {
        let chinese = Self.post(body: String(repeating: "字", count: 100))
        let furniture = chinese.author.utf8.count + chinese.handle.utf8.count
        #expect(chinese.body.count == 100)
        #expect(ForumPosts.cost(of: [chinese]) == 300 + furniture)

        // A quotation is a stranger's words held on this device just as much as the body is.
        let quoting = Self.post(body: "ab", quoted: "cde")
        #expect(ForumPosts.cost(of: [quoting]) == 5 + furniture)
        #expect(ForumPosts.cost(of: []) == 0)
    }

    @Test("Records of nothing are bounded too")
    func theNegativeCacheIsBounded() {
        let posts = ForumPosts()
        for tid in 1...(ForumPosts.refusals + 50) {
            posts.note(.refused, for: ForumPosts.Key(Self.ref(tid), .opening))
        }
        #expect(posts.missing.count <= ForumPosts.refusals)
        // The entry just written is never the one removed, so the loop cannot spin.
        #expect(posts.missing[ForumPosts.Key(Self.ref(ForumPosts.refusals + 50), .opening)]
            == .refused)
    }

    // MARK: - What a reader clears

    @Test("Clear drops a forum's posts, and tells the bands still on screen")
    func clearReachesThePosts() async throws {
        let http = FixtureHTTP([Self.threadAddress(): .text(#"""
        <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
        <div class="message">一句话。</div></div>
        """#)])
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), posts: ForumPosts(http: http)
        )
        let ref = Self.ref()
        await session.posts.fetch(ref)
        #expect(session.posts.holding(host: Self.host).count == 1)
        let before = session.posts.generation

        await session.clear(host: Self.host.uppercased())

        #expect(session.posts.holding(host: Self.host) == (0, 0))
        #expect(session.posts.reading(ref) == .coming)
        // A bulk, deliberate invalidation is a fact about a cohort no single band can see for
        // itself, so it is announced — unlike ordinary eviction.
        #expect(session.posts.generation > before)
    }

    /// The inventory beside the Clear button has to be an answer about the thing the button
    /// presses, and what a reader has to be able to see is the figure **falling** — a button that
    /// appears to do nothing is the failure this screen is designed against. Sharing the session's
    /// own cache by construction is what makes that true; a pane wired to `.shared` while `clear`
    /// pressed something else would draw a figure that never moved.
    @Test("What Preferences reports and what Clear empties are the same posts")
    func theInventoryAndTheButtonAgree() async throws {
        let http = FixtureHTTP([Self.threadAddress(): .text(#"""
        <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
        <div class="message">一句话。</div></div>
        """#)])
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), posts: ForumPosts(http: http)
        )
        await session.posts.fetch(Self.ref())
        let held = session.posts.holding(host: Self.host)
        #expect(held.count == 1)
        #expect(held.bytes > 0)

        await session.clear(host: Self.host)
        #expect(session.posts.holding(host: Self.host) == (0, 0))
        // Both sentences the row can draw are shipped, and neither is a key falling through.
        for key in ["prefs.cache.posts", "prefs.cache.posts.none"] {
            #expect(L10n.t(key) != key)
        }
    }

    /// **The guard this project has now had to write three times.** `EmojiCatalogueStore` shipped
    /// without it and `ShellPictures` shipped without it: clearing the stored state alone leaves
    /// a fetch in the air which lands a moment later and files the forum straight back into the
    /// map the reader just emptied.
    ///
    /// Mutation-checked: delete the `cleared` guard in `ForumPosts.work` and this goes red on the
    /// first assertion rather than merely getting slower.
    @Test("A post that lands after a Clear is dropped, not filed back under the cleared forum")
    func aFetchLandingAfterAClearIsDropped() async throws {
        let gate = GateHTTP(Data(#"""
        <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
        <div class="message">一句话。</div></div>
        """#.utf8))
        let posts = ForumPosts(http: gate)
        let ref = Self.ref()

        let fetching = Task { await posts.fetch(ref) }
        await gate.waitForRequest()
        posts.forget(host: Self.host)
        await gate.open()
        await fetching.value

        #expect(posts.holding(host: Self.host) == (0, 0))
        #expect(posts.reading(ref) == .coming)
        #expect(posts.missing.isEmpty)
        // The record tidied itself away, so the next ask is a fresh one rather than a wait on a
        // task that has already finished.
        #expect(posts.inFlight.isEmpty)
    }

    // MARK: - The rest of the topic — D31

    /// **"Nobody has asked" and "there is nothing there" are opposite facts and are two cases.**
    /// A pane that folded them would draw a button for a topic with no replies, forever.
    @Test("The replies are asked for on a press, and arrive as the topic's own replies")
    func theRepliesArriveOnRequest() async throws {
        // One topic with an opening post and four answers, each on its own floor. The count and
        // the floors are what is asserted, so five numbered posts is what is written.
        let http = FixtureHTTP([Self.threadAddress(): .text(#"""
        <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
        <div class="message">工具箱一键下载安装。</div></div>
        <div class="plc" id="pid9102"><ul class="authi"><li>2<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=9">greenpine</a></li></ul>
        <div class="message">学到了。</div></div>
        <div class="plc" id="pid9103"><ul class="authi"><li>3<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=10">mossy</a></li></ul>
        <div class="message">收藏了。</div></div>
        <div class="plc" id="pid9104"><ul class="authi"><li>4<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=11">halfmoon</a></li></ul>
        <div class="message">试过可以用。</div></div>
        <div class="plc" id="pid9105"><ul class="authi"><li>5<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=12">quietriver</a></li></ul>
        <div class="message">再顶一次。</div></div>
        """#)])
        let posts = ForumPosts(http: http)
        let ref = Self.ref()

        #expect(posts.standing(of: ref) == .unasked)
        await posts.fetchReplies(ref)

        guard case .loaded(let replies) = posts.standing(of: ref) else {
            Issue.record("the replies did not arrive: \(posts.standing(of: ref))")
            return
        }
        #expect(replies.count == 4)
        #expect(replies.allSatisfy { $0.floor != 1 })
        // D31 is the replies of *this* topic and nothing else: one request, to this thread's own
        // address, and never the board's next page.
        #expect(await http.paths == ["/forum.php"])
    }

    /// The case the whole `isWithheld` distinction exists for, at the layer that draws it:
    /// `install-a.example` answers a signed-out reader with its own notice for 19 replies in 20,
    /// and a pane that drew those as empty would be telling the reader that nineteen people wrote
    /// nothing.
    ///
    /// The third-party (Comiis) template, because that is the install this happens on: a
    /// `comiis_postli` box per post, the author in `comiis_postli_top`, the words in
    /// `comiis_message_table` — and, in place of the words, `<div class="locked">`. The opening
    /// post is **unnumbered** here, which is the other thing that template does and the reason
    /// `post(tid:)` falls back to document order.
    @Test("Withheld replies reach the pane as withheld, not as people who wrote nothing")
    func withheldRepliesSurviveToThePane() async throws {
        let http = FixtureHTTP([
            Self.threadAddress("install-a.example", 88012): .text(#"""
            <div class="comiis_postli" id="pid19101">
            <div class="comiis_postli_top"><h2><a href="home.php?mod=space&uid=71">小北</a></h2></div>
            <div class="comiis_postli_time"><span>22&nbsp;分钟前</span></div>
            <div class="comiis_a comiis_message_table cl">旧插座该换了。</div>
            </div>
            <div class="comiis_postli" id="pid19102">
            <div class="comiis_postli_top"><h2><span>2<sup>#</sup></span><a href="home.php?mod=space&uid=72">灯下客</a></h2></div>
            <div class="comiis_postli_time"><span>16&nbsp;分钟前</span></div>
            <div class="comiis_a comiis_message_table cl">
            <div class="locked">游客请<a href="member.php?mod=logging&action=login">登录</a>后查看回复内容</div>
            </div></div>
            <div class="comiis_postli" id="pid19103">
            <div class="comiis_postli_top"><h2><span>3<sup>#</sup></span><a href="home.php?mod=space&uid=73">南窗</a></h2></div>
            <div class="comiis_postli_time"><span>15&nbsp;分钟前</span></div>
            <div class="comiis_a comiis_message_table cl">
            <div class="locked">游客请<a href="member.php?mod=logging&action=login">登录</a>后查看回复内容</div>
            </div></div>
            <div class="comiis_postli" id="pid19104">
            <div class="comiis_postli_top"><h2><span>4<sup>#</sup></span><a href="home.php?mod=space&uid=74">半山</a></h2></div>
            <div class="comiis_postli_time"><span>11&nbsp;分钟前</span></div>
            <div class="comiis_a comiis_message_table cl">
            <div class="locked">游客请<a href="member.php?mod=logging&action=login">登录</a>后查看回复内容</div>
            </div></div>
            <div class="comiis_postli" id="pid19105">
            <div class="comiis_postli_top"><h2><span>5<sup>#</sup></span><a href="home.php?mod=space&uid=75">老陈</a></h2></div>
            <div class="comiis_postli_time"><span>9&nbsp;分钟前</span></div>
            <div class="comiis_a comiis_message_table cl">
            <div class="locked">游客请<a href="member.php?mod=logging&action=login">登录</a>后查看回复内容</div>
            </div></div>
            """#),
        ])
        let posts = ForumPosts(http: http)
        let ref = Self.ref(88012, host: "install-a.example")
        await posts.fetchReplies(ref)

        guard case .loaded(let replies) = posts.standing(of: ref) else {
            Issue.record("the replies did not arrive")
            return
        }
        #expect(replies.count == 4)
        #expect(replies.allSatisfy { $0.isWithheld })
        #expect(replies.allSatisfy { $0.body.isEmpty })
        // Their names survived, which is what makes this "you may not read it" rather than
        // "nobody wrote anything" — and is what the row draws beside the lock.
        #expect(replies.allSatisfy { !$0.author.isEmpty })
    }

    /// **A press has to change something on screen.** `standing(of:)` answers `.coming` off the
    /// in-flight record, so that record has to be observed — unlike `ShellPictures.inFlight`,
    /// which nothing reads from a body. Without it the reader presses Load and the button sits
    /// there unchanged until the replies land.
    @Test("Pressing for the replies is visible before they arrive")
    func theWaitIsVisible() async throws {
        let gate = GateHTTP(Data(#"""
        <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
        <div class="message">一句话。</div></div>
        <div class="plc" id="pid9102"><ul class="authi"><li>2<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=9">greenpine</a></li></ul>
        <div class="message">回一句。</div></div>
        """#.utf8))
        let posts = ForumPosts(http: gate)
        let ref = Self.ref()

        let fetching = Task { await posts.fetchReplies(ref) }
        await gate.waitForRequest()
        #expect(posts.standing(of: ref) == .coming)

        await gate.open()
        await fetching.value
        guard case .loaded = posts.standing(of: ref) else {
            Issue.record("the replies did not arrive")
            return
        }
    }

    @Test("A topic nobody answered says so, and does not keep offering to load nothing")
    func aTopicWithNoRepliesSaysSo() {
        let posts = ForumPosts()
        let ref = Self.ref()
        posts.keep([], for: ForumPosts.Key(ref, .replies), startedAt: 0)
        #expect(posts.standing(of: ref) == .none)
    }

    @Test("The two parts of one thread are two entries and do not stand in for each other")
    func openingAndRepliesAreSeparate() async throws {
        let posts = ForumPosts(http: FixtureHTTP([Self.threadAddress(): .text(#"""
        <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
        <div class="message">一句话。</div></div>
        <div class="plc" id="pid9102"><ul class="authi"><li>2<sup>#</sup></li>
        <li><a href="home.php?mod=space&uid=9">greenpine</a></li></ul>
        <div class="message">回一句。</div></div>
        """#)]))
        let ref = Self.ref()

        await posts.fetch(ref)
        // The opening post is in hand and the replies are still unasked: D30 and D31 are two
        // decisions, and one request does not quietly answer the other.
        guard case .words = posts.reading(ref) else {
            Issue.record("the opening post did not arrive")
            return
        }
        #expect(posts.standing(of: ref) == .unasked)
        #expect(ForumPosts.Part.allCases.count == 2)
    }

    // MARK: - The boards under boards — D29

    /// D29's other half: the set-in says "under that one" to a reader who can see the list, and
    /// this is what says it to a reader who cannot. It is not decoration — a child is *not*
    /// included in its parent, so whether a row is one is what decides whether a pick is sensible.
    @Test("A board under a board says whose it is, by name and never by number")
    func aSubBoardNamesItsParentOutLoud() async throws {
        // `install-d.example`'s wide `list` index: one board to a `<tr>`, its own name in an
        // `<h2>`, and its children written as bare anchors in the same cell. That shape is the
        // only reason there is a child here to be named at all.
        let http = FixtureHTTP([
            "https://install-d.example/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <h2><a href="https://install-d.example/forum.php?gid=296">官方区</a></h2>
            <div id="category_296" class="bm_c">
            <table class="fl_tb"><tr>
            <td class="fl_icn"><a href="https://install-d.example/forum-297-1.html"><img src="/icon.png" alt="" /></a></td>
            <td>
            <h2><a href="https://install-d.example/forum-297-1.html">官方软件区</a></h2>
            <p class="xg2">官方软件讨论区</p>
            <p>子版块: <a href="https://install-d.example/forum-300-1.html">输入法工具</a></p>
            </td>
            <td class="fl_i"><span class="xi2">370</span><span class="xg1"> / 6414</span></td>
            <td class="fl_by"><div><cite>2026-3-15 13:25</cite></div></td>
            </tr></table>
            </div></body></html>
            """#),
        ])
        let categories = try await DiscuzClient(http: http, host: "install-d.example").boards()
        let boards = categories.flatMap(\.boards)
        let sheet = BoardPickerList(
            offer: JoinOffer(host: "install-d.example", kind: .discuz, categories: categories),
            picked: .constant([])
        )

        let child = try #require(boards.first { $0.name == "输入法工具" })
        #expect(child.depth == 1)
        #expect(sheet.spoken(child) == "输入法工具, under 官方软件区")
        // A board at the top says its name and nothing more: there is nothing to say.
        let top = try #require(boards.first { $0.fid == 297 })
        #expect(sheet.spoken(top) == "官方软件区")
    }

    /// **A tick on a child means the child, and a tick on a parent means the parent.** The whole
    /// argument for listing sub-boards separately is that a parent's `forumdisplay` does not carry
    /// its children's threads, so a checkbox that quietly meant nine boards would be a lie about
    /// what the reader subscribed to. Pinned where it becomes true for the reader: one pick, one
    /// subscription, one tab, reading that board's own number.
    @Test("Picking a board under a board subscribes to that board and to nothing else")
    func aSubBoardIsItsOwnPick() async throws {
        let http = FixtureHTTP([
            // Enough for the detector to name it a Discuz!.
            "/": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
            """#),
            // The index, with 300 written as a bare anchor inside 297's own cell.
            "https://install-d.example/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <h2><a href="https://install-d.example/forum.php?gid=296">官方区</a></h2>
            <div id="category_296" class="bm_c">
            <table class="fl_tb"><tr>
            <td>
            <h2><a href="https://install-d.example/forum-297-1.html">官方软件区</a></h2>
            <p>子版块: <a href="https://install-d.example/forum-300-1.html">输入法工具</a></p>
            </td>
            <td class="fl_i"><span class="xi2">370</span><span class="xg1"> / 6414</span></td>
            </tr></table>
            </div></body></html>
            """#),
            // 300's own listing — proof it answers for itself, which is the whole argument for
            // making it a separate pick.
            "https://install-d.example/forum.php?mod=forumdisplay&fid=300": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=300">输入法工具</a></h1>
            <table id="threadlisttableid">
            <tbody id="normalthread_51180"><tr>
            <th class="common"><a href="forum.php?mod=viewthread&tid=51180" class="s xst">候选框不见了</a></th>
            <td class="by"><cite><a href="home.php?mod=space&uid=21">mudbank</a></cite><em>2026-3-15 13:25</em></td>
            <td class="num"><a href="forum.php?mod=viewthread&tid=51180" class="xi2">3</a><em>90</em></td>
            </tr></tbody>
            </table></body></html>
            """#),
        ])
        let session = ShellSession(http: http, store: ItemStore())
        session.hostname = "install-d.example"
        await session.add()
        await session.confirm()

        let offer = try #require(session.choosing?.offer)
        let child = try #require(offer.boards.first { $0.fid == 300 })
        #expect(child.parent == 297)
        await session.subscribe([child])

        // One source, one board, and it is the child's own number — not its parent's.
        #expect(session.sources.map(\.host) == ["install-d.example"])
        #expect(session.sources.first?.boards.map(\.fid) == [300])
        #expect(session.queries.map(\.id) == ["all"])
        // And exactly one board was read: a tick on a child is one board's worth of traffic.
        let listings = await http.requested.filter { $0.query?.contains("forumdisplay") == true }
        #expect(listings.count == 1)
    }

    // MARK: - The row is still one height

    #if os(macOS)
    /// A row drawn at a fixed width, measured the way `EmojiEverywhereTests` measures it — the
    /// same harness, so the two figures are comparable.
    private static func height(_ item: DummyItem, posts: ForumPosts) -> CGFloat {
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: posts,
                               marks: .constant(DummyMarks()), onToast: { _ in })
            .frame(width: 720)
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// **The assertion this whole unit stands on.**
    ///
    /// A fetched post fills a band that is already there and already line-limited, and the row
    /// has to be exactly as tall with it as without — or the timeline reflows under the thumb
    /// that is scrolling it, on the one gesture that makes the fetch happen. Four states are
    /// measured because there are four things a row can be showing: the plates while it is
    /// coming, the words when they land, the lock when the forum withheld them, and the reason
    /// when it could not be read. A fifth, `silent`, is measured beside them because a post with
    /// no words in it is the state most likely to collapse a band by accident.
    ///
    /// One number is asserted rather than *the* number, for the reason the sibling test gives:
    /// the ink a system font reports is a fact about the machine, and pinning 204 would fail on
    /// another one for a reason that has nothing to do with this row. Measured here on
    /// 2026-09-16 it is **204.0 in all five states**, which is the same figure
    /// `everyRowIsOneHeight` has measured all branch — so a forum row is not a shape of its own,
    /// which is what the last assertion says in code.
    @Test("A row is one height whether or not its first post has arrived")
    func theRowDoesNotMoveWhenThePostLands() {
        let item = Self.item(id: "discuz:\(Self.host):\(Self.tid)",
                             title: "工具箱一键下载安装", kind: .discuz)
        let ref = try! #require(ForumThreadRef(item))
        let key = ForumPosts.Key(ref, .opening)
        let long = String(repeating: "写了很长的一段话，长到一行放不下。", count: 40)

        let coming = ForumPosts()

        let words = ForumPosts()
        words.keep([Self.post(body: long)], for: key, startedAt: 0)

        let withheld = ForumPosts()
        withheld.keep([Self.post(withheld: true)], for: key, startedAt: 0)

        let silent = ForumPosts()
        silent.keep([Self.post(body: "")], for: key, startedAt: 0)

        let absent = ForumPosts()
        absent.note(.refused, for: key)

        let heights = [coming, words, withheld, silent, absent].map { Self.height(item, posts: $0) }
        #expect(Set(heights).count == 1, "one height per state, got \(heights)")
        // And it is the height of every other row in the list, not a shape of its own.
        #expect(Set(heights) == Set([Self.height(Self.item(), posts: ForumPosts())]))
    }
    #endif

    // MARK: - Making items

    private static func row(_ item: DummyItem) -> DummyItemRow {
        DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                     marks: .constant(DummyMarks()), onToast: { _ in })
    }

    /// An item built the way the product builds one — through a `Note` — so that the kind, the
    /// shape and the id are the real ones rather than a shape a test chose for itself. This
    /// branch's first convention: a test must not be free to describe a smaller world than the
    /// code.
    private static func item(
        id: String = "1",
        title: String? = nil,
        body: String = "",
        kind: ProtocolKind = .mastodon
    ) -> DummyItem {
        DummyItem(Note(
            id: id,
            source: Source(host: host, kind: kind),
            author: "tinbox",
            handle: "@tinbox@\(host)",
            body: body,
            title: title,
            postedAt: .distantPast,
            origins: [.publicTimeline]
        ))
    }
}

/// A transport that answers one address and holds the answer until the test lets it go.
///
/// The only way to put a fetch reliably *in the air* while something else happens to the cache —
/// which is what the Clear-during-a-fetch case needs, and that case is a bug this project has
/// shipped twice. Sleeping instead would make the test a race that passes on a quiet machine and
/// fails under load, which is the one kind of test this branch has been burned by.
actor GateHTTP: HTTPClient {
    private let body: Data
    private var requested = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var asked: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    init(_ body: Data) {
        self.body = body
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requested += 1
        for continuation in asked { continuation.resume() }
        asked = []
        if !opened {
            await withCheckedContinuation { waiting.append($0) }
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (body, response)
    }

    /// Returns once the transport has actually been reached, so a test never guesses.
    func waitForRequest() async {
        guard requested == 0 else { return }
        await withCheckedContinuation { asked.append($0) }
    }

    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
