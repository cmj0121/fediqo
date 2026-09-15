import Foundation
import Testing
@testable import FediqoCore

@Suite("What came attached")
struct AttachmentTests {
    private let file = URL(string: "https://first.example/full.mp4")!
    private let still = URL(string: "https://first.example/preview.jpg")!

    @Test("A shape needs both halves, both of them positive")
    func aspectNeedsBothHalves() {
        #expect(Attachment(kind: .image, url: file, width: 1000, height: 560).aspect == 0.56)
        #expect(Attachment(kind: .image, url: file, width: 1000).aspect == nil)
        #expect(Attachment(kind: .image, url: file, height: 560).aspect == nil)
        #expect(Attachment(kind: .image, url: file, width: 0, height: 560).aspect == nil)
        #expect(Attachment(kind: .image, url: file, width: 1000, height: 0).aspect == nil)
        #expect(Attachment(kind: .image, url: file, width: -1000, height: 560).aspect == nil)
        #expect(Attachment(kind: .image, url: file, width: 1000, height: -560).aspect == nil)
        #expect(Attachment(kind: .image, url: file).aspect == nil)
    }

    @Test("Pixels that do not make a shape are not kept as half a shape")
    func uselessPixelsAreDropped() {
        let half = Attachment(kind: .image, url: file, width: 1000)
        #expect(half.width == nil)
        #expect(half.height == nil)
        let whole = Attachment(kind: .image, url: file, width: 600, height: 900)
        #expect(whole.width == 600)
        #expect(whole.height == 900)
        #expect(whole.aspect == 1.5)
    }

    @Test("What is drawn is the still where there is one, the file otherwise")
    func displayPrefersTheStill() {
        #expect(Attachment(kind: .image, url: file, previewURL: still).displayURL == still)
        #expect(Attachment(kind: .image, url: file).displayURL == file)
        #expect(Attachment(kind: .image, previewURL: still).displayURL == still)
        #expect(Attachment(kind: .image).displayURL == nil)
    }

    @Test("Nothing to draw is an empty attachment")
    func emptyIsNeitherAddress() {
        #expect(Attachment(kind: .unknown).isEmpty)
        #expect(!Attachment(kind: .unknown, url: file).isEmpty)
        #expect(!Attachment(kind: .unknown, previewURL: still).isEmpty)
    }

    @Test("Playing needs the file itself, not a still of it")
    func playableNeedsTheFile() {
        #expect(Attachment(kind: .video, url: file).isPlayable)
        #expect(Attachment(kind: .audio, url: file).isPlayable)
        #expect(!Attachment(kind: .image, url: file).isPlayable)
        #expect(!Attachment(kind: .unknown, url: file).isPlayable)
        #expect(!Attachment(kind: .video, previewURL: still).isPlayable)
        #expect(!Attachment(kind: .audio, previewURL: still).isPlayable)
    }

    @Test("Alt is what the author wrote, and empty where they wrote none")
    func altIsCarried() {
        #expect(Attachment(kind: .image, url: file, alt: "a cat").alt == "a cat")
        #expect(Attachment(kind: .image, url: file).alt.isEmpty)
    }

    @Test("Nothing on sensitive and spoiler is not a note saying no")
    func silenceIsNotANo() {
        let note = Note(
            id: "n1",
            source: Source(host: "first.example", kind: .mastodon),
            author: "Ada",
            handle: "@ada@first.example",
            body: "hello",
            postedAt: Date(timeIntervalSince1970: 0),
            origins: [.publicTimeline]
        )
        #expect(note.sensitive == nil)
        #expect(note.spoiler == nil)
        #expect(note.attachments.isEmpty)
        #expect(note.emojis.isEmpty)

        let covered = Note(
            id: "n2",
            source: note.source,
            author: "Ada",
            handle: "@ada@first.example",
            body: "hello",
            postedAt: Date(timeIntervalSince1970: 0),
            origins: [.publicTimeline],
            attachments: [Attachment(kind: .image, previewURL: still)],
            sensitive: true,
            spoiler: "the ending"
        )
        #expect(covered.sensitive == true)
        #expect(covered.spoiler == "the ending")
        #expect(covered.attachments.count == 1)

        let said = Note(
            id: "n3",
            source: note.source,
            author: "Ada",
            handle: "@ada@first.example",
            body: "hello",
            postedAt: Date(timeIntervalSince1970: 0),
            origins: [.publicTimeline],
            sensitive: false,
            spoiler: ""
        )
        #expect(said.sensitive == false)
        #expect(said.spoiler == "")
    }
}
