import FediqoCore
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

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
/// written and the receiver's yes, until every way out. The screen stays awake on a phone
/// meanwhile, and the move is foreground-only: a suspension is a dropped link that resumes.
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
        /// Every byte is there; the receiver proves and reads it back.
        case settling(peer: String)
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

    private(set) var step: Step?
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
    @ObservationIgnored private var move: NearbyMove?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var browsing: Task<Void, Never>?
    @ObservationIgnored private var token: SourceWork.Token?
    @ObservationIgnored private var pictures: DiskCopies?
    @ObservationIgnored private var adopt: (@MainActor () async -> Void)?
    @ObservationIgnored private var holding = false
    /// The devices last listed, for the list to come back to.
    @ObservationIgnored private var lastPeers: [NearbyPeer] = []

    init(work: SourceWork = .shared) {
        self.work = work
    }

    // MARK: - What a screen reads

    /// The question or notice up right now, where the step is one.
    var asking: Step? {
        switch step {
        case .asking, .refused, .done, .checkingMark: step
        default: nil
        }
    }

    /// The sheet up right now: the receiver's code, or the sender's list.
    enum Sheet: Identifiable, Equatable {
        case hold(code: String)
        case pick

        var id: String {
            switch self {
            case .hold(let code): "hold " + code
            case .pick: "pick"
            }
        }
    }

    var sheet: Sheet? {
        switch step {
        case .holding(let code): .hold(code: code)
        case .browsing: .pick
        default: nil
        }
    }

    var peers: [NearbyPeer] {
        if case .browsing(let peers) = step { peers } else { [] }
    }

    var progress: PackageProgress? {
        switch step {
        case .packing(let progress), .moving(let progress, _): progress
        default: nil
        }
    }

    /// The other device's name, where the step knows it.
    var peer: String? {
        switch step {
        case .connecting(let peer), .waiting(let peer), .moving(_, let peer), .reconnecting(let peer),
             .settling(let peer), .done(_, let peer):
            peer
        case .asking(let ask): ask.peer
        case .packing: picked?.name
        default: nil
        }
    }

    var isUp: Bool { step != nil }

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
        Task { @MainActor in
            await pictures?.hold()
            await move.answer(true)
        }
    }

    // MARK: - Every way out

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

    /// The record's line ended, the store let go, the copies released, the screen let sleep.
    private func end() {
        if let token {
            work.end(token)
            self.token = nil
        }
        hold(false)
        pictures?.release()
        pictures = nil
        Self.keepAwake(false)
    }

    private func hold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        holdStill?(on)
        Self.keepAwake(on)
    }

    /// The screen stays awake on a phone while the move runs: a phone that sleeps is a link
    /// that drops.
    private static func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
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
        case .settling(let peer):
            step = .settling(peer: peer)
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
