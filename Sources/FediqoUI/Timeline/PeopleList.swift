import SwiftUI
import Observation
import FediqoCore

/// One of the two lists on a page about somebody: who they follow, or who follows them (#90).
///
/// Asked of the same server the account page asks and of no other, and paged the way every page in
/// this app is paged — by the last row of the one before, using that server's own number.
@MainActor
@Observable
final class PeopleListModel {
    let kind: People.Kind
    let subject: PersonSubject
    /// What the account page already knows about them, which is where the counts come from — and
    /// the counts are what say whether an empty list is empty or withheld.
    let profile: Profile?

    private(set) var people: [Profile] = []
    private(set) var loading = false
    private(set) var reachedTheEnd = false
    private(set) var failure: SourceFailure?

    /// How many are asked for at once. Said here rather than at the request, because the answer
    /// coming back shorter than this is what says the list has ended.
    static let page = 40

    /// What the reader is to somebody in this list, **for the ones they have acted on**.
    ///
    /// Not fetched for the list. A relationship is a fact on the reader's own server and every
    /// row here is somebody else's server's account of a person, so knowing it for forty rows
    /// would be forty lookups before a single one was drawn — spent on a question most readers
    /// are not asking. So the control is an offer rather than a state, and what a row says about
    /// the reader appears once the server has answered about that row.
    private(set) var acted: [String: Relationship] = [:]
    /// Whose press is still out.
    private(set) var pressing: Set<String> = []

    private let client: any SourceClient
    private let acting: () async -> ActingAccount?
    private let id: String
    /// Where people met here are written down. Nil in a preview and in a test that is only
    /// watching what was asked of a server.
    private let store: LocalStore?
    private var asked = false

    init(kind: People.Kind, subject: PersonSubject, profile: Profile?, id: String,
         client: any SourceClient, store: LocalStore? = nil,
         acting: @escaping () async -> ActingAccount? = { nil }) {
        self.acting = acting
        self.kind = kind
        self.subject = subject
        self.profile = profile
        self.id = id
        self.client = client
        self.store = store
    }

    /// Follows somebody from inside the list, without leaving it (#90).
    ///
    /// The same path the account page takes and the same rule: nothing moves before the server
    /// answers, because whether somebody has accepted a follower is that somebody's answer.
    func setFollow(_ person: Profile) async {
        guard let account = await acting() else {
            failure = .needsSignIn(subject.host)
            return
        }
        guard pressing.insert(person.authorId).inserted else { return }
        defer { pressing.remove(person.authorId) }
        do {
            acted[person.authorId] = try await client.setFollow(
                !(acted[person.authorId]?.isOn ?? false), with: person.handle, as: account)
        } catch {
            failure = SourceFailure.of(error)
        }
    }

    /// Why this list is empty, where it is. Not a thing a list can say about itself: a server
    /// answers a withheld list and an empty one identically, and the count beside it is the only
    /// thing that tells them apart.
    var reason: People.Reason {
        guard people.isEmpty, !loading else { return .some }
        return People.reason(forEmpty: kind, on: profile)
    }

    /// The first page, once.
    func read() async {
        guard !asked else { return }
        asked = true
        await more()
    }

    /// The page after the last, or the first where there is none yet.
    func more() async {
        guard !loading, !reachedTheEnd else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await client.people(kind, of: id, host: subject.host, limit: Self.page,
                                               before: people.last, token: nil)
            // Nothing new is not the same as nothing: a page that repeats what is already here
            // is a server that has run out, and asking it again would be asking for the same
            // rows for ever.
            let held = Set(people.map(\.authorId))
            let fresh = page.filter { !held.contains($0.authorId) }
            people += fresh
            // A short page is the end as surely as an empty one. A server asked for forty and
            // answering with three has no fourth to give, and offering "More" there is offering
            // a press that spends a request to change nothing.
            reachedTheEnd = fresh.isEmpty || page.count < Self.page
            // Everybody in `accounts` until now arrived by writing something this device read.
            // These have written nothing anybody here has seen, and they are people all the
            // same — so they are written down the way a sighting writes one (#90).
            //
            // Not the reader's business if it fails: what is on the screen is what the server
            // said, and the store having trouble is not a reason to take a list away.
            try? await store?.saw(fresh, on: Server(host: subject.host, socialProtocol: .mastodon))
        } catch {
            failure = SourceFailure.of(error)
            // A page that failed is not a list that has ended. Stopping here rather than marking
            // the end leaves the reader able to ask again.
        }
    }
}

