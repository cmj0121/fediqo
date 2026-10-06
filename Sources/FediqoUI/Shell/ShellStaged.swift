import Foundation
import SwiftUI

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
public struct ShellStaged: Sendable {
    /// The place to stand on, or the one the launch landed on.
    public var place: ShellPlace?
    /// The row whose conversation is opened, as `NoteKey.rowID` names it. Only on the timeline.
    public var opens: String?
    /// Whether the composer is up, where the reader may write.
    public var composing: Bool
    /// A sentence said at the foot of the timeline, and kept there: a notice is gone in two
    /// seconds, which is before a picture is taken.
    public var says: String?
    /// The page read out of a post's words, as a press on its hyperlink would open it.
    public var reads: URL?
    /// The forum whose sign-in is asked for, as a read that needed one would ask.
    public var signsIn: String?
    /// What is then done to the list, one step after another with a moment between: what a
    /// person would have scrolled and pressed to get a picture's state.
    public var steps: [Step]
    /// How the list is scrolled, which only the app can do: it is the one with the device's
    /// own scroll view to reach. Nothing, and a step that scrolls does nothing.
    public var scroll: (@MainActor @Sendable (_ down: CGFloat) -> Void)?
    /// Whether the picture says, in a line over the page, which row the list reports at its
    /// top, which it reports as the first wholly on screen, and which is marked as being read
    /// (#303) — what a picture cannot otherwise show of a report nobody draws.
    public var reports: Bool

    /// One thing done to the list.
    public enum Step: Hashable, Sendable {
        /// The list scrolled this many points down from its start.
        case scroll(CGFloat)
        /// The timeline of every post.
        case all
        /// The timeline of what is rising, which holds posts where the launch was given some.
        case trends
        /// A timeline of the person's own that no post is under.
        case empty
        /// Timelines of the person's own, written as they would have written them: one with a
        /// long name, one whose rule names a source that is not here, and one more.
        case timelines
        /// The timeline at this place among them all, from nought, put in front.
        case go(Int)
        /// The list of every timeline, up.
        case list
    }

    /// Whether the launch stands as a device with no keyboard: a simulator reports the keyboard
    /// of the Mac it runs on, and a phone has none (`ShellKeyboard.stagedAbsent`).
    public var noKeyboard: Bool

    public init(
        place: ShellPlace? = nil, opens: String? = nil, composing: Bool = false, says: String? = nil,
        reads: URL? = nil, signsIn: String? = nil, noKeyboard: Bool = false, steps: [Step] = [],
        reports: Bool = false
    ) {
        self.place = place
        self.opens = opens
        self.composing = composing
        self.says = says
        self.reads = reads
        self.signsIn = signsIn
        self.noKeyboard = noKeyboard
        self.steps = steps
        self.reports = reports
    }
}

/// What the list reports and what is marked, written over a picture made to show it (#303).
///
/// None of the three is observed — that is the point of how they are kept — so the line is
/// drawn again on a clock. Only a staged launch that asks for it draws this.
struct StagedReport: View {
    let session: ShellSession

    /// A row's own number, which is the end of its id: enough to tell rows apart in a picture.
    static func short(_ row: String?) -> String {
        guard let row else { return "none" }
        return row.split(separator: "/").last.map(String.init) ?? row
    }

    static func line(top: String?, whole: String?, marked: String?, kept: String?) -> String {
        "top \(short(top)) · whole \(short(whole)) · marked \(short(marked)) · kept \(short(kept))"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let mark = session.readingMark
            Text(Self.line(top: session.scrolledTop, whole: mark.whole.first, marked: mark.id, kept: mark.kept))
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.yellow, in: Capsule())
                .foregroundStyle(.black)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
