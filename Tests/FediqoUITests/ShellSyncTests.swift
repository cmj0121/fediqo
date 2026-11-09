import CryptoKit
import FediqoCore
import Foundation
import Synchronization
import Testing
@testable import FediqoUI

/// U6: paired devices merging on the shell (D4, D5, D6, D8). Two `ShellSync`s over a pipe, each
/// with a window: a source that arrives is added signed out and read in, a removal that arrives
/// keeps its posts, a timeline that arrives shows in every window; the first merge waits for a
/// yes on one device and a no keeps the pair unmerged; it runs only while a window is in front
/// and the period is not never; Forget; and every word in every language.
@Suite("Paired devices merging, on the shell", .serialized, .watched)
@MainActor
struct ShellSyncTests {
    private static let timing = SyncTiming(
        dueCheck: .seconds(60), syncNowWindow: .seconds(4), answerWait: .seconds(10), stepWait: .seconds(5)
    )

    /// An hour ago: every stamp a check lays in is before anything the clocks make now.
    private static let anHourAgo = Date().timeIntervalSince1970 - 3600

    private static func stamp(_ seconds: Double, _ by: String) -> SyncStamp {
        SyncStamp(ms: Int64((anHourAgo + seconds) * 1000), counter: 0, device: by)
    }

    private static func note(_ host: String, _ id: String) -> Note {
        Note(
            id: "https://\(host)/statuses/\(id)", source: Source(host: host, kind: .mastodon), author: "Ada",
            handle: "@ada@\(host)", body: "hello", postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [.home], statusID: id
        ).readNow()
    }

    /// One device: its store, its timelines file, its window and its `ShellSync`.
    struct Device {
        let id: String
        let name: String
        let store: ItemStore
        let pairs: MemoryPairs
        let window: ShellSession
        let other: ShellSession
        let sync: ShellSync
        let folder: URL
        let defaults: UserDefaults
    }

    private func device(
        _ link: PipeNearbyLink, _ id: String, _ name: String, sources: [Source], notes: [Note] = [],
        sync stamps: SourceSync, timelines: [TimelineDefinition] = []
    ) async throws -> Device {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = SyncDefaults()
        let clock = SyncClock(device: id)
        let store = ItemStore(sources: sources, notes: notes, sync: stamps, clock: clock)
        let file = ListFiles(directory: folder, defaults: defaults, protected: .always).timelines
        if !timelines.isEmpty {
            #expect(WrittenTimelineStore(defaults: defaults, file: file).save(timelines, clock: clock))
        }
        let window = ShellSession(http: FixtureHTTP([:]), store: store, timelines: WrittenTimelineStore(defaults: defaults, file: file))
        let other = ShellSession(http: FixtureHTTP([:]), store: store, timelines: WrittenTimelineStore(defaults: defaults, file: file))
        for session in [window, other] {
            session.syncClock = clock
            await session.adopt()
        }
        let pairs = MemoryPairs()
        let sync = ShellSync(
            link: link, pairs: pairs, clock: clock, deviceName: name, store: store,
            timelines: WrittenTimelineStore(defaults: defaults, file: file), defaults: defaults, timing: Self.timing
        )
        return Device(id: id, name: name, store: store, pairs: pairs, window: window, other: other, sync: sync, folder: folder, defaults: defaults)
    }

    private func pair(_ a: Device, _ b: Device, firstMerged: Bool) throws {
        let secret = SymmetricKey(size: .bits256)
        try a.pairs.keep(PairedDevice(device: b.id, name: b.name, pairedAt: Date(), firstMerged: firstMerged), secret: secret)
        try b.pairs.keep(PairedDevice(device: a.id, name: a.name, pairedAt: Date(), firstMerged: firstMerged), secret: secret)
    }

