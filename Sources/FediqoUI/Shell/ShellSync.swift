import FediqoCore
import Foundation
import Observation

/// The first-merge question (D8), while one is asked: who it is with and what would change.
struct SyncAsk: Equatable, Identifiable {
    let id: String
    let peer: PairedDevice
    let preview: SyncPreview
}

/// What the last merge with a device came to, and when: the toast on the lead window and the
/// line under the paired devices.
struct SyncTold: Equatable {
    let peer: PairedDevice
    let outcome: SyncOutcome
    let at: Date
}

/// The run's merging with paired devices nearby (D1–D8): made once by the app, shared by every
/// window, and the one `SyncLocal` the session asks.
///
/// **In front only** (D6): it runs while at least one window is out of the background — a Mac
/// window that is merely not key is `.inactive` and keeps it running. While it runs and the period
/// is not "never", every paired device is listened for, and each one is looked for and merged once
/// its period has passed — asked at once on coming to the front, then every `dueCheck`. "Sync now"
/// looks for `syncNowWindow` whatever the period. The last window to come to the front is the
/// `lead`: the first-merge question, the toast and the shell's own removal path run there.
///
/// **A merge goes in by the person's own paths** (D4, D5): the store lays in what won, a source new
/// here signed out; a removal that arrived is the lead's Remove with its posts kept; the timelines
/// are written once, and every window reads them again through the store's `kept` notice.
@MainActor
@Observable
public final class ShellSync {
    /// Where pairing is, while it is up.
    enum PairStep: Equatable {
        /// This device shows a code and its name, and waits for the other to join; nil until
        /// the first code is made.
        case holding(code: String?, mark: String?)
        /// The devices nearby holding a pairing code.
        case browsing([NearbyPeer])
        /// The code is typed; the person is asked whether the other screen shows this mark.
        case checkingMark(peer: NearbyPeer, code: String, mark: String)
        /// Joined: pairing, then the first merge.
        case running(Running)
        /// How it ended.
        case ended(Ended)

        enum Running: Equatable {
            case connecting
            case paired(PairedDevice)
            case merging(PairedDevice)
            /// The other device is looking at the first-merge question.
            case waiting(PairedDevice)
        }

        enum Ended: Equatable {
            /// Paired, and what the first merge came to.
            case done(PairedDevice, SyncOutcome)
            /// The other end is this very device.
            case sameDevice
            case refused(NearbyRefusal)
        }
    }

    /// A Sync now that found nobody, or a look the system refused.
    enum Looked: Equatable {
        case nobodyFound
        case notAllowed
    }

    let clock: SyncClock
    let deviceName: String
    private(set) var paired: [PairedDevice] = []
    private(set) var asking: SyncAsk?
    /// The other device is looking at its first-merge question.
    private(set) var waiting: PairedDevice?
    private(set) var told: SyncTold?
    private(set) var looked: Looked?
    private(set) var pairStep: PairStep?
    private(set) var lookingNow = false

    /// How often paired devices are looked for (D6), kept with the person's other choices
    /// (`DummyPrefs.syncPeriod`). Setting it starts listening and the due check again under it.
    var period: SyncPeriod {
        didSet {
            guard period != oldValue else { return }
            DummyPrefs.keep(syncPeriod: period, in: defaults)
            restart()
        }
    }

    /// The person's choices read again, as each window's are after a read back
    /// (`DummyPrefs.reread`): a period that came with the package takes effect at once.
    func reread() {
        period = DummyPrefs.syncPeriod(in: defaults)
    }

    /// Whether the pairing sheet is the one showing the first-merge question.
    var pairingAsks: Bool {
        if case .running? = pairStep { true } else { false }
    }

