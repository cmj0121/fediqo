import Foundation
import Testing
@testable import FediqoCore

/// #310, #313: what Fediqo believes a Mastodon says of how the reader stands to somebody, and
/// of following them, held against the real one this checkout brings up (`make servers`,
/// Mastodon 4.6.6) — every line of the table in `MastodonStandingCaptures`. Each check goes
/// through this app's own reader, `MastodonStanding`, and beside it asks the server plainly
/// for the part of the answer the reader rests on.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **What a check changes it puts back, however it ends** (`restoring`): whoever was followed
/// is unfollowed, the locked account is asked again as the seed left it, and the mute is made
/// for good again — by the writer's own sign-in for everything.
///
/// **Asked gently.** A run makes some seventy requests and no registration: every sign-in here
/// is the seed's.
@Suite("What a Mastodon says of how the reader stands to somebody, and of following them", .enabled(if: LocalServers.requested), .serialized)
struct MastodonStandingSaysTests {
    private typealias Captures = MastodonStandingCaptures

    private static let host = LocalServers.mastodon

    /// One answer, whole: its status, its headers, and its body as JSON where it is JSON.
    private struct Answer {
        let status: Int
        let response: HTTPURLResponse
        let body: Data

        var text: String { String(decoding: body, as: UTF8.self) }
        var object: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var list: [[String: Any]] { (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? [] }
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
    }

