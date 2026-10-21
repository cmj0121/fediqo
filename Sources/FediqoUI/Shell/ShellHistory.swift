import FediqoCore
import Foundation

// What changed posts said before, filled in from their sources (#332, Decision 1).
//
// After a landing, each changed post that arrived owing its history (`Note.historyOwed`) is
// asked of its own source, in that source's line of loads (`MastodonHistoryFill`): behind
// nothing the reader waits on, paced, and let go with the source. Nothing is drawn while it
// asks, and nothing is said where it fails: the row keeps what this device saw.
//
// **What is owed is the store's word** — the row's `historyAt` against its `editedAt` — and what
// is on its way the store's too, so a relaunch and a second session read the same. What this
// holds is only which owed asks a landing has already looked at this run (`seen`), as
// `ShellRefs` does, so one landing's share is of what **arrived**: a store carried forward with
// many changed posts asks `eager` of them at its first landing, and none more until they arrive
// again changed.

@MainActor
final class ShellHistory {
    /// How many history asks one landing makes of one source: `ShellRefs.eager`'s figure, for
    /// its reason.
    static let eager = ShellRefs.eager

    private var seen: [String: Set<ItemStore.HistoryOwed>] = [:]
    private var running: Task<Void, Never>?
    private var again = false
    private var asks: [UUID: Task<Void, Never>] = [:]

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

    /// Returns once every landing started so far has asked what it had to, and every ask taken
    /// has ended and landed. For a test to wait on.
    func settled() async {
        while running != nil || !asks.isEmpty {
            if let running { await running.value }
            if let ask = asks.values.first { await ask.value }
        }
    }

    /// Asks, of each Mastodon source, for the history its newest arrivals owe, within `eager`.
    func landed(in session: ShellSession) async {
        guard session.startsLoads else { return }
        let fill = MastodonHistoryFill(store: session.store, loads: session.loads)
        for source in session.sources where source.kind == .mastodon {
            let host = source.host
            let owed = await session.store.historyOwed(host: host)
            let before = seen[host] ?? []
            // Only what is still owed is remembered, so this never outgrows the store.
            seen[host] = Set(owed)
            for one in owed.filter({ !before.contains($0) }).prefix(Self.eager) {
                let id = UUID()
                asks[id] = Task { [weak self, weak session] in
                    await fill.fill(one) { [weak session] in
                        guard let session else { return nil }
                        return await Self.reader(of: host, in: session)
                    }
                    // Let go of without being asked — nobody to ask through at that try, or the
                    // source let go — it is the store's to offer again, and a later landing looks
                    // at it afresh. One given up for the run the store keeps taken.
                    if let session, await session.store.historyOwed(host: host, among: [one.item]).contains(one) {
                        self?.seen[host]?.remove(one)
                    }
                    self?.asks[id] = nil
                }
            }
        }
    }

    /// The source let go of, or signed out of: what it owes is looked at afresh when it is
    /// asked again.
    func letGo(host: String) {
        seen[host.lowercased()] = nil
    }

    /// The reader of posts a history ask of `host` goes through at this try: as the reader where
    /// they are signed in there, and unsigned otherwise — a post anybody may read, anybody may
    /// read the history of. Nothing where the source is gone.
    private static func reader(of host: String, in session: ShellSession) -> MastodonPost? {
        guard session.sources.contains(where: { $0.host == host && $0.kind == .mastodon }) else { return nil }
        let limit = session.reload.deadline
        if let door = session.mastodon.authorized(host: host, within: limit, for: .reference) {
            return session.reach.post(door)
        }
        return session.reach.unsignedPost(host, for: .reference, within: limit)
    }
}