    @ObservationIgnored private let pairs: any PairStore
    @ObservationIgnored private let link: any SyncLink
    @ObservationIgnored private let store: ItemStore
    @ObservationIgnored private let timelines: WrittenTimelineStore?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let timing: SyncTiming
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let session: SyncSession
    /// The devices last listed holding a pairing code, for the list to come back to.
    @ObservationIgnored private var lastPeers: [NearbyPeer] = []
    /// The windows out of the background, by identity, held weakly.
    @ObservationIgnored private var inFront: [ObjectIdentifier: Weak] = [:]
    @ObservationIgnored private weak var lead: ShellSession? {
        didSet { leadID = lead.map(ObjectIdentifier.init) }
    }
    /// Which window leads, as the windows read it.
    private var leadID: ObjectIdentifier?
    /// The window pairing began on: its sheet stays there when another window leads.
    @ObservationIgnored private weak var pairWindow: ShellSession? {
        didSet { pairWindowID = pairWindow.map(ObjectIdentifier.init) }
    }
    private var pairWindowID: ObjectIdentifier?
    @ObservationIgnored private var listening: Task<Void, Never>?
    /// Counts each listen started, so an ended one clears only its own.
    @ObservationIgnored private var listenRun = 0
    @ObservationIgnored private var dueChecks: Task<Void, Never>?
    @ObservationIgnored private var looking: Task<Void, Never>?
    @ObservationIgnored private var pairing: Task<Void, Never>?
    @ObservationIgnored private var browsing: Task<Void, Never>?
    @ObservationIgnored private var answering: CheckedContinuation<Bool?, Never>?

    private struct Weak {
        weak var session: ShellSession?
    }

    /// The app's: the timelines kept in `lists`' file, as every window keeps them.
    public convenience init(
        link: any SyncLink, pairs: any PairStore, clock: SyncClock, deviceName: String, store: ItemStore,
        lists: ListFiles?, defaults: UserDefaults = .standard
    ) {
        self.init(
            link: link, pairs: pairs, clock: clock, deviceName: deviceName, store: store,
            timelines: WrittenTimelineStore(defaults: defaults, file: lists?.timelines), defaults: defaults
        )
    }

    init(
        link: any SyncLink, pairs: any PairStore, clock: SyncClock, deviceName: String, store: ItemStore,
        timelines: WrittenTimelineStore?, defaults: UserDefaults = .standard, timing: SyncTiming = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.link = link
        self.pairs = pairs
        self.clock = clock
        self.deviceName = deviceName
        self.store = store
        self.timelines = timelines
        self.defaults = defaults
        period = DummyPrefs.syncPeriod(in: defaults)
        self.timing = timing
        self.now = now
        let relay = Relay()
        session = SyncSession(link: link, pairs: pairs, clock: clock, name: deviceName, local: relay, timing: timing, now: now)
        relay.owner = self
        refresh()
    }

    /// Whether loops run now: a window in front.
    var running: Bool { !inFront.isEmpty }
    var isListening: Bool { listening != nil }

    /// Whether `window` is the one the question and the toast are put on.
    func leads(_ window: ShellSession) -> Bool {
        leadID == ObjectIdentifier(window)
    }

    // MARK: - Windows

    /// A window came to the front: it leads, and listening and the due check start where they
    /// are not running.
    func cameToFront(_ window: ShellSession) {
        inFront[ObjectIdentifier(window)] = Weak(session: window)
        lead = window
        refresh()
        start()
    }

    /// A window went to the background; with none left in front, both loops stop. A merge in
    /// flight drops — nothing is half written, as each store writes whole.
    func wentAway(_ window: ShellSession) {
        inFront[ObjectIdentifier(window)] = nil
        if lead === window { lead = inFront.values.lazy.compactMap(\.session).first }
        if inFront.isEmpty { stop() }
    }

    /// A window closed: a pairing it showed goes to the lead.
    func windowGone(_ window: ShellSession) {
        if pairWindow === window { pairWindow = nil }
        wentAway(window)
    }

    /// Whether `window` shows the pairing sheet: the window that began it, while it is open,
    /// whichever leads — else the lead. Nil (no shell around the pane) shows it.
    func showsPairing(on window: ShellSession?) -> Bool {
        guard pairStep != nil else { return false }
        guard let window else { return true }
        if let pairWindowID { return pairWindowID == ObjectIdentifier(window) }
        return leads(window)
    }

