import Foundation
import Testing

@testable import FediqoCore

/// What counts as the same post (#113).
///
/// **The copies are decoded from statuses rather than built by hand** wherever the answer turns
/// on what a server said. The claim under test is that the fact comes off the wire — that two
/// instances carrying one post send one name for it — and a `Note` written out in Swift with the
/// same string in two places would assert nothing about that at all.
@Suite("The same post")
struct SamePostTests {
    private let first = Source(host: "first.example", kind: .mastodon)
    private let second = Source(host: "second.example", kind: .mastodon)

    @Test("One post held from two sources is one post, and still two copies underneath")
    func twoSourcesOnePost() throws {
        // The same status, read from two instances. Each gave it its own local id; neither
        // minted the `uri`, because the server Ada wrote it on did.
        let here = try note(status(id: "100", uri: Self.written), from: first)
        let there = try note(status(id: "88291", uri: Self.written), from: second)

        #expect(here.post == there.post)
        #expect(SamePost.gathered([here, there]).map { $0.map(\.source.host) } == [
            ["first.example", "second.example"],
        ])
        // What #10 settled is untouched: the copies are still two rows in the store.
        #expect(here.key != there.key)
    }

    @Test("A post and a boost of it are one post; two people boosting it are still one")
    func aBoostCarriesThePost() throws {
        let original = try note(status(id: "100", uri: Self.written), from: first)
        let boosted = try note(
            boost(
                id: "500", uri: "https://first.example/users/bob/statuses/500",
                of: status(id: "100", uri: Self.written)
            ),
            from: first
        )
        let boostedElsewhere = try note(
            boost(
                id: "77", uri: "https://second.example/users/cyd/statuses/77",
                of: status(id: "88291", uri: Self.written)
            ),
            from: second
        )

        #expect(original.post == boosted.post)
        #expect(original.post == boostedElsewhere.post)
        #expect(SamePost.gathered([original, boosted, boostedElsewhere]).count == 1)
        // The boost's own name is not what was answered with. Two of them are in play here and
        // neither reached the answer.
        #expect(boosted.post?.stated == Self.written)
    }

    @Test("Two posts with the same words by different people are two posts")
    func samewordsDifferentPeople() throws {
        let ada = try note(
            status(id: "1", uri: Self.written, content: "<p>the same sentence</p>", who: "ada"),
            from: first
        )
        let bob = try note(
            status(
                id: "2", uri: "https://first.example/users/bob/statuses/2",
                content: "<p>the same sentence</p>", who: "bob"
            ),
            from: first
        )

        #expect(ada.body == bob.body)
        #expect(ada.post != bob.post)
        #expect(SamePost.gathered([ada, bob]).count == 2)
    }

    @Test("Two posts with the same words by the same author, written twice, are two posts")
    func onePersonWroteItTwice() throws {
        let monday = try note(status(id: "1", uri: Self.written, content: "<p>again</p>"), from: first)
        let tuesday = try note(
            status(id: "2", uri: "https://first.example/users/ada/statuses/2", content: "<p>again</p>"),
            from: first
        )

        #expect(monday.body == tuesday.body && monday.handle == tuesday.handle)
        #expect(monday.post != tuesday.post)
        #expect(SamePost.gathered([monday, tuesday]).count == 2)
    }

    @Test("The answer is the same whichever order the copies arrived in")
    func orderDoesNotDecide() throws {
        let bob = "https://first.example/users/bob/statuses/7"
        let copies = [
            try note(status(id: "100", uri: Self.written), from: first),
            try note(status(id: "88291", uri: Self.written), from: second),
            try note(status(id: "7", uri: bob), from: first),
        ]
        // Which copies are together, said without saying anything about their order.
        let expected: Set<Set<String>> = [
            [NoteKey(host: "first.example", id: Self.written).rowID,
             NoteKey(host: "second.example", id: Self.written).rowID],
            [NoteKey(host: "first.example", id: bob).rowID],
        ]

        for order in Self.everyOrder(of: copies) {
            let gathered = Set(SamePost.gathered(order).map { Set($0.map(\.key.rowID)) })
            #expect(gathered == expected)
        }
    }

    @Test("A third copy joins the post it names, and leaves the two already there together")
    func aThirdArrives() throws {
        let third = Source(host: "third.example", kind: .pleroma)
        let two = [
            try note(status(id: "100", uri: Self.written), from: first),
            try note(status(id: "88291", uri: Self.written), from: second),
        ]
        let late = try note(status(id: "4", uri: Self.written), from: third)

        #expect(SamePost.gathered(two).map { $0.map(\.source.host) } == [
            ["first.example", "second.example"],
        ])
        #expect(SamePost.gathered(two + [late]).map { $0.map(\.source.host) } == [
            ["first.example", "second.example", "third.example"],
        ])
    }

    @Test("Nothing in the answer is a number: the words decide neither way")
    func noThreshold() throws {
        // Everything a reader sees differs — the words, the name, the picture, the cover, the
        // hour it was posted — and the two are one post, because their servers said so.
        let plain = try note(status(id: "100", uri: Self.written), from: first)
        let elsewhere = try note(
            """
            {
              "id": "88291",
              "uri": "\(Self.written)",
              "created_at": "2024-06-06T09:00:00.000Z",
              "content": "<p>nothing whatever like the other copy</p>",
              "spoiler_text": "a cover this instance put on it",
              "sensitive": true,
              "account": { "username": "ada", "acct": "ada@first.example", "display_name": "Ada Lovelace" }
            }
            """,
            from: second
        )
        #expect(plain.body != elsewhere.body && plain.author != elsewhere.author)
        #expect(plain.post == elsewhere.post)

        // And the other way about: identical to the character but for the name, and two posts.
        let twin = try note(
            status(id: "100", uri: "https://first.example/users/ada/statuses/101"), from: first
        )
        #expect(twin.body == plain.body && twin.author == plain.author && twin.postedAt == plain.postedAt)
        #expect(twin.post != plain.post)
    }

    @Test("A copy whose server named no post is merged with nothing")
    func nothingStatedIsNothingMerged() throws {
        let unnamed = try note(
            """
            {
              "id": "100",
              "created_at": "2024-01-01T00:00:00.000Z",
              "content": "<p>x</p>",
              "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
            }
            """,
            from: first
        )
        #expect(unnamed.post == nil)
        // Not even with itself read a second time, which is the honest answer: this device was
        // told no name for it, so it can show nothing to be that post.
        #expect(SamePost.gathered([unnamed, unnamed]).count == 2)
        #expect(unnamed.id == Note.inventedID(host: "first.example", statusID: "100"))
    }

    @Test("A forum names its own and nobody else's")
    func aForumSpeaksForItself() {
        let here = topic(host: "forum.example", id: 7, title: "the same title")
        let there = topic(host: "other.example", id: 7, title: "the same title")

        #expect(here.title == there.title)
        #expect(here.post != there.post)
        #expect(SamePost.gathered([here, there]).count == 2)
        // Read twice off the same forum it is the one topic, as it already was.
        #expect(SamePost.gathered([here, here]).count == 1)
    }

    @Test("Gathering hands back the order it was given, and re-orders nothing")
    func orderIsTheCallersOwn() throws {
        let one = try note(status(id: "1", uri: "https://first.example/users/ada/statuses/1"), from: first)
        let two = try note(status(id: "2", uri: Self.written), from: first)
        let twoAgain = try note(status(id: "9", uri: Self.written), from: second)

        #expect(SamePost.gathered([two, one, twoAgain]).map { $0.map(\.id) } == [
            [Self.written, Self.written],
            ["https://first.example/users/ada/statuses/1"],
        ])
    }

    /// The name the post was minted under, on the server Ada wrote it on.
    private static let written = "https://first.example/users/ada/statuses/100"

    private func note(_ json: String, from source: Source) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .public)
    }

    /// One status, in the fields this suite turns on. `uri` is the fact; `id` is what the
    /// instance that handed it over calls it locally, and differs per instance on purpose.
    private func status(
        id: String,
        uri: String,
        content: String = "<p>the post itself</p>",
        who: String = "ada"
    ) -> String {
        """
        {
          "id": "\(id)",
          "uri": "\(uri)",
          "created_at": "2024-06-06T09:00:00.000Z",
          "content": "\(content)",
          "account": { "username": "\(who)", "acct": "\(who)@first.example", "display_name": "\(who)" }
        }
        """
    }

    /// Somebody's boost of `inner`: a status of its own, wrapped round the post it carries.
    private func boost(id: String, uri: String, of inner: String) -> String {
        """
        {
          "id": "\(id)",
          "uri": "\(uri)",
          "created_at": "2024-06-07T09:00:00.000Z",
          "content": "",
          "account": { "username": "bob", "acct": "bob", "display_name": "Bob" },
          "reblog": \(inner)
        }
        """
    }

    private func topic(host: String, id: Int, title: String) -> Note {
        Note(
            id: "discourse:\(host):\(id)",
            source: Source(host: host, kind: .discourse),
            author: "Ada",
            handle: "@ada@\(host)",
            body: "",
            title: title,
            postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: []
        )
    }

    private static func everyOrder(of notes: [Note]) -> [[Note]] {
        guard notes.count > 1 else { return [notes] }
        return notes.indices.flatMap { at -> [[Note]] in
            var rest = notes
            let taken = rest.remove(at: at)
            return everyOrder(of: rest).map { [taken] + $0 }
        }
    }
}