    private func eventually(_ what: () async -> Bool) async -> Bool {
        for _ in 0..<3000 {
            if await what() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Merged, or found already the same by a later merge.
    private func settled(_ told: SyncTold?) -> Bool {
        merged(told) || told?.outcome == .nothingToMerge
    }

    private func merged(_ told: SyncTold?) -> Bool {
        if case .merged? = told?.outcome { true } else { false }
    }

    @Test("A merge adds what arrived signed out, keeps a removed source's posts, and shows the timeline in every window")
    func merges() async throws {
        let link = PipeNearbyLink()
        let shared = TimelineDefinition(name: "Shared", rules: [])
        let a = try await device(
            link, "A-MAC", "Mac", sources: [Source(host: "a.example", kind: .mastodon)],
            sync: SourceSync(stamps: ["a.example": Self.stamp(10, "A-MAC")], gone: ["gone.example": Self.stamp(50, "A-MAC")]),
            timelines: [shared]
        )
        let b = try await device(
            link, "B-PHONE", "Phone",
            sources: [Source(host: "gone.example", kind: .mastodon, lists: [ListSubscription(id: "1", name: "Friends")])],
            notes: [Self.note("gone.example", "1")],
            sync: SourceSync(stamps: ["gone.example": Self.stamp(20, "B-PHONE")])
        )
        defer { for folder in [a.folder, b.folder] { try? FileManager.default.removeItem(at: folder) } }
        try pair(a, b, firstMerged: true)
        a.sync.cameToFront(a.window)
        b.sync.cameToFront(b.window)
        #expect(await eventually { link.listeners.count >= 2 })

        // Merged at once by the due check, then again by Sync now, which finds both the same.
        b.sync.syncNow()
        #expect(await eventually { await b.store.sources().map(\.host) == ["a.example"] })
        #expect(await eventually { settled(a.sync.told) && settled(b.sync.told) && !b.sync.lookingNow })

        let there = await b.store.sources()
        #expect(there.map(\.host) == ["a.example"], "the removal arrived, and the source new here was added")
        #expect(there.first?.lists.isEmpty == true, "signed out: nothing of an account came with it")
        #expect(!(await b.store.held(host: "gone.example")).isEmpty, "a removal that arrives keeps the posts (D4)")
        #expect(await b.store.sourceSync().gone["gone.example"] == Self.stamp(50, "A-MAC"), "kept at the stamp it arrived with")
        #expect(await eventually { b.window.sources.map(\.host) == ["a.example"] })
        #expect(await eventually { b.window.written.map(\.name) == ["Shared"] && b.other.written.map(\.name) == ["Shared"] })
        #expect(await a.store.sources().map(\.host) == ["a.example"])
        #expect(b.sync.paired.first?.lastMerged != nil && a.sync.paired.first?.firstMerged == true)
        a.sync.wentAway(a.window)
        b.sync.wentAway(b.window)
    }

    @Test("The first merge waits for a yes on one device; a no keeps the pair unmerged and is asked again")
    func firstMerge() async throws {
        let link = PipeNearbyLink()
        let a = try await device(
            link, "A-MAC", "Mac", sources: [Source(host: "a.example", kind: .mastodon)], sync: SourceSync()
        )
        let b = try await device(
            link, "B-PHONE", "Phone", sources: [Source(host: "b.example", kind: .mastodon)], sync: SourceSync()
        )
        defer { for folder in [a.folder, b.folder] { try? FileManager.default.removeItem(at: folder) } }
        try pair(a, b, firstMerged: false)
        a.sync.period = .never
        b.sync.period = .never
        a.sync.cameToFront(a.window)
        b.sync.cameToFront(b.window)
        #expect(!a.sync.isListening && !b.sync.isListening, "never listens")

        a.sync.syncNow()
        b.sync.syncNow()
        #expect(await eventually { a.sync.asking != nil || b.sync.asking != nil })
        let asker = a.sync.asking != nil ? a : b
        let asked = asker.id == a.id ? b : a
        let ask = try #require(asker.sync.asking)
        #expect(ask.peer.device == asked.id)
        #expect(!ask.preview.isEmpty)
        #expect(await eventually { asked.sync.waiting?.device == asker.id }, "the other device says it is waiting")
        asker.sync.answer(false)
        #expect(await eventually { asked.sync.told?.outcome == .notMerged(.declined) && asker.sync.told?.outcome == .notMerged(.declined) })
        #expect(asked.sync.waiting == nil)
        #expect(await b.store.sources().map(\.host) == ["b.example"], "a no changes nothing")
        #expect(a.sync.paired.first?.firstMerged == false && b.sync.paired.first?.firstMerged == false)

        try? await Task.sleep(for: .seconds(4.5))
        a.sync.syncNow()
        b.sync.syncNow()
        #expect(await eventually { a.sync.asking != nil || b.sync.asking != nil }, "asked again at the next join")
        (a.sync.asking != nil ? a : b).sync.answer(true)
        #expect(await eventually { merged(a.sync.told) && merged(b.sync.told) })
        #expect(await a.store.sources().map(\.host).sorted() == ["a.example", "b.example"])
        #expect(a.sync.paired.first?.firstMerged == true && b.sync.paired.first?.firstMerged == true)
        a.sync.wentAway(a.window)
        b.sync.wentAway(b.window)
    }

    @Test("A first-merge question nobody answers within the wait is taken down as a no")
    func unansweredIsNo() async throws {
        let link = PipeNearbyLink()
        let a = try await device(link, "A-MAC", "Mac", sources: [Source(host: "a.example", kind: .mastodon)], sync: SourceSync())
        let b = try await device(link, "B-PHONE", "Phone", sources: [Source(host: "b.example", kind: .mastodon)], sync: SourceSync())
        defer { for folder in [a.folder, b.folder] { try? FileManager.default.removeItem(at: folder) } }
        try pair(a, b, firstMerged: false)
        a.sync.period = .never
        b.sync.period = .never
        a.sync.cameToFront(a.window)
        b.sync.cameToFront(b.window)
        a.sync.syncNow()
        b.sync.syncNow()
        #expect(await eventually { a.sync.asking != nil || b.sync.asking != nil })
        let asker = a.sync.asking != nil ? a : b
        #expect(await eventually { asker.sync.asking == nil }, "taken down once the wait is over")
        #expect(await eventually { asker.sync.told?.outcome == .notMerged(.declined) })
        #expect(await b.store.sources().map(\.host) == ["b.example"], "no answer changes nothing")
        a.sync.wentAway(a.window)
        b.sync.wentAway(b.window)
    }

    @Test("It listens only while a window is in front and the period is not never; the period is kept; Forget stops it")
    func runsInFront() async throws {
        let link = PipeNearbyLink()
        let a = try await device(link, "A-MAC", "Mac", sources: [], sync: SourceSync())
        let b = try await device(link, "B-PHONE", "Phone", sources: [], sync: SourceSync())
        defer { for folder in [a.folder, b.folder] { try? FileManager.default.removeItem(at: folder) } }
        #expect(a.sync.period == .hour, "one hour unless chosen")
        a.sync.cameToFront(a.window)
        #expect(!a.sync.isListening, "nothing paired, nothing to listen for")
        a.sync.wentAway(a.window)

        try pair(a, b, firstMerged: true)
        a.sync.forget(PairedDevice(device: "nobody", name: "x", pairedAt: Date()))
        #expect(a.sync.paired.map(\.device) == [b.id])
        a.sync.cameToFront(a.window)
        a.sync.cameToFront(a.other)
        #expect(a.sync.isListening && a.sync.leads(a.other))
        #expect(await eventually { link.listeners.count == 1 })
        a.sync.wentAway(a.other)
        #expect(a.sync.isListening && a.sync.leads(a.window), "another window still in front leads")
        a.sync.period = .never
        #expect(!a.sync.isListening)
        a.sync.period = .tenMinutes
        #expect(a.sync.isListening)
        a.sync.windowGone(a.window)
        #expect(!a.sync.isListening && !a.sync.running, "no window in front, nothing runs")
        #expect(await eventually { link.listeners.isEmpty }, "a listen replaced by a restart is not left running")

        a.sync.cameToFront(a.window)
        #expect(await eventually { link.listeners.count == 1 })
        a.sync.period = .hour
        a.sync.period = .sixHours
        #expect(await eventually { link.listeners.count == 1 })
        a.sync.wentAway(a.window)
        #expect(await eventually { link.listeners.isEmpty }, "restarted, then sent away: nothing listens")
        a.sync.cameToFront(a.window)
        a.sync.wentAway(a.window)
        a.sync.cameToFront(a.window)
        a.sync.wentAway(a.window)
        #expect(await eventually { link.listeners.isEmpty }, "back and forth quickly leaves nothing listening")
        a.sync.period = .never
        a.defaults.set("10m", forKey: "fediqo.dummy.syncPeriod")
        a.sync.reread()
        #expect(a.sync.period == .tenMinutes, "a read back's period takes effect at once")

        let again = ShellSync(
            link: link, pairs: a.pairs, clock: SyncClock(device: a.id), deviceName: "Mac", store: a.store, timelines: nil,
            defaults: a.defaults, timing: Self.timing
        )
        #expect(again.period == .tenMinutes, "kept with the person's choices")

        a.sync.cameToFront(a.window)
        a.sync.forget(try #require(a.sync.paired.first))
        #expect(a.sync.paired.isEmpty && !a.sync.isListening)
        #expect(try a.pairs.secret(for: b.id) == nil)
        a.sync.wentAway(a.window)
    }

    @Test("Pairing stays on the window it began on when another leads, and goes to the lead once that window closes")
    func pairingStaysOnItsWindow() async throws {
        let link = PipeNearbyLink()
        let a = try await device(link, "A-MAC", "Mac", sources: [], sync: SourceSync())
        defer { try? FileManager.default.removeItem(at: a.folder) }
        a.sync.cameToFront(a.window)
        a.sync.beginPairHold(from: a.window)
        #expect(a.sync.showsPairing(on: a.window) && !a.sync.showsPairing(on: a.other))
        a.sync.cameToFront(a.other)
        #expect(a.sync.leads(a.other))
        #expect(a.sync.showsPairing(on: a.window), "the window it began on keeps it")
        #expect(!a.sync.showsPairing(on: a.other), "the lead shows no second pairing sheet")
        a.sync.windowGone(a.window)
        #expect(a.sync.showsPairing(on: a.other), "the lead takes it once that window is gone")
        a.sync.stopPairing()
        #expect(!a.sync.showsPairing(on: a.other) && !a.sync.showsPairing(on: nil))
        a.sync.wentAway(a.other)
    }

    @Test("The first merge's rows, the status line and a paired device's row say what they should")
    func words() {
        let summary = SyncSummary(
            addedSources: ["a.example"], replacedSources: [], removedSources: ["gone.example"],
            addedTimelines: ["Shared"], replacedTimelines: ["Old"], removedTimelines: []
        )
        let rows = SyncPreviewCard.rows(summary, language: .english)
        #expect(rows.map(\.name) == ["a.example", "gone.example", "Shared", "Old"])
        #expect(rows.map(\.what) == ["Source added", "Source removed", "Timeline added", "Timeline changed"])
        #expect(rows.first?.spoken == "Source added: a.example")
        #expect(SyncPreviewCard.rows(summary, language: .taiwanese).first?.spoken == "加入來源：a.example")
        #expect(SyncPreviewCard.rows(SyncSummary(), language: .english).isEmpty)

        #expect(ShellSync.changesLine(summary, language: .english) == "2 sources and 2 timelines changed here")
        #expect(ShellSync.changesLine(SyncSummary(addedSources: ["x"]), language: .english) == "one source changed here")
        #expect(ShellSync.outcomeLine(.nothingToMerge, peer: "Phone", language: .english) == "Merged with Phone: already the same")
        #expect(ShellSync.toast(.nothingToMerge, peer: "Phone") == nil && ShellSync.toast(.notMerged(.busy), peer: "Phone") == nil)
        #expect(ShellSync.toast(.notMerged(.declined), peer: "Phone", language: .english)?.contains("Phone") == true)
        #expect(PairedDevicesSection.idle(paired: 0, period: .hour, language: .english) == "No device paired yet")
        #expect(PairedDevicesSection.idle(paired: 1, period: .never, language: .english) == "Merges only when you press Sync now")
        #expect(PairedDevicesSection.idle(paired: 1, period: .hour, language: .english) == "Merges every hour while Fediqo is open on both")
        #expect(PairedDevicesSection.periodLabel(.sixHours, language: .taiwanese) == "每 6 小時")
        let device = PairedDevice(device: "B", name: "Phone", pairedAt: Date())
        #expect(PairedDeviceRow.merged(device, language: .english) == "Paired; not merged yet")
        var merged = device
        merged.firstMerged = true
        merged.lastMerged = Date().addingTimeInterval(-120)
        #expect(PairedDeviceRow.merged(merged, language: .english).hasPrefix("Last merged "))
        #expect(PairedDeviceRow.more(device, language: .english) {}.items.first?.isDanger == true)
        #expect(SyncPairSheet.endedWords(.sameDevice, language: .english).title == "That is this device")
        #expect(SyncPairSheet.runningLine(.merging(device), language: .english).contains("Phone"))
    }

    @Test("Every word said is there in every language, and every refusal is its own sentence")
    func theWords() throws {
        let refusals: [SyncRefusal] = [
            .peerOlder, .peerNewer, .notPaired, .declined, .unreadableHere, .unreadableThere, .clockAhead, .busy,
            .tooLarge, .malformed, .notAllowed, .lost,
        ]
        let keys = [
            "sync.title", "sync.line", "sync.help", "sync.pair.hold", "sync.pair.hold.help", "sync.pair.join",
            "sync.pair.join.help", "sync.now", "sync.now.help", "sync.period", "sync.period.10m", "sync.period.1h",
            "sync.period.6h", "sync.period.never", "sync.status.looking", "sync.status.waiting", "sync.status.notAllowed",
            "sync.status.nobody", "sync.status.none", "sync.status.never", "sync.status.10m", "sync.status.1h", "sync.status.6h", "sync.row.notMerged",
            "sync.row.merged", "sync.forget", "sync.forget.title", "sync.forget.line", "sync.forget.help",
            "sync.hold.title", "sync.hold.line", "sync.hold.help", "sync.join.title", "sync.join.line", "sync.join.help",
            "sync.join.looking", "sync.join.row.brief", "sync.join.go", "sync.pairing.connecting", "sync.pairing.paired",
            "sync.pairing.merging", "sync.pairing.done", "sync.pairing.same.title", "sync.pairing.same.line",
            "sync.ask.title", "sync.ask.line", "sync.ask.help", "sync.ask.here", "sync.ask.there", "sync.ask.nothing",
            "sync.ask.note", "sync.ask.spoken", "sync.ask.no", "sync.ask.yes", "sync.merged", "sync.equal", "sync.changes.none",
            "sync.changes.sources", "sync.changes.timelines", "sync.changes.both", "sync.count.sources", "sync.count.timelines",
        ] + ["source", "timeline"].flatMap { kind in ["added", "replaced", "removed"].map { "sync.ask.\(kind).\($0)" } }
            + refusals.map { "sync.refused." + ShellSync.refusalKey($0) }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: root.appendingPathComponent("Sources/FediqoUI/Resources/\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in keys {
                #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)")
            }
        }
        let lines = Set(refusals.map { ShellSync.outcomeLine(.notMerged($0), peer: "Phone", language: .english) })
        #expect(lines.count == refusals.count)
        for line in lines { #expect(line.contains("Phone") && !line.contains("sync.")) }
        #expect(ShellSync.outcomeLine(.notMerged(.otherVersion(9)), peer: "P") == ShellSync.outcomeLine(.notMerged(.peerNewer), peer: "P"))
        for (lproj, word) in [("en", "paired"), ("zh-TW", "配對")] {
            let plist = try String(contentsOf: root.appendingPathComponent("Apps/Shared/\(lproj).lproj/InfoPlist.strings"), encoding: .utf8)
            #expect(plist.contains(word), "the local network is asked for merging too, in \(lproj)")
        }
    }

    @Test("The group is on the Move tab after Nearby, pairing is one modifier on the pane, and the root adds one modifier and no presenter")
    func whereItLives() throws {
        let shell = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI")
        let prefs = try String(contentsOf: shell.appendingPathComponent("Shell/PreferencesPane.swift"), encoding: .utf8)
        #expect(prefs.contains("NearbySection(session: session)\n        }\n        if let sync { PairedDevicesSection(sync: sync, session: session) }"))
        #expect(prefs.contains(".modifier(SyncPairFlow(sync: sync, session: session))"))
        let root = try String(contentsOf: shell.appendingPathComponent("FediqoRootView.swift"), encoding: .utf8)
        #expect(root.contains(".modifier(SyncAcrossWindows(sync: sync, session: session))"))
        #expect(!root.contains("SyncAskSheet") && !root.contains("syncClock:"))
        for file in ["Shell/ShellSync.swift", "Shell/PairedDevicesSection.swift", "Shell/SyncPreviewSheet.swift"] {
            let text = try String(contentsOf: shell.appendingPathComponent(file), encoding: .utf8)
                .replacingOccurrences(of: "@unknown default:", with: "")
            for reach in ["http", "URLSession", "SecItem", "import Network", "default:"] {
                #expect(!text.contains(reach), "\(file) reaches for \(reach)")
            }
        }
    }
}

/// Pairs and secrets in memory, as the Keychain store keeps them.
final class MemoryPairs: PairStore {
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

/// Preferences kept in memory, so no test reads or writes the reader's.
private final class SyncDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
