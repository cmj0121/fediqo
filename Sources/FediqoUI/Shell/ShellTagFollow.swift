import FediqoCore
import Foundation
import Observation

// A hashtag followed at a source (#318): the line each signed-in source has on the hashtag's
// page — what is asked for it, when, and how a press there is guarded.
//
// **One line a source the reader is signed in to, and only a source that says who people are**
// — the one fact per kind there is, read where a person's page reads it. A forum has no line
// and is asked nothing; with no sign-in there is no line either.
//
// **Asked when the page comes in front, and when the person presses.** Where the sign-in holds
// who the reader follows, the page coming in front asks that source whether the reader follows
// the hashtag: one ask a source, and none again while the page stays. A failure's "Try again"
// asks once more. **Where the sign-in does not hold it, nothing is asked and nothing is
// guessed**: the line is the lock of how that sign-in stands (`PartWords.place`), and its press
// only raises the question. Nothing is asked while no such page is in front.
//
// **A press is shown first, and guarded as a mark on a post is** — by `PressGuard`, the one
// guard a bookmark and a notice dismissed are pressed under: one request out a hashtag and
// source, a press while it is out sends nothing, and the answer is taken only by the press
// that began it. The line reads as doing it meanwhile. What the source answers is what the
// line then says; a press that did not arrive leaves the line as the source last said and
// says so under it.
//
// **Every answer lands only where it is still the one awaited**: each read is numbered on the
// one count every page's asks are numbered on; a press's answer is written only to the page it
// was pressed on, for the sign-in it went with. A page left is let go (`closed`), so an answer
// come late — a yes, a failure — is told to nobody; and where the page was opened again while
// the press was out, it is asked afresh once the press has landed. **What a source said is
// never held while it is being read** (`begin`): whatever that page read before the press
// landed is let go as the fresh read begins, a read still on its way is superseded by it, and
// with nothing said there is no press — so no act is taken over a read that is out, and no
// read begun before an act's answer writes over what the act showed.
//
// **As whoever asked, and let go with their sign-in** (`PageReaders`); **held nowhere**. Each
// for the reason given where a person's page keeps the same rule (`ShellPersonPages`).
//
// **Known limits, left as they are.** The page's key folds case and width and not accents,
// and a Mastodon folds accents too: `#café` and `#cafe` are two pages here for one hashtag
// there. Neither lands on the other's — each asks by its own name and says what the source
// answered that name — but a press on one is not seen on the other until it is opened again.
// And a press refused (403) because the sign-in's hold on follows was taken back elsewhere is
// said as any press that did not arrive: the sign-in is still drawn as holding follows.

/// One source's line on a hashtag's page.
struct TagFollowLine: Equatable, Identifiable {
    enum Standing: Equatable {
        /// The source is being asked whether the reader follows it, or is about to be.
        case asking
        /// As the source last said: followed, or not.
        case said(Bool)
        /// A press is out: following, or unfollowing.
        case doing(Bool)
        /// The source could not be asked. Nothing is known, and nothing is offered but asking again.
        case unknown
        /// The source has no hashtag of this name: nothing to follow, and nothing to ask again.
        case absent
        /// The sign-in does not hold who the reader follows: how it stands, in its own line.
        case locked(PartWords.Place)
    }

    /// What the line's press does.
    enum Offer: Equatable {
        case follow, unfollow
        /// Asks the source again whether it is followed.
        case again
        /// Raises the question that asks the sign-in for who the reader follows.
        case ask
    }

    /// The host of the source.
    let host: String
    let tag: PostTag
    var standing: Standing
    /// What a press that did not arrive wanted: to follow, or to unfollow. Nothing otherwise.
    var missed: Bool?

    var id: String { host }

    var offers: Offer? {
        switch standing {
        case .said(let followed): followed ? .unfollow : .follow
        case .unknown: .again
        case .locked(let place): place.asks ? .ask : nil
        case .asking, .doing, .absent: nil
        }
    }

    /// The row's own press, and Return's with the lamp on it: what it offers, **but
    /// unfollowing** — that is in the row's `…` (`more`), as unfollowing somebody is in their
    /// page's, and no key reaches it.
    var press: Offer? { offers == .unfollow ? nil : offers }

