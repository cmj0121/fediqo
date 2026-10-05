import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #290, as far as this unit draws it: a reblog is a row of its own, standing at the time of the
/// reblog and saying who reblogged; what it draws of a post is read from the post's own item, or
/// it says the post is no longer held; and whatever is pressed on it is done to the post.
@MainActor
@Suite("A reblog's row")
struct ReblogRowTests {
    private let host = "social.example"
    private let writing = MastodonOAuth.reading + " " + MastodonOAuth.writing
    private static let published = Date(timeIntervalSince1970: 1_700_000_000)
    private static let reblogged = published.addingTimeInterval(7 * 86400)

    private var source: Source { Source(host: host, kind: .mastodon) }

    private var post: Note {
        Note(
            id: "https://social.example/users/ada/statuses/9", source: source, author: "Ada",
            handle: "@ada@social.example", body: "hello about cats", postedAt: Self.published, categories: [],
            boosted: false, favourited: false, counts: Counts(replies: 1, reblogs: 2, favourites: 3), statusID: "9"
        ).readNow()
    }

    private var reblog: Note {
        Note(
            id: "https://social.example/users/bob/statuses/900/activity", source: source, author: "Bob",
            handle: "@bob@social.example", body: "", postedAt: Self.reblogged, categories: [.home],
            statusID: "900", gaps: [TimelineGap(.newerRemain, in: .home)], listed: [.home: "900"],
            refs: [Reference(kind: .reblogs, id: "https://social.example/users/ada/statuses/9", statusID: "9")]
        )
    }

    private static func status(favourited: Bool) -> String {
        """
        {"id":"9","uri":"https://social.example/users/ada/statuses/9",
         "created_at":"2023-11-14T22:13:20.000Z","content":"<p>hello about cats</p>",
         "visibility":"public","favourited":\(favourited),"reblogged":false,
         "account":{"username":"ada","acct":"ada@social.example","display_name":"Ada"}}
        """
    }

