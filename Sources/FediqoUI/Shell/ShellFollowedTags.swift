import FediqoCore
import Foundation
import Observation
import SwiftUI

// The hashtags the reader follows at a source (#318), as a list: where it is reached from,
// what is asked for it and when, and how a row unfollows.
//
// **Reached from the reader's own page at that source, and only where a sign-in sees who they
// follow.** The list is nobody's but the reader's, so its way stands where their account is
// tended. Where the sign-in does not hold the word that sees, the way is the lock of how that
// sign-in stands (`PartWords.place`), its press only raises the question, **and nothing is
// asked of the source** — not to draw the lock, and not behind it. A forum has no way, and
// with no sign-in there is none.
//
// **Asked when the list opens, and when the person presses** — a list of people's own rules
// (`ShellPeoplePages`). Opening asks one stretch; the foot's press asks the next, by the place
// the source named and no other; `r` and "Try again" ask from the top. One ask a press, never
// two on the wire, and **no more shown than `most`**: reached, the foot says so and is no
// press, and what a stretch brought past it is not drawn.
//
// **A row's press is the hashtag page's own** (`ShellTagFollow.press(_:at:to:in:)`): this
// object sends nothing that follows or unfollows, guards nothing of its own, and says a press
// that did not arrive in that page's sentence. A row unfollowed **stays where it stood**, said
// as not followed with the way back offered, as the line on the hashtag's page stays — and one
// followed again stays there too, though a read taken meanwhile does not list it.
//
// **How a row stands is what this list showed or a press was answered** — never a read of the
// list that was already on its way. Each answer is numbered on the one count every ask is
// numbered on, so a read from the top lets go of what was answered before it began, which it
// has taken in, and keeps what was answered since.
//
// **Every answer lands only where it is still the one awaited, as whoever asked, and let go
// with their sign-in** (`PageReaders`); held nowhere; and a list whose step was left is let go
// (`closed`), so a stretch come late lands nowhere. Each for the reason given where a person's
// page keeps the same rule (`ShellPersonPages`).

/// The hashtags the reader follows at one source, as a step of the walk names their page.
struct FollowedTags: Hashable, Sendable, Identifiable {
    /// The host of the source that keeps the list, and is asked for it.
    let host: String

    var id: String { "\(host)\u{1e}followed\u{1e}tags" }
}

extension ShellWalk {
    /// The page of the hashtags followed in front, where one is (#318).
    var openedFollowedTags: FollowedTags? {
        guard case .followedTags(let page) = standing else { return nil }
        return page
    }

    /// The list opened from its line on the reader's own page: one more step of the walk.
    /// **The lamp and the step in one turn**, as a list of people opens from its figure: the
    /// line is lit and is what the walk remembers, so leaving the list gives it back.
    mutating func open(_ page: FollowedTags, lamp: inout String?) -> Bool {
        guard walk(to: .followedTags(page), from: page.id) else { return false }
        lamp = page.id
        return true
    }
}

/// The way to the list, on the reader's own page: open, or the lock of how the sign-in stands.
struct FollowedTagsEntry: Equatable, Identifiable {
    let page: FollowedTags
    /// How the sign-in stands where it does not see who the reader follows. Nothing where it does.
    var locked: PartWords.Place?

    /// What the lamp stands on where it stands on this line.
    var id: String { page.id }

    /// Whether pressing a locked line asks the sign-in for who the reader follows.
    var asks: Bool { locked?.asks ?? false }

    /// Whether the line is a press — open, or a lock that asks — and so a row the keys stand on.
    var presses: Bool { locked == nil || asks }

    func words(language: DummyLanguage? = nil) -> String {
        guard let locked else { return L10n.t("followed.tags.title", language: language) }
        return String(format: L10n.t(locked.key, language: language), page.host)
    }

    /// What a listener is read: the words, and for the open way what pressing it does.
    func spoken(language: DummyLanguage? = nil) -> String {
        let said = words(language: language)
        return locked == nil ? String(format: L10n.t("person.count.opens", language: language), said) : said
    }
}

