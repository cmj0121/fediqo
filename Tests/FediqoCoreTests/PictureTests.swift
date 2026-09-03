import Foundation
import Testing
@testable import FediqoCore

/// A post with a picture in it (#89).
///
/// Two things are worth asserting and neither is "the upload works". One is that **what a server
/// will refuse is found out before a byte goes up** — a reader who has waited for three
/// photographs and is then told the server takes two has spent their connection on being refused.
/// The other is that **a rule nobody stated is not enforced**, which is the same care `maxCharacters`
/// is treated with: a server that did not say has not said zero.
@Suite("A post with a picture in it")
struct PictureTests {
    private var client: MastodonClient { MastodonClient(session: stubbedSession()) }

    private func acting(on host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/users/ada", token: "t")
    }

    private func picture(_ name: String = "room.png", mime: String = "image/png",
                         bytes: Int = 8, description: String = "A reading room.") -> Draft.Picture {
        Draft.Picture(bytes: Data(repeating: 0x41, count: bytes), filename: name, mime: mime,
                description: description)
    }

    private func instance(_ host: String, kinds: [String]? = nil, size: Int? = nil,
                          most: Int? = nil) -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "", maxCharacters: 500,
                     mediaKinds: kinds, mediaSizeLimit: size, maxAttachments: most)
    }

    // MARK: - what is sent

    @Test("A picture goes up before the status that names it, with its description")
    func picturesGoFirst() async throws {
        let host = "picture-send.test"
        stubRoutes.on(host, "/api/v2/media", status: 200, body: "{ \"id\": \"77\" }")
        stubRoutes.on(host, "/api/v1/statuses", status: 200, body: """
        { "id": "9", "uri": "https://\(host)/users/ada/statuses/9", "url": null,
          "created_at": "2026-09-03T10:00:00.000Z", "content": "<p>here</p>",
          "account": { "id": "1", "url": "https://\(host)/@ada", "username": "ada",
                       "acct": "ada", "display_name": "Ada", "avatar": null },
          "media_attachments": [], "tags": [] }
        """)

        _ = try await client.publish(Draft(text: "here", pictures: [picture()]),
                                     as: acting(on: host))

        // The media request came first, and the status names what it answered with.
        #expect(stubRoutes.paths(for: host) == ["/api/v2/media", "/api/v1/statuses"])
        #expect(stubRoutes.requests(for: host, "/api/v1/statuses").first?
            .fields["media_ids[0]"] == "77")
    }

    /// It is not an afterthought that can be added later and forgotten: this app says out loud
    /// when a server sent a picture without one, so it would be a poor thing for it to send one.
    @Test("The description rides with the picture")
    func descriptionRidesAlong() async throws {
        let host = "picture-alt.test"
        stubRoutes.on(host, "/api/v2/media", status: 200, body: "{ \"id\": \"1\" }")

        _ = try await client.upload(picture(description: "A reading room."), as: acting(on: host))

        let body = try #require(stubRoutes.requests(for: host, "/api/v2/media").first?.body)
        #expect(body.contains("A reading room."))
        #expect(body.contains("filename=\"room.png\""))
        #expect(body.contains("Content-Type: image/png"))
    }

    /// A reader may decline to describe one. What is not allowed is the question never being
    /// asked — and an empty description is not sent as an empty one, which a server would keep.
    @Test("An empty description is not sent as an empty description")
    func emptyDescriptionIsNotSent() async throws {
        let host = "picture-nodesc.test"
        stubRoutes.on(host, "/api/v2/media", status: 200, body: "{ \"id\": \"1\" }")

        _ = try await client.upload(picture(description: "   "), as: acting(on: host))

        #expect(stubRoutes.requests(for: host, "/api/v2/media").first?
            .body.contains("name=\"description\"") == false)
    }

    // MARK: - what is refused, before anything goes up

    @Test("More pictures than the server takes is refused before the first byte")
    func tooManyIsRefusedFirst() async {
        let host = "picture-many.test"
        let refused = PostActions.refusal(of: Draft(text: "x", pictures: [picture(), picture(), picture()]), against: instance(host, most: 2))

        #expect(refused == .tooManyPictures(host, 2))
    }

    @Test("A picture larger than the server takes is refused, and named")
    func tooLargeIsRefused() async {
        let host = "picture-big.test"
        let refused = PostActions.refusal(of: Draft(text: "x", pictures: [picture(bytes: 4_000)]), against: instance(host, size: 1_000))

        #expect(refused == .pictureTooLarge(host, "room.png", 1_000))
    }

    @Test("A kind the server does not take is refused, and what it does take is carried along")
    func wrongKindIsRefused() async {
        let host = "picture-kind.test"
        let refused = PostActions.refusal(of: Draft(text: "x", pictures: [picture(mime: "image/heic")]), against: instance(host, kinds: ["image/png", "image/jpeg"]))

        #expect(refused == .pictureNotTaken(host, "room.png", ["image/png", "image/jpeg"]))
    }

    /// The same care `maxCharacters` gets. A composer that refused a picture because it had not
    /// been told a limit would be enforcing a rule nobody made.
    @Test("A rule the server did not state is not enforced")
    func silenceIsNotARule() async {
        let host = "picture-silent.test"
        let big = Draft(text: "x", pictures: [picture(bytes: 50_000_000), picture(mime: "image/heic")])

        #expect(PostActions.refusal(of: big, against: instance(host)) == nil)
    }

    /// An empty list of kinds is a server that said nothing useful, not one that takes nothing.
    @Test("An empty list of kinds refuses nothing")
    func emptyKindsRefuseNothing() async {
        let host = "picture-empty-kinds.test"
        #expect(PostActions.refusal(of: Draft(text: "x", pictures: [picture(mime: "image/heic")]), against: instance(host, kinds: [])) == nil)
    }

    /// A picture with no words is a post. The composer's own check reads this, so a reader who
    /// has attached a photograph and written nothing can still send it.
    @Test("A picture with no words is something to send")
    func aPictureAloneIsAPost() {
        #expect(Draft(text: "", pictures: [picture()]).carries)
        #expect(!Draft(text: "   ").carries)
    }
}
