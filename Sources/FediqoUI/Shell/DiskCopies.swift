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
/// **Capped (#7).** What is kept is trimmed, oldest written first, down to `cap` bytes: at launch,
/// and after every `trimEvery` writes rather than after each, because a trim walks every copy.
final class DiskCopies: Sendable {
    /// What the copies on this device may weigh, all hosts together.
    static let defaultCap = 512 * 1024 * 1024
    static let defaultTrimEvery = 32

    private let copies: any MediaCopies
    private let queue = DispatchQueue(label: "fediqo.pictures.disk", qos: .utility)
    let cap: Int
    private let trimEvery: Int
    /// Writes since the last trim. Touched only on `queue`, which is what makes it safe to share.
    private let written = WriteCount()

    init(_ copies: any MediaCopies, cap: Int = DiskCopies.defaultCap, trimEvery: Int = DiskCopies.defaultTrimEvery) {
        self.copies = copies
        self.cap = cap
        self.trimEvery = max(1, trimEvery)
    }

    func data(host: String, url: URL) async -> Data? {
        await withCheckedContinuation { done in
            queue.async { [copies] in done.resume(returning: copies.data(host: host, url: url)) }
        }
    }

    func store(_ data: Data, host: String, url: URL) {
        queue.async { [copies, written, cap, trimEvery] in
            try? copies.store(data, host: host, url: url)
            written.count += 1
            guard written.count >= trimEvery else { return }
            written.count = 0
            copies.trim(toBytes: cap)
        }
    }

    func remove(host: String, url: URL) {
        queue.async { [copies] in copies.remove(host: host, url: url) }
    }

    func forget(host: String) {
        queue.async { [copies] in copies.forget(host: host) }
    }

    func keepOnly(hosts: [String]) {
        queue.async { [copies] in copies.keepOnly(hosts: hosts) }
    }

    /// Every copy of every host: the drop by cache. Rows draw from their hyperlinks afterwards.
    func removeAll() {
        queue.async { [copies] in copies.removeAll() }
    }

    func trim() {
        queue.async { [copies, cap] in copies.trim(toBytes: cap) }
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

    /// Returns once everything asked for before it has run.
    func settled() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }
}

/// A counter only ever read and written on `DiskCopies.queue`.
private final class WriteCount: @unchecked Sendable {
    var count = 0
}
