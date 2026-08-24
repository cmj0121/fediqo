import Foundation
import Observation
import FediqoCore

@MainActor
@Observable
final class FeedModel {
    let mode: FeedMode

    private(set) var result = TimelineResult(posts: [], failures: [:])
    /// What is still wrong with each server, by `Server.endpoint`, kept across loads.
    ///
    /// `result` is replaced whole every time, and a server inside its wait is not in it at
    /// all — so a screen reading the last load alone would take a broken server's line down
    /// and put it back up every cycle, though nothing about the server changed. This is the
    /// standing answer instead: it survives the loads that did not ask, and it clears the
    /// moment the server answers one that did, or stops being one of ours.
    private(set) var failures: [String: SourceFailure] = [:]
    private(set) var loading = false
    private var loadedFor: [String] = []

    private let loader: TimelineLoader

    /// Told, by `Server.endpoint`, when a server turned down the token a read carried. The
    /// posts still arrived — the loader asked again as a stranger — so this marks the
    /// account and never the column.
    var onTokenRejected: (@MainActor (String) -> Void)?

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

    /// `refresh` says who asked. The reader by default — the refresh button, and the first
    /// load of a screen — so that everything is asked at once, whatever it did last time.
    func load(servers: [Server], refresh: Refresh = .manual) async {
        loading = true
        let loaded = await loader.load(servers: servers, mode: mode, refresh: refresh)
        result = TimelineResult(posts: loaded.posts(carrying: result.posts, asked: servers),
                                failures: loaded.failures)
        failures = loaded.failures(carrying: failures, of: servers)
        // Only what this load was told, not the standing answer: a credential is turned down
        // once and marked once, rather than again on every tick that skips the server.
        for (endpoint, failure) in loaded.failures {
            if case .tokenRejected = failure { onTokenRejected?(endpoint) }
        }
        loadedFor = servers.map(\.id).sorted()
        loading = false
    }

    /// The rules, applied. They add and remove; they never move.
    func visible(preferences: Preferences) -> [Post] {
        TimelineLoader.apply(showBoosts: preferences.showBoosts, mediaOnly: preferences.showMediaOnly, to: result.posts)
    }
}
