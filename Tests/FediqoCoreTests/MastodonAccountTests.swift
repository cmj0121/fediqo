import Foundation
import Testing

@testable import FediqoCore

@Suite("Home and your lists, read as you")
struct MastodonAccountTests {
    private let host = MastodonFixture.host

    private static func status(_ id: String) -> String {
        """
        {"id":"\(id)","uri":"https://social.example/users/ada/statuses/\(id)",
         "created_at":"2024-01-0\(id)T00:00:00.000Z","content":"<p>\(id)</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func timeline(_ ids: String...) -> FixtureSender.Outcome {
        .json("[" + ids.map(status).joined(separator: ",") + "]")
    }

    private static func lists(_ pairs: (String, String)...) -> FixtureSender.Outcome {
        .json("[" + pairs.map { #"{"id":"\#($0.0)","title":"\#($0.1)","replies_policy":"list"}"# }
            .joined(separator: ",") + "]")
    }

    private static let friends = ListSubscription(id: "42", name: "Friends")

    /// A store holding this host, choosing `lists`, and an account reading it through `routes`.
    private func account(
        _ routes: [String: FixtureSender.Outcome], lists: [ListSubscription] = []
    ) async throws -> (MastodonAccount, ItemStore, FixtureSender, MemoryMastodonTokens) {
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon, lists: lists))
        let server = FixtureSender(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        return (MastodonAccount(door: door, store: store), store, server, tokens)
    }

    private func categories(_ store: ItemStore) async -> [String: Set<FediqoCore.Category>] {
        Dictionary(uniqueKeysWithValues: await store.all().map { ($0.id.components(separatedBy: "/").last!, $0.categories) })
    }

    @Test("Home's posts carry Home, asked as you, forty at a time")
    func home() async throws {
        let (account, store, server, _) = try await account(["/api/v1/timelines/home": Self.timeline("1", "2")])
        #expect(try await account.read())
        #expect(await categories(store) == ["1": [.home], "2": [.home]])
        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://social.example/api/v1/timelines/home?limit=40")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(await server.paths == ["/api/v1/timelines/home"], "no list chosen, so none is asked")
    }

    @Test("A chosen list's posts carry that list; a list not chosen is never asked")
    func chosenListOnly() async throws {
        let (account, store, server, _) = try await account([
            "/api/v1/lists": Self.lists(("42", "Friends"), ("7", "Work")),
            "/api/v1/timelines/home": Self.timeline(),
            "/api/v1/timelines/list/42": Self.timeline("3"),
            "/api/v1/timelines/list/7": Self.timeline("4"),
        ], lists: [Self.friends])
        #expect(try await account.read())
        #expect(await categories(store) == ["3": [.list(id: "42")]])
        #expect(await server.paths
            == ["/api/v1/lists", "/api/v1/timelines/home", "/api/v1/timelines/list/42"])
    }

    @Test("A post in Home and in a list carries both, as one row")
    func homeAndList() async throws {
        let (account, store, _, _) = try await account([
            "/api/v1/lists": Self.lists(("42", "Friends")),
            "/api/v1/timelines/home": Self.timeline("1", "2"),
            "/api/v1/timelines/list/42": Self.timeline("2"),
        ], lists: [Self.friends])
        #expect(try await account.read())
        #expect(await categories(store) == ["1": [.home], "2": [.home, .list(id: "42")]])
    }

    @Test("A list renamed on the server is still one category, under its new name")
    func renamed() async throws {
        let (account, store, _, _) = try await account([
            "/api/v1/lists": Self.lists(("42", "Pals")),
            "/api/v1/timelines/home": Self.timeline(),
            "/api/v1/timelines/list/42": Self.timeline("5"),
        ], lists: [Self.friends])
        await store.ingest([Note(
            id: "https://social.example/users/ada/statuses/5", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@social.example", body: "5",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.list(id: "42")]
        )])
        #expect(try await account.read())
        #expect(await store.sources().first?.lists == [ListSubscription(id: "42", name: "Pals")])
        #expect(await categories(store) == ["5": [.list(id: "42")]])
    }

    @Test("A list the server no longer names keeps its choice and its label")
    func listGoneKeepsLabel() async throws {
        let (account, store, _, _) = try await account([
            "/api/v1/lists": Self.lists(),
            "/api/v1/timelines/home": Self.timeline(),
            "/api/v1/timelines/list/42": .json("{}", status: 404),
        ], lists: [Self.friends])
        #expect(try await account.read() == false)
        #expect(await store.sources().first?.lists == [Self.friends])
    }

    @Test("Home refused is one read lost, not the lists; the answer says not everything came")
    func homeFails() async throws {
        let (account, store, _, tokens) = try await account([
            "/api/v1/lists": Self.lists(("42", "Friends")),
            "/api/v1/timelines/home": .json("{}", status: 500),
            "/api/v1/timelines/list/42": Self.timeline("3"),
        ], lists: [Self.friends])
        #expect(try await account.read() == false)
        #expect(await categories(store) == ["3": [.list(id: "42")]])
        #expect(try tokens.signedInHosts() == [host])
    }

    @Test("A 401 on Home that the server confirms ends the read signed out, and nothing lands")
    func signedOutOnHome() async throws {
        let (account, store, server, tokens) = try await account([
            "/api/v1/timelines/home": .json("{}", status: 401),
            "/api/v1/accounts/verify_credentials": .json("{}", status: 401),
            "/api/v1/lists": Self.lists(("42", "Friends")),
            "/api/v1/timelines/list/42": Self.timeline("3"),
        ], lists: [Self.friends])
        await #expect(throws: MastodonAuthError.signedOut) { _ = try await account.read() }
        #expect(try tokens.signedInHosts().isEmpty)
        #expect(await store.all().isEmpty)
        #expect(!(await server.paths.contains("/api/v1/timelines/list/42")))
    }

    @Test("A reload asks only what it names: one chosen list, and neither Home nor the list names")
    func reloadAsksWhatItNames() async throws {
        let work = ListSubscription(id: "7", name: "Work")
        let (account, store, server, _) = try await account([
            "/api/v1/lists": Self.lists(("42", "Friends"), ("7", "Work")),
            "/api/v1/timelines/home": Self.timeline("1"),
            "/api/v1/timelines/list/42": Self.timeline("3"),
            "/api/v1/timelines/list/7": Self.timeline("4"),
        ], lists: [Self.friends, work])
        #expect(try await account.read(home: false, lists: ["42", "99"]))
        #expect(await categories(store) == ["3": [.list(id: "42")]])
        #expect(await server.paths == ["/api/v1/timelines/list/42"], "99 is not chosen, so it asks nothing")
    }

    @Test("A reload of Home alone asks Home alone; a failed read says not everything came")
    func reloadHomeAlone() async throws {
        let (account, store, server, _) = try await account([
            "/api/v1/timelines/home": Self.timeline("1"),
        ], lists: [Self.friends])
        #expect(try await account.read(home: true, lists: []))
        #expect(await categories(store) == ["1": [.home]])
        #expect(await server.paths == ["/api/v1/timelines/home"])

        let (failing, _, _, _) = try await self.account([
            "/api/v1/timelines/home": .json("{}", status: 500),
        ])
        #expect(try await failing.read(home: true, lists: []) == false)
    }

    @Test("Choosing lists keeps the choice and reads only the lists not chosen before")
    func choose() async throws {
        let (account, store, server, _) = try await account([
            "/api/v1/timelines/list/42": Self.timeline("3"),
            "/api/v1/timelines/list/7": Self.timeline("4"),
        ], lists: [Self.friends])
        let work = ListSubscription(id: "7", name: "Work")
        #expect(try await account.choose([Self.friends, work]))
        #expect(await store.sources().first?.lists == [Self.friends, work])
        #expect(await server.paths == ["/api/v1/timelines/list/7"])
        #expect(await categories(store) == ["4": [.list(id: "7")]])
    }

    @Test("Unchoosing a list stops it being read and takes nothing from what it brought")
    func unchoose() async throws {
        let (account, store, server, _) = try await account([
            "/api/v1/timelines/home": Self.timeline(),
            "/api/v1/lists": Self.lists(("42", "Friends")),
            "/api/v1/timelines/list/42": Self.timeline("3"),
        ], lists: [Self.friends])
        #expect(try await account.read())
        #expect(try await account.choose([]))
        #expect(await store.sources().first?.lists == [])
        #expect(await categories(store) == ["3": [.list(id: "42")]])
        #expect(try await account.read())
        #expect(await server.paths.filter { $0 == "/api/v1/timelines/list/42" }.count == 1)
    }

    @Test("The lists offered are the server's, and an id that is not one path segment is dropped")
    func listsOffered() async throws {
        let (account, _, _, _) = try await account([
            "/api/v1/lists": Self.lists(("42", "Friends"), ("../x", "Odd"), ("", "Empty")),
        ])
        #expect(try await account.lists() == [Self.friends])
    }

    @Test("A source removed while its reads were out gets none of them")
    func removedMeanwhile() async throws {
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let host = host
        let server = HookedSender(["/api/v1/timelines/home": "[" + Self.status("1") + "]"]) { _ in
            await store.remove(host: host)
        }
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        #expect(try await MastodonAccount(door: door, store: store).read())
        #expect(await store.all().isEmpty)
        #expect(await store.sources().isEmpty)
    }

    @Test("Posts go in only while their source is here, in one step")
    func ingestIfSourceHere() async {
        let store = ItemStore()
        let note = Note(
            id: "1", source: Source(host: host, kind: .mastodon), author: "Ada", handle: "@ada",
            body: "x", postedAt: Date(timeIntervalSince1970: 0), categories: [.home]
        )
        await store.ingest([note], ifSourceHere: host)
        #expect(await store.all().isEmpty)
        await store.add(Source(host: host, kind: .mastodon))
        await store.ingest([note], ifSourceHere: "SOCIAL.example")
        #expect(await store.all() == [note])
    }

    @Test("A picker's Done landing while the names are on the wire is kept, and relabelled")
    func doneDuringRelabel() async throws {
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon, lists: [Self.friends]))
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let work = ListSubscription(id: "7", name: "Work")
        let host = host
        let server = HookedSender([
            "/api/v1/lists": #"[{"id":"42","title":"Pals"},{"id":"7","title":"Office"}]"#,
            "/api/v1/timelines/home": "[]",
            "/api/v1/timelines/list/42": "[]",
        ]) { path in
            if path == "/api/v1/lists" { await store.subscribe(host: host, toLists: [Self.friends, work]) }
        }
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        #expect(try await MastodonAccount(door: door, store: store).read())
        #expect(await store.sources().first?.lists == [
            ListSubscription(id: "42", name: "Pals"), ListSubscription(id: "7", name: "Office"),
        ])
    }

    @Test("Relabelling renames only lists held now, and adds none")
    func relabelOnlyHeld() async {
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon, lists: [Self.friends]))
        await store.relabel(host: host, lists: ["42": "Pals", "7": "Work"])
        #expect(await store.sources().first?.lists == [ListSubscription(id: "42", name: "Pals")])
        let revision = await store.revision
        await store.relabel(host: host, lists: ["42": "Pals"])
        #expect(await store.revision == revision, "an unchanged label counted as a change")
    }

    @Test("A list id that is not one path segment, however it got into the store, is never asked")
    func tamperedID() async throws {
        let (account, _, server, _) = try await account([
            "/api/v1/lists": Self.lists(("42", "Friends")),
            "/api/v1/timelines/home": Self.timeline(),
            "/api/v1/timelines/list/42": Self.timeline("3"),
        ], lists: [ListSubscription(id: "../../accounts/1", name: "x"), Self.friends])
        #expect(try await account.read())
        #expect(await server.paths
            == ["/api/v1/lists", "/api/v1/timelines/home", "/api/v1/timelines/list/42"])
        #expect(!ListSubscription.isPathSegment("../x"))
        #expect(!ListSubscription.isPathSegment(""))
        #expect(!ListSubscription.isPathSegment("4%2F2"))
        #expect(ListSubscription.isPathSegment("42"))
    }

    @Test("Choosing lists changes no board, and choosing boards changes no list")
    func listsAndBoardsApart() async {
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon, lists: [Self.friends]))
        await store.subscribe(host: host, to: [BoardSubscription(fid: 1, name: "b")])
        #expect(await store.sources().first?.lists == [Self.friends])
        await store.subscribe(host: host, toLists: [])
        #expect(await store.sources().first?.boards == [BoardSubscription(fid: 1, name: "b")])
    }

    @Test("A source holds one choice per list id")
    func onePerList() {
        let source = Source(host: host, kind: .mastodon, lists: [
            Self.friends, ListSubscription(id: "42", name: "Pals"),
        ])
        #expect(source.lists == [Self.friends])
    }
}

/// Answers by path, running `meanwhile` before it answers — something the reader does while the
/// read is on the wire. Remembers every path asked.
private actor HookedSender: HTTPSender {
    let bodies: [String: String]
    let meanwhile: @Sendable (String) async -> Void
    private(set) var paths: [String] = []

    init(_ bodies: [String: String], meanwhile: @escaping @Sendable (String) async -> Void) {
        self.bodies = bodies
        self.meanwhile = meanwhile
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        paths.append(path)
        await meanwhile(path)
        guard let body = bodies[path] else { throw FixtureHTTPError.unmapped }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}
