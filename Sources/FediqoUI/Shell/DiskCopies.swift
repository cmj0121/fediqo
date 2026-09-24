import FediqoCore
import Foundation

/// Every touch of the copies on this device, one at a time, in the order it was asked for, and
/// off the main actor.
///
/// **Ordered, because a Clear has to win.** A write asked for before a Clear and run after it
/// would put back a copy of the server the reader just emptied. A serial queue rather than an
/// actor: work handed to an actor from separate tasks has no promised order, and `async` on one
/// queue does. Reads go through the same queue, so a read asked for after a Clear never finds
/// what the Clear was about to delete.
///
/// **Capped (#7).** A running total of what the copies weigh is kept on the queue: measured by
/// the launch trim, grown by each write, and cut by each drop. The copies are walked only when
/// that total passes `cap`, and then trimmed oldest written first until they fit.
final class DiskCopies: Sendable {
    /// What the copies on this device may weigh, all hosts together.
    static let defaultCap = 512 * 1024 * 1024

    private let copies: any MediaCopies
    private let queue = DispatchQueue(label: "fediqo.pictures.disk", qos: .utility)
    let cap: Int
    /// What the copies weigh, or nil where it is not known and the next write measures it.
    private let tally = Tally()

    init(_ copies: any MediaCopies, cap: Int = DiskCopies.defaultCap) {
        self.copies = copies
        self.cap = cap
    }

    func data(host: String, url: URL) async -> Data? {
        await withCheckedContinuation { done in
            queue.async { [copies] in done.resume(returning: copies.data(host: host, url: url)) }
        }
    }

    func store(_ data: Data, host: String, url: URL) {
        queue.async { [copies, tally, cap] in
            try? copies.store(data, host: host, url: url)
            guard let total = tally.total else {
                tally.total = copies.trim(toBytes: cap)
                return
            }
            tally.total = total + data.count
            if total + data.count > cap { tally.total = copies.trim(toBytes: cap) }
        }
    }

    /// Unknown afterwards: one copy's size is not worth a read of its own, so the next write
    /// measures again.
    func remove(host: String, url: URL) {
        queue.async { [copies, tally] in
            copies.remove(host: host, url: url)
            tally.total = nil
        }
    }

    func forget(host: String) {
        queue.async { [copies, tally] in
            let gone = copies.bytes(host: host)
            copies.forget(host: host)
            tally.total = tally.total.map { max(0, $0 - gone) }
        }
    }

    func keepOnly(hosts: [String]) {
        queue.async { [copies, tally] in
            copies.keepOnly(hosts: hosts)
            tally.total = nil
        }
    }

    /// Every copy of every host: the drop by cache. Rows draw from their hyperlinks afterwards.
    func removeAll() {
        queue.async { [copies, tally] in
            copies.removeAll()
            tally.total = 0
        }
    }

    /// Down to the cap, and the running total measured: what the launch does.
    func trim() {
        queue.async { [copies, tally, cap] in tally.total = copies.trim(toBytes: cap) }
    }

    /// What each host's copies weigh, read off the main actor and after every touch asked before.
    func bytes(hosts: [String]) async -> [String: Int] {
        await withCheckedContinuation { done in
            queue.async { [copies] in
                done.resume(returning: Dictionary(
                    hosts.map { ($0, copies.bytes(host: $0)) }, uniquingKeysWith: { first, _ in first }
                ))
            }
        }
    }

    /// What a trim by the room limit let go and left (#249).
    struct Trimmed: Equatable, Sendable {
        /// How many copies went.
        let dropped: Int
        /// What is kept, in bytes, measured.
        let kept: Int
        /// The hosts whose copies went, folded and sorted.
        let sources: [String]
    }

    /// Drops copies, oldest written first, until what is kept weighs no more than `cap` — the
    /// room limit's first step (#249), which comes before any post goes. Measured before and
    /// after, so the answer says how many went and from which of `hosts`; the running total is
    /// what was measured.
    func trim(toBytes cap: Int, among hosts: [String]) async -> Trimmed {
        await withCheckedContinuation { done in
            queue.async { [copies, tally] in
                let before = copies.count()
                let held = hosts.map { ($0, copies.bytes(host: $0)) }
                let kept = copies.trim(toBytes: cap)
                tally.total = kept
                let sources = held.filter { copies.bytes(host: $0.0) < $0.1 }.map(\.0).sorted()
                done.resume(returning: Trimmed(dropped: before - copies.count(), kept: kept, sources: sources))
            }
        }
    }

    /// What every copy on this device weighs, all hosts together — **the set a trim acts on**
    /// (#249): the running total where it is known, and one measure of the copies where it is
    /// not, which is then the running total.
    func measure() async -> Int {
        await withCheckedContinuation { done in
            queue.async { [copies, tally] in
                if let total = tally.total { return done.resume(returning: total) }
                let total = copies.trim(toBytes: .max)
                tally.total = total
                done.resume(returning: total)
            }
        }
    }

    /// The running total, as the queue has it once everything asked before has run.
    func total() async -> Int? {
        await withCheckedContinuation { done in
            queue.async { [tally] in done.resume(returning: tally.total) }
        }
    }

    /// Returns once everything asked for before it has run.
    func settled() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }
}

/// The running total, only ever read and written on `DiskCopies.queue`.
private final class Tally: @unchecked Sendable {
    var total: Int?
}
