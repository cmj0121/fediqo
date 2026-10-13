import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoPersistence

/// #347: what a package carries of a sign-in beyond the token — what it was asked, what was
/// refused, whose it is — and what a read back does with the sign-in it takes out: written
/// down before the package's is filed, as being replaced until every step has held and as
/// replaced after, never ended by the read back itself, and the journal put back as it was
/// where the read back is undone.
@Suite("A sign-in in a package")
struct SignInInAPackageTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let host = PackagerFixture.mastodon.host
    private static let acting = MastodonOAuth.scopes(writing: true, bookmarks: false)
    private static let follows = MastodonPart.follows.words.joined(separator: " ")
    private let key = PackageKey.password("open sesame")

    private func package() -> URL { PackagerFixture.package() }

    private static func token(
        _ string: String, client: String = "c", scopes: String? = SignInInAPackageTests.acting, id: String? = "42"
    ) -> MastodonToken {
        let token = MastodonToken(host: host, accessToken: string, clientID: client, clientSecret: "s", scopes: scopes, asked: scopes)
        return id.map { token.named(accountID: $0, handle: "@ada@\(host)") } ?? token
    }

    /// The sign-ins left at the host, as a line a test compares: which token, in which state.
    private func journal(_ tokens: MemoryMastodonTokens, at host: String = SignInInAPackageTests.host) throws -> [String] {
        try tokens.left(host: host).map { "\($0.accessToken) \($0.state.rawValue)" }
    }

    /// A whole package as a build before #347 wrote one: the sign-in with its token, its
    /// registration and what it may do, and not a key more.
    private func older(at url: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let file = try StoreFile(at: scratch)
            try await file.save(sources: [PackagerFixture.mastodon], notes: [])
            try file.db.close()
        }
        let index = try Data(contentsOf: scratch.appendingPathComponent("index.sqlite"))
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let secrets = Data("""
        {"mastodon":[{"host":"\(Self.host)","accessToken":"t","clientID":"c","clientSecret":"s","scopes":"\(Self.acting)"}],\
        "apps":[{"host":"\(Self.host)","clientID":"c","clientSecret":"s","scopes":"\(Self.acting)"}],"forums":[]}
        """.utf8)
        let summary = PackageSummary(
            sources: [.init(host: Self.host, kind: .mastodon)], posts: 0, timelines: 0,
            takenAt: PackagerFixture.origin, withPictures: false, bytes: index.count + settings.count + secrets.count,
            hasSecrets: true, device: "an older build", appVersion: "0.5.0", entryCount: 3
        )
        let writer = try PackageWriter(to: url, key: key, summary: summary, rounds: 1000)
        for (kind, name, data) in [
            (PackageFormat.Entry.Kind.store, "index.sqlite", index), (.settings, "settings", settings), (.secrets, "secrets", secrets),
        ] {
            var offset = 0
            try writer.add(kind, name: name, bytes: data.count) { most in
                guard offset < data.count else { return nil }
                let end = min(data.count, offset + most)
                defer { offset = end }
                return data[offset..<end]
            }
        }
        try writer.finish()
    }

    // MARK: - What rides

    @Test("A sign-in taken from a package says of each part what the device it came from knew — held, asked and not given, refused on the page, never asked — and whose it is; what that device had left at the source does not ride")
    func whatWasKnownRides() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        // Reads and acts; asked for bookmarks and not given them; refused following on the
        // source's page; never asked for notices.
        let known = MastodonToken(
            host: Self.host, accessToken: "t", clientID: "c", clientSecret: "s", scopes: Self.acting,
            asked: Self.acting + " write:bookmarks " + Self.follows, refused: Self.follows,
            accountID: "42", handle: "@ada@\(Self.host)"
        )
        try from.tokens.save(known)
        try from.tokens.journal(MastodonLeft(Self.token("narrower", scopes: MastodonOAuth.reading), as: .left))
        let standings = MastodonPart.allCases.map { MastodonParts.standing($0, of: known.held) }
        try #require(Set(standings).isSuperset(of: [.held, .notGiven, .refused, .unasked]), "the premise: one part of each kind")

        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }

        let carried = try #require(try onto.tokens.token(host: Self.host))
        #expect(MastodonPart.allCases.map { MastodonParts.standing($0, of: carried.held) } == standings)
        #expect(MastodonParts.standing(.bookmarks, of: carried.held) == .notGiven)
        #expect(MastodonParts.standing(.follows, of: carried.held) == .refused)
        #expect(MastodonParts.standing(.notices, of: carried.held) == .unasked)
        #expect(carried.scopes == known.scopes && carried.asked == known.asked && carried.refused == known.refused)
        #expect(carried.accountID == "42" && carried.handle == "@ada@\(Self.host)")
        #expect(carried.accessToken == "t" && carried.clientID == "c" && carried.clientSecret == "s")
        // The journal never rides, and taking away took nothing out of the sender's.
        #expect(try onto.tokens.leftHosts().isEmpty)
        #expect(try journal(from.tokens) == ["narrower left"])
    }

    @Test("A package from a build before this reads as before: the token, its registration and what it may do, nothing asked beyond that, nothing refused and nobody named — every part stands as it did")
    func anOlderPackage() async throws {
        let onto = try await Device()
        let url = package()
        defer { onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await older(at: url)

        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }

        let carried = try #require(try onto.tokens.token(host: Self.host))
        #expect(carried.accessToken == "t" && carried.clientID == "c" && carried.clientSecret == "s")
        #expect(carried.scopes == Self.acting)
        #expect(carried.asked == nil && carried.refused == nil && carried.accountID == nil && carried.handle == nil)
        let before = MastodonHeld(scopes: Self.acting, asked: nil)
        for part in MastodonPart.allCases {
            #expect(MastodonParts.standing(part, of: carried.held) == MastodonParts.standing(part, of: before), "\(part)")
        }
        #expect(MastodonParts.standing(.follows, of: carried.held) == .unasked)
        #expect(try onto.tokens.app(host: Self.host)?.scopes == Self.acting)
    }

    @Test("What a package says of whose a sign-in is, is taken as an account check's answer is: an id that is nothing or too long is none, and a handle is kept only with an id, where it can be a name of that very source", arguments: [
        ["", "@ada@one.example"], [String(repeating: "9", count: 600), "@ada@one.example"], ["42", "@ada@elsewhere.example"],
        ["42", "ada\u{202E}"], ["4 2", "@ada@one.example"], ["42\u{7}", "@ada@one.example"], ["42\u{202E}", "@ada@one.example"],
        ["42\n", "@ada@one.example"],
    ])
    func whoseItIsIsHeldToTheRule(_ said: [String]) throws {
        let carried = MastodonToken.carried(
            host: Self.host, accessToken: "t", clientID: "c", clientSecret: "s", scopes: nil, asked: nil, refused: nil,
            accountID: said[0], handle: said[1]
        )
        #expect(carried.accountID == (said[0] == "42" ? "42" : nil))
        #expect(carried.handle == nil)
        #expect(carried.packaged)
    }

    @Test("The lists of words a package brings are bounded before they are filed: what cannot be a scope word is dropped, a list longer than a source's own account of a token may be is none at all, and a sign-in reading by the source's one word for every read still reads by it")
    func theWordsAreBounded() async throws {
        func carried(_ scopes: String?, asked: String? = nil, refused: String? = nil) -> MastodonToken {
            .carried(
                host: Self.host, accessToken: "t", clientID: "c", clientSecret: "s", scopes: scopes, asked: asked,
                refused: refused, accountID: nil, handle: nil
            )
        }
        let junk = "read:statuses \u{7}bell wri\"te back\\slash \(String(repeating: "x", count: 65)) caf\u{E9}  write:statuses\nread"
        let kept = carried(junk, asked: junk, refused: junk)
        #expect(kept.scopes == "read:statuses write:statuses read")
        #expect(kept.asked == kept.scopes && kept.refused == kept.scopes)
        let many = (0...MastodonOAuth.tokenInfoWords).map { "w\($0)" }.joined(separator: " ")
        let over = carried(many, asked: many, refused: many)
        #expect(over.scopes == nil && over.asked == nil && over.refused == nil)
        let huge = carried(String(repeating: "a", count: 1 << 20), asked: String(repeating: " ", count: 1 << 20))
        #expect(huge.scopes == nil && huge.asked == nil)
        #expect(carried("\u{7} \u{8}").scopes == nil)
        #expect(carried(nil).scopes == nil)
        #expect(carried("read write").scopes == "read write")
        #expect(carried(Self.acting).scopes == Self.acting)

        // And through a package: what is filed in the Keychain is the bounded list.
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try from.tokens.save(MastodonToken(host: Self.host, accessToken: "t", clientID: "c", clientSecret: "s", scopes: many, asked: junk))
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }
        let filed = try #require(try onto.tokens.token(host: Self.host))
        #expect(filed.scopes == nil && filed.asked == "read:statuses write:statuses read")
        #expect(try onto.tokens.parts()[Self.host]?.asked == "read:statuses write:statuses read")
    }

    // MARK: - The mark on both sides

    @Test("Taking a sign-in away marks it, where it stays, as one that has ridden a package — in place, with everything else beside it and the mark of its filing as they were — and reading it back marks the one filed; a sign-in this device made is unmarked", arguments: [PackageSummary.Contents.whole, .signInsOnly])
    func markedOnBothSides(_ contents: PackageSummary.Contents) async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try from.tokens.save(Self.token("t"))
        let before = try #require(try from.tokens.token(host: Self.host))
        try #require(!before.packaged)

        try await from.packager().takeAway(to: url, key: key, pictures: false, contents: contents) { _ in }

        let sender = try #require(try from.tokens.token(host: Self.host))
        #expect(sender.packaged)
        #expect(sender.stamp == before.stamp, "a mark beside the sign-in read as another sign-in filed")
        #expect(sender.accessToken == "t" && sender.scopes == before.scopes && sender.asked == before.asked)
        #expect(sender.accountID == before.accountID && sender.handle == before.handle)

        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }
        #expect(try onto.tokens.token(host: Self.host)?.packaged == true)
        // The mark stays through a note written beside the sign-in afterwards.
        #expect(try from.tokens.update(MastodonToken(host: Self.host, accessToken: "t", clientID: "c", clientSecret: "s", refused: Self.follows)))
        #expect(try from.tokens.token(host: Self.host)?.packaged == true)
    }

    @Test("A take-away whose mark the Keychain refuses takes nothing away: no package is written holding a sign-in this device does not know it shared")
    func aMarkRefused() async throws {
        let from = try await PackagerFixture.populated()
        let url = package()
        defer { from.remove(); try? FileManager.default.removeItem(at: url) }
        from.tokens.refuse(.changing)

        await #expect(throws: ForumCredentialError.self) {
            try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try from.tokens.token(host: Self.host)?.packaged == false)
    }

    // MARK: - The sign-in a read back takes out

    @Test("A read back writes the sign-in it replaces down — with its own registration, what it held and whose it was — before the package's is filed: as being replaced until every step has held, and as replaced once it has; one the package brings no sign-in for is written down too; the journal held before stays")
    func theReplacedJoinsTheJournal() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try onto.tokens.save(Self.token("old", client: "c-old"))
        try onto.tokens.journal(MastodonLeft(Self.token("older", scopes: MastodonOAuth.reading), as: .left))
        try onto.tokens.save(MastodonToken(host: "kept.example", accessToken: "k", clientID: "c-kept", clientSecret: "s"))
        let watching = WatchedTokens(inner: onto.tokens)

        try await packager(onto, tokens: watching).readBack(url, key: key, replacing: true) { _ in }

        #expect(try onto.tokens.token(host: Self.host)?.accessToken == "t")
        #expect(try journal(onto.tokens) == ["older left", "old replaced"])
        let left = try #require(try onto.tokens.left(host: Self.host).last)
        #expect(left.clientID == "c-old" && left.accountID == "42" && left.words == Self.acting)
        #expect(watching.journalAtFiling[Self.host] == ["older left", "old replacing"], "the package's sign-in was filed before the one it replaces was written down")
        // The two notes of sign-ins taken out, each with that sign-in still held; then the two
        // rewritten as replaced once every step held, with the package's own held or none.
        #expect(watching.heldAtJournal == ["k", "old", "nothing", "t"], "a sign-in was forgotten before it was written down")
        // No sign-in rides for this host, and the one held there is gone from the device.
        #expect(try onto.tokens.token(host: "kept.example") == nil)
        #expect(try journal(onto.tokens, at: "kept.example") == ["k replaced"])
    }

    @Test("A package of sign-ins only that brings a registration and no sign-in for a host takes the sign-in held there off the device, written down — and leaves every other host's alone")
    func aRegistrationAndNoSignIn() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try from.tokens.save(MastodonApp(host: Self.host, clientID: "c-theirs", clientSecret: "s"))
        try await from.packager().takeAway(to: url, key: key, pictures: false, contents: .signInsOnly) { _ in }
        try onto.tokens.save(Self.token("old", client: "c-old"))
        try onto.tokens.save(MastodonToken(host: "kept.example", accessToken: "k", clientID: "c", clientSecret: "s"))

        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }

        #expect(try onto.tokens.token(host: Self.host) == nil)
        #expect(try onto.tokens.app(host: Self.host)?.clientID == "c-theirs")
        #expect(try journal(onto.tokens) == ["old replaced"])
        #expect(try onto.tokens.left(host: Self.host).first?.clientID == "c-old", "written down under the package's registration, which cannot end it")
        #expect(try onto.tokens.token(host: "kept.example")?.accessToken == "k")
        #expect(try onto.tokens.leftHosts() == [Self.host])
    }

    @Test("The very token a package brings is replaced by nothing but itself: it is not written down as left, and is filed under a new mark — what the package says of it is nobody's confirmed word")
    func theSameTokenReadBack() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try onto.tokens.save(Self.token("t"))
        let stamp = try #require(try onto.tokens.token(host: Self.host)?.stamp)

        try await onto.packager().readBack(url, key: key, replacing: true) { _ in }

        #expect(try onto.tokens.leftHosts().isEmpty)
        let filed = try #require(try onto.tokens.token(host: Self.host))
        #expect(filed.accessToken == "t" && filed.scopes == "read" && filed.accountID == nil, "as the package says")
        #expect(filed.stamp != nil && filed.stamp != stamp)
    }

    @Test("A sign-in the package brings that this device had left is the one held again and no longer left, and the one it replaces takes its turn in the journal")
    func aLeftOneReadBack() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try onto.tokens.save(Self.token("wider"))
        try onto.tokens.journal(MastodonLeft(Self.token("t", scopes: "read"), as: .left))

        try await onto.packager().readBack(url, key: key, replacing: true) { _ in }

        #expect(try onto.tokens.token(host: Self.host)?.accessToken == "t")
        #expect(try journal(onto.tokens) == ["wider replaced"])
    }

    @Test("A journal that cannot be written stops the read back before anything is taken out: the sign-in held is still held as it was, the package's is not filed, and nothing else on the device has changed")
    func theNoteCannotBeTaken() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try onto.tokens.save(Self.token("old"))
        let held = try #require(try onto.tokens.token(host: Self.host))
        let before = try onto.fingerprint()
        onto.tokens.refuse(.leaving)

        await #expect(throws: ForumCredentialError.self) {
            try await onto.packager().readBack(url, key: key, replacing: true) { _ in }
        }

        let after = try #require(try onto.tokens.token(host: Self.host))
        #expect(after == held && after.stamp == held.stamp)
        #expect(try onto.tokens.leftHosts().isEmpty)
        #expect(try onto.fingerprint() == before)
    }

    // MARK: - Rolled back

    @Test("A read back that is rolled back puts the journal back as it was, entry for entry and in order, and the sign-in held back as it was held — what was written beside it and the mark of its filing with it")
    func rolledBack() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device(noFile: true)
        let url = package()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onto.directory.path)
            from.remove(); onto.remove(); try? manager.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        // Held: a sign-in with a refusal beside it. Left: the very token the package brings,
        // then one owed an end. And a sign-in at a host the package brings none for.
        try onto.tokens.save(Self.token("wider").recorded(refused: Self.follows))
        try onto.tokens.journal(MastodonLeft(Self.token("t", scopes: "read"), as: .left))
        try onto.tokens.journal(MastodonLeft(Self.token("owed-one"), as: .owed))
        try onto.tokens.save(MastodonToken(host: "kept.example", accessToken: "k", clientID: "c", clientSecret: "s"))
        let held = try #require(try onto.tokens.token(host: Self.host))
        let kept = try #require(try onto.tokens.token(host: "kept.example"))
        // The Keychain accepts the package's sign-in, and the folder then refuses the index.
        let path = onto.directory.path
        let watching = WatchedTokens(inner: onto.tokens) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        }

        await #expect(throws: (any Error).self) {
            try await packager(onto, tokens: watching).readBack(url, key: key, replacing: true) { _ in }
        }

        try #require(watching.journalAtFiling[Self.host] == ["t left", "owed-one owed", "wider replacing"], "the premise: the read back had filed, and written down")
        #expect(try journal(onto.tokens) == ["t left", "owed-one owed"])
        #expect(try journal(onto.tokens, at: "kept.example").isEmpty)
        #expect(try onto.tokens.leftHosts() == [Self.host])
        let after = try #require(try onto.tokens.token(host: Self.host))
        #expect(after == held && after.stamp == held.stamp)
        #expect(after.refused == Self.follows && after.accountID == "42" && !after.packaged)
        let other = try #require(try onto.tokens.token(host: "kept.example"))
        #expect(other == kept && other.stamp == kept.stamp)
    }

    @Test("A read back that is rolled back takes out of the journal only the notes it took itself: one the session took meanwhile, of a sign-in of its own, stays, and so does a state it moved another to")
    func rolledBackKeepsWhatOthersWrote() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device(noFile: true)
        let url = package()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onto.directory.path)
            from.remove(); onto.remove(); try? manager.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try onto.tokens.save(Self.token("wider"))
        try onto.tokens.journal(MastodonLeft(Self.token("t", scopes: "read"), as: .left))
        try onto.tokens.journal(MastodonLeft(Self.token("earlier"), as: .left))
        let held = try #require(try onto.tokens.token(host: Self.host))
        // Once the package's sign-in is in: the session writes one down of its own and moves
        // another to owed, and the folder then refuses the index.
        let path = onto.directory.path
        let inner = onto.tokens
        let watching = WatchedTokens(inner: inner) {
            try? inner.journal(MastodonLeft(Self.token("the-sessions-own"), as: .left))
            try? inner.journal(MastodonLeft(Self.token("earlier"), as: .owed))
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        }

        await #expect(throws: (any Error).self) {
            try await packager(onto, tokens: watching).readBack(url, key: key, replacing: true) { _ in }
        }

        #expect(Set(try journal(onto.tokens)) == ["t left", "earlier owed", "the-sessions-own left"])
        let after = try #require(try onto.tokens.token(host: Self.host))
        #expect(after == held && after.stamp == held.stamp)
    }

    @Test("A sign-in the person makes at a host while a read back is being undone is theirs, and stands: the undo takes out only the package's own, puts nothing over the newer one, and leaves the sign-in the read back took out written down as replaced, for the session to settle")
    func aNewerSignInStandsThroughTheUndo() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device(noFile: true)
        let url = package()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onto.directory.path)
            from.remove(); onto.remove(); try? manager.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try onto.tokens.save(Self.token("wider"))
        try onto.tokens.save(MastodonToken(host: "kept.example", accessToken: "k", clientID: "c", clientSecret: "s"))
        // Once the package's sign-in is in: the person signs in again at its host and at the
        // other, and the folder then refuses the index.
        let path = onto.directory.path
        let inner = onto.tokens
        let watching = WatchedTokens(inner: inner) {
            _ = try? inner.swap(expecting: "t", with: Self.token("newer"))
            _ = try? inner.swap(expecting: nil, with: MastodonToken(host: "kept.example", accessToken: "newer-k", clientID: "c", clientSecret: "s"))
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        }

        await #expect(throws: (any Error).self) {
            try await packager(onto, tokens: watching).readBack(url, key: key, replacing: true) { _ in }
        }

        #expect(try onto.tokens.token(host: Self.host)?.accessToken == "newer", "a sign-in made during the undo was dropped")
        #expect(try onto.tokens.token(host: "kept.example")?.accessToken == "newer-k")
        #expect(try journal(onto.tokens) == ["wider replaced"])
        #expect(try journal(onto.tokens, at: "kept.example") == ["k replaced"])
    }

    @Test("A filing the Keychain refuses midway, with a sign-in made at the host meanwhile: the way back takes out only the package's own, puts nothing over the newer one, and leaves the sign-in the read back took out written down as replaced")
    func aNewerSignInStandsThroughAFilingRefused() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        try onto.tokens.save(Self.token("wider"))
        try onto.tokens.save(MastodonToken(host: "kept.example", accessToken: "k", clientID: "c", clientSecret: "s"))
        let kept = try #require(try onto.tokens.token(host: "kept.example"))
        // The package's sign-in goes in, the person signs in again at its host, and the
        // Keychain then refuses the package's registration.
        let inner = onto.tokens
        let watching = WatchedTokens(inner: inner) { _ = try? inner.swap(expecting: "t", with: Self.token("newer")) }
        watching.refusesRegistrations = true

        await #expect(throws: ForumCredentialError.keychain(-1)) {
            try await packager(onto, tokens: watching).readBack(url, key: key, replacing: true) { _ in }
        }

        #expect(try onto.tokens.token(host: Self.host)?.accessToken == "newer", "a sign-in made during the filing was dropped")
        #expect(try journal(onto.tokens) == ["wider replaced"])
        // Where nothing was signed in to meanwhile, what was held is back as it was.
        let other = try #require(try onto.tokens.token(host: "kept.example"))
        #expect(other == kept && other.stamp == kept.stamp)
        #expect(try journal(onto.tokens, at: "kept.example").isEmpty)
    }

    // MARK: - Never logged

    @Test("What rides of a sign-in is written by nothing but the sealed entry: the packager's file prints and logs no token, registration or journal entry")
    func neverLogged() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appending(path: "Sources/FediqoPersistence/StorePackager.swift"), encoding: .utf8)
        #expect(!source.contains("print("))
        #expect(!source.contains("dump("))
        for line in source.split(separator: "\n") where line.contains("NetLog.") {
            for word in ["token", "secret", "accessToken", "left", "entry", "previous", "fresh"] {
                #expect(!line.contains("\\(\(word)"), "\(line)")
            }
        }
    }

    private func packager(_ device: Device, tokens: any MastodonTokenStore) -> StorePackager {
        StorePackager(
            directory: device.directory, file: device.file, store: device.store, media: device.media, tokens: tokens,
            credentials: device.credentials, defaults: device.defaults, device: "a test", appVersion: "0.7.0",
            freeSpace: { _ in .max }, rounds: 1000
        )
    }
}

