import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #293: what waits in a source's line of loads is dropped when the reader lets the source go —
/// removes it, clears it, or signs out of it — and what is on the wire for it ends there too.
@MainActor
@Suite("Letting a source go drops its loads")
struct LoadsLetGoTests {
    private let host = "social.example"

    /// One load held on the wire until the test lets it through, and whether it was asked.
    private actor Held {
        private var entered: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?
        private(set) var asked = 0

        func work() async -> LoadAnswer {
            asked += 1
            for waiter in entered { waiter.resume() }
            entered = []
            await withCheckedContinuation { release = $0 }
            return .answered()
        }

        func onTheWire() async {
            guard asked == 0 else { return }
            await withCheckedContinuation { entered.append($0) }
        }

        func letThrough() {
            release?.resume()
            release = nil
        }
    }

    private func shell() async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.reading))
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        await store.add(Source(host: "other.example", kind: .mastodon))
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: ActServer([:]))
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        return session
    }

    /// One load of `host` on the wire, one waiting behind it, and one waiting on another source.
    private func lined(_ session: ShellSession) async throws -> (held: Held, onWire: LoadTicket, waiting: LoadTicket, other: LoadTicket, otherHeld: Held) {
        let held = Held(), otherHeld = Held()
        guard case .taken(let onWire) = await session.loads.ask(host: host, id: "a", { await held.work() }),
              case .taken(let waiting) = await session.loads.ask(host: host, id: "b", { .answered() }),
              case .taken(let other) = await session.loads.ask(host: "other.example", id: "c", { await otherHeld.work() })
        else { throw CancellationError() }
        await held.onTheWire()
        await otherHeld.onTheWire()
        let standing = await session.loads.standing(host: host)
        #expect(standing.waiting == 1 && standing.onTheWire == 1, "the premise: one on the wire, one behind it")
        return (held, onWire, waiting, other, otherHeld)
    }

    private func settled(_ session: ShellSession, _ lined: (held: Held, onWire: LoadTicket, waiting: LoadTicket, other: LoadTicket, otherHeld: Held)) async {
        // Asked of the line first: a line still standing would leave the tickets below unended.
        let standing = await session.loads.standing(host: host)
        #expect(standing == LoadStanding(), "the source's line is gone")
        guard standing == LoadStanding() else {
            await session.loads.letGo(host: host)
            await lined.held.letThrough()
            await lined.otherHeld.letThrough()
            return
        }
        #expect(await lined.waiting.end() == .letGo, "what waited was dropped, and never asked")
        await lined.held.letThrough()
        #expect(await lined.onWire.end() == .letGo, "what was on the wire ends there")
        // Another source's line is its own.
        #expect(await session.loads.standing(host: "other.example").onTheWire == 1)
        await lined.otherHeld.letThrough()
        #expect(await lined.other.end() == .done)
    }

    @Test("Removing a source drops its loads, and leaves another source's")
    func removed() async throws {
        let session = try await shell()
        let lined = try await lined(session)
        await session.remove(host: host)
        await settled(session, lined)
    }

    @Test("Clearing a source drops its loads")
    func cleared() async throws {
        let session = try await shell()
        let lined = try await lined(session)
        await session.clear(host: host)
        await settled(session, lined)
    }

    @Test("Signing out of a source drops its loads")
    func signedOut() async throws {
        let session = try await shell()
        let lined = try await lined(session)
        await session.signOut(host: host)
        await settled(session, lined)
    }

    @Test("A load is listed where other reads are, under words a reader knows, in each language")
    func named() {
        #expect(SourceWork.Purpose.allCases.contains(.reference) && !SourceWork.Purpose.reference.gathers)
        #expect(L10n.t(SourceWork.Purpose.reference.titleKey, language: .english) == "Reading a post another post refers to")
        #expect(L10n.t(SourceWork.Purpose.reference.titleKey, language: .taiwanese) == "讀取另一則貼文提到的貼文")
        #expect(!SourceWork.Purpose.reference.symbol.isEmpty)
    }
}
