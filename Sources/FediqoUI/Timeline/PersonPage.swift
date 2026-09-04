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
            // The ring moving where nobody can see it is the key doing nothing, as far as the
            // reader is concerned — so the same director the timeline has, watching from a
            // body of its own rather than from this one (#71).
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.band) {
                        who
                        theirPosts
                    }
                    .padding(Space.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background { ScrollDirector(place: model.place, proxy: proxy) }
            }
            // Their posts are the timeline's rows, so they are arranged the way the timeline
            // arranges them: measured once for the page, at the width a row here actually has.
            // `Space.pad` is what the scrolling column is padded by, and it is not a row's (#118).
            .fediqoMeasuresRows(rowsInsetBy: Space.pad)
        }
        .background(Palette.surface(colorScheme))
        .task { await model.read() }
        // A run told to open one of the two lists does it once the page has an id to ask by.
        // The same shape every other launch variable has, and the same reason (#30).
        .task(id: model.profile?.id) {
            guard let kind = app.openingPeople, app.people == nil, model.profile != nil
            else { return }
            app.openPeople(kind)
        }
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
                EmojiText(prose: note, emojis: model.emojis, size: TypeScale.body)
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
                    // Two of the three are the way out to a list, and the count is the control:
                    // it is already the words for it, and a button beside it saying "Followers"
                    // again would be the same label twice. The posts count is not a way anywhere
                    // — the posts are on this page already.
                    let kind: People.Kind? = switch key {
                    case "person.followers": .followers
                    case "person.following": .following
                    default: nil
                    }
                    Button { if let kind { app.openPeople(kind) } } label: {
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text(count, format: .number)
                                .fediqoFont(TypeScale.lead, weight: .semibold)
                                .contentTransition(.numericText())
                            Text(t(key)).fediqoFont(TypeScale.caption)
                                .foregroundStyle(kind == nil ? .secondary : Palette.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(kind == nil || model.profile == nil)
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
            // Widest first (S9). Beside the control where the row can hold both, under it where
            // it cannot — and not a handle cut down the middle, which is what a single
            // arrangement gave at 420 points: `@ada…r.example` names nobody, and naming which
            // account this is is the whole of why the line is here.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.gap) {
                    followControl
                    actingAs
                    Spacer(minLength: Space.tight)
                }
                VStack(alignment: .leading, spacing: Space.tight) {
                    HStack(spacing: Space.gap) { followControl; Spacer(minLength: Space.tight) }
                    actingAs
                }
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

    /// The press itself, and what is standing beside it while it is out.
    private var followControl: some View {
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
        .fixedSize()
    }

    /// Which account this follow would be, and which account the relationship above is about.
    ///
    /// **One fact and not two.** Whether the reader follows somebody is a fact on one server, so
    /// a page that says "Following" without saying whose following it is has answered a question
    /// nobody asked — and with more than one account signed in, pressing here makes one of them
    /// follow somebody the reader may not have meant. The composer says it for a reply (#87) and
    /// this says it for a follow, from the same door both acts use.
    ///
    /// Nothing where nobody is signed in: the sentence under the control already says so, and
    /// two ways of saying it is one too many.
    @ViewBuilder
    private var actingAs: some View {
        if let handle = model.actingHandle {
            Text(t("person.as", handle))
                .fediqoFont(TypeScale.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Whole or on its own line. A handle cut in the middle is a handle that names
                // nobody, and `ViewThatFits` above is what gives it the other line.
                .fixedSize()
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

    /// One of their posts, drawn the way that same post is drawn in the timeline.
    private func theirs(_ post: Post) -> some View {
        let ringed = post.mergeKey == model.place.selection
        return PostRow(post: post,
                       selected: ringed,
                       turns: ringed ? app.mediaTurns : 0,
                       plays: ringed ? app.mediaPlays : 0,
                       covers: ringed ? app.mediaCovers : 0,
                       revealed: app.preferences.showSensitive,
                       answering: FeedScreen.answering(post, among: model.posts,
                                                       orKnown: app.parentHandles),
                       focus: { model.place.select(post) },
                       openAuthor: { app.openPerson(of: post) },
                       open: { app.expand(post) })
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
                    // Everything the timeline hands a row, because it is the same row: this
                    // drew a card inside a card — `PostRow` already carries one — and passed
                    // none of the rest, so a post on somebody's page had no ring, ignored the
                    // reader's standing answer about what an author covered, never said it was
                    // a reply, and had a name that could not be pressed (#94).
                    theirs(post)
                }
            }
        }
    }
}
