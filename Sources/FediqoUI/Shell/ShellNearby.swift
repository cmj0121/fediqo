import FediqoCore
import Foundation
import Observation

/// A store moving to or from a device nearby (#253, #6) — the steps on the shell, with every
/// decision in one place and nothing drawn here. `NearbyMove` runs the move; this reads its
/// events onto the main actor as steps a screen draws, and asks the person what the move asks.
///
/// **Holding** (the receiver): a press shows a six-digit code and this device's name, and waits.
/// **Offering** (the sender): a press lists the devices nearby that are holding; the person
/// picks one, types its code, chooses what rides, and the package is written and sent. Both
/// screens then ask #252's question; either no closes the link with nothing written; a yes on
/// both moves the package, and the receiver reads it back exactly as it would a file.
///
/// **Recorded under the other device.** Each side writes one line to the run's record under the
/// name the other device gave itself (`SourceWork.beginNearby`), begun as the two join and ended
/// on every way out — so the list shows where it went, and nothing else.
///
/// **The store is held still** while the move runs (`holdStill`): from the sender's first byte
/// written and the receiver's yes, until every way out.
///
/// **The device stays awake for the whole run** (`awake`, `staysAwake`), a longer span than the
/// store's stillness: from the first press — the code up, the list up — to the flow's end, a
/// drop back to the code included, and let go on every way out. The move is foreground-only: a
/// suspension is a dropped link that resumes.
@MainActor
@Observable
final class ShellNearby {
    /// Which side this device is on, while a move is up.
    enum Side: Equatable {
        case holding
        case offering
    }

    /// Where the flow is, or nothing while nothing is under way.
    enum Step: Equatable {
        /// The receiver is showing its code and waiting for a sender.
        case holding(code: String)
        /// The sender is looking at the devices nearby.
        case browsing([NearbyPeer])
        /// The sender typed the code; before joining, the person is asked whether the other
        /// screen shows the same mark.
        case checkingMark(MarkCheck)
        /// The sender is writing the package.
        case packing(PackageProgress)
        case connecting(peer: String)
        /// #252's question, on either side.
        case asking(Ask)
        /// This side said yes; the other has not yet.
        case waiting(peer: String)
        case moving(PackageProgress, peer: String)
        case reconnecting(peer: String)
        /// Every byte is there; the receiver proves and reads it back — how far, once the read
        /// back has begun, and nothing while it proves or on the sender.
        case settling(PackageProgress?, peer: String)
        case done(PackageSummary, peer: String)
        case refused(NearbyRefusal)
    }

    /// What the sender is about to join with, held while the mark is checked.
    struct MarkCheck: Equatable {
        let peer: NearbyPeer
        let code: String
        let rides: Rides
        let mark: String
    }

    struct Ask: Equatable {
        let offer: NearbyOffer
        let peer: String
        /// Whether a store held here would be replaced (the receiver only).
        let held: Bool
        /// Which way: true on the device that will hold the store.
        let receiving: Bool
    }

    /// What is on the sender's pick sheet: everything with the pictures, everything without, or
    /// only what signs in (#6).
    enum Rides: String, CaseIterable, Identifiable, Equatable {
        case withPictures
        case withoutPictures
        case signInsOnly

        var id: String { rawValue }
        var pictures: Bool { self == .withPictures }
        var contents: PackageSummary.Contents { self == .signInsOnly ? .signInsOnly : .whole }
    }

    private(set) var step: Step? {
        didSet { awake.set(Self.staysAwake(step)) }
    }
    private(set) var side: Side?
    /// The device the sender's pick sheet has lit.
    var picked: NearbyPeer?
    /// The code as typed on the sender, or shown on the receiver, for the line beside progress.
    private(set) var code = ""
    /// The receiver's session mark (`NearbyCode.fingerprint`), shown beside its code.
    private(set) var mark = ""
    /// What the sender weighed, for the pick sheet's sizes.
    private(set) var weight: PackageWeight?
    /// When bytes began to move, for the estimate.
    private(set) var since: Date?

