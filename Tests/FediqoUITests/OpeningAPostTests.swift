import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// Opening a post: `Return`, `Space` and a click all mean the same thing, `Escape` is the way
/// back, and what used to be `Return` is `o` now.
@Suite("Opening a post")
@MainActor
struct OpeningAPostTests {
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

    @Test("Return opens the whole post, and Escape puts it away")
    func openAndClose() {
        let app = timeline("open-and-close", [post("a"), post("b")])
        #expect(app.perform(.nextPost))
        #expect(app.perform(.expandPost))
        #expect(app.expanded?.text == "a")

        #expect(app.perform(.dismiss))
        #expect(app.expanded == nil)
        // And the ring is where it was: coming back is coming back, not starting again.
        #expect(app.feed(for: .publicFixture).selection == post("a").mergeKey)
    }

    @Test("With no post under the ring there is nothing to open")
    func nothingToOpen() {
        let app = timeline("open-nothing", [])
        #expect(app.perform(.expandPost) == false)
        #expect(app.expanded == nil)
    }

    @Test("A click opens the post that was clicked, and takes the ring with it")
    func clickingOpens() {
        let app = timeline("open-click", [post("a"), post("b")])
        app.expand(post("b"))
        #expect(app.expanded?.text == "b")
        #expect(app.feed(for: .publicFixture).selection == post("b").mergeKey)
    }

    @Test("o is what hands the post to the server it came from")
    func browserIsItsOwnKey() {
        let app = timeline("open-browser", [post("a")])
        var opened: [URL] = []
        app.openLink = { opened.append($0) }
        #expect(app.perform(.nextPost))
        #expect(app.perform(.openInBrowser))
        #expect(opened.map(\.absoluteString) == ["https://one.example/@a/a"])
        // And it is not what opening the post here does.
        #expect(app.expanded == nil)
    }

    @Test("Escape closes the composer before the post underneath it")
    func oneKeyClosesOneThing() {
        let app = timeline("open-escape-order", [post("a")])
        app.perform(.nextPost)
        app.perform(.expandPost)
        app.setComposing(true)

        #expect(app.perform(.dismiss))
        #expect(app.composing == false)
        #expect(app.expanded != nil)
        #expect(app.perform(.dismiss))
        #expect(app.expanded == nil)
    }

    @Test("m turns the deck, and only where there is a deck to turn")
    func turningTheDeck() {
        let app = timeline("open-deck", [post("a", media: 3), post("b", media: 1)])
        #expect(app.perform(.nextPost))
        let before = app.mediaTurns
        #expect(app.perform(.rotateMedia))
        #expect(app.mediaTurns == before + 1)

        // One attachment is a picture, not a stack: there is nothing to turn and the press
        // says so rather than pretending.
        #expect(app.perform(.nextPost))
        #expect(app.perform(.rotateMedia) == false)
        #expect(app.mediaTurns == before + 1)
    }

    @Test("While a post is open the keys move through the conversation, not the list behind it")
    func theKeysFollowTheReader() {
        let app = timeline("open-keys", [post("a"), post("b")])
        let feed = app.feed(for: .publicFixture)
        #expect(app.perform(.nextPost))
        #expect(app.perform(.expandPost))
        let ringInTheList = feed.selection

        // The conversation is one post until a server says otherwise, so there is nowhere to
        // go — and the answer is `false` rather than the list moving under the page.
        #expect(app.perform(.nextPost) == false)
        #expect(feed.selection == ringInTheList)

        // Back in the list, they move it again.
        #expect(app.perform(.dismiss))
        #expect(app.perform(.nextPost))
        #expect(feed.selection != ringInTheList)
    }

    @Test("The conversation is read from the post outwards, and the ring starts on it")
    func theRingStartsOnTheOpenedPost() {
        let app = timeline("open-ring", [post("a")])
        app.expand(post("a"))
        let thread = try? #require(app.thread)
        #expect(thread?.selection == post("a").mergeKey)
        #expect(thread?.selected?.text == "a")
        // And it goes away with the page: what it read is in the store, not in it.
        app.perform(.dismiss)
        #expect(app.thread == nil)
    }

