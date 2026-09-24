import CryptoKit
import FediqoCore
import Foundation
import Synchronization
import Testing
@testable import FediqoPersistence

/// #253, #6 headless: two `NearbyMove`s in one process over `PipeNearbyLink`, a real
/// `StorePackager` on each side with its own scratch device. The receiver's store ends equal to
/// the sender's; a no on either side writes nothing; a wrong code never connects and rolls the
/// code; a cut link resumes from what the receiver holds; an altered stream is refused by #252's
/// checks; sign-ins only moves what signs in and nothing else.
@Suite("Moving a store to a device nearby", .serialized)
struct NearbyMoveTests {
    typealias Device = PackagerFixture.PackagerDevice
    typealias Event = NearbyMove.Event

    /// Every event one side emitted, read from any task.
    final class Watch: Sendable {
        private let held = Mutex<[Event]>([])
        private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

        init(_ events: AsyncStream<Event>) {
            task.withLock { $0 = Task { for await event in events { held.withLock { $0.append(event) } } } }
        }

        var events: [Event] { held.withLock { $0 } }

        /// Waits until an event answers `test`, or fails after a while.
        @discardableResult
        func until(_ what: String, _ test: (Event) -> Bool) async -> Event? {
            for _ in 0..<600 {
                if let found = events.first(where: test) { return found }
                try? await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("never saw \(what); saw \(events)")
            return nil
        }
    }

    /// A pair of devices joined by one pipe, and the two moves on them.
    struct Pair {
        let link = PipeNearbyLink()
        let from: Device
        let onto: Device
        let sender: NearbyMove
        let receiver: NearbyMove

        init(from: Device, onto: Device) {
            self.from = from
            self.onto = onto
            sender = NearbyMove(link: link, carrier: from.packager(), device: "a laptop", retryDelay: .milliseconds(20), retries: 20)
            receiver = NearbyMove(link: link, carrier: onto.packager(), device: "a tablet", retryDelay: .milliseconds(20), retries: 20)
        }

        func remove() {
            from.remove()
            onto.remove()
        }

        /// The receiver holding, with its code, and the peer the sender sees.
        func hold() async -> (Watch, String, NearbyPeer) {
            let held = Watch(await receiver.hold())
            guard case .code(let code)? = await held.until("a code", { if case .code = $0 { true } else { false } }) else {
                return (held, "", NearbyPeer(id: "", name: "", sessionID: ""))
            }
            for _ in 0..<100 where link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            return (held, code, link.peers[0])
        }
    }

    private static func isAsking(_ event: Event) -> Bool {
        if case .asking = event { true } else { false }
    }

    private static func isDone(_ event: Event) -> Bool {
        if case .done = event { true } else { false }
    }

    private static func isRefused(_ event: Event) -> Bool {
        if case .refused = event { true } else { false }
    }

    /// Drives a whole move where both say yes, and hands back both watches.
    private func moveWhole(_ pair: Pair, pictures: Bool, contents: PackageSummary.Contents = .whole) async -> (sent: Watch, held: Watch) {
        let (held, code, peer) = await pair.hold()
        #expect(peer.name == "a tablet" && NearbyCode.isWellFormed(code))
        let sent = Watch(await pair.sender.offer(to: peer, code: code, pictures: pictures, contents: contents))
        await sent.until("the sender's question", Self.isAsking)
        await held.until("the receiver's question", Self.isAsking)
        await pair.sender.answer(true)
        await pair.receiver.answer(true)
        await sent.until("the sender done", Self.isDone)
        await held.until("the receiver done", Self.isDone)
        return (sent, held)
    }

