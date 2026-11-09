import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import FediqoCore

/// U5: paired devices find each other by a rotating tag, join under the pair secret, and merge.
@Suite("Syncing paired devices nearby")
struct SyncSessionTests {
    private static let when = Date(timeIntervalSince1970: 1_800_000_000)
    private static let quick = SyncTiming(syncNowWindow: .seconds(2), answerWait: .seconds(5), stepWait: .seconds(5))

    private struct Device {
        let id: String
        let name: String
        let pairs: MemoryPairStore
        let local: MemoryLocal
        let clock: SyncClock
        let session: SyncSession
    }

    private func device(_ link: PipeNearbyLink, _ id: String, _ name: String, holding: SyncSnapshot = .empty, answer: Bool? = true, hang: Duration? = nil, timing: SyncTiming = quick) -> Device {
        let pairs = MemoryPairStore()
        let local = MemoryLocal(holding, answer: answer, hang: hang)
        let clock = SyncClock(device: id, wall: { Self.when })
        let session = SyncSession(link: link, pairs: pairs, clock: clock, name: name, local: local, timing: timing, now: { Self.when })
        return Device(id: id, name: name, pairs: pairs, local: local, clock: clock, session: session)
    }

    @discardableResult
    private func pair(_ a: Device, _ b: Device, firstMerged: Bool = true) throws -> SymmetricKey {
        let secret = SymmetricKey(size: .bits256)
        try a.pairs.keep(PairedDevice(device: b.id, name: b.name, pairedAt: Self.when, firstMerged: firstMerged), secret: secret)
        try b.pairs.keep(PairedDevice(device: a.id, name: a.name, pairedAt: Self.when, firstMerged: firstMerged), secret: secret)
        return secret
    }

    private static func stamp(_ ms: Int64, _ by: String) -> SyncStamp {
        SyncStamp(ms: 1_799_000_000_000 + ms, counter: 0, device: by)
    }

    private static func source(_ host: String, _ ms: Int64, _ by: String) -> (String, Stamped<SyncSource>) {
        (host, Stamped(SyncSource(host: host, kind: .mastodon, boards: []), at: stamp(ms, by)))
    }

    private static let timelineID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static var mac: SyncSnapshot {
        SyncSnapshot(sources: Dictionary(uniqueKeysWithValues: [source("mac.example", 1, "A-MAC")]))
    }

    private static var phone: SyncSnapshot {
        SyncSnapshot(
            sources: Dictionary(uniqueKeysWithValues: [source("phone.example", 2, "B-PHONE")]),
            timelines: [timelineID: Stamped(SyncTimeline(id: timelineID, name: "News", body: Data("{}".utf8)), at: stamp(3, "B-PHONE"))]
        )
    }

    /// Starts `device` listening, and waits until `count` listeners are up in the room.
    private func listen(_ device: Device, on link: PipeNearbyLink, until count: Int) async -> Task<Void, any Error> {
        let task = Task { try await device.session.listen() }
        _ = await eventually { link.listeners.count >= count }
        return task
    }