    /// The row's `…`: unfollowing, where the source said it is followed — an item as plain as a
    /// person's unfollow, which asks nothing first since following again is one press. Nothing
    /// otherwise, and then no `…` is drawn.
    func more(act: @escaping () -> Void) -> ShellMore? {
        offers == .unfollow ? ShellMore(items: [Self.item(to: false, act: act)]) : nil
    }

    /// What the row's `…` is called: its one item, and of what at which source — two rows of
    /// About are told apart by it.
    func moreLabel(language: DummyLanguage? = nil) -> String {
        let named = String(format: L10n.t("tag.follow.unfollow.spoken", language: language), tag.text, host)
        return ShellMore.label(only: named, language: language)
    }

    /// The item of a `…` that follows a hashtag, or with `to` false stops: one glyph and one
    /// name wherever it stands — About's row, a row of the hashtags followed.
    static func item(to: Bool, act: @escaping () -> Void) -> ShellMoreItem {
        .plain(to ? "plus.circle" : "minus.circle", L10n.t(to ? "tag.follow.follow" : "tag.follow.unfollow"), act: act)
    }

    /// Whether the line is drawn dim with the lock: it says how a sign-in stands, not how the
    /// hashtag does.
    var isLocked: Bool {
        if case .locked = standing { return true }
        return false
    }

    /// The line: at which source, and how it stands there.
    func words(language: DummyLanguage? = nil) -> String {
        let stands: String
        switch standing {
        case .asking: stands = L10n.t("tag.follow.asking", language: language)
        case .said(let followed): stands = L10n.t(followed ? "tag.follow.followed" : "tag.follow.notFollowed", language: language)
        case .doing(let to): stands = L10n.t(to ? "tag.follow.following" : "tag.follow.unfollowing", language: language)
        case .unknown: stands = L10n.t("tag.follow.unknown", language: language)
        case .absent: stands = String(format: L10n.t("tag.follow.absent", language: language), host)
        case .locked(let place): stands = String(format: L10n.t(place.key, language: language), host)
        }
        return String(format: L10n.t("tag.follow.at", language: language), host, stands)
    }

    /// The word of the press beside the line, or nothing: there is none, the line itself is
    /// the press, as a lock's is, or what it offers is in its `…`.
    func pressWords(language: DummyLanguage? = nil) -> String? {
        switch press {
        case .follow: L10n.t("tag.follow.follow", language: language)
        case .again: L10n.t("tag.retry", language: language)
        case .unfollow, .ask, nil: nil
        }
    }

    /// What the press is called to a listener, who hears it apart from the line.
    func pressSpoken(language: DummyLanguage? = nil) -> String? {
        switch press {
        case .follow: String(format: L10n.t("tag.follow.follow.spoken", language: language), tag.text, host)
        // "Try again" alone says neither what nor where: two sources that failed would be
        // two presses of one name.
        case .again: String(format: L10n.t("tag.again.spoken", language: language), tag.text, host)
        case .unfollow, .ask, nil: pressWords(language: language)
        }
    }

    /// The sentence of a press that did not arrive, or nothing.
    func missedWords(language: DummyLanguage? = nil) -> String? {
        missed.map {
            String(format: L10n.t($0 ? "tag.follow.failed.follow" : "tag.follow.failed.unfollow", language: language), tag.text, host)
        }
    }
}

/// Whether the reader follows each hashtag whose page was in front this run, by source.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
@MainActor
@Observable
final class ShellTagFollow {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// One hashtag at one source.
    private struct Page {
        let host: String
        var askedAs: AskedAs
        /// How often the sign-in at its host had become another when the page was made.
        let under: Int
        /// Which page this is, of all made this run: a page left and opened again is another.
        let number: Int
        /// As the source last said, or nothing where it has not.
        var said: Bool?
        /// Whether what stands in `said` was the list's word (`press(_:at:to:in:)`), written
        /// down to be pressed over: the page coming in front asks all the same.
        var seeded = false
        /// Whether the last read failed.
        var failed = false
        /// Whether the last read was answered that the source has no such hashtag.
        var absent = false
        /// Whether a read is on the wire.
        var asking = false
        /// The number of the read whose answer this page awaits.
        var awaits = 0
    }

