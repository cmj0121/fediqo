import Foundation
import Security
import Testing
@testable import FediqoCore

/// #347: the sign-ins a device made at a source and does not use — what is kept of them, where,
/// and that nothing but ending one can be done with it.
@Suite("The sign-ins a device left at a source")
struct MastodonLeftTests {
    private static let host = "social.example"

    private static func token(_ string: String, scopes: String? = MastodonOAuth.reading, id: String? = "1") -> MastodonToken {
        let made = MastodonToken(
            host: host, accessToken: string, clientID: "cid-SECRET", clientSecret: "csecret-SECRET", scopes: scopes
        )
        return id.map { made.named(accountID: $0, handle: "@reader@\(host)") } ?? made
    }

    private func states(_ store: MemoryMastodonTokens) throws -> [MastodonLeft.State] {
        try store.left(host: Self.host).map(\.state)
    }

    // MARK: - A set by token string

    @Test("A sign-in is in the journal once, in the state last written; taking it out leaves the others")
    func aSetByString() throws {
        let store = MemoryMastodonTokens()
        let narrow = Self.token("tok-narrow-SECRET")
        try store.journal(MastodonLeft(narrow, as: .pending))
        try store.journal(MastodonLeft(Self.token("tok-other-SECRET"), as: .left))
        try store.journal(MastodonLeft(narrow, as: .owed))
        #expect(try states(store) == [.left, .owed])
        #expect(try store.leftHosts() == [Self.host])

        try store.unjournal(MastodonLeft(narrow, as: .left))
        #expect(try states(store) == [.left])
        try store.forgetLeft(host: Self.host)
        #expect(try store.left(host: Self.host).isEmpty)
        #expect(try store.leftHosts().isEmpty, "an empty journal is no journal")
    }

    @Test("A sign-in that comes to be the one held leaves the journal, by a swap as by a save")
    func theHeldOneLeaves() throws {
        for bySwap in [true, false] {
            let store = MemoryMastodonTokens()
            let fresh = Self.token("tok-fresh-SECRET")
            try store.journal(MastodonLeft(fresh, as: .pending))
            try store.journal(MastodonLeft(Self.token("tok-old-SECRET"), as: .left))
            if bySwap {
                #expect(try store.swap(expecting: nil, with: fresh))
            } else {
                try store.save(fresh)
            }
            #expect(try states(store) == [.left], "by swap: \(bySwap)")
        }
    }

    @Test("A swap that keeps nothing leaves the journal as it was")
    func aSwapNotMadeLeavesTheJournal() throws {
        let store = MemoryMastodonTokens()
        try store.save(Self.token("tok-held-SECRET"))
        let fresh = Self.token("tok-fresh-SECRET")
        try store.journal(MastodonLeft(fresh, as: .pending))
        #expect(try !store.swap(expecting: "another", with: fresh))
        store.refuse(.changing)
        #expect(throws: (any Error).self) { _ = try store.swap(expecting: "tok-held-SECRET", with: fresh) }
        #expect(try states(store) == [.pending])
    }

    @Test("A journal that cannot be written says so, and what was journalled is as it was")
    func aWriteRefused() throws {
        let store = MemoryMastodonTokens()
        try store.journal(MastodonLeft(Self.token("tok-old-SECRET"), as: .left))
        store.refuse(.leaving)
        #expect(throws: (any Error).self) { try store.journal(MastodonLeft(Self.token("tok-new-SECRET"), as: .pending)) }
        #expect(try states(store) == [.left])
        store.refuse(.readingLeft)
        #expect(throws: (any Error).self) { try store.journal(MastodonLeft(Self.token("tok-new-SECRET"), as: .pending)) }
        #expect(try states(store) == [.left])
    }

    @Test("A journal is written over the one already there, in place: a write the keychain refuses loses no entry written before it — by a note, by taking one out, or by a sign-in coming to be held")
    func aWriteRefusedLosesNothing() throws {
        let store = MemoryMastodonTokens()
        let old = MastodonLeft(Self.token("tok-old-SECRET"), as: .left)
        let older = MastodonLeft(Self.token("tok-older-SECRET"), as: .left)
        try store.journal(older)
        try store.journal(old)

        // Every refusal is of the write itself: taking the item away is refused by nothing.
        store.refuse(.leaving)
        #expect(throws: (any Error).self) { try store.journal(old.marked(.owed)) }
        #expect(try states(store) == [.left, .left])
        store.refuse(.leaving)
        #expect(throws: (any Error).self) { try store.unjournal(old) }
        #expect(try states(store) == [.left, .left])

        // Kept all the same: the journal's write is not the sign-in's, and loses nothing.
        store.refuse(.leaving)
        try store.save(Self.token("tok-old-SECRET"))
        #expect(try store.token(host: Self.host)?.accessToken == "tok-old-SECRET")
        #expect(try store.left(host: Self.host).contains { $0.isSame(as: older) }, "a write that failed took the journal with it")

        let changes = MastodonKeychain.changes(forLeft: [old])
        #expect(Set(changes.keys) == [kSecValueData as String], "a write in place moves where the journal is kept, or how")
    }

