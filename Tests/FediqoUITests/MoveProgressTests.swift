#if os(macOS)
import AppKit
#endif
import FediqoCore
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import FediqoUI

/// #253 on both devices, and #247 beside it: what the progress sheet says at every running step
/// of a move nearby and of a take away or read back, when it is up, when Cancel may still stop
/// it, that the device stays awake exactly while a move runs, and that a sheet's presses sit in
/// one row wherever the row fits.
@Suite("A move's progress, on both devices", .serialized)
@MainActor
struct MoveProgressTests {
    typealias Step = ShellNearby.Step

    nonisolated private static let summary = PackageSummary(
        sources: [.init(host: "one.example", kind: .mastodon)], posts: 12, timelines: 1,
        takenAt: Date(timeIntervalSince1970: 1_800_000_000), withPictures: false, bytes: 5_000,
        hasSecrets: true, device: "a laptop", appVersion: "0.7.0", entryCount: 1
    )
    private static let peer = NearbyPeer(id: "p", name: "a tablet", sessionID: "s")
    private static let ask = ShellNearby.Ask(
        offer: NearbyOffer(summary: summary, fileBytes: 5_000), peer: "a laptop", held: true, receiving: true
    )
    private static let half = PackageProgress(done: 2_500, total: 5_000)
    private static let unknown = PackageProgress(done: 0, total: 0)

    /// Every step there is, each once.
    private static let steps: [Step] = [
        .holding(code: "123456"), .browsing([peer]),
        .checkingMark(.init(peer: peer, code: "123456", rides: .withoutPictures, mark: "AB12")),
        .packing(unknown), .packing(half), .connecting(peer: "a tablet"), .asking(ask), .waiting(peer: "a tablet"),
        .moving(half, peer: "a tablet"), .reconnecting(peer: "a tablet"), .settling(nil, peer: "a tablet"),
        .settling(half, peer: "a tablet"), .done(summary, peer: "a tablet"), .refused(.lost),
    ]

    // MARK: - The stage, both sides

    @Test("Every running step has its stage, its fraction where known, and Stop until the read back — the receiver's runs to its end, the sender may Close; nothing else has one")
    func stages() {
        typealias Stage = ShellNearby.Stage
        func stage(_ step: Step, _ side: ShellNearby.Side) -> Stage? { ShellNearby.stage(step, side: side) }
        // The sender.
        #expect(stage(.packing(Self.unknown), .offering) == Stage(line: "nearby.stage.packing", fraction: nil, press: .stop))
        #expect(stage(.packing(Self.half), .offering) == Stage(line: "nearby.stage.packing", fraction: 0.5, press: .stop))
        #expect(stage(.connecting(peer: "t"), .offering) == Stage(line: "nearby.stage.connecting", fraction: nil, press: .stop))
        #expect(stage(.waiting(peer: "t"), .offering) == Stage(line: "nearby.stage.waiting", fraction: nil, press: .stop))
        #expect(stage(.moving(Self.half, peer: "t"), .offering) == Stage(line: "nearby.stage.sending", fraction: 0.5, press: .stop))
        #expect(stage(.reconnecting(peer: "t"), .offering) == Stage(line: "nearby.stage.reconnecting", fraction: nil, press: .stop))
        #expect(stage(.settling(nil, peer: "t"), .offering) == Stage(line: "nearby.stage.provingThere", fraction: nil, press: .close))
        // The receiver: the question is its own; then the bytes, the proof and the read back.
        #expect(stage(.waiting(peer: "l"), .holding) == Stage(line: "nearby.stage.waiting", fraction: nil, press: .stop))
        #expect(stage(.moving(Self.half, peer: "l"), .holding) == Stage(line: "nearby.stage.receiving", fraction: 0.5, press: .stop))
        #expect(stage(.reconnecting(peer: "l"), .holding) == Stage(line: "nearby.stage.reconnecting", fraction: nil, press: .stop))
        #expect(stage(.settling(nil, peer: "l"), .holding) == Stage(line: "nearby.stage.proving", fraction: nil, press: .runsToEnd))
        #expect(stage(.settling(Self.half, peer: "l"), .holding) == Stage(line: "nearby.stage.reading", fraction: 0.5, press: .runsToEnd))
        // A code, the list, the mark, a question and a notice are their own sheets, never progress.
        for step in Self.steps {
            let running = stage(step, .offering) != nil
            #expect(running == Self.isRunning(step), "\(step)")
            #expect(ShellNearby.sheet(for: step) == Self.expectedSheet(step), "\(step)")
        }
        #expect(ShellNearby.sheet(for: nil) == nil && stage(.packing(Self.half), .holding) != nil)
    }

    private static func isRunning(_ step: Step) -> Bool {
        switch step {
        case .packing, .connecting, .waiting, .moving, .reconnecting, .settling: true
        default: false
        }
    }

    private static func expectedSheet(_ step: Step) -> ShellNearby.Sheet? {
        switch step {
        case .holding(let code): .hold(code: code)
        case .browsing: .pick
        default: isRunning(step) ? .progress : nil
        }
    }

