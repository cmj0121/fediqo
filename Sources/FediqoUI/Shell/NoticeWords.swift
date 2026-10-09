import FediqoCore
import Foundation

/// What a notice's row says, and what a listener hears of it (#323) — functions of the notice,
/// so every sentence can be asked for without drawing a row.
///
/// **Who and what are two things.** Who did it is drawn as a post's author is, and what they
/// did is the glyph before the name and that glyph's words, so a line gathered from several
/// people is said "Ada and 2 others" and then "favourited your post", in the order either
/// language says it.
enum NoticeWords {
    /// What happened, without who: what the row's glyph says, and what is drawn where the glyph
    /// cannot say it.
    ///
    /// **Total.** A kind this build does not know is said as unknown, under the word its source
    /// used — a line left out would be a thing that happened to the person, hidden from them.
    static func what(_ notice: Notice, language: DummyLanguage? = nil) -> String {
        switch notice.kind {
        case .mention:
            L10n.t(notice.answers ? "notices.what.answer" : "notices.what.mention", language: language)
        case .reblog: L10n.t("notices.what.reblog", language: language)
        case .favourite: L10n.t("notices.what.favourite", language: language)
        case .follow: L10n.t("notices.what.follow", language: language)
        case .followRequest: L10n.t("notices.what.followRequest", language: language)
        case .quote: L10n.t("notices.what.quote", language: language)
        case .poll: L10n.t("notices.what.poll", language: language)
        case .update: L10n.t("notices.what.update", language: language)
        case .server(let word):
            (notice.people.isEmpty ? nil : serverWord(word + ".by", language: language))
                ?? serverWord(word, language: language)
                ?? String(format: L10n.t("notices.what.server", language: language), word)
        case .unknown(let word):
            String(format: L10n.t("notices.what.unknown", language: language), word)
        }
    }

    /// Whether what happened reads on from who: "Ada" and then "favourited your post". The
    /// server's own word and an unknown kind are whole sentences, and stand beside the name.
    static func readsOnFromWho(_ notice: Notice, language: DummyLanguage? = nil) -> Bool {
        switch notice.kind {
        case .mention, .reblog, .favourite, .follow, .followRequest, .quote, .poll, .update: true
        case .server(let word): !notice.people.isEmpty && serverWord(word + ".by", language: language) != nil
        case .unknown: false
        }
    }

    /// The glyph for what happened: the act's own wherever the app already draws that act.
    static func symbol(_ notice: Notice) -> String {
        switch notice.kind {
        case .mention: notice.answers ? "arrowshape.turn.up.left" : "at"
        case .reblog: "arrow.2.squarepath"
        case .favourite: "star"
        case .follow: "person.badge.plus"
        case .followRequest: "person.badge.clock"
        case .quote: "quote.bubble"
        case .poll: "chart.bar"
        case .update: "pencil"
        case .server: "server.rack"
        case .unknown: "questionmark.circle"
        }
    }

    /// Whether the glyph says what happened by itself: it does for a kind with a glyph of its
    /// own. The server's own words share one, and every unknown kind another, so a line of
    /// those keeps its words where they can be read.
    static func symbolSays(_ notice: Notice) -> Bool {
        switch notice.kind {
        case .mention, .reblog, .favourite, .follow, .followRequest, .quote, .poll, .update: true
        case .server, .unknown: false
        }
    }

    /// Who: one name, or "Ada and 2 others" for a line gathered from several. Nothing where the
    /// source named nobody — the server speaking for itself.
    ///
    /// **The count is the source's and the name is the newest of its sample**: a gathered line
    /// says how many it stands for and sends a few of them, so the others are counted, not named.
    static func who(_ notice: Notice, language: DummyLanguage? = nil) -> String? {
        guard let first = notice.people.first else { return nil }
        let name = name(first)
        let others = max(notice.count, notice.people.count) - 1
        guard others > 0 else { return name }
        return ShellQuestion.counted("notices.who.others", others, name, language: language)
    }

