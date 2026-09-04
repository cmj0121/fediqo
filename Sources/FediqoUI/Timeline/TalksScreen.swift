import SwiftUI
import FediqoCore

/// Who you are talking to (#109).
///
/// **A page of its own, because it is a different thing.** #103 says a new reading that needed a
/// new screen would be the shape breaking; this one cuts the other way, and the issue says so:
/// `/api/v1/conversations` answers with conversations rather than posts — an id, the people in
/// it, whether it is unread, and what was said last. A timeline is a stretch of time made of
/// posts; this is a set of threads made of people.
///
/// Drawn as a list of people and a line, not as rows. A row is built to answer what a post says,
/// who wrote it, and what can be done to it; here the answer to *who* is several people, and
/// what a reader came for is *what was said last*.
struct TalksScreen: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    private var model: TalksModel { app.talks }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(titleKey: RailItem.talks.titleKey,
                       subtitle: t("talks.subtitle"),
                       loading: model.loading) {
                EmptyView()
            } controls: {
                IconButton(symbol: "arrow.clockwise", labelKey: "timeline.refresh") {
                    Task { await model.read() }
                }
            }
            Hairline()
            body(for: model.talks)
        }
        .background(Palette.surface(colorScheme))
        // Keyed on the accounts, not on the page appearing. Who is signed in arrives over the
        // keychain after the shell is drawn, so a page that asked once on appear would ask
        // before there was anybody to ask as — and would then be right about nothing until the
        // app was next launched.
        .task(id: app.yourAccounts) { await model.readIfNeeded() }
    }

    @ViewBuilder
    private func body(for talks: [Talk]) -> some View {
        if talks.isEmpty {
            VStack(spacing: Space.mid) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .fediqoSymbol(Glyph.big, weight: .light)
                    .foregroundStyle(.tertiary)
                Text(t(model.failures.isEmpty ? "talks.empty" : "talks.refused"))
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Size.prose)
            }
            .padding(Space.room)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.gap) {
                    ForEach(talks) { talk in
                        row(talk)
                    }
                }
                .padding(Space.gap)
            }
        }
    }

    /// One conversation: who is in it, what was said last, and where it is.
    ///
    /// **The order is the conversation's and not time's**, and the page says so in its own line
    /// rather than by drawing a timestamp that would make it look sorted. Pressing it opens the
    /// whole thread, which is `thread` and was already built.
    private func row(_ talk: Talk) -> some View {
        Button { open(talk) } label: {
            HStack(alignment: .top, spacing: Space.gap) {
                if talk.unread {
                    // Unread is the server's answer, not this app's guess: read is a fact about
                    // an account rather than about a device, and a reader who read it on their
                    // phone has read it.
                    Circle().fill(Palette.accent)
                        .frame(width: Size.dot, height: Size.dot)
                        .padding(.top, Space.snug)
                        .accessibilityLabel(Text(t("talks.unread")))
                } else {
                    Color.clear.frame(width: Size.dot, height: Size.dot)
                }
                VStack(alignment: .leading, spacing: Space.tight) {
                    HStack(spacing: Space.snug) {
                        ForEach(talk.people.prefix(4), id: \.authorId) { person in
                            RemoteImage(url: person.avatarURL, width: Size.avatar,
                                        height: Size.avatar, standing: .avatar)
                        }
                        // `EmojiText`, because a name can be written partly in pictures and a
                        // shortcode is what the server sends. Its plain init, which does not
                        // hunt for addresses: a name is not prose (#119).
                        EmojiText(who(talk), emojis: talk.people.flatMap(\.emojis),
                                  size: TypeScale.small, weight: .medium)
                            .lineLimit(1)
                        Spacer(minLength: Space.tight)
                        // Which server it is held on. A conversation belongs to one account on
                        // one server, and with several signed in a reader has to be able to
                        // tell whose conversation this is.
                        Text(talk.host)
                            .fediqoFont(TypeScale.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let said = talk.last?.text, !said.isEmpty {
                        Text(said)
                            .fediqoFont(TypeScale.minor)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        // A conversation whose last post has been deleted is still a
                        // conversation, and saying nothing about it beats inventing a line.
                        Text(t("talks.nothingSaid"))
                            .fediqoFont(TypeScale.minor)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(Space.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fediqoCard()
        }
        .buttonStyle(.plain)
    }

    /// Who is in it, in the words a reader would use. Nobody but the reader is a conversation
    /// with yourself, which Mastodon does answer with and which is a real thing to have.
    private func who(_ talk: Talk) -> String {
        let names = talk.people.map { $0.name.isEmpty ? $0.handle : $0.name }
        return names.isEmpty ? t("talks.justYou") : names.joined(separator: ", ")
    }

    private func open(_ talk: Talk) {
        guard let post = talk.last else { return }
        app.expand(post)
    }
}