    @Test("Only a store writes a sign-in down as lost: nothing outside this module can make an entry that is filed again as the sign-in held")
    func lostIsTheStoresAlone() throws {
        let token = Self.token("tok-SECRET")
        for state in MastodonLeft.State.allCases {
            let made = MastodonLeft(token, as: state)
            #expect(made.state != .lost, "made as lost from \(state.rawValue)")
            #expect(made.marked(.lost).state == made.state, "marked as lost from \(state.rawValue)")
        }
        #expect(MastodonLeft(token, as: .lost).state == .left)

        // Journalled from outside, an entry is never filed again as held.
        let store = MemoryMastodonTokens()
        try store.journal(MastodonLeft(token, as: .lost))
        try store.journal(MastodonLeft(Self.token("tok-other-SECRET"), as: .owed).marked(.lost))
        #expect(try !store.restoreLost(host: Self.host))
        #expect(try store.token(host: Self.host) == nil)

        // The store's own way in, which takes the sign-in itself.
        try store.journalLost(Self.token("tok-mine-SECRET"), accountID: nil)
        #expect(try states(store).contains(.lost))
        #expect(try store.restoreLost(host: Self.host))
        #expect(try store.token(host: Self.host)?.accessToken == "tok-mine-SECRET")

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let left = try String(contentsOf: root.appending(path: "Sources/FediqoCore/MastodonLeft.swift"), encoding: .utf8)
        #expect(left.contains("\n    static func lost(") && !left.contains("public static func lost("))
        #expect(!left.contains("public init(\n        host:"), "an entry can be made in any state from outside")
    }

    // MARK: - The sign-in the person held

    @Test("A sign-in written down as lost is filed again as the one held only where none is, with what it was granted, and then leaves the journal")
    func theLostOneIsFiledAgain() throws {
        let store = MemoryMastodonTokens()
        let lost = Self.token("tok-lost-SECRET", scopes: MastodonOAuth.scopes(writing: true))
        try store.journalLost(lost, accountID: nil)
        try store.journal(MastodonLeft(Self.token("tok-old-SECRET"), as: .left))

        try store.save(Self.token("tok-held-SECRET"))
        #expect(try !store.restoreLost(host: Self.host), "filed over a sign-in that is held")
        try store.forget(host: Self.host)

        store.refuse(.adding)
        #expect(throws: (any Error).self) { _ = try store.restoreLost(host: Self.host) }
        #expect(try states(store) == [.lost, .left], "a filing that failed lost the note of it")

        #expect(try store.restoreLost(host: Self.host))
        let held = try #require(try store.token(host: Self.host))
        #expect(held.accessToken == lost.accessToken && held.clientSecret == lost.clientSecret)
        #expect(held.scopes == lost.scopes && held.asked == lost.scopes)
        #expect(held.grant == .writing)
        #expect(try states(store) == [.left])
        #expect(try !store.restoreLost(host: Self.host))
    }

    @Test("A sign-in filed again is still whose it was: by the id written with it, or the one its check named where it had none")
    func theLostOneIsStillWhoseItWas() throws {
        for (written, said) in [("7", nil), (nil, "7")] as [(String?, String?)] {
            let store = MemoryMastodonTokens()
            try store.journalLost(Self.token("tok-lost-SECRET", id: written), accountID: said)
            #expect(try store.restoreLost(host: Self.host))
            #expect(try store.token(host: Self.host)?.accountID == "7")
        }
        let unnamed = MemoryMastodonTokens()
        try unnamed.journalLost(Self.token("tok-lost-SECRET", id: nil), accountID: nil)
        #expect(try unnamed.restoreLost(host: Self.host))
        #expect(try unnamed.token(host: Self.host)?.accountID == nil)
    }

    // MARK: - What is kept, and how

