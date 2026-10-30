import Foundation
import Testing
@testable import FediqoCore

/// #433, in the half of it Core holds: a collection made, changed and removed, who is in it, and
/// taking oneself out — read from what a real 4.6.6 answered (`MastodonCollectionCaptures`).
@Suite("Collections made and tended at a Mastodon")
struct MastodonCollectionWritesTests {
    private typealias Captures = MastodonCollectionCaptures

    private static let origin = "https://\(Captures.host)"
    private static let reading = "read:statuses read:lists read:accounts"
    private static let whole = reading + " read:collections write:collections"
    private static let source = Source(host: Captures.host, kind: .mastodon)

    private func door(
        _ routes: [String: FormServer.Answer], scopes: String? = MastodonCollectionWritesTests.whole
    ) throws -> (MastodonCollectionWrites, FormServer) {
        let server = FormServer(routes)
        let token = MastodonToken(host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret", scopes: scopes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return (MastodonCollectionWrites(door: MastodonAuthorized(token: token, sender: server, store: tokens)), server)
    }

    private func asked(_ server: FormServer) async -> [String] {
        await server.asked.map { "\($0.method) \($0.address) [\($0.form)]" }
    }

    @Test("Collections are a part of two words, standing without acting, with a half that sees and a half that changes; tending is still the last part")
    func thePart() {
        #expect(MastodonPart.collections.words == ["read:collections", "write:collections"])
        #expect(!MastodonPart.collections.rider && !MastodonPart.collections.needsActing && MastodonPart.collections.wordsBesideActing.isEmpty)
        #expect(MastodonPart.allCases.last == .tending)
        #expect(MastodonParts.half(of: .collections, in: "read:collections") == .seeing)
        #expect(MastodonParts.half(of: .collections, in: "write:collections") == .changing)
        #expect(MastodonParts.page(held: nil, ticked: [.collections], readOnly: true) == "read:collections")
        #expect(MastodonParts.unknown(in: Self.whole).isEmpty)
    }

    @Test("Making sends the name, both choices and what words there are, and what the source made comes back with them")
    func making() async throws {
        let (writes, server) = try door(["POST /api/v1/collections": .init(body: Captures.created)])
        let made = try await writes.make(CollectionDraft(name: " Friends ", words: "People worth reading"))
        #expect(made.name == "Friends" && made.words == "People worth reading" && made.sensitive == false && made.discoverable == true && made.count == 0)
        let form = try #require(await server.asked.first?.form)
        #expect(form.contains("name=Friends") && form.contains("sensitive=false") && form.contains("discoverable=true"))
        #expect(form.contains("description=People") && !form.contains("account_ids"))
    }

    @Test("One not to be found is read as not to be found, and its empty words are nothing")
    func hidden() async throws {
        let (writes, _) = try door(["POST /api/v1/collections": .init(body: Captures.hiddenCreated)])
        let made = try await writes.make(CollectionDraft(name: "Hidden", discoverable: false))
        #expect(made.discoverable == false && made.words == nil)
    }

    @Test("A change sends what differs and nothing else; nothing differing sends nothing; a description emptied is sent empty and comes back nothing")
    func changing() async throws {
        let (writes, server) = try door(["PATCH /api/v1/collections/9": .init(body: Captures.changed)])
        let before = CollectionDraft(name: "Friends", words: "People worth reading")
        var after = before
        await #expect(throws: MastodonCollectionError.invalid) { try await writes.change("9", from: before, to: after) }
        #expect(await server.asked.isEmpty)
        after.words = ""
        let changed = try await writes.change("9", from: before, to: after)
        #expect(await asked(server) == ["PATCH \(Self.origin)/api/v1/collections/9 [description=]"])
        #expect(changed.name == "Friends renamed" && changed.words == nil)
    }

    @Test("Removing, taking out and revoking each go to their own address, and the source's empty answer is taken")
    func removals() async throws {
        let (writes, server) = try door([
            "DELETE /api/v1/collections/9": .init(body: ""),
            "DELETE /api/v1/collections/9/items/5": .init(body: ""),
            "POST /api/v1/collections/9/items/5/revoke": .init(body: ""),
        ])
        try await writes.remove("9")
        try await writes.drop("5", from: "9")
        try await writes.leave("5", from: "9")
        #expect(await server.asked.map { "\($0.method) \($0.address)" } == [
            "DELETE \(Self.origin)/api/v1/collections/9",
            "DELETE \(Self.origin)/api/v1/collections/9/items/5",
            "POST \(Self.origin)/api/v1/collections/9/items/5/revoke",
        ])
    }

    @Test("Adding someone says their place and how it stands, by the id a removal goes by")
    func adding() async throws {
        let (writes, server) = try door(["POST /api/v1/collections/9/items": .init(body: Captures.itemAdded)])
        let item = try await writes.add(Captures.bob, to: "9")
        #expect(item == CollectionItem(id: "117532232938512782", accountID: Captures.bob, state: .accepted))
        #expect(await server.asked.first?.form == "account_id=\(Captures.bob)")
    }

    @Test("The owner's signed list holds the one not to be found, where the unsigned one does not")
    func theOwnersList() async throws {
        let path = "/api/v1/accounts/\(Captures.owner)/collections"
        let (writes, server) = try door(["GET \(path)?limit=100": .init(body: Captures.ownList)])
        let own = try await writes.of(Captures.owner)
        #expect(own.contains { $0.discoverable == false } && own.contains { $0.discoverable == true })
        #expect(await server.asked.first?.bearer == "Bearer tok-123")
        let http = FixtureHTTP(["\(Self.origin)\(path)": .text(Captures.listUnsigned)])
        let unsigned = try await MastodonCollections(http: http, host: Captures.host).of(Captures.owner, source: Self.source)
        #expect(unsigned.allSatisfy { $0.discoverable == true } && !unsigned.isEmpty)
    }

    @Test("Its owner's read shows who is pending, each with the place they are removed by; anyone else's shows only who accepted, and the people(in:) of old are the same people")
    func pendingForTheOwner() async throws {
        let (writes, _) = try door(["GET /api/v1/collections/9": .init(body: Captures.pendingAsOwner)])
        let owners = try await writes.whole("9", source: Self.source)
        #expect(owners.collection.count == 2)
        #expect(owners.members.map(\.item.state) == [.pending, .accepted])
        #expect(owners.members.first?.person.accountID == Captures.bob)
        #expect(owners.members.allSatisfy { !$0.item.id.isEmpty })

        let (others, _) = try door(["GET /api/v1/collections/9": .init(body: Captures.pendingAsAnother)])
        let another = try await others.whole("9", source: Self.source)
        #expect(another.collection.count == 1 && another.members.map(\.item.state) == [.accepted])

        let http = FixtureHTTP(["\(Self.origin)/api/v1/collections/9": .text(Captures.pendingAsAnother)])
        let people = try await MastodonCollections(http: http, host: Captures.host).people(in: "9", source: Self.source)
        #expect(people.map(\.accountID) == another.members.map(\.person.accountID))
    }

    @Test("A sign-in without the word sends nothing: a write without the half that changes, a read without the half that sees")
    func locked() async throws {
        let (noWrite, wrote) = try door([:], scopes: Self.reading + " read:collections")
        await #expect(throws: MastodonCollectionError.locked) { try await noWrite.make(CollectionDraft(name: "x")) }
        await #expect(throws: MastodonCollectionError.locked) { try await noWrite.leave("5", from: "9") }
        #expect(await wrote.asked.isEmpty)
        let (noRead, read) = try door([:], scopes: Self.reading + " write:collections")
        await #expect(throws: MastodonCollectionError.locked) { try await noRead.of(Captures.owner) }
        #expect(await read.asked.isEmpty)
    }

    @Test("What the source refuses is said as it says it, in either shape of a 422: too long, blank, over 25 people, someone already in")
    func refusals() async throws {
        for (body, sentence) in [
            (Captures.tooLong, "Validation failed: Name is too long (maximum is 40 characters)"),
            (Captures.wordsTooLong, "Validation failed: Description is too long (maximum is 100 characters)"),
            (Captures.blank, "Validation failed: Name can't be blank"),
            (Captures.overPeople, "Validation failed: Collection items are too many, no more than 25 are allowed"),
            (Captures.alreadyIn, "Validation failed: Account has already been taken"),
        ] {
            let (writes, _) = try door(["POST /api/v1/collections": .init(body: body, status: 422)])
            await #expect(throws: MastodonCollectionError.refused(sentence: sentence)) { try await writes.make(CollectionDraft(name: "x")) }
        }
    }

    @Test("An eleventh collection is said as too many: the source's own sentence is its failure to find one")
    func tooMany() async throws {
        let (writes, _) = try door(["POST /api/v1/collections": .init(body: Captures.tooManyCollections, status: 422)])
        await #expect(throws: MastodonCollectionError.tooMany) { try await writes.make(CollectionDraft(name: "x")) }
    }

    @Test("A sign-in the source says lacks the word, a person not allowed this, and what is gone, are told apart")
    func refusedApart() async throws {
        let (scope, _) = try door(["DELETE /api/v1/collections/9": .init(body: Captures.outOfScope, status: 403, authenticate: Captures.outOfScopeHeader)])
        await #expect(throws: MastodonCollectionError.outOfScope) { try await scope.remove("9") }
        let (notAllowed, _) = try door(["DELETE /api/v1/collections/9": .init(body: Captures.notAllowed, status: 403)])
        await #expect(throws: MastodonCollectionError.notAllowed) { try await notAllowed.remove("9") }
        let (gone, _) = try door(["DELETE /api/v1/collections/9": .init(body: Captures.notFound, status: 404)])
        await #expect(throws: MastodonCollectionError.gone) { try await gone.remove("9") }
    }

    @Test("A 2xx that is no collection is told from a refusal as taken and unreadable, a 422 that cannot be read is unreadable, and a blank name or an id unfit for a path sends nothing")
    func theEdges() async throws {
        let (writes, server) = try door(["POST /api/v1/collections": .init(body: #"{"collection":{"id":"a/b"}}"#)])
        await #expect(throws: MastodonCollectionError.tookUnreadable) { try await writes.make(CollectionDraft(name: "x")) }
        #expect(MastodonCollectionWrites.refusal(from: Data("<html>".utf8)) == .unreadable)
        let before = await server.asked.count
        await #expect(throws: MastodonCollectionError.invalid) { try await writes.make(CollectionDraft(name: "  ")) }
        await #expect(throws: MastodonCollectionError.invalid) { try await writes.remove("../9") }
        await #expect(throws: MastodonCollectionError.invalid) { try await writes.leave("a/b", from: "9") }
        #expect(await server.asked.count == before)
    }
}
