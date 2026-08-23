import Foundation
import GRDB

/// The servers you chose, as `servers.selected_at` and `servers.position` in the local store.
///
/// `servers` is a catalogue of every host the post path has met; choosing one is a timestamp
/// on its row, and withdrawing the choice blanks it — the row and every post it handed over
/// stay. A copy of the chosen list is kept here so `servers` answers synchronously, the way
/// the screens read it; every change is written to the database first and the copy re-read
/// from it, so the two cannot disagree.
@MainActor
public final class SQLiteServerStore: ServerStore {
    private let store: LocalStore
    private var cache: [Server] = []

    /// On the first run with a store, the list `UserDefaultsServerStore` kept in `defaults`
    /// is taken over in its order and the key removed, so it is imported exactly once.
    public init(store: LocalStore, defaults: UserDefaults = .standard) {
        self.store = store
        importFromDefaults(defaults)
        reload()
    }

    public var servers: [Server] { cache }

    public func add(_ server: Server) {
        perform("add \(server.host)") { db in try Self.select(db, server) }
    }

    public func remove(_ server: Server) {
        perform("remove \(server.host)") { db in
            try db.execute(sql: "UPDATE servers SET selected_at = NULL, position = NULL WHERE url = ?",
                           arguments: [server.endpoint])
        }
    }

    public func removeAll() {
        perform("remove all") { db in
            try db.execute(sql: "UPDATE servers SET selected_at = NULL, position = NULL WHERE selected_at IS NOT NULL")
        }
    }

    /// Upserts the row the way the post path does and marks it chosen — once: a server already
    /// chosen keeps its `selected_at` and its place. A title that is only the host (what
    /// `Server.init` fills in when none was given) is not written, so a title the network
    /// taught the row stays.
    private static func select(_ db: Database, _ server: Server) throws {
        let url = server.endpoint
        let ms = LocalStore.milliseconds(server.addedAt)
        let title = server.title == server.host ? nil : server.title
        try LocalStore.upsertServer(db, .init(url: url, proto: server.socialProtocol.storeProto, title: title), now: ms)
        try db.execute(sql: """
            UPDATE servers
            SET selected_at = ?, position = (SELECT coalesce(max(position), -1) + 1 FROM servers)
            WHERE url = ? AND selected_at IS NULL
            """, arguments: [ms, url])
    }

    /// A change and the list it leaves, in one write. A change that fails is logged and leaves
    /// the copy as it was: the protocol cannot throw, and a list that says more than is
    /// stored would be the worse answer.
    private func perform(_ what: String, _ block: (Database) throws -> Void) {
        do {
            cache = try store.writeSync { db in
                try block(db)
                return try Self.selected(db)
            }
        } catch {
            LocalStore.log.error("server list: \(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func reload() {
        do {
            cache = try store.readSync(Self.selected)
        } catch {
            LocalStore.log.error("server list: read failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func selected(_ db: Database) throws -> [Server] {
        try Row.fetchAll(db, sql: """
            SELECT host, proto, title, selected_at FROM servers
            WHERE selected_at IS NOT NULL
            ORDER BY position, selected_at
            """).map { row in
            Server(host: row["host"], socialProtocol: SocialProtocol(storeProto: row["proto"]),
                   title: row["title"] ?? "", addedAt: LocalStore.date(row["selected_at"]))
        }
    }

    private func importFromDefaults(_ defaults: UserDefaults) {
        guard let data = defaults.data(forKey: UserDefaultsServerStore.defaultsKey) else { return }
        do {
            let chosen = try store.readSync { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM servers WHERE selected_at IS NOT NULL") ?? 0
            }
            if chosen > 0 {
                LocalStore.log.info("servers already chosen in the store; the UserDefaults list is dropped")
            } else {
                let servers = try JSONDecoder().decode([Server].self, from: data)
                try store.writeSync { db in
                    for server in servers { try Self.select(db, server) }
                }
                LocalStore.log.info("imported \(servers.count, privacy: .public) servers from UserDefaults")
            }
        } catch {
            LocalStore.log.error("server list: import from UserDefaults failed: \(String(describing: error), privacy: .public)")
        }
        defaults.removeObject(forKey: UserDefaultsServerStore.defaultsKey)
    }
}