    @Test("A journal is kept as the sign-in is — this device only, while unlocked, never synchronised — under a service of its own, and with nothing readable beside its value")
    func keptAsTheSignInIs() throws {
        let entries = [MastodonLeft(Self.token("tok-old-SECRET"), as: .left)]
        let item = MastodonKeychain.attributes(forLeft: entries, host: "Social.Example")
        let held = MastodonKeychain.attributes(for: Self.token("tok-held-SECRET"))
        #expect(item[kSecAttrService as String] as? String == "fediqo.mastodon.left")
        #expect(item[kSecAttrService as String] as? String != held[kSecAttrService as String] as? String)
        #expect(item[kSecAttrAccount as String] as? String == Self.host)
        #expect(item[kSecAttrAccessible as String] as? String == held[kSecAttrAccessible as String] as? String)
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        let known: Set<String> = [
            kSecClass as String, kSecAttrService as String, kSecAttrAccount as String, kSecAttrSynchronizable as String,
            kSecAttrLabel as String, kSecAttrAccessible as String, kSecValueData as String,
        ]
        #expect(Set(item.keys) == known, "something of a journal rides where it is read without its value")
        #expect((item[kSecAttrLabel as String] as? String)?.contains("SECRET") == false)
        #expect(MastodonKeychain.allLeft()[kSecReturnData as String] == nil, "which hosts have a journal is asked with their values")
    }

    @Test("A journal's value comes back as it was written; a state a later build wrote is read as left; a value that is no journal is none")
    func theValue() throws {
        let entries = MastodonLeft.State.allCases.enumerated().map { index, state in
            let token = Self.token("tok-\(index)-SECRET", scopes: index == 0 ? nil : "read:statuses", id: index == 1 ? nil : "7")
            return state == .lost ? MastodonLeft.lost(token, accountID: nil) : MastodonLeft(token, as: state)
        }
        #expect(entries.map(\.state) == MastodonLeft.State.allCases)
        let data = MastodonKeychain.LeftWire.encode(entries)
        #expect(MastodonKeychain.LeftWire.decode(data, host: Self.host) == entries)

        let later = Data(#"[{"accessToken":"t","clientID":"c","clientSecret":"s","state":"shelved","more":1}]"#.utf8)
        #expect(MastodonKeychain.LeftWire.decode(later, host: Self.host)?.map(\.state) == [.left])
        #expect(MastodonKeychain.LeftWire.decode(Data("{}".utf8), host: Self.host) == nil)
        #expect(MastodonKeychain.LeftWire.decode(Data(), host: Self.host) == nil)
    }

    @Test("A sign-in kept by a build before the journal reads as it did, with no journal; and what this build keeps of a sign-in is what that build reads")
    func anOlderBuild() throws {
        // What a build before this one wrote, and all it wrote.
        let before = Data(#"{"accessToken":"tok-old","clientID":"cid","clientSecret":"csecret","scopes":"read:statuses"}"#.utf8)
        let read = try #require(MastodonKeychain.Wire.decode(before, host: Self.host))
        #expect(read.accessToken == "tok-old" && read.scopes == "read:statuses")
        let store = MemoryMastodonTokens()
        try store.save(read)
        #expect(try store.left(host: Self.host).isEmpty && store.leftHosts().isEmpty)
        #expect(try !store.restoreLost(host: Self.host))

        // The sign-in's own item gains nothing with the journal: an older build reads it whole.
        let written = try #require(try JSONSerialization.jsonObject(
            with: MastodonKeychain.Wire.encode(Self.token("tok-held"))
        ) as? [String: Any])
        let names: Set<String> = ["accessToken", "clientID", "clientSecret", "scopes", "accountID", "handle"]
        #expect(Set(written.keys).subtracting(["asked", "refused", "stamp"]) == names)
        #expect(MastodonKeychain.leftService != MastodonKeychain.service && MastodonKeychain.leftService != MastodonKeychain.appService)
    }

    // MARK: - Never printed, and good for one thing

    @Test("An entry and a journal print as a host and a state: no token, registration or secret reaches a description, a mirror or a dump")
    func neverPrinted() throws {
        let store = MemoryMastodonTokens()
        let entry = MastodonLeft(Self.token("tok-SECRET"), as: .owed)
        try store.journal(entry)
        let journal = try store.left(host: Self.host)
        var printed = "\(entry) \(String(reflecting: entry)) \(journal) \(String(reflecting: journal)) \(MastodonEnd.refused)"
        dump(entry, to: &printed)
        dump(journal, to: &printed)
        dump(store, to: &printed)
        printed += "\(ForumCredentialError.keychain(errSecDecode))"
        #expect(!printed.contains("SECRET"))
        #expect(printed.contains(Self.host) && printed.contains("owed"))
    }