/// One hashtag on the list: the row a rising hashtag has, and how the reader stands to it.
struct FollowedTagRow: Equatable, Identifiable {
    enum Standing: Equatable {
        /// As the list showed it.
        case followed
        /// A press was answered that it is followed no longer.
        case unfollowed
        /// A press is out: following, or unfollowing.
        case doing(Bool)
    }

    let tag: PostTag
    /// The host of the source that listed it.
    let host: String
    var standing = Standing.followed
    /// What a press that did not arrive wanted: to follow, or to unfollow. Nothing otherwise.
    var missed: Bool?

    /// The row as a page of hashtags draws and opens one.
    var listed: RisingRow { .tag(RisingTag(tag: tag), source: host) }

    var id: String { listed.id }

    /// What is said under the hashtag's name, in the words its own page says it in — or
    /// nothing where it stands as every row of this list does: followed.
    func words(language: DummyLanguage? = nil) -> String? {
        switch standing {
        case .followed: nil
        case .unfollowed: TagFollowLine(host: host, tag: tag, standing: .said(false)).words(language: language)
        case .doing(let to): TagFollowLine(host: host, tag: tag, standing: .doing(to)).words(language: language)
        }
    }

    /// The sentence of a press that did not arrive, or nothing.
    func missedWords(language: DummyLanguage? = nil) -> String? {
        TagFollowLine(host: host, tag: tag, standing: .said(true), missed: missed).missedWords(language: language)
    }
}

/// What the page of the hashtags followed is handed.
struct FollowedTagsSaid: Equatable {
    enum Reading: Equatable {
        /// Not answered yet: on the wire, or about to be.
        case asking
        /// The source answered: `rows` is what it listed, which may be nothing.
        case said
        /// The source refused, failed, or sent what could not be read.
        case failed
    }

    enum Foot: Equatable {
        /// The source named a next stretch: a press reads it.
        case more
        /// A stretch is on the wire.
        case reading
        /// The source named no next: the end of the list.
        case end
        /// The last stretch asked for did not come. A press asks again.
        case failed
        /// The source stopped handing the list on in order. It ends here.
        case stopped
        /// Read as far as such a list is read here: the source has more, and none is asked for.
        case farthest

        /// Whether the foot is a press.
        var presses: Bool { self == .more || self == .failed }
    }

    /// What a row's `…` holds.
    enum Offer: Equatable {
        /// Follow it, or with false stop.
        case act(Bool)
        /// The sign-in may not change who the reader follows: how it stands, in its own line.
        case locked(PartWords.Place)
    }

    let page: FollowedTags
    var reading = Reading.asking
    /// Asking from the top came to a failure with a list already given, which stands.
    var againFailed = false
    var rows: [FollowedTagRow] = []
    /// Whether the list is being asked from the top.
    var asking = false
    var foot: Foot?
    /// How the sign-in stands where it sees who the reader follows and may not change it.
    var changing: PartWords.Place?

    /// What the `…` of `row` holds, or nothing while a press of its own is out.
    func offer(for row: FollowedTagRow) -> Offer? {
        if let changing { return .locked(changing) }
        switch row.standing {
        case .followed: return .act(false)
        case .unfollowed: return .act(true)
        case .doing: return nil
        }
    }

    /// What an offer is called in the menu: the hashtag page's own two words, or the line of
    /// how the sign-in stands.
    static func name(of offer: Offer, on row: FollowedTagRow, language: DummyLanguage? = nil) -> String {
        switch offer {
        case .act(let to): L10n.t(to ? "tag.follow.follow" : "tag.follow.unfollow", language: language)
        case .locked(let place): String(format: L10n.t(place.key, language: language), row.host)
        }
    }

