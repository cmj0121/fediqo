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

/// A chosen server, of the one protocol the double below claims to speak.
func makeServer(_ host: String) -> Server {
    Server(host: host, socialProtocol: .mastodon, title: host)
}

/// A post whose `mergeKey` is `uri`, posted at `at`, so a test can name a row and place it
/// in time in one line. `sourceURL` is a server's endpoint, because the store keys on it.
func makePost(_ uri: String, at seconds: TimeInterval = 0,
              from host: String = "example.social") -> Post {
    makePost(uri, at: seconds, from: host, web: URL(string: "https://\(host)/@a/\(uri)"))
}

/// The same post at a named address — or at none, which is what a server that gave no web
/// address for a post looks like, and the one thing the default above cannot say.
func makePost(_ uri: String, at seconds: TimeInterval = 0, from host: String = "example.social",
              web: URL?) -> Post {
    Post(uri: uri, socialProtocol: .mastodon, sourceURL: "https://\(host)",
         createdAt: Date(timeIntervalSince1970: seconds), authorId: "https://\(host)/users/a",
         authorName: "A", authorHandle: "@a@\(host)", text: uri, webURL: web, sources: [host])
}

/// A server with a fixed run of posts in it, handing them over a page at a time — the whole
/// of what a reach for the bottom needs of a network, with no network in it.
///
/// `holds` keeps the first request open until it is let go, which is the only way to have a
/// page genuinely in flight while the next reach arrives with nothing sleeping. `sameEveryTime`
/// ignores the cursor and answers its newest page for ever, which is the cold-start cliff at
/// its worst: every round lands above the reader and none of them below.
actor PagedClient: SourceClient {
    /// A page, here and in the loader the tests build beside it — kept as one number so the
    /// double's page and the loader's `limit` cannot drift apart.
    static let pageSize = 2

    private let all: [Post]
    private let sameEveryTime: Bool
    private let holds: Bool
    /// How many pages have been asked for. Counted rather than kept: which cursor each round
    /// carried is `ServerPagingTests`' question, asked there of the real client.
    private(set) var asks = 0
    private var release: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    init(_ all: [Post], sameEveryTime: Bool = false, holds: Bool = false) {
        self.all = all
        self.sameEveryTime = sameEveryTime
        self.holds = holds
    }

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "")
    }

    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }

    /// Nothing here reconciles anything away: a double that answered "gone" would mark posts
    /// no test asked it to.
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }

    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] {
        asks += 1
        arrival?.resume()
        arrival = nil
        // Only the first is held. A second arriving is the guard having let one through, which
        // is exactly what the test watches for — holding that one too would leave a
        // continuation nobody resumes and a suite that never finishes.
        if holds, asks == 1 { await withCheckedContinuation { release = $0 } }
        guard !sameEveryTime else { return Array(all.prefix(Self.pageSize)) }
        let start = before.flatMap { cursor in
            all.firstIndex { $0.mergeKey == cursor.mergeKey }.map { $0 + 1 }
        } ?? 0
        return Array(all[min(start, all.count)...].prefix(Self.pageSize))
    }

    /// Back once a request is genuinely out.
    func untilAsked() async {
        guard asks == 0 else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func letGo() {
        release?.resume()
        release = nil
    }
}

/// One feed reading `client` and, where there is one, `store` — the wired path a reach for
/// the bottom takes, with the network replaced and nothing else.
@MainActor
func freshFeed(_ name: String, mode: FeedMode = .timeline, client: PagedClient,
               store: LocalStore? = nil) -> FeedModel {
    FeedModel(mode: mode, preferences: Preferences(defaults: scratch(name)),
              loader: TimelineLoader(registry: SourceRegistry(clients: [.mastodon: client]),
                                     limit: PagedClient.pageSize, store: store,
                                     secrets: InMemorySecretStore()))
}
