import Foundation
import Testing
@testable import FediqoCore

/// One answer of the local server, whole.
private struct ActsAnswer {
    let status: Int
    let response: HTTPURLResponse
    let body: Data

    var text: String { String(decoding: body, as: UTF8.self) }
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    var list: [[String: Any]] { (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? [] }
    var link: String? { response.value(forHTTPHeaderField: "Link") }
}

/// What the checks below ask the server with, and through.
private enum Acts {
    static let host = LocalServers.mastodon
    static let source = Source(host: host, kind: .mastodon)

    static func seeded() throws -> (all: LocalServers.Seeded, notices: LocalServers.Seeded.Notices) {
        let all = try LocalServers.seeded()
        let stale: Comment = "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again"
        let notices = try #require(all.notices, stale)
        try #require(notices.spare.count >= 4, stale)
        return (all, notices)
    }

    static func ask(_ path: String, as token: String? = nil, _ method: String = "GET", form: String? = nil) async throws -> ActsAnswer {
        guard let url = URL(string: "https://\(host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.utf8)
        }
        let (body, response) = try await LocalHTTP.client().send(request)
        return ActsAnswer(status: response.statusCode, response: response, body: body)
    }

    static func door(_ accessToken: String) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)
    }

    /// A store holding `id` as `token` reads it, and a writer through `token` beside it.
    static func holding(_ id: String, as token: String) async throws -> (MastodonWrite, ItemStore, Note) {
        let store = ItemStore()
        await store.add(source)
        let sent = ReadMoment.now()
        let read = try await Acts.ask("/api/v1/statuses/\(id)", as: token)
        let note = try MastodonJSON.decoder.decode(StatusDTO.self, from: read.body).asNote(source: source, category: .home, sent: sent)
        await store.ingest([note])
        return (MastodonWrite(door: try door(token), store: store), store, note)
    }

    /// What every post a check here writes begins with, and no other post does.
    static let marker = "fediqo-334"

    /// Takes back every one of `token`'s latest posts whose words carry `marker`.
    static func takingBack(as token: String) async throws {
        let me = try #require(try await ask("/api/v1/accounts/verify_credentials", as: token).object["id"] as? String)
        for post in try await ask("/api/v1/accounts/\(me)/statuses?limit=40", as: token).list
        where (post["content"] as? String)?.contains(marker) == true {
            if let id = post["id"] as? String { _ = try await ask("/api/v1/statuses/\(id)", as: token, "DELETE") }
        }
    }

    /// Runs `body` with `count` posts of `token`'s own, written for it at `visibility`, and takes
    /// them back however it ends — unpinned first — and before it, should a run that died, or a
    /// server that throttled its deletions, have left one.
    ///
    /// **Written as the seed's `ownFan`** by the checks below: somebody nobody follows, whose posts
    /// no other check counts, and never in a public timeline (`unlisted`, `direct`).
    static func withOwnPosts(
        _ count: Int, _ visibility: String, as token: String, _ body: ([String]) async throws -> Void
    ) async throws {
        try await takingBack(as: token)
        var made: [String] = []
        let thrown: (any Error)?
        do {
            for n in 1...count {
                let answer = try await ask("/api/v1/statuses", as: token, "POST", form: "status=\(marker)+\(visibility)+\(n)&visibility=\(visibility)")
                made.append(try #require(answer.object["id"] as? String, "writing: \(answer.status) \(answer.text)"))
            }
            try await body(made)
            thrown = nil
        } catch {
            thrown = error
        }
        for id in made {
            _ = try? await ask("/api/v1/statuses/\(id)/unpin", as: token, "POST")
            let gone = try await ask("/api/v1/statuses/\(id)", as: token, "DELETE")
            #expect(gone.status == 200, "taken back: \(gone.status) \(gone.text)")
        }
        if let thrown { throw thrown }
    }

    /// The source's own words `act` was refused in (`MastodonWriteError.refused`), or nothing
    /// where it was not refused so.
    static func refusal(_ act: () async throws -> Note) async -> String? {
        do {
            _ = try await act()
        } catch MastodonWriteError.refused(let sentence) {
            return sentence
        } catch {}
        return nil
    }

    /// The person no other check counts the posts of, and their sign-in.
    static func fan() throws -> LocalServers.Seeded.People.SignedIn {
        let stale: Comment = "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again"
        let people = try #require(try LocalServers.seeded().people, stale)
        return try #require(people.ownFan, stale)
    }
}

