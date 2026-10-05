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
    ///
    /// **No row comes in still owing a load** (`Note.refsDue`, #293). What another device had
    /// yet to ask its sources for is not this device's to ask: a store that arrived with every
    /// row marked would otherwise be a request a row to the person's own servers, set off by
    /// whoever made the package.
    public func replace(sources: [Source], notes arriving: [Note], said: [SourceProfile] = []) {
        let incoming = arriving.map { note in
            var settled = note
            settled.refsDue = false
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
    private func admit(_ incoming: [Note], exempt: Bool) {
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
        let incoming = admitted + admitted.compactMap(\.quotedNote)
        var moved = false
        var recounted = false
        var shown = false
        var replies = false
        for note in incoming {
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
                var merged = existing.filled(from: note, marksStand: outrun(note))
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
                shown = shown || !merged.isTopicReply
                replies = replies || merged.isTopicReply
                if kept { moved = true } else { recounted = true }
            } else {
                var note = note
                note.asked = .unsaid
                notes[key] = note
                arrival[key] = arrivals
                arrivals += 1
                shown = shown || !note.isTopicReply
                replies = replies || note.isTopicReply
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
            shown = shown || !refreshed.isTopicReply
            replies = replies || refreshed.isTopicReply
        }
        if moved { changed(shown: shown, replies: replies) }
        // The posts these quote, taken in as `ingest` takes them (#214): a quote read again may
        // name one this device has not held yet.
        let quoted = held.compactMap(\.quotedNote)
        let before = revision
        if !quoted.isEmpty { admit(quoted, exempt: true) }
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
            replies = replies || held.isTopicReply
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
    public func remove(host raw: String, keepingPosts: Bool = false) {
        let host = raw.lowercased()
        sourceList.removeAll { $0.host == host }
        saidByHost[host] = nil
        sourcesWatcher?(sourceList.map(\.host))
        if keepingPosts {
            changed(shown: false, replies: false)
            return
        }
        let shown = shownByKept()
        let going = notes.values.filter { $0.key.host == host && !$0.kept && !shown.contains($0.key) }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        changed(shown: true, replies: going.contains { $0.isTopicReply })
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
                replies = replies || note.isTopicReply
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
        changed(shown: going.contains { !$0.isTopicReply }, replies: going.contains { $0.isTopicReply })
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
        guard !going.isEmpty else { return 0 }
        for note in going {
            notes[note.key] = nil
            arrival[note.key] = nil
        }
        changed(shown: going.contains { !$0.isTopicReply }, replies: going.contains { $0.isTopicReply })
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

    /// Every item this device holds, newest first (#296): whatever brought it — a timeline, a
    /// search, a read under a tag, a thread opened, a quote — it is an item like any other, and
    /// every timeline whose rules let it through shows it. What it arrived through is its
    /// categories, and one that arrived through none is shown by no rule on a category.
    ///
    /// **Never a forum topic's kept reply** (`Note.isTopicReply`): that is a part of a topic and
    /// not an item, and is handed over by `replies()`.
    public func all() -> [Note] {
        let arrival = self.arrival
        return notes.values.filter { !$0.isTopicReply }
            .sorted { Self.storeOrder($0, $1, arrival) }
    }

    /// Every kept reply of a forum topic, newest first — what `all()` leaves out. For the count
    /// of what this device holds, which they are part of; nothing draws them but their topic,
    /// which reads its own through `held(host:idPrefix:)`.
    public func replies() -> [Note] {
        let arrival = self.arrival
        return notes.values.filter(\.isTopicReply)
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
    public func forget(_ key: NoteKey, at moment: Date = Date()) {
        guard var gone = notes[key] else { return }
        if gone.kept || shownByKept().contains(key) {
            guard gone.goneSince == nil else { return }
            gone.goneSince = moment
            notes[key] = gone
        } else {
            notes[key] = nil
            arrival[key] = nil
        }
        changed(shown: !gone.isTopicReply, replies: gone.isTopicReply)
    }

    /// Takes back what a signed-in reader's reads said they had done to `host`'s posts — boosted,
    /// favourited, bookmarked (#285) — so each row says what a post no such read brought says:
    /// nothing. For a sign-in that has ended, or been replaced by another account's: those words
    /// were that reader's, and left here they would be told to the next one, whose first press
    /// would undo an act they never made. The posts stay; what this device keeps of its own
    /// (`kept`) is untouched. Returns whether any row changed, so a caller writes only then.
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
        var shown = false
        var replies = false
        for (key, note) in notes where gone(key.host) {
            guard note.boosted != nil || note.favourited != nil || note.bookmarked != nil else { continue }
            notes[key] = note.withoutReaderMarks()
            shown = shown || !note.isTopicReply
            replies = replies || note.isTopicReply
        }
        guard shown || replies else { return false }
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
        changed(shown: !held.isTopicReply, replies: held.isTopicReply)
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
        changed(shown: keeping.contains { !$0.isTopicReply }, replies: keeping.contains { $0.isTopicReply })
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
        changed(shown: !held.isTopicReply, replies: held.isTopicReply)
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
        changed(shown: going.contains { !$0.isTopicReply }, replies: going.contains { $0.isTopicReply })
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
            replies = replies || note.isTopicReply
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