    private func start() {
        guard running, period.interval != nil, !paired.isEmpty else { return }
        if listening == nil {
            listenRun += 1
            let run = listenRun
            listening = Task { [weak self, session] in
                do {
                    try await session.listen()
                } catch SyncRefusal.notAllowed {
                    self?.looked = .notAllowed
                } catch {}
                // Only this run's own end: one stopped and replaced leaves the new one standing.
                if self?.listenRun == run { self?.listening = nil }
            }
        }
        if dueChecks == nil {
            let every = timing.dueCheck
            dueChecks = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    // The pairs as last read: nothing is read again unless one is due.
                    if await self.session.anyDue(self.paired, period: self.period) {
                        _ = await self.session.dialDue(period: self.period)
                    }
                    try? await Task.sleep(for: every)
                }
            }
        }
    }

    private func stop() {
        listening?.cancel()
        listening = nil
        dueChecks?.cancel()
        dueChecks = nil
    }

    /// Listening and the due check again: a pair kept or forgotten, or the period changed.
    private func restart() {
        stop()
        start()
    }

    /// The pairs read again: at the start, on coming to the front, and where pairing, a merge
    /// or Forget changed them.
    private func refresh() {
        let now = (try? pairs.pairs()) ?? []
        if now != paired { paired = now }
    }

    // MARK: - What a person presses

    /// Looks for every paired device for `syncNowWindow` and merges with each one found,
    /// whatever the period.
    func syncNow() {
        guard looking == nil else { return }
        lookingNow = true
        looked = nil
        looking = Task { [weak self, session] in
            _ = await session.syncNow()
            guard let self else { return }
            self.lookingNow = false
            self.looking = nil
        }
    }

    /// The first-merge question's answer.
    func answer(_ yes: Bool) {
        settleAsk(yes)
    }

    /// This side forgets `device`: its secret goes, the other no longer finds this one.
    func forget(_ device: PairedDevice) {
        try? pairs.forget(device: device.device)
        if told?.peer.device == device.device { told = nil }
        refresh()
        restart()
    }

    /// Shows a code and this device's name, and waits for the other device to join.
    func beginPairHold(from window: ShellSession? = nil) {
        guard pairStep == nil else { return }
        pairWindow = window
        pairStep = .holding(code: nil, mark: nil)
        follow { await $0.holdPairing() }
    }

    /// Lists the devices nearby holding a pairing code.
    func beginPairBrowse(from window: ShellSession? = nil) {
        guard pairStep == nil else { return }
        pairWindow = window
        pairStep = .browsing([])
        browsing = Task { [weak self, link] in
            do {
                for try await listed in link.browse(pairing: true) {
                    guard let self else { return }
                    self.lastPeers = listed
                    guard case .browsing = self.pairStep else { continue }
                    self.pairStep = .browsing(self.lastPeers)
                }
            } catch {
                guard let self, case .browsing = self.pairStep else { return }
                self.pairStep = .ended(.refused(NearbyRefusal(error)))
            }
        }
    }

    /// A device picked and its code typed: the mark is shown and asked about before anything joins.
    func typed(code: String, for peer: NearbyPeer) {
        guard case .browsing = pairStep, NearbyCode.isWellFormed(code) else { return }
        let digits = code.trimmingCharacters(in: .whitespacesAndNewlines)
        pairStep = .checkingMark(peer: peer, code: digits, mark: NearbyCode.mark(code: digits, sessionID: peer.sessionID))
    }

    /// The other screen shows the same mark: this device joins it.
    func markMatched() {
        guard case .checkingMark(let peer, let code, _) = pairStep else { return }
        beginPairJoin(peer: peer, code: code)
    }

    /// The other screen shows another: back to the list.
    func markMismatched() {
        guard case .checkingMark = pairStep else { return }
        pairStep = .browsing(lastPeers)
    }

    func beginPairJoin(peer: NearbyPeer, code: String) {
        browsing?.cancel()
        browsing = nil
        pairStep = .running(.connecting)
        follow { await $0.joinPairing(peer: peer, code: code) }
    }

    /// Pairing put away, wherever it was: a hold or a join stops, and an ended one is cleared.
    func stopPairing() {
        pairing?.cancel()
        pairing = nil
        browsing?.cancel()
        browsing = nil
        if case .running = pairStep { settleAsk(nil) }
        pairStep = nil
        pairWindow = nil
        let session = session
        Task { await session.stopPairing() }
    }

    private func follow(_ start: @escaping @Sendable (SyncSession) async -> AsyncStream<PairingEvent>) {
        pairing?.cancel()
        let session = session
        pairing = Task { [weak self] in
            let events = await start(session)
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.took(event)
            }
        }
    }

    /// Each event as the step it shows, once.
    private func took(_ event: PairingEvent) {
        switch event {
        case .code(let code, let sessionID):
            pairStep = .holding(code: code, mark: NearbyCode.mark(code: code, sessionID: sessionID))
        case .connecting:
            pairStep = .running(.connecting)
        case .paired(let peer):
            pairStep = .running(.paired(peer))
            refresh()
            restart()
        case .merging(let peer):
            pairStep = .running(.merging(peer))
        case .waitingForAnswer(let peer):
            pairStep = .running(.waiting(peer))
        case .done(let peer, let outcome):
            pairStep = .ended(.done(peer, outcome))
            told = SyncTold(peer: peer, outcome: outcome, at: now())
            refresh()
        case .sameDevice:
            pairStep = .ended(.sameDevice)
        case .refused(let refusal):
            pairStep = .ended(.refused(refusal))
        }
    }

    // MARK: - The first-merge question

    /// Asked until answered, or until the session stops waiting (`answerWait`, or the merge
    /// put away): its cancellation takes the question down as no.
    fileprivate func confirm(_ preview: SyncPreview, with peer: PairedDevice) async -> Bool? {
        guard lead != nil || pairStep != nil else { return nil }
        settleAsk(nil)
        asking = SyncAsk(id: peer.device + "-" + UUID().uuidString, peer: peer, preview: preview)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if asking == nil {
                    continuation.resume(returning: nil)
                } else {
                    answering = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.settleAsk(nil) }
        }
    }

    private func settleAsk(_ answer: Bool?) {
        asking = nil
        answering?.resume(returning: answer)
        answering = nil
    }

    // MARK: - SyncLocal

    fileprivate func snapshot() async throws -> SyncSnapshot {
        let sources = await store.syncEntries()
        guard let timelines else { return SyncSnapshot(sources: sources) }
        guard let held = timelines.syncEntries() else { throw SyncRefusal.unreadableHere }
        return SyncSnapshot(sources: sources, timelines: held)
    }

    fileprivate func readable(_ remote: SyncSnapshot) -> Bool {
        remote.timelines.values.allSatisfy { entry in
            guard let value = entry.value else { return true }
            return WrittenTimelineStore.definition(from: value.body) != nil
        }
    }

    /// The timelines first, read and written once with nothing between, so nothing is laid in
    /// where they cannot be; then the store, and the lead's removals and asks.
    fileprivate func apply(_ changes: SyncChanges, from peer: PairedDevice) async throws {
        if !changes.timelines.isEmpty {
            guard let timelines, let held = timelines.loadStamped(),
                  timelines.settle(arrived: changes.timelines, held: held) == true
            else { throw SyncRefusal.unreadableHere }
        }
        if !changes.sources.isEmpty {
            let settled = await store.settle(arrived: changes.sources)
            if let lead {
                await lead.takeMerged(settled)
            } else {
                for host in settled.toRemove.keys.sorted() {
                    await store.remove(host: host, keepingPosts: true)
                }
            }
        }
        lead?.saveSoon()
        let stamps = changes.sources.values.map(\.stamp) + changes.timelines.values.map(\.stamp)
        if let newest = stamps.max() { clock.witness(newest) }
    }

    fileprivate func said(_ event: SyncEvent) {
        switch event {
        case .looking:
            lookingNow = true
        case .joined:
            break
        case .waitingForAnswer(let peer):
            waiting = peer
        case .done(let peer, let outcome):
            if waiting?.device == peer.device { waiting = nil }
            // Busy is the other merge with that device under way: its own outcome is said.
            if outcome != .notMerged(.busy) { told = SyncTold(peer: peer, outcome: outcome, at: now()) }
            refresh()
            if let toast = Self.toast(outcome, peer: peer.name) { lead?.showToast(toast) }
        case .nobodyFound:
            looked = .nobodyFound
        case .refusedLooking(let refusal):
            looked = refusal == .notAllowed ? .notAllowed : .nobodyFound
        }
    }

    // MARK: - Words

    /// The toast a merge leaves on the lead window: something changed, or why it did not. Nothing
    /// where both were already equal, or where the other side's merge was the one that ran.
    static func toast(_ outcome: SyncOutcome, peer: String, language: DummyLanguage? = nil) -> String? {
        switch outcome {
        case .nothingToMerge: nil
        case .notMerged(.busy): nil
        case .merged, .notMerged: outcomeLine(outcome, peer: peer, language: language)
        }
    }

    /// One sentence for what a merge with `peer` came to.
    static func outcomeLine(_ outcome: SyncOutcome, peer: String, language: DummyLanguage? = nil) -> String {
        switch outcome {
        case .merged(let here, _):
            String(format: L10n.t("sync.merged", language: language), peer, changesLine(here, language: language))
        case .nothingToMerge:
            String(format: L10n.t("sync.equal", language: language), peer)
        case .notMerged(let refusal):
            String(format: L10n.t("sync.refused." + refusalKey(refusal), language: language), peer)
        }
    }

    /// "2 sources and 1 timeline changed here", or "Nothing changed here".
    static func changesLine(_ summary: SyncSummary, language: DummyLanguage? = nil) -> String {
        let sources = summary.addedSources.count + summary.replacedSources.count + summary.removedSources.count
        let timelines = summary.addedTimelines.count + summary.replacedTimelines.count + summary.removedTimelines.count
        switch (sources, timelines) {
        case (0, 0): return L10n.t("sync.changes.none", language: language)
        case (_, 0): return L10n.count("sync.changes.sources", sources, language: language)
        case (0, _): return L10n.count("sync.changes.timelines", timelines, language: language)
        case (_, _):
            return String(
                format: L10n.t("sync.changes.both", language: language),
                L10n.count("sync.count.sources", sources, language: language),
                L10n.count("sync.count.timelines", timelines, language: language)
            )
        }
    }

    /// The key of a refusal's sentence: every one said as itself.
    static func refusalKey(_ refusal: SyncRefusal) -> String {
        switch refusal {
        case .peerOlder: "peerOlder"
        case .peerNewer, .otherVersion: "peerNewer"
        case .notPaired: "notPaired"
        case .declined: "declined"
        case .unreadableHere: "unreadableHere"
        case .unreadableThere: "unreadableThere"
        case .clockAhead: "clockAhead"
        case .busy: "busy"
        case .tooLarge: "tooLarge"
        case .malformed: "malformed"
        case .notAllowed: "notAllowed"
        case .lost: "lost"
        }
    }
}