    /// The menu of `row`: its one item — the one About's row holds, Unfollow red and asked
    /// about first — or, where the sign-in's standing is said and cannot be asked about, that
    /// sentence at its head. `act` is handed what the item offered when the menu was built,
    /// so a press only ever does that.
    @MainActor
    func more(for row: FollowedTagRow, act: @escaping (Bool) -> Void, ask: @escaping () -> Void) -> ShellMore? {
        guard let offer = offer(for: row) else { return nil }
        let name = Self.name(of: offer, on: row)
        switch offer {
        case .act(let to):
            return ShellMore(items: [TagFollowLine.item(to: to, tag: row.tag, at: row.host) { act(to) }])
        case .locked(let place):
            guard place.asks else { return ShellMore(head: [name], items: []) }
            return ShellMore(items: [.plain(SourceRow.permissionSymbol, name, act: ask)])
        }
    }

    // MARK: - Words

    static func title(language: DummyLanguage? = nil) -> String {
        L10n.t("followed.tags.title", language: language)
    }

    /// What is said above the rows: that the list is being asked for, that it could not be —
    /// or, once the source has given it, what asking again came to.
    func stateLine(language: DummyLanguage? = nil) -> String? {
        switch reading {
        case .asking: String(format: L10n.t("followed.tags.asking", language: language), page.host)
        case .failed: String(format: L10n.t("followed.tags.failed", language: language), page.host)
        case .said: againFailed ? String(format: L10n.t("followed.tags.again.failed", language: language), page.host) : nil
        }
    }

    /// Whether the line above the rows offers the press that asks again.
    var offersAgain: Bool { reading == .failed || againFailed }

    /// What stands where rows would, once the source has answered with none and named no
    /// next: a sentence about the source, never about the reader.
    func nothing(language: DummyLanguage? = nil) -> String? {
        guard reading == .said, rows.isEmpty, foot == nil else { return nil }
        return String(format: L10n.t("followed.tags.none", language: language), page.host)
    }

    func footSymbol(_ foot: Foot) -> String {
        switch foot {
        case .more: "arrow.down.circle"
        case .reading: "ellipsis"
        case .end: "checkmark.circle"
        case .failed: "exclamationmark.arrow.circlepath"
        case .stopped: "exclamationmark.circle"
        case .farthest: "circle.dotted"
        }
    }

    func footWords(_ foot: Foot, language: DummyLanguage? = nil) -> String {
        switch foot {
        case .more: L10n.t("followed.tags.foot.more", language: language)
        case .reading: L10n.t("followed.tags.foot.reading", language: language)
        case .end: String(format: L10n.t("followed.tags.foot.end", language: language), page.host)
        case .failed: String(format: L10n.t("followed.tags.foot.failed", language: language), page.host)
        case .stopped: String(format: L10n.t("followed.tags.foot.stopped", language: language), page.host)
        case .farthest:
            String(
                format: L10n.t("followed.tags.foot.farthest", language: language),
                L10n.grouped(rows.count, language: language), page.host
            )
        }
    }
}

