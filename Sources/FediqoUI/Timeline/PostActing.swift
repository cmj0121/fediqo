import Foundation
import FediqoCore

/// What the app knows about what the reader has done to the posts on screen, and how it does
/// one more thing.
///
/// The steps of an action live in Core (`PostActions`). What is here is the part that is
/// genuinely a screen's: which account acts, whether the reader has agreed to what that
/// costs, and what to show while it is happening.
extension AppState {
    /// Whose account acts on this post.
    ///
    /// The post's own server first, where the reader has an account on it — that is the free
    /// path and the one where nobody new learns anything. Otherwise the account they chose,
    /// or the only one they have. Nothing where they have none: without an account there is
    /// no such thing as favouriting something.
    func acting(on post: Post) async -> ActingAccount? {
        guard let signIn, let tokens else { return nil }
        let endpoints = signIn.accounts.keys.sorted()
        guard !endpoints.isEmpty else { return nil }

        let home = Server.endpoint(of: URL(string: post.sourceURL) ?? URL(fileURLWithPath: "/"))
        let chosen = endpoints.contains(home) ? home
            : preferences.actingServer.flatMap { endpoints.contains($0) ? $0 : nil }
            ?? (endpoints.count == 1 ? endpoints[0] : nil)
        guard let chosen, let account = signIn.accounts[chosen],
              let server = servers.first(where: { $0.endpoint == chosen }),
              let token = await tokens.tokens(for: [server])[chosen]
        else { return nil }
        return ActingAccount(host: server.host, authorId: account.authorId,
                             token: token.accessToken)
    }

    /// Every account the reader could act as, in a stable order, for the screen that asks them
    /// to choose. One of them is not a choice and is not presented as one.
    var actingChoices: [(endpoint: String, account: SignedInAccount)] {
        guard let signIn else { return [] }
        return signIn.accounts.keys.sorted().compactMap { endpoint in
            signIn.accounts[endpoint].map { (endpoint, $0) }
        }
    }

    /// What this post is marked with, as far as anybody has told us. Never-told throughout
    /// where nobody has: an empty star that does not claim to mean "not favourited".
    func marks(of post: Post) -> PostMarks {
        postMarks[post.mergeKey] ?? .unknown
    }

    func isKept(_ post: Post) -> Bool { keptPosts.contains(post.mergeKey) }

    /// Reads back what this device holds about a page of posts: what each account did, and
    /// what is being kept here.
    ///
    /// Asked for a page at a time rather than a row at a time — a list of forty rows each
    /// opening the store is forty round trips for one answer — and asked again whenever the
    /// page changes or the acting account does.
    func loadMarks(for posts: [Post]) async {
        guard let store, !posts.isEmpty else { return }
        let keys = posts.map(\.mergeKey)
        if let kept = try? await store.kept(among: keys) { keptPosts = kept }
        guard let account = await acting(on: posts[0]),
              let found = try? await store.marks(of: keys, as: account.authorId) else { return }
        postMarks = found
    }

    /// Favourite, boost or bookmark, or take it back.
    ///
    /// The screen is moved first and put back if the server disagrees. That is not optimism
    /// for its own sake: the alternative is a star that does nothing for as long as somebody
    /// else's server takes to answer, on a control whose whole job is to answer immediately.
    func act(_ action: PostAction, on post: Post) async {
        guard let account = await acting(on: post) else {
            actionFailure = .needsSignIn(post.sources.first ?? "")
            return
        }
        let was = marks(of: post).value(of: action) ?? false
        postMarks[post.mergeKey] = marks(of: post).setting(action, to: !was)
        do {
            let reach = try await postActions.perform(action, on: post, as: account, done: !was,
                                                      fetching: preferences.mayFetchToAct)
            if reach == .fetched { lastReachedOut = account.host }
        } catch {
            postMarks[post.mergeKey] = marks(of: post).setting(action, to: was)
            actionFailure = SourceFailure.of(error)
        }
    }

    /// Kept, or let go. No server is told, so there is nothing to put back if one disagrees.
    func keep(_ post: Post) async {
        guard let store else { return }
        let kept = !isKept(post)
        if kept { keptPosts.insert(post.mergeKey) } else { keptPosts.remove(post.mergeKey) }
        do {
            try await store.keep(post.mergeKey, kept: kept)
        } catch {
            if kept { keptPosts.remove(post.mergeKey) } else { keptPosts.insert(post.mergeKey) }
            actionFailure = SourceFailure.of(error)
        }
    }

    /// A mute, in one of its two places. `onServer` false is this device's own rule and needs
    /// no account; true asks the acting server to carry it out as well.
    func mute(_ kind: Mute.Kind, _ value: String, onServer: Bool, for post: Post) async {
        let account = onServer ? await acting(on: post) : nil
        if onServer, account == nil {
            actionFailure = .needsSignIn(post.sources.first ?? "")
            return
        }
        do {
            try await postActions.setMute(kind, value, muted: true, as: account)
            await refreshMutes()
        } catch {
            actionFailure = SourceFailure.of(error)
        }
    }

    func refreshMutes() async {
        guard let store else { return }
        mutes = (try? await store.mutes()) ?? []
    }

    /// Whether a mute of this shape is already standing, so a control can say "muted" rather
    /// than offering to do it again.
    func isMuted(_ kind: Mute.Kind, _ value: String, onServer: Bool) -> Bool {
        mutes.contains { $0.kind == kind && $0.value == value && $0.isLocal != onServer }
    }

    /// Reports a post, with whatever the reader wanted to say about it.
    func report(_ post: Post, comment: String) async {
        guard let account = await acting(on: post) else {
            actionFailure = .needsSignIn(post.sources.first ?? "")
            return
        }
        do {
            try await postActions.report(post, as: account, comment: comment,
                                         fetching: preferences.mayFetchToAct)
            reported.insert(post.mergeKey)
        } catch {
            actionFailure = SourceFailure.of(error)
        }
    }
}
