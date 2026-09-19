import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Mastodon answering by path, remembering every path asked. Each path answers from its list in
/// turn and keeps giving the last answer — a check that says yes at sign-in and no later.
private actor Server: HTTPSender {
    private var routes: [String: [Outcome]]
    /// Paths held until the test opens their gate, so a press can be caught mid-read.
    private let gates: [String: Gate]
    private(set) var paths: [String] = []

    enum Outcome: Sendable {
        case json(String, status: Int = 200)
    }

    init(_ overrides: [String: [Outcome]] = [:], gates: [String: Gate] = [:]) {
        self.gates = gates
        routes = [
            "/api/v1/apps": [.json(#"{"client_id":"cid","client_secret":"csecret"}"#)],
            "/oauth/token": [.json(#"{"access_token":"tok-123"}"#)],
            "/api/v1/accounts/verify_credentials": [.json(#"{"id":"1"}"#)],
            "/oauth/revoke": [.json("{}")],
            "/api/v1/timelines/home": [.json(timeline("1", "2"))],
        ].merging(overrides) { $1 }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, var answers = routes[url.path] else {
            throw FixtureHTTPError.unmapped
        }
        paths.append(url.path)
        await gates[url.path]?.wait()
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        routes[url.path] = answers
        switch answer {
        case .json(let body, let status):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }
}

private func status(_ id: String) -> String {
    """
    {"id":"\(id)","uri":"https://social.example/users/ada/statuses/\(id)",
     "created_at":"2024-01-0\(id)T00:00:00.000Z","content":"<p>\(id)</p>",
     "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
    """
}

private func timeline(_ ids: String...) -> String {
    "[" + ids.map(status).joined(separator: ",") + "]"
}

private func lists(_ pairs: (String, String)...) -> String {
    "[" + pairs.map { #"{"id":"\#($0.0)","title":"\#($0.1)"}"# }.joined(separator: ",") + "]"
}

/// The server's page, approving with the state it was sent.
@MainActor
private final class Approve: OAuthBrowser {
    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }
}

@MainActor
@Suite("Home and your lists")
struct ListChoiceTests {
    private let host = "social.example"
    private static let friends = ListSubscription(id: "42", name: "Friends")

    private var token: MastodonToken {
        MastodonToken(host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret")
    }

    /// A session holding this Mastodon, choosing `lists`, and signed in where `signedIn`.
    private func shell(
        _ overrides: [String: [Server.Outcome]] = [:],
        lists: [ListSubscription] = [],
        signedIn: Bool = true,
        gates: [String: Gate] = [:]
    ) async throws -> (ShellSession, Server, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if signedIn { try tokens.save(token) }
        let server = Server(overrides, gates: gates)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(),
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        await session.store.add(Source(host: host, kind: .mastodon, lists: lists))
        session.sources = await session.store.sources()
        return (session, server, tokens)
    }

    private func categories(_ session: ShellSession) -> [String: Set<FediqoCore.Category>] {
        Dictionary(uniqueKeysWithValues: session.notes.map {
            ($0.id.components(separatedBy: "/").last!, $0.categories)
        })
    }

    // MARK: - Home

    @Test("Signing in reads Home, and its posts carry Home")
    func signInReadsHome() async throws {
        let (session, server, _) = try await shell(signedIn: false)
        await session.signIn(host: host, through: Approve())
        #expect(session.isSignedIn(host: host))
        #expect(categories(session) == ["1": [.home], "2": [.home]])
        #expect(await server.paths.last == "/api/v1/timelines/home")
        #expect(await !server.paths.contains("/api/v1/lists"), "no list is chosen, so none is asked")
        #expect(session.rowRefusal == nil)
        #expect(session.progress == nil)
    }

    @Test("A source never signed in asks for neither Home nor lists, and offers no lists")
    func neverSignedIn() async throws {
        let (session, server, _) = try await shell(signedIn: false)
        await session.readAsYou(host: host)
        await session.changeLists(host: host)
        #expect(await server.paths.isEmpty)
        #expect(session.stage == nil)
        let row = try #require(session.rows.first)
        #expect(!row.signedIn)
        #expect(SourceRow.controls(of: row.source, signedIn: row.signedIn) == [.signIn, .clear, .remove])
    }

    @Test("A 401 on Home the server confirms signs the row out and says so once")
    func endedOnHome() async throws {
        let (session, _, tokens) = try await shell([
            "/api/v1/timelines/home": [.json("{}", status: 401)],
            "/api/v1/accounts/verify_credentials": [.json("{}", status: 401)],
        ])
        #expect(session.isSignedIn(host: host))
        await session.readAsYou(host: host)
        #expect(!session.isSignedIn(host: host))
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(session.mastodon.ended == [host])
        #expect(session.notes.isEmpty)
    }

    @Test("A read that did not all come back is one sentence under the row")
    func partial() async throws {
        let (session, _, _) = try await shell(["/api/v1/timelines/home": [.json("{}", status: 500)]])
        await session.readAsYou(host: host)
        #expect(session.rowRefusal?.host == host)
        #expect(session.rowRefusal?.key == "account.mastodon.read.partial")
        #expect(session.isSignedIn(host: host), "a 500 is not a sign-out")
    }

    @Test("Signing out keeps what Home and the lists brought in, and the lists chosen")
    func signOutKeeps() async throws {
        let (session, _, tokens) = try await shell([
            "/api/v1/lists": [.json(lists(("42", "Friends")))],
            "/api/v1/timelines/list/42": [.json(timeline("3"))],
        ], lists: [Self.friends])
        await session.readAsYou(host: host)
        await session.signOut(host: host)
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(categories(session) == ["1": [.home], "2": [.home], "3": [.list(id: "42")]])
        #expect(await session.store.all().count == 3)
        #expect(session.sources.first?.lists == [Self.friends])
    }

    // MARK: - Stopping a read

    enum Stop: String, CaseIterable, Sendable { case signOut, clear, remove }

    @Test("A read stopped by a sign-out, a Clear or a Remove brings nothing back", arguments: Stop.allCases)
    func stopped(by stop: Stop) async throws {
        let gate = Gate()
        let (session, server, _) = try await shell(gates: ["/api/v1/timelines/home": gate])
        let reading = Task { await session.readAsYou(host: host) }
        #expect(await spun { await server.paths.contains("/api/v1/timelines/home") })
        switch stop {
        case .signOut: await session.signOut(host: host)
        case .clear: await session.clear(host: host)
        case .remove: await session.remove(host: host)
        }
        await gate.open()
        await reading.value
        #expect(await session.store.all().isEmpty, "Home's posts landed after the \(stop)")
        #expect(session.notes.isEmpty)
        #expect(session.rowRefusal == nil)
        #expect(session.progress == nil)
        #expect(await session.store.sources().count == (stop == .remove ? 0 : 1))
    }

    @Test("A read finishing while another row reads its lists leaves that row's line alone")
    func progressApart() async throws {
        let gate = Gate()
        let other = "other.example"
        let (session, server, tokens) = try await shell(
            ["/api/v1/lists": [.json(lists(("7", "Work")))]], gates: ["/api/v1/lists": gate]
        )
        try tokens.save(MastodonToken(host: other, accessToken: "t2", clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
        await session.store.add(Source(host: other, kind: .mastodon))
        session.sources = await session.store.sources()

        let choosing = Task { await session.changeLists(host: other) }
        #expect(await spun { await server.paths.contains("/api/v1/lists") })
        let theirs = session.progress
        #expect(theirs?.owner == .row(host: other))
        await session.readAsYou(host: host)
        #expect(session.progress == theirs, "the Home read took or cleared the other row's line")
        #expect(categories(session) == ["1": [.home], "2": [.home]])
        await gate.open()
        await choosing.value
        #expect(session.progress == nil)
        if case .choosingLists(let choice) = session.stage { #expect(choice.host == other) } else {
            Issue.record("the other row's picker did not open")
        }
    }

    // MARK: - Choosing lists

    @Test("A signed-in Mastodon row carries the lists control, bound to Sign in")
    func control() async throws {
        let (session, _, _) = try await shell()
        let row = try #require(session.rows.first)
        #expect(row.signedIn)
        let controls = SourceRow.controls(of: row.source, signedIn: true)
        #expect(controls == [.signIn, .lists, .clear, .remove])
        #expect(SourceRow.widest(session.rows) == controls, "the list's threshold missed the lists control")
        #expect(SourceRow.controlLine(controls)
            == SourceRow.controlLine([.signIn, .boards, .clear, .remove]))
        for kind in ProtocolKind.allCases {
            #expect(SourceRow.canChooseLists(kind) == (kind == .mastodon), "\(kind)")
        }
    }

    @Test("The picker opens with the server's lists, ticked from what is chosen and still there")
    func opens() async throws {
        let gone = ListSubscription(id: "9", name: "Gone")
        let (session, server, _) = try await shell([
            "/api/v1/lists": [.json(lists(("42", "Pals"), ("7", "Work")))],
        ], lists: [Self.friends, gone])
        await session.changeLists(host: host)
        guard case .choosingLists(let choice) = session.stage else {
            Issue.record("no picker: \(String(describing: session.stage))")
            return
        }
        #expect(choice.host == host)
        #expect(choice.offered == [
            ListSubscription(id: "42", name: "Pals"), ListSubscription(id: "7", name: "Work"),
        ])
        #expect(choice.ticked == ["42"])
        #expect(await server.paths == ["/api/v1/lists"])
        #expect(session.stage?.surface == .sheet)
        #expect(JoinSheet.leading(for: session.stage) == .cancel)
        #expect(session.stage?.closesWhenTheWindowLeaves == true)
        #expect(session.stage?.host == host)
        #expect(session.progress == nil)
    }

    @Test("Done keeps the pick and reads only the lists newly chosen; an unchosen one is never read")
    func done() async throws {
        let (session, server, _) = try await shell([
            "/api/v1/lists": [.json(lists(("42", "Friends"), ("7", "Work"), ("8", "Other")))],
            "/api/v1/timelines/list/42": [.json(timeline("3"))],
            "/api/v1/timelines/list/7": [.json(timeline("2", "4"))],
            "/api/v1/timelines/list/8": [.json(timeline("5"))],
        ], lists: [Self.friends])
        await session.readAsYou(host: host)
        await session.changeLists(host: host)
        guard case .choosingLists(var choice) = session.stage else {
            Issue.record("no picker")
            return
        }
        choice.ticked.insert("7")
        session.stage = .choosingLists(choice)
        await session.chooseLists(choice.picks)

        #expect(session.stage == nil)
        #expect(session.sources.first?.lists == [Self.friends, ListSubscription(id: "7", name: "Work")])
        #expect(categories(session) == [
            "1": [.home], "2": [.home, .list(id: "7")], "3": [.list(id: "42")], "4": [.list(id: "7")],
        ])
        let paths = await server.paths
        #expect(paths.filter { $0 == "/api/v1/timelines/list/42" }.count == 1, "a kept list was read again")
        #expect(!paths.contains("/api/v1/timelines/list/8"))
        #expect(session.rowRefusal == nil)
    }

    @Test("Cancel on the picker changes nothing")
    func cancel() async throws {
        let (session, _, _) = try await shell(
            ["/api/v1/lists": [.json(lists(("7", "Work")))]], lists: [Self.friends]
        )
        await session.changeLists(host: host)
        JoinSheet.press(.cancel, on: session)
        #expect(session.stage == nil)
        #expect(session.sources.first?.lists == [Self.friends])
    }

    @Test("A list renamed on the server is relabelled, and stays one category")
    func renamed() async throws {
        let (session, _, _) = try await shell([
            "/api/v1/lists": [.json(lists(("42", "Pals")))],
            "/api/v1/timelines/list/42": [.json(timeline("3"))],
        ], lists: [Self.friends])
        await session.readAsYou(host: host)
        #expect(session.sources.first?.lists == [ListSubscription(id: "42", name: "Pals")])
        #expect(categories(session)["3"] == [.list(id: "42")])
    }

    @Test("Lists that could not be read are one sentence under the row, and no picker")
    func unread() async throws {
        let (session, _, _) = try await shell(["/api/v1/lists": [.json("{}", status: 500)]])
        await session.changeLists(host: host)
        #expect(session.stage == nil)
        #expect(session.rowRefusal?.key == "account.source.lists.unread")
    }

    @Test("Every sentence the lists say is in every language")
    func sentences() {
        let keys = [
            "account.mastodon.home.progress", "account.mastodon.read.partial",
            "account.source.lists.change", "account.source.lists.progress",
            "account.source.lists.reading", "account.source.lists.unread",
            "list.choose.title", "list.choose.detail", "list.choose.none", "list.choose.done",
            "list.choose.hint.on", "list.choose.hint.off",
        ]
        for key in keys {
            for language in DummyLanguage.allCases {
                let said = L10n.t(key, language: language)
                #expect(said != key && !said.isEmpty, "\(key) is missing in \(language)")
            }
        }
    }
}