    @Test("What is covered is covered until the reader says otherwise")
    func coveringIsThePreference() {
        let app = freshApp("open-covered")
        // Off to begin with: a warning somebody wrote is a warning until the reader lifts it,
        // and the app is not the one to overrule the author.
        #expect(app.preferences.showSensitive == false)
        #expect(post("a", covered: true).sensitive == true)
        #expect(post("a").sensitive == nil)
    }
}

/// Playing what came attached: only where the file itself is here, only one at a time, and
/// never without being asked.
@Suite("Playing an attachment")
@MainActor
struct PlaybackTests {
    private let film = URL(string: "https://one.example/v/1.mp4")!

    private func post(_ id: String, _ attachments: [FediqoCore.Attachment]) -> Post {
        Post(uri: "https://one.example/api/v1/statuses/\(id)", socialProtocol: .mastodon,
             sourceURL: "https://one.example", createdAt: Date(timeIntervalSince1970: 100),
             authorId: "https://one.example/@a", authorName: "A", authorHandle: "@a@one.example",
             text: id, attachments: attachments,
             webURL: URL(string: "https://one.example/@a/\(id)"))
    }

    private func timeline(_ name: String, _ posts: [Post]) -> AppState {
        let app = freshApp(name)
        app.railItem = .timeline
        app.currentTimeline = "public"
        app.feed(for: .publicFixture).show(posts)
        return app
    }

    @Test("Only an attachment whose file we hold can be played")
    func onlyWhatWeHold() {
        // A film, with the file: playable.
        #expect(FediqoCore.Attachment(kind: .video, url: film, previewURL: URL(string: "https://one.example/v/1.png")).isPlayable)
        #expect(FediqoCore.Attachment(kind: .audio, url: film).isPlayable)
        // A picture is not something to play, and neither is a still with nothing behind it —
        // which is every attachment stored before the file's address was kept.
        #expect(FediqoCore.Attachment(kind: .image, url: film).isPlayable == false)
        #expect(FediqoCore.Attachment.unknown(displaying: film).isPlayable == false)
        #expect(FediqoCore.Attachment(kind: .video, previewURL: film).isPlayable == false)
    }

    @Test("p asks the row under the ring, and says so when there is nothing to play")
    func theKeyAsksTheRow() {
        let app = timeline("play-key", [
            post("a", [FediqoCore.Attachment(kind: .video, url: film)]),
            post("b", [FediqoCore.Attachment.unknown(displaying: film)]),
        ])
        #expect(app.perform(.nextPost))
        let asked = app.mediaPlays
        #expect(app.perform(.playMedia))
        #expect(app.mediaPlays == asked + 1)

        // A still with nothing behind it is not something to play, and the press says so.
        #expect(app.perform(.nextPost))
        #expect(app.perform(.playMedia) == false)
        #expect(app.mediaPlays == asked + 1)
    }

    @Test("One thing plays at a time, and starting the same thing again stops it")
    func oneAtATime() {
        let app = freshApp("play-one")
        let other = URL(string: "https://one.example/v/2.mp4")!
        app.playback.toggle(film)
        #expect(app.playback.isPlaying(film))

        app.playback.toggle(other)
        #expect(app.playback.isPlaying(other))
        #expect(app.playback.isPlaying(film) == false)

        app.playback.toggle(other)
        #expect(app.playback.playing == nil)
    }

    @Test("Closing the post takes its sound with it")
    func closingStops() {
        let app = timeline("play-close", [post("a", [FediqoCore.Attachment(kind: .video, url: film)])])
        app.perform(.nextPost)
        app.perform(.expandPost)
        app.playback.toggle(film)
        #expect(app.playback.playing != nil)

        #expect(app.perform(.dismiss))
        #expect(app.playback.playing == nil)
    }

    @Test("p stops whatever is playing, wherever the reader has got to")
    func theKeyStopsFromAnywhere() {
        let app = timeline("play-stop", [
            post("a", [FediqoCore.Attachment(kind: .video, url: film)]),
            post("b", []),
        ])
        app.perform(.nextPost)
        app.playback.toggle(film)
        // The ring moves on to a post with nothing attached; the sound is still coming from
        // the one behind it, and the key that started it is the key that stops it.
        #expect(app.perform(.nextPost))
        #expect(app.perform(.playMedia))
        #expect(app.playback.playing == nil)
    }
}
