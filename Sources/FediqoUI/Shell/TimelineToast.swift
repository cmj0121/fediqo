import SwiftUI

/// One sentence at the bottom of the timeline: a wait, a miss, a warning, or a brief note.
///
/// **One chrome, not a second banner.** The capsule that already sat on
/// `TimelinePane` is this fact for every kind; loading adds a spinner (or an
/// hourglass when motion is asked to stop), and nothing else grows a plate or a
/// line of its own.
struct TimelineToast: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A reload is on the wire. Stays until the wait ends; not a 2s flash.
        case loading
        /// A source did not answer, or an open post could not be found.
        case error
        /// The reader stopped the reload.
        case warning
        /// A brief note (can't edit All, unreadable, an item toast). 2s, as today.
        case note
    }

    var kind: Kind
    var text: String

    /// The widest the capsule is drawn, in points: a sentence is read in a column, not across
    /// a desktop's whole window.
    static let measure: CGFloat = 480
    /// The most lines a sentence too long for one is given before it is cut short.
    static let lines = 3

    /// Notes flash; a wait and a miss stay, because the reader has to act on them.
    var stays: Bool { kind != .note }

    /// What the toast says, one at a time. Running first; a live note replaces a
    /// leftover line; otherwise the reload line. A stack would be four facts for
    /// one capsule.
    ///
    /// `waiting` is a run nobody pressed for — the wait's alone (#95). A note the reader
    /// has just caused says its two seconds over it: the wait comes round every minute,
    /// and would otherwise swallow every note that happened to land while it ran.
    static func shown(
        running: Bool,
        waiting: Bool = false,
        line: String?,
        stopped: Bool,
        note: String?
    ) -> TimelineToast? {
        if running, !(waiting && note != nil) {
            return TimelineToast(
                kind: .loading,
                text: line ?? L10n.t("timeline.reload.progress")
            )
        }
        if let note {
            return TimelineToast(kind: .note, text: note)
        }
        if let line {
            return TimelineToast(kind: stopped ? .warning : .error, text: line)
        }
        return nil
    }

    /// What a running reload's toast says (#170): one piece of it that is on the wire now — the
    /// source's host and the timeline or board it reads, by the name the reader knows it by —
    /// and how many more are, as "+2". Nil where none of `reading` is running yet, and the
    /// toast says its plain word.
    ///
    /// **The one named is the one running longest**, so the line holds still while it runs and
    /// moves on only when it ends. Only the reload's own purposes count: a picture or an emoji
    /// on the wire meanwhile is not the reload. Built from `SourceWork`'s lines alone, which
    /// hold a host, a purpose and a name — never an address, a list's id or a board's number.
    static func reloading(
        _ running: [Int: SourceWork.Running],
        reading: Set<SourceWork.Purpose>,
        language: DummyLanguage? = nil
    ) -> String? {
        let pieces = running
            .filter { reading.contains($0.value.purpose) }
            .sorted { ($0.value.since, $0.key) < ($1.value.since, $1.key) }
        guard let first = pieces.first?.value else { return nil }
        let one = if let name = first.name {
            String(
                format: L10n.t("timeline.reload.piece", language: language),
                first.host, name.text(language: language)
            )
        } else {
            String(format: L10n.t("timeline.reload.host", language: language), first.host)
        }
        guard pieces.count > 1 else { return one }
        return String(format: L10n.t("timeline.reload.more", language: language), one, pieces.count - 1)
    }

    /// The mark beside a wait: a spinner while motion is allowed, an hourglass at rest
    /// when it is not. A wait is not a launch, so this is not the mascot.
    static func waitMark(reduceMotion: Bool) -> WaitMark {
        reduceMotion ? .hourglass : .spinner
    }

    enum WaitMark: Equatable, Sendable {
        case spinner
        case hourglass

        /// The SF Symbol for the still mark. Spinner is a `ProgressView`, not a glyph.
        var symbol: String? {
            switch self {
            case .spinner: nil
            case .hourglass: "hourglass"
            }
        }
    }
}

