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

    /// What this post has been received with, as far as anybody has told us: the numbers a
    /// write's answer gave where there has been one, and the numbers the post arrived with
    /// where there has not.
    ///
    /// A post is a value, and the one in the list and the one on the opened page are two
    /// copies of it. So the newer numbers cannot live on the post — they live here, keyed the
    /// way the marks are, and both copies read the same answer.
    func counts(of post: Post) -> Counts {
        postCounts[post.mergeKey] ?? post.counts
    }

    func isKept(_ post: Post) -> Bool { keptPosts.contains(post.mergeKey) }

    /// Whether this mark is still out to a server.
    ///
    /// What a control asks so it can say it is working. Keeping is not here and never will be:
    /// it goes no further than this machine, so there is nothing to wait for and nothing to
    /// show — a control that pulsed at a write to a local database would be inventing a wait.
    func isActing(_ action: PostAction, on post: Post) -> Bool {
        actingOn[post.mergeKey]?.contains(action) ?? false
    }

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
        // What the store holds — except for a post an action is still out for. In that gap this
        // app knows something the store has not been told yet, and a page read landing in it
        // used to hand the star back to the store's older answer, where it stayed until the
        // next read. That is what "it did not update" looked like.
        var next = found
        for key in actingOn.keys { next[key] = postMarks[key] }
        postMarks = next
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
        let key = post.mergeKey
        // What was there before the press, whole. Putting a rejected press back means putting
        // *this* back — not a `false` worked out from it, which would turn a mark nobody has
        // ever told us about into this app claiming the reader has not made it.
        let before = marks(of: post)
        let was = before.value(of: action) ?? false
        postMarks[key] = before.setting(action, to: !was)
        actingOn[key, default: []].insert(action)
        defer {
            actingOn[key]?.remove(action)
            if actingOn[key]?.isEmpty == true { actingOn[key] = nil }
        }
        do {
            let acted = try await postActions.perform(action, on: post, as: account, done: !was,
                                                      fetching: preferences.mayFetchToAct)
            if acted.reach == .fetched { lastReachedOut = account.host }
            // The numbers as the server's own answer to the write reported them — the one
            // moment this app is told what the count is with this press counted in.
            if let counts = acted.counts { postCounts[key] = counts }
        } catch {
            postMarks[key] = before
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
