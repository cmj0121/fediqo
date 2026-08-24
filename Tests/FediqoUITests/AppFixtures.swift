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

/// The three pages that are one screen each. Every rule about a page with no feed is asked
/// of all of them, so the list is written once rather than at each of the tests.
let pagesWithoutTabs: [RailItem] = [.kept, .statistics, .settings]

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

extension AppState {
    /// One press, through the door both listeners use: what the key means, what the app did
    /// about it, and whether the press was ours to keep.
    @MainActor
    func presses(_ character: Character, modifiers: EventModifiers = []) -> Bool {
        KeyCommand.handles(character, modifiers: modifiers, typing: isTyping) { perform($0) }
    }
}

/// One feed, on its own, with rules nobody has changed — a feed applies the reader's filters
/// to its own list, so it needs somewhere of its own to read them from for the same reason
/// the app does.
@MainActor
func freshFeed(_ name: String, mode: FeedMode = .timeline) -> FeedModel {
    FeedModel(mode: mode, preferences: Preferences(defaults: scratch(name)))
}