    /// The words of the post the notice is about, as one quiet run: nothing where it is about no
    /// post, or the post has no words.
    static func excerpt(_ notice: Notice, language: DummyLanguage? = nil) -> String? {
        excerpt(of: notice.post, language: language)
    }

    /// What a line shows and says of a post: its words as one run — **and never the words of a
    /// post its author covered** (`DummyItem.covered`'s rule, asked of the note). A timeline
    /// keeps those under the cover until the reader lifts it, and a line that printed them
    /// would have lifted it for them: what stands here is what the post was covered with, as
    /// an earlier wording says it (`EarlierWordings`) — the author's warning where they wrote
    /// one, else that it is covered. Opening the line leads to the conversation, and the cover.
    ///
    /// **Either is a stranger's writing set in a line of ours**, and is made fit for it as a
    /// name is (`oneLine`), at `excerptLength`: a row cuts it at two lines, and a listener is
    /// read all of it.
    static func excerpt(of post: Note?, language: DummyLanguage? = nil) -> String? {
        guard let post else { return nil }
        let warning = oneLine(post.spoiler ?? "", limit: excerptLength)
        // Whether it is covered is the note's own word (`Note.covered`), as a timeline's row
        // asks it — never what is left of the warning once it is made fit for a line: a
        // warning of nothing but what is stripped still covers, and says only that it does.
        guard post.covered == true else {
            let words = oneLine(post.body, limit: excerptLength)
            return words.isEmpty ? nil : words
        }
        return warning.isEmpty
            ? L10n.t("item.covered.mark", language: language)
            : String(format: L10n.t("item.covered.warning", language: language), warning)
    }

    // MARK: - Naming somebody

    /// How long a name a source sent may run on a line of ours (`LineText.nameLength`).
    static let nameLength = LineText.nameLength

    /// How long a post's words, or the line it was covered with, may run on a line of ours:
    /// well past the two lines a row draws, and short of a post read out whole.
    static let excerptLength = 280

    /// A name, a handle or a post's words a source sent, made fit to stand in one line of ours
    /// (`LineText.oneLine`).
    static func oneLine(_ text: String, limit: Int = nameLength) -> String {
        LineText.oneLine(text, limit: limit)
    }

    /// Somebody as a row names them: their name, or their handle where they have none.
    static func name(_ person: NoticePerson) -> String {
        person.lineName.isEmpty ? person.lineHandle : person.lineName
    }

    /// Somebody as a question or a sentence about an act names them: **by their handle, as
    /// the source gives it**, with the name they chose after it. A name is anything its owner
    /// typed — somebody else's among them — and the handle is the one the source vouches for,
    /// so it is what the person is asked about.
    static func named(_ person: NoticePerson, language: DummyLanguage? = nil) -> String {
        let handle = person.lineHandle, name = person.lineName
        guard !handle.isEmpty else { return name }
        guard !name.isEmpty else { return handle }
        return String(format: L10n.t("notices.person.named", language: language), handle, name)
    }

    /// The whole row as a listener hears it, the row being one element: who and what, the post,
    /// the source, and when — said exactly, as a timeline's row says its time.
    @MainActor
    static func spoken(_ notice: Notice, language: DummyLanguage? = nil) -> String {
        spoken(
            notice, who: who(notice, language: language), what: what(notice, language: language),
            excerpt: excerpt(notice, language: language), language: language
        )
    }

    /// Who and what, as one run: "Ada favourited your post". What a line elsewhere names a
    /// notice by, and the head of what a listener hears of its row.
    static func act(_ notice: Notice, language: DummyLanguage? = nil) -> String {
        act(notice, who: who(notice, language: language), what: what(notice, language: language), language: language)
    }

    private static func act(_ notice: Notice, who: String?, what: String, language: DummyLanguage?) -> String {
        let reads = readsOnFromWho(notice, language: language)
        return who.map {
            String(format: L10n.t(reads ? "notices.spoken.act" : "notices.spoken.named", language: language), $0, what)
        } ?? what
    }

