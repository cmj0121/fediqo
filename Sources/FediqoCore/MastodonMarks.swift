import Foundation

// What the reader bookmarked and favourited at a Mastodon, read as categories of it (#317).
//
// **Listed by when each was marked, and paged by the mark.** A Mastodon hands its bookmarks and
// favourites over newest mark first, and names the next stretch in its `Link` header by the id it
// gave the mark — a number of its own, counted from one, that is no post's id (asked of a real
// 4.6: `MastodonMarksCaptures`). A post published last year and bookmarked this morning stands
// first. So nothing here is read on by a post's id: the timeline machinery for what is listed by
// publish time (`MastodonReadOn`) would step `min_id` over marks and compare them with posts, and
// is not used.
//
// **Each post is listed under the span of marks its stretch held** (`MarkSpan`): from the mark
// that ends the stretch — the `max_id` its `Link` names for the next — up to the mark that heads
// it, the `min_id` its `Link` names for the one before. The post's own mark lies between the two.
// The list's last stretch names no next, and its floor is `end`, older than any mark. Read again,
// a post keeps what both spans say of it (`MarkSpan.merged`): their overlap, or, where its mark
// moved — marked again elsewhere — the newer.
//
// **What a read covers decides what it does not bring back.** A stretch asked below a mark `C`
// that names `N` as next holds every mark from `N` up to below `C` that the source still has; a
// read from the newest down holds every mark above where it stopped. So a post held through the
// category whose span lies wholly inside what a read covered, and that the read did not bring, is
// no longer marked — from Fediqo or any other app — and leaves the category
// (`MarkCover.contains`). A post whose span reaches outside is left as it is. Only the category
// goes: the post itself stays while anything else holds it, as every row does.
//
// **A refresh walks down from the newest mark**, a stretch at a time. The wait's walk stops at the
// first stretch that brings nothing but posts already held there — where it meets what this
// device holds — and at `bound`; a reload the person asks for walks on until it has passed the
// lowest mark held, so that every post held is decided, up to `thoroughBound`. One that stops at
// its bound having met nothing held — more were marked since than it reads — leaves a place where
// marks may be missing, said on the lowest post it brought with the mark to read on below
// (`TimelineGap.mayBeMissing`), which reading down from fills (`readDown`); a walk that passes
// every mark held settles every such place.
//
// **Reading on reaches the oldest mark**: the stretch below a mark, one at a time, until the
// source names no next. Where it goes next is the source's own next (`older` hands it back), not
// what landed: a stretch whose posts the keep window refuses, or one that is empty and names a
// next all the same, still moves it on. A post met twice is one row.
//
// **A read that fails anywhere lands nothing**, and **a read outrun by a later one decides
// nothing** (`ItemStore.beginMarks`): one sent before another landed says nothing of what that
// one found, and brings back no post it found no longer marked.

/// Where a post's mark lies in the source's own numbering of marks (#317): at or above `floor`, and
/// at or below `ceiling` where the source said one. Written into `Note.listed` as `floor` or
/// `floor:ceiling`.
public struct MarkSpan: Hashable, Sendable {
    public let floor: String
    public let ceiling: String?

    public init(floor: String, ceiling: String? = nil) {
        self.floor = floor
        self.ceiling = ceiling
    }

    /// The span `listed` writes, or nothing for nothing.
    public init?(listed: String?) {
        guard let listed, !listed.isEmpty else { return nil }
        let parts = listed.split(separator: ":", maxSplits: 1).map(String.init)
        self.init(floor: parts[0], ceiling: parts.count == 2 ? parts[1] : nil)
    }

    /// As `Note.listed` holds it.
    public var listed: String { ceiling.map { "\(floor):\($0)" } ?? floor }

    /// The lowest floor of the spans `listed` writes — where a walk has passed every post held,
    /// and where reading on starts below. Nothing for none.
    public static func lowestFloor(of listed: some Sequence<String>) -> String? {
        listed.compactMap { MarkSpan(listed: $0)?.floor }.min { StatusID.later($1, than: $0) }
    }

