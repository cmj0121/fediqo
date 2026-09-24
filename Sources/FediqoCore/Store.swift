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
    /// The oldest a note may be posted and still be held, or nil to keep everything forever —
    /// the default. The reader's drop by time (#7), held here so every way in obeys it.
    private(set) var retention: Date?
    /// Counts the changes to what a save writes: every call that may have changed a source or a
    /// note bumps it. A saver that remembers the revision it last wrote skips a save with nothing
    /// new in it. Starts at 0 for any store, a relaunched one included. **A count recounted is
    /// the one change it does not move** (#208): that is drawn now and written with the next.
    public private(set) var revision = 0
    /// Counts the changes to what `all()` draws, which is fewer than `revision`'s (#175): a
    /// source's boards restated, or a post held aside, is a change a save writes and no timeline
    /// shows. A reader that has adopted `all()` at this count has nothing new to adopt.
    public private(set) var drawn = 0
    /// Counts the changes to what `aside()` hands over (#176): a row held aside arriving, changing
    /// or going, or widening into one a timeline draws. A reader that has adopted `aside()` at
    /// this count has nothing new to adopt — so a landing only the timelines see does not make a
    /// search read every row held aside again.
    public private(set) var asideRevision = 0
    /// Everyone listening for a change. See `changes()`.
    private var listeners: [UUID: AsyncStream<Int>.Continuation] = [:]

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
    /// `shown` says whether it changed what `all()` draws too, and moves `drawn` where it did;
    /// `aside` the same of what `aside()` hands over, and `asideRevision`. **Both said at every
    /// call**, so a change added later has to answer for the rows held aside rather than fall
    /// silent about them by default.
    ///
    /// `kept` false is a change nothing need write down (#208): the screens are told and renewed,
    /// and the revision a saver reads stays where it is, so no save is made for it alone.
    private func changed(shown: Bool, aside: Bool, kept: Bool = true) {
        if kept { revision += 1 }
        if shown { drawn += 1 }
        if aside { asideRevision += 1 }
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
    public init(sources: [Source], notes incoming: [Note], said: [SourceProfile] = []) {
        for source in sources where !sourceList.contains(where: { $0.host == source.host }) {
            sourceList.append(source)
        }
        // Only of a source still here, and without a moment it was said is a word nothing can
        // draw as said then: the first `said(_:at:)` is what puts one in.
        let hosts = Set(sourceList.map(\.host))
        for profile in said where Self.isWord(profile) && hosts.contains(profile.host) {
            saidByHost[profile.host] = profile
        }
        notes = Dictionary(incoming.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
        // The order the rows are handed over is the order they arrived in: the run that wrote
        // this snapshot wrote them oldest first. A row named twice keeps the first mention's
        // place, the way `ingest` keeps a row's place when it is met again.
        for note in incoming where arrival[note.key] == nil {
            arrival[note.key] = arrivals
            arrivals += 1
        }
    }

    /// Everything here replaced by `sources` and `notes` in one hop — what a read back leaves
    /// (#247): the snapshot read off the package's store, adopted exactly as a relaunch would
    /// adopt it, with the same rules `init(sources:notes:)` keeps. The keep window stays the
    /// reader's and is applied to what comes in; every screen is told, and the watcher of the
    /// sources hears the new list.
    public func replace(sources: [Source], notes incoming: [Note], said: [SourceProfile] = []) {
        sourceList = []
        for source in sources where !sourceList.contains(where: { $0.host == source.host }) {
            sourceList.append(source)
        }
        let hosts = Set(sourceList.map(\.host))
        saidByHost = [:]
        for profile in said where Self.isWord(profile) && hosts.contains(profile.host) {
            saidByHost[profile.host] = profile
        }
        notes = Dictionary(
            incoming.filter(withinRetention).map { ($0.key, $0) }, uniquingKeysWith: { _, new in new }
        )
        arrival = [:]
        arrivals = 0
        for note in incoming where notes[note.key] != nil && arrival[note.key] == nil {
            arrival[note.key] = arrivals
            arrivals += 1
        }
        sourcesWatcher?(sourceList.map(\.host))
        changed(shown: true, aside: true)
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
        changed(shown: false, aside: false)
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
        changed(shown: false, aside: false)
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
        changed(shown: false, aside: false)
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
        changed(shown: false, aside: false)
    }

    /// `ingest(_:)`, only while `host` is still a source here — in the same step, so a source
    /// removed while its reads were on the wire does not get their posts back.
    public func ingest(_ incoming: [Note], ifSourceHere host: String) {
        let host = host.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return }
        ingest(incoming)
    }

    /// Takes in posts this device went and fetched for one place — a search, a thread, a
    /// hashtag — **held aside**: `note(_:)` hands each over and a save writes it, and `all()` never
    /// draws it (#175). `ingest(_:ifSourceHere:)` in every other respect, the one way such a post
    /// gets in, so no caller spells `Holding` for itself.
    ///
    /// A post already here as one a timeline brought stays one: holding only ever widens.
    public func hold(_ incoming: [Note], ifSourceHere host: String) {
        ingest(incoming.map { note in
            var aside = note
            aside.holding = .aside
            return aside
        }, ifSourceHere: host)
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
    /// **A post that quotes another brings the quoted post with it, held aside** (#214): opening
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
    private func admit(_ incoming: [Note], exempt: Bool) {
        guard !incoming.isEmpty else { return }
        let admitted = exempt ? incoming : incoming.filter(withinRetention)
        let incoming = admitted + admitted.compactMap(\.quotedNote)
        var moved = false
        var recounted = false
        var shown = false
        var aside = false
        for note in incoming {
            let key = note.key
            if let existing = notes[key] {
                let categories = existing.categories.union(note.categories)
                let holding = existing.holding.widened(by: note.holding)
                let listed = existing.listed.later(note.listed)
                // What the held copy never said, this one may (#208): a row kept before its
                // audience was written down takes it from the next timeline that brings it.
                var merged = existing.filled(from: note)
                // The same source handing the post over again is the source having it (#179):
                // a mark it once earned comes off.
                let kept = categories != existing.categories || holding != existing.holding
                    || listed != existing.listed || existing.goneSince != nil || merged != existing
                // The counts this copy states are the source's figure now (#208), and a later
                // figure than the one held.
                merged.counts = note.counts.filled(from: existing.counts)
                guard kept || merged.counts != existing.counts else { continue }
                merged.categories = categories
                merged.holding = holding
                merged.listed = listed
                merged.goneSince = nil
                notes[key] = merged
                shown = shown || holding == .arrived
                // Held aside before: it changed there, or it widened out of there.
                aside = aside || existing.holding == .aside
                if kept { moved = true } else { recounted = true }
            } else {
                notes[key] = note
                arrival[key] = arrivals
                arrivals += 1
                shown = shown || note.holding == .arrived
                aside = aside || note.holding == .aside
                moved = true
            }
        }
        // **A landing that only recounted is drawn and not written down** (#208). A timeline read
        // every minute moves some count on nearly every page, and a save for each would be the
        // every-minute write this function exists not to make; the next change that is kept
        // carries the figures to disk with it.
        if moved {
            changed(shown: shown, aside: aside)
        } else if recounted {
            changed(shown: shown, aside: aside, kept: false)
        }
    }

    /// Posts read again (#29), only while `host` is still a source here and only those stamped
    /// with it. Unlike `ingest`, a row already held is **replaced** by what the server says now —
    /// an edited post shows its new words — keeping the categories it arrived through and its
    /// booster (`Note.refreshed(over:)`). **A post not held is dropped**: reading one post again
    /// updates what is here, and brings in nothing the reader did not already have. Returns
    /// whether anything held really changed, so a caller adopts the store only then.
    @discardableResult
    public func refresh(_ incoming: [Note], ifSourceHere host: String) -> Bool {
        let host = host.lowercased()
        guard sourceList.contains(where: { $0.host == host }) else { return false }
        var moved = false
        var shown = false
        var aside = false
        var held: [Note] = []
        for note in incoming where note.source.host == host {
            guard let existing = notes[note.key] else { continue }
            held.append(note)
            // The same words read again are not a change (#175): a thread re-read with nothing
            // edited in it neither writes the store down again nor renews a screen.
            let refreshed = note.refreshed(over: existing)
            guard refreshed != existing else { continue }
            notes[note.key] = refreshed
            moved = true
            shown = shown || refreshed.holding == .arrived
            aside = aside || refreshed.holding == .aside
        }
        if moved { changed(shown: shown, aside: aside) }
        // The posts these quote, held aside as `ingest` holds them (#214): a quote read again may
        // name one this device has not held yet.
        let quoted = held.compactMap(\.quotedNote)
        let before = revision
        if !quoted.isEmpty { admit(quoted, exempt: true) }
        return moved || revision != before
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
        var aside = false
        for (key, opening) in openings {
            guard let held = notes[key], held.opening != opening,
                  sourceList.contains(where: { $0.host == key.host })
            else { continue }
            notes[key] = held.with(opening: opening)
            moved = true
            aside = aside || held.holding == .aside
        }
        // Written down, and not a change to what is drawn: the screen draws an opening from the
        // forum's own cache as it is read, and replacing every row for each one kept as the reader
        // scrolls is what #154 set out not to do. Only a later change to what All shows carries
        // it onto the screen's rows — unless the caller says the screen draws it from here.
        if moved { changed(shown: shown, aside: aside) }
        return moved
    }

    /// The anchor a timeline is read on from (#201): the newest id a read of `category` from
    /// `host` listed a post under, of a post its source has not said is gone. A post the reader
    /// wrote, or one held aside, was listed by no read, and is never it.
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
            $0.source.host == host && $0.holding == .arrived && $0.categories.contains(category)
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
        if moved { changed(shown: true, aside: false) }
    }

    /// Where posts may be missing below `key` in `category`, as reading down from it needs it
    /// (#204): the id to read before, and what is held of that timeline below it. Nothing where
    /// `key` carries no such mark, or neither the mark nor that timeline names an id to read before.
    ///
    /// **By listed ids alone** wherever this timeline listed a post held below: the posts it
    /// listed under an id below the mark's, as themselves and not as boosts. Only where it listed
    /// none of them — a timeline held from before listings were kept (#201) — is below read off
    /// when each was posted, and then never of a post `me` wrote or boosted, nor any boost: those
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
            $0.key != key && $0.source.host == key.host && $0.holding == .arrived && $0.categories.contains(category)
        }
        let listedBelow = timeline.filter { note in
            note.listed[category].map { StatusID.later(listed, than: $0) } == true
        }
        if let floor = listedBelow.compactMap({ $0.listed[category] }).max(by: { StatusID.later($1, than: $0) }) {
            return MissingPlace(
                post: key, category: category, listed: listed,
                held: Set(listedBelow.filter { $0.boostedBy == nil }.map(\.key)), floor: floor
            )
        }
        let postedBelow = timeline.filter { $0.listed[category] == nil && $0.postedAt <= marked.postedAt }
        if !postedBelow.isEmpty, signedIn, me == nil { return nil }
        let held = postedBelow.filter { note in
            note.boostedBy == nil && note.boosted != true
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
    /// **Onto a post held**: the oldest the read brought that this store took in as itself, and
    /// back onto `key` where it took in none — one refused as older than what is kept, or only
    /// boosts — so the place is never left unsaid.
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
            .filter { $0.boostedBy == nil && $0.listed[category] != nil && notes[$0.key] != nil }
            .min { StatusID.later($1.listed[category]!, than: $0.listed[category]!) }?.key ?? key
        let place: TimelineGap? = switch down.end {
        case .met: nil
        case .further(let from): TimelineGap(.mayBeMissing, in: category, from: from)
        case .settled: TimelineGap(.settled, in: category, since: moment)
        }
        // One of each kind per timeline per post: a place said there before gives way to this one.
        if let place { notes[carrier]?.gaps.update(with: place) }
        changed(shown: true, aside: false)
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
    public func remove(host raw: String, keepingPosts: Bool = false) {
        let host = raw.lowercased()
        sourceList.removeAll { $0.host == host }
        saidByHost[host] = nil
        sourcesWatcher?(sourceList.map(\.host))
        if keepingPosts {
            changed(shown: false, aside: false)
            return
        }
        let aside = notes.contains { $0.key.host == host && $0.value.holding == .aside }
        notes = notes.filter { $0.key.host != host }
        arrival = arrival.filter { $0.key.host != host }
        changed(shown: true, aside: aside)
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
        changed(shown: false, aside: false, kept: !sameWord)
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
        changed(shown: false, aside: false)
    }

    /// Keeps only the latest `months` months as of `now` from here on, or everything where
    /// `months` is nil — forever, the default (#7). Drops what is already older, and returns how
    /// many notes went, so a caller writes and redraws only when something did. Sources are
    /// untouched: a source with nothing left inside the window stays joined.
    @discardableResult
    public func setRetention(months: Int?, from now: Date = Date(), calendar: Calendar = .current) -> Int {
        retention = KeepPolicy.cutoff(keepingMonths: months, from: now, calendar: calendar)
        guard let retention else { return 0 }
        let before = notes.count
        let asideBefore = Set(notes.filter { $0.value.holding == .aside }.keys)
        // A quoted post a kept post quotes stays, as `ingest` keeps it (#214) — held aside from
        // here, where a timeline had brought it: the timeline's reach has passed it, the quote's
        // has not.
        let quoted = Set(notes.values.filter { $0.postedAt >= retention }.compactMap(\.quotedKey))
        var demoted = false
        var kept: [NoteKey: Note] = [:]
        for (key, note) in notes {
            if note.postedAt >= retention {
                kept[key] = note
            } else if quoted.contains(key) {
                var aside = note
                if aside.holding != .aside {
                    aside.holding = .aside
                    demoted = true
                }
                kept[key] = aside
            }
        }
        notes = kept
        if notes.count != before || demoted {
            arrival = arrival.filter { notes[$0.key] != nil }
            // Which rows are aside, not how many: a cut and a demotion in one pass can leave the
            // count where it was while the rows themselves changed.
            changed(shown: true, aside: Set(notes.filter { $0.value.holding == .aside }.keys) != asideBefore)
        }
        return before - notes.count
    }

    /// How many rows were posted inside `span` and, where `host` is given, came through that host
    /// — arrived and aside alike (#248). What a press to let a span go would take, so the question
    /// before it names the true count.
    public func count(span: Range<Date>, host raw: String? = nil) -> Int {
        let host = raw?.lowercased()
        return notes.values.reduce(0) { $0 + (Self.inside(span, host: host, $1) ? 1 : 0) }
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
    @discardableResult
    public func letGo(span: Range<Date>, host raw: String? = nil) -> Int {
        let host = raw?.lowercased()
        let going = notes.values.filter { Self.inside(span, host: host, $0) }
        guard !going.isEmpty else { return 0 }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        changed(shown: going.contains { $0.holding == .arrived }, aside: going.contains { $0.holding == .aside })
        return going.count
    }

    /// Whether `note` is what `letGo(span:host:)` reaches: posted inside `span`, and from `host`
    /// where one is named.
    private static func inside(_ span: Range<Date>, host: String?, _ note: Note) -> Bool {
        span.contains(note.postedAt) && (host == nil || note.source.host == host)
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

    /// Every row a timeline may show, newest first — and **never one held aside** (#175).
    ///
    /// This device can hold a post no timeline shows: one found by a search, one read inside a
    /// thread, one brought under a hashtag. It is here, `note(_:)` hands it over, and a save
    /// writes it; what it is not is a row All grew by. Everything that feeds All reads this, so
    /// the distinction is made once and honoured everywhere rather than remembered by each caller.
    public func all() -> [Note] {
        let arrival = self.arrival
        return notes.values.filter { $0.holding == .arrived }
            .sorted { Self.storeOrder($0, $1, arrival) }
    }

    /// Every row held aside, newest first — what `all()` leaves out, and nothing it draws.
    ///
    /// **For the one place that reads past a timeline** (#176): a search finds what this device
    /// holds, and what a search brought back is held aside so All does not grow by it. Nothing
    /// else draws these; a search still passes them through the rules of the timeline in front.
    public func aside() -> [Note] {
        let arrival = self.arrival
        return notes.values.filter { $0.holding == .aside }
            .sorted { Self.storeOrder($0, $1, arrival) }
    }

    /// Lets go of one row — a post its author took back (#109). Silent where it is not held.
    ///
    /// **One row and never a host's worth.** `remove(host:)` is the reader letting go of a server;
    /// this is a server saying one post no longer exists, and the other copies of it through other
    /// sources are theirs to say about.
    public func forget(_ key: NoteKey) {
        guard let gone = notes.removeValue(forKey: key) else { return }
        changed(shown: gone.holding == .arrived, aside: gone.holding == .aside)
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
        changed(shown: held.holding == .arrived, aside: held.holding == .aside)
        return true
    }

    /// How many rows are marked gone from their source (#179) — what a press would let go.
    public func goneCount() -> Int {
        notes.values.reduce(0) { $0 + ($1.goneSince == nil ? 0 : 1) }
    }

    /// Lets go of every row marked gone from its source at or before `cutoff`, or of every marked
    /// row where `cutoff` is nil — the reader's press (#179). Returns how many went.
    ///
    /// **Marked rows and nothing else.** A row that merely did not arrive again carries no mark,
    /// so no wait and no press here can reach it.
    @discardableResult
    public func letGoneGo(markedBy cutoff: Date? = nil) -> Int {
        let going = notes.values.filter { note in
            guard let gone = note.goneSince else { return false }
            return cutoff.map { gone <= $0 } ?? true
        }
        guard !going.isEmpty else { return 0 }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        changed(shown: going.contains { $0.holding == .arrived }, aside: going.contains { $0.holding == .aside })
        return going.count
    }

    /// How many places say their source no longer has what lay there (#204) — what a press would
    /// let go beside the posts `goneCount` counts.
    public func settledCount() -> Int {
        // A post marked gone takes its places with it, and is counted as the post it is.
        notes.values.filter { $0.goneSince == nil }.reduce(0) { $0 + $1.gaps.filter { $0.kind == .settled }.count }
    }

    /// Lets go of every place settled at or before `cutoff`, or of every one where `cutoff` is nil
    /// — `letGoneGo`'s wait and press, for the places a read down settled (#204). The mark goes
    /// and the post it sits by stays. Returns how many went.
    @discardableResult
    public func letSettledGo(markedBy cutoff: Date? = nil) -> Int {
        var went = 0
        var aside = false
        for (key, note) in notes {
            let going = note.gaps.filter { gap in
                guard gap.kind == .settled else { return false }
                guard let cutoff, let since = gap.since else { return true }
                return since <= cutoff
            }
            guard !going.isEmpty else { continue }
            notes[key]?.gaps.subtract(going)
            went += going.count
            aside = aside || note.holding == .aside
        }
        if went > 0 { changed(shown: true, aside: aside) }
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

    /// Every row held from `host` whose id starts `idPrefix` — **aside ones included**, which is
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
