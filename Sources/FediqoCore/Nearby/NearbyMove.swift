import CryptoKit
import Foundation

/// One store moving between two devices nearby (#253, #6): the steps, on either side, with
/// every decision in one place and no radio in it.
///
/// **The receiver holds** (`hold`): it advertises under a fresh session id, shows a six-digit
/// code, and waits. **The sender offers** (`offer`): it writes the package to its own scratch
/// space, joins the device the person picked under the key both derive from the code, and
/// sends what the package holds. Both screens then ask #252's question; both people press yes;
/// the package streams from the sender's disk to `incoming-<uuid>/package.fdq` under the
/// receiver's staging folder; and the receiver reads it back exactly as it would a file the
/// person carried over — proven whole before anything on it changes. Either no closes the
/// link with nothing written.
///
/// **A dropped link resumes.** The receiver keeps what it holds and goes on listening under the
/// same session and key; the sender joins again, offers the same offer by its id, and is told
/// `have: <bytes>` to go on from. The package's own tags catch any splice. A wrong code fails
/// the handshake: the receiver rolls its code and session, so a code that failed opens nothing
/// — one guess per code. A handshake failing after the offer was accepted is ignored, so a
/// stranger's guess cannot cut a move in progress.
///
/// **The package's key is never the code.** A random 256-bit key locks the package
/// (`PackageKey.direct`); it crosses only inside the session the code proved.
public actor NearbyMove {
    /// What a screen draws, in order, on either side.
    public enum Event: Sendable, Equatable {
        /// The receiver's code, fresh or rolled after a wrong guess.
        case code(String)
        /// The sender is writing the package to its scratch space.
        case packing(PackageProgress)
        /// The sender is joining the device the person picked.
        case connecting
        /// #252's question, on both sides: what would move, to or from `peer`, and — on the
        /// receiver — whether a store held here would be replaced.
        case asking(NearbyOffer, peer: String, held: Bool)
        /// This side said yes; the other has not yet.
        case waiting(peer: String)
        /// Bytes on the wire, both sides.
        case moving(PackageProgress, peer: String)
        /// The link dropped; waiting for it to come back.
        case reconnecting(peer: String)
        /// Every byte is there: the receiver is proving and reading it back; the sender waits.
        case settling(peer: String)
        case done(PackageSummary, peer: String)
        case refused(NearbyRefusal)
        /// This side said no, or stopped: nothing written on either.
        case closed
    }

    private let link: any NearbyLink
    private let carrier: any StoreCarrier
    private let device: String
    private let retryDelay: Duration
    private let retries: Int

    private var continuation: AsyncStream<Event>.Continuation?
    private var task: Task<Void, Never>?
    private var pending: CheckedContinuation<Bool, Never>?
    private var answered: Bool?

    /// `device` is what this device calls itself, advertised and written into the header.
    /// `retryDelay` and `retries` bound how long a dropped link is waited for; tests shorten
    /// them.
    public init(
        link: any NearbyLink, carrier: any StoreCarrier, device: String,
        retryDelay: Duration = .seconds(2), retries: Int = 45
    ) {
        self.link = link
        self.carrier = carrier
        self.device = device
        self.retryDelay = retryDelay
        self.retries = retries
    }

    // MARK: - Driving

    /// The person's answer to the question, on this side. Heard once; a later one is nothing.
    public func answer(_ yes: Bool) {
        guard answered == nil else { return }
        answered = yes
        pending?.resume(returning: yes)
        pending = nil
    }

    /// Whatever is running stops, and the stream ends. Nothing half done is kept.
    public func stop() {
        task?.cancel()
        task = nil
        pending?.resume(returning: false)
        pending = nil
        continuation?.finish()
        continuation = nil
    }

    private func awaitAnswer() async -> Bool {
        if let answered { return answered }
        return await withCheckedContinuation { pending = $0 }
    }

    private func emit(_ event: Event) {
        continuation?.yield(event)
    }

    private func start(_ body: @escaping @Sendable () async -> Void) -> AsyncStream<Event> {
        stop()
        answered = nil
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        task = Task { [weak self] in
            await body()
            await self?.finish()
        }
        return stream
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
        task = nil
    }

    // MARK: - Holding (the receiver)

    /// Advertises this device and waits for a sender. The first event is the code to show.
    public func hold() -> AsyncStream<Event> {
        start { [self] in await runHold() }
    }

    /// What the receiver keeps across connections once its person said yes.
    private struct Accepted: Sendable {
        let offer: NearbyOffer
        let folder: URL
        let file: URL
        let held: Bool
        var key: Data?
    }

    private func runHold() async {
        while !Task.isCancelled {
            let code = NearbyCode.make()
            let sessionID = NearbyCode.sessionID()
            let psk = NearbyCode.psk(code: code, sessionID: sessionID)
            emit(.code(code))
            var accepted: Accepted?
            // Whatever was staged goes on every way out of this code: done, refused, stopped.
            defer { if let accepted { try? FileManager.default.removeItem(at: accepted.folder) } }
            var roll = false
            do {
                for try await arrival in link.advertise(name: device, sessionID: sessionID, psk: psk) {
                    switch arrival {
                    case .failedHandshake:
                        // One guess per code — until the code was proven, when a stranger's
                        // guess must not cut the move.
                        guard accepted == nil else { continue }
                        roll = true
                    case .joined(let connection):
                        defer { connection.close() }
                        do {
                            if try await serve(connection, accepted: &accepted) { return }
                        } catch is NearbyDropped {
                            // The link dropped: what is held stays, and the next join goes on.
                            guard !Task.isCancelled else { return }
                            emit(.reconnecting(peer: accepted?.offer.summary.device ?? ""))
                        } catch {
                            guard !Task.isCancelled else { return }
                            try? await connection.send(.refuse)
                            emit(.refused(NearbyRefusal(error)))
                            return
                        }
                    }
                    if roll { break }
                }
            } catch {
                guard !Task.isCancelled else { return }
                emit(.refused(NearbyRefusal(error)))
                return
            }
            guard roll else { return }
        }
    }

    /// One connection on the receiving side. True once the move is over — done, refused here,
    /// or refused there; false where the link dropped and a later join carries on.
    private nonisolated func serve(_ connection: any NearbyPeerConnection, accepted: inout Accepted?) async throws -> Bool {
        var frames = connection.frames.makeAsyncIterator()
        guard case .offer(let offer) = try await next(&frames) else { throw NearbyRefusal.malformed }
        let peer = offer.summary.device
        if let held = accepted {
            // The same offer, back after a drop: no second question.
            guard held.offer.id == offer.id else { throw NearbyRefusal.malformed }
        } else {
            let weight = try await carrier.weigh()
            // The file, its staging, and what is moved in beside what was there.
            let needed = Int(clamping: offer.fileBytes) * 3
            guard weight.free >= needed else { throw NearbyRefusal.noRoom(needed: needed, free: weight.free) }
            await emit(.asking(offer, peer: peer, held: weight.holdsStore))
            guard await self.awaitAnswer() else {
                try? await connection.send(.refuse)
                await emit(.closed)
                return true
            }
            let folder = carrier.stagingFolder().appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("package.fdq")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            accepted = Accepted(offer: offer, folder: folder, file: file, held: weight.holdsStore)
        }
        guard var held = accepted else { throw NearbyRefusal.malformed }
        do {
            try await connection.send(.accept)
        } catch is NearbyDropped {
            // The sender may have said no while the question was up here: what it sent before
            // closing is read before the drop is believed.
            if case .refuse? = try? await frames.next() { throw NearbyRefusal.refusedThere }
            throw NearbyDropped()
        }
        let key: Data
        switch try await next(&frames) {
        case .key(let sent): key = sent
        case .refuse: throw NearbyRefusal.refusedThere
        default: throw NearbyRefusal.malformed
        }
        if let known = held.key {
            guard known == key else { throw NearbyRefusal.malformed }
        } else {
            held.key = key
            accepted = held
        }
        // Asked of the file system each time, never of a cached resource value: what was
        // written before a drop is exactly what the sender must go on from.
        var have = Self.bytesOnDisk(held.file)
        try await connection.send(.have(have))
        await emit(.moving(PackageProgress(done: Int(have), total: Int(held.offer.fileBytes)), peer: peer))
        let handle = try FileHandle(forWritingTo: held.file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        while true {
            switch try await next(&frames) {
            case .bytes(let data):
                guard have + Int64(data.count) <= held.offer.fileBytes else { throw NearbyRefusal.malformed }
                try handle.write(contentsOf: data)
                have += Int64(data.count)
                await emit(.moving(PackageProgress(done: Int(have), total: Int(held.offer.fileBytes)), peer: peer))
            case .done:
                guard have == held.offer.fileBytes else { throw NearbyRefusal.malformed }
                try handle.synchronize()
                try handle.close()
                await emit(.settling(peer: peer))
                let packageKey = PackageKey.direct(SymmetricKey(data: key))
                // The identical read back (#252): proven whole here before anything changes.
                let summary = try await carrier.preview(held.file, key: packageKey)
                try await carrier.readBack(held.file, key: packageKey, replacing: held.held) { _ in }
                try await connection.send(.done)
                await emit(.done(summary, peer: peer))
                return true
            case .refuse:
                throw NearbyRefusal.refusedThere
            default:
                throw NearbyRefusal.malformed
            }
        }
    }

    // MARK: - Offering (the sender)

    /// Writes the package, joins `peer` under `code`, and sends it. `pictures` and `contents`
    /// are what rides (#247, #6).
    public func offer(
        to peer: NearbyPeer, code: String, pictures: Bool, contents: PackageSummary.Contents
    ) -> AsyncStream<Event> {
        start { [self] in await runOffer(to: peer, code: code, pictures: pictures, contents: contents) }
    }

    private func runOffer(to peer: NearbyPeer, code: String, pictures: Bool, contents: PackageSummary.Contents) async {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeaway-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let file = scratch.appendingPathComponent("package.fdq")
            let key = SymmetricKey(size: .bits256)
            emit(.packing(PackageProgress(done: 0, total: 0)))
            // Progress goes straight to the stream, in order: a task hopping onto the actor could
            // land a "still packing" after the join had been said.
            let events = continuation
            try await carrier.takeAway(to: file, key: .direct(key), pictures: pictures, contents: contents) { progress in
                events?.yield(.packing(progress))
            }
            let summary = try await carrier.preview(file, key: .direct(key))
            let fileBytes = Self.bytesOnDisk(file)
            let offer = NearbyOffer(summary: summary, fileBytes: fileBytes)
            let psk = NearbyCode.psk(code: code, sessionID: peer.sessionID)
            let keyData = key.withUnsafeBytes { Data($0) }
            var attempt = 0
            var joinedOnce = false
            while true {
                try Task.checkCancellation()
                emit(joinedOnce ? .reconnecting(peer: peer.name) : .connecting)
                let connection: any NearbyPeerConnection
                do {
                    connection = try await link.connect(to: peer, psk: psk)
                } catch is NearbyDropped {
                    // Not there yet: wait, and try again while there are tries left.
                    attempt += 1
                    guard joinedOnce, attempt <= retries else { throw NearbyRefusal.lost }
                    try await Task.sleep(for: retryDelay)
                    continue
                }
                joinedOnce = true
                defer { connection.close() }
                do {
                    if try await send(offer, file: file, key: keyData, over: connection, peer: peer.name) { return }
                    emit(.closed)
                    return
                } catch is NearbyDropped {
                    // The link dropped: join again and go on from what the receiver holds.
                    attempt += 1
                    guard attempt <= retries else { throw NearbyRefusal.lost }
                    try await Task.sleep(for: retryDelay)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            emit(.refused(NearbyRefusal(error)))
        }
    }

    /// One connection on the sending side. True once the receiver said done; false where this
    /// side said no; throws where the link dropped (to be joined again) or the move was refused.
    private nonisolated func send(
        _ offer: NearbyOffer, file: URL, key: Data, over connection: any NearbyPeerConnection, peer: String
    ) async throws -> Bool {
        var frames = connection.frames.makeAsyncIterator()
        try await connection.send(.offer(offer))
        if await answered == nil { await emit(.asking(offer, peer: peer, held: false)) }
        guard await self.awaitAnswer() else {
            try? await connection.send(.refuse)
            return false
        }
        await emit(.waiting(peer: peer))
        switch try await next(&frames) {
        case .accept: break
        case .refuse: throw NearbyRefusal.refusedThere
        default: throw NearbyRefusal.malformed
        }
        try await connection.send(.key(key))
        guard case .have(let have) = try await next(&frames), have <= offer.fileBytes else { throw NearbyRefusal.malformed }
        await emit(.moving(PackageProgress(done: Int(have), total: Int(offer.fileBytes)), peer: peer))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(have))
        var sent = have
        while let chunk = try handle.read(upToCount: NearbyFrame.mostBytes), !chunk.isEmpty {
            try Task.checkCancellation()
            try await connection.send(.bytes(chunk))
            sent += Int64(chunk.count)
            await emit(.moving(PackageProgress(done: Int(sent), total: Int(offer.fileBytes)), peer: peer))
        }
        try await connection.send(.done)
        await emit(.settling(peer: peer))
        switch try await next(&frames) {
        case .done:
            await emit(.done(offer.summary, peer: peer))
            return true
        case .refuse: throw NearbyRefusal.refusedThere
        default: throw NearbyRefusal.malformed
        }
    }

    /// The file's length now, as the file system says it.
    private nonisolated static func bytesOnDisk(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    /// The next frame, or a dropped link where there is none.
    private nonisolated func next(_ frames: inout AsyncThrowingStream<NearbyFrame, any Error>.Iterator) async throws -> NearbyFrame {
        guard let frame = try await frames.next() else { throw NearbyDropped() }
        return frame
    }
}

/// The link ended without a word — the peer went out of reach, the app was put away — which
/// is not a refusal: the sender joins again and the receiver waits. A link throws this, and
/// nothing else, for a drop.
public struct NearbyDropped: Error, Sendable, Equatable {
    public init() {}
}