/// #334: what Fediqo believes a Mastodon says when a post is pinned, its conversation quieted, it
/// is translated, and who boosted and favourited it is asked — held against the real one this
/// checkout brings up (`make servers`, Mastodon 4.6.6), every line of `MastodonPostActsCaptures`.
/// Each check goes through this app's own code (`MastodonWrite.pin`, `.quiet`,
/// `MastodonTranslator`, `MastodonPeople`) and beside it asks the server plainly for what that
/// code rests on.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **This writes, and puts back what it wrote — on posts of its own.** Every post it pins or
/// quiets it wrote itself, as the seed's `ownFan` (`Acts.withOwnPosts`), and takes back however
/// it ends: no post another check reads, counts or pins is touched, so nothing here races them.
///
/// **The translated path is not asked here** (D7): this server has no translator, so what is
/// asked of it is that a translation is not offered, and that asking all the same is a not-found.
///
/// **Asked gently.** A run makes some eighty requests, writes eight posts and no registration.
@Suite("What a Mastodon says when a post is pinned, quieted, translated, and of who boosted and favourited it", .enabled(if: LocalServers.requested), .serialized)
struct MastodonPostActsSaysTests {
    @Test("A pin of an own post lands as pinned, said to its author alone; pinned again it is turned away and read again as pinned; unpinned twice it is unpinned; past the host's five the page is full, said with its limit; somebody else's post and one only its mentioned may read are refused in the source's words; and a sign-in without the account part is refused for its scopes")
    func pinning() async throws {
        try await LocalServers.requireHealthy()
        let (all, notices) = try Acts.seeded()
        let fan = try Acts.fan()
        let said = try await MastodonClient(http: try LocalHTTP.client(), host: Acts.host).said()
        #expect(said.has.pinLimit == 5)
        try await Acts.withOwnPosts(6, "unlisted", as: fan.token) { posts in
            let (write, store, before) = try await Acts.holding(posts[0], as: fan.token)
            #expect(before.pinned == false && before.muted == false)
            #expect(try await Acts.ask("/api/v1/statuses/\(posts[0])", as: all.writer).object["pinned"] == nil, "only its author is told")

            let pinned = try await write.pin(before, on: true, limit: said.has.pinLimit)
            #expect(pinned.pinned == true && pinned.key == before.key)
            #expect(await store.note(before.key)?.pinned == true)
            let again = try await Acts.ask("/api/v1/statuses/\(posts[0])/pin", as: fan.token, "POST")
            #expect(again.status == 422 && again.text == MastodonPostActsCaptures.duplicate)
            #expect(try await write.pin(before, on: true, limit: said.has.pinLimit).pinned == true, "already pinned is pinned")
            let off = try await write.pin(pinned, on: false)
            #expect(off.pinned == false)
            #expect(await store.note(before.key)?.pinned == false)
            #expect(try await write.pin(off, on: false).pinned == false)

            // Five pinned, and a sixth.
            for post in posts[0...4] {
                #expect(try await Acts.ask("/api/v1/statuses/\(post)/pin", as: fan.token, "POST").status == 200, "pinning \(post)")
            }
            let sixth = try await Acts.ask("/api/v1/statuses/\(posts[5])/pin", as: fan.token, "POST")
            #expect(sixth.status == 422 && sixth.text == MastodonPostActsCaptures.full)
            let (fullWrite, fullStore, last) = try await Acts.holding(posts[5], as: fan.token)
            await #expect(throws: MastodonWriteError.pinLimit(5)) { try await fullWrite.pin(last, on: true, limit: said.has.pinLimit) }
            #expect(await fullStore.note(last.key)?.pinned == false)

            // The account part's word, and no other: a sign-in without it is refused for its scopes.
            #expect(MastodonPart.account.words.contains("write:accounts") && !notices.acting.scopes.contains("write:accounts"))
            let scoped = try await Acts.ask("/api/v1/statuses/\(posts[5])/pin", as: notices.acting.token, "POST")
            #expect(scoped.status == 403 && scoped.text == MastodonPostActsCaptures.outsideScopes)
            #expect(MastodonScopeRefusal.isOne(status: scoped.status, body: scoped.body, authenticate: scoped.response.value(forHTTPHeaderField: "WWW-Authenticate")))
            let (narrow, _, note) = try await Acts.holding(posts[5], as: notices.acting.token)
            await #expect(throws: MastodonAuthError.http(403)) { try await narrow.pin(note, on: true) }
            let unsigned = try await Acts.ask("/api/v1/statuses/\(posts[5])/pin", "POST")
            #expect(unsigned.status == 401 && unsigned.text == #"{"error":"The access token is invalid"}"#)
        }

        // Somebody else's post: the writer's, which this does not pin — refused, in the source's words.
        let theirs = try await Acts.ask("/api/v1/statuses/\(notices.spare[3])/pin", as: fan.token, "POST")
        #expect(theirs.status == 422 && theirs.text == MastodonPostActsCaptures.notTheirs)
        let (fanWrite, _, writers) = try await Acts.holding(notices.spare[3], as: fan.token)
        // In the account's own language, as this app's door names none: the source's words, never a full page.
        let notTheirs = await Acts.refusal { try await fanWrite.pin(writers, on: true, limit: said.has.pinLimit) }
        #expect(notTheirs == "校驗失敗：不能釘選他人的嘟文")

        // A post only its mentioned may read: refused here where this device knows it, and by the
        // source, in its words, where it does not.
        try await Acts.withOwnPosts(1, "direct", as: fan.token) { posts in
            let refused = try await Acts.ask("/api/v1/statuses/\(posts[0])/pin", as: fan.token, "POST")
            #expect(refused.status == 422 && refused.text == MastodonPostActsCaptures.mentionedOnly)
            let (write, store, note) = try await Acts.holding(posts[0], as: fan.token)
            #expect(note.audience == .mentioned && !MastodonWrite.pinnable(note))
            await #expect(throws: MastodonWriteError.notPinnable) { try await write.pin(note, on: true) }
            let unknown = Note(
                id: note.id, source: note.source, author: note.author, handle: note.handle, body: note.body,
                postedAt: note.postedAt, categories: note.categories, statusID: note.statusID
            )
            let mentionedOnly = await Acts.refusal { try await write.pin(unknown, on: true, limit: said.has.pinLimit) }
            #expect(mentionedOnly == "校驗失敗：無法釘選只有僅提及使用者可見之嘟文")
            #expect(await store.note(note.key) == note, "nothing changed")
        }
    }

