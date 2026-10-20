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
    /// One row per `NoteKey`: two hosts carrying the same Mastodon URI are two rows (#10). Each
    /// row a change reaches is remembered until a save takes it (`takeChanges`), so a save
    /// writes the rows that changed and no others (#357).
    private var notes = HeldNotes()
    /// The file a row the pool lacks is read from, by key (#357) — or nothing for a store that
    /// holds every row there is: a test's, `Staged`'s, one with no file. **That is the whole
    /// pool**, the store as it was before any of this, and nothing here reads anything.
    ///
    /// Two things hold of the pool, and make what it shows what the whole store would:
    /// - **What a timeline read from the file shows from where it was read to up is here**:
    ///   its pages are read one after another and laid in (`take`), what arrives lands here,
    ///   and nothing is let go but by what lets a row go.
    /// - **What a row here holds with it is here, where the file has it** (`Note.heldWith`,
    ///   `Note.topicKey`): every row is laid in with what it holds, and every way in reads what
    ///   it is about to merge with first. So a reference not held here is not held at all.
    private let disk: (any HeldRows)?
    /// Whether rows of this store may be in the file and not here (#357): what it counts of them
    /// is then at least what there is, never all of it (C11), and a take-away copies the file (#360).
    public nonisolated var heldInPart: Bool { disk != nil }
    /// The changes to rows not held here that the file has yet to make (`StoreOp`): made, and not
    /// yet taken by a save, or handed back by one that failed.
    private var opsOwed: [StoreOp] = []
    /// Every such change made since the file was last laid in whole (`replace`): what a read
    /// back's undo owes again (`oweEverything`). **A row read from the file is read as every one
    /// of them above `opsSettled` leaves it** (`unlanded`): a read begun before a change landed
    /// may be handed in after, and a change made again changes nothing.
    private var opsRun: [StoreOp] = []
    private var opsMade = 0
    /// The last change made before the file was last laid in whole: one numbered no higher,
    /// handed back by a save taken before, is of rows no longer there and is not owed again.
    private var opsFloor = 0
    /// The last change every read of the file now begins after the landing of, and every one
    /// before it too (#359): a row read in is the file's word on it, and is no longer read as it
    /// leaves it. **Moved only when no page is out** (`paged`), so no read begun before a
    /// landing is handed in after the move — otherwise a row marked again since, and read back,
    /// would lose its new marks to a change made before them.
    private var opsSettled = 0
    /// The changes taken by a save that has not landed (`takeChanges`): not settled until it does.
    private var opsInFlight: Set<Int> = []
    /// The rows taken by a save that has not landed (#359): what a read of the file before it
    /// lands would bring back as it was. Cleared as it lands (`wrote`) or is handed back.
    private var inFlight: Set<NoteKey> = []
    /// How many pages read off the actor are out (`paged`): none, and the moment is quiet.
    private var pagesOut = 0
    /// The file being put back to an older store (`restoring`), until `oweEverything` says it
    /// is: nothing settles meanwhile, as the file no longer holds what landed.
    private var restoringFile = false
    /// How many rows the pool holds before it lets the least lately seen go (#359, C7, C21): a
    /// soft cap — what must stay, stays — let down to nine tenths of it, so one page landing
    /// does not let rows go each time.
    public static let poolCap = 5_000
    private let cap: Int
    /// The keys the screens draw, as handed in last (`hold`), and the `drawn` they were drawn
    /// from — **nothing until the screens first say**, and no row leaves the pool before: a pool
    /// with no word on what is drawn holds every row it read, as round 1's did.
    private var pins: Set<NoteKey>?
    private var pinsDrawnAt = 0
    /// What each screen said it draws (`hold(_:drawnAt:by:)`) — every window of the app over
    /// this one store says its own — and `pins` is all of it, as of the oldest `drawn` any was
    /// made from. A screen gone says so (`letGoOfPins(by:)`), and what it drew goes as any row.
    private var pinsBy: [UUID: (pins: Set<NoteKey>, at: Int)] = [:]
    /// The screens that said they are gone (`letGoOfPins(by:)`): what one of them says after —
    /// a saying already on its way as its window closed — is not heard, or its drawing, old,
    /// would keep every row read since.
    private var screensGone: Set<UUID> = []
    /// The screen `hold(_:drawnAt:)` says for: one, where nothing names another.
    private static let oneScreen = UUID()
    /// The newest ids each timeline listed a row under, of the rows let go of the pool, newest
    /// first, and each one's row (`newestListedID`): one read again or let go answers for
    /// itself, and the next stands in. The newest `listedLeftKept` of each.
    private var listedLeft: [String: [Category: [(id: String, key: NoteKey)]]] = [:]
    private static let listedLeftKept = 64
    /// Whether the pool was told once it could not come under its cap: said once a run.
    private var overCapSaid = false
    /// Counts what may let a row leave that could not before — a row changed, laid in, taken
    /// or landed, what is drawn said again — and the count at the last pass that let none go:
    /// at the same count, the pass is not made again.
    private var poolMoved = 0
    private var leftNoneAt: Int?
    /// How many passes were made, whether or not they let a row go: for the tests.
    private(set) var evictionPasses = 0
    /// How long each of the last passes took, on this actor: for the bench.
    private(set) var passesTook: [Duration] = []
    private static let passesKept = 1_000
    /// Every key the pool answers for (#357): each row laid in, each key asked of the file.
    /// **One among these that is not in the pool is not held**, whatever the file still says —
    /// a row let go is not read back before the save that deletes it lands.
    private var looked: Set<NoteKey> = []
    /// The source's ids each host's rows were already looked for by (`HeldRows.rows(host:
    /// statusIDs:)`): one not found then is held, if ever, by a row that landed here since.
    private var namesAsked: [String: Set<String>] = [:]
    /// The "newer posts remain" marks a read on said again this run, by host (`land(_:of:
    /// ifSourceHere:)`): a row of the file laid in later says them no more, as every row held
    /// then stopped saying them.
    private var remainSaid: [String: Set<TimelineGap>] = [:]
    /// The first arrival of a row new to a store over a file: after every `rowid` there is, so a
    /// copy read from the file is the earlier of two (#114), as it arrived first.
    private static let arrivingAfterTheFile = 1 << 62
    /// The sources as the last write that landed left them on disk, with what each said of
    /// itself — nil where that is not known, and the next save writes every source. What a save
    /// finds the sources changed by, without every way of changing one having to say so.
    private var sourcesWritten: (sources: [Source], said: [String: SourceProfile])?
    /// Hosts removed whose removal a write did not land: deleted by the next.
    private var hostsOwed: Set<String> = []
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
    /// It survives a relaunch as an order rather than as a number: a save adds the rows new to
    /// the file oldest first (`takeChanges`) and keeps each row it writes again where it was, so
    /// the file holds them in the order they arrived; and `init(sources:notes:)` counts the rows
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

    public init() {
        disk = nil
        cap = Self.poolCap
    }

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
        notes.drawing = drawn
        poolMoved += 1
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
    ///
    /// **`readFromDisk` says the rows are what the file holds** — a launch's — so none is owed a
    /// write until it changes. Left out, every row and source here is owed one: a store made of
    /// rows the file may not hold, which the first save writes whole. `skipped` are rows the
    /// file holds that are no item (`Opened.skipped`): the first save deletes them.
    public init(
        sources: [Source], notes incoming: [Note], said: [SourceProfile] = [], notices: [NoticeReach] = [],
        unsent: [Unsent] = [], readFromDisk: Bool = false, skipped: [NoteKey] = []
    ) {
        self.init(
            sources: sources, notes: incoming, said: said, notices: notices, unsent: unsent,
            readFromDisk: readFromDisk, skipped: skipped, disk: nil, cap: Self.poolCap
        )
    }

    /// A store over `rows`, the file's (#357): **no row read here** — the sources, what each
    /// said, the notices and the texts, which are few — and each read by key once it is wanted,
    /// or laid in from a page (`take`). Nothing is owed a write until it changes.
    public init(
        sources: [Source], said: [SourceProfile] = [], notices: [NoticeReach] = [], unsent: [Unsent] = [],
        rows: any HeldRows, cap: Int = ItemStore.poolCap
    ) {
        self.init(
            sources: sources, notes: [], said: said, notices: notices, unsent: unsent, readFromDisk: true,
            skipped: [], disk: rows, cap: cap
        )
    }

    private init(
        sources: [Source], notes incoming: [Note], said: [SourceProfile], notices: [NoticeReach],
        unsent: [Unsent], readFromDisk: Bool, skipped: [NoteKey], disk: (any HeldRows)?, cap: Int
    ) {
        self.disk = disk
        self.cap = cap
        if disk != nil { arrivals = Self.arrivingAfterTheFile }
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
        notes = HeldNotes(Dictionary(incoming.map { note in
            // A row holds nothing of another post (`Note.brought`): what a snapshot's rows
            // refer to is among its rows, or is not held.
            var row = note
            row.brought = []
            return (row.key, row)
        }, uniquingKeysWith: { _, new in new }), owed: !readFromDisk)
        if disk != nil { notes.track() }
        var unheld: [NoteKey] = []
        for key in skipped where notes[key] == nil { unheld.append(key) }
        notes.owe(unheld)
        if readFromDisk { sourcesWritten = (sourceList, saidByHost) }
        // The order the rows are handed over is the order they arrived in: the run that wrote
        // this snapshot wrote them oldest first. A row named twice keeps the first mention's
        // place, the way `ingest` keeps a row's place when it is met again.
        for note in incoming where arrival[note.key] == nil {
            arrival[note.key] = arrivals
            arrivals += 1
        }
        // What the file says is owed is settled against what the file holds (#293): a post
        // waited for that is here is named and no longer owed, and a row that could never have
        // owed — a reblog, one with nothing to ask for — does not go on saying it does. A row
        // settled here, or given its board below, is owed a write as any change is.
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

    private static func throughItsBoard(_ note: Note, in notes: HeldNotes, or landing: [NoteKey: Note] = [:]) -> Note {
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
        notes = HeldNotes(Dictionary(
            incoming.filter { $0.kept || withinRetention($0) || shown.contains($0.key) }.map { ($0.key, $0) },
            uniquingKeysWith: { _, new in new }
        ))
        notes.drawing = drawn
        if disk != nil { notes.track() }
        // Newer than any drawing made before: none leaves before the screens draw them.
        notes.stampAll()
        // The file holds the package's rows as they came (`StorePackager`): what differs here —
        // a row past the window, one that owed a load — is owed a write; so is every source.
        let owedLoad = Set(arriving.lazy.filter(\.refsDue).map(\.key))
        let differing = incoming.map(\.key).filter { notes[$0] == nil || owedLoad.contains($0) }
        notes.owe(differing)
        sourcesWritten = nil
        hostsOwed = []
        arrival = [:]
        arrivals = disk == nil ? 0 : Self.arrivingAfterTheFile
        for note in incoming where notes[note.key] != nil && arrival[note.key] == nil {
            arrival[note.key] = arrivals
            arrivals += 1
        }
        // What the file holds once the read back is written is what came: the pool answers
        // for every row of it, and for nothing it knew of before.
        if disk != nil {
            looked = Set(incoming.map(\.key))
            namesAsked = [:]
            remainSaid = [:]
            undecodable = []
            keptSpared = []
            keptRead = true
            opsOwed = []
            opsRun = []
            opsFloor = opsMade
            opsSettled = opsMade
            listedLeft = [:]
            goneLanded = []
            putBackMay = false
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

    /// Everything here replaced by what a read back copied into the file this store is over
    /// (#360, K-10) — `sources` and what each `said` — **and no row laid in**: the file *is* the
    /// package's store now, and its rows are read as they are wanted, by the pages and by key, as
    /// at a launch. The pool and every key it answered for go, and with them every coverage, so
    /// pages read afresh; every change the run made of the file before is the older file's and
    /// is owed no more. What the whole store's `replace` lets go past the months limit is the
    /// limit's steps' after this (`letGoBeyond(_:step:after:)`), and meanwhile not drawn
    /// (`pastTheLimit`); what owed a load was settled in the file before it was copied in.
    ///
    /// **Every notice held goes**, as `replace(sources:notes:said:)` lets them go, and every
    /// source is written by the next save, said as the package said it. The texts waiting to be
    /// sent stay, the file's own. **Only over a file**: a store held whole is given its rows.
    public func replace(sources: [Source], said: [SourceProfile]) {
        guard disk != nil else { return replace(sources: sources, notes: [], said: said) }
        filesCopiedIn += 1
        sourceList = []
        for source in sources where !sourceList.contains(where: { $0.host == source.host }) {
            sourceList.append(source)
        }
        let hosts = Set(sourceList.map(\.host))
        saidByHost = [:]
        for profile in said where Self.isWord(profile) && hosts.contains(profile.host) {
            saidByHost[profile.host] = profile
        }
        notes = HeldNotes([:], owed: false)
        notes.drawing = drawn
        notes.track()
        sourcesWritten = nil
        hostsOwed = []
        arrival = [:]
        arrivals = Self.arrivingAfterTheFile
        looked = []
        namesAsked = [:]
        remainSaid = [:]
        undecodable = []
        keptSpared = []
        keptRead = false
        readPastLimit = [:]
        opsOwed = []
        opsRun = []
        opsFloor = opsMade
        opsSettled = opsMade
        listedLeft = [:]
        goneLanded = []
        putBackMay = false
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

    /// The rows of the pool past the months limit that the whole store would have let go
    /// (`letGoBeyond`), **over a file alone** (#357, C10): handed over by neither `all()` nor
    /// `replies()` — as no page shows them (`PageQuery.keepFrom`). A kept row stays, and so
    /// does what a kept or in-window row quotes, never a reblog. Nothing for a whole pool, which
    /// lets them go, or with no limit.
    ///
    /// **Still asked once the limit is kept in the file a step at a time** (#360): between two
    /// steps a row past it is held still, a row ages past it while the run goes on, and a read
    /// of the file — a thread, a person — can bring in an old one. Each is let go by the next act
    /// of the limit, and none is drawn before.
    private func pastTheLimit() -> Set<NoteKey> {
        guard disk != nil, let retention else { return [] }
        let within = { (note: Note) in note.kept || note.postedAt >= retention }
        var past: Set<NoteKey> = []
        var quoted: Set<NoteKey> = []
        for note in notes.values {
            if within(note) { quoted.formUnion(note.heldWith) } else { past.insert(note.key) }
        }
        guard !past.isEmpty else { return [] }
        return past.filter { !quoted.contains($0) || notes[$0]?.isReblog == true }
    }

    /// The oldest a post may be posted and still be shown, or nothing for no months limit
    /// (`letGoBeyond`): what every page of the file is cut by (`PageQuery.keepFrom`).
    public var keepFrom: Date? { retention }

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
    private func admit(_ landing: [Note], exempt: Bool, owing: Bool = true) {
        guard !landing.isEmpty else { return }
        // Every row this landing merges with, or asks about, read in first (#357): a copy of a
        // row the file holds and the pool does not is that row, and never a row new here. **A
        // copy of a row the file could not be read for is not taken** — nor what it brought.
        let unread = pool((landing + landing.flatMap(\.brought)).flatMap(Self.reach))
        let taken = unread.isEmpty ? landing : landing.compactMap { note -> Note? in
            guard !unread.contains(note.key) else { return nil }
            var taken = note
            taken.brought = note.brought.filter { !unread.contains($0.key) }
            return taken
        }
        admitRead(taken, exempt: exempt, owing: owing)
    }

    /// `admit`, of a landing whose rows the pool answers for, every one.
    private func admitRead(_ incoming: [Note], exempt: Bool, owing: Bool) {
        guard !incoming.isEmpty else { return }
        // A copy of a row the person keeps is taken in whatever its age (#284): the row is here
        // past the window, and what its source says of it now is still news about it.
        // Nothing but a convention carries `Note.asked` from where a status is read to here
        // (#291), so a debug build checks it: a copy that says what the reader did says when it
        // was sent. A release build takes such a copy as `outrun` says — for the older.
        assert(
            incoming.allSatisfy { note in
                !note.source.kind.saysReaderMarks || note.asked.place != nil
                    || !note.saysReader
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
                if note.isLater(than: existing) {
                    merged = merged.revised(by: note, was: existing)
                    // The poll as the change says it, and the reader's vote in it as the marks
                    // are: not this copy's word where it was sent before their own vote landed.
                    if older { merged.poll = Poll.later(note.poll, over: existing.poll, reader: false) }
                }
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
            // Its replies the file holds and the pool does not are laid in, given the board.
            for topic in boarded { poolRows(host: topic.host, idPrefix: topic.id + ":post:") }
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
        // What the file could not be read for is not held as far as this knows: not laid over.
        let unread = pool(incoming.filter { $0.source.host == host }.flatMap(Self.reach))
        var moved = false
        var shown = false
        var replies = false
        var held: [Note] = []
        for note in incoming where note.source.host == host && !unread.contains(note.key) {
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
        pool(openings.keys)
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
        let held = notes.values
            .filter { $0.source.host == host && $0.goneSince == nil }
            .compactMap { $0.listed[category] }
            .max { StatusID.later($1, than: $0) }
        // Of the rows let go of the pool, the newest not answered for again: read back, one
        // says for itself; let go of the file, it says nothing, as in the whole store.
        if let left = listedLeft[host]?[category], let first = left.firstIndex(where: { !looked.contains($0.key) }) {
            if first > 0 { listedLeft[host]?[category] = Array(left[first...]) }
        } else {
            listedLeft[host]?[category] = nil
        }
        guard let left = listedLeft[host]?[category]?.first else { return held }
        guard let held else { return left.id }
        return StatusID.later(left.id, than: held) ? left.id : held
    }

    /// The posts held of `category` from `host` that a timeline brought (#201): what a read with
    /// no anchor looks for in the newest stretch, to tell whether it reached what was held.
    public func held(host raw: String, category: Category) -> Set<NoteKey> {
        let host = raw.lowercased()
        return Set(notes.values.filter {
            $0.source.host == host && $0.categories.contains(category)
        }.map(\.key))
    }

    /// Every post of `host` held through `category` of the reader's marks (#317), by the span of
    /// marks it is listed under there (`MarkSpan`, as `Note.listed` writes it) — **the file's rows
    /// too**, read in: a read of marks decides of every post held through it, and a post only the
    /// file holds is one of them. A post listed under nothing is named by the end, which only a
    /// read that reaches the end decides of.
    public func marked(host raw: String, category: Category) -> [NoteKey: String] {
        let host = raw.lowercased()
        poolMembers(host: host, category: category)
        var held: [NoteKey: String] = [:]
        for (key, note) in notes where key.host == host && note.categories.contains(category) {
            held[key] = note.listed[category] ?? MastodonMarks.end
        }
        return held
    }

    /// The lowest mark a post of `host` is held above through `category` of the reader's marks:
    /// where reading on asks below at first (#317). Nothing where none is held.
    public func lowestMark(host raw: String, category: Category) -> String? {
        MarkSpan.lowestFloor(of: marked(host: raw, category: category).values)
    }

    /// The mark a place where marks of `category` may be missing below `key` reads down from
    /// (#317), or nothing where `key` says no such place.
    public func markHole(_ key: NoteKey, in category: Category) -> String? {
        pool([key])
        let mark = TimelineGap(.mayBeMissing, in: category)
        return notes[key]?.gaps.first { $0 == mark }?.from
    }

    /// A read of the reader's marks is begun (#317): its place among the reads, which its landing
    /// is told by (`MarksRead.begun`) — compared only with reads of its own host and category.
    public func beginMarks() -> Int {
        marksBegun += 1
        return marksBegun
    }

    /// One category of the reader's marks read (#317), landed in one step while `host` is still a
    /// source here: every post it met taken in through it, and **every post held through it whose
    /// mark lies inside what the read covered, and that it did not bring, leaving it**
    /// (`MarkCover.contains`) — the category, its span and any place said of it come off, and
    /// nothing else. The post stays where anything else holds it, a kept one included, and goes
    /// only as any row goes.
    ///
    /// **Where its marks may be missing is kept here too**: a read that leaves such a place says it
    /// on the post it names, one that read down from one moves it down or, meeting what is held or
    /// the end, takes it off, and one that went through every mark held takes every one off.
    ///
    /// **A read outrun by a later one of the same category decides nothing** — it was sent before
    /// that one landed, and its silence about a post marked since is no word that it is not — and
    /// **brings back no post a later read found no longer marked**. What else it brought lands.
    ///
    /// **While the file may hold another store** (`passingThrough`, a read back on its way), what
    /// it holds is not laid in, so what the read did not bring cannot be told from what is not
    /// held: nothing is decided then, and nothing said of a place. The posts land as `ingest`
    /// takes them, and the next read decides.
    ///
    /// `membersPooled` is a caller that asked `marked` for this category before its read, which
    /// laid the file's rows of it into the pool: they are not asked of the file again.
    public func land(_ read: MarksRead, of category: Category, ifSourceHere raw: String, membersPooled: Bool = false) {
        let host = raw.lowercased()
        guard category.isMarks, sourceList.contains(where: { $0.host == host }) else { return }
        let reads = "\(host) \(category)"
        let outrun = read.begun < (marksLanded[reads] ?? 0)
        let gone = marksGone[reads] ?? [:]
        ingest(read.notes.filter { note in
            !(outrun && note.categories.contains(category) && (gone[note.key] ?? 0) > read.begun)
        })
        guard !outrun, !passingThrough else { return }
        marksLanded[reads] = read.begun
        if !membersPooled { poolMembers(host: host, category: category) }
        let mark = TimelineGap(.mayBeMissing, in: category)
        let met = Set(read.notes.filter { $0.categories.contains(category) }.map(\.key))
        var moved = false
        var shown = false
        var replies = false
        func put(_ key: NoteKey, _ note: Note) {
            notes[key] = note
            moved = true
            shown = shown || !note.isPartOfTopic
            replies = replies || note.isPartOfTopic
        }
        for (key, note) in notes where key.host == host && note.categories.contains(category) {
            var changed = note
            // A place moved down is the same place to `==`, which does not read its mark — and
            // the row would not take it (`HeldNotes`): it is taken off first, then put back (#369).
            var moves = false
            if !met.contains(key), read.covered.contains(MarkSpan(listed: note.listed[category])) {
                changed.categories.remove(category)
                changed.listed[category] = nil
                changed.gaps = note.gaps.filter { $0.category != category }
                marksGone[reads, default: [:]][key] = read.begun
            } else if let hole = note.gaps.first(where: { $0 == mark }) {
                if read.whole || (read.fills == hole.from && (read.connected || read.reachedEnd)) {
                    changed.gaps.remove(mark)
                } else if read.fills == hole.from {
                    changed.gaps.update(with: TimelineGap(.mayBeMissing, in: category, from: read.covered.low))
                    moves = true
                }
            }
            if moves {
                var without = changed
                without.gaps.remove(mark)
                notes[key] = without
            }
            if moves || changed != note { put(key, changed) }
        }
        // On the post it names, or — where the keep window refused that one — the lowest of the
        // read's that is held.
        if let hole = read.hole,
           let key = ([hole.post] + read.notes.reversed().map(\.key)).first(where: { notes[$0]?.categories.contains(category) == true }),
           var held = notes[key] {
            // Taken off first, then put back, for the reason above (#369).
            held.gaps.remove(mark)
            notes[key] = held
            held.gaps.update(with: TimelineGap(.mayBeMissing, in: category, from: hole.from))
            put(key, held)
        }
        if moved { changed(shown: shown, replies: replies) }
    }

    /// The file's rows of `host` held through `category`, laid into the pool — nothing where there
    /// is no file, and what the file would not answer is left as it is.
    private func poolMembers(host: String, category: Category) {
        guard let disk else { return }
        do {
            pool(try disk.keys(host: host, in: category))
        } catch {
            Self.unread(error)
        }
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
        pool([read.newerRemainAbove, read.missingBelow].compactMap { $0 })
        let remain = TimelineGap(.newerRemain, in: category)
        // Said again, it is said again of the rows the file holds too, once they are read.
        if disk != nil { remainSaid[host, default: []].insert(remain) }
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
        pool([key])
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
        pool([key])
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
    public func remove(host raw: String, keepingPosts: Bool = false) async -> Bool {
        await untilNoPutBack()
        let host = raw.lowercased()
        sourceList.removeAll { $0.host == host }
        saidByHost[host] = nil
        // Deleted by the next save whether or not this store knows the file to hold it.
        hostsOwed.insert(host)
        let told = letNoticesGo(host: host)
        listedLeft[host] = nil
        sourcesWatcher?(sourceList.map(\.host))
        // Over a file, its rows of the host the pool does not hold go by key with the rest — or,
        // where the file would not say which they are, no post goes, as where they stay.
        guard !keepingPosts, poolKept(), let unpooled = unpooled(.host(host)) else {
            changed(shown: false, replies: false)
            return told
        }
        let shown = shownByKept()
        let going = notes.values.filter { $0.key.host == host && !$0.kept && !shown.contains($0.key) }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        drop(unpooled.filter { !shown.contains($0) })
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
    ///
    /// **Over a file, every step of it at once** (`letGoBeyond(months:from:calendar:step:after:)`):
    /// what the whole store would let go, read a step at a time and let go in one call — for a
    /// caller with nothing to save between. The months limit itself saves after each step.
    public func letGoBeyond(months: Int?, from now: Date = Date(), calendar: Calendar = .current) -> WentByLimit {
        let cutoff = limit(months: months, from: now, calendar: calendar)
        guard disk != nil else { return letGoBeyondWhole(cutoff) }
        guard let cutoff else { return .none }
        var went = WentByLimit.none
        var after: PageCursor?
        repeat {
            let step = letGoBeyond(cutoff, step: Self.beyondStep, after: after)
            went = went.adding(step.went)
            after = step.next
        } while after != nil
        return went
    }

    /// The months limit set as of `now`, and nothing let go but the notices older than it: what
    /// every page is cut by from here (`keepFrom`), before a step of it has run (#360). Returns
    /// the cutoff, or nothing for no limit.
    @discardableResult
    public func setLimit(months: Int?, from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        limit(months: months, from: now, calendar: calendar)
    }

    /// How many rows of the file one step of the months limit reads at most (#360, C32).
    public static let beyondStep = 2_000

    /// **One step of the months limit** (#360, C32), under the limit `setLimit` set at `cutoff`
    /// — **and nothing where the limit is no longer that**: a run of steps begun under a limit the
    /// person has since moved lets nothing go under the old one. Of the rows past it, the
    /// next `step` of the file's from past `after` on — the oldest first — let go where the whole
    /// store would let them go (`letGoBeyondWhole`), with every row the pool holds past it. Says
    /// what went, and where the next step starts, or nothing once the file has no more past the
    /// limit — or would not be read, and then nothing more goes this time.
    ///
    /// **Spared as the whole store spares**: a kept row; a row posted inside the limit; a post (not
    /// a reblog) that a kept or in-limit row of the file or the pool refers to — a quote, a reblog's
    /// post, a topic answered; what a kept reblog shows (`shownByKept`). A row past the limit
    /// spares nothing. **What the screens draw is no reason to stay** (pins), nor a change on its
    /// way to the file: a pooled row goes from the pool, the file's own by key (`drop`), and the
    /// next save deletes both. A row spared is passed over, and is not asked about again by the
    /// steps after: the cursor is past it. **A row of the file read in while the steps run** — a
    /// thread, a person — is judged by the next step whether or not it is still in the pool
    /// (`readPastLimit`): one the cursor passed while it was spared, and that left the pool
    /// since, would otherwise stay in the file.
    ///
    /// A store with no file lets go of everything at once, and says no next step.
    public func letGoBeyond(_ cutoff: Date, step: Int, after: PageCursor?) -> (went: WentByLimit, next: PageCursor?) {
        guard retention == cutoff else { return (.none, nil) }
        guard let disk else { return (letGoBeyondWhole(cutoff), nil) }
        // **None while the file is being put back, or may be**, as no hop of the room limit
        // is (`letGoOldest`): the run of steps ends where it stands, and the next act of the
        // limit begins it again.
        guard !restoringFile, !putBackMay else {
            stepping = false
            return (.none, nil)
        }
        if after == nil {
            stepping = true
            readPastLimit = [:]
        }
        guard step > 0, poolKept() else {
            stepping = false
            return (.none, nil)
        }
        let read: (rows: [PastLimit], next: PageCursor?)
        do {
            read = try disk.beyond(cutoff, limit: step, after: after)
        } catch {
            Self.unread(error)
            stepping = false
            return (.none, nil)
        }
        let shown = shownByKept()
        // What the pool's rows that stay refer to, and the pool's own rows past the limit: every
        // one each step, so one read in or aged past it since the last is not missed.
        var referred: Set<NoteKey> = []
        var past: [(key: NoteKey, reblogs: Bool)] = []
        for note in notes.values {
            if note.kept || note.postedAt >= cutoff {
                referred.formUnion(note.heldWith)
            } else {
                past.append((note.key, note.isReblog))
            }
        }
        let pooled = past.count
        // The file's rows the pool does not answer for: one it answers for is judged as it holds
        // it, among its own, or is let go already.
        // And those read in since the last step that left the pool again: the file's alone now.
        let readIn = readPastLimit
        readPastLimit = [:]
        var fromFile = Set<NoteKey>()
        for (key, reblogs) in readIn where !looked.contains(key) && notes[key] == nil && fromFile.insert(key).inserted {
            past.append((key, reblogs))
        }
        for row in read.rows where !looked.contains(row.key) && notes[row.key] == nil && fromFile.insert(row.key).inserted {
            past.append((row.key, row.reblogs))
        }
        let asked = past.filter { !$0.reblogs && !shown.contains($0.key) && !referred.contains($0.key) }.map(\.key)
        if !asked.isEmpty {
            do {
                for referrer in try disk.referring(to: asked, stayingFrom: cutoff) where !looked.contains(referrer.key) {
                    referred.insert(referrer.target)
                }
            } catch {
                Self.unread(error)
                stepping = false
                return (.none, nil)
            }
        }
        var gone: Set<String> = []
        var unpooled: [NoteKey] = []
        var shownMoved = false
        var repliesMoved = false
        var count = 0
        for (index, row) in past.enumerated()
        where !(shown.contains(row.key) || (!row.reblogs && referred.contains(row.key))) {
            if index < pooled {
                let part = notes[row.key]?.isPartOfTopic ?? false
                shownMoved = shownMoved || !part
                repliesMoved = repliesMoved || part
                notes[row.key] = nil
            } else {
                // Not read, so not known to be a topic's reply or an item: both are told.
                shownMoved = true
                repliesMoved = true
                unpooled.append(row.key)
            }
            arrival[row.key] = nil
            gone.insert(row.key.host)
            count += 1
        }
        drop(unpooled)
        if count > 0 { changed(shown: shownMoved, replies: repliesMoved) }
        if read.next == nil { stepping = false }
        return (WentByLimit(posts: count, sources: gone.sorted()), read.next)
    }

    /// Whether a run of the months limit's steps is under way (`letGoBeyond(_:step:after:)`):
    /// begun by its first step, ended by its last.
    private var stepping = false
    /// The rows of the file laid in while the steps run that are past the limit and not kept, by
    /// key, and whether each is a reblog: judged by the next step, in the pool or not.
    private var readPastLimit: [NoteKey: Bool] = [:]

    /// The months limit set as of `now` (`KeepPolicy.cutoff`), and every notice older than it let
    /// go: the cutoff, or nothing for no limit.
    private func limit(months: Int?, from now: Date, calendar: Calendar) -> Date? {
        retention = KeepPolicy.cutoff(keepingMonths: months, from: now, calendar: calendar)
        guard let retention else { return nil }
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
        return retention
    }

    /// The months limit over a store held whole: every row past `cutoff` that nothing spares,
    /// let go at once — the rule each step over a file keeps.
    private func letGoBeyondWhole(_ cutoff: Date?) -> WentByLimit {
        guard let retention = cutoff else { return .none }
        let before = notes.count
        // A quoted post a kept post quotes stays, as `ingest` keeps it (#214): the window's reach
        // has passed it, the quote's has not.
        let quoted = Set(notes.values.filter { $0.kept || $0.postedAt >= retention }.flatMap(\.heldWith))
            .filter { notes[$0]?.isReblog != true }
        var going: [NoteKey] = []
        var gone: Set<String> = []
        var replies = false
        for (key, note) in notes where !(note.kept || note.postedAt >= retention || quoted.contains(key)) {
            going.append(key)
            gone.insert(key.host)
            replies = replies || note.isPartOfTopic
        }
        for key in going { notes[key] = nil }
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
    ///
    /// **Over a file, the oldest of the file** (#357, C9), the rows the pool holds as it holds
    /// them: what goes is what would go were every row read. **Read and let go a hop at a time**
    /// (#360, C33), each of at most `roomHop` of the file's rows, and the actor free between two:
    /// a page or a landing waits for one hop, not for the round. **And none while the file is
    /// being put back, or may be** (`restoring`, `mayBePutBack`): a hop begun then would let go
    /// against a file a read back is writing; the round ends where it stands.
    public func letGoOldest(count: Int) async -> WentByLimit {
        guard count > 0, disk != nil || !notes.isEmpty else { return .none }
        guard disk != nil else {
            return letGo(mayGoForRoom().prefix(count).map { Going(key: $0.key, partOfTopic: $0.isPartOfTopic) })
        }
        var went = WentByLimit.none
        var from: RoomHop?
        while went.posts < count, !restoringFile, !putBackMay {
            let started = ContinuousClock.now
            guard let hop = roomHop(count - went.posts, from: from) else { break }
            went = went.adding(letGo(hop.chosen))
            tookHop(ContinuousClock.now - started)
            guard let next = hop.next else { break }
            from = next
            await Task.yield()
            await betweenHops?()
        }
        return went
    }

    /// What a test does between two hops of a round, the actor free (`letGoOldest`).
    private var betweenHops: (@Sendable () async -> Void)?

    /// Sets what a test does between two hops of a round.
    func doBetweenHops(_ act: (@Sendable () async -> Void)?) {
        betweenHops = act
    }

    /// `going`, chosen by the room limit, let go: from the pool where it holds them, by key where
    /// only the file does.
    private func letGo(_ going: [Going]) -> WentByLimit {
        guard !going.isEmpty else { return .none }
        for row in going {
            if notes[row.key] == nil {
                drop([row.key])
            } else {
                notes[row.key] = nil
            }
            self.arrival[row.key] = nil
        }
        strike(carried: Set(going.map(\.key)))
        // One only the file held is not known to be a reply or an item: both are told.
        changed(shown: going.contains { $0.partOfTopic != true }, replies: going.contains { $0.partOfTopic != false })
        return WentByLimit(posts: going.count, sources: Set(going.map(\.key.host)).sorted())
    }

    /// Whether `letGoOldest` could let anything go right now (#284): a post is held that is
    /// neither kept nor quoted by a held post. What the room check asks before it spends the
    /// picture copies — asked of the store each time, so a post un-kept, from this window or
    /// another, is seen by the very next check. **Over a file, a hop at a time** as the round is
    /// read, the actor free between two.
    public func holdsWhatRoomMayLetGo() async -> Bool {
        guard disk != nil else { return !mayGoForRoom().isEmpty }
        var from: RoomHop?
        while true {
            let started = ContinuousClock.now
            guard let hop = roomHop(1, from: from) else { return false }
            tookHop(ContinuousClock.now - started)
            if !hop.chosen.isEmpty { return true }
            guard let next = hop.next else { return false }
            from = next
            await Task.yield()
        }
    }

    /// How many of the file's rows one hop of the room limit reads at most (#360, C33).
    public static let roomHop = 2_000

    /// Where a round of the room limit over a file has read to: the file's cursor, and the place
    /// of the last row it read — the pool's rows up to there were judged with them.
    private struct RoomHop {
        let cursor: PageCursor
        let last: (postedAt: Date, arrival: Int64)
    }

    /// How long each of the last hops of the room limit held this actor: for the bench.
    private(set) var hopsTook: [Duration] = []

    private func tookHop(_ took: Duration) {
        hopsTook.append(took)
        if hopsTook.count > Self.passesKept { hopsTook.removeFirst(hopsTook.count - Self.passesKept) }
    }

    /// How many rows the file holds, or nothing for a store with no file behind it — what the
    /// room limit weighs a post by (#357): the pool is not all there is.
    public func rowsHeld() -> Int? {
        guard let disk else { return nil }
        do {
            return try disk.rowCount()
        } catch {
            Self.unread(error)
            return nil
        }
    }

    /// How many rows the file holds of each host, or nothing for a store with no file behind it,
    /// or one that would not be read (#359, C23): what Usage counts once the pool holds only the
    /// rows lately seen. **Read off this actor**, beside it, so a count over a large file holds
    /// back no page and no landing. What a save has yet to write is not among them.
    public nonisolated func rowsByHost() async -> [String: HostRows]? {
        guard let disk else { return nil }
        return await Task.detached(priority: .utility) {
            do {
                return try disk.rowCounts()
            } catch {
                Self.unread(error)
                return nil
            }
        }.value
    }

    /// The revision every change to a row is written at, or nothing while one is not (#360,
    /// C31): a change owed a save or on its way in one, a source's rows owed a delete, or a
    /// file being put back. What the file counts is then what the store holds, as of that
    /// revision, and no row of the pool is missing from it.
    public func rowsWritten() -> Int? {
        guard notes.touched.isEmpty, notes.dropped.isEmpty, inFlight.isEmpty, opsOwed.isEmpty, opsInFlight.isEmpty,
              hostsOwed.isEmpty, !restoringFile else { return nil }
        return revision
    }

    /// How many rows the file holds of each week and of each month of `calendar`, the `most`
    /// newest of each, or nothing for a store with no file behind it, or one that would not be
    /// read (#360, C31): Usage's breakdown, as `rowsByHost` is its count by source. **Read off
    /// this actor**, beside it, as `rowsByHost` is. What a save has yet to write is not among
    /// them: `rowsWritten` says whether anything is.
    public nonisolated func rowsByPeriod(calendar: Calendar = .current, most: Int = .max) async -> [HeldPeriod: [Holdings.Bucket]]? {
        guard let disk else { return nil }
        return await Task.detached(priority: .utility) {
            do {
                var counted: [HeldPeriod: [Holdings.Bucket]] = [:]
                for period in HeldPeriod.allCases {
                    counted[period] = try disk.rowsByPeriod(period, calendar: calendar, most: most)
                }
                return counted
            } catch {
                Self.unread(error)
                return nil
            }
        }.value
    }

    /// The source's own id of the oldest post of `host` the file holds through `category`, or
    /// nothing where there is no file or it would not be read (`HeldRows.oldestStatusID`).
    /// **Read off this actor**, as `rowsByHost` is: what a timeline's next stretch is asked from.
    public nonisolated func oldestStatusID(host: String, category: Category) async -> String? {
        guard let disk else { return nil }
        return await Task.detached(priority: .utility) {
            do {
                return try disk.oldestStatusID(host: host.lowercased(), category: category)
            } catch {
                Self.unread(error)
                return nil
            }
        }.value
    }

    /// `mayGoForRoom`, **over the file** (#357), one hop of it (#360, C33): of the file's oldest
    /// rows not kept past `from`, at most `roomHop` read — fewer where fewer are wanted — each as
    /// the pool holds it where it does, merged with the pool's own of the same stretch in the one
    /// order; and each spared by `mayGoForRoom`'s rule, asked of every row of the file or the
    /// pool that refers to it. The first `count` that go, and where the next hop reads from, or
    /// none where the file has no more. Nothing where the file would not be read.
    ///
    /// **Each hop asks the pool afresh**: between two, the actor is free and the pool moves. A
    /// pool's row is judged by the hop whose stretch it falls in, so one judged already is not
    /// judged again, and one laid in behind the hops waits for the next round.
    private func roomHop(_ count: Int, from: RoomHop?) -> (chosen: [Going], next: RoomHop?)? {
        guard let disk, poolKept() else { return nil }
        let shown = shownByKept()
        let arrival = self.arrival
        typealias Place = (postedAt: Date, arrival: Int64)
        func before(_ a: Place, _ b: Place) -> Bool {
            a.postedAt != b.postedAt ? a.postedAt < b.postedAt : a.arrival < b.arrival
        }
        func place(_ note: Note) -> Place { (note.postedAt, Int64(arrival[note.key] ?? 0)) }
        // By key and place alone, nothing decoded: what a hop of 2,000 costs is the reading.
        let read: (rows: [OldestRow], next: PageCursor?)
        do {
            // The first hop no more than is wanted; every one after it as many as a hop reads.
            read = try disk.oldestKeys(from == nil ? min(max(2 * count, 200), Self.roomHop) : Self.roomHop, after: from?.cursor)
        } catch {
            Self.unread(error)
            return nil
        }
        // The file's rows the pool does not answer for: one it answers for is here as it
        // holds it, or is let go already.
        var batch: [(going: Going, reblogs: Bool, place: Place)] = read.rows
            .filter { !looked.contains($0.key) && notes[$0.key] == nil && !shown.contains($0.key) }
            .map { (Going(key: $0.key, partOfTopic: nil), $0.reblogs, ($0.postedAt, $0.arrival)) }
        // The pool's rows that may go, past the last hop's stretch and up to this one's last
        // row, or all that are left past it.
        let last = read.rows.last.map { (postedAt: $0.postedAt, arrival: $0.arrival) }
        for note in notes.values where !note.kept && !shown.contains(note.key) {
            let at = place(note)
            if let from, !before(from.last, at) { continue }
            if read.next != nil, let last, before(last, at) { continue }
            batch.append((Going(key: note.key, partOfTopic: note.isPartOfTopic), note.isReblog, at))
        }
        batch.sort { before($0.place, $1.place) }
        let askable = batch.filter { !$0.reblogs }.map(\.going.key)
        let fromFile: [Referrer]
        do {
            fromFile = askable.isEmpty ? [] : try disk.referring(to: askable)
        } catch {
            Self.unread(error)
            return nil
        }
        var referring: [NoteKey: [(stays: Bool, place: Place)]] = [:]
        for referrer in fromFile where !looked.contains(referrer.key) && notes[referrer.key] == nil {
            referring[referrer.target, default: []].append(
                (referrer.kept || shown.contains(referrer.key), (referrer.postedAt, referrer.arrival))
            )
        }
        let asked = Set(askable)
        for note in notes.values {
            for key in note.heldWith where asked.contains(key) {
                referring[key, default: []].append((note.kept || shown.contains(note.key), place(note)))
            }
        }
        var chosen: [Going] = []
        for (going, reblogs, at) in batch where chosen.count < count {
            let spared = !reblogs && (referring[going.key] ?? []).contains { $0.stays || before(at, $0.place) }
            if !spared { chosen.append(going) }
        }
        guard let cursor = read.next, let last else { return (chosen, nil) }
        return (chosen, RoomHop(cursor: cursor, last: last))
    }

    /// A row the room limit lets go: its key, and whether it is a topic's reply — known of a
    /// row the pool holds, not of one only the file does, which is read no further than its key.
    private struct Going {
        let key: NoteKey
        let partOfTopic: Bool?
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
        Set(notes.values.lazy.filter { $0.kept && $0.isReblog }.compactMap(\.reblogKey)).union(keptSpared)
    }

    /// How many rows were posted inside `span` and, where `host` is given, came through that host
    /// — items and a topic's kept replies alike (#248). What a press to let a span go would take, so the question
    /// before it names the true count: a kept post is not counted, since the press leaves it (#284).
    /// **Over a file, of the pool alone** (#357, C11): at least how many go, and said so.
    /// The question before the press asks `countGoing`.
    public func count(span: Range<Date>, host raw: String? = nil) -> Int {
        let host = raw?.lowercased()
        let shown = shownByKept()
        return notes.values.reduce(0) { $0 + (Self.inside(span, host: host, $1, shown) ? 1 : 0) }
    }

    /// How many rows `letGo(span:host:)` would let go now — **over a file, every one of the
    /// file's**, read or not (C14): what the question before the press names. Of the pool alone
    /// where the file would not say.
    public func countGoing(span: Range<Date>, host raw: String? = nil) -> Int {
        let host = raw?.lowercased()
        guard poolKept(), let unpooled = unpooled(.span(span, host: host)) else { return count(span: span, host: host) }
        let shown = shownByKept()
        return count(span: span, host: host) + unpooled.filter { !shown.contains($0) }.count
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
    public func letGo(span: Range<Date>, host raw: String? = nil) async -> Int {
        await untilNoPutBack()
        let host = raw?.lowercased()
        // Over a file, its rows of those days the pool does not hold go by key with the rest —
        // or, where the file would not say which they are, nothing goes.
        guard poolKept(), let unpooled = unpooled(.span(span, host: host)) else { return 0 }
        let shown = shownByKept()
        let going = notes.values.filter { Self.inside(span, host: host, $0, shown) }
        let unheld = unpooled.filter { !shown.contains($0) }
        // **And the copy of a post of those days a notice carries**, an item or not: the reader
        // said these days go. Not one of a post that stays held — a kept one.
        let leaving = Set(going.map(\.key))
        let held = notes
        strike { post in
            span.contains(post.postedAt) && (host == nil || post.source.host == host)
                && (held[post.key] == nil || leaving.contains(post.key))
        }
        guard !going.isEmpty || !unheld.isEmpty else { return 0 }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        drop(unheld)
        changed(shown: going.contains { !$0.isPartOfTopic }, replies: going.contains { $0.isPartOfTopic })
        return going.count + unheld.count
    }

    /// The keys of the file's rows `selection` names that the pool does not answer for — none for
    /// a store with no file, and nothing where the file would not be read.
    private func unpooled(_ selection: RowSelection) -> [NoteKey]? {
        guard let disk else { return [] }
        do {
            return try disk.keys(selection).filter { !looked.contains($0) }
        } catch {
            Self.unread(error)
            return nil
        }
    }

    /// Rows of the file the pool does not hold, let go: **deleted by the next save, and answered
    /// for as not held** until it lands and after, so none is read in again.
    private func drop(_ keys: [NoteKey]) {
        guard !keys.isEmpty else { return }
        looked.formUnion(keys)
        notes.owe(keys, dropped: keys)
    }

    /// Whether `note` is what `letGo(span:host:)` reaches: posted inside `span`, from `host`
    /// where one is named, and not kept.
    private static func inside(_ span: Range<Date>, host: String?, _ note: Note, _ shownByKept: Set<NoteKey>) -> Bool {
        !note.kept && !shownByKept.contains(note.key)
            && span.contains(note.postedAt) && (host == nil || note.source.host == host)
    }

    /// Everything this store holds, read in one hop, the rows in the order they arrived: what a
    /// take-away writes into a store of its own. A save writes what changed (`takeChanges`).
    public func snapshot() -> (sources: [Source], notes: [Note], said: [SourceProfile], revision: Int) {
        let arrival = self.arrival
        let ordered = notes.values.sorted { (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0) }
        // By host, so one state of the store is always written one way.
        let said = saidByHost.values.sorted { $0.host < $1.host }
        return (sourceList, ordered, said, revision)
    }

    /// **What changed since the last take, and the revision it is of** (#357), in one hop: each
    /// row a change reached, as it stands now or as a key to delete; and the sources, whole, where
    /// any of them moved. Taken, it is owed no more — a save that cannot write it hands it back
    /// (`putBack`). A row changed again after this is taken again, as it then stands.
    ///
    /// **Rows new to the file in the order they arrived**, so the file keeps that order (#114).
    public func takeChanges() -> (changes: RowChanges, revision: Int) {
        var changes = RowChanges()
        var upserts: [Note] = []
        let taken = notes.take()
        for key in taken.touched {
            if let note = notes[key] { upserts.append(note) }
            if notes[key] == nil || taken.dropped.contains(key) { changes.deletes.append(key) }
        }
        let arrival = self.arrival
        changes.upserts = upserts.sorted { (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0) }
        changes.deletes.sort { ($0.host, $0.id) < ($1.host, $1.id) }
        let hosts = Set(sourceList.map(\.host))
        var removed = hostsOwed
        if let written = sourcesWritten { removed.formUnion(written.sources.map(\.host)) }
        changes.removedHosts = removed.subtracting(hosts).sorted()
        if sourcesWritten.map({ $0.sources != sourceList || $0.said != saidByHost }) ?? true {
            changes.sources = sourceList
            // By host, so one state of the store is always written one way.
            changes.said = saidByHost.values.sorted { $0.host < $1.host }
        }
        sourcesWritten = (sourceList, saidByHost)
        hostsOwed = []
        changes.ops = opsOwed
        opsOwed = []
        inFlight.formUnion(changes.upserts.map(\.key) + changes.deletes)
        opsInFlight.formUnion(changes.ops.map(\.number))
        poolMoved += 1
        return (changes, revision)
    }

    /// `changes`, taken and written: the file holds them now. What a read of the file brings
    /// in is from here on read as they left it — once no page begun before is out.
    public func wrote(_ changes: RowChanges) {
        landed(changes)
        goneLanded.formUnion(changes.deletes)
        settleOps()
        forgetLanded()
        letRowsLeave()
    }

    /// The keys a delete that landed took from the file, still among `looked` (#360, C33): they
    /// leave it at a quiet moment.
    private var goneLanded: Set<NoteKey> = []
    /// Whether a read back has the file in a state it may yet be put back from (`mayBePutBack`).
    /// Said no more, whatever waits for that goes on (`untilNoPutBack`).
    private var putBackMay = false {
        didSet {
            guard !putBackMay, !waitingForPutBack.isEmpty else { return }
            let waiting = waitingForPutBack
            waitingForPutBack = []
            for one in waiting { one.resume() }
        }
    }
    /// The acts that let posts go asked while a read back may put the file back, waiting.
    private var waitingForPutBack: [CheckedContinuation<Void, Never>] = []
    /// How many acts wait so: for the tests.
    var waitingForUndo: Int { waitingForPutBack.count }

    /// **An act that lets posts go waits while a read back may put the file back** (#360): the
    /// file then holds the package's store, or is about to, and what it names of the file's rows
    /// would be the package's — a key the package and the store put back share, let go now, would
    /// be deleted from the store put back by the undo (`oweEverything`). It goes on once the store
    /// is replaced or the undo has run, then reading the file as it is.
    private func untilNoPutBack() async {
        while putBackMay {
            await withCheckedContinuation { waitingForPutBack.append($0) }
        }
    }

    /// **A landed delete's keys leave `looked`** (#360, C33): the file no longer holds the row, so
    /// a read of it answers "not held" by itself, and a key kept for nothing is the pool's
    /// bookkeeping growing with what was let go. **Only at a quiet moment** — no page out, as
    /// `settleOps` — since a page read before the delete landed may still carry the row; **only
    /// of a key nothing has taken up since** — held again, owed again, or on its way in a later
    /// save; **and never while a read back may still put the file back** (`mayBePutBack`): its undo
    /// owes a delete of each row the older file holds that the run let go, known by `looked`.
    /// A save that failed lands nothing here, so what it carried stays answered for.
    ///
    /// **And each leaves the rows let go of the pool** (`listedLeft`): one there and no longer
    /// answered for would be taken for a row the file still holds, and its id for the newest a
    /// timeline listed (#201) — of a post the file no longer has.
    private func forgetLanded() {
        guard !goneLanded.isEmpty, pagesOut == 0, !restoringFile, !putBackMay else { return }
        var forgotten: [String: Set<NoteKey>] = [:]
        for key in goneLanded where notes[key] == nil && !notes.touched.contains(key) && !inFlight.contains(key) {
            looked.remove(key)
            readPastLimit[key] = nil
            forgotten[key.host, default: []].insert(key)
        }
        goneLanded = []
        for (host, keys) in forgotten {
            guard let byCategory = listedLeft[host] else { continue }
            var kept: [Category: [(id: String, key: NoteKey)]] = [:]
            for (category, left) in byCategory {
                let staying = left.filter { !keys.contains($0.key) }
                if !staying.isEmpty { kept[category] = staying }
            }
            listedLeft[host] = kept.isEmpty ? nil : kept
        }
    }

    /// Whether the file may be put back to what it held before a read back (#344, `restoring`):
    /// said before the read back writes the package into the file, and said no more by
    /// `replace` or `oweEverything`, or by the read back where it wrote nothing. Meanwhile a
    /// landed delete's keys stay among `looked` (`forgetLanded`).
    public func mayBePutBack(_ may: Bool) {
        putBackMay = may
        // A page read before is of the file as it was (`passingThrough`).
        if may { filesCopiedIn += 1 }
        if !may { forgetLanded() }
    }

    /// Whether the file may hold, or be about to hold, another store than the pool's (#360): a
    /// read back's copy in, until the store is replaced or owes what an undo put back. **Nothing
    /// read of the file meanwhile is laid in or answered for** — a row of the package laid into
    /// the store it replaces, or a key it lacks taken for one let go, would be written over the
    /// file put back, or deleted from it, by the undo's `oweEverything`. A read by key is passed
    /// through (`note`, `notes`); every other way in takes no copy over a key it did not find.
    /// How many reads of the reader's marks have been begun (#317), and for each host and
    /// category the latest begun of those landed and the posts each found no longer marked, by
    /// when that read was begun — what tells a read outrun by a later one (`land(_:of:ifSourceHere:)`).
    private var marksBegun = 0
    private var marksLanded: [String: Int] = [:]
    private var marksGone: [String: [NoteKey: Int]] = [:]

    private var passingThrough: Bool { putBackMay || restoringFile }

    /// Whether a read back may still put the file back (`mayBePutBack`): for the tests.
    var holdsForPutBack: Bool { putBackMay }

    /// How many keys the pool answers for (`looked`): for the tests.
    var lookedCount: Int { looked.count }

    /// **How many entries each collection the store holds has** (#360, K-12): counts only, never
    /// what an entry says. A collection of collections is counted by what it holds summed
    /// (`namesAsked`, `listedLeft`, …). The pool's own books — what each row holds, the order of
    /// sightings — are counted with their room (`.capacity`), as a dictionary or an array keeps
    /// its room when entries leave. The turns of a letting go are made and let go within a pass,
    /// and so held by nothing between passes.
    func census() -> [String: Int] {
        [
            "pool": notes.count,
            "pool.capacity": notes.rows.capacity,
            "pool.touched": notes.touched.count,
            "pool.dropped": notes.dropped.count,
            "pool.seen": notes.seen.count,
            "pool.seen.capacity": notes.seen.capacity,
            "pool.holders": notes.holders.count,
            "pool.holders.capacity": notes.holders.capacity,
            "pool.sightings": notes.sightings.count,
            "pool.sightings.capacity": notes.sightings.capacity,
            "sources": sourceList.count,
            "said": saidByHost.count,
            "opsOwed": opsOwed.count,
            "opsRun": opsRun.count,
            "opsInFlight": opsInFlight.count,
            "inFlight": inFlight.count,
            "pins": pins?.count ?? 0,
            "pinsBy": pinsBy.count,
            "pinsBy.pins": pinsBy.values.reduce(0) { $0 + $1.pins.count },
            "screensGone": screensGone.count,
            "listedLeft": listedLeft.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } },
            // A read back's waits and marks: those waiting for it to be put back or not, how
            // many files it copied in, and whether it may yet be put back or is being.
            "waitingForPutBack": waitingForPutBack.count,
            "filesCopiedIn": filesCopiedIn,
            "putBackMay": putBackMay ? 1 : 0,
            "restoringFile": restoringFile ? 1 : 0,
            "passesTook": passesTook.count,
            "hopsTook": hopsTook.count,
            "looked": looked.count,
            "looked.capacity": looked.capacity,
            "namesAsked": namesAsked.values.reduce(0) { $0 + $1.count },
            "remainSaid": remainSaid.values.reduce(0) { $0 + $1.count },
            "hostsOwed": hostsOwed.count,
            "arrival": arrival.count,
            "arrival.capacity": arrival.capacity,
            "acted": acted.count,
            "readAt": readAt.count,
            "swept": swept.count,
            "listeners": listeners.count,
            "unsent": unsent.count,
            "unsentGone": unsentGone.count,
            "unsentSenders": unsentSenders.count,
            "reaches": reaches.count,
            "noticeEpochs": noticeEpochs.count,
            "readPastLimit": readPastLimit.count,
            "goneLanded": goneLanded.count,
            "undecodable": undecodable.count,
            "keptSpared": keptSpared.count,
            "stalled": stalled.count,
            "refused": refused.values.reduce(0) { $0 + $1.count },
        ]
    }

    /// `changes` no longer on their way to the file, written or handed back.
    private func landed(_ changes: RowChanges) {
        poolMoved += 1
        inFlight.subtract(changes.upserts.map(\.key) + changes.deletes)
        opsInFlight.subtract(changes.ops.map(\.number))
    }

    /// At a quiet moment — no page out — every change up to the first still owed or on its way
    /// is the file's: a read from here on begins after it landed.
    private func settleOps() {
        guard pagesOut == 0, !restoringFile else { return }
        let lowest = (opsOwed.map(\.number) + opsInFlight).min()
        opsSettled = max(opsSettled, lowest.map { $0 - 1 } ?? opsMade)
    }

    /// `changes`, taken and not written: owed again. Each row is written as it stands at the next
    /// take, so one changed meanwhile is written with its newer word, and one let go meanwhile
    /// is deleted.
    public func putBack(_ changes: RowChanges) {
        landed(changes)
        notes.owe(changes.upserts.map(\.key) + changes.deletes, dropped: changes.deletes)
        hostsOwed.formUnion(changes.removedHosts)
        if changes.sources != nil { sourcesWritten = nil }
        opsOwed = changes.ops.filter { $0.number > opsFloor } + opsOwed
    }

    /// The file is about to be put back to an older store (#359), before it is: every change of
    /// the run is unsettled, so a row read from the file — by key, or on a page out across it
    /// — is read as each leaves it, and none settles again until `oweEverything`. Where the
    /// put back fails, none settles for the rest of the run: what the file holds is not known.
    public func restoring() {
        restoringFile = true
        opsSettled = opsFloor
        filesCopiedIn += 1
    }

    /// **The file put back to an older store behind this one** — a read back's undo copying back
    /// what the index held when it began, which a save may have written over since (#344): every
    /// row and source held is owed a write, and every row the file now holds that this store
    /// does not is owed a delete. So whatever was saved in between is written again, and nothing
    /// the file was put back to that was let go stays. `hosts` are the sources the file was put
    /// back to, owed their removal before every source held is written again.
    ///
    /// **Over a file, a row not held is one the pool answers for and lacks** (#357, #360): a row
    /// never read is the file's, not let go. So no list of what the file holds is asked for:
    /// what is owed a delete is what the pool answers for and lacks, asked of the file put back
    /// by key, a chunk at a time — a chunk that will not be read owed whole, a delete of a row
    /// the file lacks being nothing. And every change the file was to make of the rows not held
    /// is owed again, the older store knowing none of them.
    ///
    /// `fileHolds` is for a store held whole, which answers for nothing it lacks: every row of
    /// the file put back, of which it owes a delete of each it does not hold.
    public func oweEverything(hosts: [String], fileHolds keys: [NoteKey]? = nil) {
        let held = Array(notes.keys)
        var gone: [NoteKey] = []
        if let disk {
            let lacking = looked.filter { notes[$0] == nil }.sorted { ($0.host, $0.id) < ($1.host, $1.id) }
            for start in stride(from: 0, to: lacking.count, by: Self.restoredChunk) {
                let chunk = Array(lacking[start..<min(start + Self.restoredChunk, lacking.count)])
                if let found = try? disk.rows(chunk) {
                    gone += found.map(\.note.key)
                } else {
                    gone += chunk
                }
            }
        } else {
            gone = (keys ?? []).filter { notes[$0] == nil }
        }
        notes.owe(held + gone)
        filesCopiedIn += 1
        opsOwed = opsRun
        // The file knows none of them again: a row read in is read as each leaves it.
        opsSettled = opsFloor
        restoringFile = false
        sourcesWritten = nil
        hostsOwed.formUnion(hosts)
        putBackMay = false
        forgetLanded()
        changed(shown: false, replies: false)
    }

    /// How many keys one read of the file put back asks at once (`oweEverything`).
    static let restoredChunk = 500

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
        let beyond = pastTheLimit()
        return notes.values.filter { !$0.isPartOfTopic && (beyond.isEmpty || !beyond.contains($0.key)) }
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

    // MARK: - The pool, read from the file as it is wanted (#357)

    /// Lays `rows` read from the file — a page's, and what it carries — into the pool, each as
    /// the file holds it, with what each holds. **A row the pool answers for already stays as
    /// the pool has it**: it may say what no save has written yet, or be let go. Whether any
    /// row came in; never one in a whole pool.
    @discardableResult
    public func take(_ rows: [HeldRow]) -> Bool {
        let before = notes.count
        pool(found: rows)
        return notes.count != before
    }

    /// Reads a page off the actor and lays it in (`take`), **counted while it is out** (#359):
    /// the changes that land meanwhile are not settled until no page is (`settleOps`), so a page
    /// read before one landed is laid in as that change leaves it. Every page a timeline reads
    /// comes through here; `take(_:)` stays for tests and the read back.
    public func paged(_ read: @Sendable () async throws -> Page) async throws -> Page {
        pagesOut += 1
        defer { pageBack() }
        let copied = filesCopiedIn
        let page = try await read()
        // Read of a file a read back has since copied over (`replace(sources:said:)`): its rows
        // are no longer the file's, and none is laid in.
        if copied == filesCopiedIn { take(page.rows + page.carried) }
        return page
    }

    /// `paged(_:)` of a read that may have no page to give: a provisional one (C15).
    public func pagedIfAny(_ read: @Sendable () async throws -> Page?) async throws -> Page? {
        pagesOut += 1
        defer { pageBack() }
        let copied = filesCopiedIn
        guard let page = try await read() else { return nil }
        if copied == filesCopiedIn { take(page.rows + page.carried) }
        return page
    }

    /// How many times a read back copied another store into the file (`replace(sources:said:)`):
    /// a page read before the latest is of the file as it was, and is not laid in.
    private var filesCopiedIn = 0

    private func pageBack() {
        pagesOut -= 1
        settleOps()
        forgetLanded()
        letRowsLeave()
    }

    // MARK: - Rows let go of the pool, least lately seen first (#359)

    /// How many rows the pool holds: at least so many are held, never how many.
    public var pooled: Int { notes.count }

    /// The keys the screens draw now, made from what `all()` handed over at the `drawn`
    /// revision `drawnAt`: in place of the last set, each seen now. **The first call is what lets
    /// rows leave the pool at all** — none does before the screens say what they draw. Rows
    /// leave at once where the pool is over its cap and no page is out; otherwise once none is.
    public func hold(_ drawnNow: Set<NoteKey>, drawnAt: Int) {
        hold(drawnNow, drawnAt: drawnAt, by: Self.oneScreen)
    }

    /// The keys the screen `screen` draws now, as `hold(_:drawnAt:)` — **in place of what that
    /// screen said last, and beside what every other said** (#359, G-4): a window's drawing
    /// replaces nothing another window draws.
    public func hold(_ drawnNow: Set<NoteKey>, drawnAt: Int, by screen: UUID) {
        guard !screensGone.contains(screen) else { return }
        pinsBy[screen] = (drawnNow, drawnAt)
        pinsSaid()
        notes.saw(drawnNow)
        letRowsLeave()
    }

    /// The screen `screen` draws nothing any more — a window closed: what only it drew goes as
    /// any row drawn nowhere, **and nothing it says after is heard**. Once every screen said so,
    /// nothing is drawn, and none is kept for it.
    public func letGoOfPins(by screen: UUID) {
        screensGone.insert(screen)
        guard pinsBy.removeValue(forKey: screen) != nil else { return }
        pinsSaid()
        letRowsLeave()
    }

    /// `pins` as every screen says them now.
    private func pinsSaid() {
        let all = pinsBy.values.reduce(into: Set<NoteKey>()) { $0.formUnion($1.pins) }
        let at = pinsBy.values.map(\.at).min() ?? drawn
        if pins != all || pinsDrawnAt != at { poolMoved += 1 }
        pins = all
        pinsDrawnAt = at
    }

    /// **Lets the least lately seen rows go of the pool, not of the file**, where it holds more
    /// than its cap: down to nine tenths of it, so the next page read in does not let rows go
    /// again. Never in a whole store, never before the screens first say what they draw
    /// (`hold`), and only at a quiet moment — no page out, the file not being put back — so a
    /// page laid in after began after every row it might bring back older had left (C17).
    ///
    /// **What stays, whatever its turn**: a row changed and not taken by a save, or taken by
    /// one that has not landed (the file would bring it back older); a kept row; one drawn
    /// (`pins`), or laid in or changed since what is drawn was made; one owing a load not given
    /// up (`owed(host:)` asks the pool alone); one carrying a mark a read on said again
    /// (`remainSaid`: read back, it would lose it); and **what a row that stays holds with
    /// it** (`Note.heldWith`, `Note.topicKey`), so a reference not in the pool still means not
    /// held. A row let go frees what it held, which may then go in the same pass, in its turn.
    private func letRowsLeave() {
        guard disk != nil, let pins, pagesOut == 0, !restoringFile, notes.count > cap, leftNoneAt != poolMoved
        else { return }
        evictionPasses += 1
        let started = ContinuousClock.now
        defer {
            passesTook.append(ContinuousClock.now - started)
            if passesTook.count > Self.passesKept { passesTook.removeFirst(passesTook.count - Self.passesKept) }
        }
        let goal = notes.count - cap * 9 / 10
        let since = pinsDrawnAt
        /// Whether `note`, last seen under the drawing `drawn`, may go whatever holds it.
        func free(_ note: Note, drawn: Int) -> Bool {
            let key = note.key
            if note.kept || drawn >= since || notes.touched.contains(key) || inFlight.contains(key) || pins.contains(key) {
                return false
            }
            if note.refsDue && !stalled.contains(key) { return false }
            if let said = remainSaid[key.host], !note.gaps.isDisjoint(with: said) { return false }
            return true
        }
        // The rows in the order last seen, the least lately first (`HeldNotes.sightings`): each
        // free to go and held by no row that stays goes in its turn. One a row let go frees,
        // whose turn has passed, goes before the next in order; one whose turn is to come is
        // met in it.
        let order = notes.sightings
        var at = 0
        var freed = Turns([])
        var freedRows: [Int: Note] = [:]
        /// The next in order free to go and held by none, and its row; nothing once it is done.
        func nextInOrder() -> (tick: Int, note: Note)? {
            while at < order.count {
                let sighting = order[at]
                at += 1
                guard let seen = notes.seen[sighting.key], seen.tick == sighting.tick, notes.holders[sighting.key] == nil,
                      let note = notes[sighting.key], free(note, drawn: seen.drawn)
                else { continue }
                return (sighting.tick, note)
            }
            return nil
        }
        var walked = nextInOrder()
        var left = 0
        var shown = false
        var replies = false
        while left < goal {
            let note: Note
            if let first = freed.first, walked.map({ first < $0.tick }) ?? true {
                _ = freed.pop()
                // Read again since it was put in its turn: still here, and held by none.
                guard let row = freedRows.removeValue(forKey: first), notes.holders[row.key] == nil, notes[row.key] != nil
                else { continue }
                note = row
            } else if let next = walked {
                // Met in order a moment ago, and nothing let go since holds anything more.
                note = next.note
                walked = nextInOrder()
            } else {
                break
            }
            left += 1
            if note.isPartOfTopic { replies = true } else { shown = true }
            let holding = HeldNotes.holds(note)
            letGo(note, holding: holding)
            for held in holding where notes.holders[held] == nil {
                guard let seen = notes.seen[held], let row = notes[held], free(row, drawn: seen.drawn) else { continue }
                // Freed, with its turn passed: before the next in order. One to come is met there.
                if let walked, seen.tick > walked.tick { continue }
                freed.push(seen.tick)
                freedRows[seen.tick] = row
            }
        }
        if notes.count > cap, !overCapSaid {
            overCapSaid = true
            NetLog.index.notice("Rows the pool must keep are over its cap: \(self.notes.count, privacy: .public)")
        }
        guard left > 0 else {
            leftNoneAt = poolMoved
            return
        }
        // Drawn nowhere, so nothing on screen moves: what `all()` hands over is only smaller.
        changed(shown: shown, replies: replies, kept: false)
    }

    /// `note` let go of the pool and not of the file: read again once it is wanted.
    private func letGo(_ note: Note, holding: [NoteKey]? = nil) {
        let key = note.key
        notes.evict(key, holding: holding)
        looked.remove(key)
        // A row that arrived this run keeps its place among the run's: read back, the file's
        // `rowid` would put it before a copy that arrived ahead of it and is still held.
        if (arrival[key] ?? 0) < Self.arrivingAfterTheFile { arrival[key] = nil }
        // A reference by its source's id asks the file again, rather than take it for not held.
        if let statusID = note.statusID { namesAsked[key.host]?.remove(statusID) }
        if note.goneSince == nil {
            for (category, id) in note.listed {
                // Where it goes among the rest, newest first, found by halves: a letting go
                // files hundreds of rows, and each list is read in place, not copied.
                let (was, at) = Self.place(id, of: key, among: listedLeft[key.host]?[category] ?? [])
                guard at < Self.listedLeftKept else { continue }
                listedLeft[key.host, default: [:]][category, default: []].file((id, key), at: at, was: was, most: Self.listedLeftKept)
            }
        }
    }

    /// Where the row under `key`, listed under `id`, stands among `left` (newest first) — found
    /// by halves — and where it stood, if it was there.
    private static func place(_ id: String, of key: NoteKey, among left: [(id: String, key: NoteKey)]) -> (was: Int?, at: Int) {
        let was = left.firstIndex { $0.key == key }
        var low = 0
        var high = left.count
        while low < high {
            let mid = (low + high) / 2
            if StatusID.later(id, than: left[mid].id) { high = mid } else { low = mid + 1 }
        }
        return (was, was.map { $0 < low ? low - 1 : low } ?? low)
    }

    /// `note`'s key and what it holds with it: what reading it in reads.
    private static func reach(_ note: Note) -> [NoteKey] {
        [note.key] + note.heldWith + [note.topicKey].compactMap { $0 }
    }

    /// Reads each row under `keys` the pool does not answer for from the file. **Returns the
    /// keys it could not answer for** — the file would not be read, or a row will not decode —
    /// and every way in takes no copy under one of them: what the file holds there is not
    /// known, and a copy taken for a row new here would be written over it. Its source sends
    /// it again.
    @discardableResult
    private func pool(_ keys: some Sequence<NoteKey>) -> Set<NoteKey> {
        guard disk != nil else { return [] }
        if passingThrough { return Set(keys).filter { notes[$0] == nil } }
        return lay(Set(keys).subtracting(looked), found: [])
    }

    /// The rows under `keys`, the pool's where it holds them and **the file's, passed through
    /// and not laid in**, while it may hold another store (`passingThrough`).
    private func passed(_ keys: [NoteKey]) -> [NoteKey: Note] {
        var found: [NoteKey: Note] = [:]
        for key in keys { found[key] = notes[key] }
        let missing = keys.filter { found[$0] == nil }
        guard let disk, !missing.isEmpty, let read = reading({ try disk.rows(missing) }) else { return found }
        for row in read.rows where found[row.note.key] == nil { found[row.note.key] = unlanded(row.note) }
        return found
    }

    /// Lays `found` in, where the pool does not answer for its rows: the keys not answered for.
    @discardableResult
    private func pool(found: [HeldRow]) -> Set<NoteKey> {
        guard disk != nil else { return [] }
        if passingThrough { return Set(found.map(\.note.key).filter { self.notes[$0] == nil }) }
        // What the pool holds already stays as it has it, and is seen now: the window the page
        // was read for draws it once the screens next say so, and until then it is as new to
        // them as a row laid in — let go first, it would be a hole in a stretch read.
        let fresh = found.filter { looked.insert($0.note.key).inserted }
        if fresh.count != found.count {
            let laid = Set(fresh.map(\.note.key))
            notes.readAgain(found.lazy.map(\.note.key).filter { !laid.contains($0) })
        }
        return lay([], found: fresh)
    }

    /// `read`, the rows it could and, where some would not decode, the keys of those — which
    /// the pool does not answer for, so a copy of one is never taken over it. Nothing at all
    /// where the file could not be read.
    private func reading(_ read: () throws -> [HeldRow]) -> (rows: [HeldRow], unread: [NoteKey])? {
        do {
            return (try read(), [])
        } catch let partly as RowsUnread {
            // Said once a run of each, however often a copy of one is turned away.
            let fresh = Set(partly.keys).subtracting(undecodable)
            if !fresh.isEmpty {
                undecodable.formUnion(fresh)
                NetLog.index.error("Rows of the index that will not decode, not taken: \(fresh.count, privacy: .public)")
            }
            return (partly.rows, partly.keys)
        } catch {
            Self.unread(error)
            return nil
        }
    }

    /// The rows of the file met this run that will not decode: never answered for, and told once.
    private var undecodable: Set<NoteKey> = []

    /// Every row of `host` the file holds whose id starts `idPrefix`, laid in.
    private func poolRows(host: String, idPrefix: String) {
        guard let disk, let read = reading({ try disk.rows(host: host, idPrefix: idPrefix) }) else { return }
        pool(found: read.rows.filter { $0.note.id.hasPrefix(idPrefix) })
    }

    /// Reads `keys` from the file and lays them in with `found`, then what each holds
    /// (`Note.heldWith`, `Note.topicKey`), until nothing it holds is left to read. **All of it
    /// or none**: where the file will not be read, nothing is laid in and the pool answers for
    /// none of it, so no row stands in the pool without what it holds. A row that will not
    /// decode is left out alone (`RowsUnread`). Returns the keys not answered for.
    ///
    /// Each row laid in is then made what opening the whole store made every row: a forum reply
    /// given its topic's board (#297), what it owes settled against what is held (#293) — and a
    /// mark a read on said again this run taken off (`remainSaid`), as it came off every row.
    private func lay(_ keys: Set<NoteKey>, found: [HeldRow]) -> Set<NoteKey> {
        guard let disk else { return [] }
        var arriving = found
        var asking = keys
        var marked = Set(found.map(\.note.key))
        var unread: Set<NoteKey> = []
        var read: [HeldRow] = []
        while true {
            for row in arriving where notes[row.note.key] == nil {
                read.append(row)
                asking.formUnion(Self.reach(row.note))
            }
            asking.subtract(looked)
            asking.subtract(unread)
            guard !asking.isEmpty else { break }
            let next = asking.sorted { ($0.host, $0.id) < ($1.host, $1.id) }
            looked.formUnion(next)
            marked.formUnion(next)
            asking = []
            guard let answer = reading({ try disk.rows(next) }) else {
                // Asked again the next time any of it is wanted.
                looked.subtract(marked)
                return marked.union(keys)
            }
            arriving = answer.rows
            looked.subtract(answer.unread)
            unread.formUnion(answer.unread)
        }
        var laid: [NoteKey] = []
        for row in read {
            let key = row.note.key
            if stepping, let retention, !row.note.kept, row.note.postedAt < retention {
                readPastLimit[key] = row.note.isReblog
            }
            notes.lay(unlanded(row.note))
            if let said = remainSaid[key.host], !row.note.gaps.isDisjoint(with: said) {
                notes[key]?.gaps.subtract(said)
            }
            // One that arrived this run and left the pool keeps its place among the run's.
            arrival[key] = arrival[key] ?? Int(row.arrival)
            laid.append(key)
        }
        guard !laid.isEmpty else { return unread }
        for key in laid {
            guard let note = notes[key], note.source.kind == .discuz else { continue }
            let through = Self.throughItsBoard(note, in: notes)
            if through.categories != note.categories { notes[key] = through }
        }
        settleOwing(among: Set(laid))
        // What `all()` and `replies()` hand over grew; nothing is owed a write for it.
        let parts = laid.compactMap { notes[$0]?.isPartOfTopic }
        changed(shown: parts.contains(false), replies: parts.contains(true), kept: false)
        return unread
    }

    /// Whether the kept rows of the file are in the pool, with what they hold (`poolKept`).
    private var keptRead = false

    /// Every row the file holds that the person keeps, laid in once a run: **what a letting go
    /// asks before it lets a post go**, since a kept reblog of it holds it (`shownByKept`) and
    /// the reblog need not have been read. False where they could not be read, and nothing may
    /// be let go for being unkept.
    ///
    /// **Once a run**: a kept row that will not decode is no reason to read them again — what
    /// it reblogs is read off its references alone and spared (`keptSpared`).
    /// Every kept row of the file laid in (`poolKept`), for a count of what is kept that must not
    /// say none where the file keeps some (#357): one read, once a run. Whether they are all in —
    /// true for a store held whole.
    public func readKept() -> Bool {
        poolKept()
    }

    private func poolKept() -> Bool {
        guard let disk, !keptRead else { return true }
        guard let read = reading({ try disk.keptRows() }) else { return false }
        if !read.unread.isEmpty {
            do {
                keptSpared = Set(try disk.reblogged(by: read.unread))
            } catch {
                Self.unread(error)
                return false
            }
        }
        pool(found: read.rows)
        // Laid in, or answered for already: none left out by a read that failed.
        guard read.rows.allSatisfy({ looked.contains($0.note.key) }) else { return false }
        keptRead = true
        return true
    }

    /// What the kept rows of the file that will not decode reblog: held for them, as
    /// `shownByKept` holds what a kept reblog shows.
    private var keptSpared: Set<NoteKey> = []

    /// A read of the file that failed: the rows it was for are not laid in, and nothing else.
    private static func unread(_ error: any Error) {
        NetLog.index.error("Rows of the index could not be read: \(String(describing: type(of: error)), privacy: .public)")
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
    private static func named(in notes: HeldNotes, of hosts: Set<String>) -> [String: [String: String]] {
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
    private static func settleOwing(in notes: inout HeldNotes, of hosts: Set<String>?, among keys: Set<NoteKey>? = nil) -> [NoteKey] {
        let owing = Self.owing(in: notes, of: hosts, among: keys)
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

    /// The items among `notes` of `hosts` — or only those under `keys`, where given — that owe,
    /// or say a post is gone: said once, on one answer, and taken back where the post turns up
    /// after all.
    private static func owing(in notes: HeldNotes, of hosts: Set<String>?, among keys: Set<NoteKey>?) -> [Note] {
        let candidates = keys.map { $0.compactMap { notes[$0] } } ?? Array(notes.values)
        return candidates.filter {
            ($0.refsDue || $0.refs.contains(where: \.gone)) && (hosts?.contains($0.key.host) ?? true)
        }
    }

    /// `settleOwing(in:of:among:)` over what this store holds — **and what the file holds** of
    /// the posts the items owe (#357): read in by the source's id first, so a post held there
    /// names the reference as it would have in the whole store. Whether any row changed.
    @discardableResult
    private func settleOwing(of hosts: Set<String>? = nil, among keys: Set<NoteKey>? = nil) -> Bool {
        if let disk {
            var asking: [String: Set<String>] = [:]
            for note in Self.owing(in: notes, of: hosts, among: keys) {
                for reference in note.refs where reference.kind != .reblogs && reference.id == nil {
                    guard let statusID = reference.statusID,
                          namesAsked[note.key.host, default: []].insert(statusID).inserted
                    else { continue }
                    asking[note.key.host, default: []].insert(statusID)
                }
            }
            for (host, statusIDs) in asking.sorted(by: { $0.key < $1.key }) {
                // A row that will not decode names nothing: the reference stays as it is.
                guard let read = reading({ try disk.rows(host: host, statusIDs: statusIDs.sorted()) }) else {
                    namesAsked[host]?.subtract(statusIDs)
                    continue
                }
                pool(found: read.rows)
                if !read.rows.allSatisfy({ looked.contains($0.note.key) }) { namesAsked[host]?.subtract(statusIDs) }
            }
        }
        let moved = Self.settleOwing(in: &notes, of: hosts, among: keys)
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
        if let items { pool(items) }
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
            case .home, .list, .bookmarks, .favourites: through = true
            case .board: break
            }
        }
        return through || note.saysReader
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
        pool([key])
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
        let beyond = pastTheLimit()
        return notes.values.filter { $0.isPartOfTopic && (beyond.isEmpty || !beyond.contains($0.key)) }
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
        // Neither the row nor what keeps it held could be read: nothing is let go, or struck.
        guard pool([key]).isEmpty, poolKept() else { return }
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
        forgetReaderMarks(of: .only(raw.lowercased()))
    }

    /// `forgetReaderMarks(host:)` for every host not among `hosts` — the ones still signed in to.
    @discardableResult
    public func forgetReaderMarks(keeping hosts: Set<String>) -> Bool {
        forgetReaderMarks(of: .allBut(hosts))
    }

    /// **Over a file, its rows the pool does not hold are changed by the file** (`StoreOp`), with
    /// the next save — and asked for first, so a sweep with nothing left to take writes nothing.
    /// Where the file would not say, it is changed all the same.
    private func forgetReaderMarks(of hosts: StoreOp.Hosts) -> Bool {
        let gone = hosts.contains
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
            guard owesAsReader || note.saysReader else { continue }
            var plain = note.saysReader ? note.withoutReaderMarks() : note
            if owesAsReader {
                plain.refsDue = false
                stalled.remove(key)
            }
            notes[key] = plain
            shown = shown || !note.isPartOfTopic
            replies = replies || note.isPartOfTopic
        }
        var onFile = false
        if let disk {
            do {
                onFile = try disk.marked(hosts)
            } catch {
                Self.unread(error)
                onFile = true
            }
            if onFile {
                opsMade += 1
                let op = StoreOp(number: opsMade, kind: .forgetReaderMarks(hosts))
                opsOwed.append(op)
                opsRun.append(op)
            }
        }
        guard shown || replies || onFile else { return !told.isEmpty }
        changed(shown: shown, replies: replies)
        return true
    }

    /// `note`, read from the file, as every change made of the file's rows this run and not
    /// settled leaves it (`opsRun` above `opsSettled`), landed or not.
    private func unlanded(_ note: Note) -> Note {
        var note = note
        for op in opsRun where op.number > opsSettled {
            switch op.kind {
            case .forgetReaderMarks(let hosts):
                guard hosts.contains(note.key.host) else { continue }
                let owesAsReader = note.refsDue && Self.arrivedAsReader(note)
                if note.saysReader {
                    note = note.withoutReaderMarks()
                }
                if owesAsReader { note.refsDue = false }
            }
        }
        return note
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
        pool([key])
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
        // Every kept row of the file is in the pool once read, so the pool's are all of them.
        guard poolKept() else { return 0 }
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
        poolKept()
        return notes.values.reduce(0) { sum, note in
            sum + (note.kept && span.contains(note.postedAt) && (host == nil || note.key.host == host) ? 1 : 0)
        }
    }

    /// How many kept rows are marked gone from their source (#294): what `letGoneGo` leaves.
    public func keptGoneCount() -> Int {
        poolKept()
        return notes.values.reduce(0) { $0 + ($1.kept && $1.goneSince != nil ? 1 : 0) }
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
        pool([key])
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
    public func letGoneGo(markedBy cutoff: Date? = nil) async -> Int {
        await untilNoPutBack()
        // Over a file, its marked rows the pool does not hold go by key with the rest — or,
        // where the file would not say which they are, nothing goes.
        guard poolKept(), let unpooled = unpooled(.gone(markedBy: cutoff)) else { return 0 }
        let shown = shownByKept()
        let going = notes.values.filter { note in
            guard !note.kept, !shown.contains(note.key), let gone = note.goneSince else { return false }
            return cutoff.map { gone <= $0 } ?? true
        }
        let unheld = unpooled.filter { !shown.contains($0) }
        guard !going.isEmpty || !unheld.isEmpty else { return 0 }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        drop(unheld)
        strike(carried: Set(going.map(\.key) + unheld))
        changed(shown: going.contains { !$0.isPartOfTopic }, replies: going.contains { $0.isPartOfTopic })
        return going.count + unheld.count
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
        if passingThrough { return passed([key])[key] }
        pool([key])
        return notes[key]
    }

    /// The rows held among `keys`, by key — one hop for a caller that just landed a read and
    /// draws what the store made of it (#284), rather than what the wire said.
    public func notes(_ keys: [NoteKey]) -> [NoteKey: Note] {
        if passingThrough { return passed(keys) }
        pool(keys)
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
        poolRows(host: host, idPrefix: idPrefix)
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

/// The turns of the rows free to leave the pool, the earliest out first: a binary heap, so a
/// row freed by one that left takes its turn without the rest being moved (`letRowsLeave`).
private struct Turns {
    private var heap: [Int] = []

    var first: Int? { heap.first }

    init(_ turns: [Int]) {
        for turn in turns { push(turn) }
    }

    mutating func push(_ turn: Int) {
        heap.append(turn)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child] < heap[parent] else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Int? {
        guard let first = heap.first else { return nil }
        let last = heap.removeLast()
        guard !heap.isEmpty else { return first }
        heap[0] = last
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var least = parent
            if left < heap.count, heap[left] < heap[least] { least = left }
            if right < heap.count, heap[right] < heap[least] { least = right }
            guard least != parent else { return first }
            heap.swapAt(parent, least)
            parent = least
        }
    }
}

extension Array {
    /// `entry` put at `at`, where it stood before taken out first, and the list kept to `most`.
    fileprivate mutating func file(_ entry: Element, at: Int, was: Int?, most: Int) {
        if let was { remove(at: was) }
        insert(entry, at: at)
        if count > most { removeLast(count - most) }
    }
}
