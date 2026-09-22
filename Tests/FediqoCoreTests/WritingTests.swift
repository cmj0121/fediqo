import Foundation
import Testing
@testable import FediqoCore

/// What a sign-in asks for, what it bought, and what a source says may be done on it (#69).
@Suite("What may be done on a source")
struct WritingTests {
    // MARK: - What a sign-in asks for

    /// **The read-only answer is byte-for-byte what this app asked for before it could write.**
    /// That is the whole of "refusing the writing part leaves reading exactly as it was": not a
    /// promise in a comment but the same string, pinned as a literal here so that widening the
    /// reading pair to sneak a `write:` in fails this test rather than a reader's expectations.
    @Test("Refusing the writing part asks for exactly the scopes reading always asked for")
    func readingIsUnchanged() {
        #expect(MastodonOAuth.reading == "read:statuses read:lists read:accounts read:search")
        #expect(MastodonOAuth.scopes(writing: false) == MastodonOAuth.reading)
        #expect(MastodonOAuth.scopes(reading: MastodonOAuth.readingWithoutSearch, writing: false)
            == MastodonOAuth.readingWithoutSearch)
        #expect(!MastodonOAuth.scopes(writing: false).contains("write"))
    }

    /// **What writing needs and no more.** Following, the profile and the filters are all `write:`
    /// scopes this app does not ask for, and the README says so — a scope added here without an act
    /// to need it is exactly the quiet widening #69 exists to refuse.
    @Test("The writing part is what posting, boosting, replying and favouriting need, and nothing else")
    func writingIsNarrow() {
        #expect(MastodonOAuth.writing == "write:statuses write:favourites")
        #expect(MastodonOAuth.scopes(writing: true)
            == "read:statuses read:lists read:accounts read:search write:statuses write:favourites")
        for wider in ["write", "write:follows", "write:accounts", "write:filters", "admin"] {
            #expect(!MastodonOAuth.writing.split(separator: " ").contains(Substring(wider)),
                    "\(wider) is asked for and nothing in this app uses it")
        }
    }

    /// Order-independent and never a substring match: a server is free to hand the scopes back in
    /// its own order, and a scope that merely contains one of these words is not one of them.
    @Test("Whether a scope string bought writing is read scope by scope")
    func readsTheGrant() {
        #expect(!MastodonOAuth.writes(nil))
        #expect(!MastodonOAuth.writes(""))
        #expect(!MastodonOAuth.writes(MastodonOAuth.reading))
        #expect(MastodonOAuth.writes(MastodonOAuth.scopes(writing: true)))
        #expect(MastodonOAuth.writes("write:favourites read:statuses write:statuses"))
        // Half of it is not it: a server that granted one of the two cannot take a post back.
        #expect(!MastodonOAuth.writes("read:statuses write:statuses"))
        #expect(!MastodonOAuth.writes("read:statuses write:statuses-ish"))
    }

    /// **One registration per answer, two rungs inside it.** A registration made for reading alone
    /// cannot carry a page that asks to write, so the two answers' sets must not overlap — and
    /// decision 32's narrower rung must stay reusable inside each.
    @Test("The registrations a sign-in may reuse are the two rungs of its own answer")
    func knownRegistrations() {
        let reads = MastodonOAuth.known(writing: false)
        let writes = MastodonOAuth.known(writing: true)
        // The set is the ladder `signIn` climbs, so the two must name the same two strings.
        for wanted in [true, false] {
            let ladder = MastodonOAuth.registrations(writing: wanted)
            #expect(MastodonOAuth.known(writing: wanted) == [ladder.wide, ladder.narrow])
            #expect(ladder.wide.contains("read:search"))
            #expect(!ladder.narrow.contains("read:search"))
            #expect(MastodonOAuth.writes(ladder.wide) == wanted)
            #expect(MastodonOAuth.writes(ladder.narrow) == wanted)
        }
        #expect(reads == [MastodonOAuth.reading, MastodonOAuth.readingWithoutSearch])
        #expect(writes.count == 2)
        #expect(reads.isDisjoint(with: writes), """
            A registration made for one answer is reusable for the other, so a reader changing \
            their mind would meet invalid_scope on a page this app asked for.
            """)
        #expect(writes.allSatisfy(MastodonOAuth.writes))
        #expect(!reads.contains(where: MastodonOAuth.writes))
    }

    // MARK: - What a sign-in bought

    /// **Nothing written down and reading written down are two different answers**, and the whole
    /// of "a person signed in before this is asked again" rests on telling them apart.
    @Test("A token with no scopes has never been asked; one with the reading scopes has")
    func grants() {
        #expect(MastodonGrant.of(scopes: nil) == .unasked)
        #expect(MastodonGrant.of(scopes: MastodonOAuth.reading) == .reading)
        #expect(MastodonGrant.of(scopes: MastodonOAuth.readingWithoutSearch) == .reading)
        #expect(MastodonGrant.of(scopes: MastodonOAuth.scopes(writing: true)) == .writing)
        #expect(MastodonGrant.of(scopes: "") == .reading, "asked, and granted nothing to write with")
    }

    @Test("A token carries what its sign-in asked for, through the Keychain and back")
    func tokenRemembers() throws {
        let asked = MastodonOAuth.scopes(writing: true)
        let token = MastodonFixture.token(scopes: asked)
        #expect(token.grant == .writing)
        let read = try #require(MastodonKeychain.Wire.decode(
            MastodonKeychain.Wire.encode(token), host: MastodonFixture.host
        ))
        #expect(read == token)
        #expect(read.scopes == asked)
        #expect(read.grant == .writing)
    }

    /// The item an earlier build wrote: no `scopes` key at all. It must still read, and it must
    /// read as *never asked* rather than as a refusal — a token that decoded to `nil` would sign
    /// the reader out, and one that decoded to `reading` would answer the question for them.
    @Test("A token kept before this build reads back, and reads as never asked")
    func legacyToken() throws {
        let legacy = Data(#"{"accessToken":"tok","clientID":"cid","clientSecret":"sec"}"#.utf8)
        let token = try #require(
            MastodonKeychain.Wire.decode(legacy, host: MastodonFixture.host)
        )
        #expect(token.accessToken == "tok")
        #expect(token.scopes == nil)
        #expect(token.grant == .unasked)
    }

    /// **The scopes ride as an item attribute, and that is what keeps the source page free of a
    /// Keychain access prompt per row.** Reading a generic password's *data* is what asks the
    /// reader to allow access; reading its attributes does not. So this is pinned from both sides:
    /// the attribute is written, and it is what `grant(_:)` reads back.
    @Test("A token's scopes ride as an attribute, beside the secret and never in it")
    func scopesRideAsAnAttribute() throws {
        let generic = kSecAttrGeneric as String
        let asked = MastodonOAuth.scopes(writing: true)
        let attributes = MastodonKeychain.attributes(for: MastodonFixture.token(scopes: asked))
        #expect(attributes[generic] as? Data == Data(asked.utf8))
        #expect(MastodonKeychain.grant(attributes) == .writing)
        // And the protections the secret has are the ones it had: this changes what is *beside*
        // the value and nothing about where it lives or who it follows.
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        // A token kept before the question carries no attribute at all, which is how an item
        // written by an earlier build reads as never asked rather than as a refusal.
        let older = MastodonKeychain.attributes(for: MastodonFixture.token(scopes: nil))
        #expect(older[generic] == nil)
        #expect(MastodonKeychain.grant(older) == .unasked)
        #expect(MastodonKeychain.grant([:]) == .unasked)

        // The listing query still asks for attributes and never for data — the whole mechanism
        // rests on that staying true.
        #expect(MastodonKeychain.allItems()[kSecReturnData as String] == nil)
        #expect(MastodonKeychain.allItems()[kSecReturnAttributes as String] as? Bool == true)
    }

    // MARK: - What may be done on a source

    /// **Every protocol answers, and the map is stated rather than derived**, so a protocol added
    /// without a decision about writing fails here instead of inheriting somebody else's.
    @Test("Which protocols this app can write to at all")
    func canWrite() {
        let expected: [ProtocolKind: Bool] = [
            .mastodon: true,
            .pleroma: false, .akkoma: false, .misskey: false, .pixelfed: false, .lemmy: false,
            .peertube: false, .friendica: false, .gotosocial: false, .discourse: false,
            .discuz: false, .unknown: false,
        ]
        #expect(Set(expected.keys) == Set(ProtocolKind.allCases), """
            A protocol was added and this map was not asked about it.
            """)
        for kind in ProtocolKind.allCases {
            #expect(kind.canWrite == expected[kind], "\(kind)")
        }
    }

    /// **A Discuz! signs in and still cannot be written to**, which is the arm of #69 that is
    /// about the protocol and not about anything a reader chose: its sign-in is a cookie that
    /// lets this device *read* a board, and nothing here can post to a forum.
    @Test("A forum reads only however it is signed in to")
    func forumsNeverWrite() {
        for kind in [ProtocolKind.discuz, .discourse] {
            for grant in MastodonGrant.allCases {
                #expect(SourceWriting.of(kind: kind, grant: grant, refused: false) == .never)
            }
            #expect(SourceWriting.of(kind: kind, grant: nil, refused: true) == .never)
        }
    }

    @Test("What a Mastodon row says, from what its sign-in bought and what it has refused since")
    func mastodonStates() {
        func writing(_ grant: MastodonGrant?, refused: Bool = false) -> SourceWriting {
            SourceWriting.of(kind: .mastodon, grant: grant, refused: refused)
        }
        // Not signed in: the public timeline is read, and writing was never on the table.
        #expect(writing(nil) == .reads)
        // Signed in before the question, and signed in having refused it: both read, neither
        // writes. Which of the two it is, is the Account page's question and not this one's.
        #expect(writing(.unasked) == .reads)
        #expect(writing(.reading) == .reads)
        #expect(writing(.writing) == .writes)
        // A refusal only means anything where writing was bought at all.
        #expect(writing(.writing, refused: true) == .refused)
        #expect(writing(.reading, refused: true) == .reads)
        #expect(writing(nil, refused: true) == .reads)
    }
}