    /// The server asked plainly, with no sign-in unless a token is handed in.
    private func ask(_ path: String, as token: String? = nil, _ method: String = "GET", form: String? = nil) async throws -> Answer {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.utf8)
        }
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, response: response, body: body)
    }

    /// The seed's people, and its sign-ins of the writer: one for everything, one that reads
    /// and sees who they follow, and one that holds both words of follows.
    private struct Seeded {
        let people: LocalServers.Seeded.People
        let writer: String
        let seeing: String
        let following: String
        let followable: String
    }

    private func seeded() throws -> Seeded {
        let all = try LocalServers.seeded()
        let stale: Comment = "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again"
        let people = try #require(all.people, stale)
        return Seeded(
            people: people, writer: all.writer, seeing: try #require(people.standing?.token, stale),
            following: try #require(people.following?.token, stale), followable: try #require(people.followable?.id, stale)
        )
    }

    private func reader(_ accessToken: String) throws -> MastodonStanding {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonStanding(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    private static func stands(_ id: String) -> String { "/api/v1/accounts/relationships?id[]=\(id)" }
    private static func account(_ id: String, _ act: String) -> String { "/api/v1/accounts/\(id)/\(act)" }

    /// Runs `body`, and then puts back what it may have changed — as the writer's sign-in for
    /// everything, whatever became of `body`: `unfollowed` are unfollowed, `asked` is asked to
    /// follow again, `muted` is muted for good.
    private func restoring(
        _ seeded: Seeded, unfollowed: [String] = [], asked: String? = nil, muted: String? = nil, _ body: () async throws -> Void
    ) async throws {
        let thrown: (any Error)?
        do {
            try await body()
            thrown = nil
        } catch {
            thrown = error
        }
        var left: [String] = []
        for id in unfollowed where (try? await ask(Self.account(id, "unfollow"), as: seeded.writer, "POST"))?.status != 200 {
            left.append("followed: \(id)")
        }
        if let asked, (try? await ask(Self.account(asked, "follow"), as: seeded.writer, "POST"))?.object["requested"] as? Bool != true {
            left.append("not asked: \(asked)")
        }
        if let muted, (try? await ask(Self.account(muted, "mute"), as: seeded.writer, "POST", form: "duration=0"))?.status != 200 {
            left.append("muted for a time: \(muted)")
        }
        if let thrown { throw thrown }
        #expect(left.isEmpty, "left changed on the server: \(left)")
    }

    @Test("How the reader stands to each kind of person is read as the server says it: nobody's follower, somebody they block, mute, asked to follow, and who blocks them; nothing for a suspended account or an id nobody has; and themselves, an entry like any other with nothing in it")
    func howTheReaderStands() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        let people = seeded.people
        let stands = try reader(seeded.seeing)

        #expect(try await stands.standing(to: people.person.id) == PersonStanding(accountID: people.person.id))
        #expect(try await stands.standing(to: people.blocked.id) == PersonStanding(accountID: people.blocked.id, blocking: true))
        #expect(try await stands.standing(to: people.muted.id) == PersonStanding(accountID: people.muted.id, muting: true))
        #expect(try await stands.standing(to: people.locked.id) == PersonStanding(accountID: people.locked.id, requested: true))
        #expect(try await stands.standing(to: people.blocker.id) == PersonStanding(accountID: people.blocker.id, blockedBy: true))
        #expect(try await stands.standing(to: people.gone.id) == nil, "a suspended account has no entry")
        #expect(try await stands.standing(to: "1999999999") == nil, "nor has an id nobody has")

        let entry = try await ask(Self.stands(people.person.id), as: seeded.seeing)
        #expect(Set(entry.list.first?.keys.map { $0 } ?? []) == MastodonSignInCaptures.standingNames)

        let me = try #require(try await ask("/api/v1/accounts/verify_credentials", as: seeded.writer).object["id"] as? String)
        #expect(try await stands.standing(to: me) == PersonStanding(accountID: me))
    }

    @Test("A stretch of people is asked about in one ask: as many as a stretch brings are named and each is read by their own id, in whatever order the server answers; a suspended account, an id nobody has and an id that is no number have no entry and cost nobody else theirs; the reader themselves is an entry with nothing in it; somebody named twice is answered once; and an ask is refused by its length and not by how many it names, with nothing said")
    func aStretchInOneAsk() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        let people = seeded.people
        let stands = try reader(seeded.seeing)
        let me = try #require(try await ask("/api/v1/accounts/verify_credentials", as: seeded.writer).object["id"] as? String)

        let known = [people.person.id, people.blocked.id, people.muted.id, people.locked.id, people.blocker.id, me]
        let absent = [people.gone.id, "1999999999"]
        // As many as the longest stretch of a list brings, the rest ids nobody has.
        let named = known + absent + (0 ..< MastodonStanding.most - known.count - absent.count).map { "\(2_999_999_999 + $0)" }
        #expect(named.count == MastodonStanding.most)
        let said = try await stands.standings(to: named)
        #expect(Set(said.keys) == Set(known), "nobody but who is somebody there")
        #expect(said[people.person.id] == PersonStanding(accountID: people.person.id))
        #expect(said[people.blocked.id] == PersonStanding(accountID: people.blocked.id, blocking: true))
        #expect(said[people.muted.id] == PersonStanding(accountID: people.muted.id, muting: true))
        #expect(said[people.locked.id] == PersonStanding(accountID: people.locked.id, requested: true))
        #expect(said[people.blocker.id] == PersonStanding(accountID: people.blocker.id, blockedBy: true))
        #expect(said[me] == PersonStanding(accountID: me), "the reader themselves: an entry with nothing in it")

        func many(_ ids: [String]) -> String { "/api/v1/accounts/relationships?" + ids.map { "id[]=\($0)" }.joined(separator: "&") }
        let odd = try await ask(many(["abc", people.person.id, people.person.id, people.gone.id]), as: seeded.seeing)
        #expect(odd.status == 200)
        #expect(odd.list.compactMap { $0["id"] as? String } == [people.person.id], "no number, twice, and suspended: one entry")

        // Not counted: two hundred names are answered as eighty are.
        let long = try await ask(many([people.person.id] + (1 ..< 200).map { "\(2_999_999_999 + $0)" }), as: seeded.seeing)
        #expect(long.status == 200 && long.list.count == 1)
        // Refused by its length: a thousand names are a query past what the server's door reads.
        let tooLong = try await ask(many([people.person.id] + (1 ..< 1000).map { "\(2_999_999_999 + $0)" }), as: seeded.seeing)
        #expect(tooLong.status == 400 && tooLong.body.isEmpty)
    }

    @Test("Following and unfollowing want the word that changes who the reader follows: refused with none and to the word that only sees, in the words kept; with both words somebody is followed, said so by the next read, followed again at no cost, unfollowed, and unfollowed again")
    func followingAndUnfollowing() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        let id = seeded.followable
        try await restoring(seeded, unfollowed: [id]) {
            for act in ["follow", "unfollow"] {
                let nobody = try await ask(Self.account(id, act), as: nil, "POST")
                #expect(nobody.status == 401)
                #expect(nobody.text == MastodonPeopleCaptures.standingUnsigned)
                let refused = try await ask(Self.account(id, act), as: seeded.seeing, "POST")
                #expect(refused.status == 403)
                #expect(refused.header("WWW-Authenticate") == MastodonSignInCaptures.followRefusedHeader)
            }
            await #expect(throws: MastodonAuthError.http(403)) { _ = try await reader(seeded.seeing).follow(id) }
            let follows = try reader(seeded.following)
            #expect(try await follows.standing(to: id) == PersonStanding(accountID: id), "a refusal followed nobody")

            let followed = PersonStanding(accountID: id, following: true, showsBoosts: true, notifies: false)
            #expect(try await follows.follow(id) == followed)
            #expect(try await follows.standing(to: id) == followed)
            #expect(try await reader(seeded.seeing).standing(to: id) == followed, "told to the word that only sees")
            #expect(try await follows.follow(id) == followed, "asked twice, answered the same")
            #expect(try await follows.follow(id, false) == PersonStanding(accountID: id))
            #expect(try await follows.follow(id, false) == PersonStanding(accountID: id))
            #expect(try await follows.standing(to: id) == PersonStanding(accountID: id))

            let plain = try await ask(Self.account(id, "unfollow"), as: seeded.following, "POST")
            #expect(Set(plain.object.keys) == MastodonSignInCaptures.standingNames)
        }
    }

    @Test("What is taken from somebody followed is said again with a follow: each word changes its own thing and leaves the other as it stood, a follow with no word leaves both, the answer is the whole standing and the next read says the same; a sign-in that only sees is told both and refused the change; and of somebody asked and not yet agreed the word is kept on the request, which stays a request")
    func whatIsTakenIsNarrowed() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        let id = seeded.followable
        func stands(_ boosts: Bool, _ notify: Bool) -> PersonStanding {
            PersonStanding(accountID: id, following: true, showsBoosts: boosts, notifies: notify)
        }
        try await restoring(seeded, unfollowed: [id]) {
            let follows = try reader(seeded.following)
            #expect(try await follows.follow(id) == stands(true, false), "a follow begins with their boosts shown and no notice")
            #expect(try await follows.narrow(id, boosts: false) == stands(false, false))
            #expect(try await follows.standing(to: id) == stands(false, false))
            #expect(try await follows.narrow(id, notify: true) == stands(false, true), "the other is left as it stood")
            #expect(try await follows.follow(id) == stands(false, true), "a follow with no word resets neither")
            #expect(try await follows.narrow(id, boosts: true) == stands(true, true))
            #expect(try await follows.narrow(id, notify: false) == stands(true, false))
            #expect(try await follows.standing(to: id) == stands(true, false))

            let seeing = try reader(seeded.seeing)
            #expect(try await seeing.standing(to: id) == stands(true, false), "told to the word that only sees")
            await #expect(throws: MastodonAuthError.http(403)) { _ = try await seeing.narrow(id, boosts: false) }
            #expect(try await follows.standing(to: id) == stands(true, false), "a refusal changed nothing")

            let whole = try await ask(Self.account(id, "follow"), as: seeded.following, "POST", form: "reblogs=false&notify=true")
            #expect(Set(whole.object.keys) == MastodonSignInCaptures.standingNames, "the whole standing, not the two alone")
            #expect(whole.object["showing_reblogs"] as? Bool == false && whole.object["notifying"] as? Bool == true)
            // Whatever is not a no is a yes there: this app sends the two words it means.
            let odd = try await ask(Self.account(id, "follow"), as: seeded.following, "POST", form: "reblogs=perhaps")
            #expect(odd.object["showing_reblogs"] as? Bool == true)
            #expect(try await follows.follow(id, false) == PersonStanding(accountID: id), "not followed: nothing is said of either")
            let raw = try await ask(Self.stands(id), as: seeded.following)
            #expect(raw.list.first?["showing_reblogs"] as? Bool == false && raw.list.first?["notifying"] as? Bool == false)
        }

        let locked = seeded.people.locked.id
        try await restoring(seeded, asked: locked) {
            let told = try await ask(Self.account(locked, "follow"), as: seeded.following, "POST", form: "notify=true")
            #expect(told.object["requested"] as? Bool == true && told.object["following"] as? Bool == false)
            #expect(told.object["notifying"] as? Bool == true && told.object["showing_reblogs"] as? Bool == true)
            let asked = PersonStanding(accountID: locked, requested: true)
            #expect(try await reader(seeded.following).standing(to: locked) == asked, "only asked: nothing is taken yet, so nothing is said of it")
            let back = try await ask(Self.account(locked, "follow"), as: seeded.following, "POST", form: "notify=false")
            #expect(back.object["notifying"] as? Bool == false && back.object["requested"] as? Bool == true)
        }
    }

    @Test("Requests to follow somebody are listed to them and answered by them: accepted, the whole standing says the asker follows; refused, that they do not; either again, of a request taken back, or of somebody who never asked, is refused as not found and changes nothing. A follower is removed and the standing says so; again, and of somebody who already left, it changes nothing; of somebody who has only asked, the request stays. A sign-in that only sees is listed its own and refused every change")
    func requestsAreAnswered() async throws {
        try await LocalServers.requireHealthy()
        let all = try LocalServers.seeded(), seeded = try seeded()
        // Asked as the seed's person with a sign-in of their own, locked for the length of
        // this: the writer's own requests are what other checks read, and are left alone.
        let me = seeded.people.hidden
        let asker = try #require(try await ask("/api/v1/accounts/verify_credentials", as: all.other).object["id"] as? String)
        func asks() async throws { _ = try await ask(Self.account(me.id, "follow"), as: all.other, "POST") }
        func leaves() async throws { _ = try await ask(Self.account(me.id, "unfollow"), as: all.other, "POST") }
        func listed(as token: String) async throws -> [String] {
            let people = MastodonPeople(door: MastodonAuthorized(
                token: MastodonToken(host: Self.host, accessToken: token, clientID: "x", clientSecret: "x"),
                sender: try LocalHTTP.client(), store: MemoryMastodonTokens()
            ))
            return try await people.stretch(.requests, source: Source(host: Self.host, kind: .mastodon), limit: 80).people.map(\.accountID)
        }
        _ = try await ask("/api/v1/accounts/update_credentials", as: me.token, "PATCH", form: "locked=true")
        let thrown: (any Error)?
        do {
            let answers = try reader(me.token)
            try await leaves()
            #expect(try await listed(as: me.token).isEmpty)
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await answers.answer(asker, accept: true) }
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await answers.answer(asker, accept: false) }

            try await asks()
            #expect(try await listed(as: me.token) == [asker])
            // Removing a follower does nothing to somebody who has only asked: they still ask.
            #expect(try await answers.removeFollower(asker).followedBy == false)
            #expect(try await listed(as: me.token) == [asker])
            let whole = try await ask("/api/v1/follow_requests/\(asker)/authorize", as: me.token, "POST")
            #expect(whole.text.contains(#""followed_by":true"#))
            #expect(Set(whole.object.keys) == MastodonSignInCaptures.standingNames, "the whole standing")
            #expect(try await listed(as: me.token).isEmpty)
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await answers.answer(asker, accept: true) }
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await answers.answer(asker, accept: false) }
            #expect(try await answers.standing(to: asker)?.followedBy == true, "answering twice changed nothing")

            #expect(try await answers.removeFollower(asker).followedBy == false)
            #expect(try await answers.removeFollower(asker).followedBy == false, "again: nothing to change")
            #expect(try await answers.standing(to: asker)?.followedBy == false)

            try await asks()
            #expect(try await answers.answer(asker, accept: false).followedBy == false)
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await answers.answer(asker, accept: false) }
            // Taken back before it is answered.
            try await asks()
            try await leaves()
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await answers.answer(asker, accept: true) }
            #expect(try await answers.standing(to: asker)?.followedBy == false, "nobody was let in")
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await answers.removeFollower("1999999999") }
            // How many ask is said by the account check alone, and nowhere on the list.
            let check = try await ask("/api/v1/accounts/verify_credentials", as: me.token).object
            #expect((check["source"] as? [String: Any])?["follow_requests_count"] as? Int == 0 && check["follow_requests_count"] == nil)
            thrown = nil
        } catch {
            thrown = error
        }
        try? await leaves()
        _ = try await ask("/api/v1/accounts/update_credentials", as: me.token, "PATCH", form: "locked=false")
        if let thrown { throw thrown }

        // The writer's own, with the word that only sees: listed, and every change refused.
        let sees = try reader(seeded.seeing)
        _ = try await listed(as: seeded.seeing)
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await sees.answer(asker, accept: true) }
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await sees.answer(asker, accept: false) }
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await sees.removeFollower(asker) }
        let none = try await ask("/api/v1/follow_requests")
        #expect(none.status == 401)
    }

    @Test("Somebody who must agree is asked and not followed, at every asking; unfollowing them is what withdraws the request, and the next read says so")
    func somebodyWhoMustAgree() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        let id = seeded.people.locked.id
        try await restoring(seeded, asked: id) {
            let follows = try reader(seeded.following)
            let asked = PersonStanding(accountID: id, requested: true)
            #expect(try await follows.standing(to: id) == asked, "as the seed left it")
            #expect(try await follows.follow(id, false) == PersonStanding(accountID: id), "withdrawn")
            #expect(try await follows.standing(to: id) == PersonStanding(accountID: id))
            #expect(try await follows.follow(id) == asked)
            #expect(try await follows.follow(id) == asked, "asked twice, answered the same")
            #expect(try await follows.standing(to: id) == asked)
        }
    }

    @Test("Following somebody who lives on another server is answered as followed, and the next read says asked: only a read says how it stands until their server agrees")
    func somebodyLivingElsewhere() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        let id = seeded.people.far.id
        try await restoring(seeded, unfollowed: [id]) {
            let follows = try reader(seeded.following)
            #expect(try await follows.standing(to: id) == PersonStanding(accountID: id))
            #expect(try await follows.follow(id) == PersonStanding(accountID: id, following: true, showsBoosts: true, notifies: false), "what the press was answered")
            #expect(try await follows.standing(to: id) == PersonStanding(accountID: id, requested: true), "and how it stands")
            #expect(try await follows.follow(id, false) == PersonStanding(accountID: id))
        }
    }

    @Test("Nobody is followed who blocks the reader, whom the reader blocks, or who moved — refused, and nothing changed; nor a suspended account, an id nobody has or the reader themselves; unfollowing any that is somebody is answered as it stood")
    func whoIsNotFollowed() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        let people = seeded.people
        let follows = try reader(seeded.following)
        let refusing = [people.blocker.id, people.blocked.id, people.moved.id]
        try await restoring(seeded, unfollowed: refusing) {
            for id in refusing {
                let before = try await follows.standing(to: id)
                let refused = try await ask(Self.account(id, "follow"), as: seeded.following, "POST")
                #expect(refused.status == 403, "\(id)")
                #expect(refused.text == Captures.notAllowed, "\(id)")
                #expect(refused.header("WWW-Authenticate") == nil, "not for want of a word")
                await #expect(throws: MastodonAuthError.http(403)) { _ = try await follows.follow(id) }
                #expect(try await follows.standing(to: id) == before, "nothing changed: \(id)")
                #expect(try await follows.follow(id, false) == before, "unfollowed as it stood: \(id)")
            }
            #expect(try await follows.standing(to: people.blocked.id)?.blocking == true, "the block stays")

            for id in [people.gone.id, "1999999999", "abc"] {
                let none = try await ask(Self.account(id, "follow"), as: seeded.following, "POST")
                #expect(none.status == 404, "\(id)")
                #expect(none.text == Captures.notFound, "\(id)")
            }
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await follows.follow(people.gone.id) }

            let me = try #require(try await ask("/api/v1/accounts/verify_credentials", as: seeded.writer).object["id"] as? String)
            let own = try await ask(Self.account(me, "follow"), as: seeded.following, "POST")
            #expect(own.status == 403)
            #expect(own.text == Captures.ownAccount)
            #expect(try await follows.follow(me, false) == PersonStanding(accountID: me))
        }
    }

    @Test("Somebody muted for a time is said to be muted until a moment, written to the second; muted for good, until none")
    func mutedForATime() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try seeded()
        let id = seeded.people.muted.id
        try await restoring(seeded, muted: id) {
            let stands = try reader(seeded.seeing)
            #expect(try await stands.standing(to: id) == PersonStanding(accountID: id, muting: true))
            let before = Date()
            #expect(try await ask(Self.account(id, "mute"), as: seeded.writer, "POST", form: "duration=3600").status == 200)
            let said = try #require(try await stands.standing(to: id))
            let until = try #require(said.mutedUntil)
            #expect(said.muting)
            let inAnHour = until.timeIntervalSince(before)
            #expect(inAnHour > 3500 && inAnHour < 3700, "an hour on: \(inAnHour)")
            let raw = try #require(try await ask(Self.stands(id), as: seeded.seeing).list.first?["muting_expires_at"] as? String)
            #expect(raw.count == Captures.mutedForATime.split(separator: "\"muting_expires_at\":\"")[1].prefix { $0 != "\"" }.count, "to the second: \(raw)")
        }
        #expect(try await reader(seeded.seeing).standing(to: id) == PersonStanding(accountID: id, muting: true))
    }
}
