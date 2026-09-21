import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

#if os(macOS)
import AppKit
import SwiftUI
#endif

/// Unit F7: five things the reader asked for after using the forum for real.
///
/// > the load more thread should give the animation for loading … no shortcut for load more … the
/// > main thread does not load well … the user's avatar does not loaded … give a interactive
/// > button to open the native browser of the original link
///
/// Two of the five were diagnosed before the unit started and both held. "The main thread does not
/// load well" is the opening post being cut to three lines *in the pane the reader opened in order
/// to read it* — `DummyThreadPane` draws the root through `DummyItemRow`, and a row caps its words
/// at `bodyLines`, while the replies below it are held to no height at all. "The avatar does not
/// load" is a Discuz! thread *table* carrying none, where the thread *page* carries one in six
/// different spellings; what `DiscuzClient` reads off those six is pinned in Core's own suite, and
/// what this one asks is who puts it on the row.
@MainActor
@Suite("Reading a thread properly")
struct ThreadReadingTests {
    private static let host = "install-c.example"
    private static let tid = 70241

    init() {
        L10n.language = .english
    }

    // MARK: - Addresses and values

    private static func threadAddress(_ host: String = host, _ tid: Int = tid) -> String {
        "https://\(host)/forum.php?mod=viewthread&tid=\(tid)&mobile=2"
    }

    private static func ref(_ tid: Int = tid, host: String = host) -> ForumThreadRef {
        ForumThreadRef(host: host, tid: tid)
    }

    /// A row's item, built through a `Note` the way the product builds one.
    private static func item(
        id: String = "discuz:\(host):\(tid)",
        title: String? = "工具箱一键下载安装",
        kind: ProtocolKind = .discuz,
        url: URL? = nil
    ) -> DummyItem {
        DummyItem(Note(
            id: id,
            source: Source(host: host, kind: kind),
            author: "tinbox",
            handle: "@tinbox@\(host)",
            body: "",
            title: title,
            postedAt: .distantPast,
            categories: [.public],
            url: url
        ))
    }

    private static func post(
        pid: Int = 1,
        body: String = "",
        quoted: [DiscuzQuotation] = [],
        avatar: URL? = nil
    ) -> DiscuzPost {
        DiscuzPost(
            pid: pid, tid: tid, floor: 1, author: "tinbox",
            handle: "@tinbox@\(host)", body: body, quoted: quoted, avatarURL: avatar
        )
    }