/// A Keychain over a memory one that notes, each time a sign-in is filed, what was journalled
/// at its host just then, and each time one is written down as left, which sign-in was held —
/// and runs `onFiled` the first time the package's sign-in is in.
private final class WatchedTokens: MastodonTokenStore, @unchecked Sendable {
    let inner: MemoryMastodonTokens
    private let onFiled: (@Sendable () -> Void)?
    /// Refuses the package's registration, as a Keychain that fails midway through a filing.
    var refusesRegistrations = false
    private let lock = NSLock()
    private var filings: [String: [String]] = [:]
    private var journalled: [String] = []
    private var ran = false

    init(inner: MemoryMastodonTokens, onFiled: (@Sendable () -> Void)? = nil) {
        self.inner = inner
        self.onFiled = onFiled
    }

    /// The journal at each host as it stood when the package's sign-in was first filed there.
    var journalAtFiling: [String: [String]] { lock.withLock { filings } }
    /// The token held at the moment each note of a sign-in left was taken.
    var heldAtJournal: [String] { lock.withLock { journalled } }

    func token(host: String) throws -> MastodonToken? { try inner.token(host: host) }
    func save(_ token: MastodonToken) throws {
        let first = lock.withLock { () -> Bool in
            guard token.packaged, filings[token.host] == nil else { return false }
            filings[token.host] = ((try? inner.left(host: token.host)) ?? []).map { "\($0.accessToken) \($0.state.rawValue)" }
            defer { ran = true }
            return !ran
        }
        try inner.save(token)
        if first { onFiled?() }
    }
    func forget(host: String) throws { try inner.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try inner.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try inner.grants() }
    func update(_ token: MastodonToken) throws -> Bool { try inner.update(token) }
    func swap(expecting held: String?, with token: MastodonToken) throws -> Bool { try inner.swap(expecting: held, with: token) }
    func left(host: String) throws -> [MastodonLeft] { try inner.left(host: host) }
    func leftHosts() throws -> Set<String> { try inner.leftHosts() }
    func journal(_ entry: MastodonLeft) throws {
        let held = try inner.token(host: entry.host)?.accessToken
        lock.withLock { journalled.append(held ?? "nothing") }
        try inner.journal(entry)
    }
    func unjournal(_ entry: MastodonLeft) throws { try inner.unjournal(entry) }
    func app(host: String) throws -> MastodonApp? { try inner.app(host: host) }
    func save(_ app: MastodonApp) throws {
        if refusesRegistrations, lock.withLock({ ran }) { throw ForumCredentialError.keychain(-1) }
        try inner.save(app)
    }
    func forgetApp(host: String) throws { try inner.forgetApp(host: host) }
}
