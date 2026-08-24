import Foundation
import Observation
import FediqoCore

@MainActor
@Observable
final class FeedModel {
    let mode: FeedMode

    private(set) var result = TimelineResult(posts: [], failures: [:])
    private(set) var loading = false
    private var loadedFor: [String] = []

    private let loader: TimelineLoader

    init(mode: FeedMode, loader: TimelineLoader = TimelineLoader()) {
        self.mode = mode
        self.loader = loader
    }

    /// Reloads only when the set of servers actually changed, so switching rails does not
    /// re-ask every server every time. Before the first load, what the store holds is shown
    /// before any server is asked; a store that cannot be read is simply skipped on the way there.
    func loadIfNeeded(servers: [Server]) async {
        if loadedFor.isEmpty, result.isEmpty,
           let stored = try? await loader.stored(mode: mode), !stored.isEmpty {
            result = TimelineResult(posts: stored, failures: [:])
        }
        let signature = servers.map(\.id).sorted()
        guard signature != loadedFor || result.isEmpty else { return }
        await load(servers: servers)
    }

    func load(servers: [Server]) async {
        loading = true
        result = await loader.load(servers: servers, mode: mode)
        loadedFor = servers.map(\.id).sorted()
        loading = false
    }

    /// The rules, applied. They add and remove; they never move.
    func visible(preferences: Preferences) -> [Post] {
        TimelineLoader.apply(showBoosts: preferences.showBoosts, mediaOnly: preferences.showMediaOnly, to: result.posts)
    }
}
