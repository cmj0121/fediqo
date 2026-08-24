import Foundation
import SwiftUI
import FediqoCore
@testable import FediqoUI

/// The keys that are not letters, in the spelling the commands are written in. Shared,
/// because the keys are asked about in more than one place: what a press means, and whether
/// the app keeps it.
let escape = KeyEquivalent.escape.character
let tab = KeyEquivalent.tab.character
let enter = KeyEquivalent.return.character
let up = KeyEquivalent.upArrow.character
let down = KeyEquivalent.downArrow.character

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
