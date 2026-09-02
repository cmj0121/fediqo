import SwiftUI
import FediqoCore

/// The inbox: what other people did, aimed at the reader.
///
/// It lives in the timeline rather than in the rail because that is what it is about — every
/// row here is somebody answering something, and the answer belongs beside the thread of time
/// rather than in a place of its own.
///
/// The screen says why a notice can be late, and it says it as a matter of fact rather than as
/// an apology. There is no Fediqo server holding a push subscription and there will not be
/// one, so what a reader gets is exactly what their own device could hear: everything, at once,
/// while the app is open, and whatever the operating system allows when it is not. A reader who
/// is told that can decide what to do about it; one who is not is left thinking the app is
/// broken.
struct NoticesSheet: View {
    /// The least a sheet of notices can be given and still be a list rather than a slot.
    private static let narrowest = CGSize(width: 380, height: 320)
    /// How tall the scrolling part is allowed to grow before it scrolls instead. A sheet that
    /// grows with its contents is a sheet that covers the timeline it was opened from.
    private static let tallest: CGFloat = 420

    let model: NoticeModel?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.pad) {
            header
            if let model, !model.notices.isEmpty {
                list(model.notices)
            } else {
                // Centred, the way `PlaceholderView` centres what it has to say. A sheet is
                // as tall as the platform makes it, and a line of text pinned to the top of
                // one leaves a void underneath that reads as a list that failed to load —
                // which is the one thing an empty inbox must not look like.
                Text(t("timeline.notifications.empty"))
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Size.prose, maxHeight: .infinity, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
            why
        }
        .padding(Space.room)
        .frame(minWidth: Self.narrowest.width, minHeight: Self.narrowest.height)
        .task { await model?.markSeen() }
    }

    private var header: some View {
        HStack {
            Text(t("timeline.notifications")).fediqoFont(TypeScale.section, weight: .semibold)
            Spacer()
            Button(t("common.close"), action: onClose)
                .buttonStyle(.plain)
                .fediqoFont(TypeScale.small)
                .foregroundStyle(.secondary)
        }
    }

    private func list(_ notices: [Notice]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(notices) { NoticeRow(notice: $0) }
            }
        }
        .frame(maxHeight: Self.tallest)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Why a notice can be late, in the fewest words that are still true.
    ///
    /// Under the list rather than over it: a reader opening this sheet came for what happened,
    /// and the rule is what they read once and then never again. It stays on the screen rather
    /// than hiding behind a button, because the day it matters is the day something is late
    /// and that is not a day to go looking for an explanation.
    private var why: some View {
        Text(t("notices.why"))
            .fediqoFont(TypeScale.minor)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One thing that happened, at the height every other row in this list is.
struct NoticeRow: View {
    let notice: Notice

    /// One line of what was said, and no more. S6 says a row is bounded, and this is where the
    /// bound is here: a mention is read in this list to decide whether to open it, not instead
    /// of opening it, so one line is the whole of what it has to do.
    private static let quotedLines = 1

    var body: some View {
        HStack(alignment: .top, spacing: Space.step) {
            Image(systemName: notice.kind.symbolName)
                .fediqoSymbol(Glyph.lead)
                .foregroundStyle(notice.isUnseen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
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
            Text(notice.actorName.isEmpty ? notice.actorHandle : notice.actorName)
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
                Text(t("notices.late", NoticeRow.spelled(notice.lateness)))
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
    static func spelled(_ seconds: TimeInterval) -> String {
        let style = Duration.UnitsFormatStyle(
            allowedUnits: seconds >= 3600 ? [.hours] : [.minutes],
            width: .narrow
        )
        return Duration.seconds(seconds).formatted(style)
    }
}
