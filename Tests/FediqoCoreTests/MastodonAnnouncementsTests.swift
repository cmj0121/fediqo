import Foundation
import Testing
@testable import FediqoCore

/// #321 — what a Mastodon announces to a signed-in reader, read through the one signed-in door;
/// dismissing one (the account part) and a reaction put on and taken off (the acting part, never
/// asked for on its own), each as the server answers it. The lock is the held words'; an empty
/// list is the source giving none, never the host having none (GoToSocial item 7).
@Suite("What a Mastodon announces, and the reader's acts on it")
struct MastodonAnnouncementsTests {
    private static let r = "read:statuses read:lists read:accounts"
    private static let w = "write:statuses write:favourites"
    private static let a = "write:accounts"
    private static let list = "/api/v1/announcements"

    private static func reader(
        _ routes: [String: FixtureSender.Outcome], scopes: String? = "\(r) \(w) \(a)"
    ) throws -> (MastodonAnnouncements, FixtureSender) {
        let token = MastodonFixture.token(scopes: scopes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        let server = FixtureSender(routes)
        return (MastodonAnnouncements(door: MastodonAuthorized(token: token, sender: server, store: tokens)), server)
    }

    /// One announcement in the shape a Mastodon's documentation gives it.
    private static let one = #"""
    {"id":"8","content":"<p>Audio is fixed &amp; back.</p><p>Sorry :blobcat:</p>","starts_at":"2026-10-20T00:00:00.000Z","ends_at":"2026-10-21T00:00:00.000Z","all_day":true,"published_at":"2026-10-14T01:27:38.726Z","updated_at":"2026-10-14T02:00:00Z","read":false,"mentions":[],"statuses":[],"tags":[],"emojis":[{"shortcode":"blobcat","url":"https://files.example/blobcat.png","static_url":"https://files.example/blobcat-still.png","visible_in_picker":true}],"reactions":[{"name":"bongoCat","count":9,"me":false,"url":"https://files.example/bongo.gif","static_url":"https://files.example/bongo.png"},{"name":"🤔","count":1,"me":true}]}
    """#

    // MARK: - Reading

    @Test("Announcements are read signed in from the sign-in's own host: words out of their markup as a post's are, when, the stretch it is about, the source's read, and each reaction with its count and whether the reader put it")
    func readsThem() async throws {
        let (announcements, server) = try Self.reader([Self.list: .json("[\(Self.one)]")])
        let read = try await announcements.read()
        let sent = try #require(await server.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.absoluteString == "https://\(MastodonFixture.host)\(Self.list)")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        let it = try #require(read.first)
        #expect(read.count == 1)
        #expect(it.id == "8")
        #expect(it.words == HTMLText.plain("<p>Audio is fixed &amp; back.</p><p>Sorry :blobcat:</p>"))
        #expect(it.words.contains("Audio is fixed & back."))
        #expect(it.emojis == [CustomEmoji(shortcode: "blobcat", url: URL(string: "https://files.example/blobcat.png")!, staticURL: URL(string: "https://files.example/blobcat-still.png")!)])
        #expect(it.publishedAt == MastodonJSON.date(from: "2026-10-14T01:27:38.726Z"))
        #expect(it.updatedAt == MastodonJSON.date(from: "2026-10-14T02:00:00Z"))
        #expect(it.startsAt == MastodonJSON.date(from: "2026-10-20T00:00:00.000Z"))
        #expect(it.endsAt == MastodonJSON.date(from: "2026-10-21T00:00:00.000Z"))
        #expect(it.allDay)
        #expect(it.read == false)
        #expect(it.reactions == [
            .init(name: "bongoCat", count: 9, me: false, picture: CustomEmoji(shortcode: "bongoCat", url: URL(string: "https://files.example/bongo.gif")!, staticURL: URL(string: "https://files.example/bongo.png")!)),
            .init(name: "🤔", count: 1, me: true),
        ])
    }

    @Test("What the source leaves unsaid stays unsaid: no read flag is not read, no `me` is not 'not the reader', no times are none")
    func unsaidIsUnsaid() async throws {
        let bare = #"[{"id":"9","content":"<p>hi</p>","reactions":[{"name":"x","count":2}]}]"#
        let (announcements, _) = try Self.reader([Self.list: .json(bare)])
        let it = try #require(try await announcements.read().first)
        #expect(it.read == nil)
        #expect(it.publishedAt == nil && it.startsAt == nil && it.endsAt == nil && it.updatedAt == nil)
        #expect(!it.allDay)
        #expect(it.reactions == [.init(name: "x", count: 2, me: nil)])
    }

    @Test("An empty list is the source giving none — handed back as none, never as the host having no such thing; only a not-found of the address says that")
    func emptyIsNotAbsent() async throws {
        let (empty, _) = try Self.reader([Self.list: .json("[]")])
        #expect(try await empty.read().isEmpty)

        for page in ["<html>no</html>", #"{"error":"Not Found"}"#, ""] {
            let (absent, _) = try Self.reader([Self.list: .json(page, status: 404)])
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await absent.read() }
        }
        // A record's not-found is no word about the host.
        let (record, _) = try Self.reader([Self.list: .json(#"{"error":"Record not found"}"#, status: 404)])
        await #expect(throws: MastodonAuthError.http(404)) { try await record.read() }
    }

    @Test("A reading refused (403) for want of a word, as a Mastodon says it, is outside the scope; any other 403 is the source's refusal; an answer that is no list is unreadable")
    func readRefusals() async throws {
        let (outside, _) = try Self.reader([Self.list: .json(#"{"error":"This action is outside the authorized scopes"}"#, status: 403)])
        await #expect(throws: AnnouncementError.outsideScope) { try await outside.read() }
        // GoToSocial's 403 names no word and is not Mastodon's sentence: the source refusing.
        let (refused, _) = try Self.reader([Self.list: .json(#"{"error":"Forbidden"}"#, status: 403)])
        await #expect(throws: AnnouncementError.forbidden) { try await refused.read() }
        let (odd, _) = try Self.reader([Self.list: .json(#"{"id":"1"}"#)])
        await #expect(throws: AnnouncementError.unreadable) { try await odd.read() }
    }

    @Test("Entry by entry and bounded: one with no id an act could use, or of another shape, is left out; a reaction whose name is no name is left out; a list and its reactions are held to their lengths")
    func entryByEntry() async throws {
        let reactions = (0..<150).map { #"{"name":"r\#($0)","count":1,"me":false}"# }.joined(separator: ",")
        let many = (0..<120).map { #"{"id":"\#($0 + 1)","content":"<p>n</p>"}"# }
        let body = "[" + ([
            #"{"id":"1/../2","content":"x"}"#, #"{"content":"no id"}"#, "7",
            #"{"id":"5","content":"<p>kept</p>","reactions":[{"name":"a b","count":1},{"name":"../x","count":1},{"name":"ok","count":-3},\#(reactions)]}"#,
        ] + many).joined(separator: ",") + "]"
        let (announcements, _) = try Self.reader([Self.list: .json(body)])
        let read = try await announcements.read()
        #expect(read.count == MastodonAnnouncements.longest)
        let kept = try #require(read.first)
        #expect(kept.id == "5")
        #expect(kept.reactions.count == MastodonAnnouncements.reactionsLongest)
        #expect(kept.reactions.first == .init(name: "ok", count: 0, me: nil))
    }

    @Test("Words are cut before they are taken out of their markup")
    func wordsAreCut() async throws {
        let long = String(repeating: "a", count: MastodonAnnouncements.markupLength + 500)
        let (announcements, _) = try Self.reader([Self.list: .json(#"[{"id":"1","content":"\#(long)"}]"#)])
        let it = try #require(try await announcements.read().first)
        #expect(it.words.unicodeScalars.count <= MastodonAnnouncements.markupLength + 1)
    }

    // MARK: - Dismissing

    @Test("Dismissing is one POST to the announcement's own dismiss, nothing in it, and the source's 200 is done")
    func dismisses() async throws {
        let path = "\(Self.list)/8/dismiss"
        let (announcements, server) = try Self.reader([path: .json("{}")])
        try await announcements.dismiss("8")
        let requests = await server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "POST")
        #expect(requests.first?.url?.absoluteString == "https://\(MastodonFixture.host)\(path)")
        #expect(await server.form(path).isEmpty)
    }

    @Test("A dismissal's 403 is the account part's lock only where it is not held, the source forbidding it where it is — whatever the 403 says; a 404 is the announcement gone")
    func dismissRefusals() async throws {
        let path = "\(Self.list)/8/dismiss"
        for body in [#"{"error":"This action is outside the authorized scopes"}"#, #"{"error":"forbidden"}"#, ""] {
            let (without, _) = try Self.reader([path: .json(body, status: 403)], scopes: "\(Self.r) \(Self.w)")
            await #expect(throws: AnnouncementError.locked(.account)) { try await without.dismiss("8") }
            let (unsaid, _) = try Self.reader([path: .json(body, status: 403)], scopes: nil)
            await #expect(throws: AnnouncementError.locked(.account)) { try await unsaid.dismiss("8") }
            let (holding, _) = try Self.reader([path: .json(body, status: 403)], scopes: "\(Self.r) \(Self.a)")
            await #expect(throws: AnnouncementError.forbidden) { try await holding.dismiss("8") }
        }
        let (gone, _) = try Self.reader([path: .json(#"{"error":"Record not found"}"#, status: 404)])
        await #expect(throws: AnnouncementError.gone) { try await gone.dismiss("8") }
    }

    @Test("An id that is not one segment of a path is asked nothing")
    func badIDsAskNothing() async throws {
        let (announcements, server) = try Self.reader([:])
        for id in ["", "1/2", "../x", "a b", String(repeating: "1", count: 65)] {
            await #expect(throws: MastodonRequestError.invalidURL) { try await announcements.dismiss(id) }
            await #expect(throws: MastodonRequestError.invalidURL) { try await announcements.react(id, with: "ok") }
            await #expect(throws: MastodonRequestError.invalidURL) { try await announcements.unreact(id, with: "ok") }
        }
        #expect(await server.requests.isEmpty)
    }

    // MARK: - Reactions

    @Test("A reaction is put on by a PUT and taken off by a DELETE of its own path, an emoji's name as one escaped segment; the source's 200 is done, and nothing else is asked")
    func reacts() async throws {
        for name in ["🤔", "bongoCat", "👍🏽", "❤️", "1️⃣"] {
            let path = "\(Self.list)/8/reactions/\(name)"
            let (announcements, server) = try Self.reader([path: .json("{}")])
            try await announcements.react("8", with: name)
            try await announcements.unreact("8", with: name)
            let requests = await server.requests
            #expect(requests.map(\.httpMethod) == ["PUT", "DELETE"], "\(name)")
            #expect(requests.allSatisfy { $0.url?.path == path && $0.url?.host == MastodonFixture.host })
            #expect(requests.allSatisfy { $0.httpBody == nil })
        }
        let (announcements, server) = try Self.reader(["\(Self.list)/8/reactions/🤔": .json("{}")])
        try await announcements.react("8", with: "🤔")
        #expect(await server.requests.first?.url?.absoluteString == "https://\(MastodonFixture.host)\(Self.list)/8/reactions/%F0%9F%A4%94")
    }

    @Test("A reaction's 403 is the acting part's lock only where it is not held — the account part is no stand-in — and the source forbidding it where it is; a 422 is the source's refusal with its sentence; a 404 the announcement gone when putting one on, and done when taking one off")
    func reactionRefusals() async throws {
        let path = "\(Self.list)/8/reactions/🤔"
        let (without, _) = try Self.reader([path: .json("", status: 403)], scopes: "\(Self.r) \(Self.a)")
        await #expect(throws: AnnouncementError.locked(.acting)) { try await without.react("8", with: "🤔") }
        await #expect(throws: AnnouncementError.locked(.acting)) { try await without.unreact("8", with: "🤔") }
        let (holding, _) = try Self.reader([path: .json("", status: 403)], scopes: "\(Self.r) \(Self.w)")
        await #expect(throws: AnnouncementError.forbidden) { try await holding.react("8", with: "🤔") }

        let (refused, _) = try Self.reader([path: .json(#"{"error":"Validation failed: Name is not a recognized emoji"}"#, status: 422)])
        await #expect(throws: AnnouncementError.refused(sentence: "Validation failed: Name is not a recognized emoji")) {
            try await refused.react("8", with: "🤔")
        }
        let (unsaid, _) = try Self.reader([path: .json("<html>", status: 422)])
        await #expect(throws: AnnouncementError.refused(sentence: "")) { try await unsaid.react("8", with: "🤔") }

        // A real Mastodon's 404 for a reaction of the reader's that is not there, and for an
        // announcement withdrawn, alike: putting one on is refused as gone; taking one off is done.
        let (gone, server) = try Self.reader([path: .json(#"{"error":"Record not found"}"#, status: 404)])
        await #expect(throws: AnnouncementError.gone) { try await gone.react("8", with: "🤔") }
        try await gone.unreact("8", with: "🤔")
        #expect(await server.requests.map(\.httpMethod) == ["PUT", "DELETE"], "asked once each, and nothing more")
    }

    @Test("A reaction's name is a shortcode or an emoji, and nothing that could be more than one segment of a path")
    func reactionNames() {
        for name in ["blobcat", "blob_cat2", "🤔", "👍🏽", "👨‍👩‍👧", "❤️", "🏴󠁧󠁢󠁳󠁣󠁴󠁿", "1️⃣"] {
            #expect(MastodonAnnouncements.isReactionName(name), "\(name)")
        }
        for name in ["", "a b", "a/b", "..", "%2F", "a?b", "a#b", "a\u{202E}b", "é", "\u{FE0F}", "\u{200D}\u{FE0F}", "a\u{FE0F}", String(repeating: "a", count: 65)] {
            #expect(!MastodonAnnouncements.isReactionName(name), "\(name)")
        }
    }
}
