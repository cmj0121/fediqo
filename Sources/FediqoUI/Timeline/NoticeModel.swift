import Foundation
import FediqoCore
import Observation

/// What the inbox screen reads, and the one thing that keeps it filled.
///
/// It owns the connection rather than the sheet does, and that is the whole point: a socket
/// that lives as long as a sheet is open is a socket that hears nothing while a reader is
/// looking at their timeline, which is every moment that matters. This is started when the app
/// is, and it goes on listening whether or not anybody is looking.
@MainActor
@Observable
final class NoticeModel {
    private let store: LocalStore
    private let tokens: TokenSource
    private let loader: NoticeLoader
    /// Where the last-asked time is kept. On disk rather than here, because the times worth
    /// saying are the ones nobody was looking at — see `Preferences.lastHeard`.
    private let remembering: Preferences

    /// The inbox, newest first. What the sheet draws.
    private(set) var notices: [Notice] = []
    /// How many nobody has looked at. What the bell would show.
    private(set) var unseen = 0
    /// When this device last heard anything at all — an arrival, or a catch-up that found
    /// nothing. Nil until the first one, on this device, ever. Shown as a fact, never as a
    /// promise: it says when the asking last worked, and nothing about when it will next.
    var lastHeard: Date? { remembering.lastHeard }

    /// Whether an ask the reader made themselves is still out. Only theirs: the listening and
    /// the background wake are not things anybody is waiting on, and a spinner for them would
    /// be the screen twitching at its own accord.
    private(set) var asking = false

    /// The listening. One task for every inbox at once; cancelled when the app goes away.
    @ObservationIgnored private var listening: Task<Void, Never>?

    init(store: LocalStore, tokens: TokenSource, registry: SourceRegistry,
         remembering: Preferences) {
        self.store = store
        self.tokens = tokens
        self.remembering = remembering
        self.loader = NoticeLoader(registry: registry, store: store)
    }

    /// Starts listening to every inbox there is, and reads back what is already stored so a
    /// relaunch shows the inbox before the network says anything.
    ///
    /// Starting twice is starting once. A screen that appears, disappears and appears again
    /// must not open a second socket to every server the reader is signed in to.
    func start(on servers: [Server]) async {
        await refresh()
        guard listening == nil else { return }

        let inboxes = await self.inboxes(among: servers)
        guard !inboxes.isEmpty else { return }

        listening = Task { [loader] in
            await loader.run(inboxes) { [weak self] arrived in
                await self?.heard(arrived)
            }
        }
    }

    /// Somebody signed in or out, so the inboxes are not the inboxes any more. The connections
    /// go and are made again from what is true now — there is no editing a socket.
    func restart(on servers: [Server]) async {
        stop()
        await start(on: servers)
    }

    func stop() {
        listening?.cancel()
        listening = nil
    }

    /// One catch-up and nothing more. What a background wake gets, and what a reader pulling
    /// the sheet down gets: the same read, because they are the same question.
    @discardableResult
    func catchUp(on servers: [Server]) async -> Int {
        let inboxes = await self.inboxes(among: servers)
        guard !inboxes.isEmpty else { return 0 }
        let round = await loader.catchUp(on: inboxes)
        // Nothing answered is not a quiet morning. Writing the time down here would have the
        // screen say a server was reached on an evening when none was, which is the one thing
        // this line must never do.
        guard round.reached else { return 0 }
        await heard(round.arrived)
        return round.arrived
    }

    /// The reader asked, rather than the schedule. The same catch-up the background wake makes,
    /// which is the point: asking by hand is not a lesser path that exists because the scheduled
    /// one is unreliable — it is the same question, put at a moment somebody chose.
    func askNow(on servers: [Server]) async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        await catchUp(on: servers)
    }

    /// Reads the store again. Every path that changes anything ends here, so what is drawn is
    /// always what was written rather than something assembled on the way past.
    func refresh() async {
        notices = (try? await store.notices()) ?? notices
        unseen = (try? await store.unseenNoticeCount()) ?? unseen
    }

    /// The reader looked. What was on the screen is marked, and what arrives while they are
    /// still reading is not — the edge is the newest notice that was there when they opened it.
    func markSeen() async {
        guard let newest = notices.first?.noticedAt else { return }
        _ = try? await store.markNoticesSeen(upTo: newest)
        await refresh()
    }

    private func heard(_ arrived: Int) async {
        remembering.lastHeard = Date()
        guard arrived > 0 else { return }
        await refresh()
    }

    /// Every account signed in anywhere, paired with the server it is signed in to and the
    /// token that proves it. A server nobody is signed in to has no inbox to read: there is no
    /// such thing as somebody else's notifications read as a stranger.
    private func inboxes(among servers: [Server]) async -> [NoticeLoader.Inbox] {
        guard let signedIn = try? await store.signedInByServer() else { return [] }
        let tokens = await tokens.tokens(for: servers)
        return servers.compactMap { server in
            guard let account = signedIn[server.endpoint], let token = tokens[server.endpoint] else { return nil }
            return NoticeLoader.Inbox(server: server, owner: account.authorId, token: token.accessToken)
        }
    }
}
