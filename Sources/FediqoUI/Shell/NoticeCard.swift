import FediqoCore
import SwiftUI

// A notice drawn as what it is about (#375): the post's own row, the person's own row, or who
// in faces over the person's own post — under the one quiet line of what happened. What has no
// post or person behind it stays the line it was.

/// What a notice is drawn as. Decided from the notice alone, so the page, a test and a listener
/// read one answer.
enum NoticeShape: Equatable {
    /// The line it always was: the server's word, an admin's notice, a relationship the server
    /// cut, a year looked back on, a kind this build does not know — and any notice whose post or
    /// person did not come with it.
    case line
    /// What happened, over that post's own row: an answer, a mention, a quotation, a new post from
    /// somebody the person asked to be told of, a poll that ended, a boosted post changed.
    case post(Note)
    /// Who, as faces, over the person's own post drawn short: a boost, a favourite. Where the
    /// source gathered several follows into one line, who without a post.
    case faces(Note?)
    /// The person who followed: their row, with what can be done to them in its `…`.
    case follower(NoticePerson)
    /// The person who asks to follow: their row, with accepting on it and declining in its `…`.
    case request(NoticePerson)

    /// The person a follower's or a request's card is of.
    static func person(of notice: Notice) -> NoticePerson? {
        switch of(notice) {
        case .follower(let person), .request(let person): person
        default: nil
        }
    }

    /// **Grouping is the source's**: a line it gathered is drawn as one card, and never joined
    /// to another or split here.
    static func of(_ notice: Notice) -> NoticeShape {
        switch notice.kind {
        case .mention, .quote, .poll, .update:
            return notice.post.map { .post($0) } ?? .line
        case .unknown("status"):
            return notice.post.map { .post($0) } ?? .line
        case .reblog, .favourite:
            return notice.post.map { .faces($0) } ?? .line
        case .follow:
            guard let first = notice.people.first else { return .line }
            return notice.people.count == 1 && notice.count <= 1 ? .follower(first) : .faces(nil)
        case .followRequest:
            return notice.people.first.map { .request($0) } ?? .line
        case .server, .unknown:
            return .line
        }
    }
}

extension NoticeWords {
    /// What a listener is read of the line of a card (#375): what happened, its source and when —
    /// and the post's words only where no row of the post is drawn under it, which says them.
    @MainActor
    static func spokenLine(_ notice: Notice, language: DummyLanguage? = nil) -> String {
        spoken(
            notice, who: who(notice, language: language), what: what(notice, language: language),
            excerpt: NoticeShape.of(notice) == .line ? excerpt(notice, language: language) : nil, language: language
        )
    }

    /// How many faces a line of who draws, newest first: enough to see that it is several.
    static let faces = 6

    /// Who, as the faces line names them: the first one or two by name, and how many others —
    /// "A, B and 3 others". The others are the source's count, not only who it sent.
    static func facesNamed(_ notice: Notice) -> (names: [String], others: Int) {
        let named = notice.people.prefix(2).map(name)
        return (Array(named), max(0, max(notice.count, notice.people.count) - named.count))
    }

    /// The names of a faces line, joined as the language joins two.
    static func facesNames(_ notice: Notice, language: DummyLanguage? = nil) -> String {
        let (names, others) = facesNamed(notice)
        guard names.count == 2 else { return names.first ?? "" }
        let key = others > 0 ? "notices.faces.list" : "notices.faces.pair"
        return String(format: L10n.t(key, language: language), names[0], names[1])
    }

    /// "and 3 others", where there are any: the press that opens who they are.
    static func facesOthers(_ notice: Notice, language: DummyLanguage? = nil) -> String? {
        let others = facesNamed(notice).others
        return others > 0 ? L10n.count("notices.faces.others", others, language: language) : nil
    }
}

/// One notice, drawn as what it is about (`NoticeShape`): the line of what happened, and under it
/// the post's row, who in faces over the person's post, or the person's row.
///
/// **Each part keeps its own press and its own `…`**, side by side and never one inside the other:
/// the line's long press opens the line's panel, the post's opens the post's, so one hold is never
/// taken by a row inside another.
struct NoticeCard: View {
    let notice: Notice
    let session: ShellSession
    var people: ShellPersonPages?
    var selected = false
    var tooOld = false
    var onPress: () -> Void
    var onOpen: (() -> Void)?
    var onOpenPerson: (DummyPerson) -> Void
    var onOpenPeople: (PeopleList) -> Void
    var heard: ((String) -> Void)?
    var menu: NoticeRow.Menu
    /// The page's one asker, where a post row's or a person row's chosen item puts its question.
    var asked: Binding<ShellMoreAsk?>
    /// What a post row's pictures open and play through, as on the timeline. Nothing where the
    /// page is drawn with none: a fixture.
    var media: NoticeMedia?