    /// What this span and a later read's `newer` say of one post together: where they overlap,
    /// the overlap — each is true of its mark — and where they do not, its mark moved (it was
    /// marked again) and `newer` is where it is now.
    public func merged(with newer: MarkSpan) -> MarkSpan {
        let floor = StatusID.later(newer.floor, than: self.floor) ? newer.floor : self.floor
        let ceiling: String? = switch (self.ceiling, newer.ceiling) {
        case (let a?, let b?): StatusID.later(a, than: b) ? b : a
        case (let a?, nil): a
        case (nil, let b): b
        }
        if let ceiling, StatusID.later(floor, than: ceiling) { return newer }
        return MarkSpan(floor: floor, ceiling: ceiling)
    }
}

/// The marks a read went through (#317): every mark at or above `low` and below `high` — or with no
/// end above, for a read from the newest — that the source still has.
public struct MarkCover: Hashable, Sendable {
    public let low: String
    public let high: String?

    public init(low: String, high: String? = nil) {
        self.low = low
        self.high = high
    }

    /// Whether a post held under `span` has its mark inside: a post that is, and was not brought,
    /// is no longer marked. A span that says no ceiling is inside only a cover with no end above.
    public func contains(_ span: MarkSpan?) -> Bool {
        guard let span, !StatusID.later(low, than: span.floor) else { return false }
        guard let high else { return true }
        return span.ceiling.map { StatusID.later(high, than: $0) } ?? false
    }
}

/// What reading one category of marks brought (#317), ready to land.
public struct MarksRead: Sendable, Equatable {
    /// Every post the read met, once each, carrying the category and the span it is listed under.
    public var notes: [Note]
    /// What it went through.
    public var covered: MarkCover
    /// Whether it went through every mark held — down to the end, or past the lowest held — so
    /// that no place it left earlier can still be missing anything.
    public var whole = false
    /// Whether it met a post already held through the category.
    public var connected = false
    /// A place it leaves where marks may be missing: the post it is said on, and the mark to read
    /// below.
    public var hole: Hole?
    /// The mark a place where marks may be missing was read down from, by this read: it goes where
    /// the read met what is held or reached the end, and moves down to `covered.low` otherwise.
    public var fills: String?
    /// When it was begun among the reads of its category (`ItemStore.beginMarks`).
    public var begun = 0

    public struct Hole: Sendable, Equatable {
        public let post: NoteKey
        public let from: String

        public init(post: NoteKey, from: String) {
            self.post = post
            self.from = from
        }
    }

    public init(
        notes: [Note] = [], covered: MarkCover, whole: Bool = false, connected: Bool = false, hole: Hole? = nil,
        fills: String? = nil, begun: Int = 0
    ) {
        self.notes = notes
        self.covered = covered
        self.whole = whole
        self.connected = connected
        self.hole = hole
        self.fills = fills
        self.begun = begun
    }

    /// Whether it went down to the list's end.
    public var reachedEnd: Bool { covered.low == MastodonMarks.end }
}

/// A source that hands a mark's next stretch back as the one just read, or one no older: it is
/// not paging, and would be read for ever.
public struct MarksNotPaging: Error, Equatable {}

/// The reader's bookmarks and favourites at one signed-in Mastodon, read into the store.
public struct MastodonMarks: Sendable {
    /// How many stretches the wait's walk reads at most.
    public static let bound = 5
    /// How many a reload the person asked for reads at most, to pass every mark held: a thousand
    /// marks at forty a stretch.
    public static let thoroughBound = 25
    /// How many posts one stretch asks for.
    public static let limit = 40
    /// The floor of a post on the list's last stretch: older than every mark there is. A
    /// Mastodon counts its marks from one.
    public static let end = "0"

    private let door: MastodonAuthorized
    private let store: ItemStore
    /// How many posts each stretch asks for, and how many stretches a walk reads at most, the
    /// wait's and a reload's: `limit` and the bounds, but where a check asks as a person pages.
    private let length: Int
    private let reach: Int
    private let thoroughReach: Int

    public init(door: MastodonAuthorized, store: ItemStore) {
        self.init(door: door, store: store, length: Self.limit, reach: Self.bound, thoroughReach: Self.thoroughBound)
    }

