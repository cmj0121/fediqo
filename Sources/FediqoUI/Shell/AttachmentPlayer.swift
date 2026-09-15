import AVKit
import SwiftUI

/// The one player in the app, and the only thing that owns one.
///
/// **A player exists only for the thing that is playing** — not one per row that could play. A
/// visible row that is not playing draws its still from `ShellPictures` at deck tier and needs no
/// `AVPlayer` at all. That is decision 7's "at most one thing plays" turned from a rule somebody
/// has to keep into a shape that cannot express the alternative, and it is what collapses the
/// worst case rather than patching its symptoms:
///
/// - **No duplication for a shared address.** A timeline can show one address twice — a post and
///   the boost of it, two posts quoting one video. A player per row played all of them; one
///   player cannot.
/// - **Nothing to restart.** A player owned by a row in a `LazyVStack` gets a fresh `onAppear`
///   every time the row scrolls back, and a player that plays on appearance starts the file again
///   from the beginning — a whole second download, unpressed. A player owned here appears and
///   disappears with the reader's decision, not with the view's.
///
/// So the worst case is one file times one forward buffer, and both of those are numbers.
///
/// **The decisions are not here.** Which file, which post, which stage is `ShellPlaying`'s, a
/// plain value with a suite of its own. This keeps an `AVPlayer` in step with that value and does
/// nothing else.
@MainActor
@Observable
final class ShellPlayback {
    /// How far ahead AVFoundation may read, in seconds.
    ///
    /// **Zero — the default — means "as fast as the link allows"**, which for the progressive
    /// `.mp4` Mastodon serves is the whole file, however large a hostile instance made it.
    /// Nothing else in this branch bounds it: the picture budget does not reach here, and a
    /// video's address goes to `AVPlayer` directly rather than through `HTTPClient`, so neither
    /// the response ceiling nor the redirect guard is on this path. This is the only number
    /// standing between a press of `a` and an unbounded download.
    ///
    /// Two values, because two things are happening. A slot playing silently is a moving
    /// thumbnail and needs barely any; a film the reader opened to watch should not stall every
    /// few seconds on a slow link.
    static let rowBuffer: TimeInterval = 3
    static let viewerBuffer: TimeInterval = 10

    /// What is playing. Read by every row and by the viewer; written only through this class, so
    /// the value and the player cannot disagree.
    private(set) var playing = ShellPlaying()

    /// The player behind it, where there is one. Built per file rather than reused: a new item on
    /// an existing player buys nothing here, and a player left holding a finished item goes on
    /// holding whatever it buffered.
    private(set) var player: AVPlayer?

    /// The player for this card, where this card is the thing that is playing.
    ///
    /// The whole question in one call, because a view has no other use for either half: a player
    /// it is not allowed to draw is the same as no player.
    func player(for url: URL?, of post: String, on stage: ShellPlaying.Stage) -> AVPlayer? {
        playing.here(url, of: post, on: stage) == nil ? nil : player
    }

    @discardableResult
    func toggle(_ url: URL?, of post: String, on stage: ShellPlaying.Stage) -> Bool {
        var next = playing
        guard next.toggle(url, of: post, on: stage) else { return false }
        playing = next
        rebuild()
        return true
    }

    @discardableResult
    func stop() -> Bool {
        var next = playing
        guard next.stop() else { return false }
        playing = next
        rebuild()
        return true
    }

    /// Lets go of the old player and builds the new one, if there is one to build.
    ///
    /// The teardown is `pause` **and** `replaceCurrentItem(with: nil)`: `pause` alone leaves the
    /// player holding everything it had buffered.
    private func rebuild() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        guard let url = playing.url else { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration =
            playing.stage == .viewer ? Self.viewerBuffer : Self.rowBuffer
        let made = AVPlayer(playerItem: item)
        // A film in a list starts quiet. Nobody reading a page of posts asked for sound out of
        // one of them, and a 96pt square has nowhere to put the control that turns it down.
        made.isMuted = playing.stage == .row
        player = made
        made.play()
    }
}