    /// Holds the store still for the move, and lets it go: the session's `holdsStill`.
    @ObservationIgnored var holdStill: ((Bool) -> Void)?
    @ObservationIgnored let work: SourceWork
    /// The device kept awake while the flow runs, and let sleep once it ends.
    @ObservationIgnored let awake: StayAwake
    @ObservationIgnored private var move: NearbyMove?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var browsing: Task<Void, Never>?
    @ObservationIgnored private var token: SourceWork.Token?
    @ObservationIgnored private var pictures: DiskCopies?
    /// The copies actually held — set once `hold()` has returned, and released once, by `end`.
    /// A hold put away before its yes never took them, and must never give them back: resuming
    /// a queue that was not suspended is a crash.
    @ObservationIgnored private var heldPictures: DiskCopies?
    /// Moves on at every `end`, so a hold of the copies that returns after its move ended gives
    /// them straight back instead of keeping them for a move that is gone.
    @ObservationIgnored private var round = 0
    @ObservationIgnored private var adopt: (@MainActor () async -> Void)?
    @ObservationIgnored private var holding = false
    /// The devices last listed, for the list to come back to.
    @ObservationIgnored private var lastPeers: [NearbyPeer] = []

    init(work: SourceWork = .shared, awake: StayAwake = StayAwake()) {
        self.work = work
        self.awake = awake
    }

    /// Whether the device is kept awake at `step`: every step of a run — the code up, the list,
    /// the mark, the questions, the bytes — and not once it has ended, on its notice or with
    /// nothing up.
    static func staysAwake(_ step: Step?) -> Bool {
        switch step {
        case nil, .done, .refused: false
        default: true
        }
    }

    // MARK: - What a screen reads

    /// The question or notice up right now, where the step is one.
    var asking: Step? {
        switch step {
        case .asking, .refused, .done, .checkingMark: step
        default: nil
        }
    }

    /// The sheet up right now: the receiver's code, the sender's list, or — on either side,
    /// while the move runs and nothing is asked — how far it has come.
    enum Sheet: Identifiable, Equatable {
        case hold(code: String)
        case pick
        /// One id for every running step, so the sheet stays up and redraws as the move goes on
        /// rather than coming down and going up again at each.
        case progress

        var id: String {
            switch self {
            case .hold(let code): "hold " + code
            case .pick: "pick"
            case .progress: "progress"
            }
        }
    }

    var sheet: Sheet? { Self.sheet(for: step) }

    static func sheet(for step: Step?) -> Sheet? {
        switch step {
        case .holding(let code): .hold(code: code)
        case .browsing: .pick
        default: stage(step, side: .offering) == nil ? nil : .progress
        }
    }

    /// Where a running move is, as the progress sheet says it: the stage's line, how far where
    /// that is known, and whether it may still be stopped.
    struct Stage: Equatable {
        let line: String
        let fraction: Double?
        let canCancel: Bool
    }

    /// The stage at `step` on `side`, or nothing where the step is not a running move — a code,
    /// the list, a question, a notice.
    ///
    /// **Stopped by the person until the receiver is reading back**, the rule `dismiss` keeps:
    /// once every byte is there the read back runs to its end, and on the sender a stop then
    /// stops nothing that matters and only loses the notice.
    static func stage(_ step: Step?, side: Side?) -> Stage? {
        let sending = side != .holding
        switch step {
        case .packing(let progress): return Stage(line: "nearby.stage.packing", fraction: known(progress), canCancel: true)
        case .connecting: return Stage(line: "nearby.stage.connecting", fraction: nil, canCancel: true)
        case .waiting: return Stage(line: "nearby.stage.waiting", fraction: nil, canCancel: true)
        case .moving(let progress, _):
            return Stage(line: sending ? "nearby.stage.sending" : "nearby.stage.receiving", fraction: known(progress), canCancel: true)
        case .reconnecting: return Stage(line: "nearby.stage.reconnecting", fraction: nil, canCancel: true)
        case .settling(let progress, _):
            let line = sending ? "nearby.stage.provingThere" : progress == nil ? "nearby.stage.proving" : "nearby.stage.reading"
            return Stage(line: line, fraction: progress.flatMap(known), canCancel: false)
        default: return nil
        }
    }

    /// A fraction only where there is a total to be a fraction of.
    private static func known(_ progress: PackageProgress) -> Double? {
        progress.total > 0 ? progress.fraction : nil
    }

    var peers: [NearbyPeer] {
        if case .browsing(let peers) = step { peers } else { [] }
    }

    var progress: PackageProgress? {
        switch step {
        case .packing(let progress), .moving(let progress, _), .settling(let progress?, _): progress
        default: nil
        }
    }