    /// Which page a `.task` is: the hashtag, and for each source that has a line who asks and
    /// whether their sign-in holds follows — so a reader who ends, begins or changes, and a
    /// sign-in given follows, each open the page again by themselves.
    struct Opening: Hashable {
        let host: String
        let askedAs: AskedAs
        let under: Int
        let held: Bool
    }

    private var pages: [String: Page] = [:]
    /// The presses out, each with what it is drawn as doing — following, or unfollowing — by
    /// the page's own key: the one guard of a press (`PressGuard`), as a mark on a post has.
    private var presses = PressGuard<String, Bool>()
    /// What each press that did not arrive wanted — to follow, or to unfollow — by the page's
    /// key: said under the line until it is pressed again, or its page is left.
    private var missed: [String: Bool] = [:]
    /// How often the sign-in at its host had become another when each press out was made: a
    /// press is drawn only for the reader who made it.
    private var pressedUnder: [String: Int] = [:]
    /// The read on the wire for each page.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a source's word on a hashtag, where a test reads by one — a wire that
    /// goes on answering a read that was called off, as a transfer already ended does. Nothing
    /// in the app.
    @ObservationIgnored var reaching: ((MastodonToken) -> MastodonTagFollows)?
    /// Who else is told what a press was answered: the list of the hashtags followed, whose
    /// row is as an act answered (`ShellFollowedTags`). Told for the reader who pressed and
    /// nobody else, whether or not the page pressed on still stands.
    @ObservationIgnored var whenAnswered: ((_ tag: PostTag, _ host: String, _ followed: Bool) -> Void)?
    /// The tab in front on each hashtag's page, where it is not its first — by the hashtag as
    /// its page is kept (`HeldUnderTag.folded`), and not in the step of the walk: a tab is not
    /// a step.
    private var fronts: [String: TagTab] = [:]
    /// Where the lamp stood on each tab of each page when the tab was left. Not observed: it
    /// is read only as a tab is brought in front.
    @ObservationIgnored private var lamps: [String: [TagTab: String]] = [:]

    init(errands: PageErrands, readers: PageReaders) {
        self.errands = errands
        self.readers = readers
    }

    /// The page of `tag` at `host`, and its press: the host first, so a source's are let go
    /// together, and the hashtag folded as a source treats one, whatever case it was written in.
    private static func key(_ tag: PostTag, _ host: String) -> String {
        "\(host)\u{1e}\(MastodonRising.folded(tag))"
    }

    /// Whether `tag` is one a source is asked about: its name is no longer than one may be.
    private static func asks(about tag: PostTag) -> Bool {
        tag.name.unicodeScalars.count <= MastodonTagFollows.nameLength
    }

    /// The sources that have a line: each that says who people are and the reader is signed
    /// in to, in the order the sources stand.
    private func sources(in session: ShellSession) -> [Source] {
        session.sources.compactMap { ShellPersonPages.source(at: $0.host, in: session) }
            .filter { session.mastodon.signedInHosts.contains($0.host) }
    }

    private static func holds(at host: String, in session: ShellSession) -> Bool {
        session.mastodon.standing(.follows, host: host) == .held
    }

    /// The page as it stands **for whoever would ask now**, or nothing.
    private func standing(_ key: String, at host: String, in session: ShellSession) -> Page? {
        pages[key].flatMap { page in
            page.under == ShellPersonPages.signIns(at: host, in: session)
                && page.askedAs.isTheSame(as: ShellPersonPages.askedAs(at: host, in: session)) ? page : nil
        }
    }

    // MARK: - What the page is handed

    func opening(_ tag: PostTag, in session: ShellSession) -> [Opening] {
        guard Self.asks(about: tag) else { return [] }
        return sources(in: session).map {
            Opening(
                host: $0.host, askedAs: ShellPersonPages.askedAs(at: $0.host, in: session),
                under: ShellPersonPages.signIns(at: $0.host, in: session), held: Self.holds(at: $0.host, in: session)
            )
        }
    }

