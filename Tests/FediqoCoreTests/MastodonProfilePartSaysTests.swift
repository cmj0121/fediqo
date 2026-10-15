import Foundation
import Testing
@testable import FediqoCore

/// What rides the profile part (#312, #315, #318, #321) — a picture and a header, a suggestion
/// dismissed, people and hashtags featured, and what the server announces — done through this
/// app's own code against the real one this checkout brings up (`make servers`, Mastodon 4.6.6).
///
/// **The reader is the seed's `parts_321`**, whom no other check reads, counts or lists, and whom
/// the seed puts back on every run: no picture, no header, nobody dismissed from what it is
/// suggested, nobody and no hashtag featured, `parts_followed_315` followed and
/// `parts_stranger_315` not, no announcement dismissed and no reaction of theirs. It signs in
/// with this app's words for every part, and with the same words but the profile part's.
///
/// **What a check does it undoes, however it ends** — but two acts have no undoing at any
/// address: a suggestion dismissed and an announcement dismissed. Those the seed takes back,
/// and the checks of them hold only what holds on a run after the first.
///
/// **Asked of the server first, by hand, 2026-10-15** — and what the checks hold:
/// - **Announcements are read with any sign-in at all**: the address asks no word, only that
///   somebody is signed in (`require_user!`), so this app's reading words — and a sign-in for
///   reading posts alone — are answered 200. It never answers 403 `insufficient_scope`; unsigned
///   it is a 422, "This method requires an authenticated user".
/// - Dismissing one wants `write:accounts` (403 `insufficient_scope`, "requires scope _write
///   write:accounts_"); it is `200 {}`, and `200 {}` again; **the dismissed one is still listed,
///   `read: true`, with or without `with_dismissed`**, and read `false` by everybody else.
/// - A reaction wants `write:favourites`. PUT is `200 {}`; **the same again is 422 `Duplicate
///   record`**; a name that is no emoji 422 `Validation failed: Name is not a recognized emoji`.
///   DELETE is `200 {}`; **one not there is 404 `Record not found`**, as an announcement nobody
///   has is to either.
/// - **The host states 16 MiB for any picture, and holds an own picture to 8 MB**: one of 9 MiB is
///   a 422 naming `avatar` ("must be less than 8 MB") and `avatar_file_size`. Taking away a
///   picture there is none of is `200` with the account.
/// - Featuring somebody not followed is a 422 ("You must be already following…"); featuring and
///   taking off are each `200` with the standing, and the same again. A hashtag featured again is
///   `200` with the same featuring; **under another case it is a 422** ("Tag has already been
///   taken"); taking off one gone is a 404.
@Suite("What a Mastodon says of what rides the profile part", .enabled(if: LocalServers.requested), .serialized)
struct MastodonProfilePartSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    /// The smallest PNG there is, one pixel — the seed's own.
    private static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func parts() throws -> LocalServers.Seeded.Parts {
        try #require(try LocalServers.seeded().parts, "servers/.run/mastodon-tokens.json was seeded before this was: run `make servers` again")
    }

    private func door(_ token: String, scopes: String) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        let held = MastodonToken(host: Self.host, accessToken: token, clientID: "x", clientSecret: "x", scopes: scopes)
        try tokens.save(held)
        return MastodonAuthorized(token: held, sender: try LocalHTTP.client(), store: tokens)
    }

    /// Runs `body`, then `undo` whatever became of it, and throws what `body` threw.
    private func undoing(_ body: () async throws -> Void, _ undo: () async -> Void) async throws {
        let thrown: (any Error)?
        do {
            try await body()
            thrown = nil
        } catch {
            thrown = error
        }
        await undo()
        if let thrown { throw thrown }
    }

    @Test("A picture and a header go with Save and come back as the server keeps them, read back the same afresh, and are taken away to none; one over the host's stated limit is never sent; one under it but over the 8 MB the server holds an own picture to is its refusal on the picture's row; without the profile part a removal is the part's lock")
    func picturesChangedAndRemoved() async throws {
        try await LocalServers.requireHealthy()
        let parts = try parts()
        let own = MastodonOwnAccount(door: try door(parts.token, scopes: parts.scopes))
        let start = try await own.read()
        #expect(start.picture == nil && start.header == nil, "as the seed left it")
        let limit = try #require(try await own.limits().picture)
        #expect(limit == 16_777_216, "what the host states of any picture")

        try await undoing {
            let sent = try #require(try await own.change(from: start, to: start, pictures: [
                .picture: .chosen(Self.pixel, type: "image/png", name: "face.png"),
                .header: .chosen(Self.pixel, type: "image/png", name: "band.png"),
            ], limit: limit))
            let picture = try #require(sent.account.picture), header = try #require(sent.account.header)
            #expect(picture.host() == Self.host && header.host() == Self.host)
            #expect(sent.person.accountID == parts.id)
            let back = try await own.read()
            #expect(back.picture == picture && back.header == header, "read back the same")

            let removed = try #require(try await own.change(from: back, to: back, pictures: [.picture: .removed, .header: .removed]))
            #expect(removed.account.picture == nil && removed.account.header == nil)
            #expect(try await own.read() == start, "read back as none")
            #expect(try await own.change(from: start, to: start, pictures: [.picture: .removed])?.account == start, "none taken away again is the account as it is")

            let over = Data(count: limit + 1)
            await #expect(throws: OwnPictureTooLarge(limit: limit, stated: true)) {
                _ = try await own.change(from: start, to: start, pictures: [.picture: .chosen(over, type: "image/png", name: "big.png")], limit: limit)
            }
            // A picture with nine MiB after its end: under what the host states, over what it keeps.
            let large = Self.pixel + Data(count: 9 << 20)
            let refused = await #expect(throws: OwnAccountError.self) {
                _ = try await own.change(from: start, to: start, pictures: [.picture: .chosen(large, type: "image/png", name: "large.png")], limit: limit)
            }
            guard case let .refused(_, rows) = refused else {
                Issue.record("not a refusal: \(String(describing: refused))")
                return
            }
            #expect(rows.keys.contains(.picture) && rows[.picture]?.contains("8") == true, "\(rows)")
            #expect(try await own.read() == start, "nothing kept")

            let lacking = MastodonOwnAccount(door: try door(parts.lacking, scopes: parts.lackingScopes))
            await #expect(throws: OwnAccountError.locked) { _ = try await lacking.change(from: start, to: start, pictures: [.header: .removed]) }
        } _: {
            _ = try? await own.change(from: start, to: start, pictures: [.picture: .removed, .header: .removed])
        }
        #expect(try await own.read() == start, "left changed on the server")
    }

    @Test("Somebody dismissed from what is suggested is not suggested on the next read nor the one after, and is still suggested to another reader; without the profile part the dismissal is the part's lock and dismisses nobody")
    func aSuggestionDismissed() async throws {
        try await LocalServers.requireHealthy()
        let parts = try parts()
        let people = try #require(try LocalServers.seeded().people)
        let suggestions = MastodonSuggestions(door: try door(parts.token, scopes: parts.scopes))
        let suggested = Set(try await suggestions.stretch(source: Self.source).people.map(\.accountID))
        // The seed lets each run dismiss one of the five it suggests to everybody.
        let fan = try #require(people.fans.first { suggested.contains($0.id) }, "every one already dismissed: run `make servers` again")

        let lacking = MastodonSuggestions(door: try door(parts.lacking, scopes: parts.lackingScopes))
        await #expect(throws: AccountPartError.locked) { try await lacking.dismiss(accountID: fan.id) }
        #expect(try await suggestions.stretch(source: Self.source).people.contains { $0.accountID == fan.id })

        try await suggestions.dismiss(accountID: fan.id)
        for read in ["the next read", "the one after"] {
            let left = Set(try await suggestions.stretch(source: Self.source).people.map(\.accountID))
            #expect(!left.contains(fan.id), "\(read)")
            #expect(left == suggested.subtracting([fan.id]), "\(read): nobody else is gone")
        }
        let theirs = try #require(try LocalServers.seeded().notices).reading
        let another = MastodonSuggestions(door: try door(theirs.token, scopes: theirs.scopes))
        #expect(try await another.stretch(source: Self.source).people.contains { $0.accountID == fan.id })
    }

    @Test("Somebody followed is featured and taken off as the server answers, each said again the same; who the reader features is them — to the reader and to anybody unsigned — and then nobody; somebody not followed is the server's refusal in its own words; and without the profile part it is the part's lock")
    func aPersonFeatured() async throws {
        try await LocalServers.requireHealthy()
        let parts = try parts()
        let door = try door(parts.token, scopes: parts.scopes)
        let featuring = MastodonFeaturing(door: door), stands = MastodonStanding(door: door), people = MastodonPeople(door: door)
        let anybody = MastodonFeatured(http: try LocalHTTP.client(), host: Self.host)
        func featured() async throws -> [[String]] {
            [try await people.stretch(.featuredByReader, source: Self.source).people.map(\.accountID),
             try await anybody.featuredPeople(of: parts.id, source: Self.source).people.map(\.accountID)]
        }
        let followed = parts.followed.id
        #expect(try await stands.standing(to: followed)?.featured == false, "as the seed left it")
        #expect(try await featured() == [[], []])

        try await undoing {
            let refused = await #expect(throws: AccountPartError.self) { _ = try await featuring.feature(accountID: parts.stranger.id) }
            guard case let .refused(sentence) = refused else {
                Issue.record("not a refusal: \(String(describing: refused))")
                return
            }
            #expect(!sentence.isEmpty, "in the server's own words")
            let lacking = MastodonFeaturing(door: try self.door(parts.lacking, scopes: parts.lackingScopes))
            await #expect(throws: AccountPartError.locked) { _ = try await lacking.feature(accountID: followed) }
            #expect(try await featured() == [[], []], "nobody was featured by either")

            let on = try await featuring.feature(accountID: followed)
            #expect(on.accountID == followed && on.following && on.featured == true)
            #expect(try await featuring.feature(accountID: followed) == on, "said again, the same")
            #expect(try await stands.standing(to: followed)?.featured == true, "read back")
            #expect(try await featured() == [[followed], [followed]])

            let off = try await featuring.unfeature(accountID: followed)
            #expect(off.following && off.featured == false)
            #expect(try await featuring.unfeature(accountID: followed) == off, "said again, the same")
            #expect(try await stands.standing(to: followed)?.featured == false, "read back")
            #expect(try await featured() == [[], []])
        } _: {
            _ = try? await featuring.unfeature(accountID: followed)
        }
    }

    @Test("A hashtag is featured and taken off as the server answers: the featuring it hands back is the one listed — to the reader and to anybody unsigned — and featured again is that one; the hashtag says it is featured, then not; the same name in another case is the server's refusal; one taken off twice asks nothing more; without the profile part it is the part's lock")
    func aHashtagFeatured() async throws {
        try await LocalServers.requireHealthy()
        let parts = try parts()
        let door = try door(parts.token, scopes: parts.scopes)
        let featuring = MastodonFeaturing(door: door), follows = MastodonTagFollows(door: door)
        let anybody = MastodonFeatured(http: try LocalHTTP.client(), host: Self.host)
        let tag = try #require(PostTag("#partsq7")), other = try #require(PostTag("#PartsQ7"))
        #expect(try await featuring.ownFeaturedTags().isEmpty, "as the seed left it")
        #expect(try await follows.standing(of: tag) == TagStanding(following: false, featuring: false))

        try await undoing {
            let lacking = MastodonFeaturing(door: try self.door(parts.lacking, scopes: parts.lackingScopes))
            await #expect(throws: AccountPartError.locked) { _ = try await lacking.feature(tag: tag) }
            #expect(try await featuring.ownFeaturedTags().isEmpty)

            let made = try await featuring.feature(tag: tag)
            #expect(made.id != nil && made.name == "partsq7" && made.count == 0 && made.last == nil)
            #expect(try await featuring.feature(tag: tag) == made, "featured again, the same featuring")
            #expect(try await featuring.ownFeaturedTags() == [made], "read back")
            #expect(try await anybody.featuredTags(of: parts.id, source: Self.source) == [made], "and seen so by anybody")
            #expect(try await follows.standing(of: tag).featuring == true)

            let refused = await #expect(throws: AccountPartError.self) { _ = try await featuring.feature(tag: other) }
            guard case let .refused(sentence) = refused else {
                Issue.record("not a refusal: \(String(describing: refused))")
                return
            }
            #expect(!sentence.isEmpty, "in the server's own words")
            #expect(try await featuring.ownFeaturedTags() == [made], "nothing more was featured")

            try await featuring.unfeature(tag: other)
            #expect(try await featuring.ownFeaturedTags().isEmpty, "taken off by the featuring of the same hashtag, however written")
            #expect(try await follows.standing(of: tag).featuring == false)
            #expect(try await anybody.featuredTags(of: parts.id, source: Self.source).isEmpty)
            try await featuring.unfeature(tag: tag)
            await #expect(throws: MastodonAuthError.http(404)) { try await featuring.unfeature(made) }
        } _: {
            _ = try? await featuring.unfeature(tag: tag)
        }
    }

    @Test("Announcements are read with this app's reading words and with any sign-in at all; dismissed, one is still listed, read, to the reader and unread to another; a reaction is put on and taken back as the server answers, read back each time — put on twice the server's refusal, taken back twice done; without its part each act is that part's lock")
    func announcementsReadDismissedAndReacted() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let parts = try parts(), notices = try #require(seeded.notices), people = try #require(seeded.people)
        let announcements = MastodonAnnouncements(door: try door(parts.token, scopes: parts.scopes))
        func one(_ id: String, _ reader: MastodonAnnouncements = announcements) async throws -> Announcement {
            try #require(try await reader.read().first { $0.id == id })
        }

        // This app's reading words, and reading posts alone: neither is refused.
        let reading = MastodonAnnouncements(door: try door(notices.reading.token, scopes: notices.reading.scopes))
        let narrow = MastodonAnnouncements(door: try door(try #require(people.narrow).token, scopes: "read:statuses"))
        for (name, reader) in [("reading", reading), ("posts alone", narrow)] {
            let read = try await reader.read()
            #expect(Set(read.map(\.id)).isSuperset(of: [parts.dismiss, parts.react]), "\(name)")
            #expect(read.first { $0.id == parts.react }?.words == "fediqo321seed react", "\(name)")
        }
        let start = try await one(parts.react)
        #expect(start.read == false && start.reactions == [.init(name: "👍", count: 1, me: false)], "as the seed left it")

        // Dismissed: never taken back but by the seed, so held on a run after the first too.
        let lacking = MastodonAnnouncements(door: try door(parts.lacking, scopes: parts.lackingScopes))
        await #expect(throws: AnnouncementError.locked(.account)) { try await lacking.dismiss(parts.dismiss) }
        try await announcements.dismiss(parts.dismiss)
        #expect(try await one(parts.dismiss).read == true, "still listed, read")
        try await announcements.dismiss(parts.dismiss)
        #expect(try await one(parts.dismiss, reading).read == false, "another reader's is their own")
        await #expect(throws: AnnouncementError.gone) { try await announcements.dismiss("999999") }

        let mark = "fediqo_mark"
        try await undoing {
            await #expect(throws: AnnouncementError.locked(.acting)) { try await narrow.react(parts.react, with: "👍") }
            try await announcements.react(parts.react, with: "👍")
            try await announcements.react(parts.react, with: mark)
            let on = try await one(parts.react)
            #expect(on.reactions.first == .init(name: "👍", count: 2, me: true), "read back")
            let custom = try #require(on.reactions.first { $0.name == mark })
            #expect(custom.count == 1 && custom.me == true && custom.picture?.url.host() == Self.host)
            await #expect(throws: AnnouncementError.refused(sentence: "Duplicate record")) { try await announcements.react(parts.react, with: "👍") }
            let unknown = await #expect(throws: AnnouncementError.self) { try await announcements.react(parts.react, with: "nosuchemoji") }
            guard case let .refused(sentence) = unknown else {
                Issue.record("not a refusal: \(String(describing: unknown))")
                return
            }
            #expect(!sentence.isEmpty)
            await #expect(throws: AnnouncementError.gone) { try await announcements.react("999999", with: "👍") }

            try await announcements.unreact(parts.react, with: "👍")
            try await announcements.unreact(parts.react, with: "👍")
            try await announcements.unreact(parts.react, with: mark)
            #expect(try await one(parts.react).reactions == start.reactions, "read back taken back")
        } _: {
            _ = try? await announcements.unreact(parts.react, with: "👍")
            _ = try? await announcements.unreact(parts.react, with: mark)
        }
        #expect(try await one(parts.react) == start, "left changed on the server")
    }
}