    private func eventually(_ what: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if await what() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func done(_ device: Device) -> [SyncOutcome] {
        device.local.events.compactMap { if case .done(_, let outcome) = $0 { outcome } else { nil } }
    }

    @Test("Two paired ends find each other by tag, join under the pair secret, and both end equal")
    func merges() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone)
        try pair(a, b)
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }

        let outcomes = await b.session.dialDue(period: .hour)
        guard case .merged(let here, let there) = try #require(outcomes[a.id]) else {
            Issue.record("not merged: \(String(describing: outcomes[a.id]))")
            return
        }
        #expect(here.addedSources == ["mac.example"] && there.addedSources == ["phone.example"] && there.addedTimelines == ["News"])
        #expect(await eventually { await !done(a).isEmpty })
        let merged = SyncMerge.merge(Self.mac, Self.phone)
        #expect(a.local.held == merged && b.local.held == merged)
        #expect(try a.pairs.pairs().first?.lastMerged == Self.when && b.pairs.pairs().first?.lastMerged == Self.when)
        #expect(b.clock.now() > merged.newest, "a local edit after the merge wins over what arrived")
        #expect(a.local.events.contains(.joined(PairedDevice(device: b.id, name: "Phone", pairedAt: Self.when, firstMerged: true))))
        // Nothing crossed in the clear: every sync frame rode sealed.
        #expect(!Set(link.transcript.compactMap(\.first)).contains(NearbyFrame.Tag.sync.rawValue))

        // Merged an hour ago is not due within the hour.
        #expect(await b.session.dialDue(period: .hour).isEmpty)
    }

    @Test("A listener advertises a random name and the pair's tag for this bucket, nothing else")
    func advertises() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac")
        let secret = try pair(a, device(link, "B-PHONE", "Phone"))
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }
        let listener = try #require(link.listeners.first)
        #expect(listener.name.hasPrefix("fq-") && listener.name != "Mac")
        #expect(listener.tag == SyncDiscovery.tag(secret: secret, bucket: SyncDiscovery.bucket(at: Self.when)))
        #expect(link.peers.isEmpty, "a sync listener is never a Move hold")
    }

    @Test("An unpaired device neither finds a tag it can read nor joins")
    func unpaired() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        try pair(a, device(link, "B-PHONE", "Phone"))
        let stranger = device(link, "C-PAD", "Pad", holding: Self.phone, timing: SyncTiming(syncNowWindow: .milliseconds(300)))
        try stranger.pairs.keep(PairedDevice(device: a.id, name: "Mac", pairedAt: Self.when), secret: SymmetricKey(size: .bits256))
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }

        #expect(await stranger.session.dialDue(period: .hour).isEmpty)
        let listener = try #require(link.listeners.first)
        let guess = SyncDiscovery.psk(secret: SymmetricKey(size: .bits256), tag: listener.tag)
        await #expect(throws: NearbyRefusal.wrongCode) { try await link.connect(to: listener, psk: guess) }
        #expect(a.local.snapshots == 0 && a.local.held == Self.mac)
    }

    @Test("A forgotten pair cannot join: refused while the old listener stands, unseen once it is gone")
    func forgotten() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone, timing: SyncTiming(syncNowWindow: .milliseconds(500)))
        try pair(a, b)
        let listening = await listen(a, on: link, until: 1)
        try a.pairs.forget(device: b.id)

        #expect(await b.session.dialDue(period: .hour)[a.id] == .notMerged(.notPaired))
        #expect(a.local.snapshots == 0 && b.local.snapshots == 0)
        #expect(a.local.held == Self.mac && b.local.held == Self.phone)

        listening.cancel()
        _ = await eventually { link.listeners.isEmpty }
        let again = Task { try await a.session.listen() }
        defer { again.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(link.listeners.isEmpty)
        #expect(await b.session.syncNow().isEmpty)
        #expect(b.local.events.contains(.nobodyFound))
    }

    /// Joins `a`'s listener as a peer speaking `version`, says hello, and returns what came
    /// back up to the refusal: `a`'s own hello (who it is, no records), then the refusal.
    private func helloAt(version: UInt8, to a: Device, secret: SymmetricKey, on link: PipeNearbyLink) async throws -> [SyncFrame] {
        let listener = try #require(link.listeners.first)
        let psk = SyncDiscovery.psk(secret: secret, tag: listener.tag)
        let connection = try await link.connect(to: listener, psk: psk)
        let mailbox = Mailbox(connection)
        defer { mailbox.close(); connection.close() }
        let channel = try await NearbyChannel.open(over: connection, inbox: mailbox, role: .sender, psk: psk, sessionID: listener.tag)
        let hello = try JSONEncoder().encode(SyncHello(device: "B-PHONE", name: "Phone", firstMerged: true))
        try await channel.send(.sync(Data([version, 1]) + hello))
        var heard: [SyncFrame] = []
        while case .sync(let data) = try? await channel.next() {
            heard.append(try SyncFrame.decode(data))
            if case .versionRefused = heard.last { break }
        }
        return heard
    }

    @Test("An older or newer peer gets nothing of this side's, and is told who must update")
    func otherVersion() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        let secret = try pair(a, device(link, "B-PHONE", "Phone"))
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }

        let mine = SyncFrame.hello(SyncHello(device: a.id, name: "Mac", firstMerged: true))
        #expect(try await helloAt(version: 0, to: a, secret: secret, on: link) == [mine, .versionRefused(newest: SyncFrame.version)])
        #expect(await eventually { done(a) == [.notMerged(.peerOlder)] })
        #expect(try await helloAt(version: 2, to: a, secret: secret, on: link) == [mine, .versionRefused(newest: SyncFrame.version)])
        #expect(await eventually { done(a) == [.notMerged(.peerOlder), .notMerged(.peerNewer)] })
        #expect(a.local.snapshots == 0, "no snapshot was taken, so none was sent")
    }

    @Test("The first merge waits for the dialer's yes, then both end equal and merged")
    func firstMergeYes() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac, answer: false)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone, answer: true)
        try pair(a, b, firstMerged: false)
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }

        guard case .merged = try #require(await b.session.dialDue(period: .hour)[a.id]) else {
            Issue.record("not merged")
            return
        }
        #expect(await eventually { await !done(a).isEmpty })
        #expect(b.local.asked == 1 && a.local.asked == 0, "only the dialer is asked")
        #expect(a.local.events.contains { if case .waitingForAnswer = $0 { true } else { false } })
        #expect(a.local.held == b.local.held)
        #expect(try a.pairs.pairs().first?.firstMerged == true && b.pairs.pairs().first?.firstMerged == true)
    }

    @Test("A no changes nothing and keeps the pair unmerged, asked again at the next join")
    func firstMergeNo() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone, answer: false)
        try pair(a, b, firstMerged: false)
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }

        #expect(await b.session.dialDue(period: .hour)[a.id] == .notMerged(.declined))
        #expect(await eventually { done(a) == [.notMerged(.declined)] })
        #expect(a.local.held == Self.mac && b.local.held == Self.phone)
        #expect(a.local.applied == 0 && b.local.applied == 0)
        for store in [a.pairs, b.pairs] {
            let kept = try #require(try store.pairs().first)
            #expect(!kept.firstMerged && kept.lastMerged == nil)
        }
        // Asked again at Sync now.
        #expect(await b.session.syncNow()[a.id] == .notMerged(.declined))
        #expect(b.local.asked == 2)
    }

    @Test("No answer within the wait is a no")
    func firstMergeTimeout() async throws {
        let link = PipeNearbyLink()
        let timing = SyncTiming(syncNowWindow: .seconds(2), answerWait: .milliseconds(300), stepWait: .seconds(5))
        let a = device(link, "A-MAC", "Mac", holding: Self.mac, timing: timing)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone, answer: true, hang: .seconds(30), timing: timing)
        try pair(a, b, firstMerged: false)
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }

        let started = ContinuousClock.now
        #expect(await b.session.dialDue(period: .hour)[a.id] == .notMerged(.declined))
        #expect(ContinuousClock.now - started < .seconds(25), "ended by the wait, not by the 30 s confirm")
        #expect(await eventually { done(a) == [.notMerged(.declined)] })
        #expect(a.local.held == Self.mac && b.local.held == Self.phone)
        #expect(try a.pairs.pairs().first?.firstMerged == false && b.pairs.pairs().first?.firstMerged == false)
    }

    @Test("Both sides dialing at once comes to one merge, whichever join lands first", arguments: [true, false])
    func simultaneous(lowerJoinsFirst: Bool) async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone)
        try pair(a, b)
        let listenA = await listen(a, on: link, until: 1)
        let listenerA = try #require(link.listeners.first?.name)
        let listenB = await listen(b, on: link, until: 2)
        let listenerB = try #require(link.listeners.first { $0.name != listenerA }?.name)
        defer { listenA.cancel(); listenB.cancel() }

        link.holdJoins()
        async let fromA = a.session.dialDue(period: .hour)
        async let fromB = b.session.dialDue(period: .hour)
        #expect(await eventually { link.joinsHeld == 2 }, "both dialed before either joined")
        // The lower id's join lands first, or the higher's: it hears `.busy` before the other lands.
        link.releaseJoins(to: lowerJoinsFirst ? listenerB : listenerA)
        try await Task.sleep(for: .milliseconds(200))
        link.releaseJoins()
        let (outcomesA, outcomesB) = await (fromA, fromB)

        guard case .merged = outcomesA[b.id], case .merged = outcomesB[a.id] else {
            Issue.record("A: \(String(describing: outcomesA[b.id])), B: \(String(describing: outcomesB[a.id]))")
            return
        }
        #expect(a.local.snapshots == 1 && b.local.snapshots == 1, "exactly one exchange ran")
        #expect(done(a).count == 1 && done(b).count == 1, "A: \(done(a)), B: \(done(b))")
        #expect(a.local.held == b.local.held)
    }

    @Test("A stranger replaying the tag under its own name neither stops the merge nor reads as not paired")
    func replayedTag() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone)
        try pair(a, b)
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }
        let tag = try #require(link.listeners.first?.tag)
        // "fq-" lists before any real instance name, so it is dialed first.
        let replay = link.advertise(name: "fq-", tag: tag, psk: SymmetricKey(size: .bits256))
        defer { withExtendedLifetime(replay) {} }
        #expect(link.listeners.first?.name == "fq-")

        guard case .merged = try #require(await b.session.dialDue(period: .hour)[a.id]) else {
            Issue.record("not merged: \(done(b))")
            return
        }
        #expect(!done(b).contains(.notMerged(.notPaired)) && done(b).count == 1)
        #expect(await eventually { a.local.held == b.local.held })
    }

    @Test("One look dials at most three of a pair's listeners, however many strangers replay its tag")
    func dialsCapped() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone)
        try pair(a, b)
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }
        let tag = try #require(link.listeners.first?.tag)
        // "fq-0" … "fq-3" list before any real instance name, so they are dialed first.
        let guesses = Mutex(0)
        let replays = (0..<4).map { index in
            let stream = link.advertise(name: "fq-\(index)", tag: tag, psk: SymmetricKey(size: .bits256))
            return Task {
                for try await arrival in stream {
                    if case .failedHandshake = arrival { guesses.withLock { $0 += 1 } }
                }
            }
        }
        defer { for replay in replays { replay.cancel() } }
        _ = await eventually { link.listeners.count == 5 }
        #expect(SyncSession.mostListenersTried == 3)

        #expect(await b.session.dialDue(period: .hour).isEmpty)
        #expect(guesses.withLock { $0 } == 3)
        #expect(a.local.snapshots == 0 && done(b).isEmpty)
    }

    @Test("Strangers listed first take one look's dials, not the next: the real listener is tried then")
    func failedListenersRemembered() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone)
        try pair(a, b)
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }
        let tag = try #require(link.listeners.first?.tag)
        let replays = (0..<3).map { link.advertise(name: "fq-\($0)", tag: tag, psk: SymmetricKey(size: .bits256)) }
        defer { withExtendedLifetime(replays) {} }
        _ = await eventually { link.listeners.count == 4 }

        var outcome: SyncOutcome?
        for _ in 0..<2 where outcome == nil {
            outcome = await b.session.dialDue(period: .hour)[a.id]
        }
        guard case .merged = try #require(outcome) else {
            Issue.record("not merged: \(String(describing: outcome))")
            return
        }
        #expect(await eventually { a.local.held == b.local.held })
    }

    @Test("A port source merges; a removed localhost and a live loopback address stay on their device, the rest merges")
    func localHostsStayHome() async throws {
        let port = Stamped(SyncSource(host: "[a.example:8443]", kind: .mastodon, boards: []), at: Self.stamp(4, "A-MAC"))
        let loopback = Stamped(SyncSource(host: "127.0.0.1", kind: .mastodon, boards: []), at: Self.stamp(5, "A-MAC"))
        let gone = Stamped<SyncSource>(nil, at: Self.stamp(6, "A-MAC"))
        var holding = Self.mac
        holding.sources["[a.example:8443]"] = port
        holding.sources["127.0.0.1"] = loopback
        holding.sources["localhost"] = gone
        let held = holding
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: held)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone)
        try pair(a, b)
        let listening = await listen(a, on: link, until: 1)
        defer { listening.cancel() }

        guard case .merged = try #require(await b.session.dialDue(period: .hour)[a.id]) else {
            Issue.record("not merged: \(done(b))")
            return
        }
        let merged = SyncMerge.merge(held.shared, Self.phone)
        #expect(merged.sources["[a.example:8443]"] == port && merged.sources["mac.example"] != nil)
        #expect(b.local.held == merged)
        #expect(await eventually { a.local.held == SyncMerge.merge(held, Self.phone) })
    }

    @Test("While a pairing's first merge waits for its answer, no dial or join starts a second one")
    func pairingHoldsThePair() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac, answer: false)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone, answer: true, hang: .milliseconds(1500))
        var held = await a.session.holdPairing().makeAsyncIterator()
        guard case .code(let code, let sessionID) = await held.next() else { throw NearbyDropped() }
        let hold = try await pairingHold(on: link, sessionID: sessionID)
        let joining = Task {
            var events: [PairingEvent] = []
            for await event in await b.session.joinPairing(peer: hold, code: code) { events.append(event) }
            return events
        }
        while let event = await held.next() {
            if case .waitingForAnswer = event { break }
        }

        let listenA = await listen(a, on: link, until: 1)
        let listenerA = try #require(link.listeners.first)
        let listenB = await listen(b, on: link, until: 2)
        defer { listenA.cancel(); listenB.cancel() }
        async let fromA = a.session.dialDue(period: .hour)
        async let fromB = b.session.dialDue(period: .hour)

        // A join into A's listener meanwhile hears `.busy`.
        let secret = try #require(try a.pairs.secret(for: b.id))
        let psk = SyncDiscovery.psk(secret: secret, tag: listenerA.tag)
        let connection = try await link.connect(to: listenerA, psk: psk)
        let mailbox = Mailbox(connection)
        let channel = try await NearbyChannel.open(over: connection, inbox: mailbox, role: .sender, psk: psk, sessionID: listenerA.tag)
        guard case .sync(let said) = try await channel.next() else { throw NearbyDropped() }
        #expect(try SyncFrame.decode(said) == .refused(.busy))
        mailbox.close()
        connection.close()

        let (outcomesA, outcomesB) = await (fromA, fromB)
        guard case .done(_, .merged) = await joining.value.last, case .merged = outcomesA[b.id], case .merged = outcomesB[a.id] else {
            Issue.record("A: \(String(describing: outcomesA[b.id])), B: \(String(describing: outcomesB[a.id]))")
            return
        }
        #expect(a.local.snapshots == 1 && b.local.snapshots == 1, "the pairing's merge was the only one")
    }

    @Test("`within` gives nil to a task already cancelled, and never starts the operation")
    func withinCancelled() async {
        let ran = Mutex(false)
        let value = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SyncSession.within(.seconds(3600)) {
                ran.withLock { $0 = true }
                return 1
            }
        }.value
        #expect(value == nil && !ran.withLock { $0 })
    }

    /// The pairing hold under `sessionID` once it advertises: the code is said before the hold
    /// is up, as a browser sees it.
    private func pairingHold(on link: PipeNearbyLink, sessionID: String) async throws -> NearbyPeer {
        for try await peers in link.browse() {
            if let peer = peers.first(where: { $0.sessionID == sessionID }) { return peer }
        }
        throw NearbyDropped()
    }

    @Test("Pairing runs the first merge on the same channel, the joiner confirming")
    func pairingMerges() async throws {
        let link = PipeNearbyLink()
        let a = device(link, "A-MAC", "Mac", holding: Self.mac, answer: false)
        let b = device(link, "B-PHONE", "Phone", holding: Self.phone, answer: true)
        var held = await a.session.holdPairing().makeAsyncIterator()
        guard case .code(let code, let sessionID) = await held.next() else { throw NearbyDropped() }
        let hold = try await pairingHold(on: link, sessionID: sessionID)
        var joined: [PairingEvent] = []
        for await event in await b.session.joinPairing(peer: hold, code: code) { joined.append(event) }
        var holder: [PairingEvent] = []
        while let event = await held.next() { holder.append(event) }

        let phonePair = PairedDevice(device: b.id, name: "Phone", pairedAt: Self.when)
        let macPair = PairedDevice(device: a.id, name: "Mac", pairedAt: Self.when)
        #expect(holder.prefix(3) == [.paired(phonePair), .merging(phonePair), .waitingForAnswer(phonePair)])
        #expect(Array(joined.prefix(3)) == [.connecting, .paired(macPair), .merging(macPair)])
        guard case .done(_, .merged) = holder.last, case .done(_, .merged) = joined.last else {
            Issue.record("holder \(holder), joiner \(joined)")
            return
        }
        #expect(a.local.held == b.local.held && b.local.asked == 1 && a.local.asked == 0)
        #expect(try a.pairs.pairs().first?.firstMerged == true && b.pairs.pairs().first?.firstMerged == true)
    }

    @Test("Move's list never shows a sync listener, and the tag list never shows a Move hold")
    func moveUnchanged() async throws {
        let link = PipeNearbyLink()
        let psk = SymmetricKey(size: .bits256)
        let listener = link.advertise(name: "fq-000000000000", tag: "t", psk: psk)
        let move = link.advertise(name: "Mac", sessionID: "m", psk: psk)
        defer { _ = (listener, move) }
        var holds = link.browse().makeAsyncIterator()
        #expect(try await holds.next()?.map(\.sessionID) == ["m"])
        var tags = link.browseTags().makeAsyncIterator()
        #expect(try await tags.next()?.map(\.name) == ["fq-000000000000"])
    }

    @Test("Tags rotate by bucket, are accepted one bucket either way, and only under the pair's secret")
    func tags() {
        let secret = SymmetricKey(size: .bits256)
        let bucket = SyncDiscovery.bucket(at: Self.when)
        #expect(bucket == 1_800_000_000 / 900)
        let tag = SyncDiscovery.tag(secret: secret, bucket: bucket)
        #expect(tag.count == 32 && tag.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(tag != SyncDiscovery.tag(secret: secret, bucket: bucket + 1))
        for skew in [-900.0, 0, 900] {
            #expect(SyncDiscovery.accepts(tag, secret: secret, at: Self.when.addingTimeInterval(skew)))
        }
        #expect(!SyncDiscovery.accepts(tag, secret: secret, at: Self.when.addingTimeInterval(1800)))
        #expect(!SyncDiscovery.accepts(tag, secret: SymmetricKey(size: .bits256), at: Self.when))
        let other = SyncDiscovery.tag(secret: secret, bucket: bucket + 1)
        #expect(SyncDiscovery.psk(secret: secret, tag: tag) != SyncDiscovery.psk(secret: secret, tag: other))
        #expect(SyncDiscovery.pskIdentity(tag: tag) == Data("fediqo-sync-1 \(tag)".utf8))
        let name = SyncDiscovery.instanceName()
        #expect(name.count == 15 && name.hasPrefix("fq-") && name != SyncDiscovery.instanceName())
    }

    @Test("Sync frames round-trip; versionRefused reads at any version; another version is said as such")
    func frames() throws {
        let frames: [SyncFrame] = [
            .hello(SyncHello(device: "D", name: "Mac", firstMerged: false)), .snapshot(Self.phone),
            .answer(true), .applied(false), .refused(.clockAhead), .versionRefused(newest: 1),
        ]
        for frame in frames {
            #expect(try SyncFrame.decode(frame.encode()) == frame)
        }
        #expect(try SyncFrame.decode(Data([9, 0xFF, 9])) == .versionRefused(newest: 9))
        #expect(try SyncFrame.versionRefused(newest: 1).encode() == Data([1, 0xFF, 1]))
        #expect(throws: SyncRefusal.otherVersion(2)) { try SyncFrame.decode(Data([2, 1, 0])) }
        #expect(throws: NearbyRefusal.malformed) { try SyncFrame.decode(Data([1, 0xFF])) }
        let unknownKind = try String(decoding: SyncFrame.snapshot(Self.mac).encode(), as: UTF8.self)
            .replacingOccurrences(of: "mastodon", with: "zzzzzzzz")
        #expect(throws: SyncRefusal.peerNewer) { try SyncFrame.decode(Data(unknownKind.utf8)) }
        let big = SyncTimeline(id: Self.timelineID, name: "Big", body: Data(count: NearbyFrame.mostBytes))
        #expect(throws: SyncRefusal.tooLarge) {
            try SyncFrame.snapshot(SyncSnapshot(timelines: [Self.timelineID: Stamped(big, at: .zero)])).encode()
        }
    }

    @Test("A refusal reads from the other side's view")
    func mirrored() {
        #expect(SyncRefusal.peerOlder.mirrored == .peerNewer && SyncRefusal.unreadableHere.mirrored == .unreadableThere)
        #expect(SyncRefusal.busy.mirrored == .busy)
    }
}

