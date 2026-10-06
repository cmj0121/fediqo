/// Where a launch is put with nothing pressed: a place, a post opened on it, the composer over it.
///
/// **For a picture, and for nothing a reader does.** `scripts/shots.sh` photographs the app and
/// may not press anything — a hosted runner will not grant what driving an app needs (#30), and
/// this story takes no driven tests (#300) — so a screen that has to be arrived at is arrived at
/// here, once, when the store has said what is held. The app hands one over only in a debug
/// build launched for a picture; every other launch hands over nothing and this is never read.
///
/// **It names where to stand and never how to get there.** `FediqoRootView.arrive(at:)` goes by
/// the functions a press goes through, so a picture cannot show a state the app would refuse a
/// reader.
public struct ShellStaged: Hashable, Sendable {
    /// The place to stand on, or the one the launch landed on.
    public var place: ShellPlace?
    /// The row whose conversation is opened, as `NoteKey.rowID` names it. Only on the timeline.
    public var opens: String?
    /// Whether the composer is up, where the reader may write.
    public var composing: Bool

    public init(place: ShellPlace? = nil, opens: String? = nil, composing: Bool = false) {
        self.place = place
        self.opens = opens
        self.composing = composing
    }
}
