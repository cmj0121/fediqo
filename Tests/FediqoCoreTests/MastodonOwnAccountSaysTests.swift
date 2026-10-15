import Foundation
import Testing
@testable import FediqoCore

/// #312: the reader's own account read and changed through this app's own `MastodonOwnAccount`,
/// held against the real one this checkout brings up (`make servers`, Mastodon 4.6.6).
///
/// **The account is the seed's `own_312`**, which no other check reads, counts or lists, and
/// whom the seed puts back as these checks start from on every run: "Own 312", "Words of my
/// own.", two fields, followed without asking, not found, its lists shown. It is limited by the
/// server, so being found turned on lists it in no directory another check reads.
///
/// **What a check changes it puts back, however it ends** (`restoring`), through the same code.
///
/// **Asked of the server first, by hand, 2026-10-15** — and what the checks hold:
/// - A change is answered with the account whole; a fresh read says the same.
/// - Fields are replaced whole, and one field with no name and no value is no field: the set
///   is emptied (`Account#fields_attributes=` drops a blank one).
/// - A name past the host's 40 is a 422 whose `details` names `display_name`; nothing changes.
/// - **Turning "follow without asking" on lets the waiting in later, not in the answer.** The
///   server queues one job per request (`UpdateAccountService#authorize_all_follow_requests`,
///   `AuthorizeFollowWorker`) and answers at once, so the answer's `follow_requests_count` still
///   counts them. This fixture runs no worker, so they stay waiting; when the queued job was run
///   by hand the asker followed and the count was 0.
@Suite("What a Mastodon says of a change to the reader's own account", .enabled(if: LocalServers.requested), .serialized)
struct MastodonOwnAccountSaysTests {
    private static let host = LocalServers.mastodon

    /// As the seed leaves the account, and as every check puts it back.
    private static let start = OwnAccount(
        name: "Own 312", words: "Words of my own.",
        fields: [.init(name: "site", value: "own.example"), .init(name: "pronouns", value: "they")],
        followWithoutAsking: true, findable: false, listsShown: true
    )

    private struct Seeded {
        let own: LocalServers.Seeded.People.SignedIn
        let fan: LocalServers.Seeded.People.SignedIn
    }

