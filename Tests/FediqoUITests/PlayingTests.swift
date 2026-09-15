import Foundation
import FediqoCore
import Testing
@testable import FediqoUI

/// What is playing, and what stops it.
///
/// The `AVPlayer` is `ShellPlayback`'s; every decision about *which* file plays, on *which* post
/// and on *which* stage is this value's, which is why all of it can be asserted here without an
/// AVFoundation object anywhere in the suite.
@Suite("What is playing")
struct PlayingTests {
    private static let film = URL(string: "https://first.example/a.mp4")!
    private static let other = URL(string: "https://first.example/b.mp4")!

    @Test("Nothing plays until something is asked for")
    func nothingPlaysByItself() {
        let playing = ShellPlaying()
        #expect(playing.here(Self.film, of: "p1", on: .row) == nil)
        #expect(playing.here(Self.film, of: "p1", on: .viewer) == nil)
        #expect(playing.url == nil)
    }

    @Test("a starts it, and a again stops it")
    func toggleStartsAndStops() {
        var playing = ShellPlaying()
        let started = playing.toggle(Self.film, of: "p1", on: .row)
        #expect(started)
        #expect(playing.here(Self.film, of: "p1", on: .row) == Self.film)
        let stopped = playing.toggle(Self.film, of: "p1", on: .row)
        #expect(stopped)
        #expect(playing.here(Self.film, of: "p1", on: .row) == nil)
    }

    @Test("At most one thing plays in the whole app")
    func startingOneStopsTheLast() {
        var playing = ShellPlaying()
        let started = playing.toggle(Self.film, of: "p1", on: .row)
        #expect(started)
        let replaced = playing.toggle(Self.other, of: "p1", on: .row)
        #expect(replaced)
        #expect(playing.here(Self.other, of: "p1", on: .row) == Self.other)
        #expect(playing.here(Self.film, of: "p1", on: .row) == nil)
    }

    // The same file drawn in the slot and drawn over the whole app is two different things — one
    // silent with no controls, one with all of them. Without the stage in the answer, opening the
    // viewer over a playing row gives two players on one file.
    @Test("The same file on the other stage is not what is playing here")
    func theStageIsPartOfTheAnswer() {
        var playing = ShellPlaying()
        let inTheRow = playing.toggle(Self.film, of: "p1", on: .row)
        #expect(inTheRow)
        #expect(playing.here(Self.film, of: "p1", on: .viewer) == nil)
        let inTheViewer = playing.toggle(Self.film, of: "p1", on: .viewer)
        #expect(inTheViewer)
        #expect(playing.here(Self.film, of: "p1", on: .row) == nil)
        #expect(playing.here(Self.film, of: "p1", on: .viewer) == Self.film)
    }

    // A timeline can show one address twice — a post and the boost of it, two posts quoting one
    // video. Keyed on the file alone, every row that resolved to that address drew its own player
    // and all of them played: one press, N downloads, N chosen by whoever wrote the timeline.
    @Test("Two posts carrying the same file are two different things")
    func thePostIsPartOfTheAnswer() {
        var playing = ShellPlaying()
        let started = playing.toggle(Self.film, of: "p1", on: .row)
        #expect(started)
        #expect(playing.here(Self.film, of: "p1", on: .row) == Self.film)
        #expect(playing.here(Self.film, of: "p2", on: .row) == nil)
        // And starting it on the other post moves it rather than adding a second.
        let moved = playing.toggle(Self.film, of: "p2", on: .row)
        #expect(moved)
        #expect(playing.here(Self.film, of: "p1", on: .row) == nil)
        #expect(playing.here(Self.film, of: "p2", on: .row) == Self.film)
    }

    @Test("Stopping forgets the post as well as the file")
    func stoppingForgetsThePost() {
        var playing = ShellPlaying()
        let started = playing.toggle(Self.film, of: "p1", on: .row)
        #expect(started)
        let stopped = playing.stop()
        #expect(stopped)
        #expect(playing.post == nil)
        #expect(playing.url == nil)
    }

    @Test("Stopping says whether there was anything to stop")
    func stoppingReportsItself() {
        var playing = ShellPlaying()
        let nothingToStop = playing.stop()
        #expect(!nothingToStop)
        let started = playing.toggle(Self.film, of: "p1", on: .row)
        #expect(started)
        let stopped = playing.stop()
        #expect(stopped)
        #expect(playing.url == nil)
    }

    @Test("Nothing is asked to play where there is no file to play")
    func nothingToPlay() {
        var playing = ShellPlaying()
        let nothingToStart = playing.toggle(nil, of: "p1", on: .row)
        #expect(!nothingToStart)
        #expect(playing.here(nil, of: "p1", on: .row) == nil)
    }

    @Test("Only something that plays, and only where the file itself came with it")
    func whatIsPlayable() {
        let film = FediqoCore.Attachment(kind: .video, url: Self.film, previewURL: Self.other)
        let sound = FediqoCore.Attachment(kind: .audio, url: Self.film)
        let picture = FediqoCore.Attachment(kind: .image, url: Self.film)
        let stillOnly = FediqoCore.Attachment(kind: .video, previewURL: Self.other)
        let nobodySaid = FediqoCore.Attachment(kind: .unknown, url: Self.film)

        #expect(ShellPlaying.playable(film) == Self.film)
        #expect(ShellPlaying.playable(sound) == Self.film)
        #expect(ShellPlaying.playable(picture) == nil)
        #expect(ShellPlaying.playable(stillOnly) == nil)
        #expect(ShellPlaying.playable(nobodySaid) == nil)
        #expect(ShellPlaying.playable(nil) == nil)
    }
}

/// Which mark a card gets, and which cards get none.
@Suite("The play mark on the card")
struct PlayMarkTests {
    private static let file = URL(string: "https://first.example/a.mp4")!

    @Test("A video and an audio clip are marked")
    func whatIsMarked() {
        #expect(
            AttachmentDeck.playSymbol(of: FediqoCore.Attachment(kind: .video, url: Self.file))
                == "play.fill"
        )
        #expect(
            AttachmentDeck.playSymbol(of: FediqoCore.Attachment(kind: .audio, url: Self.file))
                == "waveform"
        )
    }

    // A picture looks like a picture, and a question mark over somebody's photograph claims to
    // know something about it that nobody told us.
    @Test("A picture is not marked, and neither is something the server would not name")
    func whatIsNotMarked() {
        let picture = FediqoCore.Attachment(kind: .image, url: Self.file)
        let nobodySaid = FediqoCore.Attachment(kind: .unknown, url: Self.file)
        #expect(AttachmentDeck.playSymbol(of: picture) == nil)
        #expect(AttachmentDeck.playSymbol(of: nobodySaid) == nil)
    }

    // The mark is a button. One offering to play a still with no file behind it is the control
    // that lies, which is why unit 6 left the mark out while `a` did nothing.
    @Test("A film with no file behind it is not marked either")
    func aStillIsNotMarked() {
        let stillOnly = FediqoCore.Attachment(
            kind: .video,
            previewURL: URL(string: "https://first.example/a.jpg")
        )
        #expect(AttachmentDeck.playSymbol(of: stillOnly) == nil)
    }
}
