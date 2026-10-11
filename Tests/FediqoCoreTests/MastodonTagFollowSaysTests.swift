import Foundation
import Testing
@testable import FediqoCore

/// #318: what Fediqo believes a Mastodon says of a hashtag followed, held against the real one
/// this checkout brings up (`make servers`, Mastodon 4.6.6) — every line of the table in
/// `MastodonTagFollowCaptures`. Each check goes through this app's own reader,
/// `MastodonTagFollows`, and beside it asks the server plainly for the part of the answer the
/// reader rests on.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **What a check follows it unfollows, however it ends** (`restoring`): by the sign-in that
/// followed, and again by the writer's own for everything. The hashtags themselves stay — a
/// Mastodon makes one by its being followed and has no way to unmake it — and say nothing of
/// anybody.
///
/// **Asked gently.** A run makes some hundred and twenty requests and no registration: every sign-in here
/// is the seed's.
@Suite("What a Mastodon says of a hashtag followed", .enabled(if: LocalServers.requested), .serialized)
struct MastodonTagFollowSaysTests {
    private typealias Captures = MastodonTagFollowCaptures

    private static let host = LocalServers.mastodon

    /// One answer, whole: its status, its headers, and its body as JSON where it is JSON.
    private struct Answer {
        let status: Int
        let response: HTTPURLResponse
        let body: Data

        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
        var object: [String: Any] { json as? [String: Any] ?? [:] }
        var names: [String] { (json as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
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

    /// The seed's sign-ins of the writer: one for everything, this app's reading words, those
    /// and the words that act on a post, those and the word that sees who they follow, and
    /// those and both words of follows. And a post of somebody else's the seed made.
    private struct SignIns {
        let writer: String
        let reading: String
        let acting: String
        let seeing: String
        let following: String
        let post: String
    }

    private func signIns() throws -> SignIns {
        let seeded = try LocalServers.seeded()
        let notices = try #require(seeded.notices, "servers/.run/mastodon-tokens.json was seeded before notices were: run `make servers` again")
        let seeing = try #require(seeded.people?.standing, "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again")
        let following = try #require(seeded.people?.following, "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again")
        return SignIns(
            writer: seeded.writer, reading: notices.reading.token, acting: notices.acting.token, seeing: seeing.token,
            following: following.token, post: seeded.seeded.plain
        )
    }

    private func reader(_ accessToken: String) throws -> MastodonTagFollows {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonTagFollows(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    private func tag(_ name: String) throws -> PostTag {
        try #require(PostTag("#" + name))
    }

    private static func escaped(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
    }

    /// Runs `body`, and then unfollows every one of `names` — as the writer's sign-in for
    /// everything, whatever became of `body` and of the sign-in it used.
    private func restoring(_ names: [String], as writer: String, _ body: () async throws -> Void) async throws {
        let thrown: (any Error)?
        do {
            try await body()
            thrown = nil
        } catch {
            thrown = error
        }
        var left: [String] = []
        for name in names {
            let undone = try? await ask("/api/v1/tags/\(Self.escaped(name))/unfollow", as: writer, "POST")
            if undone?.status != 200 { left.append(name) }
        }
        if let thrown { throw thrown }
        #expect(left.isEmpty, "left followed on the server: \(left)")
    }

    @Test("A hashtag is told to anyone, and whether the reader follows it only to a sign-in — to any sign-in, the reading words alone among them; a name nobody ever used is answered all the same")
    func aHashtagIsTold() async throws {
        try await LocalServers.requireHealthy()
        let signedIn = try signIns()
        let name = "fediqo318told"
        let path = "/api/v1/tags/\(name)"

        let unsigned = try await ask(path)
        #expect(unsigned.status == 200)
        #expect(Set(unsigned.object.keys) == ["id", "name", "url", "history"])
        #expect(unsigned.object["id"] as? String == "", "nobody ever used it: answered all the same, with no id")
        #expect(throws: MastodonTagFollowError.unreadable) { _ = try MastodonTagFollows.followed(in: unsigned.body) }

        for token in [signedIn.reading, signedIn.acting, signedIn.seeing, signedIn.following, signedIn.writer] {
            let told = try await ask(path, as: token)
            #expect(told.status == 200)
            #expect(Set(told.object.keys) == ["id", "name", "url", "history", "following", "featuring"])
            #expect(told.object["following"] as? Bool == false)
            #expect(told.object["name"] as? String == name)
        }
        #expect(try await reader(signedIn.following).isFollowed(try tag(name)) == false)
        #expect(try await reader(signedIn.reading).isFollowed(try tag(name)) == false)

        // How often it may be asked rides on every answer under the API.
        #expect(unsigned.header("X-RateLimit-Limit") == "300")
        let remaining = try #require(unsigned.header("X-RateLimit-Remaining").flatMap(Int.init))
        let within: Bool = remaining >= 0 && remaining <= 300
        #expect(within)
        let reset = try #require(unsigned.header("X-RateLimit-Reset"))
        let moment = ISO8601DateFormatter()
        moment.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(moment.date(from: reset) != nil, "a moment: \(reset)")
    }

    @Test("Following and unfollowing want the word that changes who the reader follows: refused to the reading words and to the word that only sees, in the words kept; with both words of follows it is followed, said so to every sign-in, followed again at no cost, unfollowed, and unfollowed again — and that sign-in still writes no post")
    func followingAndUnfollowing() async throws {
        try await LocalServers.requireHealthy()
        let signedIn = try signIns()
        let name = "fediqo318follow"
        let path = "/api/v1/tags/\(name)"
        try await restoring([name], as: signedIn.writer) {
            for act in ["follow", "unfollow"] {
                let nobody = try await ask("\(path)/\(act)", "POST")
                #expect(nobody.status == 401)
                #expect(String(decoding: nobody.body, as: UTF8.self) == Captures.noSignIn)
                for token in [signedIn.reading, signedIn.seeing, signedIn.acting] {
                    let refused = try await ask("\(path)/\(act)", as: token, "POST")
                    #expect(refused.status == 403)
                    #expect(String(decoding: refused.body, as: UTF8.self) == Captures.notGiven)
                    #expect(refused.header("WWW-Authenticate") == Captures.followRefusedHeader)
                }
            }
            await #expect(throws: MastodonAuthError.http(403)) { _ = try await reader(signedIn.seeing).follow(try tag(name)) }
            #expect(try await ask(path, as: signedIn.following).object["following"] as? Bool == false, "a refusal followed nothing")

            let follows = try reader(signedIn.following)
            #expect(try await follows.follow(try tag(name)) == true)
            #expect(try await follows.isFollowed(try tag(name)) == true)
            let made = try await ask(path, as: signedIn.reading)
            #expect(made.object["following"] as? Bool == true, "told to the reading words too")
            #expect(made.object["id"] as? String != "", "made by being followed")
            #expect(try await ask(path).object["following"] == nil, "and to nobody without a sign-in")
            #expect(try await follows.follow(try tag(name)) == true, "asked twice, answered the same")
            #expect(try await follows.follow(try tag(name), false) == false)
            #expect(try await follows.follow(try tag(name), false) == false)
            #expect(try await follows.isFollowed(try tag(name)) == false)
            // And one nobody ever used is unfollowed without complaint, and is not made by it.
            let never = try await ask("/api/v1/tags/fediqo318told/unfollow", as: signedIn.following, "POST")
            #expect(never.status == 200)
            #expect(never.object["following"] as? Bool == false)
            #expect(never.object["id"] as? String == "")

            // Holding follows is not writing: no post, and no favourite, for want of their own words.
            let post = try await ask("/api/v1/statuses", as: signedIn.following, "POST", form: "status=fediqo318+never+posted")
            #expect(post.status == 403)
            #expect(post.header("WWW-Authenticate")?.contains("_write write:statuses_") == true)
            let favourite = try await ask("/api/v1/statuses/\(signedIn.post)/favourite", as: signedIn.following, "POST")
            #expect(favourite.status == 403)
            #expect(favourite.header("WWW-Authenticate")?.contains("_write write:favourites_") == true)
            if favourite.status == 200 {
                _ = try? await ask("/api/v1/statuses/\(signedIn.post)/unfavourite", as: signedIn.writer, "POST")
            }
            if let posted = post.object["id"] as? String {
                _ = try? await ask("/api/v1/statuses/\(posted)", as: signedIn.writer, "DELETE")
            }
        }
    }

    @Test("A name is one hashtag whatever case, width or accent it is asked in, and is named as it was first written; a name in another script goes percent-encoded; a name with its mark, a space, a slash, an emoji, a full stop or digits alone is no hashtag there, to be followed or to be asked about; and the server sets no bound on a name — three hundred letters are one — so this app does")
    func names() async throws {
        try await LocalServers.requireHealthy()
        let signedIn = try signIns()
        let long = String(repeating: "f", count: MastodonTagFollows.nameLength)
        let endless = String(repeating: "f", count: 300)
        let made = ["FediQo318Case", "café318", "標籤318", long, long + "f", endless]
        try await restoring(made, as: signedIn.writer) {
            let follows = try reader(signedIn.following)
            #expect(try await follows.follow(try tag("FediQo318Case")) == true)
            #expect(try await follows.isFollowed(try tag("fediqo318case")) == true)
            #expect(try await follows.isFollowed(try tag("ＦＥＤＩＱＯ３１８ＣＡＳＥ")) == true)
            let named = try await ask("/api/v1/tags/FEDIQO318CASE", as: signedIn.following)
            #expect(named.object["name"] as? String == "FediQo318Case")
            #expect(named.object["url"] as? String == "https://\(Self.host)/tags/fediqo318case")

            #expect(try await follows.follow(try tag("café318")) == true)
            #expect(try await follows.isFollowed(try tag("cafe318")) == true)
            #expect(try await ask("/api/v1/tags/cafe318", as: signedIn.following).object["name"] as? String == "café318")
            #expect(try await follows.follow(try tag("標籤318")) == true)
            #expect(try await ask("/api/v1/tags/%E6%A8%99%E7%B1%A4318", as: signedIn.following).object["name"] as? String == "標籤318")

            for not in ["%23fediqo318a", "fediqo318%20b", "fediqo318%2Fb", "318318", Self.escaped("fediqo318😀")] {
                for (method, act) in [("GET", ""), ("POST", "/follow")] {
                    let answer = try await ask("/api/v1/tags/\(not)\(act)", as: signedIn.following, method)
                    #expect(answer.status == 404, "\(method) \(not)")
                    #expect(String(decoding: answer.body, as: UTF8.self) == Captures.notFound, "\(method) \(not)")
                }
            }
            // Through this app's reader, a name of digits alone is the source's not-found.
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await follows.isFollowed(try tag("318318")) }
            // With a full stop in it the answer is not the API's at all: a page.
            let dotted = try await ask("/api/v1/tags/fediqo318.b/follow", as: signedIn.following, "POST")
            #expect(dotted.status == 404)
            #expect(String(decoding: dotted.body.prefix(15), as: UTF8.self) == "<!DOCTYPE html>")
            #expect(dotted.header("X-RateLimit-Limit") == nil, "and says nothing of how often")

            // The longest name this app asks about is followed; one letter more the server
            // would take too, and this app does not ask.
            #expect(try await follows.follow(try tag(long)) == true)
            let longer = try await ask("/api/v1/tags/\(long)f/follow", as: signedIn.following, "POST")
            #expect(longer.status == 200)
            let longest = try await ask("/api/v1/tags/\(endless)/follow", as: signedIn.following, "POST")
            #expect(longest.status == 200)
            #expect(longest.object["name"] as? String == endless)
            #expect(longest.object["following"] as? Bool == true)
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await follows.follow(try tag(long + "f")) }
        }
    }

    @Test("The followed ones want the word that sees who the reader follows; they come the one followed last first, a stretch at a time by the answer's own word for what is next — an id no row carries — to a last stretch that names no next; a length of none or of no number is the server's own failure, which this app never asks for; a length below none is one; and a place that is past the end or no number is an empty list")
    func theFollowedOnes() async throws {
        try await LocalServers.requireHealthy()
        let signedIn = try signIns()
        let names = (1...5).map { "fediqo318p\($0)" }
        let list = "/api/v1/followed_tags"
        try await restoring(names, as: signedIn.writer) {
            #expect(try await ask(list).status == 401)
            for token in [signedIn.reading, signedIn.acting] {
                let refused = try await ask(list, as: token)
                #expect(refused.status == 403)
                #expect(String(decoding: refused.body, as: UTF8.self) == Captures.notGiven)
                #expect(refused.header("WWW-Authenticate") == Captures.listRefusedHeader)
            }
            #expect(try await ask(list, as: signedIn.seeing).status == 200, "the word that sees is enough to list")

            let follows = try reader(signedIn.following)
            for name in names { #expect(try await follows.follow(try tag(name)) == true) }

            // Through this app's reader, two at a time, to the end.
            var read = FollowedTagsRead()
            var stretches = 0
            repeat {
                read = try read.readingOn(try await follows.followed(after: read.next, limit: 2))
                stretches += 1
            } while read.next != nil && stretches < 20
            #expect(read.ended)
            #expect(Array(read.tags.map(\.name).prefix(5)) == names.reversed(), "the one followed last comes first")
            let whole = try await follows.followed()
            #expect(whole.tags == read.tags)
            #expect(whole.next == nil)

            // And plainly: what names the next is the id of a follow, which is no row's id.
            let first = try await ask("\(list)?limit=2", as: signedIn.following)
            #expect(first.names == ["fediqo318p5", "fediqo318p4"])
            let link = try #require(first.header("Link"))
            #expect(link.contains(#"rel="next""#))
            #expect(link.contains(#"rel="prev""#))
            let next = try #require(try MastodonLink.next(in: link))
            let ids = (first.json as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            #expect(!ids.contains(next), "the place is not the id of a hashtag given")
            let second = try await ask("\(list)?limit=2&max_id=\(next)", as: signedIn.following)
            #expect(second.names == ["fediqo318p3", "fediqo318p2"])
            #expect(second.header("Link")?.contains(#"rel="prev""#) == true)
            let onward = try #require(try MastodonLink.next(in: second.header("Link")))
            let third = try await ask("\(list)?limit=2&max_id=\(onward)", as: signedIn.following)
            #expect(third.names == ["fediqo318p1"])
            #expect(try MastodonLink.next(in: third.header("Link")) == nil, "the last stretch names no next")
            #expect(third.header("Link")?.contains(#"rel="prev""#) == true)
            for told in [first, second, third] {
                let following = (told.json as? [[String: Any]] ?? []).map { $0["following"] as? Bool }
                #expect(following.allSatisfy { $0 == true }, "each is said to be followed")
            }

            let last = try await ask("\(list)?limit=200", as: signedIn.following)
            #expect(last.status == 200)
            #expect(try MastodonLink.next(in: last.header("Link")) == nil, "no next is the end")
            #expect(last.header("Link")?.contains(#"rel="prev""#) == true)

            for none in ["0", "x"] {
                let failed = try await ask("\(list)?limit=\(none)", as: signedIn.following)
                #expect(failed.status == 500, "limit=\(none)")
                #expect(String(decoding: failed.body.prefix(15), as: UTF8.self) == "<!DOCTYPE html>", "limit=\(none)")
            }
            let below = try await ask("\(list)?limit=-1", as: signedIn.following)
            #expect(below.status == 200)
            #expect(below.names == ["fediqo318p5"], "a length below none is one")
            #expect(try await follows.followed(limit: 0).tags.count == 1, "asked for one, never for none")
            let over = try await ask("\(list)?limit=1000", as: signedIn.following)
            #expect(over.status == 200)
            #expect(over.names == names.reversed())
            for place in ["0", "junk"] {
                let past = try await ask("\(list)?max_id=\(place)", as: signedIn.following)
                #expect(past.status == 200, "max_id=\(place)")
                #expect(String(decoding: past.body, as: UTF8.self) == "[]", "max_id=\(place)")
                #expect(past.header("Link") == nil, "max_id=\(place)")
            }
        }
        let after = try await ask("\(list)?limit=200", as: signedIn.writer)
        #expect(!after.names.contains { $0.hasPrefix("fediqo318") }, "everything followed here was unfollowed")
    }
}