    private static func row(_ item: DummyItem, posts: ForumPosts, inFull: Bool = false) -> DummyItemRow {
        DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: posts,
                     marks: .constant(DummyMarks()), inFull: inFull, onToast: { _ in })
    }

    /// The longest thing a forum can hand this app: a post nobody would read in three lines.
    private static let longPost = String(
        repeating: "写了很长的一段话，长到一行放不下，也放不进三行。", count: 40
    )

    // MARK: - "The main thread does not load well"

    /// **The diagnosis, as a fact about the code rather than about a screenshot.**
    ///
    /// A forum row's words get `4 - 1` lines — four, less one for the title the thread carries —
    /// so the post the reader opened the thread *in order to read* was cut to three. In the pane
    /// it gets none, and the arithmetic underneath is unchanged, which is why the two are separate
    /// properties: `bodyLines` is how much room the slot leaves, `wordLines` is whether the slot's
    /// rule applies at all.
    @Test("The words are capped in a list and uncapped in the pane")
    func theOpeningPostIsNotCutInThePane() {
        let posts = ForumPosts()
        let listed = Self.row(Self.item(), posts: posts)
        #expect(listed.bodyLines == 3, "a titled forum row leaves three lines for the words")
        #expect(listed.wordLines == 3)

        let opened = Self.row(Self.item(), posts: posts, inFull: true)
        // The arithmetic is untouched. What changed is whether anything applies it.
        #expect(opened.bodyLines == 3)
        #expect(opened.wordLines == nil, "the post the reader opened is not line-limited")

        // A row with no title keeps the fourth line, in both places — the fitting is about what
        // else is in the band, and `inFull` is about which band this is.
        let untitled = Self.row(Self.item(title: nil), posts: posts)
        #expect(untitled.bodyLines == 4)
        #expect(Self.row(Self.item(title: nil), posts: posts, inFull: true).wordLines == nil)
    }

    #if os(macOS)
    private static func height(_ item: DummyItem, posts: ForumPosts, inFull: Bool = false) -> CGFloat {
        let view = row(item, posts: posts, inFull: inFull).frame(width: 720)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// **Both halves at once, measured**: the list did not move, and the pane did.
    ///
    /// The timeline's one height is not what this unit is about and must come through it
    /// untouched — a long post and no post at all still measure the same row, and that row still
    /// measures the same as any other row in the list. The pane is the opposite claim: the same
    /// item, the same post, drawn `inFull`, has to be *taller*, and taller **in proportion to the
    /// post** rather than by some new constant — which is what the third figure is for. A fix that
    /// merely traded three lines for six would pass the first assertion and fail that one.
    ///
    /// Measured on this machine on 2026-09-16: **204.0** listed with no post and 204.0 listed with
    /// a long one, 204.0 for an ordinary row, 204.0 for the pane's *short* post and **480.0** for
    /// its long one. The fourth of those is worth saying out loud — a pane row is not
    /// unconditionally taller, it is taller exactly when the post needs the room, and a short post
    /// still measures the same row as everything else. Only the relations are asserted: the ink a
    /// system font reports is a fact about the machine, which is the reason
    /// `theRowDoesNotMoveWhenThePostLands` gives for pinning none of its own.
    @Test("The list keeps its one height and the pane does not have one")
    func thePaneGrowsAndTheListDoesNot() {
        let item = Self.item()
        let key = ForumPosts.Key(Self.ref(), .opening)

        let empty = ForumPosts()
        let long = ForumPosts()
        long.keep([Self.post(body: Self.longPost)], for: key, startedAt: 0)
        let short = ForumPosts()
        short.keep([Self.post(body: "好")], for: key, startedAt: 0)

        // The list, unchanged: the post landing moves nothing, and a forum row is not a shape of
        // its own.
        let listedEmpty = Self.height(item, posts: empty)
        let listedLong = Self.height(item, posts: long)
        #expect(listedEmpty == listedLong, "the timeline row moved: \(listedEmpty) vs \(listedLong)")
        #expect(listedLong == Self.height(Self.item(id: "1", title: nil, kind: .mastodon),
                                          posts: ForumPosts()))

        // The pane: the whole post, so a long one is taller than a short one and taller than the
        // three lines the list allows.
        let openedLong = Self.height(item, posts: long, inFull: true)
        let openedShort = Self.height(item, posts: short, inFull: true)
        #expect(openedLong > listedLong, "the pane still truncates: \(openedLong) vs \(listedLong)")
        #expect(openedLong > openedShort, "the pane is a bigger box, not an unbounded one")
        // The short post's pane row is the listed row's height, not a new constant.
        #expect(openedShort == listedLong)
    }
    #endif

    // MARK: - What the opening post quoted — #104

    /// **The gap #94 left, stated as a fact about the cache rather than about a screenshot.**
    ///
    /// Core has kept a quotation out of the words and kept it rather than dropping it since #94,
    /// and `ForumReplyRow` has drawn every reply's since F6. Nothing read it back for the *first*
    /// post of a topic, so a thread that opened by answering another drew the answer and never
    /// what it answered — while the reply under it, quoting the same person, drew both.
    ///
    /// The nesting is asserted here as well as in Core because it is what the pane draws: one
    /// level per rule, which is the whole of what #94 settled about how a quotation looks.
    @Test("A topic's first post keeps what it quoted, and its own words stay its own")
    func theOpeningPostKeepsWhatItQuoted() async throws {
        // One page, two posts, each quoting: the opening post quotes an argument that already
        // has a quotation inside it, and the reply below quotes the opening post. Both halves
        // come off the one page D30 already fetches.
        let http = FixtureHTTP([
            Self.threadAddress(): .text(#"""
            <div class="plc" id="pid9101">
              <ul class="authi"><li>1<sup>#</sup></li>
              <li><a href="home.php?mod=space&amp;uid=8">tinbox</a></li></ul>
              <div class="message">
                <div class="quote"><blockquote>沙洲电子 发表于 2017-12-15 17:49<br />
                  <div class="quote"><blockquote>hexi 发表于 2017-12-15 17:00<br />
                  论坛运维都要花钱</blockquote></div>
                  这个确实该支持一下</blockquote></div>
                那就每人出十块
              </div>
            </div>
            <div class="plc" id="pid9102">
              <ul class="authi"><li>2<sup>#</sup></li>
              <li><a href="home.php?mod=space&amp;uid=9">greenpine</a></li></ul>
              <div class="message">
                <div class="quote"><blockquote>tinbox 发表于 2017-12-15 18:00<br />
                那就每人出十块</blockquote></div>
                同意楼上
              </div>
            </div>
            """#),
        ])
        let posts = ForumPosts(http: http)
        let ref = Self.ref()

        // Nothing before the page lands, which is the same answer as "quoted nothing" — and is
        // meant to be: there is nothing to draw either way.
        #expect(posts.quoted(of: ref).isEmpty)
        await posts.fetch(ref)

        let outer = try #require(posts.quoted(of: ref).first)
        #expect(posts.quoted(of: ref).count == 1, "one quotation at the top, however deep it goes")
        #expect(outer.words.hasPrefix("沙洲电子 发表于 2017-12-15 17:49"))
        #expect(outer.words.contains("这个确实该支持一下"))
        // Nested where the page nested it, each level keeping its own words.
        let inner = try #require(outer.quoting.first)
        #expect(inner.words.contains("论坛运维都要花钱"))
        #expect(!outer.words.contains("论坛运维都要花钱"))
        #expect(inner.quoting.isEmpty)

        // Told apart from the author's own words: the band's words are what this person wrote,
        // and nothing of what the other two did.
        #expect(posts.reading(ref) == .words("那就每人出十块"))

        // And the reply below it quotes too, off the same page — the two halves this issue is
        // about being the same shape at last.
        await posts.fetchReplies(ref)
        guard case .loaded(let replies) = posts.standing(of: ref) else {
            Issue.record("the replies did not arrive: \(posts.standing(of: ref))")
            return
        }
        let reply = try #require(replies.first)
        #expect(try #require(reply.quoted.first).words.contains("那就每人出十块"))
        #expect(reply.body == "同意楼上")
    }

    /// **The rule, and it is a sentence about this app rather than about a layout**: a timeline
    /// row is one height whatever the post it stands for quoted, and the pane is what the reader
    /// opened in order to read.
    ///
    /// The band takes the row's own `inFull` rather than reading it back out of `lines == nil`,
    /// so the fitting and the decision to apply it stay two things — the split `wordLines`
    /// already makes, asserted from both ends here.
    @Test("The quotation is the pane's, and a row in a list draws none")
    func onlyTheOpenedTopicDrawsTheQuotation() {
        let quoted = [DiscuzQuotation(words: "甲 说过", quoting: [DiscuzQuotation(words: "乙 说过")])]
        #expect(ForumPostBand.quotations(quoted, inFull: true) == quoted)
        #expect(ForumPostBand.quotations(quoted, inFull: false).isEmpty)
        // A post that quoted nothing draws nothing in either place, which is today's row exactly.
        #expect(ForumPostBand.quotations([], inFull: true).isEmpty)
        #expect(ForumPostBand.quotations([], inFull: false).isEmpty)

        // The one flag the band is handed is the one the row keeps, so the two cannot disagree:
        // the quotation is drawn in exactly the place the words lose their line limit.
        let posts = ForumPosts()
        #expect(Self.row(Self.item(), posts: posts, inFull: true).wordLines == nil)
        #expect(Self.row(Self.item(), posts: posts).wordLines != nil)

        // Introduced with the sentence a reply's quotation is introduced with, because it is the
        // same view: one string in every language, not a second one for the opening post.
        for language in [DummyLanguage.english, .taiwanese] {
            let said = L10n.t("thread.reply.quoted", language: language)
            #expect(said != "thread.reply.quoted", "the quotation label is missing in \(language)")
            #expect(said.contains("%@"), "\(language) has nowhere to put the quoted words")
        }
    }

    #if os(macOS)
    /// **Both halves at once, measured**, the way `thePaneGrowsAndTheListDoesNot` measures the
    /// words: the quotation is on screen in the pane, and the timeline row did not move.
    ///
    /// The second assertion is the acceptance line this unit is most able to break — the band is
    /// shared between the two surfaces, and a quotation drawn unconditionally would land on every
    /// row of a list at once. Only relations are asserted, for that test's reason: the ink a
    /// system font reports is a fact about the machine.
    @Test("A quoted first post grows the pane and leaves the timeline row where it was")
    func theQuotationMovesThePaneAndNotTheRow() {
        let item = Self.item()
        let key = ForumPosts.Key(Self.ref(), .opening)
        let words = "那就每人出十块"

        let plain = ForumPosts()
        plain.keep([Self.post(body: words)], for: key, startedAt: 0)
        let quoting = ForumPosts()
        quoting.keep(
            [Self.post(body: words, quoted: [DiscuzQuotation(words: String(
                repeating: "沙洲电子 发表于 2017-12-15 17:49，这个确实该支持一下。", count: 40
            ))])],
            for: key, startedAt: 0
        )

        // The list, unmoved: one height, whatever the post it stands for quoted. Two rules hold
        // that and both are wanted — `mainBox` pins the band at `Box.thumb` and clips it, and
        // `quotations(_:inFull:)` means there is nothing drawn there to clip.
        let listedPlain = Self.height(item, posts: plain)
        let listedQuoting = Self.height(item, posts: quoting)
        #expect(listedPlain == listedQuoting,
                "the timeline row moved: \(listedPlain) vs \(listedQuoting)")

        // The pane: the quotation is drawn, so the row is taller by what it takes.
        let openedPlain = Self.height(item, posts: plain, inFull: true)
        let openedQuoting = Self.height(item, posts: quoting, inFull: true)
        #expect(openedQuoting > openedPlain,
                "the quotation was not drawn: \(openedQuoting) vs \(openedPlain)")

        // And a first post that quoted nothing is the row it always was — the pane's short post
        // still measures the listed row, which is what it measured before any of this.
        #expect(openedPlain == listedPlain)
    }
    #endif

    // MARK: - "The user's avatar does not loaded"

    /// **The row's avatar arrives with its opening post, and costs no request of its own.**
    ///
    /// A Discuz! thread table carries no avatar, so `DummyItem.avatarURL` is `nil` for every forum
    /// row this app draws — which is the reader's complaint exactly. The thread page carries one,
    /// and D30 already fetches that page when the row is scrolled to, so the picture rides along
    /// in an answer the row was waiting for anyway. The last assertion is the whole economic case:
    /// one request, not two.
    @Test("A forum row's avatar comes off the post D30 already fetched")
    func theAvatarArrivesWithTheOpeningPost() async throws {
        // The touch template's avatar box, which is where the picture actually is: a
        // `<div class="avatar">` whose `<img>` defers the address to `data-src`, written
        // relative to the forum. Both halves matter to the address asserted below.
        let http = FixtureHTTP([
            Self.threadAddress(): .text(#"""
            <div class="plc" id="pid9101">
            <div class="avatar"><img data-src="./data/avatar/000/11/22/33_avatar_small.jpg" class="_avt"></div>
            <ul class="authi"><li>1<sup>#</sup></li>
            <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
            <div class="message">工具箱一键下载安装。</div>
            </div>
            """#),
        ])
        let posts = ForumPosts(http: http)
        let item = Self.item()
        #expect(item.avatarURL == nil, "the thread table never carried one")
        #expect(Self.row(item, posts: posts).avatarURL == nil, "nothing before the fetch")

        await posts.fetch(Self.ref())
        let drawn = try #require(Self.row(item, posts: posts).avatarURL)
        #expect(drawn.absoluteString
            == "https://install-c.example/data/avatar/000/11/22/33_avatar_small.jpg")
        #expect(await http.requested.count == 1, "the picture cost no request of its own")
    }

    /// The post's own address wins where there is one, and a row with no thread behind it never
    /// asks the forum cache at all.
    @Test("A post that brought its own picture keeps it")
    func thePostsOwnAvatarWins() {
        let sent = URL(string: "https://first.example/a.png")!
        let posts = ForumPosts()
        posts.keep(
            [Self.post(avatar: URL(string: "https://install-c.example/data/avatar/1.jpg")!)],
            for: ForumPosts.Key(Self.ref(), .opening), startedAt: 0
        )
        var note = Self.item()
        #expect(Self.row(note, posts: posts).avatarURL?.host() == "install-c.example")

        // A Mastodon row has an avatar of its own and no thread to ask about.
        note = DummyItem(Note(
            id: "109252111", source: Source(host: Self.host, kind: .mastodon),
            author: "ada", handle: "@ada@\(Self.host)", body: "hi",
            postedAt: .distantPast, categories: [.public], avatarURL: sent
        ))
        #expect(Self.row(note, posts: posts).thread == nil)
        #expect(Self.row(note, posts: posts).avatarURL == sent)
    }

    // MARK: - "The load more thread should give the animation for loading"

    /// **A reader who asked for less movement gets the still and no second frame.**
    ///
    /// The same claim, in the same shape, as `EmojiText.clock(for:reduceMotion:)`: `nil` is not a
    /// slow animation, it is the branch of `body` that has no `TimelineView` in it at all, so
    /// there is nothing left that could tick.
    @Test("Reduce motion stops the clock, and the still frame is a real frame")
    func reduceMotionStopsTheWaitingAnimation() {
        #expect(ForumWaiting.clock(reduceMotion: true) == nil)
        #expect(ForumWaiting.clock(reduceMotion: false) == ForumWaiting.tick)
        // Fast enough to read as motion, and not faster than this app's own ceiling for how often
        // anything may ask for a redraw.
        #expect(try! #require(ForumWaiting.clock(reduceMotion: false)) >= EmojiClock.fastestTick)

        // The still frame the reduce-motion branch draws: the first plate lit, the others banked,
        // so it still reads as three plates rather than as one grey bar.
        let still = (0..<ForumWaiting.plates).map { ForumWaiting.glow($0, at: 0) }
        #expect(still[0] == ForumWaiting.lit)
        #expect(still.dropFirst().allSatisfy { $0 < ForumWaiting.lit })
        // Two brightnesses, not three: a third of a pass either side of the lit plate is the same
        // point of the cosine, so plates 1 and 2 are equal and differ only by the ~2.8e-16 that a
        // `Set(still).count == 3` was quietly passing on.
        #expect(abs(still[1] - still[2]) < 1e-9,
                "the still frame is one lit plate and two equally banked ones")
    }

    /// Bounded from **both** sides, which is this branch's first convention — a ceiling asserted
    /// with no floor is one of the three defects it was written down for.
    @Test("Every plate is between banked and lit, at every instant, and the run repeats")
    func theWaitingRunIsBoundedAndPeriodic() {
        for step in 0..<400 {
            let instant = Double(step) * 0.017
            for plate in 0..<ForumWaiting.plates {
                let glow = ForumWaiting.glow(plate, at: instant)
                #expect(glow >= ForumWaiting.banked - 1e-9, "\(plate) at \(instant) went dark")
                #expect(glow <= ForumWaiting.lit + 1e-9, "\(plate) at \(instant) overran")
                #expect(glow.isFinite)
            }
        }
        // It is a loop, not a ramp: one period on and every plate is where it started.
        for plate in 0..<ForumWaiting.plates {
            let start = ForumWaiting.glow(plate, at: 3.5)
            let round = ForumWaiting.glow(plate, at: 3.5 + ForumWaiting.period)
            #expect(abs(start - round) < 1e-9)
        }
        // And it does move — a clock that drew one frame forever would pass everything above.
        let first = (0..<ForumWaiting.plates).map { ForumWaiting.glow($0, at: 0) }
        let later = (0..<ForumWaiting.plates).map { ForumWaiting.glow($0, at: ForumWaiting.period / 3) }
        #expect(first != later)
    }

    // MARK: - "No shortcut for load more"

    /// **Why `s` was free to take a second job**, which is the fact the reader found before this
    /// unit did.
    ///
    /// Neither forum parser ever sets `sensitive` or `spoiler` — both default to `nil` on a `Note`
    /// — so `DummyItem.covered` is false for every forum row this app can draw, and `s` did
    /// nothing at all on a forum. This is the assertion that keeps that true: the day a Discuz!
    /// post grows a cover, `s` on it goes back to meaning the cover, the replies lose their key on
    /// that row, and somebody has to decide what to do about it *here* rather than find out from
    /// a reader.
    @Test("A forum row has no cover, which is why s had nothing to do on one")
    func aForumRowHasNoCover() async throws {
        // Two threads, because "every one of them" is the shape of the assertion: a cover that
        // appeared on one row and not another would pass a one-row page.
        let http = FixtureHTTP([
            "https://\(Self.host)/forum.php?mod=forumdisplay&fid=34&filter=author&orderby=dateline": .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=34">工具箱讨论区</a></h1>
            <table id="threadlisttableid">
            <tbody id="stickthread_40001"><tr>
            <th class="common"><a href="forum.php?mod=viewthread&tid=40001" class="s xst">版规，先读这个</a></th>
            <td class="by"><cite><a href="home.php?mod=space&uid=1">boardkeeper</a></cite><em>2024-3-1 09:00</em></td>
            <td class="num"><a href="forum.php?mod=viewthread&tid=40001" class="xi2">2</a><em>80</em></td>
            </tr></tbody>
            <tbody id="normalthread_40125"><tr>
            <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">工具箱一键下载安装</a></th>
            <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
            <td class="num"><a href="forum.php?mod=viewthread&tid=40125" class="xi2">7</a><em>120</em></td>
            </tr></tbody>
            </table></body></html>
            """#),
        ])
        let notes = try await DiscuzClient(http: http, host: Self.host)
            .board(34, source: Source(host: Self.host, kind: .discuz))
        #expect(!notes.isEmpty)
        for note in notes {
            let item = DummyItem(note)
            #expect(item.sensitive == nil, "a Discuz! thread said something about being sensitive")
            #expect(item.spoiler == nil, "a Discuz! thread carried a cover line")
            #expect(!item.covered)
            // So on every one of them, `s` means the replies rather than the cover.
            #expect(DummyCommand.reveal(hasCover: item.covered, repliesWanted: true) == .replies)
        }
    }

    /// `s`, unchanged as a key, and every other key unchanged with it.
    @Test("s is still s, and no other key moved")
    func theKeyIsS() {
        #expect(DummyCommand.from("s") == .reveal)
        // A letter belongs to the draft while composing, and to a focused field always.
        #expect(DummyCommand.from("s", typing: true) == nil)
        #expect(DummyCommand.from("s", fieldFocused: true) == nil)
        // Nothing that already meant something changed meaning. `r` reloads (#29).
        #expect(DummyCommand.from("v") == .viewAttachment)
        #expect(DummyCommand.from("a") == .playAttachment)
        #expect(DummyCommand.from("m") == .nextAttachment)
        #expect(DummyCommand.from("\r") == .expandPost)
        #expect(DummyCommand.from("q") == .back)
        // `e` is the timeline editor's (#27, Decision 18).
        #expect(DummyCommand.from("e") == .editTimeline)
        #expect(DummyCommand.from("r") == .reload)
        for free in ["l", "o", "h"] {
            #expect(DummyCommand.from(Character(free)) == nil, "\(free) is no longer free")
        }
    }

    /// **The guide says what `s` does now.**
    ///
    /// A guide that still claimed one of the two meanings would be a screen telling the reader
    /// something true-looking and wrong, which is the failure this branch has shipped once. So the
    /// line names both jobs, in every language, and the assertion is on the words rather than on
    /// the key merely resolving.
    @Test("The guide names both of s's jobs, in every language")
    func theGuideSaysWhatSDoesNow() throws {
        let line = try #require(DummyShortcut.all.first { $0.commands == [.reveal] })
        #expect(line.keys == ["s"])
        #expect(line.group == .timeline)
        // One line for one key. `s` having two jobs must not become two lines claiming two keys.
        #expect(DummyShortcut.all.filter { $0.keys == ["s"] }.count == 1)

        for language in [DummyLanguage.english, .taiwanese] {
            let said = L10n.t("shortcut.reveal", language: language)
            #expect(said != "shortcut.reveal", "the guide line is missing in \(language)")
            // Both halves, in that language's own words for them.
            let cover = language == .english ? "cover" : "蓋"
            let rest = language == .english ? "topic" : "回覆"
            #expect(said.contains(cover), "\(language) stopped mentioning the cover: \(said)")
            #expect(said.contains(rest), "\(language) does not mention the replies: \(said)")
        }
        // And the old line is gone rather than left behind saying the old thing.
        #expect(L10n.t("shortcut.cover", language: .english) == "shortcut.cover")

        // The guide still names every command and no more — the harness this branch already has,
        // re-asked here because this unit is what last changed the list.
        #expect(Set(DummyShortcut.all.flatMap(\.commands)) == Set(DummyCommand.allCases))
        #expect(DummyShortcut.all.flatMap(\.commands).count == DummyCommand.allCases.count)
    }

    /// **The key and the button read one rule**, so a reader cannot find a mark the key will not
    /// press or press a key on a state that offers no mark.
    ///
    /// Written over every case rather than over the two that matter, because a sixth standing
    /// added later is exactly the thing that would otherwise slip through — the pane's own switch
    /// has no `default:` for the same reason.
    @Test("Pressing for the replies means something in exactly two states")
    func theKeyActsWhereTheButtonIsDrawn() {
        #expect(ForumRepliesStanding.unasked.wantsPressing)
        #expect(!ForumRepliesStanding.coming.wantsPressing)
        #expect(!ForumRepliesStanding.none.wantsPressing)
        #expect(!ForumRepliesStanding.loaded([Self.post()]).wantsPressing)
        // Asking again is only worth offering where asking again could answer differently, and
        // `asksAgain` is where that judgement already lives rather than a second copy of it.
        #expect(ForumRepliesStanding.absent(.unreachable).wantsPressing)
        #expect(!ForumRepliesStanding.absent(.refused).wantsPressing)
        #expect(!ForumRepliesStanding.absent(.unreadable).wantsPressing)
        #expect(!ForumRepliesStanding.absent(.crowded).wantsPressing)
        for absence in [ForumPosts.Absence.refused, .unreadable, .unreachable, .crowded] {
            #expect(ForumRepliesStanding.absent(absence).wantsPressing == absence.asksAgain)
        }
    }

    /// A press where there is nothing to load asks nobody for anything.
    ///
    /// The state machine rather than the key handler, because what the press must not do is put a
    /// request on the wire — and that is a fact about `fetchReplies`, which is reachable, rather
    /// than about `FediqoRootView.apply`, which needs a window.
    @Test("Pressing again while the replies are coming does not ask twice")
    func aSecondPressAsksNothing() async {
        let http = FixtureHTTP([
            Self.threadAddress(): .text(#"""
            <div class="plc" id="pid9101"><ul class="authi"><li>1<sup>#</sup></li>
            <li><a href="home.php?mod=space&uid=8">tinbox</a></li></ul>
            <div class="message">工具箱一键下载安装。</div></div>
            <div class="plc" id="pid9102"><ul class="authi"><li>2<sup>#</sup></li>
            <li><a href="home.php?mod=space&uid=9">greenpine</a></li></ul>
            <div class="message">学到了。</div></div>
            """#),
        ])
        let posts = ForumPosts(http: http)
        #expect(posts.standing(of: Self.ref()).wantsPressing)

        await posts.fetchReplies(Self.ref())
        let standing = posts.standing(of: Self.ref())
        #expect(!standing.wantsPressing, "the replies are here; there is nothing left to press")
        await posts.fetchReplies(Self.ref())
        #expect(await http.requested.count == 1, "a second press went to the wire")
    }

    // MARK: - "A button to open the native browser of the original link"

    /// **The address the button opens is carried, and it is admitted at the wire boundary.**
    ///
    /// A Discuz! thread's canonical address is *built* in Core out of a parsed host and an
    /// integer, which is why `asNote` says it is the one address in that file that did not come
    /// out of a stranger's markup. A Mastodon status's is *lifted*, and until this unit it was
    /// lifted through a bare `URL(string:)` — so `javascript:` survived into a `Note` at a field
    /// nothing happened to open. This unit opens it, so the rule applies to it: `Host.fetchableURL`
    /// in Core, and `Host.allowsFetch` again at the button, which is the same one function read
    /// twice rather than the rule written twice.
    @Test("A thread carries where it lives, and a hostile address is not carried at all")
    func theOriginalLinkIsCarriedAndChecked() {
        let built = URL(string: "https://\(Self.host)/forum.php?mod=viewthread&tid=\(Self.tid)")!
        #expect(Self.item(url: built).url == built)
        #expect(Host.allowsFetch(built))
        // Nothing where the source named nowhere — and the pane draws no button rather than a
        // dead one.
        #expect(Self.item(url: nil).url == nil)

        // The four `URL(string:)` builds happily out of a stranger's JSON. Each one is refused by
        // the one rule this package fetches under, which is the rule the button reads.
        for hostile in [
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "file:///etc/passwd",
            "http://\(Self.host)/forum.php?mod=viewthread&tid=1",
        ] {
            let built = URL(string: hostile)
            #expect(built != nil, "\(hostile) is exactly the kind URL(string:) does build")
            #expect(!Host.allowsFetch(built!), "\(hostile) would have opened")
        }
    }

    /// The pane names where the reader is being sent, in every language it ships.
    ///
    /// "Open in browser" says what will happen; it does not say where they will end up, and where
    /// they end up is the fact worth checking before following an outward link.
    @Test("The button names the host, and says that it leaves the app")
    func theButtonSaysWhereItGoes() {
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["thread.open", "thread.open.hint", "thread.open.leaves"] {
                #expect(L10n.t(key, language: language) != key, "\(key) missing in \(language)")
            }
            let label = String(format: L10n.t("thread.open", language: language), Self.host)
            #expect(label.contains(Self.host), "\(language) drops the host")
        }
    }
}
