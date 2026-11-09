import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import FediqoCore

/// U4: two devices pair once with the six digits, agree one secret, and keep it.
@Suite("Pairing two devices with the code")
struct SyncPairingTests {
    private static let when = Date(timeIntervalSince1970: 1_800_000_000)

    private func pairing(_ link: PipeNearbyLink, _ store: MemoryPairStore, device: String, name: String, guessCap: Int = 5) -> SyncPairing {
        SyncPairing(link: link, pairs: store, device: device, name: name, guessCap: guessCap, now: { Self.when })
    }

    /// The pairing hold under `sessionID`, as a browser lists it.
    private func hold(on link: PipeNearbyLink, sessionID: String) async throws -> NearbyPeer {
        for try await peers in link.browse() {
            if let peer = peers.first(where: { $0.sessionID == sessionID }) { return peer }
        }
        throw NearbyDropped()
    }

    /// Holds on `holder` and joins it from `joiner` with the code shown: the last
    /// event on each side.
    private func pair(
        _ link: PipeNearbyLink, holder: SyncPairing, joiner: SyncPairing
    ) async throws -> (held: PairingEvent?, joined: PairingEvent?) {
        let held = await holder.hold()
        var events = held.makeAsyncIterator()
        guard case .code(let code, let sessionID) = await events.next() else { throw NearbyDropped() }
        let peer = try await hold(on: link, sessionID: sessionID)
        var joined: PairingEvent?
        for await event in await joiner.join(peer: peer, code: code) { joined = event }
        var last: PairingEvent?
        while let event = await events.next() { last = event }
        return (last, joined)
    }

    @Test("A code-proven join agrees one pair secret, and both sides keep it")
    func agrees() async throws {
        let link = PipeNearbyLink()
        let mac = MemoryPairStore(), phone = MemoryPairStore()
        let (held, joined) = try await pair(
            link, holder: pairing(link, mac, device: "MAC", name: "Mac"), joiner: pairing(link, phone, device: "PHONE", name: "Phone")
        )
        #expect(held == .paired(PairedDevice(device: "PHONE", name: "Phone", pairedAt: Self.when)))
        #expect(joined == .paired(PairedDevice(device: "MAC", name: "Mac", pairedAt: Self.when)))
        let a = try #require(try mac.secret(for: "PHONE"))
        let b = try #require(try phone.secret(for: "MAC"))
        #expect(a == b && a.bitCount == 256)
        #expect(try mac.pairs().map(\.device) == ["PHONE"] && phone.pairs().map(\.device) == ["MAC"])
        // Everything after the proof rode sealed: the secret's halves never crossed in the clear.
        let tags = Set(link.transcript.compactMap(\.first))
        #expect(!tags.contains(NearbyFrame.Tag.sync.rawValue))
    }

    @Test("A pairing hold is listed as one; a Move hold is not")
    func listed() async throws {
        let link = PipeNearbyLink()
        let psk = NearbyCode.psk(code: "123456", sessionID: "p")
        let pairingHold = link.advertisePairing(name: "Mac", sessionID: "p", psk: psk)
        let moveHold = link.advertise(name: "Mac", sessionID: "m", psk: psk)
        #expect(link.peers.first { $0.sessionID == "p" }?.pairing == true)
        #expect(link.peers.first { $0.sessionID == "m" }?.pairing == false)
        _ = (pairingHold, moveHold)
    }

    @Test("A wrong code pairs nothing, and the holder rolls its code")
    func wrongCode() async throws {
        let link = PipeNearbyLink()
        let mac = MemoryPairStore(), phone = MemoryPairStore()
        let holder = pairing(link, mac, device: "MAC", name: "Mac")
        var events = await holder.hold().makeAsyncIterator()
        guard case .code(let code, let sessionID) = await events.next() else { throw NearbyDropped() }
        let peer = try await hold(on: link, sessionID: sessionID)
        let wrong = code == "000000" ? "000001" : "000000"
        var joined: PairingEvent?
        for await event in await pairing(link, phone, device: "PHONE", name: "Phone").join(peer: peer, code: wrong) { joined = event }
        #expect(joined == .refused(.wrongCode))
        guard case .code(_, let rolled) = await events.next() else { throw NearbyDropped() }
        #expect(rolled != sessionID)
        await holder.stop()
        #expect(try mac.pairs().isEmpty && phone.pairs().isEmpty)
        #expect(try mac.secret(for: "PHONE") == nil && phone.secret(for: "MAC") == nil)
    }