    /// The lines of the page of `tag`: none where no source has one.
    func lines(of tag: PostTag, in session: ShellSession) -> [TagFollowLine] {
        sources(in: session).compactMap { line(of: tag, at: $0, in: session) }
    }

    /// The one line of `tag` at `source` — a source that has a line, which whoever asks has
    /// found once for all the hashtags it asks about — or nothing where the hashtag has none.
    func line(of tag: PostTag, at source: Source, in session: ShellSession) -> TagFollowLine? {
        let host = source.host
        guard Self.asks(about: tag), let stands = session.mastodon.standing(.follows, host: host) else { return nil }
        guard stands == .held else {
            // Held in part with the rest not to be asked for has no place of its own: said, unpressed.
            let place = session.mastodon.place(.follows, host: host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
            return TagFollowLine(host: host, tag: tag, standing: .locked(place))
        }
        let key = Self.key(tag, host)
        if let to = presses.shown(key), pressedUnder[key] == ShellPersonPages.signIns(at: host, in: session) {
            return TagFollowLine(host: host, tag: tag, standing: .doing(to))
        }
        guard let page = self.standing(key, at: host, in: session) else {
            return TagFollowLine(host: host, tag: tag, standing: .asking)
        }
        guard let said = page.said else {
            if page.asking { return TagFollowLine(host: host, tag: tag, standing: .asking) }
            if page.absent { return TagFollowLine(host: host, tag: tag, standing: .absent) }
            return TagFollowLine(host: host, tag: tag, standing: page.failed ? .unknown : .asking)
        }
        return TagFollowLine(host: host, tag: tag, standing: .said(said), missed: missed[key])
    }

    // MARK: - The page's tabs (F10)

    /// The tabs of the page of `tag`, as it stands for whoever would ask now: Posts, and About
    /// where a source has a line (`TagTab.tabs`).
    func tabs(of tag: PostTag, in session: ShellSession) -> [TagTab] {
        TagTab.tabs(follows: lines(of: tag, in: session))
    }

    /// The tab in front on the page of `tag`: Posts on opening.
    func front(of tag: PostTag, in session: ShellSession) -> TagTab {
        TagTab.front(fronts[HeldUnderTag.folded(tag)], among: tabs(of: tag, in: session))
    }

    /// What the page of `tag` is handed, with `held` posts of it on this device.
    func said(of tag: PostTag, held: Int, in session: ShellSession) -> TagPageSaid {
        TagPageSaid.made(
            of: tag, held: held, follows: lines(of: tag, in: session), front: fronts[HeldUnderTag.folded(tag)], in: session
        )
    }

    /// What About holds on the page of `tag`, or nothing where the page has none. The count
    /// of posts held is the head's and no part of it.
    func about(of tag: PostTag, in session: ShellSession) -> TagAboutSaid? {
        said(of: tag, held: 0, in: session).about
    }

    /// A tab pressed, the figure that counts its posts, or a swipe: brought in front, each
    /// tab keeping its own lamp. Whether anything changed — a tab the page has not, and the
    /// one already in front, change nothing.
    @discardableResult
    func turn(_ tag: PostTag, to tab: TagTab, lamp: inout String?, in session: ShellSession) -> Bool {
        let all = tabs(of: tag, in: session), id = HeldUnderTag.folded(tag)
        let from = TagTab.front(fronts[id], among: all)
        guard all.contains(tab), tab != from else { return false }
        lamps[id, default: [:]][from] = lamp
        fronts[id] = tab
        lamp = lamps[id]?[tab]
        return true
    }

    /// Tab and ⇧Tab on the page of `tag`, as `TagTab.keyed` answers for it: the tab beside,
    /// round the ring; taken, and nothing turned, on a page with one tab; and not the page's
    /// at all while it is `covered`. Whether the key was taken.
    func rotate(_ tag: PostTag, by step: Int, covered: Bool, lamp: inout String?, in session: ShellSession) -> Bool {
        switch TagTab.keyed(tabs(of: tag, in: session), front: front(of: tag, in: session), by: step, covered: covered) {
        case .turn(let tab):
            turn(tag, to: tab, lamp: &lamp, in: session)
            return true
        case .taken: return true
        case .unheard: return false
        }
    }

    /// The timeline changed under the page of `tag` (#197): the lamp its Posts tab was left
    /// with is let go where the timeline now in front no longer shows that post — `held` is
    /// what it shows — so turning back to Posts lights no row that is not there.
    func timelineSwitched(under tag: PostTag, held: [String]) {
        let id = HeldUnderTag.folded(tag)
        let kept = TagTab.lamp(lamps[id]?[.posts], among: held)
        lamps[id]?[.posts] = kept
    }

    /// The blocks `j` and `k` walk on the page of `tag` while About is in front, or nothing
    /// where its posts are: those are walked as posts.
    func walkedAbout(of tag: PostTag, in session: ShellSession) -> [String]? {
        guard front(of: tag, in: session) == .about else { return nil }
        return about(of: tag, in: session)?.walked
    }

    /// Return with the lamp on the block `id` of About, on the page of `tag`: its row's press,
    /// where it has one. Whether the key did anything.
    func pressAbout(_ id: String, of tag: PostTag, in session: ShellSession) -> Bool {
        guard front(of: tag, in: session) == .about, let line = about(of: tag, in: session)?.press(on: id) else { return false }
        pressed(line, in: session)
        return true
    }

    /// A line's press, whatever it offers: following or unfollowing, asking the source again
    /// whether it is followed, or raising the question for a sign-in that does not hold
    /// follows. `only` is the one way a follow may go, where whoever presses means that one
    /// (`press(_:at:only:in:)`): the head's Follow never unfollows. Hands back what it sent
    /// on its way, or nothing where nothing is sent.
    @discardableResult
    func pressed(_ line: TagFollowLine, only: Bool? = nil, in session: ShellSession) -> Task<Void, Never>? {
        switch line.offers {
        case .follow, .unfollow: return Task { await self.press(line.tag, at: line.host, only: only, in: session) }
        case .again: return Task { await self.again(line.tag, at: line.host, in: session) }
        case .ask: session.askFor([.follows], host: line.host)
        case nil: break
        }
        return nil
    }

    /// The item of a line's `…` that unfollows, chosen: **only ever an unfollow**, held against
    /// what the source says where the press is taken — so a menu opened over a followed line
    /// that has since become not followed sends nothing, and never a follow.
    @discardableResult
    func unfollowed(_ line: TagFollowLine, in session: ShellSession) -> Task<Void, Never>? {
        pressed(line, only: false, in: session)
    }

    /// The walk has left the page of `tag`: which tab was in front, and each tab's lamp, are
    /// forgotten — opened afresh it opens on Posts.
    func left(_ tag: PostTag) {
        fronts[HeldUnderTag.folded(tag)] = nil
        lamps[HeldUnderTag.folded(tag)] = nil
    }

    /// The walk has ended in one go: every page's tab in front is forgotten — all but the
    /// page of `kept`, where the walk ended with that one page left standing (#197).
    func leftAll(but kept: PostTag? = nil) {
        let id = kept.map(HeldUnderTag.folded)
        fronts = fronts.filter { $0.key == id }
        lamps = lamps.filter { $0.key == id }
    }

    /// The tabs of the page of `tag` changed under it — a sign-in ended, and About went with
    /// it: where the tab kept in front is one the page no longer has, it is forgotten with
    /// every tab's lamp, and the lamp goes out (`TagTab.fallen`). The page is then its posts,
    /// with no lamp on a block no row is.
    func tabsChanged(_ tag: PostTag, lamp: inout String?, in session: ShellSession) {
        let id = HeldUnderTag.folded(tag)
        guard let fallen = TagTab.fallen(fronts[id], among: tabs(of: tag, in: session), lamp: lamp) else { return }
        fronts[id] = nil
        lamps[id] = nil
        lamp = fallen.lamp
    }

    // MARK: - Letting go

    /// Everything of `host` let go, and its reads called off: its reader is no longer who
    /// asked (`PageReaders`). A press still out comes back to nothing of its own.
    func letGo(at host: String) {
        for (key, page) in pages where page.host == host { drop(key) }
        // By the key's first half, the host — in small letters, as a post's presses are let go.
        let prefix = host.lowercased() + "\u{1e}"
        presses.letGo { key, _ in key.hasPrefix(prefix) }
        missed = missed.filter { !$0.key.hasPrefix(prefix) }
        pressedUnder = pressedUnder.filter { !$0.key.hasPrefix(host + "\u{1e}") }
    }

    /// The page of `tag` left: what it was told is let go at every source, and its reads
    /// called off. **A press still out stays out** — it is one request at the source whether
    /// or not anybody is looking — and its answer lands nowhere.
    func closed(_ tag: PostTag) {
        let suffix = "\u{1e}" + MastodonRising.folded(tag)
        for key in pages.keys where key.hasSuffix(suffix) {
            drop(key)
            // A press that did not arrive was said on the page that is gone.
            missed[key] = nil
        }
    }

    /// The list of the hashtags followed at `host` left (`ShellFollowedTags.closed`): every
    /// word it gave goes with it, and what was said under one of a press that did not arrive.
    /// What a hashtag's own page was told is that page's, and stays.
    func listClosed(at host: String) {
        for (key, page) in pages where page.host == host && page.seeded {
            drop(key)
            missed[key] = nil
        }
    }

    private func drop(_ key: String) {
        asks[key]?.cancel()
        asks[key] = nil
        pages[key] = nil
    }

    // MARK: - Reading

    /// The page of `tag` coming in front: each source whose sign-in holds follows is asked
    /// whether the reader follows it. Asked once: a source that answered or failed is drawn
    /// from that; one being asked is waited on and asked nothing more. **The list's word is
    /// no answer**: a page that holds only that is let go here, and asked as one never made.
    func opened(_ tag: PostTag, in session: ShellSession) async {
        guard Self.asks(about: tag) else { return }
        var waited: [Task<Void, Never>] = []
        for source in sources(in: session) {
            // The one look at the sign-in: a reader who changed lets what the last was given go.
            guard let held = readers.look(at: source.host, in: session).held, Self.holds(at: source.host, in: session)
            else { continue }
            let key = Self.key(tag, source.host)
            if let page = self.standing(key, at: source.host, in: session) {
                if page.asking {
                    if let running = asks[key] { waited.append(running) }
                    continue
                }
                if page.seeded {
                    drop(key)
                } else if page.said != nil || page.failed || page.absent {
                    continue
                }
            }
            waited.append(begin(tag, at: source, with: held, in: session))
        }
        for task in waited { await task.value }
    }

    /// A failure's "Try again": that source asked once more. **A press while it is being
    /// asked asks nothing**, and so does one where it has answered — a hashtag or that it has
    /// none of the name.
    func again(_ tag: PostTag, at host: String, in session: ShellSession) async {
        guard Self.asks(about: tag), let source = sources(in: session).first(where: { $0.host == host }),
              let held = readers.look(at: source.host, in: session).held, Self.holds(at: source.host, in: session)
        else { return }
        if let page = self.standing(Self.key(tag, source.host), at: source.host, in: session), page.asking || !page.failed { return }
        await begin(tag, at: source, with: held, in: session).value
    }

    /// Starts one source's read, and hands back the task it runs in. Everything it needs is
    /// taken here, before anything waits: the source, who asks, the door.
    private func begin(_ tag: PostTag, at source: Source, with held: MastodonToken, in session: ShellSession) -> Task<Void, Never> {
        let key = Self.key(tag, source.host)
        let askedAs = ShellPersonPages.askedAs(at: source.host, in: session)
        if self.standing(key, at: source.host, in: session) == nil {
            pages[key] = Page(
                host: source.host, askedAs: askedAs, under: ShellPersonPages.signIns(at: source.host, in: session), number: errands.next()
            )
        }
        let errand = errands.next()
        pages[key]?.awaits = errand
        pages[key]?.asking = true
        // Nothing the source said before stands while it is read again: the line reads as
        // asking, and there is no press over a read that is out.
        pages[key]?.said = nil
        // One read out a page: a read begun over another supersedes it.
        asks[key]?.cancel()
        let through = reaching?(held)
            ?? session.reach.tagFollows(session.mastodon.authorized(token: held, within: deadline, for: .followedTags))
        let task = Task { await self.read(tag, of: through, at: source, as: askedAs, errand: errand, in: session) }
        asks[key] = task
        return task
    }

    private func read(
        _ tag: PostTag, of through: MastodonTagFollows, at source: Source, as askedAs: AskedAs, errand: Int,
        in session: ShellSession
    ) async {
        let key = Self.key(tag, source.host)
        defer { if pages[key]?.awaits == errand { asks[key] = nil } }
        do {
            let said = try await through.isFollowed(tag)
            guard stillTheirs(key, errand: errand, at: source, in: session) else { return }
            pages[key]?.said = said
            pages[key]?.failed = false
            pages[key]?.absent = false
        } catch {
            guard stillTheirs(key, errand: errand, at: source, in: session) else { return }
            if !Cancellation.happened(error) {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                // Not found is the source's answer about the name, not an ask that failed.
                let absent = (error as? MastodonAuthError) == .http(404)
                pages[key]?.absent = absent
                pages[key]?.failed = !absent
            }
        }
        // Nothing is left asking with nothing on the wire.
        pages[key]?.asking = false
    }

    /// Whether a read's answer may land: it is still the one the page awaits, **the source is
    /// still here, and whoever would ask now is still who it was asked as**. Otherwise what
    /// was kept is let go, and the answer lands nowhere.
    private func stillTheirs(_ key: String, errand: Int, at source: Source, in session: ShellSession) -> Bool {
        guard pages[key]?.awaits == errand else { return false }
        guard ShellPersonPages.source(at: source.host, in: session) != nil,
              self.standing(key, at: source.host, in: session) != nil
        else {
            pages[key] = nil
            return false
        }
        return true
    }

    // MARK: - The press

    /// `l` on the page of `tag`: follows it at the first source whose line offers that, and
    /// hands back the press on its way — or nothing, where no line offers it. **It only ever
    /// follows**: the press is sent as a follow and as nothing else (`press(_:at:only:in:)`).
    @discardableResult
    func followByKey(_ tag: PostTag, in session: ShellSession) -> Task<Void, Never>? {
        guard let line = lines(of: tag, in: session).first(where: { $0.offers == .follow }) else { return nil }
        return Task { await self.press(tag, at: line.host, only: true, in: session) }
    }

    /// The line's press: follows the hashtag at `host`, or stops, by what the source last said.
    ///
    /// **Only over what the source said, as the reader it said it to**: where it has not
    /// answered, where the sign-in does not hold follows or is no longer the one the page was
    /// read through, the press does nothing. **One request out a hashtag and source**
    /// (`PressGuard.begin`): pressed again meanwhile, nothing more is sent.
    ///
    /// **`only` is the one way the press may go**, where whoever presses means one and not
    /// the other — the key that only ever follows (`followByKey`): it is held against what the
    /// source says **here, where the press is taken**, so a read that landed since the key
    /// looked at the line cannot turn a follow into an unfollow.
    func press(_ tag: PostTag, at host: String, only: Bool? = nil, in session: ShellSession) async {
        guard Self.asks(about: tag), let source = sources(in: session).first(where: { $0.host == host }) else { return }
        let looked = readers.look(at: source.host, in: session)
        let key = Self.key(tag, source.host)
        guard let held = looked.held, !looked.changed, Self.holds(at: source.host, in: session),
              let page = self.standing(key, at: source.host, in: session), let said = page.said,
              only == nil || only == !said,
              let flight = presses.begin(key, showing: !said)
        else { return }
        missed[key] = nil
        pressedUnder[key] = page.under
        let through = session.reach.tagFollows(session.mastodon.authorized(token: held, within: deadline, for: .write))
        // The request is this object's and not the pane's: a page left does not call it off.
        await Task {
            await self.act(tag, to: !said, flight: flight, on: page, of: through, with: held, at: source, in: session)
        }.value
    }

    /// A press on a row of the list of the hashtags followed (`ShellFollowedTags`): follows
    /// the hashtag at `host`, or with `wanted` false stops.
    ///
    /// **The list is what said how the hashtag stands**, so its word is written down as the
    /// source's last — over whatever this page read before, and never over a read that is
    /// out — and the press is then the line's own: one guard, one request, one sentence.
    /// **Marked as the list's** (`seeded`), so it stands in for no ask of the hashtag's own
    /// page (`opened`) and goes when the list does (`listClosed`).
    func press(_ tag: PostTag, at host: String, to wanted: Bool, in session: ShellSession) async {
        guard Self.asks(about: tag), let source = sources(in: session).first(where: { $0.host == host }) else { return }
        let looked = readers.look(at: source.host, in: session)
        guard looked.held != nil, !looked.changed, Self.holds(at: source.host, in: session) else { return }
        let key = Self.key(tag, source.host)
        if let page = self.standing(key, at: source.host, in: session) {
            if page.asking { return }
            pages[key]?.said = !wanted
            pages[key]?.seeded = true
            pages[key]?.failed = false
            pages[key]?.absent = false
        } else {
            pages[key] = Page(
                host: source.host, askedAs: ShellPersonPages.askedAs(at: source.host, in: session),
                under: ShellPersonPages.signIns(at: source.host, in: session), number: errands.next(), said: !wanted,
                seeded: true
            )
        }
        await press(tag, at: host, in: session)
    }

    /// Sends the press and takes its answer, if it is still this press's to take.
    ///
    /// **Under the one guard of a press** (`PressGuard`), as `ShellSession.perform` is for a
    /// post's acts and `ShellNoticeActs.perform` for a notice's: sent, and then the guard is
    /// asked whether the entry is still this press's before anything lands or fails. It
    /// differs from them in two things, which are its own. **A second press meanwhile sends
    /// nothing and keeps no turn** (`PressGuard.begin` in `press`, never `change`): there is
    /// one request, and the line says what it answered. And **a failure is said under the
    /// line** (`missed`), not on the foot strip.
    private func act(
        _ tag: PostTag, to wanted: Bool, flight: PressNumber, on pressed: Page, of through: MastodonTagFollows,
        with held: MastodonToken, at source: Source, in session: ShellSession
    ) async {
        let key = Self.key(tag, source.host)
        var answer: Bool?
        do {
            answer = try await through.follow(tag, wanted)
        } catch {
            ShellPersonPages.concluded(error, at: source, askedAs: pressed.askedAs, in: session)
        }
        // Let go of with its reader meanwhile: the entry, if any, is another press's.
        guard presses.isStill(flight, key) else { return }
        pressedUnder[key] = nil
        let sameReader = session.mastodon.token(host: source.host)?.accessToken == held.accessToken
        // The source's word to the reader who pressed, wherever the page pressed on has gone.
        if sameReader, let answer { whenAnswered?(tag, source.host, answer) }
        guard sameReader, let page = self.standing(key, at: source.host, in: session), page.number == pressed.number else {
            // Not the page pressed on, or not its reader: the answer is written nowhere.
            presses.settle(key)
            // A page of the hashtag opened since is asked afresh: whatever it read, or has on
            // its way, was asked before the press landed — and is let go as that read begins.
            if sameReader, self.standing(key, at: source.host, in: session) != nil, Self.holds(at: source.host, in: session) {
                _ = begin(tag, at: source, with: held, in: session)
            }
            return
        }
        // The press is answered, or did not arrive: either way it is out no longer.
        presses.settle(key)
        guard let answer else {
            miss(tag, wanted, key: key, at: source, in: session)
            return
        }
        pages[key]?.said = answer
        // The source's word stands either way; one that is not what was pressed is said as not done.
        if answer != wanted { miss(tag, wanted, key: key, at: source, in: session) }
    }

    /// A press that did not arrive: written down to be said on the page, and said aloud once
    /// by the road every line the app says takes (`ShellSaid.announce`) — a listener is not
    /// looking at the line that changed.
    private func miss(_ tag: PostTag, _ wanted: Bool, key: String, at source: Source, in session: ShellSession) {
        missed[key] = wanted
        let line = TagFollowLine(host: source.host, tag: tag, standing: .said(!wanted), missed: wanted)
        if let words = line.missedWords() { session.said.announce(words) }
    }
}