    @Test("A conversation is quieted on somebody else's post and let speak again, each twice and each as asked; a sign-in without the blocks part is refused for its scopes")
    func quieting() async throws {
        try await LocalServers.requireHealthy()
        let (all, notices) = try Acts.seeded()
        try await Acts.withOwnPosts(1, "unlisted", as: try Acts.fan().token) { posts in
            let post = posts[0]
            let (write, store, before) = try await Acts.holding(post, as: all.writer)
            #expect(before.muted == false && before.pinned == nil, "somebody else's: no word of a pin")
            let quiet = try await write.quiet(before, on: true)
            #expect(quiet.muted == true)
            #expect(await store.note(before.key)?.muted == true)
            #expect(try await write.quiet(quiet, on: true).muted == true)
            let speaking = try await write.quiet(quiet, on: false)
            #expect(speaking.muted == false)
            #expect(await store.note(before.key)?.muted == false)
            #expect(try await write.quiet(speaking, on: false).muted == false)
            #expect(try await Acts.ask("/api/v1/statuses/\(post)").object["muted"] == nil, "said to nobody unsigned")

            #expect(MastodonPart.blocks.words.contains("write:mutes") && !notices.acting.scopes.contains("write:mutes"))
            let scoped = try await Acts.ask("/api/v1/statuses/\(post)/mute", as: notices.acting.token, "POST")
            #expect(scoped.status == 403 && scoped.text == MastodonPostActsCaptures.outsideScopes)
            #expect(try await Acts.ask("/api/v1/statuses/\(post)", as: all.writer).object["muted"] as? Bool == false)
        }
    }

