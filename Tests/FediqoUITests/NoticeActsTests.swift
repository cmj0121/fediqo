import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Mastodons answering for their notices, for what is done to them and for the sign-in's own
/// pages, each by method, host and path, and remembering what they were asked. A route not
/// handed in answers as an older server does — 404 to the gathered read and to the policy —
/// and has no notices older than the page it was given.
actor NoticeActServer: HTTPSender {
    enum Outcome: Sendable {
        case body(String)
        case status(Int)
        /// Answers only once the gate opens.
        case held(Gate, String, Int = 200)
        /// No answer at all, once the gate opens: the request fails as the door's own does —
        /// `.timedOut` is a request that ran out of time, with nobody waiting for a clock.
        case fails(Gate?, URLError.Code)
    }

    private var routes: [String: Outcome]
    /// A scope this server does not know: a registration that asks for it is refused.
    private let refuses: String?
    private(set) var asked: [String] = []
    private var issued = 0

    init(_ routes: [String: Outcome] = [:], refuses: String? = nil) {
        self.routes = routes
        self.refuses = refuses?.replacingOccurrences(of: ":", with: "%3A")
    }

    func set(_ key: String, _ outcome: Outcome?) {
        routes[key] = outcome
    }

    /// What was asked that changes a source, in order.
    var posts: [String] { asked.filter { $0.hasPrefix("POST ") && !$0.contains("/oauth/") && !$0.hasSuffix("/api/v1/apps") } }

    func count(_ key: String) -> Int { asked.filter { $0 == key }.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let older = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "max_id" } == true
        let key = "\(request.httpMethod ?? "GET") \(url.host ?? "")\(url.path)" + (older ? "?older" : "")
        asked.append(key)
        func answer(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        switch routes[key] {
        case .body(let body)?: return answer(body)
        case .status(let status)?: return answer(#"{"error":"no"}"#, status)
        case .held(let gate, let body, let status)?:
            await gate.wait()
            return answer(body, status)
        case .fails(let gate, let code)?:
            await gate?.wait()
            throw URLError(code)
        case nil: break
        }
        switch url.path {
        case "/api/v2/notifications", "/api/v2/notifications/policy":
            return answer(#"{"error":"Not Found"}"#, 404)
        // Asked for older than it was given a page for: it has no more.
        case "/api/v1/notifications" where older:
            return answer("[]")
        case "/api/v1/apps":
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if let refuses, form.contains(refuses) {
                return answer(#"{"error":"Validation failed: Scopes doesn't match those configured on the server."}"#, 422)
            }
            return answer(#"{"client_id":"cid","client_secret":"csecret"}"#)
        case "/oauth/token":
            issued += 1
            return answer(#"{"access_token":"tok-new-\#(issued)"}"#)
        case "/api/v1/accounts/verify_credentials":
            return answer(#"{"id":"1","acct":"me"}"#)
        case "/oauth/revoke":
            return answer("{}")
        default:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// The server's own page: approves with the state it was sent, or is closed by the reader.
@MainActor
final class NoticeActPage: OAuthBrowser {
    private let closes: Bool
    /// What each page asked the reader to agree to, in order.
    private(set) var scopes: [String] = []

    init(closes: Bool = false) {
        self.closes = closes
    }

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        scopes.append(items.first { $0.name == "scope" }?.value ?? "")
        guard !closes else { throw MastodonSignInError.cancelled }
        let state = items.first { $0.name == "state" }?.value ?? ""
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }
}

/// What the two suites about acting on notices build their sessions and answers from.
@MainActor
enum NoticeActFixture {
    static let a = "a.example"
    static let b = "b.example"
    /// A sign-in that reads and acts, and may read and dismiss notices.
    static let acts = MastodonOAuth.scopes(writing: true, notices: true)
    /// A sign-in that reads, and may read notices.
    static let reads = MastodonOAuth.scopes(writing: false, notices: true)
    /// Sign-ins never asked for notices.
    static let plain = MastodonOAuth.scopes(writing: false)
    static let plainActing = MastodonOAuth.scopes(writing: true)

    static func ago(_ minutes: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-Double(minutes) * 60))
    }

    /// One notice of the single read, by `name`.
    static func one(_ id: Int, _ type: String = "favourite", by name: String = "Ada", minutes: Int) -> String {
        let user = name.lowercased().replacingOccurrences(of: " ", with: "")
        return """
        {"id":"\(id)","type":"\(type)","created_at":"\(ago(minutes))",\
        "account":{"id":"\(id)","username":"\(user)","acct":"\(user)","display_name":"\(name)"}}
        """
    }

    static func page(_ notices: String...) -> NoticeActServer.Outcome {
        .body("[" + notices.joined(separator: ",") + "]")
    }

    /// One line of the gathered read: `count` favourites of one post.
    static func gathered(count: Int, newest: Int) -> NoticeActServer.Outcome {
        .body("""
        {"accounts":[],"statuses":[],"notification_groups":[{"group_key":"favourite-9-1",
         "notifications_count":\(count),"type":"favourite","most_recent_notification_id":\(newest),
         "page_min_id":"1","page_max_id":"\(newest)","latest_page_notification_at":"\(ago(3))",
         "sample_account_ids":[]}]}
        """)
    }

    static func policy(requests: Int, notices: Int) -> NoticeActServer.Outcome {
        .body(#"{"summary":{"pending_requests_count":\#(requests),"pending_notifications_count":\#(notices)}}"#)
    }

    /// One held-back request, as the source lists it: its count a string.
    static func request(_ id: Int, by name: String, count: Int, words: String = "Held words") -> String {
        let user = name.lowercased().replacingOccurrences(of: " ", with: "")
        return """
        {"id":"\(id)","notifications_count":"\(count)","updated_at":"\(ago(4))",\
        "account":{"id":"\(id)","username":"\(user)","acct":"\(user)","display_name":"\(name)"},\
        "last_status":{"id":"9\(id)","uri":"https://\(a)/p/9\(id)","created_at":"\(ago(5))","content":"<p>\(words)</p>",\
        "account":{"username":"\(user)","acct":"\(user)","display_name":"\(name)"}}}
        """
    }

    static func token(_ host: String, scopes: String?, access: String? = nil) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: access ?? "tok-\(host)", clientID: "cid", clientSecret: "csecret", scopes: scopes,
            asked: scopes
        )
    }

    static func get(_ host: String, _ path: String = "/api/v1/notifications") -> String { "GET \(host)\(path)" }
    static func post(_ host: String, _ path: String) -> String { "POST \(host)\(path)" }

    /// A session holding each of `hosts` as a Mastodon, signed in with the scopes named.
    static func shell(
        _ routes: [String: NoticeActServer.Outcome], signedIn hosts: [String: String?], refuses: String? = nil
    ) async throws -> (ShellSession, NoticeActServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        for (host, scopes) in hosts { try tokens.save(token(host, scopes: scopes)) }
        let server = NoticeActServer(routes, refuses: refuses)
        let store = ItemStore(sources: hosts.keys.sorted().map { Source(host: $0, kind: .mastodon) }, notes: [])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        session.noticeList.deadline = .seconds(5)
        return (session, server, tokens)
    }
}

/// #323 — what is done to notices from their page, on stub doors: the ask for them, dismissing
/// one and all, and what a source holds back. Every path here ends in what the session holds
/// and what the source was asked; how each is drawn is `NoticeActsHostedTests`.
@MainActor
@Suite("Acting on notices: the ask, dismissing, and what a source holds back")
struct NoticeActsTests {
    private typealias F = NoticeActFixture
    private static let a = F.a
    private static let b = F.b

    private func ids(_ notices: [Notice]) -> [String] {
        notices.map { "\($0.source.host.prefix(1))\($0.newestID)" }
    }

    /// Two sources read: `a` acts, `b` only reads.
    private func two(
        _ extra: [String: NoticeActServer.Outcome] = [:], a scopes: String = F.acts
    ) async throws -> (ShellSession, NoticeActServer, MemoryMastodonTokens) {
        var routes: [String: NoticeActServer.Outcome] = [
            F.get(Self.a): F.page(F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9)),
            F.get(Self.b): F.page(F.one(8, "mention", by: "Cy", minutes: 5)),
        ]
        routes.merge(extra) { _, new in new }
        let shell = try await F.shell(routes, signedIn: [Self.a: scopes, Self.b: F.reads])
        await shell.0.noticeList.read(in: shell.0)
        // Read on to each source's end, so every line is shown and nothing is held under a floor.
        await shell.0.noticeList.readOn(in: shell.0)
        await shell.0.noticeList.readOn(in: shell.0)
        #expect(ids(shell.0.noticeList.lines) == ["a4", "b8", "a3"])
        return shell
    }

    /// What the strip at the foot of every page says, newest first.
    private func strip(_ session: ShellSession) -> [String] {
        session.said.lines.map { $0.words(language: .english) }
    }

    private func line(_ id: String, in session: ShellSession) throws -> Notice {
        try #require(session.noticeList.lines.first { "\($0.source.host.prefix(1))\($0.newestID)" == id })
    }

    // MARK: - The ask

    @Test("The press raises a question that names notices before anything is sent or any page opens, and a no leaves everything as it was")
    func theQuestionComesFirst() async throws {
        let (session, server, tokens) = try await F.shell([:], signedIn: [Self.a: F.plain, Self.b: F.plainActing])
        let page = NoticeActPage()

        #expect(session.askForNotices(host: Self.a))
        #expect(session.noticeAsk == Self.a)
        #expect(await server.asked.isEmpty && page.scopes.isEmpty, "something was sent before the question was answered")

        let reads = ShellQuestion.notices(host: Self.a, grant: session.mastodon.grants[Self.a], language: .english)
        #expect(reads.title == "Ask a.example for your notices?")
        #expect(reads.line == "Its page asks again for what you allowed, and to read notices.")
        #expect(reads.help?.contains("to read your notifications there") == true)
        #expect(reads.help?.contains("it is not asked to dismiss them") == true)
        #expect(reads.help?.contains("the sign-in you have goes on as it is") == true)
        #expect(reads.choices.map(\.label) == ["Ask"] && !reads.warns && reads.cancel == "Cancel")

        // Where the sign-in acts, dismissing is named too.
        let acts = ShellQuestion.notices(host: Self.b, grant: session.mastodon.grants[Self.b], language: .english)
        #expect(acts.line == "Its page asks for what you allowed, and to read and dismiss notices.")
        #expect(acts.help?.contains("to read your notifications there, and to dismiss them") == true)
        #expect(acts.help?.contains("the sign-in you have goes on as it is") == true)
        for question in [reads, acts] {
            #expect(ShellQuestion.width(question.line) <= ShellQuestion.lineLength)
        }

        session.cancelNoticeAsk()
        #expect(session.noticeAsk == nil)
        #expect(session.mastodon.notices(host: Self.a) == .unasked)
        #expect(try tokens.token(host: Self.a)?.accessToken == "tok-a.example")
        #expect(await server.asked.isEmpty && page.scopes.isEmpty)
    }

    @Test("The read-or-act question about a source whose notices the sign-in carries says they are asked for with it, and dismissing where acting is chosen; one that carries none says nothing of them",
          arguments: [DummyLanguage.english, .taiwanese])
    func theOrdinaryQuestionNamesWhatIsCarried(_ language: DummyLanguage) throws {
        let english = language == .english
        let carried = ShellQuestion.signIn(host: Self.a, notices: true, language: language)
        let plain = ShellQuestion.signIn(host: Self.a, language: language)
        #expect(plain == ShellQuestion.signIn(host: Self.a, notices: false, language: language))
        #expect(!plain.line.contains(english ? "notice" : "通知") && plain.help?.contains(english ? "notice" : "通知") == false)

        #expect(carried.title == plain.title && carried.choices == plain.choices && carried.cancel == plain.cancel)
        #expect(carried.chorded?.id == ShellQuestion.signInRead, "the answer given without looking grants the most")
        // The notices question's own words for the same choice.
        #expect(carried.line == ShellQuestion.notices(host: Self.a, grant: .unasked, language: language).line)
        #expect(ShellQuestion.width(carried.line) <= ShellQuestion.lineLength)
        let help = try #require(carried.help)
        #expect(help.contains(Self.a) && !help.contains("%") && help.count > carried.line.count)
        if english {
            #expect(carried.line == "Its page asks to read your notices. Choose what else it may do.")
            #expect(help.contains("Sign in to read asks to read, your notices among it."))
            #expect(help.contains("Sign in to read and write asks to post, reply, boost, favourite and bookmark as well, and to dismiss notices."))
            #expect(help.contains("the sign-in you have goes on as it is"))
        } else {
            #expect(help.contains("包含你的通知") && help.contains("移除通知") && help.contains("書籤"))
        }
    }

    @Test("The bookmark question about a source whose notices the sign-in carries says the page asks to read and dismiss them too",
          arguments: [DummyLanguage.english, .taiwanese])
    func theBookmarkQuestionNamesWhatIsCarried(_ language: DummyLanguage) throws {
        let english = language == .english
        let carried = ShellQuestion.bookmarks(host: Self.a, notices: true, language: language)
        let plain = ShellQuestion.bookmarks(host: Self.a, language: language)
        #expect(plain == ShellQuestion.bookmarks(host: Self.a, notices: false, language: language))
        #expect(!plain.line.contains(english ? "notice" : "通知") && plain.help?.contains(english ? "notif" : "通知") == false)
        #expect(carried.title == plain.title && carried.choices == plain.choices && !carried.warns)
        #expect(carried.line.contains(english ? "bookmarks and notices" : "書籤與通知"))
        #expect(ShellQuestion.width(carried.line) <= ShellQuestion.lineLength)
        let help = try #require(carried.help)
        #expect(help.contains(Self.a) && !help.contains("%"))
        #expect(help.contains(english ? "to read your notifications there, and to dismiss them" : "讀取你在那裡的通知，以及移除它們"))
        #expect(help.contains(english ? "bookmarks" : "書籤"))
    }

    @Test("Every place that raises an ordinary sign-in question asks the session, which reads what that sign-in will carry: the question and the page it leads to agree")
    func theQuestionAndThePageAgree() async throws {
        let beforeBookmarks = MastodonOAuth.scopes(writing: true, bookmarks: false, notices: true)
        let (session, _, _) = try await F.shell([:], signedIn: [
            Self.a: F.reads, Self.b: F.plain, "c.example": beforeBookmarks, "d.example": F.plainActing,
        ])
        // A sign-in that reads notices, asked what it may do: the row's own press for writing.
        #expect(session.mastodon.carriesNotices(host: Self.a))
        #expect(session.signInQuestion(host: Self.a) == ShellQuestion.signIn(host: Self.a, notices: true))
        #expect(session.signInQuestion(host: "A.Example").line == session.signInQuestion(host: Self.a).line)
        // One never asked for notices, and a source nobody is signed in to, carry none.
        for host in [Self.b, "d.example", "nobody.example"] {
            #expect(!session.mastodon.carriesNotices(host: host))
            #expect(session.signInQuestion(host: host) == ShellQuestion.signIn(host: host))
            #expect(session.bookmarkQuestion(host: host) == ShellQuestion.bookmarks(host: host))
        }
        // The bookmark question, which a post's row and Account both put.
        #expect(session.mastodon.bookmarks(host: "c.example") == .unasked)
        #expect(session.bookmarkQuestion(host: "c.example") == ShellQuestion.bookmarks(host: "c.example", notices: true))

        // What the question said is what the page is asked for, whichever answer is given.
        for (writing, wanted) in [(false, F.reads), (true, F.acts)] {
            let page = NoticeActPage()
            await session.signIn(host: Self.a, through: page, writing: writing)
            #expect(page.scopes == [wanted], "the page asked for other than the question said")
            #expect(session.signInQuestion(host: Self.a) == ShellQuestion.signIn(host: Self.a, notices: true))
        }
        let asked = NoticeActPage()
        await session.allowBookmarks(host: "c.example", through: asked)
        #expect(asked.scopes == [F.acts])
        let none = NoticeActPage()
        await session.signIn(host: Self.b, through: none, writing: true)
        #expect(none.scopes == [F.plainActing], "a sign-in told nothing of notices asked for them")
    }

    @Test("Notices allowed while a sign-in question stood open are not asked for by its answer: the page asks for what the question said, and a question put down reads afresh")
    func theAnswerAsksForWhatTheQuestionSaid() async throws {
        let (session, _, tokens) = try await F.shell([:], signedIn: [Self.a: F.plain, Self.b: F.plainActing])
        func allow(_ host: String, _ scopes: String) throws {
            try tokens.save(F.token(host, scopes: scopes))
            session.mastodon.refresh()
        }

        // The read-or-act question, drawn while the sign-in has no notices.
        session.signInChoice = Self.a
        let asked = session.signInAsked(host: Self.a)
        #expect(asked == SignInAsked(host: Self.a, notices: false))
        try allow(Self.a, F.reads)
        #expect(session.mastodon.carriesNotices(host: Self.a))
        #expect(session.signInAsked(host: Self.a) == asked, "a card drawn again came to say something else")
        #expect(session.signInQuestion(host: Self.a) == ShellQuestion.signIn(host: Self.a))
        let page = NoticeActPage()
        session.putDownSignInChoice()
        await session.signIn(host: Self.a, through: page, writing: true, noticesSaid: asked.notices)
        #expect(page.scopes == [F.plainActing], "the page asked for notices the question never named")
        #expect(session.signInChoice == nil)

        // Put down, the next question reads what is held now, and its answer carries that.
        try allow(Self.a, F.acts)
        session.signInChoice = Self.a
        let again = session.signInAsked(host: Self.a)
        #expect(again.notices && session.signInQuestion(host: Self.a) == ShellQuestion.signIn(host: Self.a, notices: true))
        // Said to carry them and since lost: the page asks for less, never more.
        try allow(Self.a, F.plainActing)
        let less = NoticeActPage()
        session.putDownSignInChoice()
        await session.signIn(host: Self.a, through: less, writing: true, noticesSaid: again.notices)
        #expect(less.scopes == [F.plainActing])

        // The bookmark question, the same way.
        let beforeBookmarks = MastodonOAuth.scopes(writing: true, bookmarks: false)
        try allow(Self.b, beforeBookmarks)
        session.bookmarkAsk = Self.b
        let bookmark = session.signInAsked(host: Self.b)
        #expect(!bookmark.notices && session.bookmarkQuestion(host: Self.b) == ShellQuestion.bookmarks(host: Self.b))
        try allow(Self.b, MastodonOAuth.scopes(writing: true, bookmarks: false, notices: true))
        #expect(session.mastodon.carriesNotices(host: Self.b) && session.mastodon.bookmarks(host: Self.b) == .unasked)
        let marks = NoticeActPage()
        await session.allowBookmarks(host: Self.b, through: marks, noticesSaid: bookmark.notices)
        #expect(marks.scopes == [F.plainActing], "the page asked for notices the question never named")
        #expect(session.bookmarkAsk == nil && session.noticesSaid.isEmpty)
    }

    @Test("Yes opens the source's own page asking for notices on top of what the sign-in has — and dismissing only where it acts — and then the page reads")
    func yesAsksOnTheSourcesPage() async throws {
        for (held, writing) in [(F.plain, false), (F.plainActing, true)] {
            let (session, server, tokens) = try await F.shell(
                [F.get(Self.a): F.page(F.one(4, minutes: 2))], signedIn: [Self.a: held]
            )
            let page = NoticeActPage()
            session.askForNotices(host: Self.a)

            await session.allowNotices(host: Self.a, through: page)

            #expect(page.scopes == [MastodonOAuth.scopes(writing: writing, notices: true)])
            #expect(session.noticeAsk == nil)
            #expect(session.mastodon.notices(host: Self.a) == .allowed)
            #expect(session.mastodon.dismisses(host: Self.a) == writing, "dismissing was asked of a sign-in that only reads")
            #expect(session.mastodon.grants[Self.a] == (writing ? .writing : .reading))
            #expect(try tokens.token(host: Self.a)?.accessToken == "tok-new-1")
            #expect(ids(session.noticeList.lines) == ["a4"], "the page did not read once notices were allowed")
            #expect(session.noticeList.acts.said.isEmpty)
            #expect(await !server.asked.contains("POST a.example/oauth/revoke") || session.mastodon.isSignedIn(host: Self.a))
        }
    }

    @Test("A page closed leaves the sign-in as it was and says nothing; the source may be asked again")
    func aClosedPageChangesNothing() async throws {
        let (session, _, tokens) = try await F.shell([:], signedIn: [Self.a: F.plainActing])
        session.askForNotices(host: Self.a)

        await session.allowNotices(host: Self.a, through: NoticeActPage(closes: true))

        #expect(session.mastodon.isSignedIn(host: Self.a))
        #expect(try tokens.token(host: Self.a)?.accessToken == "tok-a.example")
        #expect(try tokens.token(host: Self.a)?.scopes == F.plainActing)
        #expect(session.mastodon.grants[Self.a] == .writing)
        #expect(session.mastodon.notices(host: Self.a) == .unasked)
        #expect(session.noticeList.acts.said.isEmpty && session.rowRefusal == nil && session.mastodon.ended.isEmpty)
        #expect(session.askForNotices(host: Self.a), "a page closed stopped the source being asked")
    }

    @Test("An ask that fails says notices were not allowed, never that the sign-in failed, and the sign-in held goes on")
    func aFailedAskSaysOnlyWhatIsTrue() async throws {
        let (session, server, tokens) = try await F.shell([:], signedIn: [Self.a: F.plain])
        await server.set("POST a.example/api/v1/apps", .status(503))

        await session.allowNotices(host: Self.a, through: NoticeActPage())

        #expect(session.noticeList.acts.said[Self.a] == .init(act: .ask, why: .unreachable))
        #expect(NoticesPane.said(in: session, language: .english).map(\.words)
            == ["Notices were not allowed on a.example. Its sign-in works as it did."])
        #expect(session.rowRefusal == nil, "the sign-in was said to have failed")
        #expect(session.mastodon.isSignedIn(host: Self.a) && session.mastodon.grants[Self.a] == .reading)
        #expect(try tokens.token(host: Self.a)?.accessToken == "tok-a.example")
        #expect(session.mastodon.notices(host: Self.a) == .unasked)
    }

    @Test("A source that has no notices to give is named as having none, is not asked again, and keeps its sign-in")
    func aSourceWithNoneIsNotAskedAgain() async throws {
        let (session, server, tokens) = try await F.shell([:], signedIn: [Self.a: F.plain], refuses: MastodonOAuth.noticing)
        let page = NoticeActPage()

        await session.allowNotices(host: Self.a, through: page)

        #expect(page.scopes.isEmpty, "a page was opened for a scope the server does not know")
        #expect(session.mastodon.notices(host: Self.a) == .unavailable)
        #expect(NoticesPane.lines(in: session) == [.refused(host: Self.a)])
        #expect(session.noticeList.acts.said.isEmpty, "the page's own line says it, and nothing says it twice")
        #expect(session.mastodon.isSignedIn(host: Self.a))
        #expect(try tokens.token(host: Self.a)?.accessToken == "tok-a.example")

        let sent = await server.asked.count
        #expect(!session.askForNotices(host: Self.a), "a source that answered was offered the question again")
        await session.allowNotices(host: Self.a, through: page)
        #expect(await server.asked.count == sent && page.scopes.isEmpty)
    }

    @Test("A sign-in made before any was asked what it may do is asked to read or to act, with notices in both answers")
    func anEarliestSignInChooses() async throws {
        for writing in [false, true] {
            let (session, _, _) = try await F.shell([F.get(Self.a): F.page()], signedIn: [Self.a: nil])
            #expect(session.mastodon.grants[Self.a] == .unasked)
            let question = ShellQuestion.notices(host: Self.a, grant: .unasked, language: .english)
            #expect(question.choices.map(\.label) == ["Read only", "Read and write"])
            #expect(question.line == "Its page asks to read your notices. Choose what else it may do.")
            #expect(question.chorded?.id == ShellQuestion.signInRead, "the answer a key gives is the one that grants least")
            #expect(ShellQuestion.noticesChose(ShellQuestion.signInWrite) == true)
            #expect(ShellQuestion.noticesChose(ShellQuestion.signInRead) == false)
            #expect(ShellQuestion.noticesChose(ShellQuestion.yes) == nil)

            let page = NoticeActPage()
            await session.allowNotices(host: Self.a, through: page, writing: writing)
            #expect(page.scopes == [MastodonOAuth.scopes(writing: writing, notices: true)])
            #expect(session.mastodon.dismisses(host: Self.a) == writing)
        }
    }

    @Test("A question left open over a source since signed out asks nothing")
    func aStaleQuestionAsksNothing() async throws {
        let (session, server, _) = try await F.shell([:], signedIn: [Self.a: F.plain])
        session.askForNotices(host: Self.a)
        await session.mastodon.signOut(host: Self.a)
        let sent = await server.asked.count
        let page = NoticeActPage()

        await session.allowNotices(host: Self.a, through: page)

        #expect(page.scopes.isEmpty)
        #expect(await server.asked.count == sent)
        #expect(!session.mastodon.isSignedIn(host: Self.a), "the press for notices signed somebody in")
    }

    // MARK: - Dismissing one

    @Test("A dismissed line leaves what is drawn at the yes, and what is held only once its source has answered")
    func dismissedOnlyAfterTheAnswer() async throws {
        let gate = Gate()
        let dismiss = F.post(Self.a, "/api/v1/notifications/4/dismiss")
        let (session, server, _) = try await two([dismiss: .held(gate, "{}")])
        let acts = session.noticeList.acts
        let notice = try line("a4", in: session)

        let task = Task { await acts.dismiss(notice, in: session) }
        #expect(await spun { await server.count(dismiss) == 1 })
        #expect(ids(session.noticeList.lines) == ["b8", "a3"], "the line was drawn after the yes")
        #expect(session.noticeList.reaches[Self.a]?.notices.contains { $0.id == notice.id } == true, "it left what is held before the source answered")
        #expect(acts.acting == [notice.id])

        await gate.open()
        await task.value
        #expect(ids(session.noticeList.lines) == ["b8", "a3"])
        #expect(session.noticeList.reaches[Self.a]?.notices.contains { $0.id == notice.id } == false)
        #expect(acts.acting.isEmpty && acts.said.isEmpty && session.said.lines.isEmpty)
        #expect(await server.posts == [dismiss])
    }

    @Test("A gathered line is dismissed as the line it is: by its key, in one request")
    func aGatheredLineGoesAsOne() async throws {
        let dismiss = F.post(Self.a, "/api/v2/notifications/favourite-9-1/dismiss")
        let (session, server, _) = try await F.shell([
            F.get(Self.a, "/api/v2/notifications"): F.gathered(count: 5, newest: 12),
            dismiss: .body("{}"),
        ], signedIn: [Self.a: F.acts])
        await session.noticeList.read(in: session)
        let notice = try #require(session.noticeList.lines.first)
        #expect(notice.count == 5 && notice.handle == .gathered(key: "favourite-9-1"))

        await session.noticeList.acts.dismiss(notice, in: session)

        #expect(session.noticeList.lines.isEmpty)
        #expect(await server.posts == [dismiss])
    }

    @Test("A dismissal the source refuses, or that fails, draws the line again and says so on the strip; the next that lands takes the words down")
    func aRefusalLeavesTheLine() async throws {
        let dismiss = F.post(Self.a, "/api/v1/notifications/4/dismiss")
        let (session, server, tokens) = try await two([dismiss: .status(403)])
        let acts = session.noticeList.acts
        let notice = try line("a4", in: session)

        await acts.dismiss(notice, in: session)
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"])
        #expect(session.said.lines.map(\.what) == [.notice(.dismiss)] && session.said.lines.map(\.why) == [.refused])
        #expect(strip(session) == ["a.example would not let this sign-in dismiss the notice. It is still here. The notice: Ada favourited your post."])
        #expect(acts.said.isEmpty && NoticesPane.said(in: session).isEmpty, "said twice: on the strip and above the list")
        #expect(session.mastodon.dismisses(host: Self.a), "one refusal rewrote what the sign-in may do")
        #expect(try tokens.token(host: Self.a)?.scopes == F.acts)

        await server.set(dismiss, .status(503))
        await acts.dismiss(notice, in: session)
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"])
        #expect(session.said.lines.map(\.what) == [.notice(.dismiss)] && session.said.lines.map(\.why) == [.declined])
        #expect(strip(session) == ["a.example did not dismiss the notice. It is still here. The notice: Ada favourited your post."])

        // No answer at all is the one thing said as not reached.
        await server.set(dismiss, nil)
        await acts.dismiss(notice, in: session)
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"])
        #expect(strip(session) == ["a.example could not be reached, so the notice was not dismissed. It is still here. The notice: Ada favourited your post."])

        await server.set(dismiss, .body("{}"))
        await acts.dismiss(notice, in: session)
        #expect(ids(session.noticeList.lines) == ["b8", "a3"])
        #expect(acts.said.isEmpty && session.said.lines.isEmpty)
    }

    @Test("Nothing is sent for a line whose sign-in only reads, for one of a source not held, or for one the list does not hold")
    func nothingIsSentWhereItMayNotBe() async throws {
        let (session, server, _) = try await two()
        let acts = session.noticeList.acts

        // b's sign-in reads only.
        await acts.dismiss(try line("b8", in: session), in: session)
        // A line that says it is another source's is never sent to this source's door: a's
        // own id, under a source nobody here holds, and under b.
        let held = try line("a4", in: session)
        for host in ["c.example", Self.b] {
            let other = Notice(
                source: Source(host: host, kind: .mastodon), handle: held.handle, kind: held.kind, people: held.people,
                post: nil, at: held.at, newestID: held.newestID, oldestID: held.oldestID
            )
            await acts.dismiss(other, in: session)
        }
        // And one of a's the list does not hold.
        let unheld = Notice(
            source: held.source, handle: .one(id: "99"), kind: .favourite, people: [], post: nil, at: held.at,
            newestID: "99", oldestID: "99"
        )
        await acts.dismiss(unheld, in: session)

        #expect(await server.posts.isEmpty)
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"])
        #expect(acts.said.isEmpty && session.said.lines.isEmpty)
    }

    @Test("An answer for a sign-in since replaced, or signed out of, changes nothing and says nothing")
    func aReplacedSignInsAnswerChangesNothing() async throws {
        let dismiss = F.post(Self.a, "/api/v1/notifications/4/dismiss")
        for (status, replaced) in [(200, true), (403, true), (503, true), (200, false)] {
            let gate = Gate()
            let (session, server, tokens) = try await two([dismiss: .held(gate, "{}", status)])
            let acts = session.noticeList.acts
            let notice = try line("a4", in: session)

            let task = Task { await acts.dismiss(notice, in: session) }
            #expect(await spun { await server.count(dismiss) == 1 })
            if replaced {
                try tokens.save(F.token(Self.a, scopes: F.acts, access: "tok-other"))
            } else {
                try tokens.forget(host: Self.a)
            }
            await gate.open()
            await task.value

            #expect(session.noticeList.reaches[Self.a]?.notices.contains { $0.id == notice.id } == true, "\(status)")
            #expect(acts.said.isEmpty && session.said.lines.isEmpty, "\(status): a refusal of a sign-in no longer held was said of the one held now")
            #expect(acts.acting.isEmpty)
        }
    }

    @Test("A sign-in the server ended while acting is told as one, and what that source said goes with it")
    func anEndedSignInLetsGo() async throws {
        let dismiss = F.post(Self.a, "/api/v1/notifications/4/dismiss")
        let (session, server, _) = try await two([dismiss: .status(401)])
        await server.set(F.get(Self.a, "/api/v1/accounts/verify_credentials"), .status(401))

        await session.noticeList.acts.dismiss(try line("a4", in: session), in: session)

        #expect(!session.mastodon.isSignedIn(host: Self.a))
        #expect(session.mastodon.ended == [Self.a])
        #expect(ids(session.noticeList.lines) == ["b8"])
        #expect(session.noticeList.acts.said.isEmpty && session.said.lines.isEmpty)
    }

    @Test("A line dismissed while its source is being read stays gone when that read answers still naming it")
    func aDismissalOutlivesAReadOnTheWire() async throws {
        let dismiss = F.post(Self.a, "/api/v1/notifications/4/dismiss")
        let (session, server, _) = try await two([dismiss: .body("{}")])
        let list = session.noticeList
        let notice = try line("a4", in: session)
        // The next read of a is asked before the dismissal, and answers after it.
        let gate = Gate()
        await server.set(F.get(Self.a), .held(gate, "[" + [F.one(5, by: "Di", minutes: 1), F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9)].joined(separator: ",") + "]"))
        let read = Task { await list.read(in: session) }
        #expect(await spun { await server.count(F.get(Self.a)) == 2 })

        await list.acts.dismiss(notice, in: session)
        #expect(!list.lines.contains { $0.id == notice.id })

        await gate.open()
        await read.value
        #expect(ids(list.lines) == ["a5", "b8", "a3"], "a line its source dismissed came back with a read asked for before")

        // And a read stopped instead of answered does not put it back either.
        let (other, asked, _) = try await two([dismiss: .body("{}")])
        let closed = Gate()
        await asked.set(F.get(Self.a), .held(closed, "[]"))
        let stopped = Task { await other.noticeList.read(in: other) }
        #expect(await spun { await asked.count(F.get(Self.a)) == 2 })
        await other.noticeList.acts.dismiss(try line("a4", in: other), in: other)
        #expect(other.noticeList.stop())
        await closed.open()
        await stopped.value
        #expect(ids(other.noticeList.lines) == ["b8", "a3"])
    }

    // MARK: - Dismissing all

    @Test("Dismissing all asks one source once; its lines leave what is drawn at the yes and what is held once it answers; the other source's stand")
    func dismissAllTakesOneSourcesLines() async throws {
        let gate = Gate()
        let clear = F.post(Self.a, "/api/v1/notifications/clear")
        let (session, server, _) = try await two([clear: .held(gate, "{}")])
        let acts = session.noticeList.acts

        let task = Task { await acts.dismissAll(host: Self.a, in: session) }
        #expect(await spun { await server.count(clear) == 1 })
        #expect(ids(session.noticeList.lines) == ["b8"], "the source's lines were drawn after the yes")
        #expect(session.noticeList.reaches[Self.a]?.notices.count == 2, "they left what is held before the source answered")
        #expect(acts.acting == [ShellNoticeActs.all(Self.a)])

        await gate.open()
        await task.value
        #expect(ids(session.noticeList.lines) == ["b8"])
        #expect(await server.posts == [clear])
        #expect(session.noticeList.reaches[Self.a]?.before == nil, "a source with nothing left still has more to read on to")
        #expect(!session.noticeList.hasMore(in: session))
    }

    @Test("Dismissing all that is refused or fails draws every line again and says so on the strip; a source whose sign-in only reads is asked nothing")
    func dismissAllRefused() async throws {
        let clear = F.post(Self.a, "/api/v1/notifications/clear")
        let (session, server, _) = try await two([clear: .status(403)])
        let acts = session.noticeList.acts

        await acts.dismissAll(host: Self.a, in: session)
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"])
        #expect(strip(session) == ["a.example would not let this sign-in dismiss its notices. They are still here."])

        await server.set(clear, .status(500))
        await acts.dismissAll(host: Self.a, in: session)
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"])
        #expect(strip(session) == ["a.example did not dismiss its notices. They are still here."])
        #expect(NoticesPane.said(in: session).isEmpty)

        await acts.dismissAll(host: Self.b, in: session)
        #expect(await server.posts == [clear, clear], "a sign-in that only reads was sent to dismiss")
        #expect(acts.said[Self.b] == nil && !session.said.lines.contains { $0.host == Self.b })
    }

    @Test("Dismissing all for a sign-in since replaced changes nothing")
    func dismissAllForAReplacedSignIn() async throws {
        let gate = Gate()
        let clear = F.post(Self.a, "/api/v1/notifications/clear")
        let (session, server, tokens) = try await two([clear: .held(gate, "{}")])
        let task = Task { await session.noticeList.acts.dismissAll(host: Self.a, in: session) }
        #expect(await spun { await server.count(clear) == 1 })
        try tokens.save(F.token(Self.a, scopes: F.acts, access: "tok-other"))
        await gate.open()
        await task.value
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"])
        #expect(session.noticeList.acts.said.isEmpty && session.said.lines.isEmpty)
    }

    // MARK: - What a source holds back

    private static let policy = "/api/v2/notifications/policy"
    private static let requests = "/api/v1/notifications/requests"

    @Test("What a source holds back is asked when the page reads; one with no such thing is asked once and never again")
    func heldIsAskedWithThePageAndAbsentOnlyOnce() async throws {
        let (session, server, _) = try await two([F.get(Self.a, Self.policy): F.policy(requests: 2, notices: 3)])
        let acts = session.noticeList.acts
        #expect(acts.holdings.isEmpty, "reading the list alone asked what is held back")

        await acts.readPage(in: session)
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 2, notices: 3))
        #expect(acts.holdings[Self.b] == .absent && acts.held(host: Self.b) == nil)
        #expect(acts.holders == [Self.a])
        #expect(NoticeActs.words(NoticesHeld(requests: 2, notices: 3), host: Self.a, language: .english)
            == "a.example is holding back 3 notices.")
        #expect(NoticeActs.words(NoticesHeld(requests: 1, notices: 1), host: Self.a, language: .english)
            == "a.example is holding back 1 notice.")
        #expect(await server.count(F.get(Self.a, Self.requests)) == 0, "the requests were read before anybody opened them")

        await acts.readPage(in: session)
        await acts.look(in: session)
        #expect(await server.count(F.get(Self.b, Self.policy)) == 1, "a source that has no such thing was asked again")
        #expect(await server.count(F.get(Self.a, Self.policy)) == 3, "what a source holds changes, and is asked afresh")

        // A source that holds nothing just now has nothing to offer; a failure leaves what was known.
        await server.set(F.get(Self.a, Self.policy), F.policy(requests: 0, notices: 0))
        await acts.look(in: session)
        #expect(acts.held(host: Self.a) == nil && acts.holders.isEmpty)
        await server.set(F.get(Self.a, Self.policy), F.policy(requests: 1, notices: 4))
        await acts.look(in: session)
        await server.set(F.get(Self.a, Self.policy), .status(503))
        await acts.look(in: session)
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 1, notices: 4))
        #expect(acts.said.isEmpty, "a look nobody pressed for said something")
    }

    /// Two sources, `a` holding two people's notices back, its held-back line opened.
    private func holding(
        _ extra: [String: NoticeActServer.Outcome] = [:], a scopes: String = F.acts
    ) async throws -> (ShellSession, NoticeActServer, MemoryMastodonTokens) {
        var routes: [String: NoticeActServer.Outcome] = [
            F.get(Self.a, Self.policy): F.policy(requests: 2, notices: 4),
            F.get(Self.a, Self.requests): .body("[" + F.request(71, by: "Eve", count: 3) + "," + F.request(72, by: "Flo", count: 1) + "]"),
        ]
        routes.merge(extra) { _, new in new }
        let shell = try await two(routes, a: scopes)
        let acts = shell.0.noticeList.acts
        await acts.look(in: shell.0)
        await acts.open(host: Self.a, in: shell.0)
        #expect(acts.opened == [Self.a])
        #expect(acts.requests[Self.a]?.map(\.requestID) == ["71", "72"])
        return shell
    }

    @Test("Opening a source's held-back line lists who, how many and the last one's words; a failure to read them says so")
    func theRequestsAreListed() async throws {
        let (session, server, _) = try await holding()
        let acts = session.noticeList.acts
        let eve = try #require(acts.requests[Self.a]?.first)
        #expect(NoticeActs.name(eve.person) == "Eve" && eve.count == 3)
        #expect(NoticeActs.count(eve, language: .english) == "3 notices held")
        #expect(NoticeActs.excerpt(eve) == "Held words")
        #expect(NoticeActs.spoken(eve, language: .english) == "Eve, 3 notices held: Held words")
        #expect(NoticeActs.count(try #require(acts.requests[Self.a]?.last), language: .english) == "1 notice held")

        acts.close(host: Self.a)
        #expect(acts.opened.isEmpty)
        await server.set(F.get(Self.a, Self.requests), .status(503))
        await acts.open(host: Self.a, in: session)
        #expect(NoticesPane.said(in: session, language: .english).map(\.words) == ["a.example did not hand over what it is holding back."])
        #expect(acts.requests[Self.a]?.count == 2, "a failure emptied what was listed")

        // A source that holds nothing is not opened, and is asked nothing.
        await acts.open(host: Self.b, in: session)
        #expect(!acts.opened.contains(Self.b))
        #expect(await server.count(F.get(Self.b, Self.requests)) == 0)
    }

    @Test("A held-back request whose last post its author covered shows what it was covered with and never its words")
    func aCoveredRequestKeepsItsCover() {
        let source = Source(host: Self.a, kind: .mastodon)
        func request(sensitive: Bool?, spoiler: String?) -> NoticeRequest {
            NoticeRequest(
                requestID: "71", source: source, person: NoticePerson(handle: "@eve@a.example", name: "Eve"), count: 3,
                lastPost: Note(
                    id: "https://a.example/p/971", source: source, author: "Eve", handle: "@eve@a.example",
                    body: "What was put under the cover", postedAt: Date(), categories: [], sensitive: sensitive,
                    spoiler: spoiler, statusID: "971"
                ),
                at: Date()
            )
        }
        let warned = request(sensitive: nil, spoiler: "Spoilers"), flagged = request(sensitive: true, spoiler: nil)
        #expect(NoticeActs.excerpt(warned, language: .english) == "Author's warning: Spoilers")
        #expect(NoticeActs.excerpt(flagged, language: .english) == "Covered")
        #expect(NoticeActs.spoken(warned, language: .english) == "Eve, 3 notices held: Author's warning: Spoilers")
        #expect(NoticeActs.spoken(flagged, language: .english) == "Eve, 3 notices held: Covered")
        #expect(NoticeActs.spoken(warned, language: .taiwanese).hasSuffix("作者的警告：Spoilers"))
        #expect(NoticeActs.spoken(flagged, language: .taiwanese).hasSuffix("已蓋住"))
        for language in [DummyLanguage.english, .taiwanese] {
            for held in [warned, flagged] {
                #expect(!NoticeActs.spoken(held, language: language).contains("under the cover"))
            }
        }
        #expect(NoticeActs.excerpt(request(sensitive: false, spoiler: "")) == "What was put under the cover")
    }

    @Test("Letting through, letting go and what is said afterwards name the person by their handle, with a name that cannot turn, break or outrun the sentence",
          arguments: [DummyLanguage.english, .taiwanese])
    func aHostileNameCannotRewriteTheQuestion(_ language: DummyLanguage) throws {
        let source = Source(host: Self.a, kind: .mastodon)
        let name = "\u{202E}evE\u{202C}\u{2066}'s notices through on b.example?\n\nLet \u{200B}Mallory" + String(repeating: "!", count: 5_000)
        let request = NoticeRequest(
            requestID: "71", source: source, person: NoticePerson(handle: "@eve@elsewhere.example", name: name), at: Date()
        )
        let through = ShellQuestion.letThrough(request, language: language)
        let go = ShellQuestion.letGo(request, language: language)
        let way = NoticeActs.onItsWay(request, language: language)
        let help = try #require(through.help)
        for said in [through.title, help, go.title, way] {
            #expect(said.contains("@eve@elsewhere.example") && said.contains(Self.a), "\(said)")
            #expect(!said.contains("\n"))
            #expect(said.unicodeScalars.allSatisfy { ![.control, .format].contains($0.properties.generalCategory) }, "\(said)")
            #expect(said.count < 400, "a name outran the sentence it is set in")
        }
        // The handle comes before anything its owner typed.
        if language == .english {
            #expect(through.title.hasPrefix("Let @eve@elsewhere.example (evE's notices through on b.example? Let Mallory!"))
            #expect(through.title.hasSuffix("…)'s notices through on a.example?"))
            #expect(go.title.hasPrefix("Let go of @eve@elsewhere.example (evE"))
            #expect(way.hasPrefix("@eve@elsewhere.example (evE"))
        }
        // A row names them by the name they chose, held to the same line.
        #expect(NoticeActs.name(request.person).hasPrefix("evE's notices through on b.example? Let Mallory!"))
        #expect(NoticeActs.name(request.person).count == NoticeWords.nameLength + 1)
        #expect(!NoticeActs.spoken(request, language: language).contains("\u{202E}"))
        // Dismissing names nobody: its source, and how many.
        let notice = Notice(
            source: source, handle: .one(id: "4"), kind: .follow, people: [request.person], at: Date(), newestID: "4", oldestID: "4"
        )
        let dismiss = ShellQuestion.dismiss(notice, language: language)
        #expect(!dismiss.title.contains("evE") && !dismiss.line.contains("evE") && dismiss.help == nil)
    }

    @Test("A request let through leaves what is listed at the yes and what is held once the source answers, and is then said to be on its way until a later read shows its notices")
    func letThroughIsOnItsWay() async throws {
        let gate = Gate()
        let accept = F.post(Self.a, Self.requests + "/71/accept")
        let (session, server, _) = try await holding([accept: .held(gate, "{}")])
        let acts = session.noticeList.acts
        let eve = try #require(acts.requests[Self.a]?.first)

        let task = Task { await acts.letThrough(eve, in: session) }
        #expect(await spun { await server.count(accept) == 1 })
        #expect(acts.requests[Self.a]?.count == 2 && acts.onItsWay.isEmpty, "it moved in what is held before the source answered")

        await gate.open()
        await task.value
        #expect(acts.requests[Self.a]?.map(\.requestID) == ["72"])
        #expect(acts.onItsWay == [eve])
        #expect(NoticeActs.onItsWay(eve, language: .english)
            == "@eve@a.example (Eve)'s notices are on their way from a.example. A later read shows them.")
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 1, notices: 1))
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"], "nothing joins the list with the source's yes")
        let asked = await server.asked.count

        // Nothing polls, and reading on is not the read that shows them.
        await session.noticeList.readOn(in: session)
        #expect(acts.onItsWay == [eve])
        #expect(await server.asked.count == asked, "something was asked with nobody pressing")

        // A read of that source that does not land leaves it said; another source's says nothing of it.
        await server.set(F.get(Self.a), .status(503))
        await session.noticeList.read(in: session)
        #expect(acts.onItsWay == [eve])

        // The next read of its newest stretch that lands takes the words down, whatever it
        // brings: it does not stand for the rest of the run.
        await server.set(F.get(Self.a), F.page(F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9)))
        await session.noticeList.retry(host: Self.a, in: session)
        #expect(acts.onItsWay.isEmpty)
        #expect(session.noticeList.standing(host: Self.a) == .read)
    }

    @Test("A request let go leaves what is held once the source answers; the last one gone, the held-back line goes with it")
    func letGoLeavesAfterTheAnswer() async throws {
        let (session, server, _) = try await holding([
            F.post(Self.a, Self.requests + "/71/dismiss"): .body("{}"),
            F.post(Self.a, Self.requests + "/72/dismiss"): .body("{}"),
        ])
        let acts = session.noticeList.acts
        let listed = try #require(acts.requests[Self.a])

        await acts.letGo(listed[0], in: session)
        #expect(acts.requests[Self.a]?.map(\.requestID) == ["72"])
        #expect(acts.onItsWay.isEmpty)
        await acts.letGo(listed[1], in: session)
        #expect(acts.held(host: Self.a) == nil && acts.holders.isEmpty && acts.opened.isEmpty)
        #expect(await server.posts == [F.post(Self.a, Self.requests + "/71/dismiss"), F.post(Self.a, Self.requests + "/72/dismiss")])
    }

    @Test("A request the source refuses to act on, or that fails, is listed again and the strip says so")
    func aRefusedRequestStays() async throws {
        let accept = F.post(Self.a, Self.requests + "/71/accept")
        let go = F.post(Self.a, Self.requests + "/71/dismiss")
        let (session, _, _) = try await holding([accept: .status(403), go: .status(503)])
        let acts = session.noticeList.acts
        let eve = try #require(acts.requests[Self.a]?.first)

        await acts.letThrough(eve, in: session)
        #expect(acts.requests[Self.a]?.count == 2 && acts.onItsWay.isEmpty)
        #expect(strip(session) == ["a.example would not let this sign-in let notices through. What it holds is still held. From: @eve@a.example (Eve)."])
        #expect(acts.listed(host: Self.a).count == 2, "a request the source kept is not listed")

        await acts.letGo(eve, in: session)
        #expect(acts.requests[Self.a]?.count == 2)
        #expect(strip(session).first == "a.example did not let the notices go. What it holds is still listed. From: @eve@a.example (Eve).")
        #expect(strip(session).count == 2, "two acts, each said: neither stands for the other")
        #expect(NoticesPane.said(in: session).isEmpty)
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 2, notices: 4))
    }

    @Test("Letting through and letting go are acts: nothing is sent for a sign-in that only reads, for another source's request, or for a sign-in since replaced")
    func requestsAreSentOnlyWhereTheyMayBe() async throws {
        // A sign-in that reads sees what is held, and may do nothing to it.
        let (reading, asked, _) = try await holding(a: F.reads)
        let listed = try #require(reading.noticeList.acts.requests[Self.a])
        await reading.noticeList.acts.letThrough(listed[0], in: reading)
        await reading.noticeList.acts.letGo(listed[1], in: reading)
        #expect(await asked.posts.isEmpty)
        #expect(reading.noticeList.acts.requests[Self.a]?.count == 2)

        // A request that says it is another source's is not sent to this source's door.
        let accept = F.post(Self.a, Self.requests + "/71/accept")
        let gate = Gate()
        let (session, server, tokens) = try await holding([accept: .held(gate, "{}")])
        let acts = session.noticeList.acts
        let eve = try #require(acts.requests[Self.a]?.first)
        let elsewhere = NoticeRequest(
            requestID: eve.requestID, source: Source(host: Self.b, kind: .mastodon), person: eve.person, count: eve.count, at: eve.at
        )
        await acts.letThrough(elsewhere, in: session)
        await acts.letGo(elsewhere, in: session)
        #expect(await server.posts.isEmpty)

        // An answer for a sign-in since replaced changes nothing.
        let task = Task { await acts.letThrough(eve, in: session) }
        #expect(await spun { await server.count(accept) == 1 })
        try tokens.save(F.token(Self.a, scopes: F.acts, access: "tok-other"))
        await gate.open()
        await task.value
        #expect(acts.requests[Self.a]?.count == 2 && acts.onItsWay.isEmpty && acts.said.isEmpty && session.said.lines.isEmpty)
    }

    @Test("What a failure is said as is only what is known: refused, not done, not confirmed, or not reached")
    func whatAFailureIsSaidAs() {
        typealias Acts = ShellNoticeActs
        let timedOut = URLError(.timedOut)
        #expect(WriteWhy(MastodonAuthError.http(403), wrote: true) == .refused)
        #expect(WriteWhy(MastodonAuthError.http(401), wrote: false) == .refused)
        #expect(WriteWhy(MastodonAuthError.http(500), wrote: true) == .declined)
        #expect(WriteWhy(MastodonAuthError.http(404), wrote: true) == .declined)
        #expect(WriteWhy(MastodonAuthError.http(429), wrote: false) == .declined)
        #expect(WriteWhy(MastodonNoticeError.unreadable, wrote: false) == .declined)
        #expect(WriteWhy(timedOut, wrote: true) == .unconfirmed, "a write that ran out of time was said not to have happened")
        #expect(WriteWhy(timedOut, wrote: false) == .unreachable, "a read has nothing to confirm")
        #expect(WriteWhy(URLError(.notConnectedToInternet), wrote: true) == .unreachable)
        #expect(WriteWhy(FixtureHTTPError.unreachable, wrote: true) == .unreachable)

        func words(_ act: Acts.Act, _ why: WriteWhy, _ language: DummyLanguage = .english) -> String {
            NoticeActs.words(.init(act: act, why: why), host: Self.a, language: language)
        }
        #expect(words(.dismiss, .unconfirmed) == "a.example did not confirm the notice was dismissed. Read again to see.")
        #expect(words(.dismissAll, .unconfirmed) == "a.example did not confirm its notices were dismissed. Read again to see.")
        #expect(words(.letThrough, .unconfirmed) == "a.example did not confirm the notices were let through. Read again to see.")
        #expect(words(.letGo, .unconfirmed) == "a.example did not confirm the notices were let go. Read again to see.")
        #expect(words(.letThrough, .declined) == "a.example did not let the notices through. What it holds is still listed.")
        #expect(words(.requests, .unreachable) == "Could not read what a.example is holding back.")
        #expect(words(.dismiss, .locked) == "This device could not read the sign-in for a.example, so it was not asked.")
        // Every sentence an act can come to is written in each language.
        let writes: [Acts.Act] = [.dismiss, .dismissAll, .letThrough, .letGo]
        for language in [DummyLanguage.english, .taiwanese] {
            for act in writes + [.requests] {
                for why in [WriteWhy.refused, .unreachable, .declined] + (act == .requests ? [] : [.unconfirmed]) {
                    let said = words(act, why, language)
                    #expect(said.contains(Self.a) && !said.contains("notices.act."), "\(act) \(why) has no words in \(language)")
                }
            }
        }
    }

    @Test("A dismissal that runs out of time is said as not confirmed, and the line is drawn again until a read says")
    func aDismissalOutOfTime() async throws {
        let gate = Gate()
        let dismiss = F.post(Self.a, "/api/v1/notifications/4/dismiss")
        let (session, server, _) = try await two([dismiss: .held(gate, "{}")])
        session.noticeList.deadline = .milliseconds(50)

        let notice = try line("a4", in: session)
        let task = Task { await session.noticeList.acts.dismiss(notice, in: session) }
        #expect(await spun { await server.count(dismiss) == 1 })
        // Past the deadline, and only then does the source get round to answering.
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()
        await task.value

        #expect(await server.count(dismiss) == 1)
        #expect(ids(session.noticeList.lines) == ["a4", "b8", "a3"])
        #expect(session.said.lines.map(\.what) == [.notice(.dismiss)] && session.said.lines.map(\.why) == [.unconfirmed])
    }

    @Test("A sign-out lets go of everything said and held of that source's acts with its lines")
    func aSignOutLetsGo() async throws {
        let (session, _, _) = try await holding([F.post(Self.a, "/api/v1/notifications/4/dismiss"): .status(503)])
        let acts = session.noticeList.acts
        await acts.dismiss(try line("a4", in: session), in: session)
        #expect(session.said.lines.map(\.host) == [Self.a])

        await session.signOut(host: Self.a)

        #expect(session.said.lines.isEmpty, "a sign-out left a line about a source no longer signed in to")
        #expect(acts.said.isEmpty && acts.holdings[Self.a] == nil && acts.requests.isEmpty && acts.opened.isEmpty)
        #expect(ids(session.noticeList.lines) == ["b8"])
    }
}
