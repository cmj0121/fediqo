import Foundation
import Security
import Testing
@testable import FediqoCore

/// #347: what is kept beside a Mastodon sign-in, and the writes that keep it — the note made
/// in place, and the fresh sign-in kept only while the one it replaces is still the one held.
///
/// Run over the memory store, whose writes are the real store's own (`TokenFiling`) over a
/// dictionary. What the Keychain itself does with the dictionaries built here is not seen by
/// any test: `swift test` may not touch it.
@Suite("Where a Mastodon sign-in is kept")
struct MastodonTokenStoreTests {
    private static let host = "social.example"
    private static let reading = MastodonOAuth.scopes(writing: false)
    private static let acting = MastodonOAuth.scopes(writing: true)

    private static func token(_ string: String, scopes: String? = reading, asked: String? = reading) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: string, clientID: "client", clientSecret: "client-secret",
            scopes: scopes, asked: asked
        )
    }

    private func held(_ store: MemoryMastodonTokens) throws -> MastodonToken? {
        try store.token(host: Self.host)
    }

    // MARK: - The stamp

    @Test("A stamp is made when a token string is first filed, is carried through every later write of that string, and is another for another string")
    func aStampIsMadeAtFirstFilingAndCarried() throws {
        let store = MemoryMastodonTokens()
        let first = Self.token("first")
        #expect(first.stamp == nil, "only a store stamps")

        try store.save(first)
        let stamp = try #require(try held(store)?.stamp)
        #expect(stamp.count >= 22, "sixteen random bytes")

        // The same string again, by each way it is written.
        try store.save(Self.token("first", scopes: Self.acting))
        #expect(try held(store)?.stamp == stamp)
        #expect(try store.update(first.recorded(refused: "write:bookmarks")))
        #expect(try held(store)?.stamp == stamp)
        #expect(try store.swap(expecting: "first", with: Self.token("first")))
        #expect(try held(store)?.stamp == stamp)
        let withName = try #require(try held(store)).named(accountID: "7", handle: "@me@social.example")
        try store.save(withName)
        #expect(try held(store)?.stamp == stamp)

        // Another string: another stamp, by either way it is kept.
        try store.save(Self.token("second"))
        let second = try #require(try held(store)?.stamp)
        #expect(second != stamp)
        #expect(try store.swap(expecting: "second", with: Self.token("third")))
        let third = try #require(try held(store)?.stamp)
        #expect(third != second)
    }

    @Test("A token put back after the one that replaced it is let go comes back with the stamp it had")
    func aTokenPutBackKeepsItsStamp() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("old"))
        let old = try #require(try held(store))
        try store.save(Self.token("new"))
        try store.forget(host: Self.host)
        try store.save(old)
        #expect(try held(store)?.stamp == old.stamp)
    }

    @Test("Two tokens are the same sign-in whatever stamp each was filed under, and are not where one was refused something the other was not")
    func theStampIsNoPartOfWhatASignInIs() {
        let token = Self.token("tok")
        #expect(token.stamped("one") == token.stamped("two"))
        #expect(token.stamped("one") == token)
        #expect(token.recorded(refused: "write:bookmarks") != token)
        #expect(token.recorded(refused: "write:bookmarks").stamped("one").recorded(asked: nil).stamp == "one")
    }

    @Test("No two stamps are the same, and none is made from a clock or a count")
    func theStampIsRandom() throws {
        let stamps = (0 ..< 200).map { _ in TokenFiling.stamp() }
        #expect(Set(stamps).count == stamps.count)
        let source = try Self.source()
        let minted = try #require(source.components(separatedBy: "static func stamp() -> String {").dropFirst().first)
        #expect(minted.components(separatedBy: "\n    }\n").first?.contains("PKCE.random(bytes: 16)") == true)
        for clock in ["Date(", "Date.now", "ContinuousClock", "DispatchTime", "CFAbsoluteTime", "UUID("] {
            #expect(!source.contains(clock), "\(clock) in the token store")
        }
    }

    // MARK: - What is held, by the one look

    @Test("What a sign-in is known to hold is read from the value where something is decided, and off the copies beside it for drawing — and the two say the same")
    func whatIsHeldByTheValueAndByTheRow() throws {
        let store = MemoryMastodonTokens()
        let refused = Self.token("tok", scopes: Self.reading, asked: Self.acting).recorded(refused: "write:statuses write:favourites")
        try store.save(refused)
        let filed = try #require(try held(store))
        let stamp = try #require(filed.stamp)

        let byValue = try #require(try store.parts(host: Self.host))
        #expect(byValue == MastodonHeld(scopes: Self.reading, asked: Self.acting, refused: "write:statuses write:favourites", stamp: stamp))
        #expect(try store.parts() == [Self.host: byValue])
        #expect(try store.parts(host: "elsewhere.example") == nil)

        // The real store's row: what rides beside the value, read back.
        let row = MastodonKeychain.attributes(for: filed)
        #expect(MastodonKeychain.held(row) == byValue)
        #expect(row[kSecAttrDescription as String] as? String == "\(stamp) write:statuses write:favourites")
        let plain = MastodonKeychain.attributes(for: filed.recorded(refused: nil))
        #expect(plain[kSecAttrDescription as String] as? String == stamp)
        #expect(MastodonKeychain.held(plain) == MastodonHeld(scopes: Self.reading, asked: Self.acting, stamp: stamp))
        // Never filed: no stamp to lead with, and the refusal still reads.
        let unfiled = MastodonKeychain.attributes(for: refused)
        #expect(MastodonKeychain.held(unfiled) == MastodonHeld(scopes: Self.reading, asked: Self.acting, refused: "write:statuses write:favourites"))
    }

    @Test("A row written before a refusal or a stamp was kept reads as it did: nothing refused, no stamp, and every look what it was")
    func anOlderRowReadsAsItDid() {
        let older: [String: Any] = [
            kSecAttrGeneric as String: Data(Self.reading.utf8), kSecAttrComment as String: Self.acting,
        ]
        #expect(MastodonKeychain.held(older) == MastodonHeld(scopes: Self.reading, asked: Self.acting))
        #expect(MastodonKeychain.bookmarksRefused(older))
        #expect(MastodonKeychain.grant(older) == .reading)
        #expect(MastodonKeychain.held([:]) == MastodonHeld(scopes: nil, asked: nil))
        #expect(MastodonKeychain.grant([:]) == .unasked)
        let neverFiled = MastodonKeychain.attributes(for: Self.token("tok", scopes: nil, asked: nil))
        #expect(neverFiled[kSecAttrDescription as String] == nil)
        #expect(neverFiled[kSecAttrGeneric as String] == nil)
    }

    @Test("Who may bookmark, who may read or dismiss notices, and who was refused either are readings of the one look")
    func everyLookIsAReadingOfTheOne() throws {
        let store = MemoryMastodonTokens()
        let everything = MastodonOAuth.scopes(writing: true, notices: true)
        let rows: [(String, scopes: String?, asked: String?)] = [
            ("unasked.example", nil, nil),
            ("reads.example", Self.reading, Self.reading),
            ("acts.example", Self.acting, Self.acting),
            ("bare.example", MastodonOAuth.scopes(writing: true, bookmarks: false), Self.acting),
            ("all.example", everything, everything),
            ("sees.example", MastodonOAuth.scopes(writing: false, notices: true), everything),
            ("refused.example", Self.reading, everything),
        ]
        for row in rows {
            try store.save(MastodonToken(host: row.0, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: row.scopes, asked: row.asked))
        }
        let parts = try store.parts()
        #expect(Set(parts.keys) == Set(rows.map(\.0)))
        #expect(try store.grants() == parts.mapValues(\.grant))
        #expect(try store.bookmarking() == ["acts.example", "all.example"])
        #expect(try store.bookmarksRefused() == ["bare.example", "sees.example", "refused.example"])
        #expect(try store.noticing() == ["all.example", "sees.example"])
        #expect(try store.dismissing() == ["all.example"])
        #expect(try store.noticesRefused() == ["refused.example"])
        let notices = store.noticeGrants()
        #expect(notices == MastodonNoticeGrants(noticing: ["all.example", "sees.example"], dismissing: ["all.example"], refused: ["refused.example"]))
    }

    // MARK: - The note made in place

    @Test("An update writes beside the held sign-in in place, without the delete-then-add a save is, leaves what it does not name as held, and keeps the stamp")
    func anUpdateWritesInPlace() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("tok").named(accountID: "7", handle: "@me@social.example"))
        let before = try #require(try held(store))

        // An add would be refused: an update makes none.
        store.refuse(.adding)
        let noted = Self.token("tok", scopes: nil, asked: Self.acting).recorded(refused: "write:bookmarks")
        #expect(try store.update(noted))

        let after = try #require(try held(store))
        #expect(after.asked == Self.acting)
        #expect(after.refused == "write:bookmarks")
        #expect(after.scopes == Self.reading, "what the note leaves out stays as held")
        #expect(after.accountID == "7")
        #expect(after.handle == "@me@social.example")
        #expect(after.stamp == before.stamp)
        #expect(try store.parts(host: Self.host)?.refused == "write:bookmarks")
    }

    @Test("An update is written only while the token string held is the one it is a note on: over another string, or with nothing held, nothing is written")
    func anUpdateIsConditionedOnTheHeldString() throws {
        let store = MemoryMastodonTokens()
        let stale = Self.token("old").recorded(refused: "write:bookmarks")
        #expect(try !store.update(stale), "nothing held")
        #expect(try held(store) == nil)

        try store.save(Self.token("new"))
        let before = try #require(try held(store))
        #expect(try !store.update(stale), "another string held")
        let after = try #require(try held(store))
        #expect(after == before)
        #expect(after.stamp == before.stamp)
        #expect(after.refused == nil)
    }

    @Test("An update the Keychain refuses, after a refusal on the source's page, throws and leaves the sign-in held exactly as it was — the refusal reads as never asked, and the next update lands")
    func anUpdateThatFailsLeavesTheSignInHeld() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("tok"))
        let before = try #require(try held(store))
        let refusal = before.recorded(asked: Self.acting).recorded(refused: "write:statuses write:favourites")

        store.refuse(.changing)
        #expect(throws: ForumCredentialError.keychain(errSecInteractionNotAllowed)) { try store.update(refusal) }
        let after = try #require(try held(store))
        #expect(after == before)
        #expect(after.stamp == before.stamp)
        #expect(after.refused == nil)
        #expect(after.asked == Self.reading)
        #expect(try store.signedInHosts() == [Self.host])

        #expect(try store.update(refusal))
        #expect(try held(store)?.refused == "write:statuses write:favourites")
    }

    // MARK: - The swap

    @Test("A fresh sign-in is kept only while the token string held is still the one the ask began with: replaced meanwhile, signed out meanwhile, or signed in meanwhile where there was none, it is not kept and nothing is written")
    func aSwapKeepsOnlyOverTheStringExpected() throws {
        let fresh = Self.token("fresh", scopes: Self.acting, asked: Self.acting)

        // Replaced meanwhile — a sign-in elsewhere in the app, or a package read back.
        let replaced = MemoryMastodonTokens()
        try replaced.save(Self.token("held"))
        try replaced.save(Self.token("other"))
        let other = try #require(try held(replaced))
        #expect(try !replaced.swap(expecting: "held", with: fresh))
        #expect(try held(replaced) == other)
        #expect(try held(replaced)?.stamp == other.stamp)

        // Signed out meanwhile.
        let signedOut = MemoryMastodonTokens()
        try signedOut.save(Self.token("held"))
        try signedOut.forget(host: Self.host)
        #expect(try !signedOut.swap(expecting: "held", with: fresh))
        #expect(try held(signedOut) == nil)

        // Signed in meanwhile, where the ask began with none.
        let signedIn = MemoryMastodonTokens()
        try signedIn.save(Self.token("other"))
        #expect(try !signedIn.swap(expecting: nil, with: fresh))
        #expect(try held(signedIn)?.accessToken == "other")

        // Still the one: kept. And still none: kept.
        let still = MemoryMastodonTokens()
        try still.save(Self.token("held"))
        #expect(try still.swap(expecting: "held", with: fresh))
        #expect(try held(still) == fresh)
        let none = MemoryMastodonTokens()
        #expect(try none.swap(expecting: nil, with: fresh))
        #expect(try held(none) == fresh)
    }

    /// A write another thread makes while a swap is between its read and its write.
    enum Other: String, CaseIterable, Sendable {
        case save, forgetHost, forgetToken, update, swap
    }

    @Test("A write from another thread while a swap is between its read and its write waits for the swap, and sees the swap's string and not the one before it", arguments: Other.allCases)
    func aWriteFromAnotherThreadWaitsForTheSwap(_ other: Other) throws {
        let lock = WatchedLock()
        let store = MemoryMastodonTokens(writing: lock)
        let old = Self.token("old")
        try store.save(old)
        let order = Order()
        // Signalled once the other thread asks for the store's lock — or, were its write to
        // take none, once it is through. Either way the swap goes on, and the test ends.
        let atTheDoor = DispatchSemaphore(value: 0)
        let through = DispatchSemaphore(value: 0)
        // A store that never lets its lock go is a test that fails, and not one that never
        // ends: each wait gives up, and the other thread is let through whatever comes of it.
        defer {
            if !lock.try() { Issue.record("the store's lock was still held when the test ended") }
            lock.unlock()
        }

        store.betweenReadAndWrite = {
            // Once: the other thread's write may be a swap of its own.
            store.betweenReadAndWrite = nil
            if lock.try() {
                lock.unlock()
                order.note("open")
            } else {
                order.note("held")
            }
            lock.asked = {
                order.note("asked")
                atTheDoor.signal()
            }
            Thread.detachNewThread {
                defer {
                    atTheDoor.signal()
                    through.signal()
                }
                let said: String
                switch other {
                case .save:
                    try? store.save(Self.token("theirs"))
                    said = "saved"
                case .forgetHost:
                    try? store.forget(host: Self.host)
                    said = "forgot"
                case .forgetToken:
                    said = "forgot the old one: \((try? store.forget(old)) == true)"
                case .update:
                    said = "noted on the old one: \((try? store.update(old.recorded(refused: "write:bookmarks"))) == true)"
                case .swap:
                    said = "kept over the old one: \((try? store.swap(expecting: "old", with: Self.token("theirs"))) == true)"
                }
                order.note(said)
            }
            if atTheDoor.wait(timeout: .now() + 30) == .timedOut {
                Issue.record("the other thread never came to its write")
            }
            order.note("writing")
        }

        let kept = try? store.swap(expecting: "old", with: Self.token("fresh"))
        guard !order.all.isEmpty else {
            Issue.record("the swap never came to its write")
            return
        }
        guard through.wait(timeout: .now() + 30) == .success else {
            Issue.record("the other thread's write never ended: the swap did not let the lock go")
            return
        }
        #expect(kept == true)

        let after = try held(store)
        switch other {
        case .save:
            #expect(order.all == ["held", "asked", "writing", "saved"])
            #expect(after?.accessToken == "theirs")
        case .forgetHost:
            #expect(order.all == ["held", "asked", "writing", "forgot"])
            #expect(after == nil)
        case .forgetToken:
            #expect(order.all == ["held", "asked", "writing", "forgot the old one: false"])
            #expect(after?.accessToken == "fresh")
        case .update:
            #expect(order.all == ["held", "asked", "writing", "noted on the old one: false"])
            #expect(after?.accessToken == "fresh")
            #expect(after?.refused == nil)
        case .swap:
            #expect(order.all == ["held", "asked", "writing", "kept over the old one: false"])
            #expect(after?.accessToken == "fresh")
        }
    }

    @Test("A swap the Keychain refuses throws and leaves the sign-in it was to replace held exactly as it was — string, facts and stamp — and the next swap lands")
    func aSwapThatFailsLeavesTheOldSignInHeld() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("held", scopes: Self.reading, asked: Self.acting).named(accountID: "7", handle: "@me@social.example").recorded(refused: "write:bookmarks"))
        let before = try #require(try held(store))
        let fresh = Self.token("fresh", scopes: Self.acting, asked: Self.acting)

        // A swap over a sign-in makes no add, and lets go of nothing before it writes.
        store.refuse(.adding)
        store.refuse(.changing)
        #expect(throws: ForumCredentialError.keychain(errSecInteractionNotAllowed)) {
            try store.swap(expecting: "held", with: fresh)
        }
        let after = try #require(try held(store))
        #expect(after == before)
        #expect(after.stamp == before.stamp)
        #expect(try store.parts() == [Self.host: before.held])

        // A read that fails: the same end.
        store.refuse(.reading)
        #expect(throws: ForumCredentialError.keychain(errSecInteractionNotAllowed)) {
            try store.swap(expecting: "held", with: fresh)
        }
        #expect(try held(store)?.stamp == before.stamp)

        #expect(try store.swap(expecting: "held", with: fresh))
        #expect(try held(store) == fresh)
    }

    @Test("A swap to a sign-in that holds fewer facts leaves none of the old one's behind, in the value or beside it, and files the new string under a new stamp")
    func aSwapLeavesNothingOfTheOldSignIn() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("held", scopes: Self.acting, asked: Self.acting).named(accountID: "7", handle: "@me@social.example").recorded(refused: "write:bookmarks"))
        let before = try #require(try held(store))
        let bare = Self.token("fresh", scopes: nil, asked: nil)

        #expect(try store.swap(expecting: "held", with: bare))
        let after = try #require(try held(store))
        #expect(after == bare)
        let stamp = try #require(after.stamp)
        #expect(stamp != before.stamp)
        #expect(try store.parts() == [Self.host: MastodonHeld(scopes: nil, asked: nil, stamp: stamp)])

        // The real store's row: what the write in place puts over the one the item had.
        let row = MastodonKeychain.attributes(for: before).merging(MastodonKeychain.changes(for: after)) { _, new in new }
        #expect(MastodonKeychain.held(row) == after.held)
        #expect(MastodonKeychain.grant(row) == .unasked)
        let written = try #require(row[kSecValueData as String] as? Data)
        let read = try #require(MastodonKeychain.Wire.decode(written, host: Self.host))
        #expect(read.held == after.held)
        #expect(read.accountID == nil)
    }

    @Test("A swap handed the refusals of the sign-in it replaces keeps other parts' refusals and drops only the words now given; handed none, it keeps none; and an update clears them only by the empty string")
    func aSwapCarriesRefusals() throws {
        let store = MemoryMastodonTokens()
        let old = Self.token("held", scopes: Self.reading, asked: Self.acting).recorded(refused: "write:statuses write:favourites write:bookmarks read:notifications")
        try store.save(old)
        let held = try #require(try store.parts(host: Self.host))

        // Acting was granted, and bookmarks refused again on this page.
        let given = "\(Self.reading) write:statuses write:favourites"
        let fresh = Self.token("fresh", scopes: given, asked: Self.acting).recorded(refused: "write:bookmarks")
        let carried = fresh.carrying(refusedFrom: held)
        #expect(carried.refused == "write:bookmarks read:notifications")
        #expect(carried.accessToken == "fresh")
        #expect(try store.swap(expecting: "held", with: carried))
        #expect(try store.parts(host: Self.host)?.refused == "write:bookmarks read:notifications")

        // Everything refused now given: nothing is left.
        let all = Self.token("all", scopes: "\(given) write:bookmarks read:notifications")
        #expect(all.carrying(refusedFrom: carried.held).refused == nil)

        // An update: nothing keeps, the empty string clears.
        #expect(try store.update(carried.recorded(refused: nil)))
        #expect(try store.parts(host: Self.host)?.refused == "write:bookmarks read:notifications")
        #expect(try store.update(carried.recorded(refused: "")))
        #expect(try store.parts(host: Self.host)?.refused == "")
        let cleared = try #require(try self.held(store))
        #expect(MastodonKeychain.held(MastodonKeychain.changes(for: cleared)) == cleared.held)

        // Not carried: the token's own, which is none.
        #expect(try store.swap(expecting: "fresh", with: Self.token("bare")))
        #expect(try store.parts(host: Self.host)?.refused == nil)
    }

    @Test("A save whose add the Keychain refuses throws with nothing held, as a save always did: the one held was let go before the add — and a first save, with nothing held, is the add alone")
    func aRefusedAddLeavesNothingHeld() throws {
        let saved = MemoryMastodonTokens()
        saved.refuse(.changing)
        try saved.save(Self.token("held"))
        #expect(try held(saved)?.accessToken == "held", "a first save changes nothing in place")
        saved.refuse(.changing, times: 0)
        saved.refuse(.adding)
        #expect(throws: ForumCredentialError.keychain(errSecInteractionNotAllowed)) { try saved.save(Self.token("fresh")) }
        #expect(try held(saved) == nil)
        try saved.save(Self.token("held"))
        #expect(try held(saved)?.accessToken == "held", "refused once")

        // A swap where nothing is held is the add too, and refused leaves nothing, as there was.
        let none = MemoryMastodonTokens()
        none.refuse(.adding)
        #expect(throws: ForumCredentialError.keychain(errSecInteractionNotAllowed)) {
            try none.swap(expecting: nil, with: Self.token("fresh"))
        }
        #expect(try held(none) == nil)
    }

    @Test("A save that cannot read what is held throws and changes nothing: the sign-in stays under its stamp, and the same string saved again is not filed under a new one")
    func aSaveThatCannotReadKeepsTheStamp() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("tok"))
        let before = try #require(try held(store))

        store.refuse(.reading)
        #expect(throws: ForumCredentialError.keychain(errSecInteractionNotAllowed)) {
            try store.save(Self.token("tok", scopes: Self.acting))
        }
        let after = try #require(try held(store))
        #expect(after == before)
        #expect(after.stamp == before.stamp)

        try store.save(Self.token("tok", scopes: Self.acting))
        #expect(try held(store)?.stamp == before.stamp)
    }

    @Test("A store that does not say how it writes in place writes nothing: an update and a swap both throw, and no host is named by any look")
    func aStoreThatDoesNotSay() throws {
        let silent = SilentStore()
        #expect(throws: ForumCredentialError.keychain(errSecUnimplemented)) { try silent.update(Self.token("tok")) }
        #expect(throws: ForumCredentialError.keychain(errSecUnimplemented)) { try silent.swap(expecting: nil, with: Self.token("tok")) }
        #expect(try silent.parts().isEmpty)
        #expect(try silent.bookmarking().isEmpty)
        #expect(try silent.noticing().isEmpty)
        #expect(silent.saves == 0)
    }

    // MARK: - The value, across builds

    @Test("A value written by a build before this one is still read: nothing refused and no stamp, and everything else as it was written — each shape a build has left")
    func aValueWrittenBeforeIsStillRead() throws {
        let first = Data(#"{"accessToken":"tok","clientID":"client","clientSecret":"client-secret"}"#.utf8)
        let asked = Data(#"{"accessToken":"tok","clientID":"client","clientSecret":"client-secret","scopes":"read:statuses","asked":"read:statuses write:bookmarks"}"#.utf8)
        let named = Data(#"{"accessToken":"tok","clientID":"client","clientSecret":"client-secret","scopes":"read:statuses","asked":"read:statuses","accountID":"7","handle":"@me@social.example"}"#.utf8)

        let earliest = try #require(MastodonKeychain.Wire.decode(first, host: Self.host))
        #expect(earliest == Self.token("tok", scopes: nil, asked: nil))
        #expect(earliest.held == MastodonHeld(scopes: nil, asked: nil))

        let middle = try #require(MastodonKeychain.Wire.decode(asked, host: Self.host))
        #expect(middle.held == MastodonHeld(scopes: "read:statuses", asked: "read:statuses write:bookmarks"))
        #expect(middle.bookmarksRefused)

        let latest = try #require(MastodonKeychain.Wire.decode(named, host: Self.host))
        #expect(latest.accountID == "7")
        #expect(latest.handle == "@me@social.example")
        #expect(latest.refused == nil)
        #expect(latest.stamp == nil)

        // Filed by this build, such a value gains a stamp and loses nothing.
        let store = MemoryMastodonTokens()
        try store.save(latest)
        #expect(try held(store) == latest)
        #expect(try held(store)?.stamp != nil)
    }

    /// The value as the build before this one reads it: its own fields, and no other.
    private struct ValueBefore: Decodable {
        var accessToken: String
        var clientID: String
        var clientSecret: String
        var scopes: String?
        var asked: String?
        var accountID: String?
        var handle: String?
    }

    @Test("A value written by this build is read by the build before it as the same sign-in — the refusal and the stamp are fields it does not know and passes over — and a value with neither is the bytes that build wrote")
    func whatAnOlderBuildReadsOfANewValue() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("tok", scopes: Self.reading, asked: Self.acting).named(accountID: "7", handle: "@me@social.example").recorded(refused: "write:bookmarks"))
        let filed = try #require(try held(store))
        let value = MastodonKeychain.Wire.encode(filed)

        let before = try JSONDecoder().decode(ValueBefore.self, from: value)
        #expect(before.accessToken == "tok")
        #expect(before.clientID == "client")
        #expect(before.clientSecret == "client-secret")
        #expect(before.scopes == Self.reading)
        #expect(before.asked == Self.acting)
        #expect(before.accountID == "7")
        #expect(before.handle == "@me@social.example")

        let read = try #require(MastodonKeychain.Wire.decode(value, host: Self.host))
        #expect(read == filed)
        #expect(read.stamp == filed.stamp)

        // Neither written down: no key for either, so nothing an older build has not seen.
        let plain = try #require(JSONSerialization.jsonObject(with: MastodonKeychain.Wire.encode(Self.token("tok"))) as? [String: Any])
        #expect(Set(plain.keys) == ["accessToken", "clientID", "clientSecret", "scopes", "asked"])
    }

    // MARK: - The item, and what never prints

    @Test("An update in place changes the value and the copies beside it, and nothing of where the item is kept or how it is protected: the same item, found the same way, under the same protection")
    func anUpdateChangesNothingOfTheItem() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("tok", scopes: Self.reading, asked: Self.acting).recorded(refused: "write:bookmarks"))
        let filed = try #require(try held(store))

        let changes = MastodonKeychain.changes(for: filed)
        let allowed: Set<String> = [
            kSecValueData as String, kSecAttrGeneric as String, kSecAttrComment as String, kSecAttrDescription as String,
        ]
        #expect(Set(changes.keys) == allowed)
        let whole = MastodonKeychain.attributes(for: filed)
        for key in allowed.subtracting([kSecValueData as String]) {
            #expect(changes[key] as? NSObject == whole[key] as? NSObject, "\(key)")
        }
        // The value is the token, so it is compared as what it reads back to and never shown.
        let written = try #require(changes[kSecValueData as String] as? Data)
        let sameValue: Bool = MastodonKeychain.Wire.decode(written, host: Self.host) == filed
        #expect(sameValue)
        let untouched: Set<String> = [
            kSecClass as String, kSecAttrService as String, kSecAttrAccount as String,
            kSecAttrSynchronizable as String, kSecAttrLabel as String, kSecAttrAccessible as String,
        ]
        #expect(Set(whole.keys).subtracting(allowed) == untouched)
        #expect(whole[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(whole[kSecAttrService as String] as? String == "fediqo.mastodon")
        // No attribute holds anything of the token, the registration's secret or who it is.
        let beside = changes.filter { $0.key != kSecValueData as String }
        let said = beside.values.map { ($0 as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\($0)" }.joined(separator: "|")
        #expect(!said.contains("tok"))
        #expect(!said.contains("client"))
    }

    @Test("Nothing new prints a token: what a sign-in is known to hold, a token that carries a refusal and a stamp, and the store itself show the host and words, and never the token or the registration's secret")
    func nothingPrintsAToken() throws {
        let store = MemoryMastodonTokens()
        let secret = MastodonToken(
            host: Self.host, accessToken: "SECRET-TOKEN", clientID: "client", clientSecret: "SECRET-CLIENT",
            scopes: Self.reading, asked: Self.acting, refused: "write:bookmarks"
        )
        try store.save(secret)
        let filed = try #require(try held(store))
        var printed = "\(filed) \(String(reflecting: filed)) \(filed.held) \(String(reflecting: try store.parts()))"
        dump(filed, to: &printed)
        dump(store, to: &printed)
        dump(filed.held, to: &printed)
        #expect(!printed.contains("SECRET"))
        #expect(printed.contains(Self.host))
    }

    @Test("The real store writes by the same rules the memory one runs, under one lock for the process, and nowhere else reaches the Keychain to write a token")
    func theRealStoreRunsTheSameRules() throws {
        let source = try Self.source()
        let real = try #require(source.components(separatedBy: "public struct KeychainMastodonTokens").dropFirst().first?
            .components(separatedBy: "public final class MemoryMastodonTokens").first)
        #expect(real.contains("private static let writing = NSLock()"))
        #expect(real.contains("TokenFiling(items: Items(), lock: Self.writing)"))
        for write in ["save(token)", "forget(host: host)", "forget(token)", "update(token)", "swap(expecting: held, with: token)"] {
            #expect(real.contains("try filing.\(write)"), "\(write) does not go through the one lock")
        }
        // The Keychain's own writes are called in one place each, below the rules.
        for call in ["SecItemAdd(", "SecItemUpdate(", "SecItemDelete("] {
            #expect(source.components(separatedBy: call).count == 2, "\(call)")
        }
        let filing = try #require(source.components(separatedBy: "struct TokenFiling").dropFirst().first?
            .components(separatedBy: "/// The real one.").first)
        let writes = filing.components(separatedBy: "\n    func ").dropFirst()
        #expect(writes.count == 5)
        for write in writes {
            #expect(write.contains("lock.withLock"), "a write takes no lock: \(write.prefix(40))")
        }
    }

    private static func source() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root.deleteLastPathComponent()
        }
        return try String(contentsOf: root.appending(path: "Sources/FediqoCore/MastodonTokens.swift"), encoding: .utf8)
    }
}

/// The store's one lock, saying when it is asked for.
private final class WatchedLock: NSLock, @unchecked Sendable {
    var asked: (@Sendable () -> Void)?

    override func lock() {
        asked?()
        super.lock()
    }
}

/// What happened, in the order it did, from whichever thread.
private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []

    func note(_ what: String) {
        lock.withLock { said.append(what) }
    }

    var all: [String] { lock.withLock { said } }
}

/// A store that answers only what the protocol requires.
private final class SilentStore: MastodonTokenStore, @unchecked Sendable {
    private(set) var saves = 0
    func token(host: String) throws -> MastodonToken? { nil }
    func save(_ token: MastodonToken) throws { saves += 1 }
    func forget(host: String) throws {}
    func forget(_ token: MastodonToken) throws -> Bool { false }
    func grants() throws -> [String: MastodonGrant] { [:] }
    func app(host: String) throws -> MastodonApp? { nil }
    func save(_ app: MastodonApp) throws {}
    func forgetApp(host: String) throws {}
}