    private func shell(
        holding notes: [Note], routes: [String: ActServer.Outcome] = [:], signedIn: Bool = true
    ) async throws -> (ShellSession, ActServer) {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(
                host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret", scopes: writing
            ))
        }
        let server = ActServer(routes)
        let store = ItemStore()
        await store.add(source)
        await store.ingest(notes)
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        return (session, server)
    }

    // MARK: - The row

    @Test("The reblog's row is the reblog's — its id, its time, what it came through, where its timeline is not whole — and draws the post's words, author and counts from the post's own item")
    func drawnFromThePost() {
        let row = DummyItem(reblog, reblogging: post)
        #expect(row.id == reblog.key.rowID && row.noteID == reblog.id)
        #expect(row.postedAt == Self.reblogged, "it stands when it was reblogged")
        #expect(row.categories == [.home] && row.gaps == reblog.gaps)
        #expect(row.isReblog && !row.reblogUnheld && !row.arrivedAsReblog)
        #expect(row.boostedBy == "Bob")
        #expect(row.author == "Ada" && row.handle == "@ada@social.example" && row.body == "hello about cats")
        #expect(row.counts == DummyCounts(replies: 1, reblogs: 2, favourites: 3))
        #expect(row.favourited == false && row.boosted == false)
        #expect(row.statusID == nil, "the reblog's own id is on nothing a press can reach")
        #expect(row.reblogged.map(\.id) == [post.key.rowID] && row.reblogged.first?.statusID == "9")
        #expect(row.actCopies.map(\.id) == [post.key.rowID])
        #expect(DummyItemRow.reblogLine(row, language: .english) == "Reblogged by Bob")
        #expect(DummyItemRow.reblogLine(row, language: .taiwanese) == "由 Bob 轉發")
    }

    @Test("Where the post reblogged is no longer held, the row says so: who reblogged and when, nothing of a post, and nothing to press")
    func unheld() {
        for row in [DummyItem(reblog, reblogging: nil), DummyItem(reblog)] {
            #expect(row.isReblog && row.reblogUnheld)
            #expect(row.author == "Bob" && row.body.isEmpty && row.postedAt == Self.reblogged)
            #expect(row.statusID == nil && row.reblogged.isEmpty && row.actCopies.isEmpty)
            #expect(DummyItemRow.reblogLine(row, language: .english) == nil, "the row is the reblog alone: it has no first line")
            #expect(DummyItemRow.reblogNotice(row, language: .english) == "Reblogged a post this device no longer holds.")
            #expect(DummyItemRow.reblogNotice(row, language: .taiwanese) == "轉發了一則這台裝置已不再留著的貼文。")
        }
    }

    @Test("A reblog is shown only a post of its own source, and never another reblog")
    func whatMayBeShown() {
        let elsewhere = Note(
            id: post.id, source: Source(host: "other.example", kind: .mastodon), author: "Eve", handle: "@eve",
            body: "not it", postedAt: Self.published, categories: []
        )
        #expect(DummyItem(reblog, reblogging: elsewhere).reblogUnheld)
        #expect(DummyItem(reblog, reblogging: reblog).reblogUnheld)
        // And a post is itself whatever it is handed.
        #expect(DummyItem(post, reblogging: reblog).id == post.key.rowID)
        #expect(!DummyItem(post, reblogging: reblog).isReblog)
    }

    @Test("A post held from before, which arrived as a reblog, says it arrived as one — in words that are not the reblog row's — and is the post, at its own time, with its own id")
    func heldFromBefore() {
        let legacy = Note(
            id: post.id, source: source, author: "Ada", handle: "@ada@social.example", body: "hello",
            postedAt: Self.published, categories: [.home], boostedBy: "Bob", boosterHandle: "@bob@social.example",
            statusID: "9"
        )
        let row = DummyItem(legacy)
        #expect(row.arrivedAsReblog && !row.isReblog && row.statusID == "9" && row.postedAt == Self.published)
        #expect(DummyItemRow.reblogLine(row, language: .english) == "Arrived as a reblog by Bob")
        #expect(DummyItemRow.reblogLine(row, language: .taiwanese) == "因 Bob 的轉發而到來")
        #expect(DummyItemRow.reblogLine(DummyItem(post)) == nil)
    }

    @Test("The three sentences are in all three languages")
    func strings() {
        for key in ["item.boostedBy", "item.arrivedAsReblogBy", "item.reblog.unheld"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    // MARK: - In a timeline

    @Test("In All the reblog stands at the time of the reblog and the post at its publish time, both rows; a timeline made of Home shows the reblog, which shows the post")
    func bothRows() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        let all = session.timelineItems(latest: nil)
        #expect(all.map(\.id) == [reblog.key.rowID, post.key.rowID])
        #expect(all.map(\.postedAt) == [Self.reblogged, Self.published])
        #expect(all[0].isReblog && all[0].body == "hello about cats" && all[0].boostedBy == "Bob")
        #expect(!all[1].isReblog && all[1].boostedBy == nil)

        let home = TimelineDefinition(name: "Home", rules: [Rule.category(.home, in: .every, sources: session.sources)].compactMap { $0 })
        session.written = [home]
        session.timelineID = .written(home.id)
        let drawn = session.timelineItems(latest: nil)
        #expect(drawn.map(\.id) == [reblog.key.rowID], "the post came through no category")
        #expect(drawn[0].body == "hello about cats", "and is still what the reblog shows")
    }

    @Test("A hide on the post's words takes the reblog with it; an include on them brings both; a rule on who reblogged brings the reblog alone")
    func throughWrittenRules() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        func drawn(_ rule: Rule?) -> [String] {
            let timeline = TimelineDefinition(name: "T", rules: [rule].compactMap { $0 })
            session.written = [timeline]
            session.timelineID = .written(timeline.id)
            return session.timelineItems(latest: nil).map(\.id)
        }
        #expect(drawn(.keyword("cats", in: .every, effect: .exclude)).isEmpty)
        #expect(drawn(.keyword("cats", in: .every)) == [reblog.key.rowID, post.key.rowID])
        #expect(drawn(.author("bob@social.example", in: .every, sources: session.sources)) == [reblog.key.rowID])
        #expect(drawn(.author("ada@social.example", in: .every, sources: session.sources)) == [post.key.rowID])
        #expect(drawn(.author("ada@social.example", in: .every, effect: .exclude, sources: session.sources)).isEmpty, "hiding Ada hides Bob's reblog of her post too")
        #expect(drawn(.author("bob@social.example", in: .every, effect: .exclude, sources: session.sources)) == [post.key.rowID])
    }

    @Test("A timeline with a rule hiding reblogs shows the post once: the reblog's row goes and the post's own row stays where the rules let it through")
    func hidingReblogsShowsThePostOnce() async throws {
        var listed = post
        listed.categories = [.home]
        let (session, _) = try await shell(holding: [reblog, listed])
        func drawn(_ rules: [Rule?]) -> [String] {
            let timeline = TimelineDefinition(name: "T", rules: rules.compactMap { $0 })
            session.written = [timeline]
            session.timelineID = .written(timeline.id)
            return session.timelineItems(latest: nil).map(\.id)
        }
        let home = Rule.category(.home, in: .every, sources: session.sources)
        #expect(drawn([home]) == [reblog.key.rowID, post.key.rowID], "the premise: both rows pass Home")
        #expect(drawn([home, .field("reblog", is: .flag(true), in: .every, effect: .exclude)]) == [post.key.rowID])
        #expect(drawn([.field("reblog", is: .flag(true), in: .every)]) == [reblog.key.rowID])
        // As the editor names and phrases it, in each language — covered's shape.
        #expect(RuleText.fieldName("reblog", language: .english) == "Is a reblog")
        #expect(RuleText.fieldPhrase("reblog", .flag(true), language: .english) == "reblogs")
        #expect(RuleText.fieldPhrase("reblog", .flag(false), language: .english) == "everything that is not a reblog")
        #expect(RuleText.fieldName("reblog", language: .taiwanese) == "是轉發")
        #expect(RuleText.fieldPhrase("reblog", .flag(true), language: .taiwanese) == "轉發")
        #expect(RuleText.fieldPhrase("reblog", .flag(false), language: .taiwanese) == "不是轉發的")
        for key in ["rule.field.reblog", "rule.field.reblog.phrase.yes", "rule.field.reblog.phrase.no"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("A search finds the reblog by the post's words and by who reblogged")
    func searched() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        func found(_ pattern: String) async -> [String] {
            let search = ShellSearch()
            search.open(from: nil, over: session.notes)
            await search.indexed()
            search.text = pattern
            search.settle(pattern)
            return session.searched(search, latest: nil)?.map(\.id) ?? []
        }
        #expect(await found("cats") == [reblog.key.rowID, post.key.rowID])
        #expect(await found("bob") == [reblog.key.rowID])
    }

    @Test("Once the post is let go the reblog's row says it is no longer held, and offers nothing")
    func afterThePostGoes() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        await session.store.forget(post.key)
        await session.reloadFromStore()
        let row = try #require(session.timelineItems(latest: nil).first)
        #expect(session.timelineItems(latest: nil).count == 1 && row.reblogUnheld)
        #expect(session.acts(on: row) == .none)
        #expect(session.rowOpened(by: row.id) == nil, "and opens nothing")
    }

    // MARK: - What is pressed

    @Test("The reblog's row offers what the post offers, less taking it back; each mark reads the post, and the copy an act goes through is the post's row")
    func actsAreThePosts() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        let row = try #require(session.timelineItems(latest: nil).first)
        #expect(row.isReblog)
        let acts = session.acts(on: row)
        #expect(acts.offers(.favourite) && acts.offers(.boost) && acts.offers(.answer))
        #expect(session.actingCopy(of: row, for: .favourite)?.id == post.key.rowID)
        #expect(session.actingCopy(of: row, for: .favourite)?.statusID == "9")
        let acting = session.acting(on: row)
        #expect(acting.through[.favourite]?.id == post.key.rowID)
        #expect(ItemActs.mark(.favourite, on: row, acting: acting, language: .english).count == 3)
    }

    @Test("A reblog of the reader's own post does not offer taking the post back from the reblog's row; the post's own row does")
    func noTakingBackFromAReblog() async throws {
        let (session, server) = try await shell(
            holding: [reblog, post], routes: ["/api/v1/accounts/verify_credentials": .json(#"{"acct":"ada"}"#)]
        )
        await session.mastodon.verifyAll()
        let rows = session.timelineItems(latest: nil)
        #expect(session.acts(on: rows[1]).offers(.withdraw), "the premise: it is the reader's post")
        #expect(!session.acts(on: rows[0]).offers(.withdraw))
        #expect(!session.askToWithdraw(rows[0]))
        #expect(await server.methods.allSatisfy { $0 == "GET" }, "and nothing was sent")
    }

    @Test("Favouriting on the reblog's row is sent with the post's id, never the reblog's, and marks the post on both rows")
    func aFavouriteGoesToThePost() async throws {
        let (session, server) = try await shell(
            holding: [reblog, post],
            routes: ["/api/v1/statuses/9/favourite": .json(Self.status(favourited: true))]
        )
        let row = try #require(session.timelineItems(latest: nil).first)
        await session.toggle(.favourite, on: row)
        #expect(await server.paths == ["/api/v1/statuses/9/favourite"])
        #expect(await server.paths.allSatisfy { !$0.contains("900") })
        let rows = session.timelineItems(latest: nil)
        #expect(rows.map(\.favourited) == [true, true], "the reblog's row and the post's own")
        #expect(await session.store.note(reblog.key)?.favourited == nil, "the reblog itself has no mark")
        #expect(session.acts.standings.isEmpty)
    }

    @Test("A reblog whose post is not held offers no act at all, so nothing can be sent with the reblog's id")
    func nothingIsSentForAnUnheldReblog() async throws {
        let (session, server) = try await shell(holding: [reblog])
        let row = try #require(session.timelineItems(latest: nil).first)
        #expect(session.acts(on: row) == .none)
        await session.toggle(.favourite, on: row)
        await session.toggle(.boost, on: row)
        await session.toggle(.bookmark, on: row)
        #expect(await server.requests.isEmpty)
    }

    @Test("Even the row made with no post in hand names no id: a caller that skipped the lookup can send nothing")
    func theBareRowCannotAct() async throws {
        let (session, server) = try await shell(holding: [reblog, post])
        let bare = DummyItem(reblog)
        #expect(session.acts(on: bare) == .none)
        await session.toggle(.favourite, on: bare)
        #expect(await server.requests.isEmpty)
    }

    @Test("Keeping the reblog's row keeps the reblog, the item pressed, and not the post")
    func keepKeepsTheReblog() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        let row = try #require(session.timelineItems(latest: nil).first)
        #expect(await session.setKept(true, on: row))
        #expect(await session.store.note(reblog.key)?.kept == true)
        #expect(await session.store.note(post.key)?.kept == false)
        #expect(session.timelineItems(latest: nil).map(\.kept) == [true, false])
    }

    @Test("A kept reblog's row does not come to say its post is no longer held: letting a span of dates go leaves the post it shows")
    func aKeptRowKeepsItsPromise() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        let row = try #require(session.timelineItems(latest: nil).first)
        #expect(await session.setKept(true, on: row))
        let span = Self.published.addingTimeInterval(-86400) ..< Self.reblogged.addingTimeInterval(86400)
        #expect(await session.store.letGo(span: span) == 0)
        await session.reloadFromStore()
        let after = try #require(session.timelineItems(latest: nil).first)
        #expect(after.kept && !after.reblogUnheld && after.body == "hello about cats")
        #expect(await session.store.note(post.key)?.kept == false, "the mark is the reblog's alone")
    }

    @Test("What each reblog reblogs is looked up once for each time the notes are replaced, however many timelines, searches and rows read it")
    func oneLookupPerAdopt() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        let built = session.reblogTargetsBuilt
        let search = ShellSearch()
        search.open(from: nil, over: session.notes)
        await search.indexed()
        search.text = "cats"
        search.settle("cats")
        // Every lookup built anywhere on this task while these read: the session's one, and none
        // of a timeline's, a search's or the rows' own.
        let tag = try #require(PostTag.found(in: "#cats").first)
        let tally = ReblogTargets.Tally()
        ReblogTargets.$counting.withValue(tally) {
            _ = session.timelineItems(latest: nil)
            let timeline = TimelineDefinition(name: "T", rules: [Rule.keyword("cats", in: .every)].compactMap { $0 })
            session.written = [timeline]
            session.timelineID = .written(timeline.id)
            #expect(session.timelineItems(latest: nil).count == 2)
            #expect(session.heldPosts(under: tag, latest: nil).isEmpty)
            _ = session.held(reblog.key.rowID)
            _ = session.rowOpened(by: reblog.key.rowID)
            #expect(session.searched(search, latest: nil)?.count == 2)
        }
        #expect(tally.built == 1)
        #expect(session.reblogTargetsBuilt - built == 1)
        await session.store.forget(post.key)
        await session.reloadFromStore()
        #expect(session.timelineItems(latest: nil).isEmpty, "the reblog says nothing now: no rule on words finds it")
        session.timelineID = .all
        #expect(session.timelineItems(latest: nil).first?.reblogUnheld == true)
        #expect(session.reblogTargetsBuilt - built == 2, "and again once the notes were replaced")
    }

    @Test("A row that claims to be a reblog and to have words draws none of them, held or not, and names no id")
    func aRowThatClaimsBoth() {
        let claimed = Note(
            id: reblog.id, source: source, author: "Bob", handle: "@bob@social.example", body: "words of its own",
            postedAt: Self.reblogged, categories: [.home], favourited: true,
            attachments: [Attachment(kind: .image, url: URL(string: "https://social.example/a.png"))],
            spoiler: "a cover", counts: Counts(favourites: 9), statusID: "900", refs: reblog.refs
        )
        let unheld = DummyItem(claimed, reblogging: nil)
        #expect(unheld.reblogUnheld && unheld.body.isEmpty && unheld.attachments.isEmpty && unheld.spoiler == nil)
        #expect(unheld.favourited == nil && unheld.counts == DummyCounts() && unheld.statusID == nil)
        #expect(DummyItem(claimed, reblogging: post).body == "hello about cats")
    }

    @Test("A reblog is in no thread: one handed in among a post's answers, or among what it answers, is left out, never drawn as a reblog of nothing")
    func aReblogIsInNoThread() {
        let answer = Note(
            id: "https://social.example/users/cyd/statuses/10", source: source, author: "Cyd", handle: "@cyd@social.example",
            body: "an answer", postedAt: Self.published, categories: [], reply: Reply(inReplyToId: "9"), statusID: "10"
        )
        let thread = DummyConversation.around(
            DummyItem(post), rootID: "9", ancestors: [reblog, answer], descendants: [answer, reblog]
        )
        #expect(thread.ancestors.map(\.id) == [answer.key.rowID])
        #expect(thread.descendants.map(\.item.id) == [answer.key.rowID])
        #expect(thread.inOrder.allSatisfy { !$0.isReblog })
    }

    @Test("Opening the reblog's row opens the post it reblogs; a post opens itself")
    func opening() async throws {
        let (session, _) = try await shell(holding: [reblog, post])
        #expect(session.rowOpened(by: reblog.key.rowID) == post.key.rowID)
        #expect(session.rowOpened(by: post.key.rowID) == post.key.rowID)
        #expect(session.held(reblog.key.rowID)?.body == "hello about cats", "a row looked up by id is drawn with its post too")
    }

    @Test("On the page of whoever reblogged, the reblog stands at its time showing the post; on the author's page the post stands once, at its own")
    func onAPersonsPage() async throws {
        let bob = DummyPerson.held(of: try #require(DummyPerson(DummyItem(reblog))), in: [reblog, post])
        #expect(bob.map(\.id) == [reblog.key.rowID] && bob[0].body == "hello about cats" && bob[0].postedAt == Self.reblogged)
        let ada = DummyPerson.held(of: try #require(DummyPerson(DummyItem(post))), in: [reblog, post])
        #expect(ada.map(\.id) == [post.key.rowID] && ada[0].postedAt == Self.published && !ada[0].isReblog)
    }
}
