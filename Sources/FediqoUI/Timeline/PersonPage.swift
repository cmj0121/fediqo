import SwiftUI
import FediqoCore

/// One person, and what the reader is to them.
///
/// Over the shell the way an opened post is, rather than a fifth place in the rail: it is
/// somewhere a reader goes and comes back from, and what was underneath keeps its scroll and its
/// ring. Pressing an author's avatar and name is what opens it (#88).
///
/// **Two servers answer this page and it says which said what.** Who they are and what they wrote
/// comes from the server that handed their post over — one the reader already reads. What the
/// reader is to them can only come from the reader's own account, and where there is no account
/// there is no answer rather than a made-up one.
struct PersonPage: View {
    let model: PersonModel
    var done: () -> Void = {}

    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    /// The picture at the top of a page, which is a portrait rather than a mark beside a line.
    private static let portrait: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.band) {
                    who
                    theirPosts
                }
                .padding(Space.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.surface(colorScheme))
        .task { await model.read() }
    }

    // MARK: - the way back

    /// Which server this page is somebody's account of, where there is room to say it.
    ///
    /// Widest first (S9), and **the whole row is what is offered** rather than only the line at
    /// the end of it. Wrapping the line alone measured it against the space the row happened to
    /// have and answered "it fits", after which the row took the difference out of everything
    /// else: `Back` and `Person` were drawn broken across two lines each. An arrangement has to
    /// be a whole arrangement or it is only a suggestion.
    ///
    /// The narrow one drops the line rather than cutting it. `As cedar.example has t…` is a
    /// sentence that has stopped being one, and half a caveat is worse than none — the same
    /// fact is on the page below, in the handle.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(sayingWhere: true)
            headerRow(sayingWhere: false)
        }
        .padding(.horizontal, Space.pad)
        .padding(.vertical, Space.mid)
        .background(PageHeaderBackground())
    }

    private func headerRow(sayingWhere: Bool) -> some View {
        HStack(spacing: Space.mid) {
            Button(action: done) {
                Label(t("person.back"), systemImage: "chevron.left")
                    .fediqoFont(TypeScale.small, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .keyboardShortcut(.escape, modifiers: [])
            // Neither of these may give: a way out and the name of the page are the two things
            // a header cannot be without, and a word broken across two lines is worse than the
            // caveat that was dropped to make room for it.
            .fixedSize()

            Text(t("person.title"))
                .fediqoFont(TypeScale.lead, weight: .semibold)
                .fixedSize()
            if model.loading { ProgressView().controlSize(.small) }
            Spacer(minLength: Space.snug)
            if sayingWhere { readFrom }
        }
    }

    private var readFrom: some View {
        Text(t("person.readFrom", model.subject.host))
            .fediqoFont(TypeScale.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: - who they are

    private var who: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            // Widest first (S9): the portrait beside the name where there is room for it, and
            // above it where there is not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Space.gap) { portrait; names }
                VStack(alignment: .leading, spacing: Space.gap) { portrait; names }
            }
            if !note.isEmpty {
                EmojiText(note, emojis: model.emojis, size: TypeScale.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            counts
            relationship
        }
    }

    private var portrait: some View {
        RemoteImage(url: model.avatarURL, width: Self.portrait, height: Self.portrait,
                    standing: .avatar)
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            EmojiText(model.name, emojis: model.emojis,
                      size: TypeScale.title, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.handle)
                .fediqoFont(TypeScale.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.relationship?.followedBy == true {
                mark("person.followsYou", "arrow.turn.down.left")
            }
            if model.profile?.locked == true {
                mark("person.locked", "lock")
            }
        }
    }

    private func mark(_ key: String, _ symbol: String) -> some View {
        Label(t(key), systemImage: symbol)
            .fediqoFont(TypeScale.caption)
            .foregroundStyle(.tertiary)
    }

    private var note: String { model.profile?.note ?? "" }

    /// Three counts, and **a count nobody sent is not drawn at all** (S5). A server that did not
    /// say how many people somebody knows has not said nobody does.
    @ViewBuilder
    private var counts: some View {
        let numbers = [(model.profile?.posts, "person.posts"),
                       (model.profile?.followers, "person.followers"),
                       (model.profile?.following, "person.following")]
            .compactMap { count, key in count.map { ($0, key) } }

        if !numbers.isEmpty {
            HStack(spacing: Space.betweenGroups) {
                ForEach(numbers, id: \.1) { count, key in
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(count, format: .number)
                            .fediqoFont(TypeScale.lead, weight: .semibold)
                            .contentTransition(.numericText())
                        Text(t(key)).fediqoFont(TypeScale.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - what you are to them

    /// The follow control, and the two things it has to be able to say that a star does not.
    ///
    /// **Nothing moves before the server answers.** A star is a mark on a post and the reader is
    /// the authority on it, so it moves at once and goes back if refused; whether somebody has
    /// accepted a follower is that somebody's answer, and drawing "following" on the press would
    /// announce an approval nobody has given.
    @ViewBuilder
    private var relationship: some View {
        VStack(alignment: .leading, spacing: Space.step) {
            HStack(spacing: Space.gap) {
                Button {
                    Task { await model.setFollow(!(model.relationship?.isOn ?? false)) }
                } label: {
                    Label(t(followLabel), systemImage: followSymbol)
                        .fediqoFont(TypeScale.body, weight: .medium)
                        .frame(minWidth: Size.button)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.relationship?.isOn == true ? Color.secondary : Palette.accent)
                .disabled(model.following)

                if model.following { ProgressView().controlSize(.small) }
                if model.relationship?.muting == true { mark("person.muted", "speaker.slash") }
            }

            // Two silences that are not the same, and the page says which one it is in. Neither
            // is an error and neither is drawn as "not following".
            if !model.hasRelationship {
                Text(t(app.signIn == nil ? "person.needsAccount" : "person.unknownHere"))
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var followLabel: String {
        guard let what = model.relationship else { return "person.follow" }
        if what.requested { return "person.requested" }
        return what.following ? "person.unfollow" : "person.follow"
    }

    private var followSymbol: String {
        guard let what = model.relationship, what.isOn else { return "person.badge.plus" }
        return what.requested ? "clock" : "checkmark"
    }

    // MARK: - what they wrote

    @ViewBuilder
    private var theirPosts: some View {
        if model.posts.isEmpty {
            if !model.loading {
                Text(t("person.nothing")).fediqoFont(TypeScale.body).foregroundStyle(.secondary)
            }
        } else {
            LazyVStack(spacing: Space.gap) {
                ForEach(model.posts, id: \.mergeKey) { post in
                    PostRow(post: post, condensed: true) { app.expand(post) }
                        .fediqoCard()
                }
            }
        }
    }
}