    @Test("A host whose document says it has no translator is offered none, and asked all the same answers a not-found — the words it gives a post it has not got — whoever asks")
    func translating() async throws {
        try await LocalServers.requireHealthy()
        let (all, notices) = try Acts.seeded()
        let said = try await MastodonClient(http: try LocalHTTP.client(), host: Acts.host).said()
        #expect(said.has.translates == false && said.has.has(.translation) == .absent)
        let languages = try await Acts.ask("/api/v1/instance/translation_languages")
        #expect(languages.status == 200 && languages.text == "{}")

        let (_, _, post) = try await Acts.holding(all.seeded.plain, as: all.writer)
        #expect(post.audience == .everyone)
        #expect(!MastodonTranslator.offered(post, into: "de", host: said.has.has(.translation)))
        #expect(MastodonTranslator.offered(post, into: "de", host: .unsaid) == (post.language != "de"), "offered but for the host")
        for token in [all.writer, notices.reading.token] {
            await #expect(throws: MastodonTranslationError.notFound) {
                try await MastodonTranslator(door: try Acts.door(token)).translate(post, into: "de")
            }
            let plain = try await Acts.ask("/api/v1/statuses/\(all.seeded.plain)/translate", as: token, "POST", form: "lang=de")
            #expect(plain.status == 404 && plain.text == MastodonPostActsCaptures.notFound)
        }
        for act in ["translate", "pin", "mute"] {
            let nobody = try await Acts.ask("/api/v1/statuses/1/\(act)", as: all.writer, "POST")
            #expect(nobody.status == 404 && nobody.text == MastodonPostActsCaptures.notFound, "\(act)")
        }
    }

    @Test("Who boosted and who favourited a post are given to anyone, a stretch at a time by a next that names the boost or the favourite, read on to the end and nobody twice; a post nobody boosted is nobody, and an id nobody has is the door's not-found")
    func whoBoostedAndFavourited() async throws {
        try await LocalServers.requireHealthy()
        let (all, notices) = try Acts.seeded()
        let liked = notices.liked
        for (list, kind) in [(MastodonPeople.List.boostedBy(post: liked), "reblogged_by"), (.favouritedBy(post: liked), "favourited_by")] {
            let whole = try await Acts.ask("/api/v1/statuses/\(liked)/\(kind)")
            #expect(whole.status == 200 && whole.list.count == 2 && whole.link?.contains(#"rel="next""#) == false, "\(kind)")
            let accounts = whole.list.compactMap { $0["id"] as? String }
            let cut = try await Acts.ask("/api/v1/statuses/\(liked)/\(kind)?limit=1")
            let next = try #require(try MastodonLink.next(in: cut.link), "\(kind)")
            #expect(!accounts.contains(next), "\(kind): the next names the \(kind == "reblogged_by" ? "boost" : "favourite"), not the person")

            for people in [MastodonPeople(http: try LocalHTTP.client(), host: Acts.host), MastodonPeople(door: try Acts.door(notices.reading.token))] {
                var read = PeopleRead()
                repeat {
                    read = try read.readingOn(try await people.stretch(list, source: Acts.source, after: read.next, limit: 1))
                } while !read.ended
                #expect(read.people.map(\.accountID) == accounts, "\(kind): all of them, in the source's order, nobody twice")
                #expect(Set(read.people.map(\.handle)) == ["@fediqo_other@\(Acts.host)", "@fediqo_third@\(Acts.host)"])
            }
        }
        let nobody = try await MastodonPeople(http: try LocalHTTP.client(), host: Acts.host).stretch(.boostedBy(post: notices.cut), source: Acts.source)
        #expect(nobody == PeopleStretch(people: [], next: nil))
        #expect(try await Acts.ask("/api/v1/statuses/1/reblogged_by").text == MastodonPostActsCaptures.notFound)
        await #expect(throws: MastodonRequestError.http(404)) {
            try await MastodonPeople(http: try LocalHTTP.client(), host: Acts.host).stretch(.favouritedBy(post: "1"), source: Acts.source)
        }
    }
}