    init(door: MastodonAuthorized, store: ItemStore, length: Int, reach: Int, thoroughReach: Int? = nil) {
        self.door = door
        self.store = store
        self.length = max(1, length)
        self.reach = max(1, reach)
        self.thoroughReach = max(1, thoroughReach ?? reach)
    }

    private var host: String { door.token.host }

    /// Where a category of marks is asked. Nothing for any other category.
    static func path(of category: Category) -> String? {
        category.markWord.map { "/api/v1/\($0)" }
    }

    /// `category` read from its newest mark down, and landed in one step — the posts met carrying
    /// it, and the posts it shows are no longer marked leaving it. `thorough` is a reload the
    /// person asked for, which walks on past every mark held; the wait's stops where it meets
    /// what is held. Throws what a stretch threw, and then nothing has landed.
    public func read(_ category: Category, thorough: Bool = true) async throws {
        guard let source = await source(), let path = Self.path(of: category) else { return }
        let begun = await store.beginMarks()
        let held = await store.marked(host: host, category: category)
        var read = try await Self.walk(
            category, holding: held, bound: thorough ? thoroughReach : reach, untilMet: !thorough
        ) { cursor in
            try await stretch(path, source: source, category: category, below: cursor)
        }
        read.begun = begun
        try Task.checkCancellation()
        await store.land(read, of: category, ifSourceHere: host, membersPooled: true)
    }

    /// The stretch of `category` below the mark `cursor`: the next of a listing read toward its
    /// end, landed with what it covers. Hands back where the next stretch begins — nothing at the
    /// list's end — **whatever landed**, so a listing reading on is never held at one mark.
    public func older(_ category: Category, than cursor: String) async throws -> String? {
        guard cursor != Self.end, let source = await source(), let path = Self.path(of: category) else { return nil }
        var held = await store.marked(host: host, category: category)
        let (read, next) = try await step(category, path, source, below: cursor, holding: &held)
        await store.land(read, of: category, ifSourceHere: host, membersPooled: true)
        return next
    }

    /// A place where marks may be missing, said on `key`, read down from: a stretch at a time
    /// from the mark it keeps, at most `bound`, until a stretch meets what is held or the list
    /// ends — and the place goes — or the bound is reached, and it moves down to where the last
    /// stretch stopped. Nothing where `key` says no such place. Throws what a stretch threw.
    public func readDown(_ category: Category, below key: NoteKey) async throws {
        guard let source = await source(), let path = Self.path(of: category),
              var cursor = await store.markHole(key, in: category)
        else { return }
        var held = await store.marked(host: host, category: category)
        for _ in 0..<reach {
            var (read, next) = try await step(category, path, source, below: cursor, holding: &held)
            read.fills = cursor
            await store.land(read, of: category, ifSourceHere: host, membersPooled: true)
            guard !read.connected, let next else { return }
            cursor = next
        }
    }

    /// One stretch asked below `cursor` and made ready to land — its place among the reads of its
    /// category, what it covers, whether it met a post `held` names — and the mark its next
    /// begins below, nothing at the end. `held` grows by what it brought, so the next stretch of
    /// the same errand counts those as held without asking the store again.
    private func step(
        _ category: Category, _ path: String, _ source: Source, below cursor: String, holding held: inout [NoteKey: String]
    ) async throws -> (read: MarksRead, next: String?) {
        let begun = await store.beginMarks()
        let page = try await stretch(path, source: source, category: category, below: cursor)
        try Self.pages(below: cursor, to: page.next)
        try Task.checkCancellation()
        let read = Self.below(cursor, page, category: category, held: held, begun: begun)
        for note in read.notes {
            if let listed = note.listed[category] { held[note.key] = listed }
        }
        return (read, page.next)
    }

    /// Throws where a source names as next a mark no older than the one it was asked below: it
    /// is not paging, and would be read for ever.
    static func pages(below cursor: String?, to next: String?) throws {
        if let next, let cursor, !StatusID.later(cursor, than: next) { throw MarksNotPaging() }
    }