/// One device's entries and screen, in memory.
final class MemoryLocal: SyncLocal {
    private struct State {
        var held: SyncSnapshot
        var events: [SyncEvent] = []
        var snapshots = 0
        var applied = 0
        var asked = 0
    }

    private let state: Mutex<State>
    private let answer: Bool?
    private let hang: Duration?

    init(_ held: SyncSnapshot, answer: Bool?, hang: Duration?) {
        state = Mutex(State(held: held))
        self.answer = answer
        self.hang = hang
    }

    var held: SyncSnapshot { state.withLock { $0.held } }
    var events: [SyncEvent] { state.withLock { $0.events } }
    var snapshots: Int { state.withLock { $0.snapshots } }
    var applied: Int { state.withLock { $0.applied } }
    var asked: Int { state.withLock { $0.asked } }

    func snapshot() async -> SyncSnapshot {
        state.withLock { state in
            state.snapshots += 1
            return state.held
        }
    }

    func readable(_ remote: SyncSnapshot) async -> Bool { true }

    func confirm(_ preview: SyncPreview, with peer: PairedDevice) async -> Bool? {
        state.withLock { $0.asked += 1 }
        if let hang { try? await Task.sleep(for: hang) }
        return answer
    }

    func apply(_ changes: SyncChanges, from peer: PairedDevice) async {
        state.withLock { state in
            state.applied += 1
            state.held.sources.merge(changes.sources) { $1 }
            state.held.timelines.merge(changes.timelines) { $1 }
        }
    }

    func said(_ event: SyncEvent) async {
        state.withLock { $0.events.append(event) }
    }
}