/// The list of the hashtags the reader follows at each source, as far as it was read this run.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellFollowedTags {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// What a press on a row was answered, and when — on the count every ask is numbered on.
    private struct Acted {
        let followed: Bool
        let at: Int
    }

    /// One source's list: what it listed, and how far it was read.
    private struct Page {
        var askedAs: AskedAs
        /// How often the sign-in at its host had become another when the list was first asked for.
        let under: Int
        var read = FollowedTagsRead()
        /// Whether a first stretch has answered: what is drawn is then the source's word.
        var answered = false
        /// Whether the list is being asked from the top.
        var asking = false
        /// Whether asking from the top last came to a failure.
        var failed = false
        var readingOn = false
        var footFailed = false
        /// The source stopped handing the list on in order: it ends where it is.
        var notPaging = false
        /// The number of the ask or the reading-on whose answer this list awaits.
        var awaits = 0
        /// What a press was answered of a hashtag, by the hashtag folded as a source folds one.
        var acted: [String: Acted] = [:]
    }

    /// Which page a `.task` is: the list **and who asks**, so a list in front whose reader
    /// ends, begins or changes opens again by itself, and is asked.
    struct Opening: Hashable {
        let host: String
        let askedAs: AskedAs
        let under: Int
    }

    /// How many hashtags a list is read to: ten of the stretches it is asked in.
    static let most = 1_000

    /// The lists, by the host of their source.
    private var pages: [String: Page] = [:]
    /// The one ask on the wire for each list — from the top, or a reading-on.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// Whose press a row's is: the hashtag page's own guard and sentences.
    @ObservationIgnored private let tags: ShellTagFollow
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// How many hashtags the list is read to, and how long a stretch is asked to be. A test
    /// shortens them.
    @ObservationIgnored var most = ShellFollowedTags.most
    @ObservationIgnored var stretch = MastodonTagFollows.stretch

    init(errands: PageErrands, readers: PageReaders, tags: ShellTagFollow) {
        self.errands = errands
        self.readers = readers
        self.tags = tags
        tags.whenAnswered = { [weak self] tag, host, followed in self?.answered(tag, at: host, followed) }
    }

    /// Whether the sign-in at `host` holds the word that sees who the reader follows: all of
    /// follows, or the half of it that reads.
    private static func sees(at host: String, in session: ShellSession) -> Bool {
        switch session.mastodon.standing(.follows, host: host) {
        case .held: true
        case .partly: MastodonParts.half(of: .follows, in: session.mastodon.heldParts[host.lowercased()]?.scopes) == .seeing
        case .unasked, .refused, .notGiven, nil: false
        }
    }

    /// How the sign-in at `host` stands to follows where it does not hold all of it. Held in
    /// part with the rest not to be asked for has no place of its own: said, unpressed.
    private static func place(at host: String, in session: ShellSession) -> PartWords.Place {
        session.mastodon.place(.follows, host: host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
    }

    /// The source whose list `page` is, where the list may be read: it says who people are,
    /// the reader is signed in to it, and that sign-in sees who they follow.
    private func source(of page: FollowedTags, in session: ShellSession) -> Source? {
        guard session.mastodon.signedInHosts.contains(page.host), Self.sees(at: page.host, in: session) else { return nil }
        return ShellPersonPages.source(at: page.host, in: session)
    }

    /// The list as it stands **for whoever would ask now**, or nothing.
    private func standing(_ host: String, in session: ShellSession) -> Page? {
        pages[host].flatMap { page in
            page.under == ShellPersonPages.signIns(at: host, in: session)
                && page.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session)) ? page : nil
        }
    }

    // MARK: - What the pages are handed

    /// The way to the list on the page of `who`, or nothing: it is not the reader's own page
    /// at a source that says who people are. Nothing is asked to draw it.
    func entry(on who: DummyPerson, in session: ShellSession) -> FollowedTagsEntry? {
        guard let me = ShellPersonPages.own(at: who.host, in: session), me.id == who.id,
              session.mastodon.standing(.follows, host: who.host) != nil
        else { return nil }
        let page = FollowedTags(host: who.host)
        return FollowedTagsEntry(page: page, locked: Self.sees(at: who.host, in: session) ? nil : Self.place(at: who.host, in: session))
    }

    func opening(_ page: FollowedTags, in session: ShellSession) -> Opening {
        Opening(
            host: page.host, askedAs: ShellPersonPages.askedAs(at: page.host, in: session),
            under: ShellPersonPages.signIns(at: page.host, in: session)
        )
    }

    /// What the page of `page` is handed, or nothing where there is no such list to draw: no
    /// source of that kind, no sign-in, or one that does not see who the reader follows.
    func said(of page: FollowedTags, in session: ShellSession) -> FollowedTagsSaid? {
        guard let source = source(of: page, in: session) else { return nil }
        var handed = FollowedTagsSaid(page: page)
        if session.mastodon.standing(.follows, host: page.host) != .held { handed.changing = Self.place(at: page.host, in: session) }
        guard let stood = self.standing(page.host, in: session) else { return handed }
        handed.reading = stood.answered ? .said : stood.failed ? .failed : .asking
        handed.againFailed = stood.answered && stood.failed
        handed.asking = stood.asking
        let pressable = handed.changing == nil
        handed.rows = stood.read.tags.prefix(most).map { row(of: $0, on: stood, at: source, pressable: pressable, in: session) }
        handed.foot = foot(of: stood)
        return handed
    }

    /// One row: being done where a press of it is out, and otherwise as a press was last
    /// answered — or, with none answered, followed, as the list showed it.
    private func row(
        of tag: PostTag, on page: Page, at source: Source, pressable: Bool, in session: ShellSession
    ) -> FollowedTagRow {
        var row = FollowedTagRow(tag: tag, host: source.host)
        let line = pressable ? tags.line(of: tag, at: source, in: session) : nil
        if case .doing(let to) = line?.standing {
            row.standing = .doing(to)
        } else if page.acted[MastodonRising.folded(tag)]?.followed == false {
            row.standing = .unfollowed
        }
        row.missed = line?.missed
        return row
    }

    private func foot(of page: Page) -> FollowedTagsSaid.Foot? {
        guard page.answered else { return nil }
        if page.readingOn { return .reading }
        if page.notPaging { return .stopped }
        if page.footFailed { return .failed }
        // More than is shown — a stretch ran past `most` — is not the end, whatever the source named.
        if page.read.tags.count > most { return .farthest }
        if page.read.next != nil { return page.read.tags.count >= most ? .farthest : .more }
        // Nothing under no rows: what stands there says the source listed none.
        return page.read.tags.isEmpty ? nil : .end
    }

    /// The rows `j` and `k` walk on the page.
    func walked(_ page: FollowedTags, in session: ShellSession) -> [String] {
        said(of: page, in: session)?.rows.map(\.id) ?? []
    }

    /// The row `id` of the page, where the list as it is drawn holds it.
    func row(_ id: String, of page: FollowedTags, in session: ShellSession) -> FollowedTagRow? {
        said(of: page, in: session)?.rows.first { $0.id == id }
    }

    /// Whether the page has anybody to ask again — what `r` and its mark go by.
    func canAskAgain(_ page: FollowedTags, in session: ShellSession) -> Bool {
        source(of: page, in: session) != nil
    }

    // MARK: - Letting go

    /// The list of `host` let go, and its ask called off: its reader is no longer who it was
    /// given to (`PageReaders`). Whatever an ask already out brings, it brings to no list.
    func letGo(at host: String) {
        asks[host]?.cancel()
        asks[host] = nil
        pages[host] = nil
    }

    /// The list's step left: what it was told is let go, and its ask called off — and with it
    /// the word it gave each hashtag pressed, which was the list's and no hashtag page's. A
    /// press still out stays out — it is one request at the source whoever is looking — and
    /// the list, opened again, is asked afresh.
    func closed(_ page: FollowedTags) {
        letGo(at: page.host)
        tags.listClosed(at: page.host)
    }

    // MARK: - Asking

    /// The list opening. Asked once: opened again, it is drawn from what was answered; opened
    /// while it is being asked, it waits on that ask and starts none.
    func opened(_ page: FollowedTags, in session: ShellSession) async {
        guard let source = source(of: page, in: session),
              let held = readers.look(at: source.host, in: session).held
        else { return }
        if let stood = self.standing(source.host, in: session) {
            if stood.asking {
                await asks[source.host]?.value
                return
            }
            if stood.answered || stood.failed { return }
        }
        await begin(at: source, with: held, in: session).value
    }

    /// `r` and "Try again": the list asked from the top. What the page holds stays drawn until
    /// the answer lands, and is then replaced by it. **A press while the list is being asked
    /// asks nothing.**
    func again(_ page: FollowedTags, in session: ShellSession) async {
        guard let source = source(of: page, in: session),
              let held = readers.look(at: source.host, in: session).held
        else { return }
        if self.standing(source.host, in: session)?.asking == true { return }
        await begin(at: source, with: held, in: session).value
    }

    /// Starts the ask from the top, and hands back the task it runs in. Everything it needs is
    /// taken here, before anything waits: the source, who asks, the door.
    private func begin(at source: Source, with held: MastodonToken, in session: ShellSession) -> Task<Void, Never> {
        let host = source.host
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        if self.standing(host, in: session) == nil {
            // Nobody's list yet, or somebody else's: what was given to them is not given to this one.
            pages[host] = Page(askedAs: askedAs, under: ShellPersonPages.signIns(at: host, in: session))
        }
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.asking = true
        // A reading-on still on the wire is this ask's to supersede: one ask is out for the
        // list, and whatever the other brings late does not land.
        asks[host]?.cancel()
        pages[host]?.readingOn = false
        let through = door(with: held, in: session)
        let length = stretch
        let task = Task { await self.ask(of: through, length: length, at: source, as: askedAs, errand: errand, in: session) }
        asks[host] = task
        return task
    }

    private func ask(
        of through: MastodonTagFollows, length: Int, at source: Source, as askedAs: AskedAs, errand: Int,
        in session: ShellSession
    ) async {
        let host = source.host
        defer { if pages[host]?.awaits == errand { asks[host] = nil } }
        do {
            let first = try await through.followed(limit: length)
            guard stillTheirs(host, errand: errand, in: session) else { return }
            // What a press was answered before this read began, the read has taken in; what
            // one was answered since is newer than the read, and stands over it.
            let since = pages[host]?.acted.filter { $0.value.at > errand } ?? [:]
            // From the top: what was read before is replaced whole.
            let fresh = try FollowedTagsRead().readingOn(Self.keeping(since, of: pages[host]?.read.tags ?? [], in: first))
            pages[host]?.read = fresh
            pages[host]?.answered = true
            pages[host]?.failed = false
            pages[host]?.footFailed = false
            pages[host]?.notPaging = false
            pages[host]?.acted = since
        } catch {
            guard stillTheirs(host, errand: errand, in: session) else { return }
            if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[host]?.failed = true
            }
        }
        // Nothing is left asking with nothing on the wire.
        pages[host]?.asking = false
    }

    /// `stretch` with each hashtag of `before` that a press was answered as followed `since`
    /// and it does not list, in the place it had: the read was taken before that follow, and a
    /// hashtag the reader follows is not left off their list until the next read.
    private static func keeping(
        _ since: [String: Acted], of before: [PostTag], in stretch: FollowedTagsStretch
    ) -> FollowedTagsStretch {
        var tags = stretch.tags
        let listed = Set(tags.map(MastodonRising.folded))
        for (place, tag) in before.enumerated() {
            let name = MastodonRising.folded(tag)
            if since[name]?.followed == true, !listed.contains(name) { tags.insert(tag, at: min(place, tags.count)) }
        }
        return FollowedTagsStretch(tags: tags, next: stretch.next)
    }

    /// The foot's press: the stretch after what the page holds, by the place the source named.
    /// One at a time, none while the list is being asked from the top, none where the source
    /// named no next or stopped handing the list on, and none past `most`.
    ///
    /// **Pressed by a reader the list was not given to, it reads nothing on**: the list is let
    /// go by the look, and asked afresh as them when it opens.
    func readOn(_ page: FollowedTags, in session: ShellSession) async {
        guard let source = source(of: page, in: session) else { return }
        let host = source.host
        let looked = readers.look(at: host, in: session)
        guard let held = looked.held, let stood = self.standing(host, in: session),
              stood.answered, !stood.readingOn, !stood.asking, !stood.notPaging,
              stood.read.tags.count < most, let next = stood.read.next
        else { return }
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.readingOn = true
        pages[host]?.footFailed = false
        let through = door(with: held, in: session)
        let length = stretch
        let task = Task {
            await self.read(after: next, of: through, length: length, at: source, as: stood.askedAs, errand: errand, in: session)
        }
        asks[host] = task
        await task.value
    }

    private func read(
        after next: String, of through: MastodonTagFollows, length: Int, at source: Source, as askedAs: AskedAs,
        errand: Int, in session: ShellSession
    ) async {
        let host = source.host
        defer { if pages[host]?.awaits == errand { asks[host] = nil } }
        do {
            let came = try await through.followed(after: next, limit: length)
            guard stillTheirs(host, errand: errand, in: session), let held = pages[host]?.read else { return }
            // Read first and written after: the two are not one access.
            let further = try held.readingOn(came)
            pages[host]?.read = further
        } catch {
            guard stillTheirs(host, errand: errand, in: session) else { return }
            if error is PagingError {
                pages[host]?.notPaging = true
            } else if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[host]?.footFailed = true
            }
        }
        pages[host]?.readingOn = false
    }

    /// Whether an answer may land: it is still the one the list awaits, **the list may still
    /// be read, and whoever would ask now is still who it was asked as**. Otherwise what was
    /// kept is let go, and the answer lands nowhere.
    private func stillTheirs(_ host: String, errand: Int, in session: ShellSession) -> Bool {
        guard pages[host]?.awaits == errand else { return false }
        guard source(of: FollowedTags(host: host), in: session) != nil, self.standing(host, in: session) != nil else {
            pages[host] = nil
            return false
        }
        return true
    }

    /// The way to the list at the source: only ever as the reader, through the signed-in
    /// door, which sends the token to its own host and nowhere else.
    private func door(with held: MastodonToken, in session: ShellSession) -> MastodonTagFollows {
        session.reach.tagFollows(session.mastodon.authorized(token: held, within: deadline, for: .followedTags))
    }

    // MARK: - A row's press

    /// The item in a row's `…` chosen: unfollows the hashtag, or follows it again — **by the
    /// hashtag page's own press**, which guards it and sends it. Nothing where the list as it
    /// is drawn does not hold the row, a press of it is out, or the sign-in may not change
    /// who the reader follows — or, `only` given, where the row no longer offers that: an
    /// Unfollow answered after the row stopped being followed sends nothing, never a follow.
    func press(_ id: String, on page: FollowedTags, only: Bool? = nil, in session: ShellSession) async {
        guard let said = said(of: page, in: session), let row = said.rows.first(where: { $0.id == id }),
              case .act(let wanted) = said.offer(for: row), only == nil || only == wanted
        else { return }
        await tags.press(row.tag, at: page.host, to: wanted, in: session)
    }

    /// What a press was answered, written down beside the list of that source.
    private func answered(_ tag: PostTag, at host: String, _ followed: Bool) {
        guard pages[host] != nil else { return }
        pages[host]?.acted[MastodonRising.folded(tag)] = Acted(followed: followed, at: errands.next())
    }
}