    @Test("Both say yes: the receiver's store, settings, sign-ins and pictures equal the sender's, and both record it under the other's name", arguments: [true, false])
    func wholeMove(pictures: Bool) async throws {
        let pair = Pair(from: try await PackagerFixture.populated(), onto: try await Device())
        defer { pair.remove() }
        let (sent, held) = await moveWhole(pair, pictures: pictures)

        guard case .asking(let offer, let peer, let replaces)? = held.events.first(where: Self.isAsking) else { return }
        // The sender's name is the one its package header carries: in the app the same name it
        // advertises under; here the fixture's carrier names itself.
        #expect(peer == "a test" && !replaces)
        #expect(offer.summary.posts == 3 && offer.summary.withPictures == pictures && offer.summary.device == "a test")
        #expect(offer.fileBytes > 0)
        guard case .asking(_, let to, _)? = sent.events.first(where: Self.isAsking) else { return }
        #expect(to == "a tablet")
        // Bytes were reported on both sides, and the estimate's total is the file's length.
        let moved = held.events.compactMap { if case .moving(let progress, _) = $0 { progress } else { nil } }
        #expect(moved.last?.done == Int(offer.fileBytes) && moved.first?.done == 0)
        #expect(sent.events.contains { if case .settling = $0 { true } else { false } })

        let onto = await pair.onto.store.snapshot()
        let from = await pair.from.store.snapshot()
        #expect(onto.sources == from.sources)
        #expect(onto.notes.map(\.id).sorted() == from.notes.map(\.id).sorted())
        #expect(try StoreFile(at: pair.onto.directory).load().notes.count == 3)
        #expect(pair.onto.defaults.string(forKey: "fediqo.dummy.keepMonths") == "6")
        #expect(try pair.onto.tokens.token(host: PackagerFixture.mastodon.host)?.accessToken == "t")
        #expect(try pair.onto.credentials.credential(host: PackagerFixture.forum.host)?.password == "hunter2")
        #expect(pair.onto.media.totalBytes() == (pictures ? 3100 : 0))
        // Nothing staged is left under the receiver's folder, and nothing more comes.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: pair.onto.directory.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("incoming-") }, "\(left)")
        try await Task.sleep(for: .milliseconds(30))
        #expect(held.events.filter(Self.isDone).count == 1 && sent.events.filter(Self.isDone).count == 1)
    }

    @Test("A receiver holding a store is asked to replace, and replaces only on that yes")
    func replaces() async throws {
        let other = Source(host: "other.example", kind: .mastodon)
        let pair = Pair(
            from: try await PackagerFixture.populated(),
            onto: try await Device(sources: [other], notes: [PackagerFixture.note("9", source: other)])
        )
        defer { pair.remove() }
        let (_, held) = await moveWhole(pair, pictures: false)
        guard case .asking(_, _, let replaces)? = held.events.first(where: Self.isAsking) else { return }
        #expect(replaces)
        let onto = await pair.onto.store.snapshot()
        #expect(onto.sources.map(\.host) == [PackagerFixture.mastodon.host, PackagerFixture.forum.host])
        #expect(!onto.notes.contains { $0.id == "9" })
    }

    @Test("A no on the receiver writes nothing on either device; a no on the sender likewise")
    func refusals() async throws {
        let pair = Pair(from: try await PackagerFixture.populated(), onto: try await Device())
        defer { pair.remove() }
        let before = try pair.onto.fingerprint()

        var (held, code, peer) = await pair.hold()
        var sent = Watch(await pair.sender.offer(to: peer, code: code, pictures: false, contents: .whole))
        await sent.until("the sender's question", Self.isAsking)
        await held.until("the receiver's question", Self.isAsking)
        await pair.sender.answer(true)
        await pair.receiver.answer(false)
        #expect(await sent.until("refused there", Self.isRefused) == .refused(.refusedThere))
        await held.until("closed", { $0 == .closed })
        await pair.receiver.stop()
        await pair.sender.stop()

        (held, code, peer) = await pair.hold()
        sent = Watch(await pair.sender.offer(to: peer, code: code, pictures: false, contents: .whole))
        await sent.until("the sender's question", Self.isAsking)
        await held.until("the receiver's question", Self.isAsking)
        await pair.sender.answer(false)
        await sent.until("closed", { $0 == .closed })
        await pair.receiver.answer(true)
        #expect(await held.until("refused there", Self.isRefused) == .refused(.refusedThere))
        await pair.receiver.stop()

        #expect(try pair.onto.fingerprint() == before)
        #expect(await pair.onto.store.sources().isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: pair.onto.directory.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("incoming-") })
    }

