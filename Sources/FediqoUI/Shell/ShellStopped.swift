import FediqoCore
import Foundation
import Observation

/// Which Mastodon hosts are told where the person stopped in Home (#316).
///
/// **Not an allowance, and none of a timeline's rules.** An allowance is what may be reached
/// beyond a source; this is a choice, one host at a time, off until the person makes it. Kept
/// as one list (`file`) beside the allowances — under the key where a test hands no file, and
/// in memory alone where it hands neither. **Versioned, and never written over what cannot be
/// read**: a choice this build does not know is left where it stands, because dropping it would
/// tell a source what this device had kept to itself. With none left on, nothing is kept — the
/// same as no host on.
@MainActor
@Observable
final class ShellStopped {
    private struct Kept: Codable {
        var version: Int
        var hosts: [String]
    }

    static let version = 1
    static let key = "fediqo.stopped"

    /// Hosts told where the person stopped, in lower case, each once.
    private(set) var hosts: Set<String> = []
    /// Whether what is kept could not be read: nothing is then written over it, and it is read
    /// again before it is next changed — a device locked at launch unlocks later.
    private(set) var unreadable = false
    /// What was changed while what is kept could not be read, in order: done over it once it is.
    @ObservationIgnored private var pending: [(Set<String>) -> Set<String>] = []
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let file: ListFile?

    init(defaults: UserDefaults? = nil, file: ListFile? = nil) {
        self.defaults = defaults
        self.file = file
        if let read = read() { hosts = read } else { unreadable = true }
    }

    /// `host` is told where the person stopped in Home. A host already on is left as it is.
    func turnOn(_ host: String) {
        let host = host.lowercased()
        change { $0.union([host]) }
    }

    /// `host` is not told. With none left, nothing is kept — the same as no host on.
    func turnOff(_ host: String) {
        let host = host.lowercased()
        change { hosts in
            var hosts = hosts
            hosts.remove(host)
            return hosts
        }
    }

    /// What is kept: nothing where nothing is, and no answer where it cannot be read.
    private func read() -> Set<String>? {
        let data: Data?
        switch file?.read() {
        case .unread?, .notKnown?: return nil
        case .data(let kept)?: data = kept
        case .some(.none): data = nil
        case nil: data = defaults?.data(forKey: Self.key)
        }
        guard let data else { return [] }
        guard Self.knowsEveryField(data),
              let kept = try? JSONDecoder().decode(Kept.self, from: data),
              kept.version == Self.version
        else { return nil }
        return Set(kept.hosts.map { $0.lowercased() })
    }

    /// Whether every object holds only the fields this version writes. A field added by a later
    /// shape that forgot to bump `version` is still not read past.
    private static func knowsEveryField(_ data: Data) -> Bool {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(top.keys).isSubset(of: ["version", "hosts"]),
              top["hosts"] as? [String] != nil
        else { return false }
        return true
    }

    /// What is kept read again where it could not be: what was changed meanwhile is done over
    /// it, and written down.
    private func readAgainIfUnread() {
        guard unreadable, let read = read() else { return }
        unreadable = false
        let changed = !pending.isEmpty
        hosts = pending.reduce(read) { $1($0) }
        pending = []
        if changed { save() }
    }

    private func save() {
        guard !unreadable else { return }
        // None left is nothing kept: no file, and no key for a launch to move back in.
        if hosts.isEmpty {
            if let file {
                try? file.lay(nil)
            } else {
                defaults?.removeObject(forKey: Self.key)
            }
            return
        }
        let kept = Kept(version: Self.version, hosts: hosts.sorted())
        guard let data = try? JSONEncoder().encode(kept) else { return }
        if let file {
            file.write(data)
        } else {
            defaults?.set(data, forKey: Self.key)
        }
    }

    /// One change: made, and written down — or, while what is kept cannot be read, kept to be
    /// made over it once it can.
    private func change(_ op: @escaping (Set<String>) -> Set<String>) {
        readAgainIfUnread()
        let before = hosts
        hosts = op(hosts)
        guard hosts != before else { return }
        if unreadable { pending.append(op) } else { save() }
    }
}