    @Test("Nothing outside this module reads an entry's token or its registration's secret, and no signed-in door takes one")
    func goodForEndingOnly() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let core = root.appending(path: "Sources/FediqoCore")
        let left = try String(contentsOf: core.appending(path: "MastodonLeft.swift"), encoding: .utf8)
        for secret in ["accessToken", "clientID", "clientSecret"] {
            #expect(left.contains("\n    let \(secret): String\n"), "\(secret) can be read from outside")
        }
        #expect(!left.contains("public var restored") && left.contains("\n    var restored: MastodonToken {"))
        let auth = try String(contentsOf: core.appending(path: "MastodonAuth.swift"), encoding: .utf8)
        let door = try #require(auth.components(separatedBy: "public struct MastodonAuthorized").dropFirst().first)
        #expect(!door.contains("MastodonLeft"))
        #expect(auth.components(separatedBy: "MastodonLeft").count == 2, "an entry is taken by more than the one ask that ends it")
    }

    @Test("Whether a sign-in left may do what another may not is read off the words of each; one with nothing written down cannot be shown not to")
    func holdsMore() {
        let acting = MastodonLeft(Self.token("a", scopes: MastodonOAuth.scopes(writing: true)), as: .left)
        let reading = MastodonLeft(Self.token("r"), as: .left)
        let unknown = MastodonLeft(Self.token("u", scopes: nil), as: .left)
        #expect(acting.holdsMore(than: MastodonOAuth.reading))
        #expect(!reading.holdsMore(than: MastodonOAuth.scopes(writing: true)))
        #expect(!reading.holdsMore(than: MastodonOAuth.reading))
        #expect(reading.holdsMore(than: nil))
        #expect(unknown.holdsMore(than: MastodonOAuth.scopes(writing: true)))
    }

    // MARK: - Ending one, and telling a token handed back

    @Test("A source's answer to ending a sign-in is read three ways: it has, it never will, or nothing to go by")
    func theAnswer() async {
        let entry = MastodonLeft(Self.token("tok-123"), as: .left)
        let answers: [(FixtureSender.Outcome, MastodonEnd)] = [
            (.json("{}"), .ended),
            (.json(MastodonSignInCaptures.revokeRefused, status: 403), .refused),
            (.json(#"{"error":"forbidden"}"#, status: 403), .unanswered),
            (.json("<html>", status: 403), .unanswered),
            (.json("{}", status: 503), .unanswered),
            (.fail, .unanswered),
        ]
        for (outcome, expected) in answers {
            let server = FixtureSender(["/oauth/revoke": outcome])
            let answer = await MastodonOAuth(host: Self.host, sender: server).revoke(entry)
            #expect(answer == expected)
            #expect(await server.form("/oauth/revoke")["token"] == "tok-123")
        }
    }

    @Test("A token is shown to be handed back only where it cannot have been made by the trade that answered with it: dated a whole second, and however long the trade took, before its answer")
    func handedBack() {
        let answered = "Sat, 10 Oct 2026 05:10:35 GMT"
        let then = 1_791_609_035
        let quick = Duration.milliseconds(300)
        #expect(!MastodonOAuth.handedBack(made: then, answered: answered, after: quick))
        #expect(!MastodonOAuth.handedBack(made: then - 1, answered: answered, after: quick))
        #expect(MastodonOAuth.handedBack(made: then - 2, answered: answered, after: quick))
        #expect(MastodonOAuth.handedBack(made: then - 86_400, answered: answered, after: quick))
        #expect(!MastodonOAuth.handedBack(made: then + 60, answered: answered, after: quick))
        #expect(!MastodonOAuth.handedBack(made: nil, answered: answered, after: quick))
        #expect(!MastodonOAuth.handedBack(made: then - 60, answered: nil, after: quick))
        #expect(!MastodonOAuth.handedBack(made: then - 60, answered: "yesterday", after: quick))
    }

    @Test("A fresh token from a server a second or more slow is not read as handed back: the gap its answer shows must be more than the trade itself took", arguments: [
        (1000, 2, true), (1001, 2, false), (1500, 2, false), (1500, 3, true),
        (2000, 3, true), (2001, 3, false), (9000, 9, false), (9000, 10, true), (0, 1, true), (0, 0, false),
    ])
    func handedBackBySlowServers(took: Int, apart: Int, shown: Bool) {
        let answered = "Sat, 10 Oct 2026 05:10:35 GMT"
        let made = 1_791_609_035 - apart
        #expect(MastodonOAuth.handedBack(made: made, answered: answered, after: .milliseconds(took)) == shown)
    }

    @Test("Only a 401 that is the source's own answer is noted as the source ending a sign-in — and every 401 from the account check still takes the token held, as it always has", arguments: [
        (MastodonSignInCaptures.afterRevoke, true),
        (#"{"error":"The access token is invalid"}"#, true),
        ("<html><body><h1>401 Authorization Required</h1></body></html>", false),
        ("", false),
        ("HTTP Basic: Access denied.\n", false),
        ("{}", false), (#"{"error":""}"#, false), (#"{"message":"Unauthorized"}"#, false), (#"{"error":401}"#, false),
    ])
    func theSourcesOwnWord(body: String, own: Bool) async throws {
        for path in ["/api/v1/timelines/home", MastodonAuthorized.accountCheck] {
            let tokens = MemoryMastodonTokens()
            try tokens.save(MastodonFixture.token)
            let endings = MastodonEndings()
            let server = FixtureSender([
                "/api/v1/timelines/home": .json("{}", status: 401),
                MastodonAuthorized.accountCheck: .json(body, status: 401),
            ])
            let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens, endings: endings)
            await #expect(throws: MastodonAuthError.signedOut) { _ = try await door.get(path: path) }
            #expect(try tokens.token(host: MastodonFixture.token.host) == nil)
            #expect(endings.takeSaid(MastodonFixture.token.host) == own)
            #expect(!endings.takeSaid(MastodonFixture.token.host), "said once and taken twice")
        }
    }

    @Test("A 401 that is not the source's own takes the sign-in held and, in the same step of the store, every sign-in written down as left — unended; one owed an end, one never kept and one lost stay. The source's own 401 leaves the journal for whoever ends it", arguments: [false, true])
    func forgottenWithWhatWasLeft(saidBySource: Bool) async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.journalLost(Self.token("tok-lost-SECRET"), accountID: nil)
        try tokens.save(MastodonFixture.token)
        for (string, state) in [("a", MastodonLeft.State.left), ("b", .owed), ("c", .left), ("d", .pending)] {
            try tokens.journal(MastodonLeft(Self.token("tok-\(string)-SECRET"), as: state))
        }
        let endings = MastodonEndings()
        let body = saidBySource ? MastodonSignInCaptures.afterRevoke : "<html>"
        let server = FixtureSender([MastodonAuthorized.accountCheck: .json(body, status: 401)])
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens, endings: endings)
        await #expect(throws: MastodonAuthError.signedOut) { _ = try await door.get(path: MastodonAuthorized.accountCheck) }

        #expect(try tokens.token(host: Self.host) == nil)
        let kept: [MastodonLeft.State] = saidBySource ? [.lost, .left, .owed, .left, .pending] : [.lost, .owed, .pending]
        #expect(try states(tokens) == kept)
        #expect(endings.takeDropped() == (saidBySource ? [] : [Self.host]))
        #expect(endings.takeDropped().isEmpty, "told twice of one dropping")
        #expect(endings.takeSaid(Self.host) == saidBySource)
    }

    @Test("The one step is the store's: asked of it directly it says how many it dropped, nothing where the sign-in is no longer the one held, and a journal it cannot write leaves the sign-in held")
    func theOneStep() throws {
        let store = MemoryMastodonTokens()
        let held = Self.token("tok-held-SECRET")
        try store.save(held)
        try store.journal(MastodonLeft(Self.token("tok-a-SECRET"), as: .left))
        try store.journal(MastodonLeft(Self.token("tok-b-SECRET"), as: .owed))

        #expect(try store.forget(Self.token("tok-another-SECRET"), saidBySource: false) == nil)
        #expect(try states(store) == [.left, .owed])
        store.refuse(.leaving)
        #expect(throws: (any Error).self) { _ = try store.forget(held, saidBySource: false) }
        #expect(try store.token(host: Self.host) != nil, "the sign-in went and what was left for it stayed")
        #expect(try states(store) == [.left, .owed])

        #expect(try store.forget(held, saidBySource: false) == 1)
        #expect(try store.token(host: Self.host) == nil)
        #expect(try states(store) == [.owed])

        try store.save(held)
        try store.journal(MastodonLeft(Self.token("tok-a-SECRET"), as: .left))
        #expect(try store.forget(held, saidBySource: true) == 0)
        #expect(try states(store) == [.owed, .left])
    }

    @Test("A 401 the account check does not stand by, or one about a sign-in since replaced, notes nothing")
    func nothingNotedOfAnother() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let endings = MastodonEndings()
        let passing = FixtureSender(["/api/v1/timelines/home": .json(MastodonSignInCaptures.afterRevoke, status: 401)])
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: passing, store: tokens, endings: endings)
        await #expect(throws: MastodonAuthError.http(401)) { _ = try await door.get(path: "/api/v1/timelines/home") }
        #expect(!endings.takeSaid(MastodonFixture.token.host))

        let other = MastodonToken(host: MastodonFixture.token.host, accessToken: "tok-newer", clientID: "c", clientSecret: "s")
        try tokens.save(other)
        let ending = FixtureSender([MastodonAuthorized.accountCheck: .json(MastodonSignInCaptures.afterRevoke, status: 401)])
        let late = MastodonAuthorized(token: MastodonFixture.token, sender: ending, store: tokens, endings: endings)
        await #expect(throws: MastodonAuthError.http(401)) { _ = try await late.get(path: MastodonAuthorized.accountCheck) }
        #expect(!endings.takeSaid(MastodonFixture.token.host))
        #expect(try tokens.token(host: other.host)?.accessToken == "tok-newer")
    }

    /// A server that dates its answer to the trade, and the token in it.
    private actor Dated: HTTPSender {
        private let made: Int?
        private(set) var paths: [String] = []

        init(made: Int?) { self.made = made }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            paths.append(url.path)
            var body = MastodonFixture.me
            var headers: [String: String] = [:]
            if url.path == "/oauth/token" {
                body = made.map { #"{"access_token":"tok-123","created_at":\#($0)}"# } ?? MastodonFixture.issued
                headers["Date"] = "Sat, 10 Oct 2026 05:10:35 GMT"
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    /// What a sign-in was handed before its check, in the order it was.
    private actor Noted {
        private(set) var strings: [String] = []
        func note(_ token: MastodonToken) { strings.append(token.accessToken) }
    }

    private struct Refused: Error {}

    @Test("A sign-in hands over the token it made before checking it; where the note cannot be taken the token is not checked and is not a sign-in; and one handed back is not handed over at all")
    @MainActor
    func notedBeforeItsCheck() async throws {
        let then = 1_791_609_035
        let fresh = Dated(made: then)
        let noted = Noted()
        let signed = try await MastodonOAuth(host: Self.host, sender: fresh).signIn(
            as: MastodonFixture.app, through: FixtureBrowser.approving()
        ) { token in
            // Nothing has been asked of the token yet.
            #expect(await fresh.paths == ["/oauth/token"])
            await noted.note(token)
        }
        #expect(await noted.strings == ["tok-123"])
        #expect(signed.failed == nil && signed.accountID == "1" && !signed.handedBack)

        let unnoted = Dated(made: then)
        let refused = try await MastodonOAuth(host: Self.host, sender: unnoted).signIn(
            as: MastodonFixture.app, through: FixtureBrowser.approving()
        ) { _ in throw Refused() }
        #expect(refused.failed == .keychain && refused.accountID == nil)
        #expect(await unnoted.paths == ["/oauth/token"], "a token nobody could note was checked all the same")

        let earlier = Dated(made: then - 600)
        let back = try await MastodonOAuth(host: Self.host, sender: earlier).signIn(
            as: MastodonFixture.app, through: FixtureBrowser.approving()
        ) { _ in throw Refused() }
        #expect(back.handedBack && back.failed == nil, "a token handed back was noted as made here")

        let undated = Dated(made: nil)
        let plain = try await MastodonOAuth(host: Self.host, sender: undated).signIn(
            as: MastodonFixture.app, through: FixtureBrowser.approving()
        )
        #expect(!plain.handedBack)
    }

    @Test("The check hands back the id its answer names, and nothing where it names none or one too long to be one")
    func theCheckNamesTheAccount() async throws {
        let answers: [(String, String?)] = [
            (MastodonFixture.me, "1"), ("{}", nil), (#"{"id":""}"#, nil), ("[]", nil),
            (#"{"id":"\#(String(repeating: "9", count: 513))"}"#, nil),
        ]
        for (body, expected) in answers {
            let server = MastodonFixture.server(verify: .json(body))
            let who = try await MastodonOAuth(host: Self.host, sender: server).verify(MastodonFixture.token)
            #expect(who.id == expected)
        }
    }
}