    /// The other device's name, where the step knows it.
    var peer: String? {
        switch step {
        case .connecting(let peer), .waiting(let peer), .moving(_, let peer), .reconnecting(let peer),
             .settling(_, let peer), .done(_, let peer):
            peer
        case .asking(let ask): ask.peer
        case .packing: picked?.name
        default: nil
        }
    }

    var isUp: Bool { step != nil }

    private var isSettling: Bool {
        if case .settling = step { true } else { false }
    }

    // MARK: - Holding (the receiver)

    /// This device will hold: it advertises and shows its code. `device` is its name; `adopt`
    /// runs once the store is read back, so the shell reads what is now here; `pictures` is held
    /// still while the package's copies are moved in.
    func beginHold(
        with carrier: any StoreCarrier, link: any NearbyLink, device: String, pictures: DiskCopies? = nil,
        adopt: @escaping @MainActor () async -> Void
    ) {
        guard step == nil else { return }
        side = .holding
        self.pictures = pictures
        self.adopt = adopt
        let move = NearbyMove(link: link, carrier: carrier, device: device)
        self.move = move
        step = .holding(code: "")
        follow { await move.hold() }
    }

    // MARK: - Offering (the sender)

    /// This device will send: it weighs what is here and lists the devices nearby holding.
    func beginOffer(with carrier: any StoreCarrier, link: any NearbyLink) {
        guard step == nil else { return }
        side = .offering
        picked = nil
        code = ""
        weight = nil
        step = .browsing([])
        browsing = Task { @MainActor [weak self] in
            if let weight = try? await carrier.weigh() { self?.weight = weight }
            do {
                for try await peers in link.browse() {
                    guard let self else { return }
                    self.lastPeers = peers
                    guard case .browsing = self.step else { continue }
                    self.step = .browsing(peers)
                    if let picked = self.picked, !peers.contains(picked) { self.picked = nil }
                }
            } catch {
                guard let self, case .browsing = self.step else { return }
                self.step = .refused(NearbyRefusal(error))
            }
        }
    }

    /// The person picked a device, typed its code and chose what rides. Before anything joins,
    /// the mark the digits and that device's session make is shown and the person asked whether
    /// the other screen shows the same: a device that does not know the code cannot show it.
    func offer(code: String, rides: Rides) {
        guard case .browsing = step, let peer = picked, NearbyCode.isWellFormed(code) else { return }
        let digits = code.trimmingCharacters(in: .whitespacesAndNewlines)
        self.code = digits
        mark = NearbyCode.mark(code: digits, sessionID: peer.sessionID)
        step = .checkingMark(MarkCheck(peer: peer, code: digits, rides: rides, mark: mark))
    }

    /// The other screen shows the same mark: the package is written and the device joined.
    /// `save` writes the store to disk first, so the package holds what is on screen.
    func markMatched(
        with carrier: any StoreCarrier, link: any NearbyLink, device: String, save: @escaping @MainActor () async -> Void
    ) {
        guard case .checkingMark(let check) = step else { return }
        browsing?.cancel()
        browsing = nil
        step = .packing(PackageProgress(done: 0, total: 0))
        hold(true)
        let move = NearbyMove(link: link, carrier: carrier, device: device)
        self.move = move
        follow {
            await save()
            return await move.offer(to: check.peer, code: check.code, pictures: check.rides.pictures, contents: check.rides.contents)
        }
    }

    /// The other screen shows something else: nothing joins, and the list is back.
    func markMismatched() {
        guard case .checkingMark = step else { return }
        code = ""
        mark = ""
        step = .browsing(lastPeers)
    }

    // MARK: - Answering

    /// The person's answer to the question here. A yes on the receiver holds the copies on disk
    /// still while the package's are moved in; either no closes the link with nothing written.
    func answer(_ yes: Bool) {
        guard case .asking(let ask) = step, let move else { return }
        guard yes else {
            Task { await move.answer(false) }
            dismiss()
            return
        }
        step = .waiting(peer: ask.peer)
        hold(true)
        let pictures = ask.receiving ? self.pictures : nil
        let round = self.round
        Task { @MainActor [weak self] in
            if let pictures {
                await pictures.hold()
                guard let self, self.round == round else {
                    pictures.release()
                    return
                }
                self.heldPictures = pictures
            }
            await move.answer(true)
        }
    }

