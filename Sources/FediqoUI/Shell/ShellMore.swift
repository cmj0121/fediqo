import FediqoCore
import Foundation
import SwiftUI

// Listing a timeline asks for more as you go (#87).
//
// `r` asks for the newest of the timeline in front. Reading toward its end is a different ask:
// the next, older stretch of each read the timeline draws from — a Mastodon timeline before the
// oldest post held from it, a forum's front page or board one page further on. It runs as its own
// kind beside `r` and a thread (#175), lands through `ItemStore.ingest` like every timeline read,
// and the listing renews from the store: older rows arrive below the place being read, so the
// selected post stays selected and nothing is scrolled.
//
// **Before the oldest post held, because no hole lies above it unsaid** (#201). A read used to
// bring a timeline's newest stretch alone, so after a relaunch the oldest post held lay past a
// hole between that stretch and what an earlier run held, and asking before it skipped the hole.
// Every read of a Mastodon timeline now reads on from the newest post held of it: what lay
// between is read, or said at its place where it could not be (`ShellReadOn.swift`). So this
// run's newest stretch reaches down, unbroken but for what is said, to the oldest post held, and
// that is where it reads on from. Asking before a post further up instead would ask again for
// pages this device holds, and bring nothing new below a reader already at the end.
//
// **What a stretch does not carry says nothing.** A post missing from a page merely did not
// arrive on it; nothing here drops a row or marks one (#179 is what a post its source really
// deleted becomes, and only a read of that one post says so).
//
// **Asked once, and not past the end.** A Mastodon stretch is asked before one post once: a page
// that brought nothing older leaves the same oldest post, and the same ask is not made again. A
// forum's stretch ends at a page with no thread on it, or at a page the same as the one before —
// which is what a Discuz! answers past its last page, the last page again. **Not at a page this
// device already holds**: what an earlier run read is still here, and ending there would stop
// every later run's listing at its second page.
//
// **Never the same forum twice at once.** A stranger's forum is asked one page after another; so
// while `r` or the wait is reading, the forums are left out of an ask for more, and the wait does
// not start while one is out.

/// One read of one source a listing can ask the next stretch of (#87).
struct Stretch: Hashable, Sendable {
    let host: String
    /// The timeline or board it reads, or nothing for a forum's front page.
    let category: FediqoCore.Category?
}

/// Where each stretch has got to. Held by the reload, for the life of the run.
struct ShellStretches {
    /// Each Mastodon stretch's posts it has been asked to read before.
    private var asked: [Stretch: Set<String>] = [:]
    /// How many pages past its first each forum stretch has read.
    private var further: [Stretch: Int] = [:]
    /// The threads each forum stretch's last page carried, to tell a page repeated past the end.
    private var lastPage: [Stretch: Set<NoteKey>] = [:]
    /// Forum stretches read to their end.
    private var ended: Set<Stretch> = []
    /// Counts the restarts. A forum page read under an earlier one is about pages that have since
    /// moved along, and is dropped rather than recorded over the restart.
    private(set) var generation = 0

    func hasAsked(_ stretch: Stretch, before id: String) -> Bool {
        asked[stretch]?.contains(id) == true
    }

    mutating func asked(_ stretch: Stretch, before id: String) {
        asked[stretch, default: []].insert(id)
    }

    /// The forum page past its first this stretch asks next — 1 is the second page — or nothing
    /// where it has been read to its end.
    func next(_ stretch: Stretch) -> Int? {
        ended.contains(stretch) ? nil : (further[stretch] ?? 0) + 1
    }

    /// One forum page read under `generation`, carrying `threads`: the end where it carried none
    /// or the same as the page before it, and the page after it otherwise.
    mutating func read(_ stretch: Stretch, page: Int, threads: Set<NoteKey>, generation: Int) {
        guard generation == self.generation else { return }
        if threads.isEmpty || threads == lastPage[stretch] {
            ended.insert(stretch)
        } else {
            further[stretch] = page
            lastPage[stretch] = threads
        }
    }

    /// A forum's newest page was read again, which moves every page under it along. The Mastodon
    /// half is kept: an id says exactly what is older than it, whatever arrived since.
    mutating func restart() {
        further = [:]
        lastPage = [:]
        ended = []
        generation += 1
    }
}