    /// One stretch read below `cursor`, as it lands: what it covers, and whether it met a post
    /// `held` names.
    static func below(_ cursor: String, _ page: Stretch, category: Category, held: [NoteKey: String], begun: Int) -> MarksRead {
        let notes = landing(page, category: category)
        return MarksRead(
            notes: notes, covered: MarkCover(low: page.next ?? end, high: cursor),
            whole: page.next == nil, connected: page.listed.contains { held[$0.note.key] != nil }, begun: begun
        )
    }

    /// One stretch: the posts the source listed, the mark its next stretch begins below —
    /// nothing at the end — and the mark that heads it, where the source said one.
    struct Stretch: Sendable {
        var listed: [Listed]
        var next: String?
        var head: String?
    }

    /// The walk a read makes from the newest mark, asked a stretch at a time through `stretch`
    /// (the stretch below a mark, or the newest for nothing): at least one, at most `bound`, and
    /// no further than past the lowest mark `held` names. `untilMet` is the wait's walk, which
    /// stops at the first stretch bringing only posts `held` names. `held` is what the store
    /// holds of the category, by the span each post is listed under.
    static func walk(
        _ category: Category, holding held: [NoteKey: String], bound: Int = bound, untilMet: Bool = false,
        stretch: (String?) async throws -> Stretch
    ) async throws -> MarksRead {
        let lowest = MarkSpan.lowestFloor(of: held.values)
        var met: [NoteKey: Note] = [:]
        var order: [NoteKey] = []
        var cursor: String?
        var connected = false
        var last: NoteKey?
        func read(_ low: String, whole: Bool = false, hole: MarksRead.Hole? = nil) -> MarksRead {
            MarksRead(
                notes: order.compactMap { met[$0] }, covered: MarkCover(low: low), whole: whole, connected: connected,
                hole: hole
            )
        }
        for _ in 0..<max(1, bound) {
            let page = try await stretch(cursor)
            try pages(below: cursor, to: page.next)
            for note in landing(page, category: category) {
                if let was = met[note.key] {
                    // Met twice — the list moved under the walk: one row, what both said of it.
                    var kept = was
                    kept.listed = was.listed.later(note.listed)
                    met[note.key] = kept
                } else {
                    met[note.key] = note
                    order.append(note.key)
                }
            }
            let known = page.listed.filter { held[$0.note.key] != nil }
            if !known.isEmpty { connected = true }
            if let lowest = page.listed.last?.note.key { last = lowest }
            guard let next = page.next else { return read(end, whole: true) }
            cursor = next
            // Every post held is decided once the walk has passed its floor.
            if lowest.map({ !StatusID.later(next, than: $0) }) ?? true { return read(next, whole: true) }
            // The wait's walk has met what is held, and brought nothing it did not hold.
            if untilMet, !page.listed.isEmpty, known.count == page.listed.count { return read(next) }
        }
        let low = cursor ?? end
        // More were marked since than this walk reads, and it met nothing held: what lies between
        // is said, on the lowest post it brought, and read down from there.
        let hole = !connected && !held.isEmpty ? last.map { MarksRead.Hole(post: $0, from: low) } : nil
        return read(low, hole: hole)
    }

    /// What one stretch lands: each post it listed, through the category and under the span of
    /// marks the stretch held, and whatever it carried — the post a boost boosts — through nothing.
    static func landing(_ page: Stretch, category: Category) -> [Note] {
        let span = MarkSpan(floor: page.next ?? end, ceiling: page.head)
        return page.listed.flatMap { listed -> [Note] in
            var note = listed.note
            note.listed = [category: span.listed]
            return [note] + listed.carried
        }
    }

    private func stretch(_ path: String, source: Source, category: Category, below cursor: String?) async throws -> Stretch {
        let sent = ReadMoment.now()
        let (body, link) = try await door.getLinked(
            path: path,
            query: [URLQueryItem(name: "limit", value: String(length))] + (try MastodonPage.older(than: cursor))
        )
        let listed = try MastodonJSON.decoder.decode([StatusDTO].self, from: body).map {
            $0.listed(source: source, category: category, sent: sent)
        }
        return Stretch(listed: listed, next: try MastodonLink.next(in: link), head: MastodonLink.previous(in: link))
    }

    private func source() async -> Source? {
        await store.sources().first { $0.host == host }
    }
}
