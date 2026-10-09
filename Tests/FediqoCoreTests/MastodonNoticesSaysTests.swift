import Foundation
import Testing
@testable import FediqoCore

/// #323: what Fediqo believes a Mastodon source says of notices, held against the real one this
/// checkout brings up (`make servers`, Mastodon 4.6.6) — as `MastodonSaysTests` holds what it
/// says of posts. Each check reads the server through this app's own reader, `MastodonNotices`
/// behind a real `MastodonAuthorized`, and beside it asks the server plainly for the part of
/// the answer the reader rests on.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb`). This server runs no
/// background worker and tells nobody of anything until its queued jobs are run, which the seed
/// does and a check cannot — so no check makes a notice, and the ones that dismiss a notice or
/// answer a held-back request use up what the seed spared for them: two notices and two
/// requests a run, four runs' worth, made up again by `make servers`. A run past that fails
/// saying so.
///
/// **Asked gently.** No registration: this server takes five in ten minutes from anywhere and
/// the other checks make two a run, so the registration the sign-in check starts on is the
/// seed's — made in the server, which holds it to the scopes it knows as it does one made
/// through its API.
///
/// **Not asked, because 4.6.6 cannot be made to answer it:** a source with no gathered read or
/// no policy (the 404 the reader falls back on). **And not done:** dismissing all, which would
/// take every seeded notice with it.
@Suite("What a Mastodon says of notices", .enabled(if: LocalServers.requested), .serialized)
struct MastodonNoticesSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    /// What the seed made for these checks. A seed file written before it made any says so.
    private static func seeded() throws -> LocalServers.Seeded.Notices {
        try #require(
            try LocalServers.seeded().notices,
            "servers/.run/mastodon-tokens.json was seeded before notices were: run `make servers` again"
        )
    }

    private static func handle(_ username: String) -> String { "@\(username)@\(host)" }
    private static let writer = handle("fediqo")
    private static let other = handle("fediqo_other")

    /// The writer's sign-ins as this app makes them: before notices were asked for, reading or
    /// reading and acting; and since, reading notices or reading and dismissing them.
    private enum Who: CaseIterable {
        case reading, acting, noticing, dismissing

        func signIn() throws -> LocalServers.Seeded.Notices.SignIn {
            let seeded = try MastodonNoticesSaysTests.seeded()
            return switch self {
            case .reading: seeded.reading
            case .acting: seeded.acting
            case .noticing: seeded.noticing
            case .dismissing: seeded.dismissing
            }
        }

        /// What this app asks for, for such a sign-in.
        var asked: String {
            switch self {
            case .reading: MastodonOAuth.scopes(writing: false)
            case .acting: MastodonOAuth.scopes(writing: true)
            case .noticing: MastodonOAuth.scopes(writing: false, notices: true)
            case .dismissing: MastodonOAuth.scopes(writing: true, notices: true)
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
        var text: String { String(decoding: body, as: UTF8.self) }
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
    }

    /// The server asked plainly, in English, so a sentence asserted does not depend on the
    /// language of the machine the checks run on.
    private func ask(_ token: String, _ method: String = "GET", _ path: String) async throws -> Answer {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, response: response, body: body)
    }

    private func ask(_ who: Who, _ method: String = "GET", _ path: String) async throws -> Answer {
        try await ask(try who.signIn().token, method, path)
    }

    private func door(_ token: MastodonToken, keptIn tokens: MemoryMastodonTokens = MemoryMastodonTokens()) throws -> MastodonAuthorized {
        try tokens.save(token)
        return MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)
    }

    private func token(_ who: Who) throws -> MastodonToken {
        let signIn = try who.signIn()
        return MastodonToken(
            host: Self.host, accessToken: signIn.token, clientID: "x", clientSecret: "x", scopes: signIn.scopes, asked: signIn.scopes
        )
    }

    private func notices(_ who: Who) throws -> MastodonNotices {
        MastodonNotices(door: try door(try token(who)))
    }

    /// Every notice the source has, read on through this app's reader until the source says
    /// there is no more: each stretch as it came, and the lines they fold into.
    private func everything(_ who: Who, gathered: Bool? = nil) async throws -> (pages: [NoticePage], lines: [Notice]) {
        let notices = try notices(who)
        var pages = [try await notices.page(source: Self.source, gathered: gathered)]
        while let before = pages.last?.before {
            try #require(pages.count < 12, "reading on never came to an end")
            pages.append(try await notices.page(source: Self.source, before: before, gathered: pages[0].gathered))
        }
        return (pages, pages.dropFirst().reduce(pages[0].notices) { $0.readingOn($1.notices) })
    }

    private func about(_ post: String, _ kind: Notice.Kind, in lines: [Notice]) -> [Notice] {
        lines.filter { $0.kind == kind && $0.post?.statusID == post }
    }

    private static let usedUp: Comment = "what the seed spared for this is used up: `make servers` makes it up again"

    // MARK: - 1. The gathered read

    @Test("The gathered read hands the people and the posts over beside its lines, a line with no time of its own and its newest id as a number — and this app makes a line of every one: a mention, an answer, a boost and a favourite by two as one line each, a follow, a follow request, a poll ended, a boosted post changed, a quote")
    func theGatheredRead() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let third = Self.handle(seeded.third)

        let raw = try await ask(.noticing, "GET", "/api/v2/notifications")
        #expect(raw.status == 200)
        #expect(raw.object["accounts"] is [[String: Any]] && raw.object["statuses"] is [[String: Any]])
        let groups = try #require(raw.object["notification_groups"] as? [[String: Any]])
        #expect(!groups.isEmpty)
        for group in groups {
            let key = group["group_key"] as? String ?? ""
            #expect(MastodonNotices.isGroupKey(key), "a key this app will put in a path: \(key)")
            #expect(group["most_recent_notification_id"] is NSNumber, "\(key): its newest id is a number")
            #expect(group["page_min_id"] is String && group["page_max_id"] is String, "\(key): its page ids are strings")
            #expect(group["created_at"] == nil, "\(key): no time of its own")
            #expect((group["latest_page_notification_at"] as? String).flatMap(MastodonJSON.date(from:)) != nil, "\(key): but its latest notice's")
            #expect(group["account"] == nil && group["status"] == nil, "\(key): nobody and no post inside it")
        }

        // Through this app's reader: asked which read it has, the source answers the gathered
        // one, and nothing it sent is left out.
        let read = try await everything(.noticing)
        let page = try #require(read.pages.first), lines = read.lines
        #expect(page.gathered)
        #expect(page.notices.map(\.handle) == groups.map { .gathered(key: $0["group_key"] as? String ?? "") })

        for line in lines {
            if case .unknown(let word) = line.kind { Issue.record("a kind this app does not name: \(word)") }
            #expect(!line.people.isEmpty, "\(line.kind.type): somebody did it")
        }

        // Favoured and boosted by two: one line each, standing for two, newest person first,
        // about the writer's own post.
        for kind in [Notice.Kind.favourite, .reblog] {
            let gathered = about(seeded.liked, kind, in: lines)
            let line = try #require(gathered.first, "\(kind.type): the seeded line")
            #expect(gathered.count == 1 && line.count == 2 && line.people.map(\.handle) == [third, Self.other])
            #expect(line.post?.handle == Self.writer && StatusID.later(line.newestID, than: line.oldestID))
        }

        // An answer arrives as a mention; the post tells the two apart.
        let mention = try #require(about(seeded.mention, .mention, in: lines).first)
        #expect(!mention.answers && mention.count == 1 && mention.people.map(\.handle) == [Self.other])
        let answer = try #require(about(seeded.answer, .mention, in: lines).first)
        #expect(answer.answers && answer.post?.handle == Self.other)

        // A follow and a follow request are about nobody's post.
        let follow = try #require(lines.first { $0.kind == .follow && $0.people.contains { $0.handle == third } })
        #expect(follow.post == nil)
        let asking = try #require(lines.first { $0.kind == .followRequest })
        #expect(asking.post == nil && asking.people.map(\.handle) == [Self.other])

        // A poll's ending is told to its owner by the owner themself.
        let poll = try #require(about(seeded.poll, .poll, in: lines).first)
        #expect(poll.people.map(\.handle) == [Self.writer] && poll.post?.handle == Self.writer)
        // A boosted post changed: the post, as it now is, and its author.
        let update = try #require(about(seeded.changed, .update, in: lines).first)
        #expect(update.people.map(\.handle) == [Self.other] && update.post?.editedAt != nil)
        // A quote is about the post that quotes.
        let quote = try #require(about(seeded.quoting, .quote, in: lines).first)
        #expect(quote.people.map(\.handle) == [Self.other] && quote.post?.handle == Self.other)
    }

    // MARK: - 2. The single read

    @Test("The single read hands each notice over with its person and its post inside it and a time of its own, and this app makes the same line of it: one person, a count of one, named by its id — two favourites of one post are two lines, and a notice the source does not gather is the same by either read")
    func theSingleRead() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()

        let raw = try await ask(.noticing, "GET", "/api/v1/notifications")
        #expect(raw.status == 200 && !raw.list.isEmpty)
        for notice in raw.list {
            #expect(notice["id"] is String && notice["account"] is [String: Any] && notice["group_key"] is String)
            #expect((notice["created_at"] as? String).flatMap(MastodonJSON.date(from:)) != nil)
        }

        let read = try await everything(.noticing, gathered: false)
        let page = try #require(read.pages.first), lines = read.lines
        #expect(!page.gathered)
        #expect(page.notices.map(\.handle) == raw.list.map { .one(id: $0["id"] as? String ?? "") })

        #expect(lines.allSatisfy { $0.count == 1 && $0.people.count == 1 && $0.newestID == $0.oldestID })
        #expect(about(seeded.liked, .favourite, in: lines).count == 2 && about(seeded.liked, .reblog, in: lines).count == 2)
        let kinds = Set(lines.map(\.kind))
        #expect(kinds == [.mention, .reblog, .favourite, .follow, .followRequest, .poll, .update, .quote])

        // The same notice by either read: only how it is named there differs.
        let gathered = try await everything(.noticing).lines
        for (post, kind) in [(seeded.answer, Notice.Kind.mention), (seeded.poll, .poll), (seeded.quoting, .quote)] {
            let one = try #require(about(post, kind, in: lines).first), line = try #require(about(post, kind, in: gathered).first)
            #expect(one.people == line.people && one.post == line.post && one.at == line.at && one.newestID == line.newestID)
            #expect(one.answers == line.answers && one.id != line.id)
        }
        // And both reads reach the same notices: a gathered line says how many it stands for.
        #expect(gathered.map(\.count).reduce(0, +) == lines.count)
    }

    // MARK: - 3. Reading on

    @Test("Reading on asks before the lowest id the page named, which is what the source's own link says, and ends at a page with nothing; a gathered line whose notices lie more than a page apart comes back on the next page under the same key and is folded into the one held; one notice at a time repeats none")
    func readingOn() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()

        let read = try await everything(.noticing)
        let first = try #require(read.pages.first)
        let before = try #require(first.before, "a first page with more below it")
        #expect(read.pages.count >= 3 && first.notices.count == 40, "forty lines a page, left to the server")
        let link = try await ask(.noticing, "GET", "/api/v2/notifications").header("Link") ?? ""
        #expect(link.contains("max_id=\(before)>; rel=\"next\""), "the source's own way on: \(link)")
        for (above, below) in zip(read.pages, read.pages.dropFirst()) {
            let asked = try #require(above.before)
            #expect(below.notices.allSatisfy { StatusID.later(asked, than: $0.newestID) }, "nothing as new as what was asked before")
        }
        let last = try #require(read.pages.last)
        #expect(last.notices.isEmpty && last.before == nil, "an empty page is the end")
        let pastTheEnd = try await ask(.noticing, "GET", "/api/v2/notifications?max_id=1")
        #expect(pastTheEnd.status == 200 && pastTheEnd.header("Link") == nil)
        #expect((pastTheEnd.object["notification_groups"] as? [Any])?.isEmpty == true)

        // The line cut at a page's edge: on two pages under one name, and one line once folded.
        let cut = read.pages.map { about(seeded.cut, .favourite, in: $0.notices) }.filter { !$0.isEmpty }
        try #require(cut.count == 2 && cut.allSatisfy { $0.count == 1 }, "the seeded line stands on two pages: \(cut.count)")
        let newer = cut[0][0], older = cut[1][0]
        #expect(newer.id == older.id && newer.handle == older.handle)
        #expect(StatusID.later(newer.oldestID, than: older.newestID), "each page reached its own stretch of the line")
        let folded = about(seeded.cut, .favourite, in: read.lines)
        #expect(folded.count == 1 && Set(read.lines.map(\.id)).count == read.lines.count, "no line twice")
        #expect(folded.first?.count == 2 && folded.first?.newestID == newer.newestID && folded.first?.oldestID == older.oldestID)
        #expect(Set(folded.first?.people.map(\.handle) ?? []) == [Self.other, Self.handle(seeded.third)])

        // One notice at a time: the same rule, and nothing twice.
        let single = try await everything(.noticing, gathered: false)
        let singleBefore = try #require(single.pages.first?.before)
        let singleLink = try await ask(.noticing, "GET", "/api/v1/notifications").header("Link") ?? ""
        #expect(singleLink.contains("max_id=\(singleBefore)>; rel=\"next\""), "\(singleLink)")
        #expect(single.pages.last?.notices.isEmpty == true && single.pages.first?.notices.count == 40)
        let ids = single.pages.flatMap(\.notices).map(\.newestID)
        #expect(zip(ids, ids.dropFirst()).allSatisfy { StatusID.later($0, than: $1) }, "newest first, all the way down")
        #expect(about(seeded.cut, .favourite, in: single.lines).count == 2)
    }

    // MARK: - 4. A sign-in made before notices were asked for

    @Test("A sign-in made before notices were asked for — reading, or reading and acting — is refused both reads and the policy with 403 and the scope it lacks, is not signed out by it, and goes on reading what it read")
    func aSignInWithoutTheScope() async throws {
        try await LocalServers.requireHealthy()
        for who in Who.allCases {
            #expect(try who.signIn().scopes == who.asked, "the seed's sign-in is this app's, word for word")
        }
        for who in [Who.reading, .acting] {
            #expect(!MastodonOAuth.notices(who.asked))
            for path in [MastodonNotices.gatheredPath, MastodonNotices.policyPath] {
                let refused = try await ask(who, "GET", path)
                #expect(refused.status == 403 && refused.error == "This action is outside the authorized scopes", "\(path): \(refused.status)")
                #expect(refused.header("WWW-Authenticate")?.contains(#"error="insufficient_scope""#) == true)
                #expect(refused.header("WWW-Authenticate")?.contains("read:notifications") == true)
            }

            // Through this app: the refusal as it came, by whichever read, and the sign-in held.
            let tokens = MemoryMastodonTokens()
            let notices = MastodonNotices(door: try door(try token(who), keptIn: tokens))
            for gathered in [nil, true, false] as [Bool?] {
                await #expect(throws: MastodonAuthError.http(403)) { _ = try await notices.page(source: Self.source, gathered: gathered) }
            }
            await #expect(throws: MastodonAuthError.http(403)) { _ = try await notices.held() }
            await #expect(throws: MastodonAuthError.http(403)) { _ = try await notices.requests(source: Self.source) }
            #expect(try tokens.token(host: Self.host) != nil, "not signed out")
            #expect(try await ask(who, "GET", "/api/v1/timelines/home?limit=1").status == 200, "and it reads as it did")
        }
    }

    // MARK: - 5. A sign-in that asks for notices

    @Test("A sign-in that asks to read and to dismiss notices on top of reading and acting is approved on the server's own page and given every scope it asked for in the order it asked — and the sign-in it gets reads notices and may dismiss")
    func aSignInAskingForNotices() async throws {
        try await LocalServers.requireHealthy()
        let asked = MastodonOAuth.scopes(writing: true, notices: true)
        #expect(asked.hasSuffix(" \(MastodonOAuth.noticing) \(MastodonOAuth.dismissing)"))

        // This app's own sign-in, with the server's page approved as the writer approves it
        // at a browser, started on a registration **the seed made, in the server, and not this
        // app's `register`**. So what is shown here is that the server's page and its token
        // grant the notices scopes to a sign-in that asks for them. That the server *registers*
        // an app asking for them is held by the seed alone — it would fail there, and
        // `make servers` with it — and by no check: nothing here shows what `register` is
        // answered for these scopes. The line below only says the seed asked for what this
        // app asks, word for word.
        let registered = try Self.seeded().app
        #expect(registered.scopes == asked, "the seed's registration asks what this app asks")
        let oauth = MastodonOAuth(host: Self.host, sender: try LocalHTTP.client())
        let app = MastodonApp(host: Self.host, clientID: registered.id, clientSecret: registered.secret, scopes: asked)
        let token = try await oauth.signIn(as: app, through: Approving(host: Self.host, browser: try LocalHTTP.browser()))
        #expect(token.scopes == asked && token.asked == asked)
        #expect(MastodonOAuth.notices(token.scopes) && MastodonOAuth.dismisses(token.scopes))
        #expect(MastodonOAuth.writes(token.scopes) && MastodonOAuth.bookmarks(token.scopes), "and it is no lesser a sign-in for it")
        #expect(!token.noticesRefused)

        // What the server itself says the token holds, and that it does what was asked for.
        let held = try await ask(token.accessToken, "GET", "/oauth/token/info")
        #expect(Set(held.object["scope"] as? [String] ?? []) == Set(asked.split(separator: " ").map(String.init)))
        let page = try await MastodonNotices(door: try door(token)).page(source: Self.source)
        #expect(page.gathered && !page.notices.isEmpty)
        // A gathered line that was never there is dismissed with a plain yes: nothing is lost.
        #expect(try await ask(token.accessToken, "POST", "\(MastodonNotices.gatheredPath)/favourite-1-1/dismiss").status == 200)
        await oauth.revoke(token)
    }

    // MARK: - 6. Dismissing

    @Test("Dismissing one notice by its id answers 200 and the notice is gone, and a second time 404, which this app takes for done; a gathered line by its key answers 200 whether or not it was there; a sign-in that only reads notices, and one made before them, is refused with 403 and the scope it lacks, and the notice stands")
    func dismissing() async throws {
        try await LocalServers.requireHealthy()
        let spare = Set(try Self.seeded().spare)
        let reader = try notices(.noticing), actor = try notices(.dismissing)
        func spared(_ lines: [Notice]) -> Notice? { lines.last { $0.kind == .favourite && spare.contains($0.post?.statusID ?? "") } }

        // One notice, by its id.
        let one = try #require(spared(try await everything(.dismissing, gathered: false).lines), Self.usedUp)
        guard case .one(let id) = one.handle else { Issue.record("the single read named a line by a key"); return }
        for who in [Who.noticing, .acting] {
            let refused = try await ask(who, "POST", "\(MastodonNotices.singlePath)/\(id)/dismiss")
            #expect(refused.status == 403 && refused.error == "This action is outside the authorized scopes")
            #expect(refused.header("WWW-Authenticate")?.contains("write:notifications") == true)
        }
        await #expect(throws: MastodonAuthError.http(403)) { try await reader.dismiss(one) }
        #expect(try await ask(.noticing, "GET", "\(MastodonNotices.singlePath)/\(id)").status == 200, "refused, and it stands")

        try await actor.dismiss(one)
        #expect(try await ask(.noticing, "GET", "\(MastodonNotices.singlePath)/\(id)").status == 404)
        let again = try await ask(.dismissing, "POST", "\(MastodonNotices.singlePath)/\(id)/dismiss")
        #expect(again.status == 404 && again.text == #"{"error":"Record not found"}"#)
        try await actor.dismiss(one)

        // A gathered line, by its key: every notice it stands for at once.
        let line = try #require(spared(try await everything(.dismissing).lines), Self.usedUp)
        guard case .gathered(let key) = line.handle else { Issue.record("the gathered read named a line by an id"); return }
        let post = try #require(line.post?.statusID)
        #expect(post != one.post?.statusID)
        let refused = try await ask(.noticing, "POST", "\(MastodonNotices.gatheredPath)/\(key)/dismiss")
        #expect(refused.status == 403 && refused.header("WWW-Authenticate")?.contains("write:notifications") == true)
        await #expect(throws: MastodonAuthError.http(403)) { try await reader.dismiss(line) }

        #expect(try await ask(.noticing, "GET", "\(MastodonNotices.gatheredPath)/\(key)").status == 200, "refused, and it stands")

        try await actor.dismiss(line)
        #expect(try await ask(.noticing, "GET", "\(MastodonNotices.gatheredPath)/\(key)").status == 404)
        let left = try await everything(.noticing).lines
        #expect(!left.contains { [post, one.post?.statusID].contains($0.post?.statusID) }, "both are gone from what is read")
        // The same yes for a line just dismissed and for one that never was: it proves nothing.
        for key in [key, "favourite-1-1"] {
            let answer = try await ask(.dismissing, "POST", "\(MastodonNotices.gatheredPath)/\(key)/dismiss")
            #expect(answer.status == 200 && answer.text == "{}", "\(key): \(answer.status)")
        }
        try await actor.dismiss(line)
    }

    // MARK: - 7. What the server holds back

    @Test("An account as it is made holds back a private mention from somebody its owner does not follow: the policy counts the requests waiting, each is listed with its person, its count as a string and the post, and none of it stands in what is read; one let through is gone from the list at once and its notice still on its way; one let go is gone, and gone again is 404; a sign-in that only reads notices may do neither")
    func whatTheServerHoldsBack() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let reader = try notices(.noticing), actor = try notices(.dismissing)

        let policy = try await ask(.noticing, "GET", MastodonNotices.policyPath)
        #expect(policy.status == 200)
        #expect(policy.object["for_private_mentions"] as? String == "filter" && policy.object["for_not_following"] as? String == "accept")
        let summary = try #require(policy.object["summary"] as? [String: Any])
        let counted = try #require(summary["pending_requests_count"] as? Int)
        guard case .holds(let held) = try await reader.held() else { Issue.record("this server has a policy to hold by"); return }
        #expect(held.requests == counted && held.notices >= held.requests && !held.isEmpty)

        let raw = try await ask(.noticing, "GET", MastodonNotices.requestsPath)
        #expect(raw.list.count == counted && raw.list.allSatisfy { $0["notifications_count"] is String && $0["id"] is String })
        let listed = try await reader.requests(source: Self.source)
        #expect(listed.map(\.requestID) == raw.list.map { $0["id"] as? String })
        let waiting = listed.filter { request in seeded.held.contains { Self.handle($0.by) == request.person.handle } }
        try #require(waiting.count >= 2, Self.usedUp)
        for request in waiting {
            let post = seeded.held.first { Self.handle($0.by) == request.person.handle }?.post
            #expect(request.count == 1 && request.lastPost?.statusID == post && request.source == Self.source)
            #expect(request.lastPost?.handle == request.person.handle && request.lastPost?.audience != .everyone)
        }
        let heldBack = Set(waiting.compactMap { $0.lastPost?.statusID })
        let ordinary = try await everything(.noticing).lines
        #expect(!ordinary.contains { heldBack.contains($0.post?.statusID ?? "") }, "held back from what is read")

        // A sign-in that only reads notices may answer no request, and the request waits on.
        let through = waiting[0], gone = waiting[1]
        await #expect(throws: MastodonAuthError.http(403)) { try await reader.letThrough(through) }
        await #expect(throws: MastodonAuthError.http(403)) { try await reader.letGo(gone) }
        #expect(try await reader.requests(source: Self.source).map(\.id) == listed.map(\.id))

        // Let through: the request is gone with the answer, and the notice is not there yet —
        // the server moves it afterwards, in its own time, which on this one is the next seed.
        try await actor.letThrough(through)
        #expect(try await ask(.noticing, "GET", "\(MastodonNotices.requestsPath)/merged").object["merged"] as? Bool == false)
        #expect(try await !reader.requests(source: Self.source).contains { $0.id == through.id })
        let newest = try await reader.page(source: Self.source).notices
        #expect(!newest.contains { heldBack.contains($0.post?.statusID ?? "") }, "on its way, and not arrived")

        // Let go: gone, and its notice with it; asked again there is no such request.
        try await actor.letGo(gone)
        let left = try await reader.requests(source: Self.source)
        #expect(left.map(\.id) == listed.map(\.id).filter { ![through.id, gone.id].contains($0) })
        #expect(try await reader.held() == .holds(NoticesHeld(requests: held.requests - 2, notices: held.notices - 2)))
        await #expect(throws: MastodonAuthError.http(404)) { try await actor.letGo(gone) }
        await #expect(throws: MastodonAuthError.http(404)) { try await actor.letThrough(through) }
    }
}