/// The session's view of `ShellSync`, held weakly so the session does not keep it.
@MainActor
private final class Relay: SyncLocal {
    weak var owner: ShellSync?

    func snapshot() async throws -> SyncSnapshot {
        guard let owner else { throw SyncRefusal.unreadableHere }
        return try await owner.snapshot()
    }

    func readable(_ remote: SyncSnapshot) async -> Bool {
        owner?.readable(remote) ?? false
    }

    func confirm(_ preview: SyncPreview, with peer: PairedDevice) async -> Bool? {
        await owner?.confirm(preview, with: peer)
    }

    func apply(_ changes: SyncChanges, from peer: PairedDevice) async throws {
        guard let owner else { throw SyncRefusal.unreadableHere }
        try await owner.apply(changes, from: peer)
    }

    func said(_ event: SyncEvent) async {
        owner?.said(event)
    }
}

extension ShellSession {
    /// This window's part of a merge (D4, D5). Each removal that arrived is the person's own Remove
    /// with the posts kept, whatever `removedPostsStay` says, at the stamp it arrived with (the
    /// store keeps it from `settle(arrived:)`). Each
    /// source new here was added signed out by the store; it is read in and asked once, behind the
    /// merge rather than in it.
    func takeMerged(_ settled: SourcesSettled) async {
        for host in settled.toRemove.keys.sorted() {
            await remove(host: host, keepingPosts: true)
        }
        guard !settled.added.isEmpty || !settled.restated.isEmpty else { return }
        await adopt()
        for host in settled.added {
            Task { [weak self] in
                guard let self else { return }
                await self.reload.joined(FetchAsk(host: host, categories: nil), in: self)
            }
        }
    }
}