    // MARK: - Every way out

    /// The sheet up was put away by something other than a press on it — Escape on the code, a
    /// swipe, the pane going. The code or the list is out, as ever. **The progress sheet is no
    /// question**: a move under way goes on whatever takes its sheet down, and only its Cancel
    /// stops it. Judged on the sheet up, so a clearing written back once the step has moved on
    /// stops nothing.
    func sheetPutAway() {
        switch sheet {
        case .hold, .pick: dismiss()
        case .progress, nil: break
        }
    }

    /// Whatever is up comes down and whatever is running stops. A move whose bytes have all
    /// arrived is being read back and runs to its end (`confirmReadBack`'s rule); dismissing
    /// then does nothing.
    func dismiss() {
        if case .settling = step, side == .holding { return }
        task?.cancel()
        task = nil
        browsing?.cancel()
        browsing = nil
        if let move {
            Task { await move.stop() }
        }
        move = nil
        end()
        step = nil
        side = nil
        picked = nil
        code = ""
        mark = ""
        since = nil
    }

    /// The record's line ended, the store let go, the copies released.
    private func end() {
        if let token {
            work.end(token)
            self.token = nil
        }
        letGo()
        pictures = nil
    }

    /// What a yes took is given back: the store let go and the copies released — the device
    /// stays awake, which is the run's, not the yes's (`staysAwake`). **At most one hold of the copies is ever outstanding**: one returned is in
    /// `heldPictures` and released here, once; one still pending sees `round` moved on and
    /// gives them straight back. Called on every way back to the code and every way out.
    private func letGo() {
        hold(false)
        round += 1
        heldPictures?.release()
        heldPictures = nil
    }

    private func hold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        holdStill?(on)
    }

    // MARK: - Following the move

    private func follow(_ start: @escaping @MainActor () async -> AsyncStream<NearbyMove.Event>) {
        let move = self.move
        task = Task { @MainActor [weak self] in
            let events = await start()
            for await event in events {
                guard let self, self.move === move else { return }
                self.took(event)
            }
        }
    }

    /// One event of the move, as a step.
    private func took(_ event: NearbyMove.Event) {
        switch event {
        case .code(let code, let sessionID):
            // Back to the code — a first code, or a new one after a drop — nothing is being
            // moved in: whatever a yes held is let go, so the next yes holds afresh.
            letGo()
            self.code = code
            mark = NearbyCode.mark(code: code, sessionID: sessionID)
            step = .holding(code: code)
        case .joined:
            // A device proved the code; its line is begun before its offer names it.
            begin(peer: L10n.t("nearby.unnamed"))
        case .packing(let progress):
            // Taken only while still packing: a late figure never moves a later step back.
            if case .packing = step { step = .packing(progress) }
        case .connecting:
            let peer = picked?.name ?? ""
            begin(peer: peer)
            step = .connecting(peer: peer)
        case .asking(let offer, let peer, let held):
            name(peer)
            step = .asking(Ask(offer: offer, peer: peer, held: held, receiving: side == .holding))
        case .waiting(let peer):
            step = .waiting(peer: peer)
        case .moving(let progress, let peer):
            if since == nil { since = Date() }
            step = .moving(progress, peer: peer)
        case .reconnecting(let peer):
            step = .reconnecting(peer: peer)
        case .settling(let progress, let peer):
            // A read back's figure is taken only while settling: a late one never moves a
            // later step back.
            if progress != nil, !isSettling { return }
            step = .settling(progress, peer: peer)
        case .done(let summary, let peer):
            let adopt = side == .holding ? self.adopt : nil
            end()
            step = .done(summary, peer: peer)
            if let adopt {
                Task { @MainActor in await adopt() }
            }
        case .refused(let refusal):
            end()
            step = .refused(refusal)
        case .closed:
            end()
            step = nil
            side = nil
        }
    }

    /// One line under the other device's name, begun once.
    private func begin(peer: String) {
        guard token == nil, !peer.isEmpty else { return }
        token = work.beginNearby(peer: peer)
    }

    /// The other device named itself: the line begun at the join is listed under that name.
    private func name(_ peer: String) {
        guard !peer.isEmpty else { return }
        guard let token else {
            begin(peer: peer)
            return
        }
        work.renameNearby(token, peer: peer)
    }
}
