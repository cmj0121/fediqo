import SwiftUI

/// One sentence at the bottom of the timeline: a wait, a miss, a warning, or a brief note.
///
/// **One chrome, not a second banner.** The capsule that already sat on
/// `TimelinePane` is this fact for every kind; loading adds the launch mascot at
/// toast size, and nothing else grows a plate or a line of its own.
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
}

/// The capsule itself. VoiceOver hears the sentence; the mascot is decoration.
struct TimelineToastBanner: View {
    let toast: TimelineToast

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: ShellSpace.snug) {
            if toast.kind == .loading {
                LandingMascot(size: Landing.toastMark, looping: true)
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
}
