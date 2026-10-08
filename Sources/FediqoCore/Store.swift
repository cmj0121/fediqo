import Foundation

/// Notes this device is holding, until it forgets them.
public actor ItemStore {
    private var sourceList: [Source] = []
    /// What each source last said about itself, by host, marked as of when it was said (#188).
    ///
    /// **Beside the source list and not inside `Source`.** A `Source` is what the reader chose —
    /// a host, and the boards and lists they picked on it — and this is the server's own word,
    /// which the next successful ask replaces whole and a Remove takes away with the rest. Kept
    /// apart, a server restating its size does not make every source look changed.
    private var saidByHost: [String: SourceProfile] = [:]
    /// One row per `NoteKey`: two hosts carrying the same Mastodon URI are two rows (#10).
    private var notes: [NoteKey: Note] = [:]
    /// When each row first arrived, as a count that only goes up. Nothing reads the number; what
    /// is read is which of two is the smaller.
    ///
    /// **Which copy a merged row is drawn as** (#114). Two sources carrying one post are two rows
    /// here and one row on screen, and the row is the copy that arrived first — so the store has
    /// to be able to say which that was. It could not before: a dictionary hands its values back
    /// in whatever order it likes, and the two copies agree on the hour they were posted and on
    /// the name their servers gave the post, which is every other thing `storeOrder` compares.
    ///
    /// **Counted, not clocked.** A moment would be a fact about this device's clock, which can go
    /// backwards; the order two copies were taken in is a fact about this store, and it is the
    /// only one being asked for.
    ///
    /// It survives a relaunch as an order rather than as a number: `snapshot` hands the rows over
    /// oldest first, a save writes them in that order, and `init(sources:notes:)` counts the rows
    /// back in the order it is given them. So the numbers a second run uses are not the first
    /// run's, and the answer they give is.
    private var arrival: [NoteKey: Int] = [:]
    private var arrivals = 0
    /// Where in the run's order the reader's own act on each post last landed (#291): the answer
    /// to a favourite, a boost or a bookmark, put or taken back. A copy of that post sent before
    /// it (`Note.asked`) leaves what the row says the reader did.
    ///
    /// **For the run, and never written down**: a relaunch has no read on its way, so there is
    /// nothing left for a place to be compared with. A post acted on is marked for as long as the
    /// run lasts, its row gone or not — one number a post, for the posts one reader pressed.
    private var acted: [NoteKey: UInt64] = [:]
    /// Where in the run's order the latest read of each held post was sent, among the reads
    /// whose word on what the reader did was taken (`outrun`). What tells "the source has been
    /// asked about this post since" from a row that merely still says what it said — for a
    /// press that did not arrive, and may have landed all the same. For the run, as `acted` is.
    ///
    /// **Let go with its post**: every way a row leaves says the store changed (`changed`), and
    /// that drops what is kept here for rows no longer held — a post let go, a host removed.
    private var readAt: [NoteKey: UInt64] = [:]

    /// Where in the run's order each of these posts was last read, for the ones read this run.
    public func lastRead(of keys: [NoteKey]) -> [NoteKey: UInt64] {
        keys.reduce(into: [:]) { $0[$1] = readAt[$1] }
    }

    /// Notes that a read's copy of a held post was taken, where it says when it was sent.
    private func read(_ copy: Note) {
        guard let sent = copy.asked.place else { return }
        readAt[copy.key] = max(readAt[copy.key] ?? 0, sent)
    }
    /// Where in the run's order the reader's marks were last taken off each host's posts
    /// (`forgetReaderMarks`): a sign-in there ended, or became somebody else's. A copy from that
    /// host sent before it was read as the reader who has gone, and says nothing of this one —
    /// on every post of the host, acted on or not (#291). For the run, as `acted` is.
    private var swept: [String: UInt64] = [:]
    /// The oldest a note may be posted and still be held, or nil to keep everything forever —
    /// the default. The reader's drop by time (#7), held here so every way in obeys it.
    private(set) var retention: Date?
    /// Counts the changes to what a save writes: every call that may have changed a source or a
    /// note bumps it. A saver that remembers the revision it last wrote skips a save with nothing
    /// new in it. Starts at 0 for any store, a relaunched one included. **A count recounted is
    /// the one change it does not move** (#208): that is drawn now and written with the next.
    public private(set) var revision = 0
    /// Counts the changes to what `all()` hands over, which is fewer than `revision`'s (#175): a
    /// source's boards restated, or a forum topic's reply kept, is a change a save writes and no
    /// timeline shows. A reader that has adopted `all()` at this count has nothing new to adopt.
    public private(set) var drawn = 0
    /// Counts the changes to what `replies()` hands over: a forum topic's reply kept, changed or
    /// gone. A reader that has adopted `replies()` at this count has nothing new to adopt — so a
    /// timeline landing, which is most changes, does not make the count of what is held read
    /// every kept reply again, and a page of a topic read does not replace every row of All.
    public private(set) var repliesRevision = 0
    /// Everyone listening for a change. See `changes()`.
    private var listeners: [UUID: AsyncStream<Int>.Continuation] = [:]
    /// What the person pressed to send and no source has said landed, in the order pressed.
    ///
    /// **Beside the items and none of them** (`Unsent`): untouched by `replace`, by
    /// `remove(host:)`, and by every limit and purge — only a landing or the person lets one go.
    private var unsent: [Unsent] = []
    /// Counts the changes to `unsent`, apart from `revision`: a saver writes the texts as a
    /// part of their own, so holding one rewrites no post, and a landing rewrites no text.
    public private(set) var unsentRevision = 0
    /// The texts let go of — landed, discarded, their source removed — by name: **what a write
    /// of a text is asked against, so one made of a copy from before the letting go is not
    /// taken** (`hold(_:)`), as the notices' epochs do for a host. Kept here, where the letting
    /// go happens, so no order of arrival can put a text back. A name is given once and never
    /// to a second text. For the run.
    private var unsentGone: Set<UUID> = []
    /// Who is sending each text that is being sent, by the name its sender goes by — a session's
    /// outbox (`claim(unsent:for:)`). **One sender a text**: decided here, in the store's own
    /// isolation, so two windows over one store cannot both send it. For the run, never written.
    private var unsentSenders: [UUID: UUID] = [:]
    /// Counts every change to the texts and to who is sending them: what a page that draws
    /// them has taken, or has yet to (`unsentView`). Apart from `unsentRevision`, which a
    /// saver writes by and a claim does not move.
    public private(set) var unsentMark = 0

    /// The texts, or who is sending one, changed: everyone listening is told, as for a notice.
    /// The revision a save writes the posts by stays where it is.
    private func unsentChanged() {
        unsentMark += 1
        for listener in listeners.values { listener.yield(revision) }
    }
    /// What each signed-in source says happened to the person, and how far down it was read, by
    /// host (`NoticeReach`, #323).
    ///
    /// **Beside the items and none of them**: a notice stands in no timeline, nothing keeps one,
    /// and the post one is about lies in its line as carried — an item only once somebody opens
    /// it. Let go with the reader they were said to (`forgetReaderMarks`), with their source
    /// (`remove`), by a read back (`replace`) and, the old ones, by the months limit; and the
    /// carried copy of a post is struck by every call that lets that post go (`strike`).
    private var reaches: [String: NoticeReach] = [:]
    /// Counts the changes to `reaches`, apart from `revision`: a saver writes the notices as a
    /// part of their own, so a page of them read rewrites no post. Everyone listening is told
    /// all the same (`noticesChanged`), which is how the page follows what is held.
    public private(set) var noticesRevision = 0
    /// Counts the times notices were let go by host — a reader signed out or replaced, a source
    /// removed, a store read back: **what a write of notices names, so one made of a copy from
    /// before the letting go is not taken** (`hold(_:fresh:since:)`). A sign-out leaves the
    /// source here, so nothing else would stop such a write putting the gone reader's notices
    /// back. For the run.
    private var noticeEpochs: [String: Int] = [:]
    /// The epoch of every host not let go of since the last read back.
    private var noticeEpochBase = 0
    private var noticeEpochLast = 0

    private func noticeEpoch(_ host: String) -> Int { noticeEpochs[host] ?? noticeEpochBase }

    /// Whoever listens is told, though nothing held need have moved: a page that writes
    /// notices has to learn the epoch its next write is of (`noticesMark`).
    private func endNoticeEpoch(_ host: String) {
        noticeEpochLast += 1
        noticeEpochs[host] = noticeEpochLast
        for listener in listeners.values { listener.yield(revision) }
    }

    /// The notices' revision and the count of their epochs ended, in one hop: a page that has
    /// taken the notices at this mark has nothing new to take.
    public var noticesMark: [Int] { [noticesRevision, noticeEpochLast] }

    public init() {}

    /// The revision, each time something here really changed — so a screen reading this store
    /// renews itself with no key pressed (#175).
    ///
    /// **A stream rather than observation**, because a Swift 6 actor cannot be `@Observable`: what
    /// the store can offer is something to await, and one listener turns it back into a redraw.
    ///
    /// **Only the newest is kept.** A listener that was busy while three reads landed has one
    /// thing to do about them and does it once; what a renewal needs to know is that something
    /// changed, never how many times. A call that changed nothing says nothing at all, which is
    /// what keeps a wait that brought nothing new off the screen.
    ///
    /// Each call is its own stream, and a stream nobody reads any more drops itself.
    public func changes() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopListening(id) }
        }
        return stream
    }

    private func stopListening(_ id: UUID) {
        listeners[id] = nil
    }

    /// Something here changed: the revision moves and everyone listening is told. **The one place
    /// either happens**, so a call that tells a saver it changed cannot forget to tell a screen.
    /// `shown` says whether it changed what `all()` hands over too, and moves `drawn` where it
    /// did; `replies` the same of what `replies()` hands over, and `repliesRevision`. **Both said
    /// at every call**, so a change added later has to answer for a topic's kept replies rather
    /// than fall silent about them by default.
    ///
    /// `kept` false is a change nothing need write down (#208): the screens are told and renewed,
    /// and the revision a saver reads stays where it is, so no save is made for it alone.
    private func changed(shown: Bool, replies: Bool, kept: Bool = true) {
        if kept { revision += 1 }
        if shown { drawn += 1 }
        if replies { repliesRevision += 1 }
        // Only a held row's read is noted (`read`), so more entries than rows means some went.
        if readAt.count > notes.count { readAt = readAt.filter { notes[$0.key] != nil } }
        for listener in listeners.values { listener.yield(revision) }
    }

    /// The notices held changed: their own revision moves and everyone listening is told. The
    /// revision a save writes the posts by stays where it is.
    private func noticesChanged() {
        noticesRevision += 1
        for listener in listeners.values { listener.yield(revision) }
    }

    /// A store holding what a relaunch read back from disk — the one way a snapshot gets in.
    ///
    /// **A snapshot is taken as it is, but never trusted to be well-formed.** It is whatever the
    /// last run wrote, read through a file format that can be older than this code; a duplicate
    /// in it is a bug somewhere else, and trapping at launch over it would turn that bug into an
    /// app that does not open. So the rules `add` and `ingest` keep hold here too: one source per
    /// host, the first one winning as `add` has it, and one row per `NoteKey`, the later copy
    /// winning outright — a snapshot is one moment written once, not two reads to merge.
    ///
    /// **A row that still owes a load comes in still owing it** (`Note.refsDue`, #293): the last
    /// run did not get to it, and this one asks for it — within the pace every load keeps
    /// (`LoadPacer`). Only a store laid in whole from elsewhere owes nothing (`replace`).
    ///
    /// **Notices come in only of a source still here**, the first reach of a host winning. Whether
    /// anybody is still signed in to it is not known here: the sweep that lets a gone reader's
    /// marks go lets their notices go with them (`forgetReaderMarks`).
    public init(
        sources: [Source], notes incoming: [Note], said: [SourceProfile] = [], notices: [NoticeReach] = [],
        unsent: [Unsent] = []
    ) {
        for text in unsent where !self.unsent.contains(where: { $0.id == text.id }) {
            self.unsent.append(text)
        }
        for source in sources where !sourceList.contains(where: { $0.host == source.host }) {
            sourceList.append(source)
        }
        // Only of a source still here, and without a moment it was said is a word nothing can
        // draw as said then: the first `said(_:at:)` is what puts one in.
        let hosts = Set(sourceList.map(\.host))
        for profile in said where Self.isWord(profile) && hosts.contains(profile.host) {
            saidByHost[profile.host] = profile
        }
        for reach in notices where hosts.contains(reach.host) {
            if reaches[reach.host] == nil { reaches[reach.host] = reach.bounded() }
        }
        notes = Dictionary(incoming.map { note in
            // A row holds nothing of another post (`Note.brought`): what a snapshot's rows
            // refer to is among its rows, or is not held.
            var row = note
            row.brought = []
            return (row.key, row)
        }, uniquingKeysWith: { _, new in new })
        // The order the rows are handed over is the order they arrived in: the run that wrote
        // this snapshot wrote them oldest first. A row named twice keeps the first mention's
        // place, the way `ingest` keeps a row's place when it is met again.
        for note in incoming where arrival[note.key] == nil {
            arrival[note.key] = arrivals
            arrivals += 1
        }
        // What the file says is owed is settled against what the file holds (#293): a post
        // waited for that is here is named and no longer owed, and a row that could never have
        // owed — a reblog, one with nothing to ask for — does not go on saying it does.
        Self.settleOwing(in: &notes, of: nil)
        // A reply kept before replies were items says what board it came through (#297).
        for (key, note) in notes where note.source.kind == .discuz {
            let through = Self.throughItsBoard(note, in: notes)
            if through.categories != note.categories { notes[key] = through }
        }
    }

    /// `note` as it arrived, **through its topic's board where it is a forum's dated reply**
    /// (#297): a reply is read off its topic's page, and the topic is in a board, so a rule on
    /// that board shows the reply as it shows the topic. Only a board — a topic the ranking
    /// lists named arrived as Trends, and its replies did not. Anything else is as it was; so
    /// is a reply whose topic is not held, which then says no board until it is read again
    /// beside one. A topic that gains a board later passes it on then (`admit`).
    /// The boards among `categories`, and nothing else.
    private static func boards(of categories: Set<Category>) -> Set<Category> {
        categories.filter { category in
            if case .board = category { return true }
            return false
        }
    }

    private static func throughItsBoard(_ note: Note, in notes: [NoteKey: Note], or landing: [NoteKey: Note] = [:]) -> Note {
        guard let topic = note.topicKey, !note.isPartOfTopic, let held = notes[topic] ?? landing[topic] else { return note }
        let boards = Self.boards(of: held.categories)
        guard !boards.isSubset(of: note.categories) else { return note }
        var through = note
        through.categories.formUnion(boards)
        return through
    }

    /// Everything here replaced by `sources` and `notes` in one hop — what a read back leaves
    /// (#247): the snapshot read off the package's store, adopted exactly as a relaunch would
    /// adopt it, with the same rules `init(sources:notes:)` keeps. The keep window stays the
    /// reader's and is applied to what comes in; every screen is told, and the watcher of the
    /// sources hears the new list.
    ///
    /// **No row comes in still owing a load** (`Note.refsDue`, #293). What another device had
    /// yet to ask its sources for is not this device's to ask: a store that arrived with every
    /// row marked would otherwise be a request a row to the person's own servers, set off by
    /// whoever made the package.
    ///
    /// **Every notice held goes**: they were said to whoever was signed in here before, and the
    /// sign-ins a read back leaves may be somebody else's. The next read of the page says them
    /// again, to whoever is signed in then.
    public func replace(sources: [Source], notes arriving: [Note], said: [SourceProfile] = []) {
        let incoming = arriving.map { note in
            var settled = note
            settled.refsDue = false
            settled.brought = []
            return settled
        }
        sourceList = []
        for source in sources where !sourceList.contains(where: { $0.host == source.host }) {
            sourceList.append(source)
        }
        let hosts = Set(sourceList.map(\.host))
        saidByHost = [:]
        for profile in said where Self.isWord(profile) && hosts.contains(profile.host) {
            saidByHost[profile.host] = profile
        }
        // A kept row comes in whatever its age (#284): the window is a limit, and keep wins.
        // **And so does what a row that comes in shows** (#214, #290), by `letGoBeyond`'s rule:
        // the post a kept or in-window item quotes or reblogs, never a reblog. Without it a
        // store read back would arrive with a kept reblog saying its post is not held.
        let entering = incoming.filter { $0.kept || withinRetention($0) }
        let reblogs = Set(incoming.lazy.filter(\.isReblog).map(\.key))
        let shown = Set(entering.flatMap(\.heldWith)).subtracting(reblogs)
        notes = Dictionary(
            incoming.filter { $0.kept || withinRetention($0) || shown.contains($0.key) }.map { ($0.key, $0) },
            uniquingKeysWith: { _, new in new }
        )
        arrival = [:]
        arrivals = 0
        for note in incoming where notes[note.key] != nil && arrival[note.key] == nil {
            arrival[note.key] = arrivals
            arrivals += 1
        }
        sourcesWatcher?(sourceList.map(\.host))
        noticeEpochLast += 1
        noticeEpochBase = noticeEpochLast
        noticeEpochs = [:]
        if !reaches.isEmpty {
            reaches = [:]
            noticesChanged()
        }
        changed(shown: true, replies: true)
    }

    /// Whether `note` is inside the reader's keep window.
    private func withinRetention(_ note: Note) -> Bool {
        retention.map { note.postedAt >= $0 } ?? true
    }

    /// Told the hosts of every source here, now and after every add and every removal (#220).
    /// Called inside this actor, so every change reaches it in the order it was made — one writer,
    /// however many windows read the store.
    private var sourcesWatcher: (@Sendable ([String]) -> Void)?

    /// Hands `watcher` the hosts here now, and again after every change to which sources there
    /// are. One watcher; a second replaces the first.
    public func watchSources(_ watcher: @escaping @Sendable ([String]) -> Void) {
        sourcesWatcher = watcher
        watcher(sourceList.map(\.host))
    }

    public func add(_ source: Source) {
        if sourceList.contains(where: { $0.host == source.host }) { return }
        sourceList.append(source)
        sourcesWatcher?(sourceList.map(\.host))
        changed(shown: false, replies: false)
    }

    /// Restates which boards a source is subscribed to, where that source is here.
    ///
    /// **`add` is deliberately not the place for this.** Adding a host twice keeps the first, and
    /// that is the right contract for a call that means "this server is one of the reader's" — it
    /// is what stops a second join clobbering a source with a differently-spelled kind. But a
    /// reader who opens the picker again and chooses a ninth board is not adding a server, they
    /// are changing one, and D26 says there is only ever the one to change: a board is a query
    /// *within* a source, so the set of them is a property of the host and not a new host.
    ///
    /// Silent where the host is not here, because subscribing to boards of a server nobody
    /// joined would put a source in the list by a side door — and every join in this package
    /// reads before it adds, on purpose.
    public func subscribe(host: String, to boards: [BoardSubscription]) {
        let host = host.lowercased()
        guard let index = sourceList.firstIndex(where: { $0.host == host }) else { return }
        let existing = sourceList[index]
        sourceList[index] = Source(
            host: existing.host, kind: existing.kind, boards: boards, lists: existing.lists
        )
        changed(shown: false, replies: false)
    }

    /// Restates which Mastodon lists a source reads — a choice, or the same lists relabelled with
    /// the names the server gives them now. `subscribe(host:to:)`'s rules: replaces the set, and
    /// is silent where the host is not here.
    public func subscribe(host: String, toLists lists: [ListSubscription]) {
        let host = host.lowercased()
        guard let index = sourceList.firstIndex(where: { $0.host == host }) else { return }
        let existing = sourceList[index]
        sourceList[index] = Source(
            host: existing.host, kind: existing.kind, boards: existing.boards, lists: lists
        )
        changed(shown: false, replies: false)
    }

    /// Gives the lists a source reads **now** the names in `names`, by id. Only relabels: a list
    /// chosen or unchosen while the names were on the wire stays as that choice left it. Silent
    /// where the host is not here or nothing changes.
    public func relabel(host: String, lists names: [String: String]) {
        let host = host.lowercased()
        guard let index = sourceList.firstIndex(where: { $0.host == host }) else { return }
        let existing = sourceList[index]
        let lists = existing.lists.map { ListSubscription(id: $0.id, name: names[$0.id] ?? $0.name) }
        guard lists != existing.lists else { return }
        sourceList[index] = Source(
            host: existing.host, kind: existing.kind, boards: existing.boards, lists: lists
        )
        changed(shown: false, replies: false)
    }

    /// `ingest(_:)`, only while `host` is still a source here — in the same step, so a source
    /// removed while its reads were on the wire does not get their posts back.
    public func ingest(_ incoming: [Note], ifSourceHere host: String) {
        let host = host.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return }
        ingest(incoming)
    }

    /// Takes notes in. The same item through one source stays one row: the first copy wins and
    /// categories grow, so All and Trends of one host share a row. A fetch with fewer takes none
    /// away: a category is what the copy arrived through, and that stays true (#25). The same
    /// item through two sources is two rows (#10) here, whatever the timeline draws them as: a
    /// merge (#114) is a way of drawing what is held, never a way of holding less of it.
    ///
    /// A note posted before the retention window is refused: the reader chose not to keep it.
    ///
    /// **A landing that added and merged nothing says nothing** (#175). A source asked again on a
    /// wait answers with the same page it answered with a minute ago far more often than not, and
    /// a revision moved for that page would write the whole store to disk and redraw every screen
    /// reading it, every minute, for nothing. `refresh`, `keep` and `setRetention` already only
    /// speak when something really moved; this is the fourth.
    ///
    /// **A post that quotes another brings the quoted post with it, as an item of its own** (#214): opening
    /// the quote finds it here with the network off, and no timeline draws it for having been
    /// quoted. One place, so every way a post gets in — a timeline, a search, a thread — does it.
    ///
    /// **A quoted post is kept whatever its age** while a post kept here quotes it: the reader chose
    /// how long to keep what their timelines bring, and a quote they can see but not open would be
    /// a press that goes nowhere.
    public func ingest(_ incoming: [Note]) {
        admit(incoming, exempt: false)
    }

    /// `ingest(_:)`'s landing. `exempt` takes `incoming` in whatever its age: the posts a post
    /// read again quotes (#214), which the keep window does not cut while it quotes them.
    private func admit(_ incoming: [Note], exempt: Bool, owing: Bool = true) {
        guard !incoming.isEmpty else { return }
        // A copy of a row the person keeps is taken in whatever its age (#284): the row is here
        // past the window, and what its source says of it now is still news about it.
        // Nothing but a convention carries `Note.asked` from where a status is read to here
        // (#291), so a debug build checks it: a copy that says what the reader did says when it
        // was sent. A release build takes such a copy as `outrun` says — for the older.
        assert(
            incoming.allSatisfy { note in
                !note.source.kind.saysReaderMarks || note.asked.place != nil
                    || (note.boosted == nil && note.favourited == nil && note.bookmarked == nil)
            },
            "a copy saying what the reader did reached the store without when it was sent"
        )
        // **The post a reblog reblogs is taken in with the reblog, whatever its own age** (#290),
        // as the post a post quotes is (#214): a reblog made today of a post from last year
        // stands in the window by its own time, and a row that could not show what it reblogs
        // would be a reblog of nothing.
        //
        // **And the post a reblog brought is not taken in without it.** A reblog older than the
        // window is refused; the post it carried came through no timeline of its own, and taken
        // in alone it would stand in All with nothing saying why it is here. So it is refused
        // with its reblog — unless it is already held, or another copy of it in this landing
        // arrived on its own.
        let fresh = exempt ? incoming : incoming.filter { withinRetention($0) || notes[$0.key]?.kept == true }
        let reblogged = Set(fresh.compactMap(\.reblogKey))
        let orphaned = exempt ? [] : Set(incoming.compactMap(\.reblogKey)).subtracting(reblogged)
        let admitted = exempt ? incoming : incoming.filter { note in
            if reblogged.contains(note.key) { return true }
            guard withinRetention(note) || notes[note.key]?.kept == true else { return false }
            return !(orphaned.contains(note.key) && note.categories.isEmpty && notes[note.key] == nil)
        }
        // **What an item refers to and brought with it is taken in with it** (#214, #293): the
        // post a post quotes, where its source sent that post along — at no request. It is an
        // item like any other from here, and one taken in this way owes no load of its own:
        // what is loaded for an item is the item's direct target and nothing further.
        let brought = admitted.flatMap(\.brought)
        // Its topic as held, or as this same landing brings it.
        let landing = Dictionary((admitted + brought).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let incoming = (admitted + brought).map { Self.throughItsBoard($0, in: notes, or: landing) }
        var arrived: [NoteKey] = []
        // Forum topics this landing showed to be in a board they were not held under (#297).
        var boarded: Set<NoteKey> = []
        var moved = false
        var recounted = false
        var shown = false
        var replies = false
        for (place, note) in incoming.enumerated() {
            let key = note.key
            if let existing = notes[key] {
                // **A row does not change what it is** (#290). A reblog and a post are never one
                // row: their ids are their source's own word, and a source that names a reblog
                // as a post it already handed over, or the other way about, is not believed —
                // the row held stays as it is, and the copy is not taken.
                guard existing.isReblog == note.isReblog else { continue }
                let categories = existing.categories.union(note.categories)
                let listed = existing.listed.later(note.listed)
                // What the held copy never said, this one may (#208): a row kept before its
                // audience was written down takes it from the next timeline that brings it.
                // …except what it says the reader did, where it was sent before their own act on
                // the post landed (#291): a reload on its way when they pressed.
                let older = outrun(note)
                if !older { read(note) }
                var merged = existing.filled(from: note, marksStand: older)
                // **Its source has changed it since this row was read** (#286): the row says what
                // the post says now, where it stood, and keeps what it said. A copy that is the
                // older of the two — a read still on its way when a later one landed — changes no
                // word of it.
                if note.isLater(than: existing) { merged = merged.revised(by: note, was: existing) }
                // The same source handing the post over again is the source having it (#179):
                // a mark it once earned comes off.
                let kept = categories != existing.categories
                    || listed != existing.listed || existing.goneSince != nil || merged != existing
                // The counts this copy states are the source's figure now (#208), and a later
                // figure than the one held.
                merged.counts = note.counts.filled(from: existing.counts)
                guard kept || merged.counts != existing.counts else { continue }
                merged.categories = categories
                merged.listed = listed
                merged.goneSince = nil
                notes[key] = merged
                if existing.source.kind == .discuz, Self.boards(of: categories) != Self.boards(of: existing.categories) {
                    boarded.insert(key)
                }
                shown = shown || !merged.isPartOfTopic
                replies = replies || merged.isPartOfTopic
                if kept { moved = true } else { recounted = true }
            } else {
                var note = note
                note.asked = .unsaid
                // What came with it is taken in beside it, above, and is no part of the row.
                note.brought = []
                // Never a load a copy brought in with it, from a file or another device.
                note.refsDue = false
                notes[key] = note
                if owing, place < admitted.count { arrived.append(key) }
                arrival[key] = arrivals
                arrivals += 1
                shown = shown || !note.isPartOfTopic
                replies = replies || note.isPartOfTopic
                moved = true
            }
        }
        // **A row held from before a reblog was an item** (#290) is the post, saying it arrived as
        // a reblog by somebody. Now that the reblog itself is here, it says so for itself: the
        // post's row stops saying it, and what that timeline listed — the reblog's own id, and
        // any place it is not whole there — is the reblog's to carry.
        for reblog in incoming where reblog.isReblog {
            guard let key = reblog.reblogKey, let post = notes[key], post.arrived(asReblogBy: reblog),
                  var held = notes[reblog.key], held.isReblog
            else { continue }
            //
            // **And the post no longer came through that timeline**, as a post a reblog brings
            // today does not: where the id that timeline listed the post under was the reblog's
            // own, the timeline listed the reblog. Whether it also listed the post itself, lower
            // down, before or after, this row cannot say — a later listing replaces an earlier id
            // (`listed.later`), and the reblog's is always the later — so the category comes off,
            // and a read that lists the post itself puts it back. The one case that can be told
            // is told: a copy of the post in this very landing that arrived through the timeline
            // on its own keeps the category, under the id that copy was listed by.
            let moving = post.listed.filter { reblog.listed[$0.key] == $0.value }
            var plain = post.withoutArrivalAsReblog()
            for category in moving.keys {
                held.gaps.formUnion(plain.gaps.filter { $0.category == category })
                plain.gaps = plain.gaps.filter { $0.category != category }
                let own = incoming.first { $0.key == key && !$0.isReblog && $0.listed[category] != nil }
                plain.listed[category] = own?.listed[category]
                if own == nil { plain.categories.remove(category) }
            }
            notes[key] = plain
            notes[reblog.key] = held
            moved = true
            shown = true
        }
        // **A topic found in a board passes it to the replies of it already held** (#297): they
        // were read off its page before the topic was known to be in that board, and a timeline
        // of that board would otherwise show the topic without replies All shows. Only where a
        // topic's boards grew, which is rare: one pass over that forum's rows then.
        if !boarded.isEmpty {
            for (key, note) in notes where note.source.kind == .discuz {
                guard let topic = note.topicKey, boarded.contains(topic) else { continue }
                let through = Self.throughItsBoard(note, in: notes)
                guard through.categories != note.categories else { continue }
                notes[key] = through
                moved = true
                shown = true
            }
        }
        // **An item that has just arrived owes a load where something it refers to is not held**
        // (#293) — judged once, here, after the whole landing is in, so a post and the one it
        // answers arriving together owe nothing. Only an item's first arrival: one held already,
        // read again, asks for nothing more, and a target let go later is not asked for again.
        if !arrived.isEmpty {
            // The post a reblog in this landing reblogs came with it, as a quoted post does: it
            // is what an item refers to, and owes nothing — unless it also arrived on its own.
            let carried = Set(admitted.compactMap(\.reblogKey))
            for key in arrived {
                // Every arrival that refers to a post by its source's id is looked at once: the
                // settling below names what is held and leaves owing only what is not.
                guard let note = notes[key], note.source.kind.loadsReferences,
                      !(carried.contains(key) && note.categories.isEmpty), !note.askable.isEmpty
                else { continue }
                notes[key]?.refsDue = true
            }
        }
        // **And what was owed before is settled on sight** (#293): a post some held item was
        // waiting for may be among what just landed — brought by a timeline, a thread, another
        // item's load — and that item then owes nothing and names it, whoever fetched it.
        if settleOwing(of: Set(incoming.map(\.key.host))) {
            moved = true
            shown = true
        }
        recarry(incoming.map(\.key))
        // **A landing that only recounted is drawn and not written down** (#208). A timeline read
        // every minute moves some count on nearly every page, and a save for each would be the
        // every-minute write this function exists not to make; the next change that is kept
        // carries the figures to disk with it.
        if moved {
            changed(shown: shown, replies: replies)
        } else if recounted {
            changed(shown: shown, replies: replies, kept: false)
        }
    }

    /// Posts read again (#29), only while `host` is still a source here and only those stamped
    /// with it. Unlike `ingest`, a row already held is **replaced** by what the server says now —
    /// an edited post shows its new words — keeping the categories it arrived through and its
    /// booster (`Note.refreshed(over:)`). **A post not held is dropped**: reading one post again
    /// updates what is here, and brings in nothing the reader did not already have. Returns
    /// whether anything held really changed, so a caller adopts the store only then.
    ///
    /// **A copy its source says was read before the row was** (#286) changes no word of it. Its
    /// counts still land. What it says the reader did lands only where `acted` — the source's own
    /// answer to an act the reader has just made (`MastodonWrite`), which must never be lost to a
    /// row that looks newer, and which no stale timeline or thread read is.
    ///
    /// **And `acted` marks the post as acted on, from this moment** (#291): a read sent before it
    /// — of a timeline, the post or its thread — still lands, and says nothing of what the reader
    /// did that this answer has not said more lately. Only an answer that arrives marks anything:
    /// an act the source turned away never reaches here. `acted` names the mark the act moved:
    /// that one is taken whatever the answer's age, and the other two as any copy's are.
    @discardableResult
    public func refresh(_ incoming: [Note], ifSourceHere host: String, acted: ReaderMark? = nil) -> Bool {
        let host = host.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return false }
        var moved = false
        var shown = false
        var replies = false
        var held: [Note] = []
        for note in incoming where note.source.host == host {
            // A row does not change what it is (#290), here as in `admit`: one post read again,
            // a thread, an act's answer are all read as posts, and one named as a reblog this
            // device holds is not laid over it.
            guard let existing = notes[note.key], existing.isReblog == note.isReblog else { continue }
            let stale = note.isEarlier(than: existing)
            if !stale { held.append(note) }
            // **An answer is the latest word on its own act, and on nothing else for certain**
            // (#291). It says all three marks, and two acts on one post can be out at once: the
            // answer to the second was sent before the first one's landed, and may say the old
            // word for it. So the act's own mark is always taken, and the other two only where
            // this copy is not the older — which is all a read's copy is ever taken for.
            let older = outrun(note)
            if acted == nil, !older { read(note) }
            let own: Set<ReaderMark> = acted.map { [$0] } ?? []
            // …and every read sent before this moment is older than the answer — marked whether
            // or not the answer changes the row, since a read that already said as much changes
            // nothing about which of the two is the later. After `older` is read: the answer is
            // not older than itself.
            if acted != nil { self.acted[note.key] = ReadMoment.now().place }
            // The same words read again are not a change (#175): a thread re-read with nothing
            // edited in it neither writes the store down again nor renews a screen.
            let refreshed = stale
                ? existing.restated(by: note, taking: acted == nil || older ? own : Set(ReaderMark.allCases))
                : note.refreshed(over: existing, taking: older ? own : Set(ReaderMark.allCases))
            guard refreshed != existing else { continue }
            notes[note.key] = refreshed
            moved = true
            // A reply its forum has now dated stops being a part and starts being an item
            // (#297): both lists moved. Only here — a copy taken in beside a held row leaves
            // the row's own date as it was, and this is what lays the later read over it.
            shown = shown || !refreshed.isPartOfTopic
            replies = replies || refreshed.isPartOfTopic || existing.isPartOfTopic
        }
        if moved { changed(shown: shown, replies: replies) }
        recarry(held.map(\.key))
        // The posts these quote, taken in as `ingest` takes them (#214): a quote read again may
        // name one this device has not held yet.
        let quoted = held.flatMap(\.brought)
        let before = revision
        // Brought by the post that quotes them, and so owing no load of their own (#293).
        if !quoted.isEmpty { admit(quoted, exempt: true, owing: false) }
        return moved || revision != before
    }

    /// Whether the reader's own act on this post landed after the read that brought `copy` was
    /// sent (#291), so that what the copy says they did is older than what the row says.
    ///
    /// **A copy that cannot say when it was sent is taken for one sent before**, on a post the
    /// reader has acted on and nowhere else: their own act is the surer word, and a copy that
    /// lost its moment on the way in must not be able to undo it. Every read of a source that
    /// says what the reader did says when it was sent (`StatusDTO.asNote`).
    ///
    /// **And so is a copy sent before a sign-in to its host ended** (`swept`), on any post of
    /// that host: it was read as a reader who has gone, and its marks are theirs.
    private func outrun(_ copy: Note) -> Bool {
        let key = copy.key
        guard let landed = [acted[key], swept[key.host]].compactMap({ $0 }).max() else { return false }
        guard let sent = copy.asked.place else { return true }
        return sent < landed
    }

    /// Keeps a forum row's opening post as just read, with the row (#154). Only for rows held,
    /// and only while their source is: an opening that arrives for a row a Remove took away is
    /// not a way back in. Returns whether anything changed, so a caller saves only then.
    ///
    /// `shown` is whether the screen draws what was kept from here (#209): a ranked blog opened
    /// is drawn from its row and nothing else, so its keep is a change to what is drawn, and a
    /// read of the store already on its way when it landed is read again rather than left to draw
    /// the row as it was. A thread's opening post, kept as the reader scrolls, is not (#154).
    @discardableResult
    public func keep(_ openings: [NoteKey: ForumOpening], shown: Bool = false) -> Bool {
        var moved = false
        var replies = false
        for (key, opening) in openings {
            guard let held = notes[key], held.opening != opening,
                  sourceList.contains(where: { $0.host == key.host })
            else { continue }
            notes[key] = held.with(opening: opening)
            moved = true
            replies = replies || held.isPartOfTopic
        }
        // Written down, and not a change to what is drawn: the screen draws an opening from the
        // forum's own cache as it is read, and replacing every row for each one kept as the reader
        // scrolls is what #154 set out not to do. Only a later change to what All shows carries
        // it onto the screen's rows — unless the caller says the screen draws it from here.
        if moved { changed(shown: shown, replies: replies) }
        return moved
    }

    /// The anchor a timeline is read on from (#201): the newest id a read of `category` from
    /// `host` listed a post under, of a post its source has not said is gone. A post the reader
    /// wrote, or one a search or a thread brought, was listed by no read, and is never it.
    public func newestListedID(host raw: String, category: Category) -> String? {
        let host = raw.lowercased()
        return notes.values
            .filter { $0.source.host == host && $0.goneSince == nil }
            .compactMap { $0.listed[category] }
            .max { StatusID.later($1, than: $0) }
    }

    /// The posts held of `category` from `host` that a timeline brought (#201): what a read with
    /// no anchor looks for in the newest stretch, to tell whether it reached what was held.
    public func held(host raw: String, category: Category) -> Set<NoteKey> {
        let host = raw.lowercased()
        return Set(notes.values.filter {
            $0.source.host == host && $0.categories.contains(category)
        }.map(\.key))
    }

    /// One timeline read on (#201), taken in as `ingest(_:ifSourceHere:)` takes a read, with where
    /// it is not whole kept on the posts it sits against — in the same step, so a screen never
    /// draws the posts without what is said about them.
    ///
    /// **Newer posts remaining is said once per timeline**: a read on from its newest post is what
    /// reaching it asks for, so whatever this read says replaces what the last one said. Posts
    /// that may be missing stay said; nothing read later can show they were not.
    public func land(_ read: ReadOn, of category: Category, ifSourceHere raw: String) {
        let host = raw.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return }
        ingest(read.notes)
        let remain = TimelineGap(.newerRemain, in: category)
        var marked: [NoteKey: Set<TimelineGap>] = [:]
        for (key, note) in notes where key.host == host && note.gaps.contains(remain) {
            marked[key] = note.gaps.subtracting([remain])
        }
        if let key = read.newerRemainAbove, let held = notes[key] {
            marked[key] = (marked[key] ?? held.gaps).union([remain])
        }
        if let key = read.missingBelow, let held = notes[key] {
            marked[key] = (marked[key] ?? held.gaps).union([TimelineGap(.mayBeMissing, in: category)])
        }
        var moved = false
        for (key, gaps) in marked where notes[key]?.gaps != gaps {
            notes[key]?.gaps = gaps
            moved = true
        }
        if moved { changed(shown: true, replies: false) }
    }

    /// Where posts may be missing below `key` in `category`, as reading down from it needs it
    /// (#204): the id to read before, and what is held of that timeline below it. Nothing where
    /// `key` carries no such mark, or neither the mark nor that timeline names an id to read before.
    ///
    /// **By listed ids alone** wherever this timeline listed an item held below: the items it
    /// listed under an id below the mark's — a reblog being an item under its own key (#290), so
    /// nothing is left out for being one. Only where it listed
    /// none of them — a timeline held from before listings were kept (#201) — is below read off
    /// when each was posted, and then never of a post `me` wrote or boosted, nor any row that
    /// arrived as a reblog before a reblog was an item: those
    /// are held for when they were written or boosted, not for where their timeline stands. And
    /// never while the reader is `signedIn` there and who they are is not known yet: which posts
    /// are theirs cannot be told, so nothing is guessed, nothing is asked, and the mark stays.
    public func missing(
        below key: NoteKey, in category: Category, writtenBy me: String? = nil, signedIn: Bool = false
    ) -> MissingPlace? {
        let mark = TimelineGap(.mayBeMissing, in: category)
        guard let marked = notes[key], let gap = marked.gaps.first(where: { $0 == mark }),
              let listed = gap.from ?? marked.listed[category]
        else { return nil }
        let timeline = notes.values.filter {
            $0.key != key && $0.source.host == key.host && $0.categories.contains(category)
        }
        let listedBelow = timeline.filter { note in
            note.listed[category].map { StatusID.later(listed, than: $0) } == true
        }
        if let floor = listedBelow.compactMap({ $0.listed[category] }).max(by: { StatusID.later($1, than: $0) }) {
            return MissingPlace(
                post: key, category: category, listed: listed,
                held: Set(listedBelow.map(\.key)), floor: floor
            )
        }
        let postedBelow = timeline.filter { $0.listed[category] == nil && $0.postedAt <= marked.postedAt }
        if !postedBelow.isEmpty, signedIn, me == nil { return nil }
        let held = postedBelow.filter { note in
            note.boostedBy == nil && !note.isReblog && note.boosted != true
                && me.map { note.handle.caseInsensitiveCompare($0) != .orderedSame } ?? true
        }
        return MissingPlace(
            post: key, category: category, listed: listed, held: Set(held.map(\.key)), floor: nil,
            hasBelow: !postedBelow.isEmpty
        )
    }

    /// One place posts may be missing, read down (#204), taken in as `land(_:of:ifSourceHere:)`
    /// takes a read on — what came and what it says in the same step. The mark below `key` goes;
    /// met, nothing takes its place; stopped short, it moves down to the oldest post read, reading
    /// on from the id that read reached; told there is nothing more, it settles there as of
    /// `moment`. Nothing but the posts where `key` no longer carries the mark: a read meanwhile said
    /// something else of that place.
    ///
    /// **Onto an item held**: the oldest the read listed that this store took in — a post or a
    /// reblog alike, each being what its listing listed (#290) — and back onto `key` where it took
    /// in none, one refused as older than what is kept, so the place is never left unsaid.
    public func land(
        _ down: ReadDown, below key: NoteKey, of category: Category, at moment: Date = Date(),
        ifSourceHere raw: String
    ) {
        let host = raw.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return }
        ingest(down.notes)
        let mark = TimelineGap(.mayBeMissing, in: category)
        guard notes[key]?.gaps.contains(mark) == true else { return }
        notes[key]?.gaps.remove(mark)
        let carrier = down.notes
            .filter { $0.listed[category] != nil && notes[$0.key] != nil }
            .min { StatusID.later($1.listed[category]!, than: $0.listed[category]!) }?.key ?? key
        let place: TimelineGap? = switch down.end {
        case .met: nil
        case .further(let from): TimelineGap(.mayBeMissing, in: category, from: from)
        case .settled: TimelineGap(.settled, in: category, since: moment)
        }
        // One of each kind per timeline per post: a place said there before gives way to this one.
        if let place { notes[carrier]?.gaps.update(with: place) }
        changed(shown: true, replies: false)
    }

    /// Lets go of one server: the source, the boards the reader picked on it, and the notes it
    /// carried here. Each source is its own rows, so this host's copy goes and the other source's
    /// copy of the same content stays (#10).
    ///
    /// **Nothing here knows about merged rows, and that is what makes letting go right** (#115).
    /// A post two sources carried is drawn as one row but held as two, so taking one server's
    /// copies away leaves the other's exactly as it arrived, and the row it was merged into is
    /// drawn again from what is left — as that source carried it. A merge stores nothing of its
    /// own, so nothing of one outlives the copies it was drawn from.
    ///
    /// Silent where the host is not here, for the reason `subscribe(host:to:)` is: nothing in this
    /// package puts a source in the list, or takes one out of it, by a side door.
    ///
    /// **`keepingPosts` leaves the notes where they are** (#250): the reader chose that a removed
    /// source's posts stay. They are still drawn by `all()` and found by a search, and they go
    /// the way any other note goes — by the window, or by a later story's limit. What stops is
    /// everything that reads by the source: `ingest(_:ifSourceHere:)`, `keep`, `markGone` and
    /// the rest all ask `sourceList` first, so nothing new lands under a host that has gone.
    /// Each note still names its source, so a row can say which host it was read through and
    /// that the host is no longer here.
    ///
    /// **A post the person keeps stays either way** (#284), exactly as `keepingPosts` leaves one:
    /// still drawn, still naming the source it was read through, and marked by the row as from a
    /// host no longer here. It goes once it is un-kept and something lets it go.
    ///
    /// **What it said happened to the person goes either way**: a notice is not a post, and
    /// nothing reads it once its source is not here. Returns whether any did, so a caller
    /// that must have them off the disk before it goes on knows to wait for the write.
    @discardableResult
    public func remove(host raw: String, keepingPosts: Bool = false) -> Bool {
        let host = raw.lowercased()
        sourceList.removeAll { $0.host == host }
        saidByHost[host] = nil
        let told = letNoticesGo(host: host)
        sourcesWatcher?(sourceList.map(\.host))
        if keepingPosts {
            changed(shown: false, replies: false)
            return told
        }
        let shown = shownByKept()
        let going = notes.values.filter { $0.key.host == host && !$0.kept && !shown.contains($0.key) }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        changed(shown: true, replies: going.contains { $0.isPartOfTopic })
        return told
    }

    public func sources() -> [Source] {
        sourceList
    }

    /// Writes down what `profile.host` has just said about itself, as of `moment`, in place of
    /// whatever it said before (#188). Silent where the host is not a source here, for
    /// `subscribe(host:to:)`'s reason: a description of a server nobody joined has nowhere to go.
    ///
    /// **A change a save writes and no timeline shows**: the row and the composer read it, All
    /// does not.
    public func said(_ profile: SourceProfile, at moment: Date = Date()) {
        let stamped = profile.said(at: moment)
        guard Self.isWord(stamped), sourceList.contains(where: { $0.host == stamped.host }) else { return }
        let before = saidByHost[stamped.host]
        saidByHost[stamped.host] = stamped
        // The same word again moves only the moment, and the moment is not written: a launch
        // that hears every source say what it said last time would otherwise write the index
        // once per source for nothing a reader could tell apart. The screens are told, so the
        // page says the newer moment this run; the index keeps the older until a word changes.
        let sameWord = before.map { $0.said(at: moment) == stamped } ?? false
        changed(shown: false, replies: false, kept: !sameWord)
    }

    /// Whether `profile` is a word worth keeping: said at a moment, and of a kind this app can
    /// name. A kept `.unknown` would stand in for the join's note across relaunches and put a
    /// source nothing reads in the list, with no ask to move it — so it is no word at all.
    private static func isWord(_ profile: SourceProfile) -> Bool {
        profile.asOf != nil && profile.kind != .unknown
    }

    /// What `host` last said about itself, marked as of when, or nothing where it has not been
    /// heard, or a Clear let its word go.
    public func said(host raw: String) -> SourceProfile? {
        saidByHost[raw.lowercased()]
    }

    /// Every source's last word about itself, by host.
    public func saidAll() -> [String: SourceProfile] {
        saidByHost
    }

    /// Lets go of what `host` said about itself — a Clear, which empties what this device holds
    /// of a server and leaves the server joined. The next ask writes it down again.
    public func forgetSaid(host raw: String) {
        let host = raw.lowercased()
        guard saidByHost.removeValue(forKey: host) != nil else { return }
        changed(shown: false, replies: false)
    }

    /// Keeps only the latest `months` months as of `now` from here on, or everything where
    /// `months` is nil — forever, the default (#7). Drops what is already older, and returns how
    /// many notes went, so a caller writes and redraws only when something did. Sources are
    /// untouched: a source with nothing left inside the window stays joined.
    @discardableResult
    public func setRetention(months: Int?, from now: Date = Date(), calendar: Calendar = .current) -> Int {
        letGoBeyond(months: months, from: now, calendar: calendar).posts
    }

    /// `setRetention`, saying which sources the posts went from as well as how many (#251) — what
    /// the months limit writes into its account. **A kept post stays whatever its age** (#284),
    /// and is counted in nothing that went.
    public func letGoBeyond(months: Int?, from now: Date = Date(), calendar: Calendar = .current) -> WentByLimit {
        retention = KeepPolicy.cutoff(keepingMonths: months, from: now, calendar: calendar)
        guard let retention else { return .none }
        // A notice older than the limit goes as a post does, and so does the copy of a post that
        // old a newer notice carries: left, they would be words older than the limit on disk.
        var noticed = false
        for (host, reach) in reaches {
            let kept = reach.within(retention).bounded()
            guard kept != reach else { continue }
            reaches[host] = kept
            noticed = true
        }
        if noticed { noticesChanged() }
        let before = notes.count
        // A quoted post a kept post quotes stays, as `ingest` keeps it (#214): the window's reach
        // has passed it, the quote's has not.
        let quoted = Set(notes.values.filter { $0.kept || $0.postedAt >= retention }.flatMap(\.heldWith))
            .filter { notes[$0]?.isReblog != true }
        var kept: [NoteKey: Note] = [:]
        var gone: Set<String> = []
        var replies = false
        for (key, note) in notes {
            if note.kept || note.postedAt >= retention || quoted.contains(key) {
                kept[key] = note
            } else {
                gone.insert(key.host)
                replies = replies || note.isPartOfTopic
            }
        }
        notes = kept
        if notes.count != before {
            arrival = arrival.filter { notes[$0.key] != nil }
            changed(shown: true, replies: replies)
        }
        return WentByLimit(posts: before - notes.count, sources: gone.sorted())
    }

    /// Lets go of the `count` oldest posts held — the room limit's step past the picture copies
    /// (#249). Returns how many went and from which sources.
    ///
    /// **Oldest by when they were posted, across every source, a topic's kept replies included**: the
    /// room is this device's and not one source's, and a kept reply weighs what a
    /// timeline's post does. Two posted in the same second go in the order they arrived. A post
    /// another held post quotes stays whatever its age, as the keep window keeps it (#214): it
    /// goes once the post quoting it has. **A kept post is never one of them** (#284): the oldest
    /// that are not kept go, and where only kept posts are left nothing goes at all.
    public func letGoOldest(count: Int) -> WentByLimit {
        guard count > 0, !notes.isEmpty else { return .none }
        let going = mayGoForRoom().prefix(count)
        guard !going.isEmpty else { return .none }
        for note in going {
            notes[note.key] = nil
            self.arrival[note.key] = nil
        }
        strike(carried: Set(going.map(\.key)))
        changed(shown: going.contains { !$0.isPartOfTopic }, replies: going.contains { $0.isPartOfTopic })
        return WentByLimit(posts: going.count, sources: Set(going.map(\.key.host)).sorted())
    }

    /// Whether `letGoOldest` could let anything go right now (#284): a post is held that is
    /// neither kept nor quoted by a held post. What the room check asks before it spends the
    /// picture copies — asked of the store each time, so a post un-kept, from this window or
    /// another, is seen by the very next check.
    public func holdsWhatRoomMayLetGo() -> Bool {
        !mayGoForRoom().isEmpty
    }

    /// The rows `letGoOldest` chooses among, in the order they go: oldest posted first, two of
    /// one second in the order they arrived. Not kept, and not held for another item that stays.
    ///
    /// **Held for another only while that other is staying** (#290, #214). A post is spared for
    /// an item that quotes or reblogs it where that item is kept, or shown by a kept reblog, or
    /// **goes later than the post does** in this order — so the post goes once what shows it has.
    /// An item that goes no later than what it refers to spares nothing: two rows naming each
    /// other, or a chain of them, cannot hold one another here for ever, and a store that only
    /// such rows fill is never one the room says only kept posts fill. **And a reblog is spared
    /// for nothing that refers to it**: what a reference keeps is a post to show, and a reblog
    /// shows none of its own.
    private func mayGoForRoom() -> [Note] {
        let arrival = self.arrival
        let order = notes.values.sorted {
            $0.postedAt != $1.postedAt
                ? $0.postedAt < $1.postedAt
                : (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0)
        }
        var rank: [NoteKey: Int] = [:]
        for (index, note) in order.enumerated() { rank[note.key] = index }
        let shown = shownByKept()
        var spared: Set<NoteKey> = []
        for (index, note) in order.enumerated() {
            let stays = note.kept || shown.contains(note.key)
            for key in note.heldWith where notes[key]?.isReblog == false {
                if stays || (rank[key] ?? .max) < index { spared.insert(key) }
            }
        }
        return order.filter { !$0.kept && !shown.contains($0.key) && !spared.contains($0.key) }
    }

    /// The posts kept reblogs show (#290). **Keeping a reblog keeps what it shows**: the mark is
    /// on the reblog — the item the person pressed — and the post it reblogs is held for as long
    /// as that mark is, by every letting go there is: the window, the room, a span of dates, a
    /// source removed, a post its source says is gone. A kept row that could come to say its
    /// post is no longer held would be a keep that kept nothing the person could see.
    private func shownByKept() -> Set<NoteKey> {
        Set(notes.values.lazy.filter { $0.kept && $0.isReblog }.compactMap(\.reblogKey))
    }

    /// How many rows were posted inside `span` and, where `host` is given, came through that host
    /// — items and a topic's kept replies alike (#248). What a press to let a span go would take, so the question
    /// before it names the true count: a kept post is not counted, since the press leaves it (#284).
    public func count(span: Range<Date>, host raw: String? = nil) -> Int {
        let host = raw?.lowercased()
        let shown = shownByKept()
        return notes.values.reduce(0) { $0 + (Self.inside(span, host: host, $1, shown) ? 1 : 0) }
    }

    /// Lets go of every row posted inside `span`, from `host` or from every host where nil — the
    /// reader's own press (#248). Returns how many went.
    ///
    /// **Exactly the rows named, and nothing the app chooses.** The keep-for window spares a post
    /// a kept post quotes; this does not, because the reader said these days go and a quoted post
    /// posted on them is one of them. Nothing outside the span or from another host moves, and
    /// every source stays joined — a host with nothing left is a source with nothing held, as
    /// `setRetention` leaves one. The host need not be a source here: a source removed while its
    /// posts were kept (#250) leaves rows this reaches like any other.
    ///
    /// **Never a post the person keeps** (#284): keep is their word too, and the later one to
    /// undo. A post a kept post quotes is not spared for that, as above.
    @discardableResult
    public func letGo(span: Range<Date>, host raw: String? = nil) -> Int {
        let host = raw?.lowercased()
        let shown = shownByKept()
        let going = notes.values.filter { Self.inside(span, host: host, $0, shown) }
        // **And the copy of a post of those days a notice carries**, an item or not: the reader
        // said these days go. Not one of a post that stays held — a kept one.
        let leaving = Set(going.map(\.key))
        let held = notes
        strike { post in
            span.contains(post.postedAt) && (host == nil || post.source.host == host)
                && (held[post.key] == nil || leaving.contains(post.key))
        }
        guard !going.isEmpty else { return 0 }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        changed(shown: going.contains { !$0.isPartOfTopic }, replies: going.contains { $0.isPartOfTopic })
        return going.count
    }

    /// Whether `note` is what `letGo(span:host:)` reaches: posted inside `span`, from `host`
    /// where one is named, and not kept.
    private static func inside(_ span: Range<Date>, host: String?, _ note: Note, _ shownByKept: Set<NoteKey>) -> Bool {
        !note.kept && !shownByKept.contains(note.key)
            && span.contains(note.postedAt) && (host == nil || note.source.host == host)
    }

    /// Everything this store holds, read in one hop — what a save writes to disk.
    ///
    /// **In the order the rows arrived, and taken at one moment.** A save does not draw anything,
    /// so it has no use for `all()`'s order; what it does need is the order the rows came in, so
    /// that the run reading them back knows which copy of a post arrived first (#114). And asking
    /// for the sources and the notes in two awaits would let an ingest or a remove land between
    /// them, writing notes whose source is gone. This is the counterpart of
    /// `init(sources:notes:)`. `revision` is the one this snapshot is of, read in the same hop.
    public func snapshot() -> (sources: [Source], notes: [Note], said: [SourceProfile], revision: Int) {
        let arrival = self.arrival
        let ordered = notes.values.sorted { (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0) }
        // By host, so one state of the store is always written one way.
        let said = saidByHost.values.sorted { $0.host < $1.host }
        return (sourceList, ordered, said, revision)
    }

    /// Holds a text pressed to send, or what is now known of one already held — in its place.
    ///
    /// **Not one let go of this run** (`unsentGone`): whoever writes it now took its copy before
    /// the person, or its landing, said it goes (#292). Returns whether it is held — **and
    /// whoever is about to send it does not, on a no.**
    @discardableResult
    public func hold(_ text: Unsent) -> Bool {
        guard !unsentGone.contains(text.id) else { return false }
        if let at = unsent.firstIndex(where: { $0.id == text.id }) {
            guard unsent[at] != text else { return true }
            unsent[at] = text
        } else {
            unsent.append(text)
        }
        unsentRevision += 1
        unsentChanged()
        return true
    }

    /// Lets a text go: it landed, or the person discarded it. Held or not, its name is not
    /// held again (`hold(_:)`), and nobody is sending it any more.
    public func letGo(unsent id: UUID) {
        var moved = unsentGone.insert(id).inserted
        if unsentSenders.removeValue(forKey: id) != nil { moved = true }
        if let at = unsent.firstIndex(where: { $0.id == id }) {
            unsent.remove(at: at)
            unsentRevision += 1
            moved = true
        }
        if moved { unsentChanged() }
    }

    /// Takes the sending of one text for `sender`, where nobody else has it: **the one place
    /// it is decided who sends a text**, so it is never sent by two at once. True where
    /// `sender` has it — now, or already. Whether the text is still held is not asked here:
    /// that is `hold(_:)`'s to say, and a sender asks both.
    public func claim(unsent id: UUID, for sender: UUID) -> Bool {
        if let has = unsentSenders[id] { return has == sender }
        unsentSenders[id] = sender
        unsentChanged()
        return true
    }

    /// Gives the sending of one text back, where `sender` has it: its request has ended,
    /// whatever became of it.
    public func release(unsent id: UUID, from sender: UUID) {
        guard unsentSenders[id] == sender else { return }
        unsentSenders[id] = nil
        unsentChanged()
    }

    /// The texts as they stand, read in one hop: each held, who is sending which, and the
    /// names let go of this run — what every page that draws them draws from, so a text
    /// discarded, landed, changed or taken to send through one of them is so in all.
    public func unsentView() -> UnsentView {
        UnsentView(texts: unsent, senders: unsentSenders, gone: unsentGone, mark: unsentMark)
    }

    /// Every text held, in the order pressed.
    public func unsentHeld() -> [Unsent] { unsent }

    /// The texts and the revision they are at, read in one hop — what a save writes of them.
    public func unsentSnapshot() -> (unsent: [Unsent], revision: Int) {
        (unsent, unsentRevision)
    }

    // MARK: - What each source says happened to the person (#323)

    /// Holds what one source has handed over of its notices, in the place of what was held of
    /// it: its lines, and how far down it was read. Only while its host is a source here, and
    /// nothing where it is what is held already. Kept to `NoticeReach.capacity` lines. Returns
    /// the notices' revision as this call left it, so whoever wrote knows what it wrote.
    ///
    /// **`fresh` names the lines the source has just said**, where the caller knows: every
    /// other line is one it held already, and where the copy here has had its post struck
    /// since — the post was let go while the caller's copy was on its way — it stays struck.
    /// A copy of what was held must not put back words this device let go (#292); only the
    /// source saying them again does. Nothing named is everything taken as given.
    @discardableResult
    public func hold(_ reach: NoticeReach, fresh: Set<String>? = nil) -> Int {
        hold(reach, fresh: fresh, since: nil).revision
    }

    /// `hold(_:fresh:)`, by a writer that says which epoch of the host its copy is from —
    /// **and is not taken where the host's notices were let go since**: the copy is of what a
    /// reader no longer here was told. Checked here, where the letting go happens, so no
    /// order of arrival can put it back. `nil` is a writer with nothing from before: taken.
    /// Returns the epoch the host is at, for the writer's next.
    @discardableResult
    public func hold(_ reach: NoticeReach, fresh: Set<String>?, since epoch: Int?) -> (revision: Int, epoch: Int) {
        let now = noticeEpoch(reach.host)
        guard epoch == nil || epoch == now else { return (noticesRevision, now) }
        return (held(reach, fresh: fresh), now)
    }

    private func held(_ reach: NoticeReach, fresh: Set<String>?) -> Int {
        guard sourceList.contains(where: { $0.host == reach.host }) else { return noticesRevision }
        // No line older than the months limit is held, whoever wrote it and whenever: a
        // write made of a copy from before the limit acted puts none back.
        var bounded = reach.withinLines(retention).bounded()
        if let fresh, let held = reaches[reach.host] {
            let struck = Set(held.notices.lazy.filter { $0.post == nil }.map(\.id))
            if bounded.notices.contains(where: { $0.post != nil && struck.contains($0.id) && !fresh.contains($0.id) }) {
                bounded.notices = bounded.notices.map { line in
                    line.post != nil && struck.contains(line.id) && !fresh.contains(line.id) ? line.carrying(nil) : line
                }
            }
        }
        guard reaches[reach.host] != bounded else { return noticesRevision }
        reaches[reach.host] = bounded
        noticesChanged()
        return noticesRevision
    }

    /// Lets go of everything one source said happened to the person. Whether anything went.
    @discardableResult
    public func letNoticesGo(host raw: String) -> Bool {
        endNoticeEpoch(raw.lowercased())
        guard reaches.removeValue(forKey: raw.lowercased()) != nil else { return false }
        noticesChanged()
        return true
    }

    /// The revision a save writes the posts by and the one it writes the notices by, in one hop:
    /// what a saver following this store looks at.
    public var revisions: (items: Int, notices: Int) { (revision, noticesRevision) }

    /// Every source's notices as held, in host order, and the revision they are at — read in
    /// one hop, so a page taking them knows whether they are newer than what it last wrote.
    ///
    /// With them, the epoch each source's notices are at (`hold(_:fresh:since:)`) and the
    /// moment the months limit lets go of everything before, where there is a limit: a page
    /// draws no line past it, though a stretch read on to this run is held until the limit acts.
    public func noticesHeld() -> (notices: [NoticeReach], revision: Int, epochs: [String: Int], cutoff: Date?) {
        (
            reaches.values.sorted { $0.host < $1.host }, noticesRevision,
            Dictionary(sourceList.map { ($0.host, noticeEpoch($0.host)) }, uniquingKeysWith: { first, _ in first }),
            retention
        )
    }

    /// How many lines are held of each source, by host: what Usage says of them.
    public func noticesCount() -> [String: Int] {
        reaches.mapValues { $0.withinLines(retention).notices.count }
    }

    /// The epoch each source's notices are at: what a page that writes them names.
    public func noticesEpochs() -> [String: Int] {
        Dictionary(sourceList.map { ($0.host, noticeEpoch($0.host)) }, uniquingKeysWith: { first, _ in first })
    }

    /// What a save writes of the notices, and the revision it is of. **Nothing older than the
    /// months limit**: a line read on to past it, or the copy of a post that old a newer line
    /// carries, is drawn for the run as it was read and is never written (`NoticeReach.within`).
    public func noticesSnapshot() -> (notices: [NoticeReach], revision: Int) {
        (reaches.values.sorted { $0.host < $1.host }.map { $0.within(retention).bounded() }, noticesRevision)
    }

    /// Strikes the carried copy of each post `gone` names from every line that carries it —
    /// **called by every function here that lets a post go**: `letGoOldest`, `letGo(span:host:)`,
    /// `forget`, `letGoneGo`; `letGoBeyond` strikes by age and `remove`, `replace` and
    /// `forgetReaderMarks` let the lines themselves go. A purge leaves nothing behind (#282): a
    /// post let go and still readable in a notice's line would be exactly that. The line stays.
    private func strike(carried gone: (Note) -> Bool) {
        var moved = false
        for (host, reach) in reaches {
            let struck = reach.striking(gone)
            guard struck != reach else { continue }
            reaches[host] = struck
            moved = true
        }
        if moved { noticesChanged() }
    }

    private func strike(carried keys: Set<NoteKey>) {
        strike { keys.contains($0.key) }
    }

    /// The carried copy of each post among `keys` made what the row held now says, where the
    /// source has said something else of it since: its words, its cover, what it shows. Called
    /// where a post is read again — opened from its notice among them — so a post its author
    /// has since covered or changed is not left as it was in the notice's line.
    ///
    /// **What stays as it was read**: the copy of a post nobody has opened or read again.
    /// Whether a post is gone, covered or changed is learnt only when it is loaded; until
    /// then its line carries what the source said when the line was read — until that stretch
    /// is read again, the months limit lets the line go, or the bound does.
    private func recarry(_ keys: some Sequence<NoteKey>) {
        guard !reaches.isEmpty else { return }
        let named = Set(keys)
        var moved = false
        for (host, reach) in reaches {
            var lines = reach.notices
            var touched = false
            for (place, line) in lines.enumerated() {
                guard let carried = line.post, named.contains(carried.key), let held = notes[carried.key],
                      held.body != carried.body || held.spoiler != carried.spoiler
                      || held.sensitive != carried.sensitive || held.title != carried.title
                      || held.attachments != carried.attachments || held.editedAt != carried.editedAt
                else { continue }
                lines[place] = line.carrying(held)
                touched = true
            }
            guard touched else { continue }
            reaches[host]?.notices = lines
            moved = true
        }
        if moved { noticesChanged() }
    }

    /// Every item this device holds, newest first (#296): whatever brought it — a timeline, a
    /// search, a read under a tag, a thread opened, a quote — it is an item like any other, and
    /// every timeline whose rules let it through shows it. What it arrived through is its
    /// categories, and one that arrived through none is shown by no rule on a category.
    ///
    /// **Never a forum topic's reply its forum gave no date** (`Note.isPartOfTopic`): that is a
    /// part of a topic and not an item, and is handed over by `replies()`. A reply the forum
    /// dated is an item, and is here (#297).
    public func all() -> [Note] {
        let arrival = self.arrival
        let stalled = self.stalled
        return notes.values.filter { !$0.isPartOfTopic }
            .map { note in
                // Named and not held: asked of what is held now, for the few items that name
                // anything — one lookup a name, and nothing for an item that names none.
                var unheld: Set<Reference.Kind> = []
                for reference in note.refs where reference.kind != .reblogs {
                    if let id = reference.id, notes[NoteKey(host: note.key.host, id: id)] == nil { unheld.insert(reference.kind) }
                }
                let stalls = !stalled.isEmpty && stalled.contains(note.key)
                let tried = refused.isEmpty ? nil : refused[note.key]
                guard stalls || !unheld.isEmpty || tried != nil else { return note }
                var said = note
                said.refsStalled = stalls
                said.refsUnheld = unheld
                if let tried {
                    said.refsTried = Set(note.refs.filter { $0.statusID.map(tried.contains) == true }.map(\.kind))
                }
                return said
            }
            .sorted { Self.storeOrder($0, $1, arrival) }
    }

    // MARK: - What an item refers to, loaded (#293)

    /// The items whose load was given up for this run. Of this run only: never written down.
    private var stalled: Set<NoteKey> = []
    /// What was asked for an item this run and came back as nothing to keep — not the post
    /// asked for, or an answer that is no word on it — by item, as the source's ids asked. Not
    /// asked again this run: the item may still owe another load, and without this the one
    /// that was refused would be asked for again each time its row came near. Of this run only.
    private var refused: [NoteKey: Set<String>] = [:]

    /// The name of every post among `notes` held from each of `hosts`, by its source's own id.
    private static func named(in notes: [NoteKey: Note], of hosts: Set<String>) -> [String: [String: String]] {
        var names: [String: [String: String]] = [:]
        for note in notes.values where hosts.contains(note.key.host) && !note.isReblog {
            if let id = note.statusID { names[note.key.host, default: [:]][id] = note.id }
        }
        return names
    }

    /// Settles what the items of `hosts` owe against what is held now (#293): a reference whose
    /// post is held is given that post's name, however the post came to be here — a timeline
    /// brought it later, a thread was read, another item's load fetched it — and an item with
    /// nothing left that could be asked for owes nothing. That last is also what takes the mark
    /// off anything that could never have owed: a reblog, an item whose references name nothing
    /// askable, a row a file says owes and cannot.
    ///
    /// **A post said to be gone that is held after all is not gone**: the reference is named
    /// and the word comes off, whichever way the post arrived.
    ///
    /// **Only items that owe, or say a post is gone, are looked at**: one pass to find them — and where there are none,
    /// which is nearly always, that pass is all — then one pass over their hosts' items for the
    /// names. Returns the items that changed.
    @discardableResult
    private static func settleOwing(in notes: inout [NoteKey: Note], of hosts: Set<String>?) -> [NoteKey] {
        // Items that owe — and items that say a post is gone: said once, on one answer, and
        // taken back where the post turns up after all.
        let owing = notes.values.filter {
            ($0.refsDue || $0.refs.contains(where: \.gone)) && (hosts?.contains($0.key.host) ?? true)
        }
        guard !owing.isEmpty else { return [] }
        let names = named(in: notes, of: Set(owing.map(\.key.host)))
        var moved: [NoteKey] = []
        for note in owing {
            let held = names[note.key.host] ?? [:]
            let settled = note.refs.map { reference -> Reference in
                guard reference.kind != .reblogs, reference.id == nil,
                      let statusID = reference.statusID, let id = held[statusID]
                else { return reference }
                // Held, so named — and no longer gone, whatever its source once answered.
                return Reference(
                    kind: reference.kind, id: id, statusID: statusID, handle: reference.handle, state: reference.state
                )
            }
            var now = settled == note.refs ? note : note.referring(by: settled)
            if now.askable.isEmpty { now.refsDue = false }
            guard now != note else { continue }
            notes[note.key] = now
            moved.append(note.key)
        }
        return moved
    }

    /// `settleOwing(in:of:)` over what this store holds. Whether any row changed.
    @discardableResult
    private func settleOwing(of hosts: Set<String>? = nil) -> Bool {
        let moved = Self.settleOwing(in: &notes, of: hosts)
        for key in moved where notes[key]?.refsDue == false {
            stalled.remove(key)
            refused[key] = nil
        }
        // An item left owing only what was already tried and refused owes nothing more: the
        // mark comes off, as it does where the one thing an item owed is refused.
        var cleared = false
        for (key, tried) in refused where hosts?.contains(key.host) ?? true {
            guard let note = notes[key] else {
                refused[key] = nil
                continue
            }
            guard note.refsDue, note.askable.allSatisfy({ tried.contains($0.statusID) }) else { continue }
            notes[key]?.refsDue = false
            refused[key] = nil
            cleared = true
        }
        return !moved.isEmpty || cleared
    }

    /// One load an item owes: the item, and the source's own id of the post to ask for.
    public struct Owed: Sendable, Equatable {
        public let item: NoteKey
        public let kind: Reference.Kind
        public let statusID: String
        /// Whether the item may have arrived only because somebody was signed in — through
        /// anything but a public timeline. What an unsigned read says of the post such an item
        /// refers to is not the source's word on it: a post its reader could see may answer
        /// "no such post" to nobody in particular.
        public let asReader: Bool

        public init(item: NoteKey, kind: Reference.Kind, statusID: String, asReader: Bool = false) {
            self.item = item
            self.kind = kind
            self.statusID = statusID
            self.asReader = asReader
        }
    }

    /// What the items held from `host` still owe, newest item first, less what was given up for
    /// this run — or only what `items` owe, where given, which looks at those items alone.
    /// Nothing where `host` is not a source here. **Each is one post to ask the item's own
    /// source for, by that source's id for it**: never another host, and never an address.
    public func owed(host raw: String, among items: Set<NoteKey>? = nil) -> [Owed] {
        let host = raw.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return [] }
        let candidates: [Note] = items.map { $0.compactMap { notes[$0] } } ?? Array(notes.values)
        let arrival = self.arrival
        return candidates
            .filter { $0.refsDue && $0.key.host == host && !stalled.contains($0.key) }
            .sorted { Self.storeOrder($0, $1, arrival) }
            .flatMap { note in
                note.askable.filter { refused[note.key]?.contains($0.statusID) != true }.map {
                    Owed(item: note.key, kind: $0.kind, statusID: $0.statusID, asReader: Self.arrivedAsReader(note))
                }
            }
    }

    /// Whether `note` reached this device by a read made as the reader — **a fact about a
    /// signed read, and the one place it is told** (#293). What such an item refers to is the
    /// reader's to ask for: never asked unsigned in their place, an unsigned "no such post"
    /// about it is not the source's word, and what it still owes goes when their sign-in ends.
    ///
    /// **Told by what the item itself carries**, since nothing else outlasts the read:
    /// - Through the public timeline or what is rising there: not the reader's. An unsigned read
    ///   brings those, whoever was signed in.
    /// - Through Home or a list: the reader's. Nobody else has those timelines.
    /// - Through no category — a search, a thread, a hashtag's read — it is the reader's only
    ///   where the copy says what the reader did to the post (`boosted`, `favourited`,
    ///   `bookmarked`, as yes or as no). A source says those to a signed read and to no other,
    ///   so an item without them was read unsigned: on a source nobody is signed in to, nothing
    ///   arrived as the reader, what it refers to may be asked unsigned, and an unsigned "no
    ///   such post" is that source's word.
    ///
    /// **Written down with the item, and let go with the sign-in.** Those marks are kept in the
    /// store, so a launch knows it of a row from the last run; and the sweep that takes them
    /// off when a sign-in ends (`forgetReaderMarks`) drops such an item's debt in the same step,
    /// so no row is left owing as a reader nobody can name.
    private static func arrivedAsReader(_ note: Note) -> Bool {
        var through = false
        for category in note.categories {
            switch category {
            case .public, .trends: return false
            case .home, .list: through = true
            case .board: break
            }
        }
        return through || note.boosted != nil || note.favourited != nil || note.bookmarked != nil
    }

    /// How one load ended, as whoever made the request reports it.
    public enum Loaded: Sendable {
        /// The source handed the post over.
        case held(Note)
        /// The source says there is no such post (404, 410): gone, said so where the reference
        /// is shown, and not asked for again.
        case gone
        /// The source did not hand the post over to who asked, and that is no word on whether it
        /// exists — an unsigned read of what a signed-in reader's item refers to. Not asked for
        /// again, and not said to be gone.
        case notSaid
        /// Given up for this run: the item still owes it, and a later run asks again.
        case stalled
    }

    /// Takes in what one load brought for `owed`, and settles what the item owes.
    ///
    /// **The post loaded is an item like any other** (#296): at its own publish time, through no
    /// category, and owing no load of its own — what it refers to in turn is not followed. It is
    /// taken in whatever its age, for the item that refers to it, and stays while that item
    /// does (`Note.heldWith`): the reference is given the post's name, which is what holds it.
    ///
    /// **Only the post that was asked for.** One whose id at its source is not the id asked, one
    /// stamped with another source, and a reblog are not what the item refers to, and are not
    /// taken: the source is not believed about a post nobody asked it for.
    ///
    /// Nothing where the item is no longer held, or its source no longer here: a load that
    /// comes back to a row let go of lands nowhere.
    public func land(_ loaded: Loaded, for owed: Owed) {
        let key = owed.item
        guard sourceList.contains(where: { $0.host == key.host }), let item = notes[key] else { return }
        /// The item's references, with the one that was asked for settled by `change`.
        func referring(_ change: (Reference) -> Reference) -> [Reference] {
            item.refs.map { reference in
                reference.kind == owed.kind && reference.statusID == owed.statusID && reference.id == nil ? change(reference) : reference
            }
        }
        switch loaded {
        case .stalled:
            guard stalled.insert(key).inserted else { return }
            changed(shown: true, replies: false, kept: false)
            return
        case .held(let post):
            guard post.source.host == key.host, post.statusID == owed.statusID, !post.isReblog else {
                // Not what was asked for: nothing is taken, and it is not asked for again.
                notes[key] = withoutAsking(item, for: owed)
                break
            }
            var arriving = post
            arriving.categories = []
            arriving.listed = [:]
            arriving.gaps = []
            admit([arriving], exempt: true, owing: false)
        case .gone:
            notes[key] = item.referring(by: referring { $0.settled(gone: true) })
        case .notSaid:
            notes[key] = withoutAsking(item, for: owed)
        }
        // Whatever came, what is held now decides what is still owed — this item's and every
        // other's that was waiting on the same post.
        stalled.remove(key)
        settleOwing(of: [key.host])
        changed(shown: true, replies: false)
    }

    /// `item` no longer owing a load of what `owed` names, with nothing learned of that post:
    /// the mark comes off where it was the last thing owed, and the reference stays as it was.
    ///
    /// **Where the item owes another load too, this one is remembered as tried** (`refused`):
    /// the mark stays for the other, and the reference that was asked is not asked again this
    /// run nor said to be on its way.
    private func withoutAsking(_ item: Note, for owed: Owed) -> Note {
        var now = item
        if item.askable.allSatisfy({ $0.statusID == owed.statusID }) {
            now.refsDue = false
            refused[item.key] = nil
        } else {
            refused[item.key, default: []].insert(owed.statusID)
        }
        return now
    }

    /// Lets every item of `host` whose load was given up be asked for again: the reader asked,
    /// or signed in again.
    public func unstall(host raw: String) {
        let host = raw.lowercased()
        let before = stalled.count + refused.count
        stalled = stalled.filter { $0.host != host }
        refused = refused.filter { $0.key.host != host }
        if stalled.count + refused.count != before { changed(shown: true, replies: false, kept: false) }
    }

    /// Every kept reply of a forum topic that its forum gave no date, newest first — what `all()` leaves out. For the count
    /// of what this device holds, which they are part of; nothing draws them but their topic,
    /// which reads its own through `held(host:idPrefix:)`.
    public func replies() -> [Note] {
        let arrival = self.arrival
        return notes.values.filter(\.isPartOfTopic)
            .sorted { Self.storeOrder($0, $1, arrival) }
    }


    /// Lets go of one row — a post its author took back (#109). Silent where it is not held.
    ///
    /// **One row and never a host's worth.** `remove(host:)` is the reader letting go of a server;
    /// this is a server saying one post no longer exists, and the other copies of it through other
    /// sources are theirs to say about.
    ///
    /// **A row the person keeps is not let go by this either** (#284): it stays, marked as gone
    /// from its source as of `moment` — which it now is — and goes once it is un-kept and what is
    /// marked is let go. One already marked keeps the moment it was first heard. **Nor is the
    /// post a kept reblog shows** (#290), the reader's own post taken back included: it stays,
    /// marked the same way, for as long as that reblog is kept.
    ///
    /// **The copy a notice carries of it is struck**, whether or not the post was ever an item
    /// here — but for one that stays held, which is still this device's to show.
    public func forget(_ key: NoteKey, at moment: Date = Date()) {
        let stays = notes[key].map { $0.kept || shownByKept().contains(key) } ?? false
        if !stays { strike(carried: [key]) }
        guard var gone = notes[key] else { return }
        if stays {
            guard gone.goneSince == nil else { return }
            gone.goneSince = moment
            notes[key] = gone
        } else {
            notes[key] = nil
            arrival[key] = nil
        }
        changed(shown: !gone.isPartOfTopic, replies: gone.isPartOfTopic)
    }

    /// Takes back what a signed-in reader's reads said they had done to `host`'s posts — boosted,
    /// favourited, bookmarked (#285) — so each row says what a post no such read brought says:
    /// nothing. For a sign-in that has ended, or been replaced by another account's: those words
    /// were that reader's, and left here they would be told to the next one, whose first press
    /// would undo an act they never made. The posts stay; what this device keeps of its own
    /// (`kept`) is untouched. Returns whether any row changed, so a caller writes only then.
    ///
    /// **What that host said happened to the reader goes whole** (#323): a notice was said to one
    /// reader as a mark was, and unlike the posts nothing of it is anybody else's to read. Gone
    /// from here in this call, and counted in what it returns — so its caller writes, and what a
    /// signed-out reader was told is not on disk a moment longer than it is held (#292).
    @discardableResult
    public func forgetReaderMarks(host raw: String) -> Bool {
        forgetReaderMarks { $0 == raw.lowercased() }
    }

    /// `forgetReaderMarks(host:)` for every host not among `hosts` — the ones still signed in to.
    @discardableResult
    public func forgetReaderMarks(keeping hosts: Set<String>) -> Bool {
        forgetReaderMarks { !hosts.contains($0) }
    }

    private func forgetReaderMarks(where gone: (String) -> Bool) -> Bool {
        // From here on a read sent before this moment says nothing of the reader (#291): one
        // still on the wire was asked as whoever has just gone. Marked for every host this
        // names, a row with a mark on it or not — the read on its way may bring the first.
        let moment = ReadMoment.now().place
        for host in Set(sourceList.map(\.host)).union(notes.keys.map(\.host)) where gone(host) {
            swept[host] = moment
        }
        let told = reaches.keys.filter(gone)
        for host in told { reaches[host] = nil }
        // Every host named, held of or not: a read of the gone reader's may still be on its
        // way here with the first of them.
        for host in Set(sourceList.map(\.host)).union(noticeEpochs.keys).union(told) where gone(host) {
            endNoticeEpoch(host)
        }
        if !told.isEmpty { noticesChanged() }
        var shown = false
        var replies = false
        for (key, note) in notes where gone(key.host) {
            // **And what the reader's own reads left owing goes with them** (#293): an item that
            // arrived by a signed read (`arrivedAsReader`) refers to posts that reader could see. Asked
            // for later, unsigned, in the reader's absence, that would be this device requesting
            // on its own what only the sign-in they ended was shown — so the debt is dropped
            // here, at the moment and for the reason their marks are.
            let owesAsReader = note.refsDue && Self.arrivedAsReader(note)
            guard owesAsReader || note.boosted != nil || note.favourited != nil || note.bookmarked != nil else { continue }
            var plain = note.boosted != nil || note.favourited != nil || note.bookmarked != nil ? note.withoutReaderMarks() : note
            if owesAsReader {
                plain.refsDue = false
                stalled.remove(key)
            }
            notes[key] = plain
            shown = shown || !note.isPartOfTopic
            replies = replies || note.isPartOfTopic
        }
        guard shown || replies else { return !told.isEmpty }
        changed(shown: shown, replies: replies)
        return true
    }

    /// Keeps one row, or un-keeps it (#284) — the person's own mark, sent nowhere. Silent where
    /// the row is not held, and where it already is as asked; returns whether anything changed,
    /// so a caller writes it down only then. The row's source need not be here: a kept post
    /// outlives its source's removal, and is un-kept like any other.
    ///
    /// **Un-keeping lets nothing go by itself.** The row is an ordinary one from that moment, and
    /// goes when a limit next acts or the person next lets something go — as it would have.
    @discardableResult
    public func setKept(_ kept: Bool, for key: NoteKey) -> Bool {
        guard var held = notes[key], held.kept != kept else { return false }
        held.kept = kept
        notes[key] = held
        changed(shown: !held.isPartOfTopic, replies: held.isPartOfTopic)
        return true
    }

    /// Stops keeping every row kept, or every one that came through `host` where one is given
    /// (#294) — a source no longer here included, as `setKept` reaches one. One act and one
    /// change, however many rows. Returns how many were kept and are not now.
    ///
    /// **Lets nothing go by itself**, as un-keeping one row lets nothing go: each is an ordinary
    /// row from this moment, and goes when a limit next acts or the person next lets something go.
    @discardableResult
    public func stopKeeping(host raw: String? = nil) -> Int {
        let host = raw?.lowercased()
        let keeping = notes.values.filter { $0.kept && (host == nil || $0.key.host == host) }
        guard !keeping.isEmpty else { return 0 }
        for var note in keeping {
            note.kept = false
            notes[note.key] = note
        }
        changed(shown: keeping.contains { !$0.isPartOfTopic }, replies: keeping.contains { $0.isPartOfTopic })
        return keeping.count
    }

    /// How many kept rows were posted inside `span` and, where `host` is given, came through that
    /// host (#294): what `letGo(span:host:)` would leave for being kept, so the question before
    /// it can say how many stay.
    public func keptCount(span: Range<Date>, host raw: String? = nil) -> Int {
        let host = raw?.lowercased()
        return notes.values.reduce(0) { sum, note in
            sum + (note.kept && span.contains(note.postedAt) && (host == nil || note.key.host == host) ? 1 : 0)
        }
    }

    /// How many kept rows are marked gone from their source (#294): what `letGoneGo` leaves.
    public func keptGoneCount() -> Int {
        notes.values.reduce(0) { $0 + ($1.kept && $1.goneSince != nil ? 1 : 0) }
    }

    /// Marks one row as gone from its source (#179): a read of that one post heard the source say
    /// it no longer has it. The row stays, and `all()` still draws it where it drew it before.
    /// Only while `key`'s host is still a source here, only a row held, and only once — the first
    /// moment it was heard is the one a wait counts from. Returns whether it was marked, so a
    /// caller writes it down only then.
    ///
    /// **Not `forget`.** That is a post the reader took back (#109), which goes; this is a post
    /// somebody else's server let go of, which the reader already read and keeps until they say.
    @discardableResult
    public func markGone(_ key: NoteKey, at moment: Date = Date()) -> Bool {
        guard sourceList.contains(where: { $0.host == key.host }),
              var held = notes[key], held.goneSince == nil
        else { return false }
        held.goneSince = moment
        notes[key] = held
        // Its source says it is gone: the copy a notice carries of it is not left readable.
        strike(carried: [key])
        changed(shown: !held.isPartOfTopic, replies: held.isPartOfTopic)
        return true
    }

    /// How many rows are marked gone from their source (#179) — what a press would let go, so
    /// never one the person keeps (#284).
    public func goneCount() -> Int {
        let shown = shownByKept()
        return notes.values.reduce(0) { $0 + ($1.goneSince == nil || $1.kept || shown.contains($1.key) ? 0 : 1) }
    }

    /// Lets go of every row marked gone from its source at or before `cutoff`, or of every marked
    /// row where `cutoff` is nil — the reader's press (#179). Returns how many went.
    ///
    /// **Marked rows and nothing else.** A row that merely did not arrive again carries no mark,
    /// so no wait and no press here can reach it. **And never a kept one** (#284): it stays,
    /// still marked, for as long as it is kept.
    @discardableResult
    public func letGoneGo(markedBy cutoff: Date? = nil) -> Int {
        let shown = shownByKept()
        let going = notes.values.filter { note in
            guard !note.kept, !shown.contains(note.key), let gone = note.goneSince else { return false }
            return cutoff.map { gone <= $0 } ?? true
        }
        guard !going.isEmpty else { return 0 }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        strike(carried: Set(going.map(\.key)))
        changed(shown: going.contains { !$0.isPartOfTopic }, replies: going.contains { $0.isPartOfTopic })
        return going.count
    }

    /// How many places say their source no longer has what lay there (#204) — what a press would
    /// let go beside the posts `goneCount` counts.
    public func settledCount() -> Int {
        // A post marked gone takes its places with it, and is counted as the post it is — unless
        // it is kept (#284), which stays, so its places are counted as places.
        notes.values.filter { $0.goneSince == nil || $0.kept }.reduce(0) { $0 + $1.gaps.filter { $0.kind == .settled }.count }
    }

    /// Lets go of every place settled at or before `cutoff`, or of every one where `cutoff` is nil
    /// — `letGoneGo`'s wait and press, for the places a read down settled (#204). The mark goes
    /// and the post it sits by stays — so a kept post's places go like any other's (#284): a
    /// place is a mark beside an item, and no item goes here. Returns how many went.
    @discardableResult
    public func letSettledGo(markedBy cutoff: Date? = nil) -> Int {
        var went = 0
        var replies = false
        for (key, note) in notes {
            let going = note.gaps.filter { gap in
                guard gap.kind == .settled else { return false }
                guard let cutoff, let since = gap.since else { return true }
                return since <= cutoff
            }
            guard !going.isEmpty else { continue }
            notes[key]?.gaps.subtract(going)
            went += going.count
            replies = replies || note.isPartOfTopic
        }
        if went > 0 { changed(shown: true, replies: replies) }
        return went
    }

    /// One row, or nothing where this store does not hold it.
    ///
    /// **So that an act can hand back the row as the store has it** rather than as it decoded it
    /// (#106): `refresh` lays the server's answer over what was held, and a caller reading its own
    /// decode back would be holding a note that disagrees with the store about the categories the
    /// row arrived through and about who boosted it.
    public func note(_ key: NoteKey) -> Note? {
        notes[key]
    }

    /// The rows held among `keys`, by key — one hop for a caller that just landed a read and
    /// draws what the store made of it (#284), rather than what the wire said.
    public func notes(_ keys: [NoteKey]) -> [NoteKey: Note] {
        var found: [NoteKey: Note] = [:]
        for key in keys { found[key] = notes[key] }
        return found
    }

    /// Every row held from `host` whose id starts `idPrefix` — **a topic's kept replies included**, which is
    /// the point: a thread read to its end (#177) is read back from here, answers and all, and
    /// `all()` would hand over none of them. In the order they arrived; a caller that means
    /// another order says so.
    public func held(host raw: String, idPrefix: String = "") -> [Note] {
        let host = raw.lowercased()
        let arrival = self.arrival
        return notes.values
            .filter { $0.source.host == host && $0.id.hasPrefix(idPrefix) }
            .sorted { (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0) }
    }

    public func trends() -> [Note] {
        all().filter { $0.categories.contains(.trends) }
    }

    private static func storeOrder(_ a: Note, _ b: Note, _ arrival: [NoteKey: Int]) -> Bool {
        if a.postedAt != b.postedAt { return a.postedAt > b.postedAt }
        if a.id != b.id { return a.id < b.id }
        // Two copies of one post from two sources (#10): the one this store took first comes
        // first, so a merged row drawn from the first of its copies is the copy that arrived
        // first (#114). The host stays behind it only so the order is total.
        let mine = arrival[a.key] ?? 0
        let theirs = arrival[b.key] ?? 0
        if mine != theirs { return mine < theirs }
        return a.source.host < b.source.host
    }
}