extension ShellReload {
    /// One stretch due to be asked, and from where.
    struct Due: Sendable {
        let stretch: Stretch
        let source: Source
        let cursor: Cursor

        enum Cursor: Sendable {
            /// A Mastodon timeline, before this post.
            case before(String)
            /// A forum, this many pages past its first.
            case page(Int)
        }
    }

    /// The next stretch of `query`'s reads, from its own sources only — the timeline in front,
    /// neared its end. In the background: nothing waits on it, and a stretch already asked, or at
    /// its source's end, is not asked. Nothing while the timeline editor is up, or while another
    /// ask for more is on its way; and no forum while `r`, the wait, or an open thread's renewal
    /// is reading (#198).
    func more(_ query: TimelineQuery, in session: ShellSession) async {
        guard !asking.contains(.more), session.editing == nil else { return }
        let readingNewest = !asking.isDisjoint(with: [.timeline, .held, .renew])
        let due = Self.due(query, in: session, stretches: stretches)
            .filter { !readingNewest || $0.source.kind == .mastodon }
        guard !due.isEmpty else { return }
        let hosts = due.map(\.stretch.host).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        await run(.more) {
            var unread: Set<String> = []
            await withTaskGroup(of: (String, Bool).self) { group in
                // One source's stretches one after another — a stranger's forum is not asked in
                // parallel — and the sources beside each other, each landing as it answers.
                for host in hosts {
                    let mine = due.filter { $0.stretch.host == host }
                    group.addTask { (host, await self.more(mine, in: session)) }
                }
                for await (host, read) in group {
                    if !read { unread.insert(host) }
                    await session.reloadFromStore()
                }
            }
            guard !Task.isCancelled else { return }
            self.record(hosts.filter(unread.contains), for: .more)
        }
    }

    /// Every stretch of `query` there is a next of now.
    static func due(_ query: TimelineQuery, in session: ShellSession, stretches: ShellStretches) -> [Due] {
        let sources = session.sources
        let asks = CompiledTimeline(query.definition(among: session.written), sources: sources).sourcesToAsk()
        return asks.flatMap { ask -> [Due] in
            guard let source = sources.first(where: { $0.host == ask.host }), SourceJoin.reads(source.kind) else {
                return []
            }
            let signedIn = source.kind == .mastodon && session.mastodon.isSignedIn(host: source.host)
            return Self.stretches(of: source, for: ask.categories, signedIn: signedIn).compactMap { stretch in
                switch source.kind {
                case .mastodon:
                    guard let category = stretch.category,
                          let oldest = Self.oldest(category, of: source.host, in: session.notes),
                          !stretches.hasAsked(stretch, before: oldest)
                    else { return nil }
                    return Due(stretch: stretch, source: source, cursor: .before(oldest))
                case .discuz, .discourse:
                    return stretches.next(stretch).map { Due(stretch: stretch, source: source, cursor: .page($0)) }
                case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
                     .unknown:
                    return nil
                }
            }
        }
    }

    /// The reads of `source` a listing continues: what `r` reads of it, less its Trends — a
    /// ranking is not a stretch of time, and has no next. Home and lists only where signed in.
    static func stretches(of source: Source, for categories: Set<FediqoCore.Category>?, signedIn: Bool) -> [Stretch] {
        let host = source.host
        switch source.kind {
        case .mastodon:
            var reads: [FediqoCore.Category] = [.public]
            if signedIn { reads += [.home] + source.lists.map { .list(id: $0.id) } }
            return reads.filter { categories?.contains($0) ?? true }.map { Stretch(host: host, category: $0) }
        case .discuz:
            if categories == nil, source.boards.isEmpty { return [Stretch(host: host, category: nil)] }
            return source.boards.map { FediqoCore.Category.board(id: String($0.fid)) }
                .filter { categories?.contains($0) ?? true }
                .map { Stretch(host: host, category: $0) }
        case .discourse:
            return categories == nil ? [Stretch(host: host, category: nil)] : []
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial, .unknown:
            return []
        }
    }

