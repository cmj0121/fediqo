import Foundation

/// Notes this device is holding, until it forgets them.
public actor ItemStore {
    private var sourceList: [Source] = []
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
    /// new in it. Starts at 0 for any store, a relaunched one included.
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
    private func changed(shown: Bool, aside: Bool) {
        revision += 1
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
    public init(sources: [Source], notes incoming: [Note]) {
        for source in sources where !sourceList.contains(where: { $0.host == source.host }) {
            sourceList.append(source)
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

    public func add(_ source: Source) {
        if sourceList.contains(where: { $0.host == source.host }) { return }
        sourceList.append(source)
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
    public func ingest(_ incoming: [Note]) {
        guard !incoming.isEmpty else { return }
        var moved = false
        var shown = false
        var aside = false
        for note in incoming where retention.map({ note.postedAt >= $0 }) ?? true {
            let key = note.key
            if let existing = notes[key] {
                let categories = existing.categories.union(note.categories)
                let holding = existing.holding.widened(by: note.holding)
                let listed = existing.listed.later(note.listed)
                // The same source handing the post over again is the source having it (#179):
                // a mark it once earned comes off.
                guard categories != existing.categories || holding != existing.holding
                        || listed != existing.listed || existing.goneSince != nil
                else { continue }
                var merged = existing
                merged.categories = categories
                merged.holding = holding
                merged.listed = listed
                merged.goneSince = nil
                notes[key] = merged
                shown = shown || holding == .arrived
                // Held aside before: it changed there, or it widened out of there.
                aside = aside || existing.holding == .aside
            } else {
                notes[key] = note
                arrival[key] = arrivals
                arrivals += 1
                shown = shown || note.holding == .arrived
                aside = aside || note.holding == .aside
            }
            moved = true
        }
        if moved { changed(shown: shown, aside: aside) }
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
        for note in incoming where note.source.host == host {
            guard let existing = notes[note.key] else { continue }
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
        return moved
    }

    /// Keeps a forum row's opening post as just read, with the row (#154). Only for rows held,
    /// and only while their source is: an opening that arrives for a row a Remove took away is
    /// not a way back in. Returns whether anything changed, so a caller saves only then.
    @discardableResult
    public func keep(_ openings: [NoteKey: ForumOpening]) -> Bool {
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
        // it onto the screen's rows.
        if moved { changed(shown: false, aside: aside) }
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
    /// are held for when they were written or boosted, not for where their timeline stands.
    public func missing(below key: NoteKey, in category: Category, writtenBy me: String? = nil) -> MissingPlace? {
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
        let postedBelow = timeline.filter { note in
            note.listed[category] == nil && note.postedAt <= marked.postedAt && note.boostedBy == nil
                && note.boosted != true && me.map { note.handle.caseInsensitiveCompare($0) != .orderedSame } ?? true
        }
        return MissingPlace(post: key, category: category, listed: listed, held: Set(postedBelow.map(\.key)), floor: nil)
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
    public func remove(host raw: String) {
        let host = raw.lowercased()
        sourceList.removeAll { $0.host == host }
        let aside = notes.contains { $0.key.host == host && $0.value.holding == .aside }
        notes = notes.filter { $0.key.host != host }
        arrival = arrival.filter { $0.key.host != host }
        changed(shown: true, aside: aside)
    }

    public func sources() -> [Source] {
        sourceList
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
        let asideBefore = notes.values.filter { $0.holding == .aside }.count
        notes = notes.filter { $0.value.postedAt >= retention }
        if notes.count != before {
            arrival = arrival.filter { notes[$0.key] != nil }
            changed(shown: true, aside: notes.values.filter { $0.holding == .aside }.count != asideBefore)
        }
        return before - notes.count
    }

    /// Everything this store holds, read in one hop — what a save writes to disk.
    ///
    /// **In the order the rows arrived, and taken at one moment.** A save does not draw anything,
    /// so it has no use for `all()`'s order; what it does need is the order the rows came in, so
    /// that the run reading them back knows which copy of a post arrived first (#114). And asking
    /// for the sources and the notes in two awaits would let an ingest or a remove land between
    /// them, writing notes whose source is gone. This is the counterpart of
    /// `init(sources:notes:)`. `revision` is the one this snapshot is of, read in the same hop.
    public func snapshot() -> (sources: [Source], notes: [Note], revision: Int) {
        let arrival = self.arrival
        let ordered = notes.values.sorted { (arrival[$0.key] ?? 0) < (arrival[$1.key] ?? 0) }
        return (sourceList, ordered, revision)
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