// MARK: - Drawn

/// The way to the hashtags followed, on the reader's own page: a press that opens the list,
/// as a figure that counts a list of people is — or, where the sign-in does not see who the
/// reader follows, how it stands, dim with the lock, the whole line the press where it asks.
struct FollowedTagsEntryLine: View {
    let entry: FollowedTagsEntry
    var lit = false
    var onPress: (FollowedTagsEntry) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if entry.presses {
            Button {
                onPress(entry)
            } label: {
                label
                    .padding(.vertical, ShellSpace.tight)
                    .padding(.horizontal, ShellSpace.snug)
                    .background(
                        lit ? ShellChrome.floatFill(colorScheme) : .clear,
                        in: RoundedRectangle(cornerRadius: DummyItemRow.Box.plate)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The wash reaches past the words; the words stand where a figure's do.
            .padding(.horizontal, -ShellSpace.snug)
            .animation(.easeInOut(duration: 0.18), value: lit)
            .help(entry.locked == nil ? FollowedTagsSaid.title() : L10n.t("mark.dim.askAgain"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.spoken())
            .accessibilityHint(entry.locked == nil ? "" : L10n.t("mark.dim.askAgain"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(lit ? .isSelected : [])
        } else {
            label.padding(.vertical, ShellSpace.tight)
        }
    }

    @ViewBuilder
    private var label: some View {
        if entry.locked == nil {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                Text(entry.words())
                Image(systemName: "chevron.right")
                    .shellFont(.mark)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(lit ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
        } else {
            Label(entry.words(), systemImage: SourceRow.permissionSymbol)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.markDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