/// One attachment, playing, in the rectangle the still was drawn in.
///
/// **Two shapes, because two rectangles.** In the 96pt slot AVKit's controls are larger than the
/// thing they would be drawn in, so the slot plays with none of them and no sound: what a reader
/// gets there is a moving thumbnail, which is an honest answer to a square that size. The viewer
/// has the whole app and gets the controls.
///
/// **It owns nothing.** The player is handed in by `ShellPlayback`, which built it when the
/// reader pressed `a`. This view starts nothing, stops nothing and keeps nothing — which is why
/// a row that scrolls away and comes back does not begin the file again.
///
/// The one thing it does report is its own disappearance, and that is the owner's cue rather than
/// this view's decision: a film playing in a row nobody can see any more is a download nobody
/// asked to continue.
struct AttachmentPlayer: View {
    let player: AVPlayer

    /// Whether AVKit's own controls are drawn.
    ///
    /// Sound is decided with it, in `ShellPlayback`: a player with controls is something the
    /// reader opened on purpose and can turn down, and a silent rectangle in a list is not a
    /// place to put sound nobody can reach.
    let controls: Bool

    /// Drawn over the player where there is no picture to draw — an audio clip is a black
    /// rectangle with controls in it, which says nothing about what it is.
    var mark: String?

    /// That this rectangle is no longer on screen.
    var onGone: () -> Void = {}

    var body: some View {
        surface
            .overlay(alignment: .topLeading) { badge }
            .onDisappear(perform: onGone)
    }

    /// The rectangle itself — and **its identity is the player's**.
    ///
    /// `ShellPlayback` builds a player per file and lets the old one go, so today a different
    /// film here is a different object and this is belt to that braces. It is written down
    /// because the alternative is one line away: the day anything reuses a single `AVPlayer`
    /// across two files — `replaceCurrentItem` rather than a fresh one — a surface that did not
    /// follow the swap goes on showing the last film's frame over the new one's sound, and AVKit
    /// is the half that would not notice. Keying on the object makes "the view follows the file"
    /// true by construction instead of by whoever writes that change remembering it.
    ///
    /// Inside `surface` rather than out in `body`, so a swap replaces the rectangle and not the
    /// `onDisappear` around it: that one is the owner's cue to stop, and firing it on a change of
    /// film would stop the film that had just started.
    @ViewBuilder
    private var surface: some View {
        Group {
            if controls {
                VideoPlayer(player: player)
            } else {
                PlayerSurface(player: player)
            }
        }
        .id(ObjectIdentifier(player))
    }

    @ViewBuilder
    private var badge: some View {
        if let mark {
            Image(systemName: mark)
                .font(ShellType.mark.weight(.medium))
                .foregroundStyle(ShellChrome.overPicture)
                .padding(ShellSpace.tight)
                .background(Circle().fill(ShellChrome.scrim))
                .padding(ShellSpace.tight)
                .allowsHitTesting(false)
        }
    }
}

/// A film and nothing else: no controls, no chrome, no gesture of its own.
///
/// `AVPlayerLayer` rather than `VideoPlayer` because it is the only one of the two that can be
/// asked for no controls on both platforms. `VideoPlayer` wraps AVKit's own view, whose controls
/// come back on hover whatever is done to the SwiftUI view around it.
///
/// The iOS half is written and never executed: this package's suite runs on macOS.
private struct PlayerSurface {
    let player: AVPlayer
}

#if os(macOS)
extension PlayerSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerLayerView { PlayerLayerView() }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

/// An `NSView` that *is* its own `AVPlayerLayer`. Assigning the layer before `wantsLayer` is what
/// makes AppKit host this one rather than make its own and put this inside it, which is what
/// keeps the film laid out by the view system instead of by a frame kept in step by hand.
private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
}
#else
extension PlayerSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerLayerView { PlayerLayerView() }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

/// The same thing on the other platform, where a backing layer cannot be handed over and the
/// player's is added to it instead.
private final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
#endif
