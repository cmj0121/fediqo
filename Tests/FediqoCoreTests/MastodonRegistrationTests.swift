import Foundation
import Testing
@testable import FediqoCore

/// A host answering one ask with whatever the test hands it — the address it says it answered
/// from included, which a path-keyed fixture cannot say.
private actor OneAnswer: HTTPSender {
    private let body: Data
    private let status: Int
    private let from: URL?
    private(set) var requests: [URLRequest] = []

    init(_ body: Data, status: Int = 200, from: URL? = nil) {
        self.body = body
        self.status = status
        self.from = from
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = from ?? request.url!
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// One registration for every word a sign-in may be asked for (#347), in the half of it Core
/// holds: what is registered for, what a host's own list takes from it, what a registration's
/// answer is believed of, and what a page may ask on one. What `MastodonSessions` does with
/// them is `MastodonRegisteringTests`' in the UI suite.
@Suite("What this app registers for at a Mastodon")
struct MastodonRegistrationTests {
    private let host = MastodonFixture.host
    private static let whole = "read:statuses read:lists read:accounts read:search write:statuses write:favourites "
        + "write:bookmarks read:notifications write:notifications read:follows write:follows write:accounts write:media "
        + "read:bookmarks read:favourites read:mutes write:mutes read:blocks write:blocks write:reports admin:read admin:write"

    private static func list(_ words: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["scopes_supported": words])
    }

    private var words: [String] { Self.whole.split(separator: " ").map(String.init) }

    // MARK: - What is registered for

    @Test("The registration is for every word of every part, in the table's order, and a page for each sign-in choice is one it holds")
    func everyWord() {
        #expect(MastodonRegistration.superset() == Self.whole)
        #expect(MastodonParts.everything == Self.whole)
        for writing in [false, true] {
            for notices in [false, true] {
                let chosen = MastodonOAuth.scopes(writing: writing, notices: notices)
                #expect(MastodonRegistration.holds(chosen, on: Self.whole))
                #expect(MastodonRegistration.page(chosen, on: Self.whole) == chosen, "the registration is wider; the page is not")
            }
        }
    }

    @Test("The host's own list only takes away: a word it lacks is left out, a word it adds is never asked for, and the order is the table's")
    func lessTheList() throws {
        let real = try #require(MastodonRegistration.listed(in: Data(MastodonSignInCaptures.wordList.utf8)))
        #expect(real.count == 47)
        #expect(MastodonRegistration.superset(listed: real) == Self.whole, "a 4.6 knows every word asked")

        let without: Set<String> = Set(words).subtracting(["write:bookmarks", "read:search"])
        #expect(MastodonRegistration.superset(listed: without)
            == "read:statuses read:lists read:accounts write:statuses write:favourites read:notifications write:notifications read:follows write:follows write:accounts write:media "
               + "read:bookmarks read:favourites read:mutes write:mutes read:blocks write:blocks write:reports admin:read admin:write")
        let larger = Set(words).union(["admin:read:reports", "follow", "push", "read", "write"])
        #expect(MastodonRegistration.superset(listed: larger) == Self.whole)
        #expect(MastodonRegistration.superset(listed: nil) == Self.whole, "no list: asked as it is")
    }

    // MARK: - The host's list, read as a stranger's writing

    @Test("A list is read out of the one name it is under; entries that are not words are passed over")
    func theListIsReadLeniently() {
        let odd: [Any] = [1, ["read:lists"], NSNull(), "", "two words", "quo\"te", "back\\slash", "ünïcode", String(repeating: "a", count: 65)]
        let mixed: [Any] = words + odd
        let body = try! JSONSerialization.data(withJSONObject: ["scopes_supported": mixed, "other": ["x": 1]])
        #expect(MastodonRegistration.listed(in: body) == Set(words))
        let longest = String(repeating: "a", count: 64)
        #expect(MastodonRegistration.listed(in: Self.list(words + [longest]))?.contains(longest) == true)
    }

    @Test("What is not a list is no list", arguments: [
        "", "[]", "null", "\"read:statuses\"", "{}", "{\"scopes_supported\":\"read:statuses read:lists read:accounts\"}",
        "{\"scopes_supported\":{\"read:statuses\":true}}", "{\"scopes_supported\":7}", "{\"scopes_supported\":[]}",
        "{\"scopes\":[\"read:statuses\",\"read:lists\",\"read:accounts\"]}", "<html>Not Found</html>", "{\"scopes_supported\":[",
    ])
    func garbage(body: String) {
        #expect(MastodonRegistration.listed(in: Data(body.utf8)) == nil)
    }

    @Test("A list too long, or in a body too large, is no list at all — never one cut short")
    func oversized() {
        let filler = (0..<(MastodonRegistration.listWords - words.count)).map { "x:\($0)" }
        #expect(MastodonRegistration.listed(in: Self.list(words + filler)) != nil, "the most that is read")
        #expect(MastodonRegistration.listed(in: Self.list(words + filler + ["one:more"])) == nil)

        var padded = Self.list(words)
        padded.append(Data(repeating: 0x20, count: MastodonRegistration.listBytes - padded.count))
        #expect(MastodonRegistration.listed(in: padded) != nil)
        padded.append(0x20)
        #expect(MastodonRegistration.listed(in: padded) == nil)
    }

    @Test("A list without the words every sign-in is asked for is not believed: the host's own answer to the registration says, not it")
    func aListThatIsNotOurs() {
        #expect(MastodonRegistration.listed(in: Self.list(["openid", "profile", "email"])) == nil)
        #expect(MastodonRegistration.listed(in: Self.list(["read", "write", "follow", "push"])) == nil)
        #expect(MastodonRegistration.listed(in: Self.list(words.filter { $0 != "read:accounts" })) == nil)
        #expect(MastodonRegistration.listed(in: Self.list(MastodonPart.reading.words)) == Set(MastodonPart.reading.words))
    }

    // MARK: - Asking for the list

    @Test("The list is asked at the one address, of the host alone, with no sign-in")
    func asked() async throws {
        let server = OneAnswer(Data(MastodonSignInCaptures.wordList.utf8))
        let listed = await MastodonOAuth(host: host, sender: server).listedWords()
        #expect(listed?.count == 47)
        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://\(host)\(MastodonSignInCaptures.wordListPath)")
        #expect((request.httpMethod ?? "GET") == "GET" && request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(await server.requests.count == 1)
    }

    @Test("A host that answers anything but the list has no list", arguments: [404, 204, 301, 302, 401, 429, 500])
    func notAnswered(status: Int) async {
        let server = OneAnswer(Data(MastodonSignInCaptures.wordList.utf8), status: status)
        #expect(await MastodonOAuth(host: host, sender: server).listedWords() == nil)
    }

    @Test("A list that came from anywhere but the host asked is no list", arguments: [
        "https://elsewhere.example/.well-known/oauth-authorization-server",
        "http://social.example/.well-known/oauth-authorization-server",
        "https://social.example:8443/.well-known/oauth-authorization-server",
        "https://social.example.elsewhere.example/.well-known/oauth-authorization-server",
    ])
    func sentElsewhere(from: String) async {
        let server = OneAnswer(Data(MastodonSignInCaptures.wordList.utf8), from: URL(string: from)!)
        #expect(await MastodonOAuth(host: host, sender: server).listedWords() == nil)
    }

    @Test("A host that cannot be reached has no list, and that is no failure")
    func unreachable() async {
        let server = FixtureSender([MastodonSignInCaptures.wordListPath: .fail])
        #expect(await MastodonOAuth(host: host, sender: server).listedWords() == nil)
        #expect(await MastodonOAuth(host: host, sender: FixtureSender([:])).listedWords() == nil)
    }

    @Test("A document that names other addresses moves none: the registration, the page, the trade and the check go where they went")
    func theDocumentMovesNoAddress() async throws {
        let named: [String: Any] = [
            "issuer": "https://evil.example/", "authorization_endpoint": "https://evil.example/oauth/authorize",
            "token_endpoint": "https://evil.example/oauth/token", "revocation_endpoint": "https://evil.example/oauth/revoke",
            "app_registration_endpoint": "https://evil.example/api/v1/apps", "scopes_supported": words,
        ]
        let evil = String(decoding: try JSONSerialization.data(withJSONObject: named), as: UTF8.self)
        let server = FixtureSender([
            MastodonSignInCaptures.wordListPath: .json(evil), "/api/v1/apps": .json(MastodonFixture.apps),
            "/oauth/token": .json(MastodonFixture.issued), "/api/v1/accounts/verify_credentials": .json(MastodonFixture.me),
            "/oauth/revoke": .json("{}"),
        ])
        let oauth = MastodonOAuth(host: host, sender: server)
        let listed = try #require(await oauth.listedWords())
        #expect(listed == Set(words))
        let app = try await oauth.register(scopes: MastodonRegistration.superset(listed: listed))
        let browser = await FixtureBrowser.approving()
        let signed = try await oauth.signIn(as: app, asking: MastodonOAuth.reading, through: browser)
        await oauth.revoke(MastodonLeft(signed.token, as: .left))
        let page = try #require(await browser.opened.first)
        #expect(page.host() == host && page.path == "/oauth/authorize")
        #expect(await server.requests.allSatisfy { $0.url?.host() == host && $0.url?.scheme == "https" })
        #expect(await server.paths == [
            MastodonSignInCaptures.wordListPath, "/api/v1/apps", "/oauth/token", "/api/v1/accounts/verify_credentials", "/oauth/revoke",
        ])
    }

    @Test("Nothing that signs in reads an address or an issuer out of a host's document")
    func noAddressIsRead() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var read = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            for name in ["_endpoint", "issuer"] {
                #expect(!text.contains(name), "\(file.lastPathComponent) names \(name)")
            }
            // The list's address is spelt in one place, and so is the one name read under it.
            if file.lastPathComponent != "MastodonRegistration.swift" {
                #expect(!text.contains(".well-known/oauth") && !text.contains("scopes_supported"), "\(file.lastPathComponent)")
            }
        }
        #expect(read > 100, "the sources were not found")
        #expect(MastodonRegistration.listPath == MastodonSignInCaptures.wordListPath)
    }

    // MARK: - What a registration's answer is believed of

    @Test("A registration records what was asked and the server named, in the order asked — never a word more")
    func theEcho() async throws {
        func registered(_ answer: String, for scopes: String) async throws -> (app: MastodonApp, echoed: Bool) {
            try await MastodonOAuth(host: host, sender: FixtureSender(["/api/v1/apps": .json(answer)])).registered(for: scopes)
        }
        let real = MastodonSignInCaptures.widestRegistration
        let all = try await registered(real, for: MastodonSignInCaptures.everyPart)
        #expect(all.app.scopes == MastodonSignInCaptures.everyPart && all.echoed)
        // Asked for more than that answer named — tending's two words, which came after it — the
        // registration is believed of what both said: the answer named neither.
        let ours = try await registered(real, for: Self.whole)
        #expect(ours.app.scopes == Self.whole.replacingOccurrences(of: " admin:read admin:write", with: ""))

        let narrower = #"{"client_id":"cid","client_secret":"cs","scopes":["write:statuses","read:statuses","admin:write"]}"#
        let less = try await registered(narrower, for: Self.whole)
        #expect(less.app.scopes == "read:statuses write:statuses admin:write" && less.echoed)
        let asString = #"{"client_id":"cid","client_secret":"cs","scopes":"read:lists  read:statuses","redirect_uri":"fediqo://oauth"}"#
        #expect(try await registered(asString, for: Self.whole).app.scopes == "read:statuses read:lists")

        for silent in [MastodonFixture.apps, #"{"client_id":"cid","client_secret":"cs","scopes":[]}"#,
                       #"{"client_id":"cid","client_secret":"cs","scopes":7,"redirect_uris":null}"#] {
            let unsaid = try await registered(silent, for: Self.whole)
            #expect(unsaid.app.scopes == Self.whole && !unsaid.echoed, "a server that names none leaves what was asked standing")
        }
    }

    @Test("A registration naming a callback that is not this app's is refused, and nothing is handed back", arguments: [
        #""redirect_uri":"https://evil.example/cb""#, #""redirect_uris":["fediqo://oauth","https://evil.example/cb"]"#,
        #""redirect_uri":"fediqo://oauth\nhttps://evil.example/cb""#, #""redirect_uri":"fediqo://oauth","redirect_uris":["fediqo://other"]"#,
    ])
    func anotherCallback(named: String) async {
        let server = FixtureSender(["/api/v1/apps": .json(#"{"client_id":"cid","client_secret":"cs",\#(named)}"#)])
        await #expect(throws: MastodonSignInError.unreadable) {
            _ = try await MastodonOAuth(host: host, sender: server).registered(for: Self.whole)
        }
    }

    @Test("A registration answered with no client id or secret, or one longer than any is, is a registration that failed", arguments: [
        ("", "cs"), ("cid", ""), (String(repeating: "c", count: 513), "cs"), ("cid", String(repeating: "s", count: 513)),
    ])
    func noClient(id: String, secret: String) async {
        let answer = #"{"client_id":"\#(id)","client_secret":"\#(secret)","redirect_uri":"fediqo://oauth"}"#
        await #expect(throws: MastodonSignInError.unreadable) {
            _ = try await MastodonOAuth(host: host, sender: FixtureSender(["/api/v1/apps": .json(answer)])).registered(for: Self.whole)
        }
    }

    @Test("A client id and secret as long as one may be are taken")
    func theLongestClient() async throws {
        let longest = String(repeating: "c", count: MastodonOAuth.clientBytes)
        let answer = #"{"client_id":"\#(longest)","client_secret":"\#(longest)"}"#
        let made = try await MastodonOAuth(host: host, sender: FixtureSender(["/api/v1/apps": .json(answer)])).registered(for: Self.whole)
        #expect(made.app.clientID == longest)
        #expect(made.app.clientSecret == longest)
    }

    // MARK: - What a page asks

    @Test("What a sign-in is written down as having asked is its page's words and those the host itself has none of — never one only left off the page")
    func whatWasAsked() {
        let chosen = MastodonOAuth.scopes(writing: true)
        let least = MastodonOAuth.scopes(search: false, writing: true, bookmarks: false)
        #expect(MastodonRegistration.asked(chosen, on: chosen) { _ in false } == chosen)
        #expect(MastodonRegistration.asked(chosen, on: least) { _ in false } == least)
        let search = MastodonPart.search.words[0]
        #expect(MastodonRegistration.asked(chosen, on: least) { $0 == search } == MastodonOAuth.scopes(writing: true, bookmarks: false))
        #expect(MastodonRegistration.asked(chosen, on: least) { _ in true } == chosen)
        // Never a word the answer did not choose, whatever the host lacks or the page named.
        #expect(MastodonRegistration.asked(MastodonOAuth.reading, on: chosen) { _ in true } == MastodonOAuth.reading)
    }

    @Test("A sign-in held keeps every word of it that the answer asks; a word the answer does not ask was given up by choosing")
    func whatIsKeptOfHeld() {
        let acting = MastodonOAuth.scopes(writing: true)
        let least = MastodonOAuth.scopes(search: false, writing: true, bookmarks: false)
        #expect(MastodonRegistration.keeps(acting, asking: acting, in: acting))
        #expect(!MastodonRegistration.keeps(acting, asking: acting, in: least))
        #expect(MastodonRegistration.keeps(least, asking: acting, in: least), "a sign-in held without them loses nothing by a page without them")
        #expect(MastodonRegistration.keeps(acting, asking: MastodonOAuth.reading, in: MastodonOAuth.reading), "reading alone is the person's own choice of less")
        #expect(!MastodonRegistration.keeps(acting, asking: MastodonOAuth.reading, in: MastodonOAuth.readingWithoutSearch))
        #expect(MastodonRegistration.keeps(nil, asking: acting, in: least) && MastodonRegistration.keeps("", asking: acting, in: nil))
        #expect(!MastodonRegistration.keeps(acting, asking: acting, in: nil))
    }

    @Test("A page asks for less than its registration was made for, and the trade and the record say what the page asked")
    func aPageForLess() async throws {
        let server = MastodonFixture.server()
        let oauth = MastodonOAuth(host: host, sender: server)
        let app = try await oauth.register(scopes: Self.whole)
        let browser = await FixtureBrowser.approving()
        let token = try await oauth.signIn(as: app, asking: MastodonOAuth.reading, through: browser).token
        let page = try #require(await browser.opened.first)
        #expect(FixtureBrowser.query(page, "scope") == MastodonOAuth.reading)
        #expect(await server.form("/oauth/token")["scope"] == MastodonOAuth.reading)
        #expect(token.scopes == MastodonOAuth.reading && token.asked == MastodonOAuth.reading)
        #expect(token.grant == .reading, "a wide registration made a wide sign-in")
    }

    @Test("A page naming a word its registration does not hold is never opened", arguments: [
        MastodonOAuth.reading, "read:statuses", nil,
    ] as [String?])
    func noPageOutsideTheRegistration(registered: String?) async {
        let server = MastodonFixture.server()
        let app = MastodonApp(host: host, clientID: "cid", clientSecret: "csecret", scopes: registered)
        let browser = await FixtureBrowser.approving()
        await #expect(throws: MastodonSignInError.unreadable) {
            _ = try await MastodonOAuth(host: host, sender: server)
                .signIn(as: app, asking: MastodonOAuth.scopes(writing: true), through: browser)
        }
        #expect(await browser.opened.isEmpty)
        #expect(await server.paths.isEmpty)
    }

    // MARK: - What a run remembers

    @Test("A page that ends with nothing sent back, twice, is a host not asked again this run; once, it is asked for the least")
    func strands() {
        var run = MastodonRegistering()
        #expect(run.mayTryWhole(host) && !run.isUnconfirmed(host))
        #expect(!run.suspected(host) && !run.stranded(host))
        run.made(at: host, confirmed: false)
        #expect(run.isUnconfirmed(host))
        run.strand(host)
        #expect(run.suspected(host) && !run.stranded(host))
        #expect(!run.mayTryWhole(host) && !run.isUnconfirmed(host))
        run.made(at: host, confirmed: false)
        run.strand(host)
        #expect(run.stranded(host) && run.suspected(host))
        #expect(!run.stranded("other.example") && !run.suspected("other.example"))
        #expect(run.mayTryWhole("other.example"))
    }

    @Test("A host has none of a word where it said so itself: its list lacks it, its registration left it out, or it alone parted a registration refused from one made")
    func hasNone() {
        let acting = MastodonOAuth.scopes(writing: true)
        let lessBookmarks = MastodonOAuth.scopes(writing: true, bookmarks: false)
        let least = MastodonOAuth.scopes(search: false, writing: true, bookmarks: false)
        let (search, bookmarks) = (MastodonPart.search.words[0], MastodonPart.bookmarks.words[0])
        var run = MastodonRegistering()
        #expect(!run.hasNone(of: bookmarks, at: host))

        // More than one word parts the two: nothing says which, and neither is laid on the host.
        run.made(least, after: acting, at: host)
        #expect(!run.hasNone(of: bookmarks, at: host) && !run.hasNone(of: search, at: host))
        run.made(lessBookmarks, after: acting, at: host)
        #expect(run.hasNone(of: bookmarks, at: host) && !run.hasNone(of: search, at: host))
        #expect(!run.hasNone(of: bookmarks, at: "other.example"))

        var named = MastodonRegistering()
        named.named(least, of: acting, at: host)
        #expect(named.hasNone(of: bookmarks, at: host) && named.hasNone(of: search, at: host))
        #expect(!named.hasNone(of: MastodonPart.acting.words[0], at: host))

        var listed = MastodonRegistering()
        listed.learnt(Set(lessBookmarks.split(separator: " ").map(String.init)), of: host)
        #expect(listed.hasNone(of: bookmarks, at: host) && !listed.hasNone(of: search, at: host))
    }

    @Test("A sign-in kept spends the suspicion and nothing else; a host forgotten is one nothing is known of, and no other host is touched")
    func forgotten() {
        let other = "other.example"
        var run = MastodonRegistering()
        for known in [host, other] {
            run.learnt(["read:statuses"], of: known)
            run.refuse(Self.whole, at: known)
            run.refusedWhole(known)
            run.named(MastodonOAuth.readingWithoutSearch, of: MastodonOAuth.reading, at: known)
            run.made(at: known, confirmed: false)
            run.strand(known)
            run.made(at: known, confirmed: false)
            run.strand(known)
            run.made(at: known, confirmed: false)
        }
        run.signedIn(host)
        #expect(!run.suspected(host) && !run.stranded(host))
        #expect(!run.mayTryWhole(host) && run.refused(Self.whole, at: host) && run.isUnconfirmed(host))
        #expect(run.stranded(other))

        run.forget(other)
        #expect(run.mayTryWhole(other) && !run.refused(Self.whole, at: other) && !run.isUnconfirmed(other))
        #expect(!run.suspected(other) && !run.stranded(other) && run.list(other) == nil)
        #expect(!run.hasNone(of: MastodonPart.search.words[0], at: other))
        #expect(run.list(host) != nil && !run.mayTryWhole(host) && run.hasNone(of: MastodonPart.search.words[0], at: host))
    }

    @Test("A refusal is remembered by host and by exactly what was refused; a confirmed registration is not suspected")
    func refusals() {
        var run = MastodonRegistering()
        run.refuse(Self.whole, at: host)
        #expect(run.refused(Self.whole, at: host) && !run.refused(MastodonOAuth.reading, at: host))
        #expect(!run.refused(Self.whole, at: "other.example") && run.mayTryWhole(host))
        run.refusedWhole(host)
        #expect(!run.mayTryWhole(host) && run.mayTryWhole("other.example"))
        run.made(at: host, confirmed: false)
        run.made(at: host, confirmed: true)
        #expect(!run.isUnconfirmed(host))
        #expect(run.list(host) == nil)
        run.learnt(["read:statuses"], of: host)
        #expect(run.list(host) == ["read:statuses"] && run.list("other.example") == nil)
    }

    @Test("Search and bookmarks are the parts a sign-in is whole without, and no other")
    func riders() {
        #expect(MastodonPart.allCases.filter(\.rider) == [.search, .bookmarks])
        #expect(MastodonParts.riderWords == ["read:search", "write:bookmarks"])
    }
}