/// The server's own page, approved as the writer approves it at a browser: signed in with the
/// seed's dummy password, shown the page this app's sign-in opens, and the page's own form sent
/// back. What it hands on is where the server then sends the person — this app's callback.
private struct Approving: OAuthBrowser {
    let host: String
    let browser: LocalBrowser

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        let door = try #require(URL(string: "https://\(host)/auth/sign_in"))
        let form = try await browser.send(URLRequest(url: door))
        let signedIn = try await browser.send(Self.post(door, [
            ("authenticity_token", try Self.formToken(in: form.0)), ("user[email]", "writer@example.com"),
            ("user[password]", "LocalOnlyPass1"),
        ]))
        try #require(signedIn.1.statusCode == 302, "signed in")

        let page = try await browser.send(URLRequest(url: url))
        // Approved by this person before and never taken back: sent straight on.
        if page.1.statusCode == 302, let onward = page.1.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)),
           onward.scheme == callbackScheme
        {
            return onward
        }
        try #require(page.1.statusCode == 200, "the page to approve: \(page.1.statusCode)")
        // The page's form carries what the address asked for back to the server, unchanged.
        let asked = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let approve = try #require(URL(string: "https://\(host)/oauth/authorize"))
        let approved = try await browser.send(Self.post(
            approve, [("authenticity_token", try Self.formToken(in: page.0))] + asked.map { ($0.name, $0.value ?? "") }
        ))
        let onward = try #require(approved.1.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)), "sent on: \(approved.1.statusCode)")
        #expect(onward.scheme == callbackScheme)
        return onward
    }

    private static func formToken(in page: Data) throws -> String {
        let html = String(decoding: page, as: UTF8.self)
        let start = try #require(html.range(of: #"name="authenticity_token" value=""#)?.upperBound, "the page's form")
        return String(html[start...].prefix { $0 != "\"" })
    }

    private static func post(_ url: URL, _ form: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var fields = URLComponents()
        fields.queryItems = form.map { URLQueryItem(name: $0.0, value: $0.1) }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((fields.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }
}