    /// `spoken(_:language:)` of parts already worked out: a row draws each, and says them here
    /// without working any out again.
    @MainActor
    static func spoken(
        _ notice: Notice, who: String?, what: String, excerpt: String?, language: DummyLanguage? = nil
    ) -> String {
        let act = act(notice, who: who, what: what, language: language)
        let said = excerpt.map {
            String(format: L10n.t("notices.spoken.post", language: language), act, $0)
        } ?? act
        return String(
            format: L10n.t("notices.spoken", language: language),
            said, notice.source.host, DummyItemRow.exact(notice.at)
        )
    }

    /// What one of the server's own words means, where this build has a sentence for it.
    private static func serverWord(_ word: String, language: DummyLanguage?) -> String? {
        let key = "notices.server." + word
        let said = L10n.t(key, language: language)
        return said == key ? nil : said
    }

    // MARK: - Narrowing

    /// The kinds every Mastodon may send, in the order the choice lists them.
    static let named: [Notice.Kind] = [.mention, .reblog, .favourite, .follow, .followRequest, .quote, .poll, .update]

    /// The kinds the choice offers, each under the word it is narrowed by: the named ones, then
    /// each of the server's own words that is held or left out now, then every unknown kind as
    /// one. A word the server has never sent is not offered — nobody can say what it would hide.
    static func narrowable(held: [Notice], hidden: Set<String>) -> [String] {
        let fixed = named.map(\.narrowedAs)
        let servers = held.compactMap { notice -> String? in
            if case .server = notice.kind { notice.kind.narrowedAs } else { nil }
        }
        let extra = Set(servers).union(hidden).subtracting(fixed).subtracting([Notice.Kind.unknownKinds])
        return fixed + extra.sorted() + [Notice.Kind.unknownKinds]
    }

    /// A kind's name in the choice.
    static func kindName(_ narrowedAs: String, language: DummyLanguage? = nil) -> String {
        let key = "notices.kind." + narrowedAs
        let said = L10n.t(key, language: language)
        return said == key ? narrowedAs : said
    }

    /// What the page's head says of the choice: that every kind is shown, or how many are not.
    static func narrowed(_ hidden: Set<String>, language: DummyLanguage? = nil) -> String {
        hidden.isEmpty
            ? L10n.t("notices.kinds.all", language: language)
            : L10n.count("notices.kinds.hidden", hidden.count, language: language)
    }

    // MARK: - What a line opens

    /// What a press on a line opens.
    enum Opens: Equatable {
        /// The post it is about, in its conversation.
        case post(Note)
        /// The person, as far as this device shows one.
        case person(DummyPerson)
        /// Nothing: the line is words, and offers no press.
        case nothing
    }

    /// The post where the notice is about one, else the person, else nothing. A follow and a
    /// request to follow are about nobody's post, so they lead to who followed.
    static func opens(_ notice: Notice) -> Opens {
        if let post = notice.post { return .post(post) }
        if let person = notice.firstPerson { return .person(person) }
        return .nothing
    }
}

extension Notice {
    /// Whoever the notice names first, as far as this device shows a person: who a press on
    /// the name opens, and who a follow leads to.
    var firstPerson: DummyPerson? {
        people.first.flatMap { DummyPerson($0, host: source.host) }
    }
}

// MARK: - What the page says above and under its lines

/// What the notices page is, before any line of it: decided from who is signed in and what each
/// sign-in may do, in the order the page gives its answers.
enum NoticesStanding: Equatable {
    /// Nobody is signed in to a source that has notices.
    case nobody
    /// Signed in, and no sign-in may read notices: `unasked` have not been asked for them,
    /// `refused` were asked and gave none.
    case notAllowed(unasked: [String], refused: [String])
    /// At least one source is read, or was: its lines, and what each source has to say.
    case list