    @Test("Wrong codes past the cap close the hold as someone guessing")
    func guessing() async throws {
        let link = PipeNearbyLink()
        let holder = pairing(link, MemoryPairStore(), device: "MAC", name: "Mac", guessCap: 2)
        var events = await holder.hold().makeAsyncIterator()
        var last: PairingEvent?
        while let event = await events.next() {
            last = event
            guard case .code(let code, let sessionID) = event else { continue }
            let peer = try await hold(on: link, sessionID: sessionID)
            let wrong = code == "000000" ? "000001" : "000000"
            _ = try? await link.connect(to: peer, psk: NearbyCode.psk(code: wrong, sessionID: sessionID))
        }
        #expect(last == .refused(.guessing))
    }

    @Test("A hold nobody joins times out")
    func timesOut() async {
        let holder = SyncPairing(link: PipeNearbyLink(), pairs: MemoryPairStore(), device: "MAC", name: "Mac", holdClock: {})
        var last: PairingEvent?
        for await event in await holder.hold() { last = event }
        #expect(last == .refused(.timedOut))
    }

    /// One listen per pair `store` holds, keyed by its secret, as a sync listener is; and
    /// whether a join under `secret` gets into any of them.
    private func joins(_ link: PipeNearbyLink, listeningFor store: MemoryPairStore, under secret: SymmetricKey) async throws -> Bool {
        var listens: [AsyncThrowingStream<NearbyArrival, any Error>] = []
        defer { _ = listens }
        var holds: [NearbyPeer] = []
        for pair in try store.pairs() {
            let kept = try #require(try store.secret(for: pair.device))
            let session = "listen-\(pair.device)"
            listens.append(link.advertise(name: "Mac", sessionID: session, psk: kept))
            holds.append(NearbyPeer(id: session, name: "Mac", sessionID: session))
        }
        var joined = false
        for hold in holds {
            do {
                try await link.connect(to: hold, psk: secret).close()
                joined = true
            } catch NearbyRefusal.wrongCode {}
        }
        return joined
    }

    @Test("Forget removes the pair on this side, and the other no longer joins")
    func forget() async throws {
        let link = PipeNearbyLink()
        let mac = MemoryPairStore(), phone = MemoryPairStore(), tablet = MemoryPairStore()
        _ = try await pair(link, holder: pairing(link, mac, device: "MAC", name: "Mac"), joiner: pairing(link, phone, device: "PHONE", name: "Phone"))
        _ = try await pair(link, holder: pairing(link, mac, device: "MAC", name: "Mac"), joiner: pairing(link, tablet, device: "TAB", name: "Tablet"))
        let phoneSecret = try #require(try phone.secret(for: "MAC"))
        #expect(try await joins(link, listeningFor: mac, under: phoneSecret), "paired, the phone gets in")

        try mac.forget(device: "PHONE")
        #expect(try mac.pairs().map(\.device) == ["TAB"])
        #expect(try mac.secret(for: "PHONE") == nil)
        #expect(try mac.pairs().allSatisfy { try mac.secret(for: $0.device) != phoneSecret }, "the forgotten secret is gone")
        // The phone still holds its side; under it, nothing the Mac now listens for opens.
        #expect(try phone.secret(for: "MAC") == phoneSecret)
        #expect(!(try await joins(link, listeningFor: mac, under: phoneSecret)), "forgotten, the phone no longer gets in")
        let tabletSecret = try #require(try tablet.secret(for: "MAC"))
        #expect(try await joins(link, listeningFor: mac, under: tabletSecret), "the pair kept still gets in")
    }

    @Test("Starting again leaves the new stream open and working; the old start never closes it")
    func restart() async throws {
        let link = PipeNearbyLink()
        let mac = MemoryPairStore()
        let holder = pairing(link, mac, device: "MAC", name: "Mac")
        let first = await holder.hold()
        var held = await holder.hold().makeAsyncIterator()
        guard case .code(let code, let sessionID) = await held.next() else { throw NearbyDropped() }
        for await _ in first {}
        // The first hold's task has gone: its listen left the pipe, and it had every chance to end.
        while link.peers.count > 1 { await Task.yield() }
        for _ in 0..<200 { await Task.yield() }
        let peer = try await hold(on: link, sessionID: sessionID)
        for await _ in await pairing(link, MemoryPairStore(), device: "PHONE", name: "Phone").join(peer: peer, code: code) {}
        #expect(await held.next() == .paired(PairedDevice(device: "PHONE", name: "Phone", pairedAt: Self.when)))

        var again = await holder.hold().makeAsyncIterator()
        guard case .code = await again.next() else { throw NearbyDropped() }
        await holder.stop()
        #expect(await again.next() == nil, "stopped, the stream ends")
    }

