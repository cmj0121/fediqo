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
final class DiskCopies: Sendable {
    private let copies: any MediaCopies
    private let queue = DispatchQueue(label: "fediqo.pictures.disk", qos: .utility)

    init(_ copies: any MediaCopies) {
        self.copies = copies
    }

    func data(host: String, url: URL) async -> Data? {
        await withCheckedContinuation { done in
            queue.async { [copies] in done.resume(returning: copies.data(host: host, url: url)) }
        }
    }

    func store(_ data: Data, host: String, url: URL) {
        queue.async { [copies] in try? copies.store(data, host: host, url: url) }
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

    /// Returns once everything asked for before it has run.
    func settled() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }
}
