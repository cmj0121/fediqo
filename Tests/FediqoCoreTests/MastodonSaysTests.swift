import Foundation
import Testing
@testable import FediqoCore

/// #298: what Fediqo believes a Mastodon source says, held against the real one this checkout
/// brings up (`make servers`, Mastodon 4.6.6). Each check speaks to that server, says what it
/// answered, and — where this app has a reader for it — reads the same answer through that
/// reader, so a belief the code rests on is pinned to the server's own word and not to an
/// answer written by hand.
///
/// **Passed over where the servers are not up**, as `LocalServerTests`' are: the gate is the
/// same trait, and `requireHealthy()` is the first line of every check.
///
/// **What is seeded and what is made here.** A second person, a follow, a list, a post changed
/// once, a reblog and a rising post are `servers/mastodon/seed.rb`'s: this server runs no
/// background worker, so nothing reaches a home, a list or the rising posts by itself. Every
/// other post a check needs it writes through the server's own API as it runs.
///
/// **Asked gently.** A run makes a few dozen requests, one registration, and — to hear how this
/// server says "slow down" at all — walks its smallest limit, five sign-ups in half an hour,
/// which is six small requests nothing else here makes.
@Suite("What a Mastodon says", .enabled(if: LocalServers.requested), .serialized)
struct MastodonSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)
    private static let marks = ["reblogged", "favourited", "bookmarked"]

    /// Who asks: nobody, the writer's first sign-in (which may not bookmark), or a sign-in of
    /// the writer or of the other person that may do everything a person can.
    private enum Who {
        case nobody, limited, writer, other

        func token() throws -> String? {
            switch self {
            case .nobody: nil
            case .limited: try LocalServers.writerToken()
            case .writer: try LocalServers.seeded().writer
            case .other: try LocalServers.seeded().other
            }
        }
    }

    /// One answer, whole: its status, its headers, and its body as JSON where it is JSON.
    private struct Answer {
        let status: Int
        let response: HTTPURLResponse
        let body: Data

        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
        var object: [String: Any] { json as? [String: Any] ?? [:] }
        var list: [[String: Any]] { json as? [[String: Any]] ?? [] }
        var error: String? { object["error"] as? String }
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
    }

    private func ask(
        _ who: Who, _ method: String = "GET", _ path: String, _ form: [(String, String)] = [], language: String = "en"
    ) async throws -> Answer {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Asked for in English, so what is asserted of a sentence does not depend on the
        // language of the machine the checks run on.
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        if let token = try who.token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !form.isEmpty {
            var fields = URLComponents()
            fields.queryItems = form.map { URLQueryItem(name: $0.0, value: $0.1) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data((fields.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        }
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, response: response, body: body)
    }

    /// A post written through the server's own API, and its id there.
    private func post(
        as who: Who, _ words: String, visibility: String = "public", answering: String? = nil, quoting: String? = nil
    ) async throws -> String {
        var form = [("status", "\(words) \(UUID().uuidString.prefix(8))"), ("visibility", visibility), ("quote_approval_policy", "public")]
        if let answering { form.append(("in_reply_to_id", answering)) }
        if let quoting { form.append(("quoted_status_id", quoting)) }
        let made = try await ask(who, "POST", "/api/v1/statuses", form)
        #expect(made.status == 200, "the post was not taken: \(made.error ?? "")")
        return try #require(made.object["id"] as? String)
    }

    private func decoded(_ answer: Answer) throws -> StatusDTO {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: answer.body)
    }

    private func door(_ who: Who) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: try #require(try who.token()), clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)
    }

    // MARK: - 1. A reblog

    @Test("A reblog as the source hands it over has an id, a name and a time of its own, carries the post it reblogs, and says nothing of its own; a timeline lists it under its own id; a reblog of a reblog is a reblog of the post")
    func aReblog() async throws {
        try await LocalServers.requireHealthy()
        let post = try await post(as: .other, "to be reblogged")
        let made = try await ask(.writer, "POST", "/api/v1/statuses/\(post)/reblog")
        #expect(made.status == 200)
        let wrapper = made.object
        let inner = try #require(wrapper["reblog"] as? [String: Any])
        let wrapperID = try #require(wrapper["id"] as? String)
        #expect(wrapperID != post && inner["id"] as? String == post)
        let wrapperURI = try #require(wrapper["uri"] as? String), innerURI = try #require(inner["uri"] as? String)
        #expect(wrapperURI != innerURI && wrapperURI.hasSuffix("/activity"), "a name of its own: \(wrapperURI)")
        #expect(wrapper["created_at"] as? String != inner["created_at"] as? String, "and a time of its own")
        #expect(wrapper["content"] as? String == "", "no words of its own")
        #expect(inner["reblog"] is NSNull || inner["reblog"] == nil, "one level")

        // Read the way this app reads it: an item for the reblog, and the post beside it.
        let arrived = try decoded(made).arrival(source: Self.source, categories: [.home], sent: .now())
        #expect(arrived.item.isReblog && arrived.item.id == wrapperURI && arrived.item.statusID == wrapperID)
        #expect(arrived.item.reblogKey == NoteKey(host: Self.host, id: innerURI))
        #expect(arrived.reblogged?.id == innerURI && arrived.reblogged?.statusID == post)
        #expect(arrived.item.postedAt != arrived.reblogged?.postedAt)

        // What a timeline lists is the reblog, under the reblog's id: the seeded one, in Home.
        let seeded = try LocalServers.seeded().seeded
        let home = try await ask(.writer, "GET", "/api/v1/timelines/home?limit=40").list
        let listed = try #require(home.first { $0["id"] as? String == seeded.reblog }, "the seeded reblog is in the writer's home")
        #expect((listed["reblog"] as? [String: Any])?["id"] as? String == seeded.reblogged)
        #expect(!home.contains { $0["id"] as? String == seeded.reblogged }, "the post it reblogs is not listed beside it")

        // A reblog of a reblog: the server makes a reblog of the post, never of the reblog.
        let again = try await ask(.other, "POST", "/api/v1/statuses/\(wrapperID)/reblog")
        #expect(again.status == 200)
        #expect((again.object["reblog"] as? [String: Any])?["id"] as? String == post)
        _ = try await ask(.other, "POST", "/api/v1/statuses/\(post)/unreblog")
        _ = try await ask(.writer, "POST", "/api/v1/statuses/\(post)/unreblog")
    }

    // MARK: - 2. What a read says of the reader

    /// Every status a read brought, and the status inside each reblog and each quote.
    private func statuses(in answer: Answer, at key: String? = nil) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func take(_ status: [String: Any]) {
            found.append(status)
            if let inner = status["reblog"] as? [String: Any] { take(inner) }
            if let quoted = (status["quote"] as? [String: Any])?["quoted_status"] as? [String: Any] { take(quoted) }
        }
        if let key {
            ((answer.object[key] as? [[String: Any]]) ?? []).forEach(take)
        } else if let one = answer.json as? [String: Any], one["id"] != nil {
            take(one)
        } else {
            answer.list.forEach(take)
        }
        return found
    }

    @Test("A signed read says of every status whether the reader reblogged, favourited and bookmarked it — on Home, a list, the public timeline, what is rising, a search, one post, its conversation and a tag — and the same read unsigned says none of the three, where it can be made unsigned at all")
    func whatAReadSaysOfTheReader() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded().seeded
        let tag = "fediqo298\(UUID().uuidString.prefix(6).lowercased())"
        let root = try await post(as: .other, "tagged #\(tag)")
        _ = try await post(as: .other, "an answer", answering: root)
        let address = try #require(try await ask(.nobody, "GET", "/api/v1/statuses/\(root)").object["url"] as? String)
        let search = "/api/v2/search?type=statuses&resolve=true&q=\(address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"

        // (what, path, the key its statuses are under, whether an unsigned read brings posts)
        let reads: [(String, String, String?, Bool)] = [
            ("home", "/api/v1/timelines/home?limit=40", nil, false),
            ("a list", "/api/v1/timelines/list/\(seeded.list)?limit=40", nil, false),
            ("public", "/api/v1/timelines/public?limit=40", nil, true),
            ("rising", "/api/v1/trends/statuses", nil, true),
            ("search", search, "statuses", false),
            ("one post", "/api/v1/statuses/\(root)", nil, true),
            ("its conversation", "/api/v1/statuses/\(root)/context", "descendants", true),
            ("a tag", "/api/v1/timelines/tag/\(tag)", nil, true),
        ]
        for (what, path, key, unsignedBrings) in reads {
            for who in [Who.writer, .limited] {
                let answer = try await ask(who, "GET", path)
                let read = statuses(in: answer, at: key)
                #expect(answer.status == 200 && !read.isEmpty, "\(what), signed: the read brought nothing to judge by")
                for status in read {
                    for mark in Self.marks {
                        #expect(status[mark] is Bool, "\(what), signed: a status says nothing of `\(mark)`")
                    }
                }
            }
            let unsigned = try await ask(.nobody, "GET", path)
            let read = statuses(in: unsigned, at: key)
            if unsignedBrings {
                #expect(unsigned.status == 200 && !read.isEmpty, "\(what), unsigned: the read brought nothing to judge by")
            } else {
                // Home and a list are nobody's without a sign-in; a search that resolves an
                // address is refused; none of them brings a post.
                #expect(unsigned.status == 401 && read.isEmpty, "\(what), unsigned: \(unsigned.status)")
            }
            for status in read {
                for mark in Self.marks {
                    #expect(status[mark] == nil, "\(what), unsigned: a status states `\(mark)`")
                }
            }
        }

        // And through this app's own readers: a copy read as the reader carries the marks, and
        // the same post read unsigned carries none — which is what tells the two apart later.
        let asReader = try await MastodonPost(door: try door(.writer)).post(id: root, source: Self.source)
        #expect(asReader.boosted == false && asReader.favourited == false && asReader.bookmarked == false)
        let asNobody = try await MastodonPost(http: try LocalHTTP.client(), host: Self.host).post(id: root, source: Self.source)
        #expect(asNobody.boosted == nil && asNobody.favourited == nil && asNobody.bookmarked == nil)
        let thread = try await MastodonPost(door: try door(.writer)).conversation(id: root, source: Self.source)
        #expect(thread.descendants.count == 1 && thread.descendants.allSatisfy { $0.favourited != nil })
        let found = try await MastodonTag(door: try door(.writer)).posts(under: try #require(PostTag("#" + tag)), source: Self.source)
        #expect(found.count == 1 && found.allSatisfy { $0.boosted != nil && $0.categories.isEmpty })
    }

    // MARK: - 3. A post that was changed

    @Test("A post that was changed says when, on every read that brings it, signed or not, and inside a reblog and a quote; one never changed says a null, and a reblog says nothing of its own")
    func aChangedPostSaysWhen() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded().seeded
        let tag = "fediqo298e\(UUID().uuidString.prefix(6).lowercased())"
        let changed = try await post(as: .other, "before #\(tag)")
        let never = try await post(as: .other, "never changed #\(tag)")
        let edit = try await ask(.other, "PUT", "/api/v1/statuses/\(changed)", [("status", "after #\(tag)"), ("quote_approval_policy", "public")])
        #expect(edit.status == 200)
        let moment = try #require(edit.object["edited_at"] as? String, "the edit's own answer says when")
        #expect(MastodonJSON.date(from: moment) != nil, "in a spelling this app reads: \(moment)")
        _ = try await post(as: .other, "an answer", answering: changed)
        let answer = try await post(as: .other, "an answer to the changed one", answering: changed)

        func says(_ status: [String: Any]?) -> String? { status?["edited_at"] as? String }
        for who in [Who.writer, .nobody] {
            let one = try await ask(who, "GET", "/api/v1/statuses/\(changed)").object
            #expect(says(one) == moment, "one post")
            let tagged = try await ask(who, "GET", "/api/v1/timelines/tag/\(tag)").list
            #expect(says(tagged.first { $0["id"] as? String == changed }) == moment, "a tag")
            let other = try #require(tagged.first { $0["id"] as? String == never })
            #expect(other.keys.contains("edited_at") && other["edited_at"] is NSNull, "never changed: the key is there, and null")
            let around = try await ask(who, "GET", "/api/v1/statuses/\(answer)/context").object
            #expect(says((around["ancestors"] as? [[String: Any]])?.first) == moment, "a conversation")
            let everybody = try await ask(who, "GET", "/api/v1/timelines/public?limit=40").list
            #expect(says(everybody.first { $0["id"] as? String == changed }) == moment, "public")
            let rising = try await ask(who, "GET", "/api/v1/trends/statuses").list
            #expect(says(rising.first { $0["id"] as? String == seeded.edited }) != nil, "rising: the seeded changed post")
        }
        for path in ["/api/v1/timelines/home?limit=40", "/api/v1/timelines/list/\(seeded.list)?limit=40"] {
            let read = try await ask(.writer, "GET", path).list
            #expect(says(read.first { $0["id"] as? String == seeded.edited }) != nil, "\(path): the seeded changed post")
            #expect(read.first { $0["id"] as? String == seeded.plain }?["edited_at"] is NSNull, "\(path): the seeded plain one")
        }

        // Inside a reblog: the post says when; the reblog itself says null.
        let reblog = try await ask(.writer, "POST", "/api/v1/statuses/\(changed)/reblog")
        #expect(reblog.object["edited_at"] is NSNull && says(reblog.object["reblog"] as? [String: Any]) == moment)
        let arrived = try decoded(reblog).arrival(source: Self.source, categories: [.home], sent: .now())
        #expect(arrived.item.editedAt == nil && arrived.reblogged?.editedAt == MastodonJSON.date(from: moment))
        _ = try await ask(.writer, "POST", "/api/v1/statuses/\(changed)/unreblog")

        // Inside a quote: the quoted status says when, and the copy this app takes in beside
        // the quoting post carries it.
        let quoting = try await post(as: .writer, "quoting the changed one", quoting: changed)
        let quote = try await ask(.writer, "GET", "/api/v1/statuses/\(quoting)")
        #expect(says((quote.object["quote"] as? [String: Any])?["quoted_status"] as? [String: Any]) == moment)
        let note = try decoded(quote).asNote(source: Self.source, categories: [], sent: .now())
        #expect(note.brought.first?.editedAt == MastodonJSON.date(from: moment) && note.editedAt == nil)
    }

    // MARK: - 4. Being asked less

    @Test("Every answer says how many asks are left and when that renews, as a date; asked past a limit the source answers 429 with the same three and no time to wait in seconds — and this app reads both")
    func askedLess() async throws {
        try await LocalServers.requireHealthy()
        for who in [Who.nobody, .writer] {
            let ordinary = try await ask(who, "GET", "/api/v1/statuses/\(try LocalServers.seeded().seeded.plain)")
            #expect(ordinary.status == 200)
            #expect(ordinary.header("X-RateLimit-Limit") == "300")
            #expect(Int(ordinary.header("X-RateLimit-Remaining") ?? "") != nil)
            let reset = try #require(ordinary.header("X-RateLimit-Reset"))
            #expect(Double(reset) == nil, "a date, and not a number of seconds: \(reset)")
            #expect(ordinary.header("Retry-After") == nil)
            let word = try #require(SourceWord(ordinary.response, now: Date()))
            #expect(word.limit == 300 && word.remaining != nil && word.retryAfter == nil)
            let renews = try #require(word.reset, "this app reads the date the source wrote: \(reset)")
            #expect(renews > Date().addingTimeInterval(-60) && renews < Date().addingTimeInterval(360), "within the five minutes the allowance is for")
        }

        // The server's smallest limit: five sign-ups in half an hour, from anywhere. Six asks
        // that sign nobody up reach it; a run soon after another finds it reached already.
        var refused: Answer?
        for _ in 0 ..< 7 where refused == nil {
            let answer = try await ask(.nobody, "POST", "/api/v1/accounts", [("x", "1")])
            if answer.status == 429 { refused = answer } else { #expect(answer.status == 401) }
        }
        let slow = try #require(refused, "the source never said to slow down")
        #expect(slow.error == "Too many requests")
        #expect(slow.header("Retry-After") == nil, "it does not say how long in seconds")
        #expect(slow.header("X-RateLimit-Limit") == "5" && slow.header("X-RateLimit-Remaining") == "0")
        let word = try #require(SourceWord(slow.response, now: Date()))
        let renews = try #require(word.reset)
        #expect(word.retryAfter == nil && word.remaining == 0 && renews > Date() && renews < Date().addingTimeInterval(1_860))

        // What a source's line of loads makes of that answer: left alone until the moment the
        // source named, with no other word to go by.
        let pacer = LoadPacer()
        await pacer.heard(host: Self.host, slow.response)
        let standing = await pacer.standing(host: Self.host)
        let wait = renews.timeIntervalSinceNow
        if wait > LoadLimits().longestPause {
            #expect(standing.givenUp, "a wait longer than this app waits: the source is left for the run (\(Int(wait)) s)")
        } else {
            let quiet = try #require(standing.quietFor)
            #expect(quiet > 0 && quiet <= wait + 5, "left alone until the allowance renews: \(quiet)")
        }
    }

    // MARK: - 5. Bookmarking

    @Test("A sign-in that may bookmark does, and takes it back, and the post then says so; one that may not is refused with 403 and the scope it lacks; a registration naming a scope the server does not know is refused in words this app reads as a refusal of its scopes")
    func bookmarking() async throws {
        try await LocalServers.requireHealthy()
        let post = try await post(as: .other, "to be bookmarked")
        let on = try await ask(.writer, "POST", "/api/v1/statuses/\(post)/bookmark")
        #expect(on.status == 200 && on.object["bookmarked"] as? Bool == true)
        #expect(try await ask(.writer, "GET", "/api/v1/statuses/\(post)").object["bookmarked"] as? Bool == true)
        let off = try await ask(.writer, "POST", "/api/v1/statuses/\(post)/unbookmark")
        #expect(off.status == 200 && off.object["bookmarked"] as? Bool == false)

        let refused = try await ask(.limited, "POST", "/api/v1/statuses/\(post)/bookmark")
        #expect(refused.status == 403 && refused.error == "This action is outside the authorized scopes")
        #expect(refused.header("WWW-Authenticate")?.contains(#"error="insufficient_scope""#) == true)
        #expect(refused.header("WWW-Authenticate")?.contains("write:bookmarks") == true)
        #expect(try await ask(.limited, "GET", "/api/v1/statuses/\(post)").object["bookmarked"] as? Bool == false, "though it may read whether it is")

        // One registration a run — this server takes five in ten minutes from anywhere — made
        // through this app's own registering, so what it asks and what it makes of the answer
        // are both the real ones.
        let heard = Heard(try LocalHTTP.client())
        await #expect(throws: MastodonSignInError.invalidScope) {
            _ = try await MastodonOAuth(host: Self.host, sender: heard).register(scopes: "read write:nonsense")
        }
        let unknown = try #require(await heard.last)
        #expect(unknown.response.statusCode == 422)
        // In English because it was asked for in English: a device set to another language is
        // answered in that language otherwise, and the sentence no longer names the scopes.
        #expect(unknown.request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(String(decoding: unknown.body, as: UTF8.self) == #"{"error":"Validation failed: Scopes doesn't match those configured on the server."}"#)
    }

    @Test("The sign-in page, asked for a scope its registration does not include, shows its own page saying so and sends the person nowhere: no redirect, no error to read, no state back; asked for what was registered it shows the page to approve")
    func theSignInPageAndAScopeNotRegistered() async throws {
        try await LocalServers.requireHealthy()
        let browser = try LocalHTTP.browser()
        let client = try LocalServers.seeded().client
        func page(scope: String) async throws -> (Data, HTTPURLResponse) {
            var address = URLComponents(string: "https://\(Self.host)/oauth/authorize")!
            address.queryItems = [
                URLQueryItem(name: "client_id", value: client), URLQueryItem(name: "redirect_uri", value: "urn:ietf:wg:oauth:2.0:oob"),
                URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "state", value: "st298"),
            ]
            return try await browser.send(URLRequest(url: try #require(address.url)))
        }
        // Nobody signed in at the browser: sent to sign in, whatever was asked for.
        let before = try await page(scope: "read follow")
        #expect(before.1.statusCode == 302 && before.1.value(forHTTPHeaderField: "Location")?.hasSuffix("/auth/sign_in") == true)

        // Signed in as a person at a browser is: the form's own token, then the password.
        let form = try await browser.send(URLRequest(url: URL(string: "https://\(Self.host)/auth/sign_in")!))
        let html = String(decoding: form.0, as: UTF8.self)
        let marker = #"name="authenticity_token" value=""#
        let start = try #require(html.range(of: marker)?.upperBound, "the sign-in form")
        let csrf = String(html[start...].prefix { $0 != "\"" })
        var signIn = URLRequest(url: URL(string: "https://\(Self.host)/auth/sign_in")!)
        signIn.httpMethod = "POST"
        var fields = URLComponents()
        fields.queryItems = [
            URLQueryItem(name: "authenticity_token", value: csrf), URLQueryItem(name: "user[email]", value: "writer@example.com"),
            URLQueryItem(name: "user[password]", value: "LocalOnlyPass1"),
        ]
        signIn.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        signIn.httpBody = Data((fields.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        #expect(try await browser.send(signIn).1.statusCode == 302, "signed in")

        // `follow` is a scope this server knows and the seeded registration ("read write") lacks.
        let refused = try await page(scope: "read follow")
        #expect(refused.1.statusCode == 400)
        #expect(refused.1.value(forHTTPHeaderField: "Location") == nil, "it redirects nowhere, so there is no `error=invalid_scope` and no `state` for this app to read")
        #expect(refused.1.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true, "a page of its own, in the person's language")
        // Asked for what was registered, the same person is taken on: the page to approve, or
        // — this app having been approved by them before — straight to the code.
        let granted = try await page(scope: "read write")
        let onward = granted.1.value(forHTTPHeaderField: "Location") ?? ""
        #expect(granted.1.statusCode == 200 || (granted.1.statusCode == 302 && onward.contains("code=")), "\(granted.1.statusCode) \(onward.prefix(60))")
    }

    // MARK: - 6. A post that is not there

    @Test("A post that was deleted answers 404 with the same body to a signed read and an unsigned one — never 410 — and so does a post the reader may not see: nothing in the answer tells the two apart")
    func aPostThatIsNotThere() async throws {
        try await LocalServers.requireHealthy()
        let deleted = try await post(as: .other, "to be deleted")
        #expect(try await ask(.other, "DELETE", "/api/v1/statuses/\(deleted)").status == 200)
        let followersOnly = try await post(as: .other, "followers only", visibility: "private")
        let direct = try await post(as: .other, "direct, to nobody", visibility: "direct")

        var answers: [String: Answer] = [:]
        answers["deleted, signed"] = try await ask(.writer, "GET", "/api/v1/statuses/\(deleted)")
        answers["deleted, unsigned"] = try await ask(.nobody, "GET", "/api/v1/statuses/\(deleted)")
        answers["never there, unsigned"] = try await ask(.nobody, "GET", "/api/v1/statuses/1")
        answers["followers only, unsigned"] = try await ask(.nobody, "GET", "/api/v1/statuses/\(followersOnly)")
        answers["direct to nobody, signed as somebody else"] = try await ask(.writer, "GET", "/api/v1/statuses/\(direct)")
        answers["its conversation, the same"] = try await ask(.writer, "GET", "/api/v1/statuses/\(direct)/context")
        for (what, answer) in answers {
            #expect(answer.status == 404, "\(what): \(answer.status)")
            #expect(String(decoding: answer.body, as: UTF8.self) == #"{"error":"Not Found"}"#, "\(what)")
        }
        // The follower, signed in, is shown the followers-only post: it exists.
        #expect(try await ask(.writer, "GET", "/api/v1/statuses/\(followersOnly)").status == 200)

        // Through this app's reader: both are the same refusal, and what #179 makes of it for a
        // post held — a question where signed, an answer where not, and never for a post
        // written for fewer than everyone.
        for id in [deleted, direct] {
            do {
                _ = try await MastodonPost(door: try door(.writer)).post(id: id, source: Self.source)
                Issue.record("the read of \(id) came back")
            } catch {
                let held = Note(
                    id: "x", source: Self.source, author: "a", handle: "@a@\(Self.host)", body: "b", postedAt: Date(),
                    categories: [], audience: .everyone
                )
                #expect(MastodonPost.saysGone(error, about: held, signedIn: true) == .ask)
                #expect(MastodonPost.saysGone(error, about: held, signedIn: false) == .gone)
            }
        }
    }

    // MARK: - 7. A conversation with a post the reader may not see

    @Test("A conversation that holds an answer to a post the reader may not see hands the answer over, saying it answers that post, and hands that post over nowhere — below, and above too, where the chain it gives skips the post it will not show")
    func aConversationWithAPostWithheld() async throws {
        try await LocalServers.requireHealthy()
        let root = try await post(as: .other, "the start")
        let hidden = try await post(as: .other, "to nobody", visibility: "direct", answering: root)
        let answer = try await post(as: .other, "an answer to the one withheld", answering: hidden)
        let further = try await post(as: .other, "an answer to the answer", answering: answer)

        for who in [Who.writer, .nobody] {
            let below = try await ask(who, "GET", "/api/v1/statuses/\(root)/context").object
            let descendants = try #require(below["descendants"] as? [[String: Any]])
            #expect(descendants.map { $0["id"] as? String } == [answer, further], "the withheld post is not among them")
            #expect(descendants.first?["in_reply_to_id"] as? String == hidden, "and the answer says it answers it")

            let above = try await ask(who, "GET", "/api/v1/statuses/\(answer)/context").object
            let ancestors = try #require(above["ancestors"] as? [[String: Any]])
            #expect(ancestors.map { $0["id"] as? String } == [root], "the chain above skips the withheld post")
            #expect(ancestors.first?["in_reply_to_id"] is NSNull, "so the post directly above is not what the answer answers")
        }

        // Read by this app and laid as the opened view lays it: the answer stands under the
        // start for the run that read it, at the first step, with its own answer under it.
        let thread = try await MastodonPost(door: try door(.writer)).conversation(id: root, source: Self.source)
        let opened = try await MastodonPost(door: try door(.writer)).post(id: root, source: Self.source)
        let view = Opened.around(opened, among: [opened] + thread.descendants, said: Set(thread.descendants.map(\.key)))
        #expect(view.below.map(\.statusID) == [answer, further])
        #expect(view.loose == [try #require(thread.descendants.first?.key)])
        #expect(Opened.around(opened, among: [opened] + thread.descendants).below.isEmpty, "by references alone it has no place")
        // And above: the start the source handed over is not what the answer says it answers,
        // so references alone put nothing above the answer.
        let fromAnswer = try await MastodonPost(door: try door(.writer)).conversation(id: answer, source: Self.source)
        let answerNote = try #require(thread.descendants.first)
        #expect(fromAnswer.ancestors.map(\.statusID) == [root])
        #expect(Opened.around(answerNote, among: [answerNote] + fromAnswer.ancestors).above.isEmpty)
        // With what the read said stands above, the start is drawn beyond the withheld post.
        let laid = Opened.around(answerNote, among: [answerNote] + fromAnswer.ancestors, saidAbove: fromAnswer.ancestors.map(\.key))
        #expect(laid.above.isEmpty && laid.beyond.map(\.statusID) == [root])
    }

    // MARK: - 8. A quote

    @Test("This server sends quotes in the shape this app reads: a state and the quoted status whole; a quote of a quote a level down as a state and an id alone; an unsigned read the same without the reader's marks; and a quoted post since deleted as that state with nothing of the post")
    func aQuote() async throws {
        try await LocalServers.requireHealthy()
        let version = try #require(try await ask(.nobody, "GET", "/api/v2/instance").object["version"] as? String)
        #expect(version.compare("4.5", options: .numeric) != .orderedAscending, "a server that can make quotes: \(version)")

        let quoted = try await post(as: .other, "to be quoted")
        let quoting = try await post(as: .writer, "quoting it", quoting: quoted)
        let read = try await ask(.writer, "GET", "/api/v1/statuses/\(quoting)")
        let quote = try #require(read.object["quote"] as? [String: Any])
        #expect(Set(quote.keys) == ["state", "quoted_status"] && quote["state"] as? String == "accepted")
        let whole = try #require(quote["quoted_status"] as? [String: Any])
        #expect(whole["id"] as? String == quoted && whole["quote"] is NSNull)
        #expect((read.object["content"] as? String)?.contains(#"class="quote-inline""#) == true, "and its own line for readers that draw no quote")

        let note = try decoded(read).asNote(source: Self.source, categories: [], sent: .now())
        #expect(note.refs == [.quotes(.accepted, id: whole["uri"] as? String, statusID: quoted)])
        #expect(note.brought.map(\.statusID) == [quoted] && !note.body.contains("RE:"))

        // A level down: an id alone.
        let outer = try await post(as: .other, "quoting the quote", quoting: quoting)
        let nested = try await ask(.other, "GET", "/api/v1/statuses/\(outer)")
        let inner = try #require(((nested.object["quote"] as? [String: Any])?["quoted_status"] as? [String: Any])?["quote"] as? [String: Any])
        #expect(Set(inner.keys) == ["state", "quoted_status_id"] && inner["quoted_status_id"] as? String == quoted)
        let outerNote = try decoded(nested).asNote(source: Self.source, categories: [], sent: .now())
        #expect(outerNote.brought.first?.refs == [.quotes(.accepted, statusID: quoted)] && outerNote.brought.first?.brought.isEmpty == true)

        // Unsigned: the same shape, and the quoted status says nothing of a reader.
        let unsigned = try await ask(.nobody, "GET", "/api/v1/statuses/\(quoting)")
        let shown = try #require((unsigned.object["quote"] as? [String: Any])?["quoted_status"] as? [String: Any])
        #expect(Self.marks.allSatisfy { shown[$0] == nil })

        // The quoted post deleted: the state says so, and nothing of the post comes.
        #expect(try await ask(.other, "DELETE", "/api/v1/statuses/\(quoted)").status == 200)
        let after = try await ask(.writer, "GET", "/api/v1/statuses/\(quoting)")
        let gone = try #require(after.object["quote"] as? [String: Any])
        #expect(gone["state"] as? String == "deleted" && gone["quoted_status"] is NSNull)
        let afterNote = try decoded(after).asNote(source: Self.source, categories: [], sent: .now())
        #expect(afterNote.refs == [.quotes(.deleted)] && afterNote.brought.isEmpty)
    }

    // MARK: - One key, one post

    /// What "Send again" rests on (`Unsent.id`): a post sent a second time under the key it was
    /// first sent with is not a second post.
    ///
    /// **And what it cannot rest on, with this server.** Mastodon 4.6.6 does not answer the
    /// repeat with the post it made: its own replay path fails (`PostStatusService` goes on to
    /// process a status it did not set) and the answer is a 500. So the key keeps a text from
    /// being posted twice, and says nothing of whether it was posted once — which is why a text
    /// that may have landed goes on saying so when a later try fails (`ShellOutbox`). Pinned as
    /// it is, so that a server that answers the repeat with the post is noticed here.
    @Test("A post sent again under the key it was first sent with makes no second post — the writer's own posts hold it once — but this server answers each repeat with a 500 and not with the post; the same words under another key are another post")
    func oneKeyIsOnePost() async throws {
        try await LocalServers.requireHealthy()
        let store = ItemStore(sources: [Self.source], notes: [])
        let write = MastodonWrite(door: try door(.writer), store: store)
        let words = "sent once \(UUID().uuidString.prefix(8))"
        let key = UUID()

        let first = try await write.post(words, visibility: .everyone, key: key)
        let firstID = try #require(first.statusID)
        for _ in 1...2 {
            await #expect(throws: MastodonAuthError.http(500), "the repeat was answered some other way") {
                try await write.post(words, visibility: .everyone, key: key)
            }
        }

        let me = try await ask(.writer, "GET", "/api/v1/accounts/verify_credentials")
        let mine = try await ask(.writer, "GET", "/api/v1/accounts/\(try #require(me.object["id"] as? String))/statuses?limit=40")
        #expect(mine.status == 200)
        let held = mine.list.filter { ($0["content"] as? String)?.contains(words) == true }
        #expect(held.compactMap { $0["id"] as? String } == [firstID], "the same key made a second post, or none")

        let other = try await write.post(words, visibility: .everyone, key: UUID())
        #expect(other.statusID != nil && other.statusID != firstID, "another key is another post")

        // Nothing of this check is left in the writer's posts for the next one to read.
        for id in [firstID, other.statusID].compactMap({ $0 }) {
            #expect(try await ask(.writer, "DELETE", "/api/v1/statuses/\(id)").status == 200)
        }
    }
}

/// A sender that passes every request on and keeps the last one with its answer: for seeing
/// what this app's own code asked a real server and what it was told.
private actor Heard: HTTPSender {
    private let inner: any HTTPSender
    private(set) var last: (request: URLRequest, body: Data, response: HTTPURLResponse)?

    init(_ inner: any HTTPSender) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (body, response) = try await inner.send(request)
        last = (request, body, response)
        return (body, response)
    }
}
