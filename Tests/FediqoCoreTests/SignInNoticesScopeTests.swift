import Foundation
import Security
import Testing
@testable import FediqoCore

/// What a sign-in asks for so notices can be read (#323), and what an earlier sign-in is read as.
///
/// The words asked for and their order, the ladder and the registrations a sign-in may start on,
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
        #expect(MastodonOAuth.dismissing == "write:notifications")

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
        #expect(MastodonOAuth.scopes(reading: Self.readingWithoutSearch, writing: false, notices: true)
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

    @Test("Asking for notices adds no rung: each rung carries the notices words after its own, and without them the ladder is as it was")
    func theLadder() {
        let acting = "\(Self.reading) \(Self.writing)"
        let actingWithoutSearch = "\(Self.readingWithoutSearch) \(Self.writing)"
        #expect(MastodonOAuth.ladder(writing: false, notices: false) == [Self.reading, Self.readingWithoutSearch])
        #expect(MastodonOAuth.ladder(writing: true, notices: false) == [
            acting + " write:bookmarks", actingWithoutSearch + " write:bookmarks", acting, actingWithoutSearch,
        ])
        #expect(MastodonOAuth.ladder(writing: false) == MastodonOAuth.ladder(writing: false, notices: false))
        #expect(MastodonOAuth.ladder(writing: true) == MastodonOAuth.ladder(writing: true, notices: false))

        #expect(MastodonOAuth.ladder(writing: false, notices: true) == [
            Self.reading + " read:notifications", Self.readingWithoutSearch + " read:notifications",
        ])
        let both = " read:notifications write:notifications"
        #expect(MastodonOAuth.ladder(writing: true, notices: true) == [
            acting + " write:bookmarks" + both, actingWithoutSearch + " write:bookmarks" + both,
            acting + both, actingWithoutSearch + both,
        ])
        for wanted in [false, true] {
            let with = MastodonOAuth.ladder(writing: wanted, notices: true)
            #expect(with.count == MastodonOAuth.ladder(writing: wanted).count, "a rung was added")
            #expect(with.allSatisfy(MastodonOAuth.notices), "a rung fell to a sign-in without notices")
            #expect(with.allSatisfy { MastodonOAuth.writes($0) == wanted })
        }
    }

    @Test("A sign-in that asks for notices starts on no registration that cannot ask for them, and one that does not starts on none made for them")
    func noRegistrationIsReusedAcrossTheChoice() {
        for wanted in [false, true] {
            let with = MastodonOAuth.known(writing: wanted, notices: true)
            let without = MastodonOAuth.known(writing: wanted, notices: false)
            #expect(without == MastodonOAuth.known(writing: wanted), "the set a sign-in had before this moved")
            #expect(with.count == 2 && without.count == 2)
            #expect(with.allSatisfy(MastodonOAuth.notices), "a registration that cannot ask for notices is reused")
            #expect(!without.contains(where: MastodonOAuth.notices), "a registration made for notices is started on unasked")
            #expect(with.isDisjoint(with: without))
            // Nor one made for the other answer about writing, as before.
            #expect(with.isDisjoint(with: MastodonOAuth.known(writing: !wanted, notices: true)))
            #expect(with.isDisjoint(with: MastodonOAuth.known(writing: !wanted, notices: false)))
            // Read off the ladder by the rule it had: the rungs that leave bookmarks out are not started on.
            #expect(with.isSubset(of: Set(MastodonOAuth.ladder(writing: wanted, notices: true))))
            #expect(with.allSatisfy { MastodonOAuth.bookmarks($0) == wanted })
        }
        // Every registration an earlier build made, and one nothing is written down for.
        let earlier = [
            Self.reading, Self.readingWithoutSearch, "\(Self.reading) \(Self.writing)",
            "\(Self.reading) \(Self.writing) write:bookmarks", "",
        ]
        for wanted in [false, true] {
            for scopes in earlier {
                #expect(!MastodonOAuth.known(writing: wanted, notices: true).contains(scopes), "\(scopes)")
            }
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