    /// The server id of the oldest post held from `host` through `category`: a Mastodon id grows
    /// with time, and a longer one is a later one.
    static func oldest(_ category: FediqoCore.Category, of host: String, in notes: [Note]) -> String? {
        notes.filter { $0.source.host == host && $0.categories.contains(category) }
            .compactMap(\.statusID)
            .min { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
    }

    /// One source's stretches, one after another. Whether every one came back.
    private func more(_ due: [Due], in session: ShellSession) async -> Bool {
        var read = true
        for one in due {
            guard !Task.isCancelled else { break }
            read = await more(one, in: session) && read
        }
        return read
    }

    /// One stretch, into the store. A reader walking away is not a failure; anything else is, and
    /// leaves the store — and so the listing — as it was.
    private func more(_ due: Due, in session: ShellSession) async -> Bool {
        let host = due.source.host
        let stamp = Source(host: host, kind: due.source.kind)
        do {
            switch due.cursor {
            case .before(let id):
                try await mastodon(due, before: id, stamp: stamp, in: session)
                stretches.asked(due.stretch, before: id)
            case .page(let page):
                let generation = stretches.generation
                let notes: [Note]
                do {
                    notes = try await forum(due, page: page, stamp: stamp, in: session)
                } catch DiscuzRequestError.noThreads {
                    // A page past the last that a forum answers with none: its end, not a miss.
                    notes = []
                }
                try Task.checkCancellation()
                await session.store.ingest(notes, ifSourceHere: host)
                stretches.read(
                    due.stretch, page: page, threads: Set(notes.map(\.key)), generation: generation
                )
            }
            return true
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            return false
        } catch {
            return Cancellation.happened(error)
        }
    }

    private func mastodon(_ due: Due, before id: String, stamp: Source, in session: ShellSession) async throws {
        let host = stamp.host
        switch due.stretch.category {
        case .public?:
            let client = MastodonClient(http: timed(session.http, for: .timeline, name: .public, in: session), host: host)
            let notes = try await client.publicTimeline(source: stamp, olderThan: id)
            try Task.checkCancellation()
            await session.store.ingest(notes, ifSourceHere: host)
        case .some(let category):
            // As the reader, through a door named for the timeline it reads, and ended by a
            // sign-out or a Clear before anything it brings lands.
            // Signed out since this was worked out: nothing is asked, and the stretch is not
            // recorded as asked — a walk away, as a sign-out ends a read already on its way.
            guard let token = session.mastodon.token(host: host) else { throw CancellationError() }
            let name: SourceWork.Name? = switch category {
            case .home: .home
            case .list(let listID): due.source.lists.first { $0.id == listID }.map { .called($0.name) }
            default: nil
            }
            let door = session.mastodon.authorized(token: token, within: deadline, for: .timeline, name: name)
            let account = MastodonAccount(door: door, store: session.store)
            _ = try await asReader(host) { try await account.older(category, than: id) }
        case nil:
            return
        }
    }

    private func forum(_ due: Due, page further: Int, stamp: Source, in session: ShellSession) async throws -> [Note] {
        let host = stamp.host
        let http = transport(host, in: session)
        switch (stamp.kind, due.stretch.category) {
        case (.discuz, .board(let id)?):
            let board = due.source.boards.first { String($0.fid) == id }
            let client = DiscuzClient(
                http: timed(http, for: .timeline, name: board.map { .called($0.name) }, in: session), host: host
            )
            guard let fid = Int(id) else { return [] }
            // Discuz! counts its pages from one, so the one past the first is page two.
            return try await client.board(fid, source: stamp, named: board?.name, page: further + 1)
        case (.discuz, nil):
            let client = DiscuzClient(http: timed(http, for: .timeline, in: session), host: host)
            return try await client.latest(source: stamp, page: further + 1)
        case (.discourse, nil):
            // Discourse counts from nought, so the one past the first is page one.
            let client = DiscourseClient(http: timed(http, for: .timeline, in: session), host: host)
            return try await client.latest(source: stamp, page: further)
        default:
            return []
        }
    }
}

/// A row that, coming into view, asks the timeline in front for its next stretch (#87) — where
/// `asks` says it is near enough the end to. A modifier of its own so the list's row stays one
/// chain the type-checker reads quickly.
struct AsksForMore: ViewModifier {
    let asks: Bool
    let timeline: TimelineQuery
    let session: ShellSession

    func body(content: Content) -> some View {
        content.onAppear {
            guard asks else { return }
            Task { await session.reload.more(timeline, in: session) }
        }
    }
}
