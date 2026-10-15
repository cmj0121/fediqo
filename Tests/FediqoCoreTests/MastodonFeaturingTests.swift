import Foundation
import Testing
@testable import FediqoCore

/// A server that answers by method, path and query, with a `Link` header where it is given one,
/// and remembers every request whole.
actor FeatureServer: HTTPClient, HTTPSender {
    struct Answer: Sendable {
        var body: String
        var status: Int = 200
        var link: String?
    }

    private let routes: [String: Answer]
    private(set) var requests: [URLRequest] = []

    /// `routes` by `"METHOD /path?query"`.
    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    var asked: [String] {
        requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")\($0.url?.query.map { "?\($0)" } ?? "")" }
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url,
              let answer = routes["\(request.httpMethod ?? "GET") \(url.path)\(url.query.map { "?\($0)" } ?? "")"]
        else { throw FixtureHTTPError.unmapped }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.link.map { ["Link": $0] }
        )!
        return (Data(answer.body.utf8), response)
    }

    func form(at index: Int = 0) -> String {
        requests[index].httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// #315 and #318 in Core: a suggestion dismissed; a person featured and taken off, whether the
/// reader features them, whom the reader and anyone else features; a hashtag featured and taken
/// off, and what the reader and anyone else features — each as a server answers it, a Mastodon's
/// and a GoToSocial's (`servers/gotosocial/FINDINGS.md` items 2, 7, 8, 13).
///
/// Every expected string is written out here and not read off the code it is held against.
@Suite("Featuring people and hashtags, and a suggestion dismissed")
struct MastodonFeaturingTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)
    private static let r = "read:statuses read:lists read:accounts"
    private static let f = "read:follows write:follows"
    private static let a = "write:accounts"
    private static let held = "\(r) \(f) \(a)"

    /// Mastodon's address not-found, a GoToSocial's, and a page: each the host saying it has no such address.
    private static let noAddress: [FeatureServer.Answer] = [
        .init(body: #"{"error":"Not Found"}"#, status: 404),
        .init(body: "404 page not found", status: 404),
        .init(body: "", status: 404),
    ]
    /// Mastodon's answer for somebody it has not got: about the record, never the host.
    private static let noRecord = FeatureServer.Answer(body: #"{"error":"Record not found"}"#, status: 404)
    /// A 403 as a GoToSocial sends it: no word named.
    private static let goToSocial403 = FeatureServer.Answer(body: #"{"error":"Forbidden"}"#, status: 403)

    private static func door(
        _ routes: [String: FeatureServer.Answer], scopes: String? = held
    ) throws -> (MastodonAuthorized, FeatureServer) {
        let token = MastodonFixture.token(scopes: scopes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        let server = FeatureServer(routes)
        return (MastodonAuthorized(token: token, sender: server, store: tokens), server)
    }

    private static func featuring(
        _ routes: [String: FeatureServer.Answer], scopes: String? = held
    ) throws -> (MastodonFeaturing, FeatureServer) {
        let (door, server) = try door(routes, scopes: scopes)
        return (MastodonFeaturing(door: door), server)
    }

    private static func relationship(_ id: String = "42", following: Bool = true, endorsed: String = "true") -> String {
        #"{"id":"\#(id)","following":\#(following),"showing_reblogs":true,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":\#(endorsed),"note":""}"#
    }

    private static func tag(_ id: String, _ name: String, count: String = #""3""#) -> String {
        #"{"id":"\#(id)","name":"\#(name)","url":"https://\#(host)/@ada/tagged/\#(name.lowercased())","statuses_count":\#(count),"last_status_at":"2026-10-14"}"#
    }

    // MARK: - A suggestion dismissed

    @Test("A suggestion is dismissed by a DELETE of its account's id at the suggestions' address, as the reader, of the sign-in's own host — and the source's {} is done")
    func dismissed() async throws {
        let (door, server) = try Self.door(["DELETE /api/v1/suggestions/42": .init(body: "{}")])
        try await MastodonSuggestions(door: door).dismiss(accountID: "42")
        let request = try #require(await server.requests.first)
        #expect(await server.asked == ["DELETE /api/v1/suggestions/42"])
        #expect(request.url?.host() == Self.host && request.url?.scheme == "https")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(request.httpBody == nil)
        for bad in ["", "4/2", "..", "42?x=1"] {
            await #expect(throws: MastodonRequestError.invalidURL) { try await MastodonSuggestions(door: door).dismiss(accountID: bad) }
        }
        #expect(await server.requests.count == 1)
    }

    @Test("A dismissal's 403 is the account part's lock where the sign-in does not hold it and the source forbidding it where it does — a GoToSocial's wordless 403 the same; and a host with no such address is absent, never a failure")
    func dismissalRefused() async throws {
        let path = "DELETE /api/v1/suggestions/42"
        for scopes in [Self.r, "\(Self.r) \(Self.f)", nil] as [String?] {
            let (door, _) = try Self.door([path: Self.goToSocial403], scopes: scopes)
            await #expect(throws: AccountPartError.locked) { try await MastodonSuggestions(door: door).dismiss(accountID: "42") }
        }
        let (door, _) = try Self.door([path: Self.goToSocial403])
        await #expect(throws: AccountPartError.forbidden) { try await MastodonSuggestions(door: door).dismiss(accountID: "42") }
        for answer in Self.noAddress {
            let (door, _) = try Self.door([path: answer])
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await MastodonSuggestions(door: door).dismiss(accountID: "42") }
        }
    }

    // MARK: - A person featured

    @Test("Somebody is featured by a POST to their endorse, taken off by unendorse, and what is handed back is whether the source's answer says they are featured")
    func personFeatured() async throws {
        let (featuring, server) = try Self.featuring([
            "POST /api/v1/accounts/42/endorse": .init(body: Self.relationship(endorsed: "true")),
            "POST /api/v1/accounts/42/unendorse": .init(body: Self.relationship(endorsed: "false")),
        ])
        #expect(try await featuring.feature(accountID: "42") == PersonStanding(accountID: "42", following: true, showsBoosts: true, notifies: false, featured: true))
        #expect(try await featuring.unfeature(accountID: "42").featured == false)
        #expect(await server.asked == ["POST /api/v1/accounts/42/endorse", "POST /api/v1/accounts/42/unendorse"])
        #expect(await server.form(at: 0).isEmpty)
        await #expect(throws: MastodonRequestError.invalidURL) { try await featuring.feature(accountID: "../42") }
        #expect(await server.requests.count == 2)
    }

    @Test("Featuring somebody the reader does not follow is the source's refusal, in its own sentence fit for a line; one with no sentence is a refusal with none")
    func notFollowedIsRefused() async throws {
        let sentence = "Validation failed: You must be already following the person you want to endorse"
        let (featuring, _) = try Self.featuring([
            "POST /api/v1/accounts/42/endorse": .init(body: #"{"error":"\#(sentence)"}"#, status: 422),
        ])
        await #expect(throws: AccountPartError.refused(sentence: sentence)) { try await featuring.feature(accountID: "42") }
        let long = String(repeating: "word ", count: 100)
        let (wordy, _) = try Self.featuring(["POST /api/v1/accounts/42/endorse": .init(body: #"{"error":"\#(long)\nmore"}"#, status: 422)])
        do {
            _ = try await wordy.feature(accountID: "42")
            Issue.record("a refusal was not thrown")
        } catch AccountPartError.refused(let said) {
            #expect(said.count <= 201 && !said.contains("\n") && said.hasPrefix("word word"))
        }
        let (bare, _) = try Self.featuring(["POST /api/v1/accounts/42/endorse": .init(body: "<html>", status: 422)])
        await #expect(throws: AccountPartError.refused(sentence: "")) { try await bare.feature(accountID: "42") }
    }

    @Test("Featuring's 403 is the lock by the held words, whatever it says; a host with no such address (GoToSocial, all four asks) is absent; Mastodon's not-found of somebody is not; an answer about somebody else, or that does not say, is unreadable")
    func personFeaturingFails() async throws {
        let endorse = "POST /api/v1/accounts/42/endorse"
        let mastodon403 = FeatureServer.Answer(body: #"{"error":"This action is outside the authorized scopes"}"#, status: 403)
        for answer in [mastodon403, Self.goToSocial403] {
            await #expect(throws: AccountPartError.locked) { try await Self.featuring([endorse: answer], scopes: Self.r).0.feature(accountID: "42") }
            await #expect(throws: AccountPartError.forbidden) { try await Self.featuring([endorse: answer]).0.feature(accountID: "42") }
        }
        for answer in Self.noAddress {
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await Self.featuring([endorse: answer]).0.feature(accountID: "42") }
            await #expect(throws: MastodonHostMoreError.noSuchAddress) {
                try await Self.featuring(["POST /api/v1/accounts/42/unendorse": answer]).0.unfeature(accountID: "42")
            }
        }
        await #expect(throws: MastodonAuthError.http(404)) { try await Self.featuring([endorse: Self.noRecord]).0.feature(accountID: "42") }
        for body in [Self.relationship("43"), #"{"id":"42","following":true}"#, "[]"] {
            await #expect(throws: AccountPartError.unreadable) { try await Self.featuring([endorse: .init(body: body)]).0.feature(accountID: "42") }
        }
    }

    @Test("Whether the reader features somebody is their standing's featured — the source's endorsed — and nothing where it does not say")
    func standingSaysFeatured() async throws {
        let ask = "GET /api/v1/accounts/relationships?id%5B%5D=42"
        func standing(_ body: String) async throws -> PersonStanding? {
            let (door, _) = try Self.door([ask: .init(body: body)])
            return try await MastodonStanding(door: door).standing(to: "42")
        }
        #expect(try await standing("[\(Self.relationship())]")?.featured == true)
        #expect(try await standing("[\(Self.relationship(endorsed: "false"))]")?.featured == false)
        let unsaid = Self.relationship().replacingOccurrences(of: #""endorsed":true,"#, with: "")
        #expect(try await standing("[\(unsaid)]")?.featured == nil)
        #expect(try await standing("[\(unsaid)]")?.following == true)
        // A word of another shape costs that word alone, never the standing.
        let odd = try #require(try await standing("[\(Self.relationship(endorsed: #""yes""#))]"))
        #expect(odd.featured == nil && odd.following == true)
        // Said only of a follow: somebody not followed is not featured, and is not said to be "not".
        #expect(try await standing("[\(Self.relationship(following: false, endorsed: "true"))]")?.featured == nil)
    }

    // MARK: - Whom somebody features

    private static func people(_ ids: ClosedRange<Int>) -> String {
        "[" + ids.map { #"{"id":"\#($0)","acct":"p\#($0)","username":"p\#($0)"}"# }.joined(separator: ",") + "]"
    }

    @Test("Whom the reader features is read on by the source's own next, as the other lists of people are, as the reader")
    func readerFeatures() async throws {
        let path = "/api/v1/endorsements"
        let (door, server) = try Self.door([
            "GET \(path)?limit=2": .init(body: Self.people(1...2), link: #"<https://\#(Self.host)\#(path)?limit=2&max_id=2>; rel="next""#),
            "GET \(path)?limit=2&max_id=2": .init(body: Self.people(3...3)),
        ])
        let people = MastodonPeople(door: door)
        let first = try await people.stretch(.featuredByReader, source: Self.source, limit: 2)
        #expect(first.people.map(\.accountID) == ["1", "2"] && first.next == "2")
        let last = try await people.stretch(.featuredByReader, source: Self.source, after: first.next, limit: 2)
        #expect(last.people.map(\.accountID) == ["3"] && last.next == nil)
        #expect(await server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123" })
        // Nobody featured is an empty list, never a host without it.
        let (empty, _) = try Self.door(["GET \(path)": .init(body: "[]")])
        #expect(try await MastodonPeople(door: empty).stretch(.featuredByReader, source: Self.source).people.isEmpty)
        for answer in Self.noAddress {
            let (door, _) = try Self.door(["GET \(path)": answer])
            await #expect(throws: MastodonHostMoreError.noSuchAddress) {
                try await MastodonPeople(door: door).stretch(.featuredByReader, source: Self.source)
            }
        }
    }

    @Test("Whom somebody else features is asked at their endorsements, unsigned or as the reader, read on by the next; a host without it is absent by either door, an id nobody has is that door's not-found, and an id that is no segment asks nothing")
    func somebodyFeatures() async throws {
        let path = "/api/v1/accounts/7/endorsements"
        let list = MastodonPeople.List.featured(by: "7")
        let server = FeatureServer([
            "GET \(path)": .init(body: Self.people(1...2), link: #"<https://\#(Self.host)\#(path)?max_id=2>; rel="next""#),
            "GET \(path)?max_id=2": .init(body: "[]"),
        ])
        let unsigned = MastodonPeople(http: server, host: Self.host)
        let first = try await unsigned.stretch(list, source: Self.source)
        #expect(first.people.map(\.accountID) == ["1", "2"] && first.next == "2")
        #expect(try await unsigned.stretch(list, source: Self.source, after: "2").people.isEmpty)
        let wrapped = MastodonFeatured(http: server, host: Self.host)
        #expect(try await wrapped.featuredPeople(of: "7", source: Self.source) == first)
        #expect(try await wrapped.featuredPeople(of: "7", source: Self.source, after: "2").next == nil)
        #expect(await server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })

        for answer in Self.noAddress {
            let gone = FeatureServer(["GET \(path)": answer])
            await #expect(throws: MastodonHostMoreError.noSuchAddress) {
                try await MastodonPeople(http: gone, host: Self.host).stretch(list, source: Self.source)
            }
            let (door, _) = try Self.door(["GET \(path)": answer])
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await MastodonPeople(door: door).stretch(list, source: Self.source) }
        }
        let nobody = FeatureServer(["GET \(path)": Self.noRecord])
        await #expect(throws: MastodonRequestError.http(404)) {
            try await MastodonPeople(http: nobody, host: Self.host).stretch(list, source: Self.source)
        }
        let (door, _) = try Self.door(["GET \(path)": Self.noRecord])
        await #expect(throws: MastodonAuthError.http(404)) { try await MastodonPeople(door: door).stretch(list, source: Self.source) }
        await #expect(throws: MastodonRequestError.invalidURL) { try await unsigned.stretch(.featured(by: "7/x"), source: Self.source) }
        // The other lists of people are as they were: their not-found is the door's.
        let followers = FeatureServer(["GET /api/v1/accounts/7/followers": Self.noAddress[0]])
        await #expect(throws: MastodonRequestError.http(404)) {
            try await MastodonPeople(http: followers, host: Self.host).stretch(.followers(of: "7"), source: Self.source)
        }
    }

    // MARK: - A hashtag featured

    @Test("A hashtag is featured by a POST of its name, without its mark, to the featured hashtags — and what is handed back is the featuring the source made, its count read though a Mastodon sends it as a string")
    func tagFeatured() async throws {
        let (featuring, server) = try Self.featuring(["POST /api/v1/featured_tags": .init(body: Self.tag("5", "Fediqo318"))])
        let tag = try #require(PostTag("#Fediqo318"))
        let made = try await featuring.feature(tag: tag)
        #expect(made == FeaturedTag(id: "5", tag: tag, count: 3, last: Date(timeIntervalSince1970: 1_791_936_000)))
        #expect(made.name == "Fediqo318")
        #expect(await server.form() == "name=Fediqo318")
        #expect(await server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        let numbered = try await Self.featuring(["POST /api/v1/featured_tags": .init(body: Self.tag("5", "a", count: "7"))]).0.feature(tag: tag)
        #expect(numbered.count == 7)
        let uncounted = try await Self.featuring(["POST /api/v1/featured_tags": .init(body: Self.tag("5", "a", count: #""many""#))]).0.feature(tag: tag)
        #expect(uncounted.count == nil)
    }

    @Test("Featuring a hashtag refused is the source's sentence; its 403 is the lock by the held words; a host with no such address is absent; an answer that is no featuring is unreadable")
    func tagFeaturingFails() async throws {
        let post = "POST /api/v1/featured_tags"
        let tag = try #require(PostTag("#fediqo"))
        let sentence = "Validation failed: You have already featured the maximum number of hashtags"
        await #expect(throws: AccountPartError.refused(sentence: sentence)) {
            try await Self.featuring([post: .init(body: #"{"error":"\#(sentence)"}"#, status: 422)]).0.feature(tag: tag)
        }
        await #expect(throws: AccountPartError.locked) { try await Self.featuring([post: Self.goToSocial403], scopes: Self.r).0.feature(tag: tag) }
        await #expect(throws: AccountPartError.forbidden) { try await Self.featuring([post: Self.goToSocial403]).0.feature(tag: tag) }
        for answer in Self.noAddress {
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await Self.featuring([post: answer]).0.feature(tag: tag) }
        }
        for body in ["[]", #"{"id":"5"}"#, #"{"id":"5","name":"no space"}"#] {
            await #expect(throws: AccountPartError.unreadable) { try await Self.featuring([post: .init(body: body)]).0.feature(tag: tag) }
        }
    }

    @Test("A featuring is taken off by a DELETE of its own id; one with no id asks nothing; its 403 is the lock; a host with no such address is absent, and Mastodon's not-found of the featuring is not")
    func tagTakenOff() async throws {
        let tag = try #require(PostTag("#fediqo"))
        let path = "DELETE /api/v1/featured_tags/5"
        let (featuring, server) = try Self.featuring([path: .init(body: "{}")])
        try await featuring.unfeature(FeaturedTag(id: "5", tag: tag))
        #expect(await server.asked == [path])
        #expect(await server.requests.first?.httpBody == nil)
        await #expect(throws: MastodonRequestError.invalidURL) { try await featuring.unfeature(FeaturedTag(id: nil, tag: tag)) }
        #expect(await server.requests.count == 1)
        await #expect(throws: AccountPartError.locked) {
            try await Self.featuring([path: Self.goToSocial403], scopes: Self.r).0.unfeature(FeaturedTag(id: "5", tag: tag))
        }
        await #expect(throws: MastodonHostMoreError.noSuchAddress) {
            try await Self.featuring([path: Self.noAddress[1]]).0.unfeature(FeaturedTag(id: "5", tag: tag))
        }
        await #expect(throws: MastodonAuthError.http(404)) {
            try await Self.featuring([path: Self.noRecord]).0.unfeature(FeaturedTag(id: "5", tag: tag))
        }
    }

    @Test("A hashtag is taken off by its name: the reader's own list is read for the featuring's id, matched however it is written, and that is taken off; one not among them asks nothing more")
    func tagTakenOffByName() async throws {
        let list = "GET /api/v1/featured_tags"
        let (featuring, server) = try Self.featuring([
            list: .init(body: "[\(Self.tag("5", "Fediqo318")),\(Self.tag("6", "other"))]"),
            "DELETE /api/v1/featured_tags/5": .init(body: "{}"),
        ])
        try await featuring.unfeature(tag: try #require(PostTag("#FEDIQO318")))
        #expect(await server.asked == [list, "DELETE /api/v1/featured_tags/5"])
        let (none, quiet) = try Self.featuring([list: .init(body: "[]")])
        try await none.unfeature(tag: try #require(PostTag("#fediqo318")))
        #expect(await quiet.asked == [list])
        let tag = try #require(PostTag("#fediqo318"))
        await #expect(throws: MastodonHostMoreError.noSuchAddress) {
            try await Self.featuring([list: Self.noAddress[0]]).0.unfeature(tag: tag)
        }
    }

    @Test("A day is read as midnight of it in UTC, a moment as a moment, and anything else as nothing")
    func lastDay() {
        #expect(FeaturedTag.day(from: "2026-10-14") == Date(timeIntervalSince1970: 1_791_936_000))
        #expect(FeaturedTag.day(from: "2026-10-14T12:00:00.000Z") == Date(timeIntervalSince1970: 1_791_979_200))
        for odd in ["2026-02-30", "2026-1-140", "yesterday", "", "２０２６-10-14"] {
            #expect(FeaturedTag.day(from: odd) == nil, "\(odd)")
        }
    }

    @Test("A hashtag's standing says whether the reader features it where its answer says — a Mastodon's — and nothing where it does not, as a GoToSocial's, never a no")
    func tagStanding() async throws {
        let path = "GET /api/v1/tags/fediqo318a"
        let tag = try #require(PostTag("#fediqo318a"))
        let (door, server) = try Self.door([path: .init(body: MastodonTagFollowCaptures.followed)])
        #expect(try await MastodonTagFollows(door: door).standing(of: tag) == TagStanding(following: true, featuring: false))
        #expect(await server.asked == [path])
        let featured = MastodonTagFollowCaptures.followed.replacingOccurrences(of: #""featuring":false"#, with: #""featuring":true"#)
        #expect(try await MastodonTagFollows(door: Self.door([path: .init(body: featured)]).0).standing(of: tag).featuring == true)
        let goToSocial = #"{"name":"fediqo318a","url":"https://social.example/tags/fediqo318a","history":[],"following":false}"#
        #expect(try await MastodonTagFollows(door: Self.door([path: .init(body: goToSocial)]).0).standing(of: tag) == TagStanding(following: false))
    }

    @Test("The hashtags the reader features are read as the reader; whether one is featured is found in that list by its folded name — never in the hashtag's own answer, which a GoToSocial gives no id or featuring; entries that are no hashtag are not listed, one twice is listed once, and an id that cannot stand in a path is none")
    func readerFeaturesTags() async throws {
        let body = "[" + [
            Self.tag("1", "Fediqo318"), Self.tag("2", "fediqo318"), Self.tag("3", "two words"), #"{"name":"noID"}"#,
            Self.tag("../4", "climbs"), #"{"id":"9"}"#,
        ].joined(separator: ",") + "]"
        let (featuring, server) = try Self.featuring(["GET /api/v1/featured_tags": .init(body: body)])
        let list = try await featuring.ownFeaturedTags()
        #expect(list.map(\.tag.name) == ["Fediqo318", "noID", "climbs"])
        #expect(list.map(\.id) == ["1", nil, nil])
        #expect(await server.asked == ["GET /api/v1/featured_tags"])
        #expect(FeaturedTag.of(try #require(PostTag("#FEDIQO318")), in: list)?.id == "1")
        #expect(FeaturedTag.of(try #require(PostTag("#other")), in: list) == nil)
        // A GoToSocial answers [] whether or not anything is featured: nothing featured, not absent.
        #expect(try await Self.featuring(["GET /api/v1/featured_tags": .init(body: "[]")]).0.ownFeaturedTags().isEmpty)
        await #expect(throws: MastodonHostMoreError.noSuchAddress) {
            try await Self.featuring(["GET /api/v1/featured_tags": Self.noAddress[0]]).0.ownFeaturedTags()
        }
        await #expect(throws: AccountPartError.unreadable) {
            try await Self.featuring(["GET /api/v1/featured_tags": .init(body: "{}")]).0.ownFeaturedTags()
        }
        let many = "[" + (0..<150).map { Self.tag("\($0)", "t\($0)") }.joined(separator: ",") + "]"
        #expect(try await Self.featuring(["GET /api/v1/featured_tags": .init(body: many)]).0.ownFeaturedTags().count == FeaturedTag.most)
    }

    @Test("The hashtags somebody features are what a real server sent, read unsigned or as the reader; a host with no such address is absent, an id nobody has is that door's not-found, and another source or an id that is no segment asks nothing")
    func somebodyFeaturesTags() async throws {
        let path = "GET /api/v1/accounts/7/featured_tags"
        let server = FeatureServer([path: .init(body: MastodonPeopleCaptures.featuredTags)])
        let unsigned = MastodonFeatured(http: server, host: Self.host)
        let list = try await unsigned.featuredTags(of: "7", source: Self.source)
        #expect(list == [FeaturedTag(id: "1", tag: try #require(PostTag("#fediqo309")), count: 0, last: nil)])
        #expect(await server.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        let (door, signed) = try Self.door([path: .init(body: "[]")])
        #expect(try await MastodonFeatured(door: door).featuredTags(of: "7", source: Self.source).isEmpty)
        #expect(await signed.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        for answer in Self.noAddress {
            await #expect(throws: MastodonHostMoreError.noSuchAddress) {
                try await MastodonFeatured(http: FeatureServer([path: answer]), host: Self.host).featuredTags(of: "7", source: Self.source)
            }
        }
        await #expect(throws: MastodonRequestError.http(404)) {
            try await MastodonFeatured(http: FeatureServer([path: Self.noRecord]), host: Self.host).featuredTags(of: "7", source: Self.source)
        }
        await #expect(throws: MastodonRequestError.invalidURL) { try await unsigned.featuredTags(of: "7/x", source: Self.source) }
        await #expect(throws: MastodonRequestError.invalidURL) {
            try await unsigned.featuredTags(of: "7", source: Source(host: "other.example", kind: .mastodon))
        }
        #expect(await server.requests.count == 1)
    }
}
