import Foundation
import Testing
@testable import FediqoCore

/// #335 in Core: a link's preview read off a status, cleaned and bounded, kept with the post by the
/// rules its other facts are, and never lost to a read that was on its way before the source's
/// worker attached it. The card is a real server's (`MastodonCardCaptures`).
@Suite("A link's preview kept with its post")
struct PostCardTests {
    private static let source = Source(host: "social.example", kind: .mastodon)

    private static func status(card: String? = nil, edited: String? = nil, id: String = "9") -> String {
        let said = card.map { #","card":\#($0)"# } ?? #","card":null"#
        let change = edited.map { #","edited_at":"\#($0)""# } ?? ""
        return """
        {"id":"\(id)","uri":"https://social.example/users/ada/statuses/\(id)","created_at":"2024-06-01T00:00:00.000Z",
         "content":"<p>see http://card.example.com/</p>","visibility":"public"\(said)\(change),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func held(_ json: String, sent: ReadMoment = .now()) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8)).asNote(source: source, category: .home, sent: sent)
    }

    private static func card(_ fields: String) -> String { "{\(fields)}" }

    @Test("A real server's card reads as its preview: title, words, who publishes it, its picture and size and that no author is missing; an http page leads nowhere and keeps its words")
    func aRealCard() throws {
        let card = try #require(try Self.held(Self.status(card: MastodonCardCaptures.card)).card)
        #expect(card.title == "A page with a preview")
        #expect(card.description == "A page this machine serves, for a post to link to and gain a card.")
        #expect(card.provider == "Fediqo fixture" && card.author == nil && card.missingAttribution == false)
        #expect(card.url == nil, "http is no link this app follows")
        #expect(card.image?.absoluteString == "https://mastodon.localhost/system/cache/preview_cards/images/000/000/002/original/3ae146e878f57d7e.png")
        #expect(card.width == 64 && card.height == 32)
        #expect(try Self.held(Self.status()).card == nil, "a post with none reads as before")
    }

    @Test("A card is cleaned and bounded where it is read: markup and entities out, one line each, cut to its length; no title is no card; a page and a picture this device would not go to are none; a size is both sides or none; the authors stand in for an empty author; and a card of another shape costs the card and never the post")
    func cleanedAndBounded() throws {
        func card(_ fields: String) throws -> PostCard? { try Self.held(Self.status(card: Self.card(fields))).card }
        let long = String(repeating: "word ", count: 200)
        let made = try #require(try card(#"""
            "url":"https://example.org/page","title":"<b>Tom &amp; Jerry</b>\nagain","description":"\#(long)",
            "provider_name":"Site‮name","author_name":"","authors":[{"name":"Ada Lovelace"}],
            "image":"https://example.org/p.png","width":800,"height":-1,"missing_attribution":true
            """#))
        #expect(made.title == "Tom & Jerry again")
        #expect(made.description?.count == PostCard.descriptionLength + 1 && made.description?.hasSuffix("…") == true, "cut, and said to be")
        #expect(made.provider == "Sitename" && made.author == "Ada Lovelace" && made.missingAttribution == true)
        #expect(made.url?.absoluteString == "https://example.org/page" && made.image != nil)
        #expect(made.width == nil && made.height == nil, "one side alone is no shape")
        // No title of its own: called by the host it leads to, where it leads anywhere followed.
        #expect(try card(#""title":"   ","url":"https://example.org/""#)?.title == "example.org")
        #expect(try card(#""title":"","url":"http://example.org/","description":"only words""#) == nil, "leads nowhere, called nothing")
        #expect(try card(#""description":"only words""#) == nil)
        let refused = try #require(try card(#""title":"t","url":"javascript:alert(1)","image":"http://example.org/p.png","author_name":"Named","authors":[{"name":"Other"}]"#))
        #expect(refused.url == nil && refused.image == nil && refused.author == "Named")
        #expect(try card(#""title":"t","url":"https://user:pw@example.org/""#)?.url == nil)
        #expect(try card(#""title":"t","width":99999,"height":10"#)?.width == nil)
        // Addresses bounded before they are parsed, and a picture never carries credentials.
        let far = "https://example.org/" + String(repeating: "a", count: PostCard.addressLength)
        let bounded = try #require(try card(#""title":"t","url":"\#(far)","image":"\#(far).png""#))
        #expect(bounded.url == nil && bounded.image == nil)
        #expect(try card(#""title":"t","image":"https://user:pw@example.org/p.png""#)?.image == nil)
        #expect(try card(#""title":"t","image":"https://example.org/p.png""#)?.image != nil)
        for odd in [#""a card""#, "[1,2]", "7"] {
            let note = try Self.held(Self.status(card: odd))
            #expect(note.card == nil && note.body.contains("card.example.com"), "\(odd)")
        }
    }

    @Test("A picture's card, as an oEmbed provider sends one — no title, no words — is kept where it leads somewhere followed, called by that host, and weighs in the post's words")
    func aPictureCard() throws {
        let photo = #"""
        {"url":"https://photos.example/p/1","title":"","description":"","language":null,"type":"photo","author_name":"",
         "author_url":"","provider_name":"Photos","provider_url":"https://photos.example/","html":"","width":640,"height":480,
         "image":"https://photos.example/p/1.jpg","image_description":"","embed_url":"https://photos.example/p/1.jpg",
         "blurhash":null,"published_at":null,"authors":[],"missing_attribution":false}
        """#
        let note = try Self.held(Self.status(card: photo))
        let card = try #require(note.card)
        #expect(card.title == "photos.example" && card.description == nil && card.provider == "Photos")
        #expect(card.url?.absoluteString == "https://photos.example/p/1" && card.width == 640 && card.height == 480)
        let bare = try Self.held(Self.status())
        #expect(note.wordBytes == bare.wordBytes + "photos.example".utf8.count + "Photos".utf8.count)
    }

    @Test("A reblog carries no card of its own; the post it brings keeps its own")
    func aReblog() throws {
        let wrapper = """
        {"id":"500","uri":"https://social.example/users/me/statuses/500/activity","created_at":"2024-06-02T00:00:00.000Z",
         "content":"","visibility":"public","account":{"username":"me","acct":"me","display_name":"Me"},
         "card":\(MastodonCardCaptures.card),"reblog":\(Self.status(card: MastodonCardCaptures.card))}
        """
        let arrived = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(wrapper.utf8))
            .arrival(source: Self.source, categories: [.home], sent: .now())
        #expect(arrived.item.card == nil && arrived.reblogged?.card?.title == "A page with a preview")
    }

    @Test("The card the worker attached after the post lands on its row; a read sent before it landed, and a copy of the post arriving again with none, take nothing away; the post changed to link nothing takes it off")
    func keptWithItsRow() async throws {
        let store = ItemStore()
        await store.add(Self.source)
        let early = ReadMoment.now()
        let bare = try Self.held(Self.status())
        await store.ingest([bare])
        #expect(await store.note(bare.key)?.card == nil)

        let withCard = try Self.held(Self.status(card: MastodonCardCaptures.card))
        #expect(await store.refresh([withCard], ifSourceHere: Self.source.host))
        #expect(await store.note(bare.key)?.card?.title == "A page with a preview")

        // A read on its way since before the card: what it says of the card is nothing.
        let onItsWay = try Self.held(Self.status(), sent: early)
        await store.refresh([onItsWay], ifSourceHere: Self.source.host)
        #expect(await store.note(bare.key)?.card?.title == "A page with a preview")
        await store.ingest([try Self.held(Self.status())])
        #expect(await store.note(bare.key)?.card?.title == "A page with a preview")
        // Arriving first without one and later with one fills it.
        #expect(bare.filled(from: withCard).card == withCard.card)

        let changed = try Self.held(Self.status(edited: "2024-06-03T00:00:00.000Z"))
        await store.refresh([changed], ifSourceHere: Self.source.host)
        #expect(await store.note(bare.key)?.card == nil, "the change took the link out")
    }
}
