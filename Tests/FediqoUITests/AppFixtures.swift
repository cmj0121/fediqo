import Foundation
import FediqoCore
@testable import FediqoUI

/// A place of its own to write preferences into, so a test says the same thing on every
/// machine rather than whatever this one was last left set to.
func scratch(_ name: String) -> UserDefaults {
    let suite = "fediqo.tests.ui.\(name)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

/// A list of servers that is nobody's: given no store, `AppState` reaches for the real
/// `UserDefaults`, and a test that reads the machine's own sources is a test whose result
/// depends on the machine.
@MainActor
final class EmptyServerStore: ServerStore {
    private(set) var servers: [Server] = []
    func add(_ server: Server) { servers.append(server) }
    func remove(_ server: Server) { servers.removeAll { $0.id == server.id } }
    func removeAll() { servers.removeAll() }
}

@MainActor
func freshApp(_ name: String, launch: LaunchOptions = .none) -> AppState {
    AppState(preferences: Preferences(defaults: scratch(name)), serverStore: EmptyServerStore(), launch: launch)
}
