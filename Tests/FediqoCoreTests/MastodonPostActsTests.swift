import Foundation
import Testing
@testable import FediqoCore

/// #334 in Core: a post pinned and unpinned, its conversation quieted and let speak, translated
/// into the reader's language, and who boosted and who favourited it read on to the end — each
/// as a Mastodon answers it (`MastodonPostActsCaptures`, asked of 4.6.6). The translated path is
/// held through a fixture that answers as the documentation says (D7): the fixture's server has
/// no translator.
///
/// Every expected string is written out here and not read off the code it is held against.
@Suite("Pinning, quieting, translating a post, and who boosted and favourited it")
struct MastodonPostActsTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)

    /// One status as the server sends it, with `pinned` and `muted` left out where nil — as on
    /// somebody else's post, and on an unsigned read.
    static func status(
        id: String = "9", visibility: String = "public", language: String? = "en",
        pinned: Bool? = nil, muted: Bool? = nil, extra: String = ""
    ) -> String {
        let marks = (pinned.map { #","pinned":\#($0)"# } ?? "") + (muted.map { #","muted":\#($0)"# } ?? "")
        let lang = language.map { #","language":"\#($0)""# } ?? ""
        return """
        {"id":"\(id)","uri":"https://social.example/users/me/statuses/\(id)",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>","spoiler_text":"",
         "visibility":"\(visibility)","favourited":false,"reblogged":false,"bookmarked":false\(lang)\(marks)\(extra),
         "account":{"username":"me","acct":"me","display_name":"Me"}}
        """
    }

    private static func held(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .home, sent: .now())
    }

    private static func door(_ routes: [String: FeatureServer.Answer]) throws -> (MastodonAuthorized, FeatureServer) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let server = FeatureServer(routes)
        return (MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens), server)
    }

    private static func writing(
        holding note: Note, _ routes: [String: FeatureServer.Answer]
    ) async throws -> (MastodonWrite, ItemStore, FeatureServer) {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([note])
        let (door, server) = try door(routes)
        return (MastodonWrite(door: door, store: store), store, server)
    }

    // MARK: - What the source says

    @Test("Whether a post is pinned and its conversation quieted is the source's word: said to its author, nothing where it is not said, and nothing for a word of another shape")
    func theSourcesWord() throws {
        let own = try Self.held(Self.status(pinned: true, muted: false))
        #expect(own.pinned == true && own.muted == false && own.saysReader)
        let theirs = try Self.held(Self.status(muted: true))
        #expect(theirs.pinned == nil && theirs.muted == true)
        let unsigned = try Self.held(Self.status())
        #expect(unsigned.pinned == nil && unsigned.muted == nil)
        let odd = try Self.held(Self.status(extra: #","pinned":"yes","muted":1"#))
        #expect(odd.pinned == nil && odd.muted == nil && odd.body == "hello", "costs the word and never the post")
        // A read that says nothing keeps what was held; one that says wins.
        #expect(unsigned.refreshed(over: own).pinned == true && unsigned.refreshed(over: own).muted == false)
        #expect(try Self.held(Self.status(pinned: false, muted: true)).refreshed(over: own).pinned == false)
        #expect(own.withoutReaderMarks().pinned == nil && own.withoutReaderMarks().muted == nil)
    }

    // MARK: - Pinning

    @Test("A pin is sent to the post's own id and lands as the source answered it; taking it off the same way")
    func pinLands() async throws {
        let before = try Self.held(Self.status(pinned: false, muted: false))
        let (write, store, server) = try await Self.writing(holding: before, [
            "POST /api/v1/statuses/9/pin": .init(body: Self.status(pinned: true, muted: false)),
            "POST /api/v1/statuses/9/unpin": .init(body: Self.status(pinned: false, muted: false)),
        ])
        let pinned = try await write.pin(before, on: true)
        #expect(pinned.pinned == true && pinned.key == before.key)
        #expect(await store.note(before.key)?.pinned == true)
        #expect(try await write.pin(pinned, on: false).pinned == false)
        #expect(await store.note(before.key)?.pinned == false)
        #expect(await server.asked == ["POST /api/v1/statuses/9/pin", "POST /api/v1/statuses/9/unpin"])
    }

    @Test("A pin turned away is told by the post read again, never by the sentence: pinned lands as pinned; the reader's own, unpinned, is a full page with the host's limit in any language; somebody else's post and one only its mentioned may read are the source's own words; an unpin turned away asks nothing more; and nothing changes")
    func pinTurnedAway() async throws {
        let before = try Self.held(Self.status(pinned: false))
        let refused = FeatureServer.Answer(body: MastodonPostActsCaptures.duplicate, status: 422)
        let (already, store, server) = try await Self.writing(holding: before, [
            "POST /api/v1/statuses/9/pin": refused,
            "GET /api/v1/statuses/9": .init(body: Self.status(pinned: true)),
        ])
        #expect(try await already.pin(before, on: true).pinned == true)
        #expect(await store.note(before.key)?.pinned == true)
        #expect(await server.asked == ["POST /api/v1/statuses/9/pin", "GET /api/v1/statuses/9"])

        // A full page, in English and in the account's own language alike (asked of a real one).
        for body in [MastodonPostActsCaptures.full, MastodonPostActsCaptures.fullInChinese] {
            let (full, fullStore, _) = try await Self.writing(holding: before, [
                "POST /api/v1/statuses/9/pin": .init(body: body, status: 422),
                "GET /api/v1/statuses/9": .init(body: Self.status(pinned: false)),
            ])
            await #expect(throws: MastodonWriteError.pinLimit(5)) { try await full.pin(before, on: true, limit: 5) }
            await #expect(throws: MastodonWriteError.pinLimit(nil)) { try await full.pin(before, on: true) }
            #expect(await fullStore.note(before.key)?.pinned == false, "nothing said changed")
        }

        // Somebody else's post says nothing of a pin; one only its mentioned may read, which this
        // device did not know was, says so when read again.
        let unsaid = try Self.held(Self.status(visibility: "nonesuch"))
        #expect(unsaid.audience == nil && MastodonWrite.pinnable(unsaid))
        for (body, reread, sentence) in [
            (MastodonPostActsCaptures.notTheirs, Self.status(), "Validation failed: Someone else's post cannot be pinned"),
            (MastodonPostActsCaptures.mentionedOnly, Self.status(visibility: "direct"),
             "Validation failed: Posts that are only visible to mentioned users cannot be pinned"),
            ("not json", Self.status(), ""),
        ] {
            let (write, held, _) = try await Self.writing(holding: unsaid, [
                "POST /api/v1/statuses/9/pin": .init(body: body, status: 422),
                "GET /api/v1/statuses/9": .init(body: reread),
            ])
            await #expect(throws: MastodonWriteError.refused(sentence: sentence)) { try await write.pin(unsaid, on: true, limit: 5) }
            #expect(await held.note(unsaid.key) == unsaid)
        }
        let (unpin, _, unpinServer) = try await Self.writing(holding: before, [
            "POST /api/v1/statuses/9/unpin": .init(body: MastodonPostActsCaptures.notTheirs, status: 422),
        ])
        await #expect(throws: MastodonWriteError.refused(sentence: "Validation failed: Someone else's post cannot be pinned")) {
            try await unpin.pin(before, on: false)
        }
        #expect(await unpinServer.asked == ["POST /api/v1/statuses/9/unpin"])
    }

    @Test("A boost and a post only its mentioned may read are not pinned, and nothing is asked; a refusal for want of the account part is the door's")
    func notPinnable() async throws {
        let direct = try Self.held(Self.status(visibility: "direct"))
        let followers = try Self.held(Self.status(visibility: "private"))
        #expect(!MastodonWrite.pinnable(direct) && MastodonWrite.pinnable(followers))
        let reblog = Note(
            id: "https://social.example/users/bob/statuses/900/activity", source: Self.source, author: "Bob",
            handle: "@bob@social.example", body: "", postedAt: Date(timeIntervalSince1970: 0), categories: [.home],
            statusID: "900", refs: [Reference(kind: .reblogs, id: "https://social.example/users/me/statuses/9", statusID: "9")]
        )
        #expect(!MastodonWrite.pinnable(reblog))
        let (write, store, server) = try await Self.writing(holding: direct, [
            "POST /api/v1/statuses/9/pin": .init(body: MastodonPostActsCaptures.outsideScopes, status: 403),
        ])
        await #expect(throws: MastodonWriteError.notPinnable) { try await write.pin(direct, on: true) }
        await #expect(throws: MastodonWriteError.notPinnable) { try await write.pin(reblog, on: true) }
        #expect(await server.asked.isEmpty)
        await #expect(throws: MastodonAuthError.http(403)) { try await write.pin(followers, on: true) }
        #expect(await store.note(direct.key) == direct)
    }

    @Test("A read sent before the pin landed does not take it back, and a sign-in that ends takes both words off")
    func aReadOnItsWay() async throws {
        let before = try Self.held(Self.status(pinned: false, muted: false))
        let onItsWay = ReadMoment.now()
        let (write, store, _) = try await Self.writing(holding: before, [
            "POST /api/v1/statuses/9/pin": .init(body: Self.status(pinned: true, muted: false)),
            "POST /api/v1/statuses/9/mute": .init(body: Self.status(pinned: true, muted: true)),
        ])
        _ = try await write.pin(before, on: true)
        _ = try await write.quiet(before, on: true)
        var stale = try Self.held(Self.status(pinned: false, muted: false))
        stale.asked = onItsWay
        await store.refresh([stale], ifSourceHere: Self.host)
        let now = try #require(await store.note(before.key))
        #expect(now.pinned == true && now.muted == true)

        #expect(await store.forgetReaderMarks(host: Self.host))
        let plain = try #require(await store.note(before.key))
        #expect(plain.pinned == nil && plain.muted == nil)
    }

    // MARK: - Quieting

    @Test("A conversation is quieted on anybody's post and let speak again, each landing as the source answered")
    func quietLands() async throws {
        let before = try Self.held(Self.status(muted: false))
        let (write, store, server) = try await Self.writing(holding: before, [
            "POST /api/v1/statuses/9/mute": .init(body: Self.status(muted: true)),
            "POST /api/v1/statuses/9/unmute": .init(body: Self.status(muted: false)),
        ])
        #expect(try await write.quiet(before, on: true).muted == true)
        #expect(await store.note(before.key)?.muted == true)
        #expect(try await write.quiet(before, on: false).muted == false)
        #expect(await store.note(before.key)?.pinned == nil, "nobody said it was pinned")
        #expect(await server.asked == ["POST /api/v1/statuses/9/mute", "POST /api/v1/statuses/9/unmute"])
    }

    // MARK: - Translating

    @Test("A translation is asked in the language given and comes back with who made it, the post untouched")
    func translated() async throws {
        let post = try Self.held(Self.status())
        let (door, server) = try Self.door(["POST /api/v1/statuses/9/translate": .init(body: MastodonPostActsCaptures.translation)])
        let said = try await MastodonTranslator(door: door).translate(post, into: "de")
        #expect(said == PostTranslation(body: "Hallo, Welt", spoiler: nil, from: "en", provider: "DeepL.com"))
        #expect(await server.form() == "lang=de")

        // A boost is translated by the post it boosts, at that post's own id.
        let (boostDoor, boostServer) = try Self.door(["POST /api/v1/statuses/9/translate": .init(body: MastodonPostActsCaptures.translation)])
        #expect(try await MastodonTranslator(door: boostDoor).translate(Self.boost(of: post), into: "de").body == "Hallo, Welt")
        #expect(await boostServer.asked == ["POST /api/v1/statuses/9/translate"])
    }

    @Test("A translated cover line is the cover a reader reads: entities decoded and markup taken out, on one line, as a post's words are")
    func translatedCover() async throws {
        let post = try Self.held(Self.status())
        let (door, _) = try Self.door(["POST /api/v1/statuses/9/translate": .init(body: MastodonPostActsCaptures.coveredTranslation)])
        let said = try await MastodonTranslator(door: door).translate(post, into: "de")
        #expect(said.spoiler == "Spoiler: Tom & Jerry <3 \"Ende\"")
        #expect(said.body == "Hallo & tschüss")
    }

    @Test("A translation's not-found is remembered for the run as no translator only where the host's document said nothing of translating")
    func notFoundRemembered() {
        var known = MastodonHostsKnown()
        known.translationNotFound(at: "quiet.example")
        #expect(known.has(.translation, at: "quiet.example") == .absent)
        known.heard(MastodonHostSays(featuredTagLimit: nil), at: "silent.example")
        known.translationNotFound(at: "silent.example")
        #expect(known.has(.translation, at: "silent.example") == .absent)
        known.heard(MastodonHostSays(featuredTagLimit: nil, translates: true), at: "says.example")
        known.translationNotFound(at: "says.example")
        #expect(known.has(.translation, at: "says.example") == .present, "a post it has not got, not a host without a translator")
    }

    /// A boost of `post` by somebody, as a timeline lists it.
    private static func boost(of post: Note) -> Note {
        Note(
            id: "https://social.example/users/bob/statuses/900/activity", source: source, author: "Bob",
            handle: "@bob@social.example", body: "", postedAt: Date(timeIntervalSince1970: 0), categories: [.home],
            statusID: "900", refs: [Reference(kind: .reblogs, id: post.id, statusID: post.statusID)]
        )
    }

    @Test("A refusal, a translator that did not answer and a not-found each leave the original; a language that is no tag and an unnameable post ask nothing")
    func notTranslated() async throws {
        let post = try Self.held(Self.status())
        for (answer, error) in [
            (FeatureServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403), MastodonTranslationError.refused),
            (FeatureServer.Answer(body: #"{"error":"Service Unavailable"}"#, status: 503), .unavailable),
            (FeatureServer.Answer(body: MastodonPostActsCaptures.notFound, status: 404), .notFound),
            (FeatureServer.Answer(body: "[]"), .unreadable),
        ] {
            let (door, _) = try Self.door(["POST /api/v1/statuses/9/translate": answer])
            await #expect(throws: error) { try await MastodonTranslator(door: door).translate(post, into: "de") }
        }
        let (door, server) = try Self.door([:])
        await #expect(throws: MastodonTranslationError.invalid) { try await MastodonTranslator(door: door).translate(post, into: "de de") }
        let bare = Note(id: "x", source: Self.source, author: "A", handle: "@a@social.example", body: "hi", postedAt: Date(), categories: [])
        await #expect(throws: MastodonTranslationError.invalid) { try await MastodonTranslator(door: door).translate(bare, into: "de") }
        #expect(await server.asked.isEmpty)
    }

    @Test("A translation is offered (D4) on a post anyone may read, with words, not already in the language, at a host that does not say it has no translator")
    func offered() throws {
        let english = try Self.held(Self.status(language: "en"))
        #expect(MastodonTranslator.offered(english, into: "de", host: .unsaid))
        #expect(MastodonTranslator.offered(english, into: "zh-Hant-TW", host: .present))
        #expect(!MastodonTranslator.offered(english, into: "en", host: .present))
        #expect(!MastodonTranslator.offered(english, into: "en-GB", host: .present), "the same language, another place")
        #expect(!MastodonTranslator.offered(english, into: "de", host: .absent))
        #expect(!MastodonTranslator.offered(english, into: "", host: .present))
        #expect(MastodonTranslator.offered(try Self.held(Self.status(visibility: "unlisted")), into: "de", host: .present))
        for visibility in ["private", "direct"] {
            #expect(!MastodonTranslator.offered(try Self.held(Self.status(visibility: visibility)), into: "de", host: .present), "\(visibility)")
        }
        #expect(MastodonTranslator.offered(try Self.held(Self.status(language: nil)), into: "en", host: .present), "the source says what it was written in")
        let wordless = try Self.held(Self.status().replacingOccurrences(of: "<p>hello</p>", with: ""))
        #expect(!MastodonTranslator.offered(wordless, into: "de", host: .present))
        // A boost is offered by the post it boosts, and by no other.
        let boost = Self.boost(of: english)
        #expect(MastodonTranslator.offered(boost, into: "de", host: .present, boosted: english))
        #expect(!MastodonTranslator.offered(boost, into: "en", host: .present, boosted: english))
        #expect(!MastodonTranslator.offered(boost, into: "de", host: .present))
        #expect(!MastodonTranslator.offered(boost, into: "de", host: .present, boosted: try Self.held(Self.status(id: "10"))), "another post")
    }

    // MARK: - What the host says

    @Test("The host's document says whether it translates and how many posts may be pinned, each read leniently and bounded")
    func theHostSays() {
        func says(_ document: String) -> MastodonHostSays { MastodonHostSays(document: Data(document.utf8)) }
        let captured = says(MastodonHostCaptures.document)
        #expect(captured.translates == false && captured.has(.translation) == .absent)
        let on = says(#"{"configuration":{"translation":{"enabled":true},"accounts":{"max_pinned_statuses":5}}}"#)
        #expect(on.translates == true && on.has(.translation) == .present && on.pinLimit == 5)
        for silent in [#"{"configuration":{"translation":{"enabled":"yes"}}}"#, #"{"configuration":{"translation":true}}"#, "{}"] {
            #expect(says(silent).has(.translation) == .unsaid && says(silent).translates == nil, "\(silent)")
        }
        #expect(says(#"{"configuration":{"accounts":{"max_pinned_statuses":-1}}}"#).pinLimit == nil)
        #expect(says(#"{"configuration":{"accounts":{"max_pinned_statuses":99999}}}"#).pinLimit == MastodonHostSays.most)
        #expect(says(#"{"configuration":{"accounts":{"max_pinned_statuses":"5","max_featured_tags":3}}}"#) == MastodonHostSays(featuredTagLimit: 3))
    }

    // MARK: - Who boosted it, and who favourited it

    private static func people(_ ids: ClosedRange<Int>) -> String {
        "[" + ids.map { #"{"id":"\#($0)","acct":"p\#($0)","username":"p\#($0)"}"# }.joined(separator: ",") + "]"
    }

    @Test("Who boosted a post and who favourited it are read on by the source's own next, which names the boost or the favourite, to the end and nobody twice, unsigned or signed in")
    func whoBoostedAndFavourited() async throws {
        for (list, path) in [
            (MastodonPeople.List.boostedBy(post: "9"), "/api/v1/statuses/9/reblogged_by"),
            (.favouritedBy(post: "9"), "/api/v1/statuses/9/favourited_by"),
        ] {
            let routes: [String: FeatureServer.Answer] = [
                "GET \(path)?limit=2": .init(body: Self.people(1...2), link: #"<https://\#(Self.host)\#(path)?limit=2&max_id=900>; rel="next", <https://\#(Self.host)\#(path)?limit=2&since_id=901>; rel="prev""#),
                "GET \(path)?limit=2&max_id=900": .init(body: Self.people(2...3), link: #"<https://\#(Self.host)\#(path)?limit=2&since_id=899>; rel="prev""#),
            ]
            let (door, _) = try Self.door(routes)
            let unsigned = FeatureServer(routes)
            for people in [MastodonPeople(door: door), MastodonPeople(http: unsigned, host: Self.host)] {
                var read = PeopleRead()
                let first = try await people.stretch(list, source: Self.source, limit: 2)
                #expect(first.next == "900", "the boost's or the favourite's own id, never a person's")
                read = try read.readingOn(first)
                read = try read.readingOn(try await people.stretch(list, source: Self.source, after: read.next, limit: 2))
                #expect(read.people.map(\.accountID) == ["1", "2", "3"] && read.ended)
            }
        }
        let (door, server) = try Self.door([:])
        await #expect(throws: MastodonRequestError.invalidURL) {
            try await MastodonPeople(door: door).stretch(.boostedBy(post: "9/x"), source: Self.source)
        }
        #expect(await server.asked.isEmpty)
    }
}
