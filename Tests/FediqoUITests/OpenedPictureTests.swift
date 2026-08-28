import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// The picture, opened over the app. The deck used to say there was no such thing on purpose;
/// #41 overturned that, and what is tested here is the part that had to survive it — one press
/// out, nothing left playing, and the keys still meaning what they meant in the row.
@Suite("A picture, at the size of the app")
@MainActor
struct OpenedPictureTests {
    private func post(_ id: String, media: Int = 0, covered: Bool = false) -> Post {
        Post(uri: "https://one.example/api/v1/statuses/\(id)",
             originURI: "https://one.example/users/a/statuses/\(id)",
             socialProtocol: .mastodon, sourceURL: "https://one.example",
             createdAt: Date(timeIntervalSince1970: 100), authorId: "https://one.example/@a",
             authorName: "A", authorHandle: "@a@one.example", text: id,
             attachments: (0..<media).map { index in
                 Attachment(kind: .image, url: URL(string: "https://one.example/m/\(id)-\(index).jpg"))
             },
             sensitive: covered ? true : nil,
             webURL: URL(string: "https://one.example/@a/\(id)"))
    }

    private func timeline(_ name: String, _ posts: [Post]) -> AppState {
        let app = freshApp(name)
        app.railItem = .timeline
        app.currentTimeline = "public"
        app.feed(for: .publicFixture).show(posts)
        return app
    }

    @Test("v opens what is attached, and only where there is something attached")
    func opensWhereThereIsSomething() {
        let app = timeline("open-media", [post("a", media: 2), post("b")])
        #expect(app.perform(.nextPost))
        #expect(app.perform(.openMedia))
        #expect(app.viewing?.attachments.count == 2)
        // At the front of the deck: which card the row has on top is the row's answer.
        #expect(app.viewing?.index == 0)

        // A post with nothing attached has nothing to open, and the press says so.
        #expect(app.perform(.dismiss))
        #expect(app.perform(.nextPost))
        #expect(app.perform(.openMedia) == false)
        #expect(app.viewing == nil)
    }

    @Test("The same key closes it, and so does Escape")
    func oneWayInAndTwoWaysOut() {
        let app = timeline("close-media", [post("a", media: 1)])
        #expect(app.perform(.nextPost))
        #expect(app.perform(.openMedia))
        #expect(app.perform(.openMedia))
        #expect(app.viewing == nil)

        #expect(app.perform(.openMedia))
        #expect(app.perform(.dismiss))
        #expect(app.viewing == nil)
    }

    @Test("Escape takes the picture before the composer, and the post after both")
    func oneKeyClosesOneThing() {
        let app = timeline("media-escape-order", [post("a", media: 1)])
        app.perform(.nextPost)
        app.perform(.expandPost)
        app.setComposing(true)
        #expect(app.perform(.openMedia))

        #expect(app.perform(.dismiss))
        #expect(app.viewing == nil)
        #expect(app.composing)
        #expect(app.perform(.dismiss))
        #expect(app.composing == false)
        #expect(app.expanded != nil)
        #expect(app.perform(.dismiss))
        #expect(app.expanded == nil)
    }

    @Test("A cover arrives with the picture and is nobody's business but this looking's")
    func whatWasCoveredStaysCovered() {
        let app = timeline("media-covered", [post("a", media: 1, covered: true)])
        #expect(app.perform(.nextPost))
        #expect(app.perform(.openMedia))
        #expect(app.viewing?.covered == true)
    }

    @Test("Nothing goes on playing behind a picture that has been closed")
    func closingStopsWhatWasPlaying() {
        let app = timeline("media-playing", [post("a", media: 1)])
        #expect(app.perform(.nextPost))
        #expect(app.perform(.openMedia))
        app.playback.toggle(URL(string: "https://one.example/m/a-0.jpg")!)
        #expect(app.playback.playing != nil)

        #expect(app.perform(.dismiss))
        #expect(app.playback.playing == nil)
    }

    @Test("Full screen is the second press: with nothing open there is nothing to give")
    func fullScreenNeedsSomethingOpen() {
        let app = timeline("media-fullscreen", [post("a", media: 1)])
        #expect(app.perform(.nextPost))
        #expect(app.perform(.fullScreen) == false)
        #expect(app.tookTheScreen == false)
    }

    @Test("The keys are written down, and v and f are two of them")
    func theKeysAreWrittenDown() {
        #expect(KeyCommand.from("v", modifiers: [], typing: false) == .openMedia)
        #expect(KeyCommand.from("f", modifiers: [], typing: false) == .fullScreen)
        // In a draft they are letters, like every other single key.
        #expect(KeyCommand.from("v", modifiers: [], typing: true) == nil)
        #expect(KeyCommand.from("f", modifiers: [], typing: true) == nil)
        #expect(KeyCommand.listened.contains("v"))
        #expect(KeyCommand.listened.contains("f"))
    }
}
