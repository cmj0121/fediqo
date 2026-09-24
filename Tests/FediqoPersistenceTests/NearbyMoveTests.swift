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
            guard case .code(let code, _)? = await held.until("a code", { if case .code = $0 { true } else { false } }) else {
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
        let rolled = await held.until("a new code", { if case .code(let next, _) = $0 { next != code } else { false } })
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
        guard case .code(let code, _)? = await held.until("a code", { if case .code = $0 { true } else { false } }) else { return }
        for _ in 0..<100 where link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let sent = Watch(await sender.offer(to: link.peers[0], code: code, pictures: true, contents: .whole))
        await sent.until("the sender's question", Self.isAsking)
        await held.until("the receiver's question", Self.isAsking)
        await sender.answer(true)
        await receiver.answer(true)
        // A byte changed inside a sealed frame fails its tag before anything is written.
        #expect(await held.until("refused", Self.isRefused) == .refused(.malformed))
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

    /// A sender written by hand over the channel, for what `NearbyMove` would never send: an
    /// offer that does not match its package, or a package altered on disk. Hands back the
    /// receiver's last word and its watch.
    private func handSend(
        _ pair: Pair, file: URL, key: SymmetricKey, offer: NearbyOffer
    ) async throws -> (NearbyFrame?, Watch) {
        let (held, code, peer) = await pair.hold()
        let psk = NearbyCode.psk(code: code, sessionID: peer.sessionID)
        let connection = try await pair.link.connect(to: peer, psk: psk)
        defer { connection.close() }
        let channel = try await NearbyChannel.open(
            over: connection, inbox: PlainInbox(connection), role: .sender, psk: psk, sessionID: peer.sessionID
        )
        try await channel.send(.offer(offer))
        await held.until("the receiver's question", Self.isAsking)
        await pair.receiver.answer(true)
        guard case .accept = try await channel.next() else { return (nil, held) }
        try await channel.send(.key(key.withUnsafeBytes { Data($0) }))
        guard case .have(let have) = try await channel.next(), have == 0 else { return (nil, held) }
        let handle = try FileHandle(forReadingFrom: file)
        while let chunk = try handle.read(upToCount: NearbyFrame.mostBytes), !chunk.isEmpty {
            try await channel.send(.bytes(chunk))
        }
        try await channel.send(.done)
        let answer = try? await channel.next()
        await held.until("refused or done", { Self.isRefused($0) || Self.isDone($0) })
        return (answer ?? .refuse, held)
    }

    @Test("A package altered on disk is refused by #252's checks; an offer that is not its package is refused before")
    func alteredAndMismatched() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let pair = Pair(from: from, onto: onto)
        defer { pair.remove() }
        let before = try onto.fingerprint()
        let file = PackagerFixture.package()
        defer { try? FileManager.default.removeItem(at: file) }
        let key = SymmetricKey(size: .bits256)
        try await from.packager().takeAway(to: file, key: .direct(key), pictures: false, contents: .whole) { _ in }
        let summary = try await from.packager().preview(file, key: .direct(key))
        let bytes = Int64(try Data(contentsOf: file).count)

        // The offer says twice the posts the header does.
        let wrong = PackageSummary(
            contents: summary.contents, sources: summary.sources, posts: summary.posts * 2, timelines: summary.timelines,
            takenAt: summary.takenAt, withPictures: summary.withPictures, bytes: summary.bytes, hasSecrets: summary.hasSecrets,
            device: summary.device, appVersion: summary.appVersion, entryCount: summary.entryCount
        )
        var (answer, held) = try await handSend(pair, file: file, key: key, offer: NearbyOffer(summary: wrong, fileBytes: bytes))
        #expect(answer == .refuse)
        #expect(held.events.first(where: Self.isRefused) == .refused(.malformed))
        await pair.receiver.stop()

        // The file itself, one byte changed inside an entry.
        var data = try Data(contentsOf: file)
        data[data.count / 2] ^= 0x01
        try data.write(to: file)
        (answer, held) = try await handSend(pair, file: file, key: key, offer: NearbyOffer(summary: summary, fileBytes: bytes))
        #expect(answer == .refuse)
        #expect(held.events.first(where: Self.isRefused) == .refused(.package(.altered)))
        await pair.receiver.stop()
        #expect(try onto.fingerprint() == before)
        #expect(await onto.store.sources().isEmpty)
    }

    @Test("A link cut on the receiver's last word: it adopted once, and the sender rejoins to hear done")
    func cutOnTheLastWord() async throws {
        let pair = Pair(from: try await PackagerFixture.populated(), onto: try await Device())
        defer { pair.remove() }
        pair.link.cutNextBeforeLastWord()
        let (sent, held) = await moveWhole(pair, pictures: false)
        #expect(held.events.filter(Self.isDone).count == 1)
        #expect(sent.events.contains { if case .reconnecting = $0 { true } else { false } })
        #expect(sent.events.filter(Self.isDone).count == 1 && !sent.events.contains(where: Self.isRefused))
        #expect(await pair.onto.store.snapshot().notes.count == 3)
    }

    @Test("A recording of the wire holds nothing in the clear past the opening, and the code alone opens none of it")
    func wireIsSealed() async throws {
        let pair = Pair(from: try await PackagerFixture.populated(), onto: try await Device())
        defer { pair.remove() }
        let (_, held) = await moveWhole(pair, pictures: false)
        guard case .asking(let offer, _, _)? = held.events.first(where: Self.isAsking) else { return }
        let transcript = pair.link.transcript
        #expect(transcript.count > 6)
        let tags = Set(transcript.compactMap(\.first))
        #expect(tags == [NearbyFrame.Tag.hello.rawValue, NearbyFrame.Tag.confirm.rawValue, NearbyFrame.Tag.sealed.rawValue], "\(tags)")
        let offerJSON = try JSONEncoder().encode(offer)
        for frame in transcript {
            #expect(!frame.contains(Data(offer.id.utf8)) && frame.count != offerJSON.count + 1)
        }
        // The code and the session id, which a sniffer has, derive the transport key — and
        // that key opens no sealed frame.
        let session = pair.link.peers.first?.sessionID ?? ""
        let psk = NearbyCode.psk(code: "000000", sessionID: session)
        for frame in transcript where frame.first == NearbyFrame.Tag.sealed.rawValue {
            let box = try? AES.GCM.SealedBox(combined: frame.dropFirst())
            #expect(box.flatMap { try? AES.GCM.open($0, using: psk) } == nil)
        }
    }

    @Test("Too many wrong codes close the hold as someone guessing; a hold nobody joins closes in time")
    func guessingAndTimeout() async throws {
        let onto = try await Device()
        defer { onto.remove() }
        let link = PipeNearbyLink()
        let receiver = NearbyMove(link: link, carrier: onto.packager(), device: "a tablet", guessCap: 3)
        let held = Watch(await receiver.hold())
        guard case .code? = await held.until("a code", { if case .code = $0 { true } else { false } }) else { return }
        for _ in 0..<3 {
            for _ in 0..<100 where link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            guard let peer = link.peers.first else { break }
            _ = try? await link.connect(to: peer, psk: NearbyCode.psk(code: "wrong", sessionID: peer.sessionID))
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await held.until("guessing", Self.isRefused) == .refused(.guessing))
        #expect(held.events.filter { if case .code = $0 { true } else { false } }.count == 3, "rolled on each guess but the last")

        let quick = NearbyMove(link: link, carrier: onto.packager(), device: "a tablet", holdTimeout: .milliseconds(50))
        let timed = Watch(await quick.hold())
        #expect(await timed.until("timed out", Self.isRefused) == .refused(.timedOut))
    }

    /// A clock a test ends by hand: each `period()` returns only when `tick()` is called, so no
    /// runner's pace decides when a hold's timeout looks.
    final class Ticker: Sendable {
        private let held = Mutex<(ticks: Int, waiter: CheckedContinuation<Void, Never>?)>((0, nil))

        func tick() {
            let waiter = held.withLock { held -> CheckedContinuation<Void, Never>? in
                guard let waiter = held.waiter else {
                    held.ticks += 1
                    return nil
                }
                held.waiter = nil
                return waiter
            }
            waiter?.resume()
        }

        @Sendable func period() async throws {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = held.withLock { held -> Bool in
                    if held.ticks > 0 {
                        held.ticks -= 1
                        return true
                    }
                    held.waiter = continuation
                    return false
                }
                if now { continuation.resume() }
            }
            try Task.checkCancellation()
        }

        /// Whether the hold is waiting on the clock now, so a tick is heard by it.
        var waiting: Bool { held.withLock { $0.waiter != nil } }
    }

    /// Ends one period of `ticker` once the hold is waiting on it, and lets the hold look.
    private func endPeriod(_ ticker: Ticker) async {
        for _ in 0..<500 where !ticker.waiting { try? await Task.sleep(for: .milliseconds(2)) }
        ticker.tick()
        for _ in 0..<500 where !ticker.waiting { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test("A hold's timeout counts only time with nobody joined: a question on screen, a move under way and a move waiting to resume never time out")
    func timeoutCountsOnlyIdleTime() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let link = PipeNearbyLink()
        let ticker = Ticker()
        link.cutNext(afterBytesFrames: 0)
        let sender = NearbyMove(link: link, carrier: from.packager(), device: "a laptop", retryDelay: .milliseconds(20), retries: 50)
        let receiver = NearbyMove(link: link, carrier: onto.packager(), device: "a tablet", holdClock: ticker.period)
        defer { from.remove(); onto.remove() }
        let held = Watch(await receiver.hold())
        guard case .code(let code, _)? = await held.until("a code", { if case .code = $0 { true } else { false } }) else { return }
        for _ in 0..<100 where link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let sent = Watch(await sender.offer(to: link.peers[0], code: code, pictures: false, contents: .whole))
        await held.until("the receiver's question", Self.isAsking)
        // A period ends while the question is on screen and unanswered.
        await endPeriod(ticker)
        #expect(!held.events.contains(where: Self.isRefused), "a question on screen timed out: \(held.events)")
        await sent.until("the sender's question", Self.isAsking)
        await sender.answer(true)
        await receiver.answer(true)
        // The link drops after the first frame of the package; a period ends while it waits to resume.
        await held.until("the drop", { if case .reconnecting = $0 { true } else { false } })
        await endPeriod(ticker)
        #expect(!held.events.contains(where: Self.isRefused), "a move waiting to resume timed out: \(held.events)")
        await held.until("the receiver done", Self.isDone)
        await sent.until("the sender done", Self.isDone)
        #expect(await onto.store.snapshot().notes.count == 3)
    }

    @Test("A hold whose visitor left before its offer was accepted times out again once a period passes with nobody there")
    func timeoutResumesAfterAVisitorLeaves() async throws {
        let from = try await PackagerFixture.populated()
        let onto = try await Device()
        let link = PipeNearbyLink()
        let ticker = Ticker()
        let sender = NearbyMove(link: link, carrier: from.packager(), device: "a laptop", retryDelay: .milliseconds(20), retries: 5)
        let receiver = NearbyMove(link: link, carrier: onto.packager(), device: "a tablet", holdClock: ticker.period)
        defer { from.remove(); onto.remove() }
        let held = Watch(await receiver.hold())
        guard case .code(let code, _)? = await held.until("a code", { if case .code = $0 { true } else { false } }) else { return }
        for _ in 0..<100 where link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        _ = Watch(await sender.offer(to: link.peers[0], code: code, pictures: false, contents: .whole))
        await held.until("the receiver's question", Self.isAsking)
        await endPeriod(ticker)
        #expect(!held.events.contains(where: Self.isRefused))
        // The visitor walks away before anyone answers.
        link.cut()
        await sender.stop()
        await held.until("back to the code", { _ in held.events.filter { if case .code = $0 { true } else { false } }.count == 2 })
        await endPeriod(ticker)
        #expect(await held.until("timed out", Self.isRefused) == .refused(.timedOut))
    }

    @Test("A yes to a question the link dropped under is nothing: the question comes down, and the next offer is asked afresh")
    func staleAnswer() async throws {
        let pair = Pair(from: try await PackagerFixture.populated(), onto: try await Device())
        defer { pair.remove() }
        let (held, code, peer) = await pair.hold()
        var sent = Watch(await pair.sender.offer(to: peer, code: code, pictures: false, contents: .whole))
        await sent.until("the sender's question", Self.isAsking)
        await held.until("the receiver's question", Self.isAsking)
        // The sender walks out of reach while the receiver's question is up.
        pair.link.cut()
        await pair.sender.stop()
        for _ in 0..<300 where held.events.filter({ if case .code = $0 { true } else { false } }).count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let codes = held.events.compactMap { if case .code(let next, _) = $0 { next } else { nil } }
        #expect(codes == [code, code], "back to the code, the same one: \(held.events)")
        // A late yes lands on no question.
        await pair.receiver.answer(true)
        // A fresh offer is asked about, and waits.
        for _ in 0..<100 where pair.link.peers.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let again = NearbyMove(link: pair.link, carrier: pair.from.packager(), device: "a laptop", retryDelay: .milliseconds(20), retries: 5)
        sent = Watch(await again.offer(to: pair.link.peers[0], code: code, pictures: false, contents: .whole))
        await sent.until("the sender's question", Self.isAsking)
        await again.answer(true)
        await held.until("asked again", { held.events.filter(Self.isAsking).count == 2 && Self.isAsking($0) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!held.events.contains { if case .moving = $0 { true } else { false } }, "nothing moves on the stale yes")
        await pair.receiver.answer(true)
        await held.until("done", Self.isDone)
        await sent.until("done", Self.isDone)
        await again.stop()
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

/// A connection's frames read one at a time, for a sender written by hand.
final class PlainInbox: NearbyInbox, @unchecked Sendable {
    private var iterator: AsyncThrowingStream<NearbyFrame, any Error>.Iterator

    init(_ connection: any NearbyPeerConnection) {
        iterator = connection.frames.makeAsyncIterator()
    }

    func next() async throws -> NearbyFrame {
        guard let frame = try await iterator.next() else { throw NearbyDropped() }
        return frame
    }
}

/// A link that changes one byte of a sealed frame on its way: what a splice looks like to the
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
            // A sealed frame the size of a chunk: a byte of the package on the wire.
            if case .sealed(var data) = frame, data.count > NearbyFrame.mostBytes, !tampered {
                tampered = true
                data[data.count / 2] ^= 0x01
                try await inner.send(.sealed(data))
                return
            }
            try await inner.send(frame)
        }

        func close() { inner.close() }
    }
}
