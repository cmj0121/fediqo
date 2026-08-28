import AVKit
import Observation
import SwiftUI
import FediqoCore

/// What is playing, which is at most one thing.
///
/// A timeline is a column of posts and several of them carry films; a screen where every one
/// of them plays at once is a screen nobody can read, and it is somebody else's bandwidth
/// being spent on things the reader never asked to watch. So playing one stops the last, and
/// this is where that is known.
///
/// **Nothing plays by itself.** Not the films, not the looping soundless ones, not on scroll.
/// A reader asks, by clicking the mark on the attachment or pressing `p`, and until they do
/// what is drawn is the still the server sent — which costs one image, the way it always did.
@MainActor
@Observable
final class Playback {
    /// The file that is playing, or nothing. The file rather than the post: one post can
    /// carry several, and it is one of them that is playing.
    private(set) var playing: URL?
    /// The player behind it, kept only while something is playing. Built per file rather than
    /// reused: a new item on an existing player buys nothing here, and a player left holding
    /// a finished item goes on holding whatever it buffered.
    private(set) var player: AVPlayer?

    /// Starts `url`, or stops it if it is what is already playing.
    func toggle(_ url: URL) {
        if playing == url {
            stop()
            return
        }
        stop()
        let player = AVPlayer(url: url)
        // A film in a timeline starts quiet. Somebody reading a page of posts did not ask for
        // sound out of one of them, and the control to turn it up is right there.
        player.isMuted = true
        playing = url
        self.player = player
        player.play()
    }

    /// Stops whatever is playing and lets go of it.
    func stop() {
        player?.pause()
        player = nil
        playing = nil
    }

    func isPlaying(_ url: URL?) -> Bool {
        guard let url else { return false }
        return playing == url
    }
}

/// One attachment, playing. It is the same rectangle the still was drawn in, so starting and
/// stopping does not move anything else on the screen.
struct AttachmentPlayer: View {
    let player: AVPlayer
    let audio: Bool
    /// The rectangle to play in. `nil` is "whatever room there is", which is what the opened
    /// picture hands it and what a row never does: in a list every row is the same height, and
    /// a film that sized itself would be the one row that is not.
    var width: CGFloat?
    var height: CGFloat?

    var body: some View {
        VideoPlayer(player: player)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            // A clip with no picture is a black rectangle with controls in it, which says
            // nothing about what it is. The mark stays, over the controls' own background.
            .overlay(alignment: .topLeading) {
                if audio {
                    Image(systemName: "waveform")
                        .fediqoSymbol(Glyph.badge)
                        .padding(Space.snug)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(Space.snug)
                        .allowsHitTesting(false)
                }
            }
    }
}
