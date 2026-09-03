import Foundation
import OSLog

/// Keeps the inboxes of every signed-in account up to date, without anybody polling anything.
///
/// One inbox is one account on one server. A reader signed in to three servers has three, and
/// they are read separately and stored separately: an event is a thing that happened on one
/// machine to one account, and there is no merging to be done.
///
/// Each inbox is read the same way twice over. **The catch-up** asks what happened since the
/// last event this device saw, which is what a relaunch, a reconnect and a background wake all
/// need. **The stream** holds one connection open and hears about the rest as they happen.
/// The catch-up runs first every time the stream is dialled, because a connection that opens at
/// 10:05 says nothing about 10:00 — and the hole that leaves is exactly the hole #9 exists to
/// close.
///
/// Nothing here is registered with anybody. There is no Fediqo server, no push token, no third
/// party told that this device would like to hear about you: a socket to the server the reader
/// already signed in to, and nothing else leaves.
public actor NoticeLoader {
    /// One account's inbox on one server.
    public struct Inbox: Sendable, Hashable {
        public let server: Server
        /// The actor URI of the account signed in there — whose inbox this is.
        public let owner: String
        public let token: String

        public init(server: Server, owner: String, token: String) {
            self.server = server
            self.owner = owner
            self.token = token
        }
    }

    /// How long before a connection that dropped is dialled again.
    ///
    /// Not `ServerBackoff`, and the two are answering different questions. That one is asked
    /// *may I ask now* by a refresh that ticks whether or not anybody failed, and it holds a
    /// whole set of endpoints against one clock. This is asked *how long do I wait* by one
    /// connection that has nothing else to do until it is back — so it is a ladder rather than
    /// a gate, and it belongs to the task that climbs it.
    ///
    /// A socket drops for reasons that are not the server's fault and are over in a second — a
    /// phone changing network, a laptop waking — so the first step is short. It stops
    /// doubling at half a minute: a server that has been refusing for five minutes will refuse
    /// for the sixth, and an app that has gone quiet for an hour to prove it is not being
    /// polite, it is broken.
    static let ladder: [Duration] = [.seconds(1), .seconds(3), .seconds(8), .seconds(20), .seconds(30)]

    private static let log = Logger(subsystem: "dev.mini-poc.fediqo", category: "notices")

    private let registry: SourceRegistry
    private let store: LocalStore
    /// How many to ask for in one catch-up. Mastodon's own ceiling is 80 and its default 15;
    /// a page of 40 covers a night in a pocket without asking a server for a page it will
    /// refuse to give.
    private let limit: Int

    public init(registry: SourceRegistry, store: LocalStore, limit: Int = 40) {
        self.registry = registry
        self.store = store
        self.limit = limit
    }

    /// Everything that happened in these inboxes since this device last looked, kept, and how
    /// many of them were new.
    ///
    /// The whole of what a background wake does. It is also the first thing `run` does for
    /// each inbox, so a reader who opened the app after an hour away sees the hour rather
    /// than whatever arrives next.
    ///
    /// One inbox failing is that inbox's failure. The others are still read: a server that is
    /// down has said nothing about anybody else's.
    @discardableResult
    public func catchUp(on inboxes: [Inbox], now: Date = Date()) async -> CatchUp {
        var new = 0
        var answered = 0
        for inbox in inboxes {
            do {
                new += try await catchUp(on: inbox, now: now)
                answered += 1
            } catch {
                Self.log.info("catch-up failed for \(inbox.server.endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return CatchUp(arrived: new, answered: answered, asked: inboxes.count)
    }

    /// What one round of asking came to.
    ///
    /// It carries `answered` and not only `arrived` because those two zeroes are different
    /// zeroes and a screen has to tell them apart: nothing new is a quiet morning, and nothing
    /// **answered** is a device that did not manage to ask anybody. A caller that saw only the
    /// count would write down "last asked just now" on the strength of every server refusing.
    public struct CatchUp: Sendable, Equatable {
        /// How many were new to this device.
        public let arrived: Int
        /// How many inboxes answered at all, whether or not they had anything to say.
        public let answered: Int
        /// How many were asked.
        public let asked: Int

        /// Whether this device managed to ask anybody. One server out of three is enough:
        /// something was heard, and what it was heard about is on the screen.
        public var reached: Bool { answered > 0 }

        public init(arrived: Int, answered: Int, asked: Int) {
            self.arrived = arrived
            self.answered = answered
            self.asked = asked
        }
    }

    /// Reads what was missed and then listens, for every inbox at once, until cancelled.
    ///
    /// `onArrival` is called after the store has been written and never before: a screen woken
    /// by this and reading the store immediately must find what it was woken about. It is
    /// handed how many were new, which is zero for a reconnect that turned up nothing — worth
    /// saying, because a screen showing "last checked" has been told something by that.
    public func run(_ inboxes: [Inbox], onArrival: @escaping @Sendable (Int) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for inbox in inboxes {
                group.addTask { await self.hold(inbox, onArrival: onArrival) }
            }
            await group.waitForAll()
        }
    }

    // MARK: - One inbox

    /// The catch-up, then the connection, then the catch-up again — for as long as this task
    /// is allowed to run.
    private func hold(_ inbox: Inbox, onArrival: @escaping @Sendable (Int) async -> Void) async {
        var rung = 0
        while !Task.isCancelled {
            let held = await listenOnce(inbox, onArrival: onArrival)
            guard !Task.isCancelled else { return }

            // A connection that carried something before it dropped is a working connection
            // that ended, not a server refusing us: the next attempt starts from the bottom
            // of the ladder rather than from wherever the last bad night left it.
            rung = held ? 0 : min(rung + 1, Self.ladder.count - 1)
            try? await Task.sleep(for: Self.ladder[rung])
        }
    }

    /// One catch-up and one connection, until it ends. Says whether anything came through it,
    /// which is what decides where the ladder starts next time.
    private func listenOnce(_ inbox: Inbox, onArrival: @escaping @Sendable (Int) async -> Void) async -> Bool {
        guard let client = registry.client(for: inbox.server.socialProtocol) else { return false }

        // First, so that the hole between the last event this device saw and the moment this
        // socket opens is closed rather than left. A connection made at 10:05 is silent about
        // 10:00, and silence is what #9 is about.
        do {
            let new = try await catchUp(on: inbox)
            await onArrival(new)
        } catch {
            Self.log.info("catch-up before listening failed for \(inbox.server.endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        var carried = false
        do {
            for try await notice in client.noticeStream(host: inbox.server.host, owner: inbox.owner, token: inbox.token) {
                carried = true
                let new = await keep([notice], from: inbox)
                await onArrival(new)
            }
        } catch {
            Self.log.info("stream ended for \(inbox.server.endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return carried
    }

    /// What happened in one inbox since this device last looked, kept.
    @discardableResult
    private func catchUp(on inbox: Inbox, now: Date = Date()) async throws -> Int {
        guard let client = registry.client(for: inbox.server.socialProtocol) else { return 0 }

        let after = try await store.noticeMark(from: inbox.server.endpoint, as: inbox.owner)
        let notices = try await client.notices(host: inbox.server.host, owner: inbox.owner,
                                               after: after, limit: limit, token: inbox.token)
        return await keep(notices, from: inbox, now: now)
    }

    /// Writes what arrived and moves the mark. Says how many of them this device had not
    /// already been told about — a live event and the catch-up that follows a reconnect will
    /// both carry some of the same ones, and a screen must not count those twice.
    private func keep(_ notices: [Notice], from inbox: Inbox, now: Date = Date()) async -> Int {
        guard !notices.isEmpty else { return 0 }
        do {
            let new = try await store.save(notices, from: inbox.server, as: inbox.owner, now: now)
            // The newest id this device has seen arrive, whether or not it was new to the
            // store: the mark is where to read from next, not what was written this time.
            if let newest = notices.map(\.remoteId).max() {
                try await store.setNoticeMark(newest, from: inbox.server.endpoint, as: inbox.owner, now: now)
            }
            return new
        } catch {
            Self.log.error("keeping \(notices.count) notices from \(inbox.server.endpoint, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }
}