    /// `hosts` are the signed-in sources of a kind that has notices, with where each sign-in
    /// stands. `held` is whether the list holds anything of a source that could be read before.
    static func standing(_ hosts: [(host: String, notices: NoticeStanding)], held: Bool) -> NoticesStanding {
        guard !hosts.isEmpty else { return .nobody }
        if hosts.contains(where: { $0.notices == .allowed }) || held { return .list }
        return .notAllowed(
            unasked: hosts.filter { $0.notices == .unasked }.map(\.host),
            refused: hosts.filter { $0.notices == .unavailable }.map(\.host)
        )
    }
}

/// One thing the page says of its sources, above its lines.
enum NoticesLine: Equatable, Identifiable {
    /// On the wire, and which sources.
    case reading([String])
    /// A source whose last ask did not come back. `again` where asking it again may help: its
    /// sign-in may still read notices.
    case failed(host: String, why: ShellNoticeList.Absence, again: Bool)
    /// Signed in, and never asked for notices.
    case unasked(host: String)
    /// Asked for notices, and gave none.
    case refused(host: String)
    /// May be asked, and was not: its sign-in could not be read off this device.
    case locked(host: String)
    /// May be asked, and has not answered or failed: the read was stopped before it did.
    case unread(host: String)
    /// Held to as many lines as are kept of one source (`NoticeReach.capacity`): its older notices are not
    /// shown, and lines of another source may stand below where they would have been.
    case full(host: String)

    var id: String {
        switch self {
        case .locked(let host): "locked:" + host
        case .unread(let host): "unread:" + host
        case .full(let host): "full:" + host
        case .reading: "reading"
        case .failed(let host, _, _): "failed:" + host
        case .unasked(let host): "unasked:" + host
        case .refused(let host): "refused:" + host
        }
    }

    /// The lines, in the order they are drawn: what is happening now, what went wrong, what
    /// is not shown, then what was never asked.
    ///
    /// **A source named as failed is not also named as refused**: one whose read was turned
    /// away is both, and says so once, as the failure it was.
    static func lines(
        reading: [String], failures: [(host: String, why: ShellNoticeList.Absence)], askable: Set<String>,
        hosts: [(host: String, notices: NoticeStanding)], locked: Set<String> = [], unread: [String] = [],
        full: [String] = []
    ) -> [NoticesLine] {
        let failed = Set(failures.map(\.host))
        var lines: [NoticesLine] = reading.isEmpty ? [] : [.reading(reading)]
        lines += failures.map { .failed(host: $0.host, why: $0.why, again: askable.contains($0.host)) }
        lines += full.map { .full(host: $0) }
        lines += locked.subtracting(failed).subtracting(reading).sorted().map { .locked(host: $0) }
        lines += unread.map { .unread(host: $0) }
        for (host, notices) in hosts where !failed.contains(host) {
            switch notices {
            case .unasked: lines.append(.unasked(host: host))
            case .unavailable: lines.append(.refused(host: host))
            case .allowed: break
            }
        }
        return lines
    }

    /// `touch` where there is nothing but a finger: a key is then not named as a way to read.
    func words(language: DummyLanguage? = nil, touch: Bool = false) -> String {
        switch self {
        case .unread(let host):
            String(format: L10n.t(touch ? "notices.source.unread.touch" : "notices.source.unread", language: language), host)
        case .reading(let hosts):
            String(format: L10n.t("notices.reading", language: language), Self.joined(hosts, language: language))
        case .failed(let host, .unreachable, _):
            String(format: L10n.t("notices.failed.unreachable", language: language), host)
        case .failed(let host, .refused, _):
            String(format: L10n.t("notices.failed.refused", language: language), host)
        case .unasked(let host):
            String(format: L10n.t("notices.source.unasked", language: language), host)
        case .refused(let host):
            String(format: L10n.t("notices.source.refused", language: language), host)
        case .locked(let host):
            String(format: L10n.t("notices.source.locked", language: language), host)
        case .full(let host):
            String(format: L10n.t("notices.source.full", language: language), host)
        }
    }

    static func joined(_ hosts: [String], language: DummyLanguage? = nil) -> String {
        hosts.joined(separator: L10n.t("item.source.join", language: language))
    }
}