    @Test("A wrong code never connects, and the receiver rolls its code")
    func wrongCode() async throws {
        let pair = Pair(from: try await PackagerFixture.populated(), onto: try await Device())
        defer { pair.remove() }
        let (held, code, peer) = await pair.hold()
        let wrong = code == "000000" ? "000001" : "000000"
        let sent = Watch(await pair.sender.offer(to: peer, code: wrong, pictures: false, contents: .whole))
        #expect(await sent.until("wrong code", Self.isRefused) == .refused(.wrongCode))
        let rolled = await held.until("a new code", { if case .code(let next) = $0 { next != code } else { false } })
        #expect(rolled != nil)
        #expect(!held.events.contains(where: Self.isAsking))
        for _ in 0..<100 where pair.link.peers.first?.sessionID == peer.sessionID { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(pair.link.peers.first?.sessionID != peer.sessionID, "the session changes with the code")
        #expect(await pair.onto.store.sources().isEmpty)
        await pair.receiver.stop()
    }

    @Test("A link cut midway comes back where the receiver left off, and the store arrives whole")
    func resumes() async throws {
        let from = try await PackagerFixture.populated()
        // Enough that the package is several frames.
        try from.media.store(Data(repeating: 3, count: 700_000), host: PackagerFixture.mastodon.host, url: URL(string: "https://cdn.example/big.jpg")!)
        let pair = Pair(from: from, onto: try await Device())
        defer { pair.remove() }
        pair.link.cutNext(afterBytesFrames: 1)
        let (sent, held) = await moveWhole(pair, pictures: true)
        #expect(sent.events.contains { if case .reconnecting = $0 { true } else { false } })
        #expect(held.events.contains { if case .reconnecting = $0 { true } else { false } })
        // After the drop, the first progress on the receiver is what it already held, not zero.
        let moved = held.events.compactMap { if case .moving(let progress, _) = $0 { progress } else { nil } }
        let starts = moved.enumerated().filter { $0.offset > 0 && $0.element.done <= moved[$0.offset - 1].done }
        #expect(starts.count == 1 && starts.first?.element.done == NearbyFrame.mostBytes, "\(moved.map(\.done))")
        #expect(held.events.filter(Self.isAsking).count == 1, "no second question on the way back")
        #expect(pair.onto.media.totalBytes() == 3100 + 700_000)
        #expect(await pair.onto.store.snapshot().notes.count == 3)
    }

    @Test("A stream altered on the way is refused by the package's own checks, and nothing changes")
    func altered() async throws {
        let from = try await PackagerFixture.populated()
        try from.media.store(Data(repeating: 3, count: 300_000), host: PackagerFixture.mastodon.host, url: URL(string: "https://cdn.example/big.jpg")!)
        let onto = try await Device()
        let link = PipeNearbyLink()
        let tampering = TamperingLink(link)
        let sender = NearbyMove(link: tampering, carrier: from.packager(), device: "a laptop", retryDelay: .milliseconds(20), retries: 5)
        let receiver = NearbyMove(link: link, carrier: onto.packager(), device: "a tablet", retryDelay: .milliseconds(20), retries: 5)
        defer { from.remove(); onto.remove() }
        let before = try onto.fingerprint()

        let held = Watch(await receiver.hold())
        guard case .code(let code)? = await held.until("a code", { if case .code = $0 { true } else { false } }) else { return }
        for _ in 0..<100 where link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let sent = Watch(await sender.offer(to: link.peers[0], code: code, pictures: true, contents: .whole))
        await sent.until("the sender's question", Self.isAsking)
        await held.until("the receiver's question", Self.isAsking)
        await sender.answer(true)
        await receiver.answer(true)
        #expect(await held.until("refused", Self.isRefused) == .refused(.package(.altered)))
        #expect(await sent.until("refused there", Self.isRefused) == .refused(.refusedThere))
        #expect(try onto.fingerprint() == before)
        #expect(await onto.store.sources().isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: onto.directory.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("incoming-") })
    }

    @Test("Sign-ins only (#6) moves what signs in and nothing else, and leaves the receiver's other sign-ins")
    func signInsOnly() async throws {
        let other = Source(host: "other.example", kind: .discuz)
        let onto = try await Device(sources: [other], notes: [PackagerFixture.note("9", source: other)])
        try onto.credentials.save(ForumCredential(host: other.host, username: "bo", password: "keep"))
        let pair = Pair(from: try await PackagerFixture.populated(), onto: onto)
        defer { pair.remove() }
        let (sent, held) = await moveWhole(pair, pictures: true, contents: .signInsOnly)
        guard case .asking(let offer, _, let replaces)? = held.events.first(where: Self.isAsking) else { return }
        #expect(offer.summary.contents == .signInsOnly && offer.summary.posts == 0 && !offer.summary.withPictures)
        #expect(offer.summary.sources.map(\.host) == [PackagerFixture.mastodon.host, PackagerFixture.forum.host])
        #expect(replaces, "a store is held; the question says so, and nothing of it goes")
        guard case .done(let summary, _)? = sent.events.first(where: Self.isDone) else { return }
        #expect(summary.contents == .signInsOnly)

        let snapshot = await pair.onto.store.snapshot()
        #expect(snapshot.sources == [other] && snapshot.notes.map(\.id) == ["9"], "the store is untouched")
        #expect(pair.onto.defaults.string(forKey: "fediqo.dummy.keepMonths") == nil, "no settings ride")
        #expect(pair.onto.media.totalBytes() == 0, "no pictures ride")
        #expect(try pair.onto.tokens.token(host: PackagerFixture.mastodon.host)?.accessToken == "t")
        #expect(try pair.onto.tokens.app(host: PackagerFixture.mastodon.host)?.clientSecret == "s")
        #expect(try pair.onto.credentials.credential(host: PackagerFixture.forum.host)?.password == "hunter2")
        #expect(try pair.onto.credentials.credential(host: other.host)?.password == "keep", "another host's sign-in stays")
    }

    @Test("Not allowed to look nearby is said as that, on either side")
    func notAllowed() async throws {
        let pair = Pair(from: try await PackagerFixture.populated(), onto: try await Device())
        defer { pair.remove() }
        pair.link.deny()
        let held = Watch(await pair.receiver.hold())
        #expect(await held.until("not allowed", Self.isRefused) == .refused(.notAllowed))
        var peers: [[NearbyPeer]] = []
        do {
            for try await found in pair.link.browse() { peers.append(found) }
            Issue.record("browsing went on")
        } catch {
            #expect(error as? NearbyRefusal == .notAllowed)
        }
        #expect(peers.isEmpty)
    }
}

/// A link that changes one byte of the package on its way: what a splice looks like to the
/// receiver.
final class TamperingLink: NearbyLink, @unchecked Sendable {
    private let inner: PipeNearbyLink

    init(_ inner: PipeNearbyLink) {
        self.inner = inner
    }

    func advertise(name: String, sessionID: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error> {
        inner.advertise(name: name, sessionID: sessionID, psk: psk)
    }

    func browse() -> AsyncThrowingStream<[NearbyPeer], any Error> { inner.browse() }

    func connect(to peer: NearbyPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection {
        Tampered(try await inner.connect(to: peer, psk: psk))
    }

    final class Tampered: NearbyPeerConnection, @unchecked Sendable {
        private let inner: any NearbyPeerConnection
        private var tampered = false

        init(_ inner: any NearbyPeerConnection) { self.inner = inner }

        var peerName: String? { inner.peerName }
        var frames: AsyncThrowingStream<NearbyFrame, any Error> { inner.frames }

        func send(_ frame: NearbyFrame) async throws {
            // The second frame of bytes: past the prelude and header, inside an entry.
            if case .bytes(var data) = frame, data.count == NearbyFrame.mostBytes, !tampered {
                tampered = true
                data[data.count / 2] ^= 0x01
                try await inner.send(.bytes(data))
                return
            }
            try await inner.send(frame)
        }

        func close() { inner.close() }
    }
}
