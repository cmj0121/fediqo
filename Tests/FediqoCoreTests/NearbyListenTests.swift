import Foundation
import Network
import Synchronization
import Testing
@testable import FediqoCore

/// #253's hand-over rule, with no radio: a listen owns a peer while it opens and hands it over
/// once it is ready, so a taker that ends the listen on its one join keeps the peer it took.
@Suite("A listen hands over the peer that joined", .serialized)
struct NearbyListenTests {
    /// A peer that only counts how often it was closed.
    final class Peer: NearbyPeerConnection, @unchecked Sendable {
        private let closes = Mutex(0)
        let peerName: String? = nil
        let frames = AsyncThrowingStream<NearbyFrame, any Error> { $0.finish() }

        func send(_ frame: NearbyFrame) async throws {}
        func close() { closes.withLock { $0 += 1 } }
        var closed: Int { closes.withLock { $0 } }
    }

    private static func listen() -> (NearbyListen<Peer>, AsyncThrowingStream<NearbyArrival, any Error>) {
        let (stream, continuation) = AsyncThrowingStream<NearbyArrival, any Error>.makeStream()
        let listen = NearbyListen<Peer>(continuation)
        continuation.onTermination = { _ in listen.end() }
        return (listen, stream)
    }

    /// Opens `peer` on a listen, hands it over, and takes it as the hold does: the first
    /// arrival, and the listen ends as the loop leaves — the stream gone with this call.
    private static func takeOne(_ peer: Peer) async throws -> (NearbyListen<Peer>, (any NearbyPeerConnection)?) {
        let (listen, stream) = Self.listen()
        listen.opening(peer)
        listen.joined(peer)
        for try await arrival in stream {
            if case .joined(let connection) = arrival { return (listen, connection) }
            break
        }
        return (listen, nil)
    }

    @Test("A peer that joined survives the listen's end: the taker, which ended it, closes it")
    func joinedSurvives() async throws {
        let peer = Peer()
        let (listen, taken) = try await Self.takeOne(peer)
        let stillOpen: Bool = listen.opening(Peer())
        let same: Bool = (taken as? Peer) === peer
        let closed: Int = peer.closed
        #expect(!stillOpen, "the listen has ended")
        #expect(same)
        #expect(closed == 0, "the listen's end must not close a peer it handed over")
        #expect(listen.opened == 0)
    }

    @Test("A peer still opening when the listen ends is closed with it")
    func unhandedIsClosed() {
        let (listen, stream) = Self.listen()
        let handed = Peer()
        let opening = Peer()
        listen.opening(handed)
        listen.joined(handed)
        listen.opening(opening)
        withExtendedLifetime(stream) { listen.end() }
        let closedOpening: Int = opening.closed
        let closedHanded: Int = handed.closed
        #expect(closedOpening == 1)
        #expect(closedHanded == 0)
    }

    @Test("A peer that failed is released and said as a guess only where the handshake failed")
    func failedIsReleased() async throws {
        let (listen, stream) = Self.listen()
        let probe = Peer()
        let guess = Peer()
        listen.opening(probe)
        listen.opening(guess)
        listen.failed(probe, handshake: false)
        listen.failed(guess, handshake: true)
        #expect(listen.opened == 0)
        var guesses = 0
        for try await arrival in stream {
            if case .failedHandshake = arrival { guesses += 1 }
            break
        }
        let closedProbe: Int = probe.closed
        let closedGuess: Int = guess.closed
        #expect(guesses == 1)
        #expect(closedProbe == 0 && closedGuess == 0, "a failed peer closed itself; the listen does not again")
    }

    @Test("A peer that opens or becomes ready after the listen ended has no taker, and is closed")
    func lateIsClosed() {
        let (listen, stream) = Self.listen()
        let early = Peer()
        listen.opening(early)
        withExtendedLifetime(stream) { listen.end() }
        listen.joined(early)
        let late = Peer()
        let taken: Bool = listen.opening(late)
        let closedEarly: Int = early.closed
        let closedLate: Int = late.closed
        #expect(!taken)
        #expect(closedEarly == 1)
        #expect(closedLate == 1)
    }

    @Test("Progress is logged once per tenth, and a resume starts where it resumed")
    func milestones() {
        var fresh = NearbyLog.Milestones()
        var logged: [Int] = []
        for done in stride(from: Int64(0), through: 1000, by: 50) {
            if let percent = fresh.passed(done: done, total: 1000) { logged.append(percent) }
        }
        #expect(logged == [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        var resumed = NearbyLog.Milestones()
        let first: Int? = resumed.passed(done: 430, total: 1000)
        let same: Int? = resumed.passed(done: 440, total: 1000)
        #expect(first == 40)
        #expect(same == nil)
    }

    @Test("A line holds a side, a phrase and a kind — never an error's description")
    func lines() {
        let plain: String = NearbyLog.line(.receiver, "joined")
        let refused: String = NearbyLog.line(.sender, "refused", NetLog.kind(of: NearbyRefusal.other("secret words")))
        let reset: String = NWNearbyLink.kind(NWError.posix(.ECONNRESET))
        let tls: String = NWNearbyLink.kind(NWError.tls(-9806))
        #expect(plain == "receiver joined")
        #expect(refused == "sender refused: NearbyRefusal.other")
        #expect(reset == "posix 54")
        #expect(tls == "tls -9806")
    }
}