/// The capsule itself. VoiceOver hears the sentence; the wait mark is decoration.
///
/// **A wait reads `SourceWork` here, and only here** (#170): what is on the wire changes with
/// every picture that starts and ends, and the capsule is the one view that redraws for it —
/// never the timeline's rows under it. Anything but a wait reads nothing of it.
struct TimelineToastBanner: View {
    let toast: TimelineToast
    /// Where a reload's pieces are listed while they run, and which of its purposes are the
    /// reload's own. Nothing, and the wait says its plain word.
    var work: SourceWork? = nil
    var reading: Set<SourceWork.Purpose> = []

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// **One line in a capsule where the sentence fits, and a few lines on a plate where it
    /// does not** (#302). A sentence too long for the page used to run on for as many lines as
    /// it took, inside a capsule whose round ends cut its corners, as wide as the page to its
    /// very edges. Now it is no wider than `TimelineToast.measure` and stands clear of the
    /// edges — and is still exactly as large as what it says, so a short notice is the capsule
    /// it was and nothing wider; a sentence that does not fit one line of that breaks, and stops after
    /// `TimelineToast.lines`. VoiceOver hears the whole of it either way.
    var body: some View {
        Within(measure: TimelineToast.measure) {
            ViewThatFits(in: .horizontal) {
                face(lines: 1)
                    .background(ShellChrome.well(colorScheme), in: Capsule())
                face(lines: TimelineToast.lines)
                    .background(
                        ShellChrome.well(colorScheme),
                        in: RoundedRectangle(cornerRadius: ShellSpace.step, style: .continuous)
                    )
            }
        }
        .foregroundStyle(ShellChrome.ink(colorScheme))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
        .accessibilityAddTraits(toast.kind == .loading ? .updatesFrequently : [])
        // Clear of the page's edges, outside the element: what VoiceOver lands on is the notice.
        .padding(.horizontal, ShellSpace.pad)
    }

    private func face(lines: Int) -> some View {
        HStack(spacing: ShellSpace.snug) {
            if toast.kind == .loading {
                waitMark
            }
            Text(text)
                .shellFont(.meta)
                .lineLimit(lines)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, ShellSpace.step)
        .padding(.vertical, ShellSpace.snug)
    }

    /// The sentence: a wait's names what is running, where the reload's pieces are listed.
    private var text: String {
        guard toast.kind == .loading, let work else { return toast.text }
        return TimelineToast.reloading(work.running, reading: reading) ?? toast.text
    }

    @ViewBuilder
    private var waitMark: some View {
        // The still mark's glyph is `WaitMark.symbol`'s, so the name a test reads is the one drawn.
        if let symbol = TimelineToast.waitMark(reduceMotion: reduceMotion).symbol {
            Image(systemName: symbol)
                .shellFont(.meta)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
    }
}

/// Offers a view no more than `measure` across, and is then exactly the size the view came out
/// at.
///
/// **Not a frame**, which is as wide as it is allowed to be: a short notice in a frame of the
/// measure is an element the measure wide, with a capsule somewhere in the middle of it.
///
/// **And nothing is taken off what is offered but the measure.** A layout is asked again at the
/// size it answered with, so one that took a margin off each time would be offered less than it
/// had just said it needed, and break its sentence a second time. The room at the page's edges
/// is padding outside this, which is taken off once.
struct Within: Layout {
    var measure: CGFloat

    /// What the view is offered across, of `room` — or the measure where nobody said.
    static func offered(_ room: CGFloat?, measure: CGFloat) -> CGFloat {
        guard let room, room.isFinite else { return measure }
        return max(0, min(measure, room))
    }

    private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: Self.offered(proposal.width, measure: measure), height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(offer(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: offer(ProposedViewSize(bounds.size)))
    }
}