    @Environment(DummyPrefs.self) private var prefs

    #if DEBUG
    /// How many cards have been drawn: what a test reads to hold that a long list draws only the
    /// cards on screen.
    nonisolated(unsafe) static var drawn = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.drawn += 1
        #endif
        let shape = NoticeShape.of(notice)
        VStack(alignment: .leading, spacing: 0) {
            NoticeRow(
                notice: notice, selected: selected, tooOld: tooOld, onPress: onPress, onOpen: onOpen,
                onOpenPerson: onOpenPerson, heard: heard, menu: menu, excerpts: shape == .line
            )
            switch shape {
            case .line:
                EmptyView()
            case .post(let post):
                postRow(post)
            case .faces(let post):
                NoticeFaces(notice: notice, onOpenPerson: onOpenPerson, onOthers: others(of: post))
                if let post { ownPost(post) }
            case .follower(let person):
                personRow(person, asks: false)
            case .request(let person):
                personRow(person, asks: true)
            }
        }
    }

    // MARK: - A post

    /// The post's own row, as the timeline draws it: **the store's copy where it holds one**, so
    /// what is done to it here shows there at once, and the reverse; the notice's own where it does
    /// not — a post older than this device keeps is still drawn, and says so when opened.
    private func postRow(_ post: Note) -> some View {
        let item = Self.item(post, in: session)
        let making = RowActing(
            session: session, people: people, linkPreviews: prefs.linkPreviews,
            serverFilters: prefs.serverFilters,
            openThread: { _ in onOpen?() }, openPeople: { list, _ in onOpenPeople(list) }
        )
        return DummyItemRow(
            item: item,
            catalogues: session.emoji,
            posts: session.posts,
            acting: Self.acting(post, in: session, making: making),
            selected: selected,
            top: media?.decks.wrappedValue.top(of: item.id, of: item.attachments.count) ?? 0,
            lifted: media?.decks.wrappedValue.isLifted(item.id) ?? false,
            player: media.flatMap { $0.playback.rowPlayer(for: item, decks: $0.decks.wrappedValue) },
            onSelect: onPress,
            onOpen: onOpen,
            onOpenPerson: onOpenPerson,
            quoteLifted: media?.decks.wrappedValue.isQuoteLifted(of: item) ?? false,
            onToggleQuoteCover: { media?.decks.wrappedValue.toggleQuoteCover(of: item) },
            onToggleCover: { _ = media?.decks.wrappedValue.toggleCover(item.id) },
            onPlay: { media?.play(item) },
            onView: { media?.view(item) },
            onViewAt: { at in
                media?.decks.wrappedValue.show(item.id, at: at, of: item.attachments.count)
                media?.view(item)
            },
            onTurn: { media?.turn(item) },
            onEnded: { media?.playback.stop() }
        )
    }

    /// The row a notice's post is drawn as: the store's copy where it holds one.
    static func item(_ post: Note, in session: ShellSession) -> DummyItem {
        DummyItem(session.heldNote(key: post.key) ?? post)
    }

    /// Whether the store will not hold `post`: older than the person keeps, as the store's window
    /// says, or found so when it was asked to hold it.
    static func tooOld(_ post: Note, in session: ShellSession) -> Bool {
        session.noticeList.notHeld.contains(post.key) || (session.keepFrom.map { post.postedAt < $0 } ?? false)
    }

    /// The acts of a notice's post (#375). **Held, it is the store's row's**, and acts as it does
    /// on the timeline. **Not yet held, a press holds it first** — as opening it does — and then
    /// acts on the row held, so what is done lands in the store and shows on the timeline. **One
    /// the store will not hold offers no act**, each mark dim with that reason, which a press says.
    static func acting(_ post: Note, in session: ShellSession, making: RowActing) -> ItemActing {
        let item = item(post, in: session)
        var acting = making(item)
        if tooOld(post, in: session) {
            acting.acts = PostActs(offered: [], refused: .tooOld)
            acting.keep = nil
            acting.vote = nil
            acting.withdraw = nil
            return acting
        }
        guard session.heldNote(key: post.key) == nil else { return acting }
        /// Holds the post, then does `then` on the row held. A second press while the first is
        /// holding is not sent. Refused for its age, the row says so from then on; refused for
        /// anything else, that is said, and nothing is done.
        func held(_ then: @escaping @MainActor (ItemActing) -> Void) {
            guard session.noticeList.beginHolding(post.key) else { return }
            Task { @MainActor in
                defer { session.noticeList.endHolding(post.key) }
                guard let row = await session.landed(noticePost: post), let note = session.heldNote(row) else {
                    if let from = await session.store.keepFrom, post.postedAt < from {
                        session.noticeList.wouldNotHold(post.key)
                    } else {
                        session.showToast(L10n.t("notices.post.unheld"))
                    }
                    return
                }
                then(making(DummyItem(note)))
            }
        }
        if acting.perform != nil { acting.perform = { act in held { $0.perform?(act) } } }
        if acting.keep != nil { acting.keep = { held { $0.keep?() } } }
        if acting.vote != nil { acting.vote = { choices in held { $0.vote?(choices) } } }
        // Quieting its conversation, and pinning it, go through the row held as well.
        if let quiet = acting.post?.quiet {
            acting.post?.quiet = ItemActing.PostMore.Turn(on: quiet.on, out: quiet.out, lock: quiet.lock) {
                held { $0.post?.quiet?.press() }
            }
        }
        if let pin = acting.post?.pin {
            acting.post?.pin = ItemActing.PostMore.Turn(on: pin.on, out: pin.out, lock: pin.lock) {
                held { $0.post?.pin?.press() }
            }
        }
        return acting
    }

    /// The person's own post, short and quieter: the news is who, not the post.
    private func ownPost(_ post: Note) -> some View {
        QuoteCard(post: QuotedPost(post), host: notice.source.host, lifted: false, onOpen: onOpen, onToggleCover: {})
            .padding(.horizontal, ShellSpace.pad)
            .padding(.bottom, ShellSpace.step)
    }

    /// Who boosted or favourited the post, as a list of its own; nothing for a line of follows.
    private func others(of post: Note?) -> (() -> Void)? {
        guard let list = Self.others(of: notice, about: post, in: session) else { return nil }
        return { onOpenPeople(list) }
    }

    /// Who "and 3 others" opens: who boosted or favourited the post, or — on a gathered line of
    /// follows — the reader's own followers at that source. Nothing where the source has not said
    /// who the reader is there.
    static func others(of notice: Notice, about post: Note?, in session: ShellSession) -> PeopleList? {
        let host = notice.source.host
        if let post {
            guard let id = post.statusID else { return nil }
            let which: PeopleList.Which = notice.kind == .reblog ? .boostedBy : .favouritedBy
            return PeopleList(which, ofPost: id, at: host, by: post.handle, counted: notice.count)
        }
        guard notice.kind == .follow else { return nil }
        return ShellPersonPages.ownFollowers(at: notice.source, in: session)
    }

    // MARK: - A person

    /// Somebody a notice names, as a row of a list of people draws them.
    static func person(_ person: NoticePerson, at source: Source) -> Person {
        Person(
            source: source, accountID: person.accountID ?? "", handle: person.handle, name: person.name,
            avatarURL: person.avatarURL, words: person.words ?? "", emojis: person.emojis
        )
    }

    private func personRow(_ who: NoticePerson, asks: Bool) -> some View {
        let person = Self.person(who, at: notice.source)
        let acting = DummyPerson(who, host: notice.source.host).flatMap { people?.stands(to: $0, in: session) }
        let key = ShellNoticeList.personKey(host: notice.source.host, accountID: person.accountID)
        let list = session.noticeList
        return PersonRow(
            person: person,
            // Their page's word where it was opened this run; the page's own ask otherwise (`stand`).
            stands: acting?.shown ?? list.stands[key],
            onPress: onPress,
            onOpen: onOpen,
            menu: NoticeRow.Menu(more: { personMore(person, acting: acting, asks: asks) }, asks: asked),
            accept: asks && Self.stillAsks(who, at: notice.source.host, in: session)
                ? { answer(.acceptRequest, on: person) } : nil
        )
    }

    /// Whether accepting is offered on a request's row: **only while the source says they still
    /// ask** — read for the lines drawn (`ShellNoticeList.stand`), and taken off at the press's yes
    /// — so a request answered here, or anywhere, is not offered again on the next read.
    static func stillAsks(_ who: NoticePerson, at host: String, in session: ShellSession) -> Bool {
        guard let id = who.accountID else { return false }
        return session.noticeList.askingToFollow.contains(ShellNoticeList.personKey(host: host, accountID: id))
    }

    /// Accepts or declines their request, as the list of who asks does, and once the source said
    /// yes takes accepting off their row.
    private func answer(_ act: PersonAct, on person: Person) {
        guard !person.accountID.isEmpty, let acts = people?.acts else { return }
        let key = ShellNoticeList.personKey(host: notice.source.host, accountID: person.accountID)
        Task {
            let came = await acts.pressRowCame(act, on: person, standing: nil, listed: .requests, in: session)
            if came.sourceDid { session.noticeList.answered(key, now: came.said) }
        }
    }

    /// The person row's `…`: what their page's `…` holds where their page has said how the reader
    /// stands to them; otherwise what the notice itself says — they follow, or ask to — can be
    /// undone from here: removing them as a follower, or declining. Then the notice's own Dismiss.
    private func personMore(_ person: Person, acting: PersonActing?, asks: Bool) -> ShellMore {
        let dismiss = NoticeActs.more(notice, in: session).items
        let who = DummyPerson(person)
        if let acting, let people {
            return ShellMore(items: acting.menu { act in Task { await people.act(act, on: who, in: session) } }.items + dismiss)
        }
        guard !person.accountID.isEmpty, let acts = people?.acts else { return ShellMore(items: dismiss) }
        if asks {
            // Declining, only while they still ask.
            guard let who = NoticeShape.person(of: notice), Self.stillAsks(who, at: notice.source.host, in: session) else {
                return ShellMore(items: dismiss)
            }
            let decline = ShellMoreItem.danger(
                PersonActing.symbol(.refuseRequest), PersonActing.name(.refuseRequest),
                asks: ShellQuestion.about(.refuseRequest, person.lineHandle, at: notice.source.host)
            ) { answer(.refuseRequest, on: person) }
            return ShellMore(items: [decline] + dismiss)
        }
        // Removing them, unless the source said they no longer follow the reader.
        let key = ShellNoticeList.personKey(host: notice.source.host, accountID: person.accountID)
        guard session.noticeList.stands[key]?.followedBy != false else { return ShellMore(items: dismiss) }
        let remove = ShellMoreItem.danger(
            PersonActing.symbol(.removeFollower), PersonActing.name(.removeFollower),
            asks: ShellQuestion.about(.removeFollower, person.lineHandle, at: notice.source.host)
        ) {
            Task { _ = await acts.pressRow(.removeFollower, on: person, standing: nil, listed: .followers, in: session) }
        }
        return ShellMore(items: [remove] + dismiss)
    }
}