    @Test("Each stage and the sheet's words are there in every language")
    func theWords() throws {
        let keys = [
            "nearby.progress.from", "nearby.stage.packing", "nearby.stage.connecting", "nearby.stage.waiting",
            "nearby.stage.sending", "nearby.stage.receiving", "nearby.stage.reconnecting", "nearby.stage.provingThere",
            "nearby.stage.proving", "nearby.stage.reading", "nearby.progress.stop.help", "carry.progress.stop.help",
            "progress.stop", "progress.close", "nearby.progress.close.help", "progress.spoken", "progress.percent", "progress.cannot", "progress.cannot.help",
        ]
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8)
            for key in keys { #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)") }
        }
        #expect(ShellProgress.spoken(stage: "Sending the package", fraction: 0.426, language: .english) == "Sending the package, 42 percent")
        #expect(ShellProgress.spoken(stage: "Joining the other device", fraction: nil, language: .english) == "Joining the other device")
        #expect(ShellProgress.spoken(stage: "傳送", fraction: 1, language: .taiwanese) == "傳送, 百分之 100")
    }

    // MARK: - Take away and read back

    @Test("Take away and read back share the sheet: a fraction as they go, Cancel only while writing, and nothing up otherwise")
    func carrySheet() {
        let taking = ShellCarry.progress(.taking(PackageProgress(done: 1, total: 4)), language: .english)
        #expect(taking?.title == "Taking away" && taking?.stage == "Writing the package" && taking?.fraction == 0.25)
        #expect(taking?.canCancel == true && taking?.code == nil)
        let reading = ShellCarry.progress(.reading(PackageProgress(done: 3, total: 4)), language: .english)
        #expect(reading?.title == "Reading back" && reading?.fraction == 0.75 && reading?.canCancel == false)
        #expect(ShellCarry.progress(.taking(Self.unknown))?.fraction == nil, "a spinner until there is a total")
        for step: ShellCarry.Step in [.weighing, .choosing(PackageWeight(withoutPictures: 1, withPictures: 2, free: 3, holdsStore: false)),
                                      .setting(pictures: true), .moving(URL(fileURLWithPath: "/x")), .opening(URL(fileURLWithPath: "/x")),
                                      .refused(.emptyPassword), .done(.taken)] {
            #expect(ShellCarry.progress(step) == nil && !ShellCarry.showsProgress(step) && !ShellCarry.staysAwake(step), "\(step)")
        }
        #expect(ShellCarry.staysAwake(.taking(Self.half)) && ShellCarry.staysAwake(.reading(Self.half)) && !ShellCarry.staysAwake(nil))
    }

    /// A carrier whose take-away waits for the test before it finishes.
    final class SlowCarrier: StoreCarrier, @unchecked Sendable {
        let gate = NearbyTests.Gate()
        func weigh() async throws -> PackageWeight { PackageWeight(withoutPictures: 1, withPictures: 2, free: 1_000, holdsStore: false) }
        func takeAway(
            to url: URL, key: PackageKey, pictures: Bool, contents: PackageSummary.Contents,
            progress: @escaping @Sendable (PackageProgress) -> Void
        ) async throws {
            progress(PackageProgress(done: 1, total: 2))
            await gate.wait()
        }
        func preview(_ url: URL, key: PackageKey) async throws -> PackageSummary { MoveProgressTests.summary }
        func readBack(_ url: URL, key: PackageKey, replacing: Bool, progress: @escaping @Sendable (PackageProgress) -> Void) async throws {}
    }

    @Test("A take-away's progress sheet taken down by the system stops nothing; a password sheet put away is still out; awake exactly while writing")
    func carryPutAway() async {
        let asked = Mutex<[Bool]>([])
        let carry = ShellCarry(work: SourceWork(), awake: StayAwake { on in asked.withLock { $0.append(on) } })
        let carrier = SlowCarrier()
        defer { carrier.gate.open() }
        carry.beginTakeAway(with: carrier)
        await Self.settle(carry) { if case .choosing = $0 { true } else { false } }
        carry.chose(pictures: false)
        #expect(CarryFlow.sheet(for: carry) == .password(.set(pictures: false)))
        carry.set(password: "open sesame", with: carrier) {}
        #expect(CarryFlow.sheet(for: carry) == .progress && carry.awake.on)
        CarryFlow.sheetPutAway(carry)
        if case .taking = carry.step {} else { Issue.record("the system took the sheet down and the take-away stopped") }
        carry.dismiss()
        #expect(carry.step == nil && !carry.awake.on)
        #expect(asked.withLock { $0 } == [true, false], "told once each way")

        carry.beginTakeAway(with: carrier)
        await Self.settle(carry) { if case .choosing = $0 { true } else { false } }
        carry.chose(pictures: false)
        CarryFlow.sheetPutAway(carry)
        #expect(carry.step == nil, "the password sheet put away is Cancel, as ever")
    }

    /// Waits for the flow's step to be one `done` names, woken by the step changing and never by
    /// a clock: every step lands on the main actor, so nothing lands between the look and the
    /// watch.
    private static func settle(_ carry: ShellCarry, until done: (ShellCarry.Step?) -> Bool) async {
        while !done(carry.step) {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = carry.step } onChange: { resume.resume() }
            }
        }
    }

    // MARK: - Staying awake

    @Test("A move nearby keeps the device awake from its first press — the code, the list, the mark included — until it has ended")
    func awakePredicate() {
        for step in Self.steps {
            let ended: Bool = switch step {
            case .done, .refused: true
            default: false
            }
            #expect(ShellNearby.staysAwake(step) == !ended, "\(step)")
        }
        #expect(!ShellNearby.staysAwake(nil))
        let asked = Mutex<[Bool]>([])
        let awake = StayAwake { on in asked.withLock { $0.append(on) } }
        awake.set(true)
        awake.set(true)
        awake.set(false)
        awake.set(false)
        #expect(asked.withLock { $0 } == [true, false], "the platform is told only of a change")

        // An owner that goes while still awake — a scene closed mid-move — lets the device sleep.
        let gone = Mutex<[Bool]>([])
        var owner: StayAwake? = StayAwake { on in gone.withLock { $0.append(on) } }
        owner?.set(true)
        owner = nil
        #expect(gone.withLock { $0 } == [true, false])
    }

    // MARK: - Presses in one row

    #if os(macOS)
    /// A press's ideal size as the card draws it.
    private static func press(_ label: String) -> CGSize {
        fitting(Button(label) {}.buttonStyle(.bordered).controlSize(.large))
    }

    /// A label at `points`, with a large press's margin round it.
    private static func label(_ label: String, points: CGFloat) -> CGSize {
        fitting(Text(label).font(.system(size: points)).padding(.horizontal, 14).padding(.vertical, 7))
    }

    private static func fitting(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.fixedSize())
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test("Every nearby and carry question sits its presses in one row — on a Mac, on a phone, at every type size")
    func oneRow() {
        let questions = [
            ShellQuestion.nearbyMark("AB12", peer: "a tablet", language: .english),
            ShellQuestion.nearbyAsk(Self.ask, language: .english),
            ShellQuestion.nearbyDone(Self.summary, peer: "a tablet", language: .english),
            ShellQuestion.nearbyRefused(.lost, language: .english),
            ShellQuestion.takeAway(PackageWeight(withoutPictures: 40_000_000, withPictures: 1_300_000_000, free: 0, holdsStore: true), language: .english),
            ShellQuestion.readBack(Self.summary, held: true, language: .english),
            ShellQuestion.carryDone(.taken, language: .english),
        ]
        for question in questions {
            let labels = (question.cancel.map { [$0] } ?? []) + question.choices.map(\.label)
            let sizes = labels.map { Self.press($0) }
            // One row at a Mac card's width...
            #expect(ShellPressRow.inOneRow(sizes, width: 340), "\(labels) at 340")
            // ...and the card, fitted to itself as a Mac sheet is, leaves its presses that row.
            let host = NSHostingView(rootView: ShellConfirmCard(question: question, answer: { _ in }))
            host.layoutSubtreeIfNeeded()
            let row = sizes.map(\.width).reduce(0, +) + ShellSpace.snug * CGFloat(sizes.count - 1)
            #expect(host.fittingSize.width - 2 * ShellSpace.room >= row - 0.5, "\(labels): the card is narrower than its presses")
        }
        // The sheets' own: the list's Cancel and Move, the password's Cancel and Set.
        for labels in [["Cancel", "Move"], ["Cancel", "Set password"]] {
            #expect(ShellPressRow.inOneRow(labels.map { Self.press($0) }, width: 360 - 2 * ShellSpace.room))
        }
        // A phone's width: the take-away's three sit in one row at the usual size — and at the
        // largest too, where each press gives up its share rather than dropping below the others.
        let three = ["Cancel", "Without pictures", "With pictures"]
        let phone: CGFloat = 393 - 2 * ShellSpace.room
        #expect(ShellPressRow.inOneRow(three.map { Self.press($0) }, width: phone))
        // A Mac's bordered press keeps its size whatever the type, so the largest phone press is
        // its label at the largest accessibility size (body at 53 points) with the press's margin.
        let largest = three.map { Self.label($0, points: 53) }
        #expect(ShellPressRow.inOneRow(largest, width: phone), "always one row, even at the largest type")
        let placed = ShellPressRow.arrangement(largest, spacing: ShellSpace.snug, width: phone)
        #expect(Set(placed.origins.map(\.y)).count <= largest.count && placed.size.height == largest.map(\.height).max())
        #expect(zip(placed.origins, placed.widths).allSatisfy { $0.x >= -0.5 && $0.x + $1 <= phone + 0.5 }, "trailing, inside the width")
        #expect(placed.widths.reduce(0, +) < largest.map(\.width).reduce(0, +), "narrowed to fit, not stacked")
    }
    #endif
}