/// The two lists, as a screen.
///
/// Every row is a person and pressing one opens their page, which is what makes these lists what
/// they are for: you follow one person, and the next twenty come from looking at whom they read.
struct PeopleList: View {
    let model: PeopleListModel
    var done: () -> Void = {}

    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.gap) {
                    ForEach(model.people, id: \.authorId) { person in
                        row(person)
                    }
                    emptiness
                    if model.loading { ProgressView().controlSize(.small).padding(Space.pad) }
                    if !model.people.isEmpty, !model.reachedTheEnd, !model.loading {
                        Button(t("people.more")) { Task { await model.more() } }
                            .buttonStyle(.bordered)
                            .padding(.vertical, Space.step)
                    }
                }
                .padding(Space.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.surface(colorScheme))
        .task { await model.read() }
    }

    private var header: some View {
        HStack(spacing: Space.mid) {
            Button(action: done) {
                Label(t("person.back"), systemImage: "chevron.left")
                    .fediqoFont(TypeScale.small, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .keyboardShortcut(.escape, modifiers: [])
            .fixedSize()

            // Which of the two this is. The whole difference between the screens, so it is said
            // rather than left to be worked out from whose page it was opened from.
            Text(t(model.kind == .following ? "people.following" : "people.followers"))
                .fediqoFont(TypeScale.lead, weight: .semibold)
                .fixedSize()
            Spacer(minLength: Space.snug)
            Text(model.subject.handle)
                .fediqoFont(TypeScale.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Space.pad)
        .padding(.vertical, Space.mid)
        .background(PageHeaderBackground())
    }

    /// One person. The same press the row of a post gives their name and picture, so that a reader
    /// who has learned it once knows it everywhere.
    private func row(_ person: Profile) -> some View {
        Button { app.openPerson(person, from: model.subject.host) } label: {
            HStack(spacing: Space.gap) {
                RemoteImage(url: person.avatarURL, width: Size.avatar, height: Size.avatar,
                            standing: .avatar)
                VStack(alignment: .leading, spacing: Space.hair) {
                    EmojiText(person.name, emojis: person.emojis,
                              size: TypeScale.body, weight: .semibold)
                        .lineLimit(1)
                    Text(person.handle)
                        .fediqoFont(TypeScale.minor)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.snug)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(person.name))
        .accessibilityHint(Text(t("person.title")))
        // Beside the row rather than in it, so the press that opens somebody and the press that
        // follows them are two presses and not one with a small target inside it.
        .overlay(alignment: .trailing) { follow(person) }
    }

    /// **An offer, not a state.** What the reader is to each of forty people is forty questions
    /// to their own server, asked before a row is drawn, about something most readers are not
    /// asking — so the control says what it will do and the row says what came back once the
    /// server has answered about that row.
    @ViewBuilder
    private func follow(_ person: Profile) -> some View {
        let what = model.acted[person.authorId]
        Button { Task { await model.setFollow(person) } } label: {
            Label(t(what?.isOn == true ? "person.unfollow" : "person.follow"),
                  systemImage: what?.isOn == true ? "checkmark" : "person.badge.plus")
                .fediqoFont(TypeScale.caption, weight: .medium)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .tint(what?.isOn == true ? Color.secondary : Palette.accent)
        .disabled(model.pressing.contains(person.authorId))
        .help(t(what?.isOn == true ? "person.unfollow" : "person.follow"))
        .accessibilityLabel(Text(t(what?.isOn == true ? "person.unfollow" : "person.follow")))
    }

    /// **An empty list is not one fact** (S5). A server answers a withheld list and an empty one
    /// identically, so what is drawn over it comes from the count beside it — and where no count
    /// was sent, this app says it does not know rather than picking the tidier reading.
    @ViewBuilder
    private var emptiness: some View {
        switch model.reason {
        case .some:
            EmptyView()
        case .withheld:
            note(t("people.withheld"), "eye.slash")
        case .none:
            note(t("people.none"), "person.2")
        case .unknown:
            note(t("people.unknown", model.subject.host), "questionmark.circle")
        }
    }

    private func note(_ words: String, _ symbol: String) -> some View {
        Label(words, systemImage: symbol)
            .fediqoFont(TypeScale.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Space.gap)
    }
}