    @Test("Paired near the hold's end, the first merge still finishes: the hold's clock stops at pairing")
    func clockStopsAtPairing() async throws {
        let link = PipeNearbyLink()
        let (fire, firing) = AsyncStream<Void>.makeStream()
        let (fired, firedSink) = AsyncStream<Void>.makeStream()
        let holder = SyncPairing(
            link: link, pairs: MemoryPairStore(), device: "MAC", name: "Mac",
            holdClock: {
                for await _ in fire { break }
                firedSink.yield()
            },
            now: { Self.when },
            firstMerge: { _, _ in
                // Waits until the hold's clock ran out, or was stopped.
                for await _ in fired { break }
                return .nothingToMerge
            }
        )
        let joiner = SyncPairing(
            link: link, pairs: MemoryPairStore(), device: "PHONE", name: "Phone", now: { Self.when },
            firstMerge: { _, _ in .nothingToMerge }
        )
        var events = await holder.hold().makeAsyncIterator()
        guard case .code(let code, let sessionID) = await events.next() else { throw NearbyDropped() }
        let peer = try await hold(on: link, sessionID: sessionID)
        for await _ in await joiner.join(peer: peer, code: code) {}
        let phone = PairedDevice(device: "PHONE", name: "Phone", pairedAt: Self.when)
        #expect(await events.next() == .paired(phone))
        firing.yield()
        var rest: [PairingEvent] = []
        while let event = await events.next() { rest.append(event) }
        #expect(rest == [.merging(phone), .done(phone, .nothingToMerge)])
    }

    @Test("The hold's time running out as the channel opens: a pair kept is paired and merged, one not kept is cut", arguments: [true, false])
    func clockAtPairing(kept: Bool) async throws {
        let link = PipeNearbyLink()
        let (fire, firing) = AsyncStream<Void>.makeStream()
        let store = KeepAtTheEnd(firing: firing, keeps: kept)
        let holder = SyncPairing(
            link: link, pairs: store, device: "MAC", name: "Mac",
            holdClock: { for await _ in fire { break } },
            now: { Self.when },
            firstMerge: { _, _ in .nothingToMerge }
        )
        let joiner = SyncPairing(
            link: link, pairs: MemoryPairStore(), device: "PHONE", name: "Phone", now: { Self.when },
            firstMerge: { opened, _ in
                // Reads (a refusal, where the holder said one) until the holder cuts the channel.
                while (try? await opened.channel.next()) != nil {}
                return .notMerged(.lost)
            }
        )
        var events = await holder.hold().makeAsyncIterator()
        guard case .code(let code, let sessionID) = await events.next() else { throw NearbyDropped() }
        let peer = try await hold(on: link, sessionID: sessionID)
        var joined: [PairingEvent] = []
        for await event in await joiner.join(peer: peer, code: code) { joined.append(event) }
        var rest: [PairingEvent] = []
        while let event = await events.next() { rest.append(event) }

        let phone = PairedDevice(device: "PHONE", name: "Phone", pairedAt: Self.when)
        #expect(rest == (kept ? [.paired(phone), .merging(phone), .done(phone, .nothingToMerge)] : [.refused(.timedOut)]))
        #expect(try store.pairs().map(\.device) == (kept ? ["PHONE"] : []))
        #expect(joined.last == .done(PairedDevice(device: "MAC", name: "Mac", pairedAt: Self.when), .notMerged(.lost)), "the channel was cut")
    }

    @Test("The same id on both ends pairs nothing")
    func sameDevice() async throws {
        let link = PipeNearbyLink()
        let a = MemoryPairStore(), b = MemoryPairStore()
        let (held, joined) = try await pair(link, holder: pairing(link, a, device: "SAME", name: "A"), joiner: pairing(link, b, device: "SAME", name: "B"))
        #expect(held == .sameDevice && joined == .sameDevice)
        #expect(try a.pairs().isEmpty && b.pairs().isEmpty)
    }

    @Test("Pairing again replaces the pair and its secret, its first merge not yet made")
    func again() async throws {
        let link = PipeNearbyLink()
        let mac = MemoryPairStore(), phone = MemoryPairStore()
        _ = try await pair(link, holder: pairing(link, mac, device: "MAC", name: "Mac"), joiner: pairing(link, phone, device: "PHONE", name: "Phone"))
        let first = try #require(try mac.secret(for: "PHONE"))
        var merged = try #require(try mac.pairs().first)
        merged.firstMerged = true
        try mac.update(merged)
        _ = try await pair(link, holder: pairing(link, mac, device: "MAC", name: "Mac"), joiner: pairing(link, phone, device: "PHONE", name: "Phone"))
        #expect(try mac.pairs().count == 1 && mac.pairs().first?.firstMerged == false)
        #expect(try mac.secret(for: "PHONE") != first && mac.secret(for: "PHONE") == phone.secret(for: "MAC"))
    }

