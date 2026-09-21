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

    /// Notes flash; a wait and a miss stay, because the reader has to act on them.
    var stays: Bool { kind != .note }

    /// What the toast says, one at a time. Running first; a live note replaces a
    /// leftover line; otherwise the reload line. A stack would be four facts for
    /// one capsule.
    static func shown(
        running: Bool,
        line: String?,
        stopped: Bool,
        note: String?
    ) -> TimelineToast? {
        if running {
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
struct TimelineToastBanner: View {
    let toast: TimelineToast

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: ShellSpace.snug) {
            if toast.kind == .loading {
                waitMark
            }
            Text(toast.text)
                .font(ShellType.meta)
        }
        .padding(.horizontal, ShellSpace.step)
        .padding(.vertical, ShellSpace.snug)
        .background(ShellChrome.well(colorScheme), in: Capsule())
        .foregroundStyle(ShellChrome.ink(colorScheme))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(toast.text))
        .accessibilityAddTraits(toast.kind == .loading ? .updatesFrequently : [])
    }

    @ViewBuilder
    private var waitMark: some View {
        switch TimelineToast.waitMark(reduceMotion: reduceMotion) {
        case .spinner:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .hourglass:
            Image(systemName: "hourglass")
                .font(ShellType.meta)
                .accessibilityHidden(true)
        }
    }
}
