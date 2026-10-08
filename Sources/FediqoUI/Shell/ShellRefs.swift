import FediqoCore
import Foundation

// What items refer to, loaded (#293).
//
// When an item first arrives and a post it refers to is not held — the post it answers, a post
// it quotes that did not come with it — the store says the item owes a load. This asks for it:
// one read of that one post, by its source's own id, through the source that brought the item,
// in that source's line (`LoadPacer`). Nobody pressed anything, so everything here is bounded,
// listed where other reads are (`SourceWork.Purpose.reference`), and let go with the source.
//
// **Only ever the item's own source, and only by that source's id for the post.** The host asked
// is the item's `source.host`; the path is built from the id that host gave. A reference's `id`
// — a name, which can spell any host — is never an address, and is not read here at all.
//
// **How much, and when** (`ShellRefs.eager`). A landing asks for at most that many posts per
// source at once, newest item first; what is past that waits, still owed, until its row is
// near the screen, and then goes to the front of the line. So a stretch of forty answers costs
// a source ten requests unless the reader goes and reads the rest.

/// What this session has asked each source for, of what its items owe.
@MainActor
final class ShellRefs {
    /// How many loads one landing asks one source for without the reader reaching for them.
    ///
    /// **Ten.** A bound on what one arrival costs a source with nobody reaching, and not on how
    /// long it takes: at the pace a source's loads keep it is half a minute of asking. The
    /// shortest wait between two timeline reads is a minute, so the line does not grow without
    /// the reader scrolling, and `LoadLimits.queued` bounds it where they do.
    static let eager = 10

    /// One post asked of one source: every item waiting on it, and how the request came back.
    private struct Asking {
        var owed: [ItemStore.Owed]
        var came: ItemStore.Loaded?
        /// Whether the answer in `came` was to an unsigned read.
        var unsigned = false
    }

    private var asking: [String: [String: Asking]] = [:]
    /// What a landing has already looked at, by source: each owed post is offered a place in a
    /// landing's share once, the first time it is seen. So the share is of what **arrived**, and
    /// what a load brings — which changes the store, and so is a landing too — opens no further
    /// share for what was passed over.
    private var seen: [String: Set<String>] = [:]
    /// Hosts this run has read as the reader. A source signed in to and then not — signed out,
    /// or ended by the server — is not read unsigned in the reader's place: its loads stop
    /// until they sign in again.
    private var readAsYou: Set<String> = []
    private var listening = false

    /// How many loads are asked or on the wire. For a test to read.
    var count: Int { asking.values.reduce(0) { $0 + $1.count } }

    /// `landed(in:)`, started and not waited for: one at a time, and once more where the store
    /// changed again meanwhile.
    func landing(in session: ShellSession) {
        guard session.startsLoads else { return }
        again = true
        guard running == nil else { return }
        running = Task { [weak self, weak session] in
            while let self, let session, self.again {
                self.again = false
                await self.landed(in: session)
            }
            self?.running = nil
        }
    }

    private var running: Task<Void, Never>?
    private var again = false
    /// Each load taken, until it has ended and what it brought has landed.
    private var ends: [UUID: Task<Void, Never>] = [:]

    /// Returns once every landing started so far has asked what it had to, and every load taken
    /// has ended and landed. For a test to wait on; with loads held on the wire it waits for them.
    func settled() async {
        while running != nil || !ends.isEmpty {
            if let running { await running.value }
            if let end = ends.values.first { await end.value }
        }
    }

    /// Returns once every landing started so far has asked what it had to — whatever became of
    /// the loads it took.
    func asked() async {
        while let running { await running.value }
    }

    /// After the store changed: takes back what was asked for items since let go, and asks for
    /// what the newest arrivals owe, within `eager`.
    func landed(in session: ShellSession) async {
        guard session.startsLoads else { return }
        listen(in: session)
        readAsYou.formUnion(session.mastodon.signedInHosts)
        // A row whose taking back is pressed is left out of `notes` and is held all the same:
        // what was asked for it is not taken back unless the post really goes.
        let held = Set(session.notes.map(\.key)).union(session.acts.leaving.compactMap(NoteKey.init(rowID:)))
        for (host, posts) in asking {
            for (statusID, one) in posts where one.owed.allSatisfy({ !held.contains($0.item) }) {
                if await session.loads.withdraw(host: host, id: statusID) { asking[host]?[statusID] = nil }
            }
        }
        for source in session.sources where source.kind.loadsReferences {
            let owed = await session.store.owed(host: source.host)
            let before = seen[source.host] ?? []
            // Only what is still owed is remembered, so this never outgrows the store.
            seen[source.host] = Set(owed.map(Self.name))
            var budget = Self.eager
            for one in owed where budget > 0 && !before.contains(Self.name(one)) {
                if await ask(one, in: session) { budget -= 1 }
            }
        }
    }

    /// Rows near the screen: what they owe goes to the front of its source's line, asked now
    /// where a landing's share had left it waiting.
    func near(_ rowIDs: [String], in session: ShellSession) async {
        guard session.startsLoads else { return }
        let keys = Set(rowIDs.compactMap(NoteKey.init(rowID:)))
        for host in Set(keys.map(\.host)) {
            guard session.sources.contains(where: { $0.host == host && $0.kind.loadsReferences }) else { continue }
            for owed in await session.store.owed(host: host, among: keys) {
                if asking[host]?[owed.statusID] != nil {
                    await session.loads.promote(host: host, id: owed.statusID)
                } else if await ask(owed, in: session) {
                    await session.loads.promote(host: host, id: owed.statusID)
                }
            }
        }
    }