/// What the page says where it has no line to draw.
enum NoticesNone: Equatable {
    /// The first read is on the wire, or about to be: the line above says so.
    case reading
    /// Lines are held, this many, and every one is of a kind left out.
    case narrowed(Int)
    /// Read, and nothing has happened.
    case nothing
    /// Not every source was read: the lines above name each and say why — failed, its sign-in
    /// not readable, or the read stopped before it answered.
    case unread

    /// `unread` is whether a source that may be asked has neither answered nor failed — a read
    /// stopped part-way — and `said` whether a line above already says why some source has
    /// nothing here. **Nothing is said to have happened nowhere while a source is unread**:
    /// "nothing has happened" is about every source, and one was not asked.
    static func none(isReading: Bool, held: Int, said: Bool, answered: Bool, unread: Bool) -> NoticesNone {
        if held > 0 { return .narrowed(held) }
        if isReading { return .reading }
        if unread { return .unread }
        if answered { return .nothing }
        return said ? .unread : .reading
    }

    /// `older` where the foot under the words offers older notices to press for.
    func words(language: DummyLanguage? = nil, older: Bool = false) -> String? {
        switch self {
        case .reading, .unread: nil
        case .narrowed(let held):
            L10n.count(older ? "notices.none.narrowedOlder" : "notices.none.narrowed", held, language: language)
        case .nothing: L10n.t("notices.none", language: language)
        }
    }
}

/// What stands under the last line.
enum NoticesFoot: Equatable {
    /// Older notices can be asked for: reaching or pressing this reads them.
    case more
    /// An older stretch is on the wire.
    case reading
    /// The list stops where a source could not be read further, and that source is named above.
    case held
    /// What this device holds is drawn, and every source is being asked for its newest: older
    /// notices can be read once they have answered.
    case asking
    /// A source has been read down to the months limit: older notices are beyond what this
    /// device keeps, and are not asked for.
    case limit
    /// A source is held to as many lines as are kept of one (`NoticeReach.capacity`), and is
    /// read on no further: there may be older notices, and they are not shown. Held so across
    /// runs, until a read from the top joined to nothing held starts the source again.
    case full
    /// Every source has handed over all it has.
    case end

    /// `full` is whether a source reached that bound (`ShellNoticeList.isFull`). Said only
    /// where nothing else is: a source named above still says why the list stops there.
    static func foot(hasMore: Bool, isReading: Bool, floor: Date?, full: Bool = false) -> NoticesFoot {
        if isReading { return .reading }
        if hasMore { return .more }
        if floor != nil { return .held }
        return full ? .full : .end
    }

    /// Whether a scroll of the person's own hand, just ended, reads on with no press: only
    /// where it brought the foot into view — in view as it ended, and not as it began — past
    /// lines they can see. A list too short to scroll, one narrowed to nothing, a pull at the
    /// top and a list put somewhere by a key all leave reading on to a press: read by the foot
    /// merely being in view, a whole history would be read stretch after stretch unasked.
    static func readsByItself(footInViewAtStart: Bool, footInViewAtEnd: Bool, shown: Int) -> Bool {
        footInViewAtEnd && !footInViewAtStart && shown > 0
    }

    func words(language: DummyLanguage? = nil) -> String {
        switch self {
        case .more: L10n.t("notices.foot.more", language: language)
        case .reading: L10n.t("notices.foot.reading", language: language)
        case .held: L10n.t("notices.foot.held", language: language)
        case .asking: L10n.t("notices.foot.asking", language: language)
        case .limit: L10n.t("notices.foot.limit", language: language)
        case .full: L10n.t("notices.foot.full", language: language)
        case .end: L10n.t("notices.foot.end", language: language)
        }
    }

    var symbol: String {
        switch self {
        case .more: "arrow.down.circle"
        case .reading: "ellipsis"
        case .held: "exclamationmark.triangle"
        case .asking: "ellipsis"
        case .limit: "calendar"
        case .full: "tray.full"
        case .end: "checkmark.circle"
        }
    }
}
