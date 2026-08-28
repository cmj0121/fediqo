import Foundation
import Testing
import GRDB
@testable import FediqoCore

@Suite("A post partly written in pictures")
struct EmojiTests {
    private let blobcat = CustomEmoji(shortcode: "blobcat", url: URL(string: "https://one.example/blobcat.png")!,
                                      staticURL: URL(string: "https://one.example/blobcat-still.png")!)
    private let party = CustomEmoji(shortcode: "party", url: URL(string: "https://one.example/party.png")!)

    @Test("A post with no emoji is one run of text, whatever colons are in it")
    func nothingToReplace() {
        #expect(CustomEmoji.runs(in: "10:30, and no pictures", from: []) == [.text("10:30, and no pictures")])
        #expect(CustomEmoji.runs(in: "", from: [blobcat]) == [])
    }

    @Test("A shortcode we were given a picture for becomes the picture")
    func replaced() {
        #expect(CustomEmoji.runs(in: "hello :blobcat: there", from: [blobcat])
                == [.text("hello "), .emoji(blobcat), .text(" there")])
    }

    @Test("A shortcode nobody sent a picture for stays the text it is")
    func unknownShortcodeSurvives() {
        #expect(CustomEmoji.runs(in: "hello :nosuch: there", from: [blobcat])
                == [.text("hello :nosuch: there")])
    }

    @Test("Two in a row, and one at each end")
    func adjacent() {
        #expect(CustomEmoji.runs(in: ":blobcat::party:", from: [blobcat, party])
                == [.emoji(blobcat), .emoji(party)])
        #expect(CustomEmoji.runs(in: ":party: says :blobcat:", from: [blobcat, party])
                == [.emoji(party), .text(" says "), .emoji(blobcat)])
    }

    @Test("A colon on its own, and a time, are text")
    func lonelyColons() {
        #expect(CustomEmoji.runs(in: "::", from: [blobcat]) == [.text("::")])
        #expect(CustomEmoji.runs(in: "at 10:30 :blobcat:", from: [blobcat])
                == [.text("at 10:30 "), .emoji(blobcat)])
    }

    @Test("The colon that closes one shortcode can open the next")
    func sharedColon() {
        // ":blobcat:party:" is blobcat, then the literal "party:" — the middle colon closes
        // the first and what follows it is not a shortcode until another colon arrives.
        #expect(CustomEmoji.runs(in: ":blobcat:party:", from: [blobcat, party])
                == [.emoji(blobcat), .text("party:")])
    }

    @Test("What a person typed with their own keyboard is never touched")
    func unicodeEmojiSurvive() {
        let typed = "👩‍👩‍👧‍👦 🇹🇼 👍🏽 :blobcat:"
        #expect(CustomEmoji.runs(in: typed, from: [blobcat])
                == [.text("👩‍👩‍👧‍👦 🇹🇼 👍🏽 "), .emoji(blobcat)])
    }

    @Test("One shortcode is one picture: the words' spelling wins over the name's")
    func foldedByShortcode() {
        let fromTheName = CustomEmoji(shortcode: "blobcat", url: URL(string: "https://two.example/other.png")!)
        let post = Post(uri: "https://one.example/1", socialProtocol: .mastodon, sourceURL: "https://one.example",
                        createdAt: .now, authorId: "a", authorName: "A", authorHandle: "@a@one.example",
                        text: ":blobcat:", emojis: [blobcat, fromTheName, party])
        #expect(post.emojis == [blobcat, party])
    }

    @Test("A status carries its own emoji and its author's, and drops the ones with no picture")
    func decoded() throws {
        let json = """
        {"id": "1", "uri": "https://one.example/users/a/statuses/1", "url": null,
         "created_at": "2026-08-28T00:00:00.000Z", "content": "<p>:blobcat: :party:</p>",
         "media_attachments": [],
         "emojis": [{"shortcode": "blobcat", "url": "https://one.example/blobcat.png",
                     "static_url": "https://one.example/blobcat-still.png"},
                    {"shortcode": "broken", "url": null, "static_url": null}],
         "account": {"id": "a", "url": "https://one.example/users/a", "username": "a", "acct": "a",
                     "display_name": ":party: A", "avatar": null,
                     "emojis": [{"shortcode": "party", "url": "https://one.example/party.png",
                                 "static_url": null}]}}
        """
        // The client's own decoder, for the reason MastodonDecodingTests gives: date handling
        // is part of reading a status.
        let status = try MastodonClient.decoder.decode(MastodonDTO.Status.self, from: Data(json.utf8))
        let post = status.asPost(from: "one.example")
        #expect(post.emojis == [blobcat, party])
    }

    @Test("The pictures go into the store on the first read and come back with the post")
    func storedAndRead() async throws {
        let store = try LocalStore.inMemory()
        let server = makeServer("one.example")
        let plain = makePost(uri: "https://one.example/1", at: 100)
        let post = Post(uri: plain.uri, socialProtocol: .mastodon, sourceURL: plain.sourceURL,
                        createdAt: plain.createdAt, authorId: plain.authorId, authorName: plain.authorName,
                        authorHandle: plain.authorHandle, text: ":blobcat: hello :party:",
                        emojis: [blobcat, party])
        try await store.save([post], from: server)

        let rows = try await store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT shortcode, url, static_url FROM post_emojis WHERE merge_key = ? ORDER BY rowid
                """, arguments: [post.mergeKey])
                .map { ($0["shortcode"] as String, $0["url"] as String, $0["static_url"] as String?) }
        }
        #expect(rows.map(\.0) == ["blobcat", "party"])
        // A server that sent no still is a NULL, not the moving one written down twice.
        #expect(rows[1].2 == nil)

        let read = try await store.timeline().first
        #expect(read?.emojis == [blobcat, party])
    }

    @Test("A post stored before 008 draws its shortcodes as the text they are")
    func nothingIsBackfilled() async throws {
        let store = try LocalStore.inMemory()
        let server = makeServer("one.example")
        let plain = makePost(uri: "https://one.example/1", at: 100)
        let post = Post(uri: plain.uri, socialProtocol: .mastodon, sourceURL: plain.sourceURL,
                        createdAt: plain.createdAt, authorId: plain.authorId, authorName: plain.authorName,
                        authorHandle: plain.authorHandle, text: "hello :blobcat:")
        try await store.save([post], from: server)

        let read = try await store.timeline().first
        #expect(read?.emojis.isEmpty == true)
        #expect(CustomEmoji.runs(in: read?.text ?? "", from: read?.emojis ?? []) == [.text("hello :blobcat:")])
    }
}