    private static func name(_ owed: ItemStore.Owed) -> String { owed.item.id + "\u{1e}" + owed.statusID }

    /// The reader let `host` go, or its sign-in ended: nothing asked of it is waited for, and
    /// what it owes is looked at afresh when it is asked again.
    func letGo(host: String) {
        asking[host.lowercased()] = nil
        seen[host.lowercased()] = nil
    }

    /// The source removed: a source of that name added again is a new one.
    func forget(host: String) {
        letGo(host: host)
        readAsYou.remove(host.lowercased())
    }

    /// Puts one owed post in its source's line. Whether a new load was taken.
    private func ask(_ owed: ItemStore.Owed, in session: ShellSession) async -> Bool {
        let host = owed.item.host
        if asking[host]?[owed.statusID] != nil {
            if asking[host]?[owed.statusID]?.owed.contains(owed) == false { asking[host]?[owed.statusID]?.owed.append(owed) }
            return false
        }
        // Before a place in the line is taken: a source that was read as the reader and has no
        // sign-in now is not asked, so asking would spend a turn and a try of the run on nothing.
        if readAsYou.contains(host), !session.mastodon.isSignedIn(host: host) { return false }
        let statusID = owed.statusID
        let asked = await session.loads.ask(host: host, id: statusID) { [weak self, weak session] in
            guard let self, let session else { return .answered() }
            return await self.attempt(statusID, of: host, in: session)
        }
        switch asked {
        case .taken(let ticket):
            asking[host, default: [:]][statusID] = Asking(owed: [owed])
            let id = UUID()
            ends[id] = Task { [weak self, weak session] in
                let end = await ticket.end()
                guard let self, let session else { return }
                await self.ended(end, statusID, of: host, in: session)
                self.ends[id] = nil
            }
            return true
        case .not(.sourceGivenUp):
            await session.store.land(.stalled, for: owed)
            return false
        case .not:
            // Full, or the run's share spent: still owed, and asked again when its row is near.
            return false
        }
    }

    /// One try: the post asked of `host` by the id `host` gave it.
    ///
    /// **As the reader where they are signed in there, and never unsigned in their place.** The
    /// sign-in is looked for at each try. A source the person added without signing in is read
    /// as it always is, unsigned. A source that was read as the reader this run and has no
    /// sign-in now — signed out, or ended by the server — is not asked at all: the try ends,
    /// nothing lands, and the item still owes its load for when they sign in again.
    private func attempt(_ statusID: String, of host: String, in session: ShellSession) async -> LoadAnswer {
        guard let source = session.sources.first(where: { $0.host == host && $0.kind.loadsReferences }),
              ListSubscription.isPathSegment(statusID)
        else { return .answered() }
        let limit = session.reload.deadline
        let post: MastodonPost
        if let door = session.mastodon.authorized(host: host, within: limit, for: .reference) {
            readAsYou.insert(host)
            asking[host]?[statusID]?.unsigned = false
            post = session.reach.post(door)
        } else if readAsYou.contains(host) {
            return .answered()
        } else {
            asking[host]?[statusID]?.unsigned = true
            post = session.reach.unsignedPost(host, for: .reference, within: limit)
        }
        do {
            let note = try await post.post(id: statusID, source: Source(host: host, kind: source.kind))
            asking[host]?[statusID]?.came = .held(note)
            return .answered()
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            return .answered()
        } catch {
            switch Self.status(of: error) {
            case 404, 410:
                asking[host]?[statusID]?.came = .gone
                return .answered()
            case 429:
                return .slowDown()
            default:
                return .failed
            }
        }
    }

    private static func status(of error: any Error) -> Int? {
        if let refused = error as? MastodonRequestError, case .http(let status) = refused { return status }
        if let refused = error as? MastodonAuthError, case .http(let status) = refused { return status }
        return nil
    }

    /// A load ended: what came is taken in for every item that waited on it, or the items are
    /// said to have been given up on for this run. Anything else leaves them owing.
    private func ended(_ end: LoadEnd, _ statusID: String, of host: String, in session: ShellSession) async {
        guard let one = asking[host]?[statusID] else { return }
        // Still listed as asked until what it brought has landed: a landing that runs between
        // must not find the post owed and nobody asking for it.
        defer { asking[host]?[statusID] = nil }
        switch end {
        case .done:
            guard let came = one.came else { return }
            for owed in one.owed {
                // "No such post", said to nobody in particular, of a post a signed-in reader's
                // item refers to, is not the source's word that it is gone.
                if case .gone = came, one.unsigned, owed.asReader {
                    await session.store.land(.notSaid, for: owed)
                } else {
                    await session.store.land(came, for: owed)
                }
            }
        case .gaveUp, .sourceGivenUp:
            for owed in one.owed { await session.store.land(.stalled, for: owed) }
        case .notTaken, .letGo, .withdrawn:
            return
        }
        session.saveSoon()
    }

    /// Other reads' word reaches the pacer from the one place answers are seen.
    private func listen(in session: ShellSession) {
        guard !listening else { return }
        listening = true
        let loads = session.loads
        session.work.hears { host, answer in
            await loads.heard(host: host, answer)
        }
    }
}
