import SwiftUI
import FediqoCore

/// One thing that happened.
///
/// Not "at the height every other row is", which is what this said and what nothing here ever
/// did: no frame holds a notice to a height, and one whose quoted line wraps is taller than one
/// whose does not. S6 asks for a row that is bounded rather than one that is uniform, and the
/// bound is `quotedLines` below.
struct NoticeRow: View {
    let group: NoticeGroup

    /// The newest of them, which is what everything but the sentence is drawn from: the avatar,
    /// the quoted line and the time all belong to the most recent thing that happened.
    private var notice: Notice { group.newest }

    /// The app's language, carried down by `fediqoChrome`. Read here because the two times on
    /// this row are built as strings rather than drawn by `Text(date, format:)`.
    @Environment(\.locale) private var locale

    /// Who did it, in the fewest words that are still true: one name where one person did it,
    /// and a name and a number where several did.
    ///
    /// The newest first, because that is the one the reader has not seen and the one the time
    /// beside it belongs to.
    private var who: String {
        let names = group.actors
        guard let first = names.first else { return "" }
        guard names.count > 1 else { return first }
        return t("notices.andOthers", first, "\(names.count - 1)")
    }

    /// One line of what was said, and no more. S6 says a row is bounded, and this is where the
    /// bound is here: a mention is read in this list to decide whether to open it, not instead
    /// of opening it, so one line is the whole of what it has to do.
    private static let quotedLines = 1

    var body: some View {
        HStack(alignment: .top, spacing: Space.step) {
            Image(systemName: notice.kind.symbolName)
                .fediqoSymbol(Glyph.lead)
                // Any of them unseen makes the row unseen: a reader who has read five of six
                // has not read the sixth.
                .foregroundStyle(group.isUnseen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: Size.iconColumn)
                .accessibilityHidden(true)

            RemoteImage(url: notice.actorAvatarURL, width: Size.avatar, height: Size.avatar,
                        radius: Radius.thumbnail, standing: .avatar)

            VStack(alignment: .leading, spacing: Space.hair) {
                said
                if let post = notice.post, !post.text.isEmpty {
                    Text(post.text)
                        .fediqoFont(TypeScale.small)
                        .foregroundStyle(.secondary)
                        .lineLimit(Self.quotedLines)
                }
            }

            Spacer(minLength: Space.step)
            when
        }
        .padding(.vertical, Space.step)
        .accessibilityElement(children: .combine)
    }

    /// Who did what. The name is the person and the rest is the event, so the two are weighted
    /// differently rather than run together into one grey sentence.
    private var said: some View {
        HStack(spacing: Space.tight) {
            // A name and *and five others* reads as a sentence; six avatars in a line is a
            // shape a reader has to work out (#124).
            Text(who)
                .fediqoFont(TypeScale.body, weight: .medium)
                .lineLimit(1)
            Text(t("notices.kind.\(notice.kind.rawValue)"))
                .fediqoFont(TypeScale.small)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// When it happened, and — only where it is worth saying — how long it took to get here.
    ///
    /// The lateness is measured and not guessed: `arrived_at` minus `noticed_at`, both written
    /// down when they were true. It is shown only past a threshold, because every notice is a
    /// fraction of a second late and saying so on every row would be noise standing where a
    /// fact should be.
    private var when: some View {
        VStack(alignment: .trailing, spacing: Space.hair) {
            Text(notice.noticedAt, format: .relative(presentation: .numeric))
                .fediqoFont(TypeScale.minor)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if notice.lateness >= NoticeRow.worthSaying {
                Text(t("notices.late", NoticeRow.spelled(notice.lateness, in: locale)))
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Below this, the delay is the network being a network and there is nothing to tell
    /// anybody. Above it, the app was asleep and the reader deserves to know that is why.
    static let worthSaying: TimeInterval = 60

    /// A duration in the coarsest unit that is still true. Minutes, or hours where minutes
    /// would be three digits: "arrived 94 minutes late" is a number a reader has to do
    /// arithmetic on to understand.
    /// **The language is handed in.** A style built without one follows the *system's*
    /// language, not the one the reader chose in this app — which is how `4分 late` came to be
    /// drawn on a screen every other word of which was English. `Text(date, format:)` reads the
    /// environment and gets this right on its own; a string built out here does not.
    static func spelled(_ seconds: TimeInterval, in locale: Locale) -> String {
        var style = Duration.UnitsFormatStyle(
            allowedUnits: seconds >= 3600 ? [.hours] : [.minutes],
            width: .narrow
        )
        style.locale = locale
        return Duration.seconds(seconds).formatted(style)
    }
}
