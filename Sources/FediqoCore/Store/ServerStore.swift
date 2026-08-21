import Foundation

/// Where the servers you chose are written down.
///
/// Deliberately a protocol over a small surface: today it is `UserDefaults`, and #2 replaces
/// the implementation with the local SQLite store without any screen noticing. Nothing here
/// presumes #2's schema.
@MainActor
public protocol ServerStore: AnyObject {
    var servers: [Server] { get }
    func add(_ server: Server)
    func remove(_ server: Server)
    func removeAll()
}

@MainActor
public final class UserDefaultsServerStore: ServerStore {
    private let defaults: UserDefaults
    private let key = "fediqo.servers"
    private var cache: [Server]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([Server].self, from: data) {
            cache = decoded
        } else {
            cache = []
        }
    }

    public var servers: [Server] { cache }

    public func add(_ server: Server) {
        guard !cache.contains(where: { $0.id == server.id }) else { return }
        cache.append(server)
        flush()
    }

    public func remove(_ server: Server) {
        cache.removeAll { $0.id == server.id }
        flush()
    }

    public func removeAll() {
        cache.removeAll()
        flush()
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: key)
    }
}