    private func seeded() throws -> Seeded {
        let stale: Comment = "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again"
        let people = try #require(try LocalServers.seeded().people, stale)
        return Seeded(own: try #require(people.own, stale), fan: try #require(people.ownFan, stale))
    }

    private func reader(_ accessToken: String) throws -> MastodonOwnAccount {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonOwnAccount(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    /// The server asked plainly as `token`.
    private func ask(_ path: String, as token: String, _ method: String = "GET") async throws -> Any {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, _) = try await LocalHTTP.client().send(request)
        return try JSONSerialization.jsonObject(with: body)
    }

    /// Runs `body`, then puts the account back as the seed left it and has the asker ask no more,
    /// whatever became of `body`.
    private func restoring(_ seeded: Seeded, _ body: (MastodonOwnAccount) async throws -> Void) async throws {
        let own = try reader(seeded.own.token)
        let thrown: (any Error)?
        do {
            try await body(own)
            thrown = nil
        } catch {
            thrown = error
        }
        _ = try? await ask("/api/v1/accounts/\(seeded.own.id)/unfollow", as: seeded.fan.token, "POST")
        if let now = try? await own.read(), now != Self.start { _ = try? await own.change(from: now, to: Self.start) }
        if let thrown { throw thrown }
        #expect(try await own.read() == Self.start, "left changed on the server")
    }

    @Test("The name, the words, the fields and each of the three switches, changed one at a time, are answered as sent and read back the same afresh, and each is undone the same way; the host's limits are its own")
    func eachChangeReadBackAndUndone() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        try await restoring(seeded) { (own: MastodonOwnAccount) async throws in
            #expect(try await own.read() == Self.start, "as the seed left it")
            #expect(try await own.limits() == OwnLimits(name: 40, words: 500, fields: 4, fieldName: 255, fieldValue: 255))

            var name = Self.start, words = Self.start, fields = Self.start
            name.name = "Own 312, renamed"
            words.words = "Other words, on two\nlines."
            fields.fields = [.init(name: "pronouns", value: "they"), .init(name: "home", value: "elsewhere")]
            var asking = Self.start, found = Self.start, hidden = Self.start
            asking.followWithoutAsking = false
            found.findable = true
            hidden.listsShown = false
            let changes = [("name", name), ("words", words), ("fields", fields), ("follow without asking", asking), ("found", found), ("lists", hidden)]

            for (what, changed) in changes {
                let answer = try #require(try await own.change(from: Self.start, to: changed), "\(what)")
                #expect(answer.account == changed, "\(what): answered as sent")
                #expect(answer.person.accountID == seeded.own.id, "\(what)")
                #expect(try await own.read() == changed, "\(what): read back the same")
                let undone = try #require(try await own.change(from: changed, to: Self.start), "\(what)")
                #expect(undone.account == Self.start, "\(what): undone")
                #expect(try await own.read() == Self.start, "\(what): read back undone")
            }
        }
    }

    @Test("A name past the host's limit is refused in the server's words, naming the name and the limit, and nothing changes")
    func aRefusalNamesWhat() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        try await restoring(seeded) { (own: MastodonOwnAccount) async throws in
            var long = Self.start
            long.name = String(repeating: "x", count: 41)
            // In the words of the language this device asks in, so only what does not hang on it.
            let refused = await #expect(throws: OwnAccountError.self) { _ = try await own.change(from: Self.start, to: long) }
            guard case let .refused(sentence, rows) = refused else {
                Issue.record("not a refusal: \(String(describing: refused))")
                return
            }
            #expect(sentence.contains("40") && Array(rows.keys) == [.name] && rows[.name]?.contains("40") == true)
            #expect(try await own.read() == Self.start)
        }
    }

    @Test("Clearing every field is sent as one empty field, and the server keeps none")
    func clearingEveryField() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        try await restoring(seeded) { (own: MastodonOwnAccount) async throws in
            var none = Self.start
            none.fields = []
            #expect(MastodonOwnAccount.form(from: Self.start, to: none).map { [$0.0, $0.1] } == [
                ["fields_attributes[0][name]", ""], ["fields_attributes[0][value]", ""],
            ])
            let answer = try #require(try await own.change(from: Self.start, to: none))
            #expect(answer.account.fields.isEmpty && answer.person.fields.isEmpty)
            #expect(try await own.read().fields.isEmpty)
            let back = try #require(try await own.change(from: none, to: Self.start))
            #expect(back.account.fields == Self.start.fields)
        }
    }

    @Test("Turning \"follow without asking\" on while somebody waits answers at once with them still counted: the server lets them in afterwards, by a job this fixture never runs")
    func followWithoutAskingWhileOneWaits() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        try await restoring(seeded) { (own: MastodonOwnAccount) async throws in
            var locked = Self.start
            locked.followWithoutAsking = false
            let shut = try #require(try await own.change(from: Self.start, to: locked))
            #expect(shut.asking == 0)
            let asked = try await ask("/api/v1/accounts/\(seeded.own.id)/follow", as: seeded.fan.token, "POST") as? [String: Any]
            #expect(asked?["requested"] as? Bool == true)

            let open = try #require(try await own.change(from: locked, to: Self.start))
            #expect(open.account.followWithoutAsking == true)
            #expect(open.asking == 1, "the answer comes before the let-in, and still counts who waits")
            let waiting = try await ask("/api/v1/follow_requests", as: seeded.own.token) as? [[String: Any]]
            #expect(waiting?.map { $0["id"] as? String } == [seeded.fan.id], "no worker here lets them in")
        }
    }
}
