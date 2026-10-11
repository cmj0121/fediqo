import Foundation
import Security
import Testing
@testable import FediqoCore

/// What a sign-in asks for so notices can be read (#323), and what an earlier sign-in is read as.
///
/// The words asked for and their order, which registrations carry a page that asks for them,
/// and what a held token's attributes say. What `MastodonSessions` does with them is
/// `SignInNoticesTests`' in the UI suite.
@Suite("What a sign-in asks for so notices can be read")
struct SignInNoticesScopeTests {
    private let host = "social.example"
    private static let reading = "read:statuses read:lists read:accounts read:search"
    private static let readingWithoutSearch = "read:statuses read:lists read:accounts"
    private static let writing = "write:statuses write:favourites"

    private func token(scopes: String?, asked: String? = nil, host: String? = nil) -> MastodonToken {
        MastodonToken(
            host: host ?? self.host, accessToken: "t", clientID: "c", clientSecret: "s",
            scopes: scopes, asked: asked
        )
    }

    @Test("Without notices every string is what it was; with them, reading them comes last, and dismissing after it only where the sign-in acts")
    func theStringsInTheirOrder() {
        #expect(MastodonOAuth.noticing == "read:notifications")
        #expect(MastodonPart.notices.wordsBesideActing == ["write:notifications"])

        // Not asked: byte for byte what a sign-in asked before this.
        #expect(MastodonOAuth.scopes(writing: false) == Self.reading)
        #expect(MastodonOAuth.scopes(writing: false, notices: false) == Self.reading)
        #expect(MastodonOAuth.scopes(writing: true, notices: false) == "\(Self.reading) \(Self.writing) write:bookmarks")
        #expect(MastodonOAuth.scopes(writing: true, bookmarks: false, notices: false) == "\(Self.reading) \(Self.writing)")

        // Asked: reading, writing, bookmarking, noticing, dismissing.
        #expect(MastodonOAuth.scopes(writing: false, notices: true) == "\(Self.reading) read:notifications")
        #expect(MastodonOAuth.scopes(writing: true, notices: true)
            == "\(Self.reading) \(Self.writing) write:bookmarks read:notifications write:notifications")
        #expect(MastodonOAuth.scopes(writing: true, bookmarks: false, notices: true)
            == "\(Self.reading) \(Self.writing) read:notifications write:notifications")
        #expect(MastodonOAuth.scopes(search: false, writing: false, notices: true)
            == "\(Self.readingWithoutSearch) read:notifications")

        // Dismissing is an act: never asked of a sign-in that only reads.
        #expect(!MastodonOAuth.dismisses(MastodonOAuth.scopes(writing: false, notices: true)))
        let asked = Set(MastodonOAuth.scopes(writing: true, notices: true).split(separator: " "))
        for wider in ["read", "write", "push", "write:follows", "write:accounts", "admin"] {
            #expect(!asked.contains(Substring(wider)), "\(wider) is asked for and nothing in this app uses it")
        }
    }

    @Test("Neither word is inside reading or writing, so a sign-in made before this reads, writes and bookmarks as it did")
    func anEarlierSignInIsNotALesserOne() {
        #expect(MastodonOAuth.reading == Self.reading)
        #expect(MastodonOAuth.writing == Self.writing)
        let earlier: [(String?, MastodonGrant, Bool)] = [
            (nil, .unasked, false),
            (Self.reading, .reading, false),
            (Self.readingWithoutSearch, .reading, false),
            ("\(Self.reading) \(Self.writing)", .writing, false),
            ("\(Self.reading) \(Self.writing) write:bookmarks", .writing, true),
        ]
        for (scopes, grant, bookmarks) in earlier {
            let label = scopes ?? "nothing written down"
            #expect(MastodonGrant.of(scopes: scopes) == grant, "\(label)")
            #expect(MastodonOAuth.writes(scopes) == (grant == .writing), "\(label)")
            #expect(MastodonOAuth.bookmarks(scopes) == bookmarks, "\(label)")
            #expect(!MastodonOAuth.notices(scopes) && !MastodonOAuth.dismisses(scopes), "\(label)")
            #expect(!token(scopes: scopes, asked: scopes).noticesRefused, "never asked is not refused: \(label)")
        }
        // And a sign-in that asked for notices still is everything it would have been without.
        #expect(MastodonGrant.of(scopes: MastodonOAuth.scopes(writing: false, notices: true)) == .reading)
        #expect(MastodonGrant.of(scopes: MastodonOAuth.scopes(writing: true, notices: true)) == .writing)
        #expect(MastodonOAuth.bookmarks(MastodonOAuth.scopes(writing: true, notices: true)))
    }

    @Test("Notices and dismissing are read scope by scope, in any order, and never as a substring")
    func readScopeByScope() {
        #expect(MastodonOAuth.notices("read:notifications read:statuses"))
        #expect(MastodonOAuth.dismisses("write:notifications read:statuses"))
        #expect(!MastodonOAuth.notices("write:notifications read:notifications-ish"))
        #expect(!MastodonOAuth.dismisses("read:notifications write:notifications-ish"))
        #expect(!MastodonOAuth.notices(nil) && !MastodonOAuth.notices(""))
        #expect(!MastodonOAuth.dismisses(nil) && !MastodonOAuth.dismisses(""))
    }

    @Test("Asking for notices adds its words after the others and takes none away: a source with no search or bookmarks is asked for the same without them, and notices still")
    func whatIsAskedWithNotices() {
        let acting = "\(Self.reading) \(Self.writing)"
        let actingWithoutSearch = "\(Self.readingWithoutSearch) \(Self.writing)"
        let both = " read:notifications write:notifications"
        #expect(MastodonOAuth.scopes(writing: false, notices: true) == Self.reading + " read:notifications")
        #expect(MastodonOAuth.scopes(writing: true, notices: true) == acting + " write:bookmarks" + both)
        // The least each can be: what is registered for once the whole of it is refused.
        let leastReading = MastodonOAuth.scopes(search: false, writing: false, bookmarks: false, notices: true)
        let leastActing = MastodonOAuth.scopes(search: false, writing: true, bookmarks: false, notices: true)
        #expect(leastReading == Self.readingWithoutSearch + " read:notifications")
        #expect(leastActing == actingWithoutSearch + both)
        for wanted in [false, true] {
            let chosen = MastodonOAuth.scopes(writing: wanted, notices: true)
            let least = wanted ? leastActing : leastReading
            #expect(MastodonRegistration.page(chosen, on: least) == least)
            #expect(MastodonOAuth.notices(least), "the least a sign-in can be fell to one without notices")
            #expect(MastodonOAuth.writes(least) == wanted)
            #expect(MastodonRegistration.page(chosen, on: MastodonRegistration.superset()) == chosen)
        }
    }

    @Test("A registration made before notices were asked for carries no page that asks for them, and one made for everything carries a page with or without")
    func noEarlierRegistrationCarriesThem() {
        // Every registration an earlier build made, and one nothing is written down for.
        let earlier: [String?] = [
            Self.reading, Self.readingWithoutSearch, "\(Self.reading) \(Self.writing)",
            "\(Self.reading) \(Self.writing) write:bookmarks", "", nil,
        ]
        for wanted in [false, true] {
            let chosen = MastodonOAuth.scopes(writing: wanted, notices: true)
            for scopes in earlier {
                #expect(MastodonRegistration.page(chosen, on: scopes) == nil, "\(scopes ?? "nothing")")
                #expect(!MastodonRegistration.holds(chosen, on: scopes))
            }
            // Notices are never left off a page as search and bookmarks are.
            let whole = MastodonRegistration.superset()
            let unnoticed = whole.replacingOccurrences(of: " read:notifications write:notifications", with: "")
            #expect(MastodonRegistration.page(chosen, on: unnoticed) == nil)
            #expect(MastodonRegistration.page(MastodonOAuth.scopes(writing: wanted), on: whole) == MastodonOAuth.scopes(writing: wanted))
        }
    }

    @Test("What a held token may do with notices is read off its attributes, and an earlier one is in none of the three answers")
    func theAttributesSaySo() throws {
        let acting = MastodonOAuth.scopes(writing: true, notices: true)
        let reads = MastodonOAuth.scopes(writing: false, notices: true)
        let before = MastodonOAuth.scopes(writing: true)
        func row(_ scopes: String?, asked: String? = nil) -> [String: Any] {
            MastodonKeychain.attributes(for: token(scopes: scopes, asked: asked))
        }
        #expect(MastodonKeychain.notices(row(acting)) && MastodonKeychain.dismisses(row(acting)))
        #expect(MastodonKeychain.notices(row(reads)) && !MastodonKeychain.dismisses(row(reads)))
        for scopes in [nil, MastodonOAuth.reading, before] as [String?] {
            let earlier = row(scopes, asked: scopes)
            #expect(!MastodonKeychain.notices(earlier) && !MastodonKeychain.dismisses(earlier))
            #expect(!MastodonKeychain.noticesRefused(earlier), "never asked is not refused")
            #expect(MastodonKeychain.grant(earlier) == MastodonGrant.of(scopes: scopes))
            #expect(MastodonKeychain.bookmarks(earlier) == MastodonOAuth.bookmarks(scopes))
        }
        // Asked and not given: told apart from never asked by what the sign-in wrote down.
        let refused = token(scopes: before, asked: acting)
        #expect(refused.noticesRefused && !refused.bookmarksRefused)
        #expect(MastodonKeychain.noticesRefused(MastodonKeychain.attributes(for: refused)))
        #expect(!token(scopes: acting, asked: acting).noticesRefused)
        #expect(MastodonKeychain.Wire.decode(MastodonKeychain.Wire.encode(refused), host: host) == refused)

        let tokens = MemoryMastodonTokens()
        try tokens.save(token(scopes: nil, host: "oldest.example"))
        try tokens.save(token(scopes: before, asked: before, host: "old.example"))
        try tokens.save(token(scopes: reads, asked: reads, host: "reads.example"))
        try tokens.save(token(scopes: acting, asked: acting, host: "acts.example"))
        try tokens.save(token(scopes: before, asked: acting, host: "refused.example"))
        #expect(try tokens.noticing() == ["reads.example", "acts.example"])
        #expect(try tokens.dismissing() == ["acts.example"])
        #expect(try tokens.noticesRefused() == ["refused.example"])
        #expect(try tokens.grants() == [
            "oldest.example": .unasked, "old.example": .writing, "reads.example": .reading,
            "acts.example": .writing, "refused.example": .writing,
        ])
        #expect(try tokens.bookmarking() == ["old.example", "acts.example", "refused.example"])
        #expect(try tokens.bookmarksRefused().isEmpty)
    }

    @Test("A store that does not say names no host for notices, so nothing is read through a sign-in nobody can show bought it")
    func aStoreThatDoesNotSay() throws {
        let silent = SilentTokens()
        #expect(try silent.noticing().isEmpty && silent.dismissing().isEmpty && silent.noticesRefused().isEmpty)
    }
}

/// A token store written before notices were asked for: it answers only what the protocol requires.
private struct SilentTokens: MastodonTokenStore {
    func token(host: String) throws -> MastodonToken? { nil }
    func save(_ token: MastodonToken) throws {}
    func forget(host: String) throws {}
    func forget(_ token: MastodonToken) throws -> Bool { false }
    func grants() throws -> [String: MastodonGrant] { ["social.example": .writing] }
    func app(host: String) throws -> MastodonApp? { nil }
    func save(_ app: MastodonApp) throws {}
    func forgetApp(host: String) throws {}
}