/// What a notice's post row opens its pictures and plays its films through: the root's own, which
/// the timeline's rows go through (#375 — the same row it is on a timeline).
struct NoticeMedia {
    let decks: Binding<ShellDecks>
    let playback: ShellPlayback
    let play: (DummyItem) -> Void
    let view: (DummyItem) -> Void
    let turn: (DummyItem) -> Void
}

/// Who boosted or favourited the person's post, or followed them, as faces side by side and their
/// names: "A, B and 3 others". A face opens its person; "and 3 others" opens who they all are.
struct NoticeFaces: View {
    let notice: Notice
    var onOpenPerson: (DummyPerson) -> Void
    var onOthers: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .body) private var side: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            HStack(spacing: ShellSpace.tight) {
                ForEach(Array(notice.people.prefix(NoticeWords.faces).enumerated()), id: \.offset) { _, person in
                    face(person)
                }
            }
            Text(NoticeWords.facesNames(notice))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
            if let others = NoticeWords.facesOthers(notice) {
                if let onOthers {
                    Button(others, action: onOthers)
                        .buttonStyle(.plain)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .underline()
                        .fixedSize()
                } else {
                    Text(others).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme)).fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.bottom, ShellSpace.step)
    }

    @ViewBuilder
    private func face(_ person: NoticePerson) -> some View {
        let who = DummyPerson(person, host: notice.source.host)
        let drawn = Group {
            if let url = person.avatarURL {
                RemoteImage(
                    url: url, tier: .deck, host: notice.source.host, standing: .avatar, alt: nil, speaks: false,
                    radius: DummyItemRow.Box.plate
                )
            } else {
                ShellVacant(standing: .avatar, radius: DummyItemRow.Box.plate)
            }
        }
        .frame(width: side, height: side)
        if let who {
            Button { onOpenPerson(who) } label: { drawn }
                .buttonStyle(.plain)
                .help(NoticeRow.spokenPerson(who))
                .accessibilityLabel(NoticeRow.spokenPerson(who))
        } else {
            drawn.accessibilityHidden(true)
        }
    }
}