    @Test("The secret is HKDF of both nonces, salted by the session, bound to both ids in order")
    func secret() {
        let s = PairHello(device: "S", name: "s", nonce: Data(repeating: 1, count: 32))
        let r = PairHello(device: "R", name: "r", nonce: Data(repeating: 2, count: 32))
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(repeating: 1, count: 32) + Data(repeating: 2, count: 32)),
            salt: Data("sid".utf8), info: Data("fediqo-sync-1 pairS\u{0}R".utf8), outputByteCount: 32
        )
        #expect(SyncPairing.secret(sender: s, receiver: r, sessionID: "sid") == expected)
        #expect(SyncPairing.secret(sender: r, receiver: s, sessionID: "sid") != expected)
        #expect(SyncPairing.secret(sender: s, receiver: r, sessionID: "other") != expected)
    }

    @Test("Pairing frames round-trip; a wrong nonce or kind is malformed, another version said as such")
    func frames() throws {
        let hello = PairHello(device: "D", name: "Mac", nonce: Data(repeating: 7, count: 32))
        for frame in [SyncFrame.pairHello(hello), .paired] {
            let data = try frame.encode()
            #expect(data.first == SyncFrame.version)
            #expect(try SyncFrame.decode(data) == frame)
            #expect(try NearbyFrame.decode(NearbyFrame.sync(data).encode()) == .sync(data))
        }
        #expect(try NearbyFrame.sync(SyncFrame.paired.encode()).encode().first == 11)
        let short = try SyncFrame.pairHello(PairHello(device: "D", name: "Mac", nonce: Data(count: 31))).encode()
        #expect(throws: NearbyRefusal.malformed) { try SyncFrame.decode(short) }
        #expect(throws: NearbyRefusal.malformed) { try SyncFrame.decode(Data([1, 99])) }
        #expect(throws: SyncRefusal.otherVersion(2)) { try SyncFrame.decode(Data([2, 7])) }
        #expect(throws: NearbyRefusal.malformed) { try SyncFrame.decode(Data([1, 7, 0])) }
        #expect(throws: NearbyRefusal.malformed) { try NearbyFrame.decode(Data([11, 1])) }
    }
}

/// A pair store whose `keep` lets the hold's clock run out first: it fires the clock and waits
/// until the hold is put away for it, then keeps the pair or, where `keeps` is false, throws.
final class KeepAtTheEnd: PairStore {
    private let kept = MemoryPairStore()
    private let firing: AsyncStream<Void>.Continuation
    private let keeps: Bool

    init(firing: AsyncStream<Void>.Continuation, keeps: Bool) {
        self.firing = firing
        self.keeps = keeps
    }

    func pairs() throws -> [PairedDevice] { try kept.pairs() }
    func secret(for device: String) throws -> SymmetricKey? { try kept.secret(for: device) }
    func update(_ pair: PairedDevice) throws { try kept.update(pair) }
    func forget(device: String) throws { try kept.forget(device: device) }

    func keep(_ pair: PairedDevice, secret: SymmetricKey) throws {
        firing.yield()
        let deadline = Date().addingTimeInterval(5)
        while !Task.isCancelled, Date() < deadline { usleep(1000) }
        guard keeps else { throw CancellationError() }
        try kept.keep(pair, secret: secret)
    }
}

/// Pairs and secrets in memory, as the Keychain store keeps them.
final class MemoryPairStore: PairStore {
    private let held = Mutex<[String: (pair: PairedDevice, secret: SymmetricKey)]>([:])

    func pairs() throws -> [PairedDevice] {
        held.withLock { $0.values.map(\.pair).sorted { $0.device < $1.device } }
    }

    func secret(for device: String) throws -> SymmetricKey? {
        held.withLock { $0[device]?.secret }
    }

    func keep(_ pair: PairedDevice, secret: SymmetricKey) throws {
        held.withLock { $0[pair.device] = (pair, secret) }
    }

    func update(_ pair: PairedDevice) throws {
        held.withLock { held in
            guard let secret = held[pair.device]?.secret else { return }
            held[pair.device] = (pair, secret)
        }
    }

    func forget(device: String) throws {
        _ = held.withLock { $0.removeValue(forKey: device) }
    }
}
