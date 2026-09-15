import FediqoCore
import Foundation

/// What is playing, which is at most one thing in the whole app.
///
/// **A timeline is a column of posts and several of them carry films.** A screen where every one
/// of them plays at once is a screen nobody can read, and it is somebody else's bandwidth spent
/// on things the reader never asked to watch. So starting one stops the last, and this is the one
/// place that knows which.
///
/// **Nothing starts by itself, and nothing carries on by itself.** Not on scroll, not on the row
/// becoming selected, not when the viewer opens. Until a reader presses `a` or the mark on the
/// card, what is drawn is the still the server sent, which costs one picture the way it always
/// did.
///
/// The second half of that is not this value's to keep and it is worth saying where it is:
/// `AttachmentPlayer` reports its own disappearance, and the owner stops. Without it a row in a
/// `LazyVStack` that scrolls off and back gets a fresh `onAppear`, and a player that plays on
/// appearance starts the file again from the beginning — a whole second download, unpressed. A
/// value that says what is playing cannot see a view go away; the view has to say so.
///
/// It belongs to the app rather than to a row, for the reason `ShellDecks` does: a row is rebuilt
/// every time the list is, and a refresh replaces the list wholesale. Nothing here is written
/// down anywhere — what was playing is about this moment.
struct ShellPlaying: Equatable, Sendable {
    /// Where it is playing.
    ///
    /// **Part of what is playing, not a fact about the view.** The same file drawn in the 96pt
    /// slot and drawn over the whole app is two different things — one silent with no controls,
    /// one with all of them — and only one of them is what the reader started. Without the stage
    /// in the answer, opening the viewer over a playing row gives two players on one file.
    enum Stage: Sendable {
        /// The slot in the row: silent, no controls, a moving thumbnail.
        case row
        /// `v`, over the whole app: AVKit's own controls, and sound.
        case viewer
    }

    /// Which post it belongs to.
    ///
    /// **The file alone is not enough, and this is not belt and braces.** A timeline can show the
    /// same address twice — a post and the boost of it, two posts quoting one video, or an
    /// instance that hands out one URL for many attachments. Keyed on the file alone, every
    /// visible row whose top card resolved to that address drew its own player with its own
    /// `AVPlayer`, and all of them played: one press, N downloads, with N chosen by whoever wrote
    /// the timeline. The post is what makes "one player" true rather than "one file".
    private(set) var post: String?
    private(set) var url: URL?
    private(set) var stage: Stage = .row

    /// The file playing here, where this row's card on this stage is the one playing it.
    ///
    /// Three questions in one, because every call site asks all three: the right post, the right
    /// file, the right stage. Nothing covers "nothing is playing", "another row is playing it"
    /// and "it is playing on the other stage" alike, which to a view is one answer — draw the
    /// still.
    func here(_ url: URL?, of post: String, on stage: Stage) -> URL? {
        guard let url, self.url == url, self.post == post, self.stage == stage else { return nil }
        return url
    }

    /// Starts this one here, or stops it if it is already what is playing here. Says whether
    /// anything moved.
    ///
    /// Starting something anywhere replaces whatever was playing, wherever that was: this value
    /// can only name one file, on one post, on one stage, so "at most one thing plays" is not a
    /// rule that has to be kept but a shape that cannot express the alternative.
    mutating func toggle(_ url: URL?, of post: String, on stage: Stage) -> Bool {
        guard let url else { return false }
        if here(url, of: post, on: stage) != nil { return stop() }
        self.url = url
        self.post = post
        self.stage = stage
        return true
    }

    /// Stops whatever was playing, and says whether there was anything to stop.
    @discardableResult
    mutating func stop() -> Bool {
        guard url != nil else { return false }
        url = nil
        post = nil
        stage = .row
        return true
    }

    /// The file to play, where there is one to play.
    ///
    /// `isPlayable` is Core's rule and carries the half that is easy to miss: it has to be
    /// something that plays **and** we have to hold the file itself. A still with nothing behind
    /// it cannot be played however obviously it is a film to look at, and a mark offering to play
    /// it would be a control that lies.
    static func playable(_ attachment: Attachment?) -> URL? {
        guard let attachment, attachment.isPlayable else { return nil }
        return attachment.url
    }
}
