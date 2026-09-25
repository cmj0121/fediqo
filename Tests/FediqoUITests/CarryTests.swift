import FediqoCore
import FediqoPersistence
import Foundation
import Testing
@testable import FediqoUI

/// #247, #252 on the shell: the steps a take-away and a read back walk, what each question says,
/// that both are written to the run's record under "this device", and that every word is in
/// every language.
@Suite("Taking away and reading back, on the shell")
@MainActor
struct CarryTests {
    nonisolated private static let summary = PackageSummary(
        sources: [.init(host: "one.example", kind: .mastodon), .init(host: "forum.example", kind: .discuz)],
        posts: 12, timelines: 2, takenAt: Date(timeIntervalSince1970: 1_800_000_000), withPictures: true,
        bytes: 3_000, hasSecrets: true, device: "a laptop", appVersion: "0.7.0", entryCount: 5
    )

    /// A carrier that does nothing to any disk and answers as it is told.
    final class FakeCarrier: StoreCarrier, @unchecked Sendable {
        var weight = PackageWeight(withoutPictures: 100, withPictures: 300, free: 1_000, holdsStore: false)
        var summary = CarryTests.summary
        var refuse: (any Error)?
        private(set) var taken: [(url: URL, pictures: Bool)] = []
        private(set) var read: [(url: URL, replacing: Bool)] = []

        func weigh() async throws -> PackageWeight { weight }

        func takeAway(
            to url: URL, key: PackageKey, pictures: Bool, contents: PackageSummary.Contents,
            progress: @escaping @Sendable (PackageProgress) -> Void
        ) async throws {
            if let refuse { throw refuse }
            progress(PackageProgress(done: 1, total: 2))
            progress(PackageProgress(done: 2, total: 2))
            taken.append((url, pictures))
        }

        func preview(_ url: URL, key: PackageKey) async throws -> PackageSummary {
            if let refuse { throw refuse }
            return summary
        }

        func readBack(_ url: URL, key: PackageKey, replacing: Bool, progress: @escaping @Sendable (PackageProgress) -> Void) async throws {
            if let refuse { throw refuse }
            progress(PackageProgress(done: 3_000, total: 3_000))
            read.append((url, replacing))
        }
    }

    /// Waits for the flow's next step, which lands from a task of its own.
    private func settle(_ carry: ShellCarry, until done: (ShellCarry.Step?) -> Bool) async {
        for _ in 0..<200 where !done(carry.step) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Taking away: weigh, choose pictures, set a password, write with progress, then move — and the record says this device")
    func takeAwayWalk() async throws {
        let work = SourceWork()
        let carry = ShellCarry(work: work)
        let carrier = FakeCarrier()
        carry.beginTakeAway(with: carrier)
        await settle(carry) { $0 != .weighing }
        #expect(carry.step == .choosing(carrier.weight))
        #expect(carry.asking == carry.step, "the pictures question is up")
        carry.chose(pictures: true)
        #expect(carry.step == .setting(pictures: true))
        #expect(carry.ask == .set(pictures: true), "the password sheet is up")
        var saved = 0
        carry.set(password: "open sesame", with: carrier) { saved += 1 }
        await settle(carry) { if case .moving = $0 { true } else { false } }
        #expect(saved == 1, "the store is written to disk before it is read")
        #expect(carrier.taken.count == 1 && carrier.taken[0].pictures)
        guard case .moving(let url) = carry.step else { Issue.record("not moving"); return }
        #expect(url.lastPathComponent.hasPrefix("Fediqo ") && url.pathExtension == "fediqo")
        #expect(carry.moving == url)
        carry.moved(.success(url))
        #expect(carry.step == .done(.taken))
        carry.dismiss()
        #expect(carry.step == nil && !carry.isUp)

        let acts = work.record
        #expect(acts.count == 1)
        #expect(acts[0].purpose == .takeAway && acts[0].source == SourceWork.thisDevice)
        #expect(SourceAct.shown(acts[0].source, language: .english) == "This device")
        #expect(SourceAct.shown(acts[0].source, language: .taiwanese) == "這部裝置")
        #expect(SourceAct.shown("one.example") == "one.example")
    }

    @Test("A package that would not fit is refused with the numbers before a password is asked; an empty password is refused too")
    func takeAwayRefusals() async {
        let carrier = FakeCarrier()
        carrier.weight = PackageWeight(withoutPictures: 100, withPictures: 300, free: 200, holdsStore: true)
        let carry = ShellCarry(work: SourceWork())
        carry.beginTakeAway(with: carrier)
        await settle(carry) { $0 != .weighing }
        carry.chose(pictures: true)
        #expect(carry.step == .refused(.noRoom(needed: 300, free: 200)))
        carry.dismiss()

        carry.beginTakeAway(with: carrier)
        await settle(carry) { $0 != .weighing }
        carry.chose(pictures: false)
        #expect(carry.step == .setting(pictures: false))
        carry.set(password: "", with: carrier) {}
        #expect(carry.step == .refused(.emptyPassword))
        carry.dismiss()
        carry.beginTakeAway(with: carrier)
        await settle(carry) { $0 != .weighing }
        carry.chose(pictures: false)
        carry.set(password: "seven77", with: carrier) {}
        #expect(carry.step == .refused(.shortPassword))
        #expect(carrier.taken.isEmpty)
        carry.dismiss()
    }

    @Test("The pictures question answered on the card takes its step, a refusal it asks stays up, and put away it closes")
    func answeredThroughTheCard() async {
        let session = ShellSession(http: FixtureHTTP())
        let carrier = FakeCarrier()
        carrier.weight = PackageWeight(withoutPictures: 100, withPictures: 300, free: 200, holdsStore: false)
        session.carrier = carrier
        let flow = CarryFlow(session: session)
        let carry = session.carry
        func press(_ answer: ShellConfirmAnswer) async {
            await settle(carry) { $0 != .weighing }
            guard let asked = carry.asking else { Issue.record("nothing asked"); return }
            ShellConfirmAnswer.settle(answer, asked: asked, item: flow.asking, onChoice: flow.answer)
            for _ in 0..<4 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        carry.beginTakeAway(with: carrier)
        await press(.choice(ShellQuestion.withoutPictures))
        #expect(carry.step == .setting(pictures: false), "the choice was not taken as put away")
        carry.dismiss()
        carry.beginTakeAway(with: carrier)
        await press(.choice(ShellQuestion.withPictures))
        #expect(carry.step == .refused(.noRoom(needed: 300, free: 200)), "the refusal the answer asked is left up")
        carry.dismiss()
        carry.beginTakeAway(with: carrier)
        await press(.cancel)
        #expect(carry.step == nil, "put away, it closes")
    }

    @Test("Moving cancelled or failed takes the scratch file with it")
    func moveCancelled() async throws {
        let carrier = FakeCarrier()
        let carry = ShellCarry(work: SourceWork())
        carry.beginTakeAway(with: carrier)
        await settle(carry) { $0 != .weighing }
        carry.chose(pictures: false)
        carry.set(password: "password", with: carrier) {}
        await settle(carry) { if case .moving = $0 { true } else { false } }
        guard case .moving(let url) = carry.step else { Issue.record("not moving"); return }
        try Data("x".utf8).write(to: url)
        carry.moveCancelled()
        #expect(carry.step == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Reading back: pick, give the password, see the question, say yes, read with progress, adopt — under this device")
    func readBackWalk() async {
        let work = SourceWork()
        let carry = ShellCarry(work: work)
        let carrier = FakeCarrier()
        carrier.weight = PackageWeight(withoutPictures: 1, withPictures: 1, free: 1, holdsStore: true)
        let file = URL(fileURLWithPath: "/tmp/Fediqo.fediqo")
        carry.picked(file)
        #expect(carry.step == .opening(file) && carry.ask == .open(file))
        carry.open(password: "open sesame", with: carrier)
        await settle(carry) { $0 != .weighing }
        let preview = ShellCarry.Preview(url: file, summary: Self.summary, held: true)
        #expect(carry.step == .previewing(preview))
        #expect(carry.asking == carry.step)
        var adopted = 0
        carry.confirmReadBack(with: carrier) { adopted += 1 }
        await settle(carry) { if case .done = $0 { true } else { false } }
        #expect(carry.step == .done(.readBack(Self.summary)))
        #expect(adopted == 1)
        #expect(carrier.read.count == 1 && carrier.read[0].replacing, "a held store is replaced only on the person's yes")
        #expect(work.record.map(\.purpose) == [.readBack])
        #expect(work.record[0].source == SourceWork.thisDevice)
    }

    @Test("A refusal on opening is its own step, and nothing was read back")
    func readBackRefused() async {
        let carrier = FakeCarrier()
        carrier.refuse = PackageRefusal.wrongPassword
        let carry = ShellCarry(work: SourceWork())
        carry.picked(URL(fileURLWithPath: "/tmp/x.fediqo"))
        carry.open(password: "nope", with: carrier)
        await settle(carry) { $0 != .weighing }
        #expect(carry.step == .refused(.package(.wrongPassword)))
        #expect(carrier.read.isEmpty)
        carry.dismiss()
        carry.picked(URL(fileURLWithPath: "/tmp/x.fediqo"))
        carry.open(password: "", with: carrier)
        #expect(carry.step == .refused(.emptyPassword))
        carry.dismiss()
        #expect(ShellCarry.Trouble(PackageFault.noRoom(needed: 5, free: 1)) == .noRoom(needed: 5, free: 1))
        #expect(ShellCarry.Trouble(PackageRefusal.cutShort) == .package(.cutShort))
        #expect(ShellCarry.Trouble(PackageFault.indexIsNewer) == .indexIsNewer)
        #expect(ShellCarry.Trouble(CocoaError(.fileWriteOutOfSpace)) == .other(CocoaError(.fileWriteOutOfSpace).localizedDescription))
    }

    @Test("A read back under way cannot be dismissed, adopts what it landed, and lets the copies on disk go on")
    func readBackRunsToItsEnd() async throws {
        let carrier = FakeCarrier()
        let carry = ShellCarry(work: SourceWork())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-hold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = DiskCopies(try MediaCache(directory: folder))
        carry.picked(URL(fileURLWithPath: "/tmp/x.fediqo"))
        carry.open(password: "open sesame", with: carrier)
        await settle(carry) { $0 != .weighing }
        var adopted = 0
        carry.confirmReadBack(with: carrier, pictures: disk) { adopted += 1 }
        #expect(carry.isUp)
        carry.dismiss()
        if case .reading = carry.step {} else { Issue.record("dismissed while reading") }
        await settle(carry) { if case .done = $0 { true } else { false } }
        #expect(adopted == 1)
        // The queue runs again after: a write asked now lands.
        disk.store(Data("x".utf8), host: "a.example", url: URL(string: "https://a.example/p.jpg")!)
        await disk.settled()
        #expect(await disk.bytes(hosts: ["a.example"])["a.example"] == 1)
        carry.dismiss()
        #expect(carry.step == nil)
    }

    @Test("Holding the copies on disk keeps every touch until they are released")
    func holdAndRelease() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-hold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try MediaCache(directory: folder)
        let disk = DiskCopies(cache)
        await disk.hold()
        disk.store(Data("x".utf8), host: "a.example", url: URL(string: "https://a.example/p.jpg")!)
        try await Task.sleep(for: .milliseconds(50))
        #expect(cache.bytes(host: "a.example") == 0, "nothing lands while held")
        disk.release()
        await disk.settled()
        #expect(cache.bytes(host: "a.example") == 1)
    }

    @Test("Dismissing while a step runs stops it, and a late answer does not land")
    func dismissCancels() async {
        let carrier = FakeCarrier()
        let carry = ShellCarry(work: SourceWork())
        carry.beginTakeAway(with: carrier)
        carry.dismiss()
        await settle(carry) { _ in false }
        #expect(carry.step == nil)
    }

    // MARK: - What is said

    @Test("The pictures question names both sizes; the read-back question names the count, the sources and the date, and replaces only on a loss")
    func questions() {
        let weight = PackageWeight(withoutPictures: 40 * 1024 * 1024, withPictures: 1_300_000_000, free: 0, holdsStore: false)
        let take = ShellQuestion.takeAway(weight, language: .english)
        #expect(take.line.contains(UsagePane.size(1_300_000_000, language: .english)))
        #expect(take.line.contains(UsagePane.size(40 * 1024 * 1024, language: .english)))
        #expect(take.choices.map(\.id) == [ShellQuestion.withoutPictures, ShellQuestion.withPictures])
        #expect(!take.warns && take.chorded?.id == ShellQuestion.withoutPictures, "the smaller is the one a key answers")

        let fresh = ShellQuestion.readBack(Self.summary, held: false, language: .english)
        #expect(fresh.title == "Read back 12 posts?")
        #expect(fresh.line.contains("one.example, forum.example"))
        #expect(fresh.line.contains("2027"), "the date it was taken away")
        #expect(fresh.help?.contains("a laptop") == true)
        #expect(!fresh.warns && fresh.choices.map(\.role) == [.primary])

        let held = ShellQuestion.readBack(Self.summary, held: true, language: .english)
        #expect(held.warns && held.choices.map(\.role) == [.destructive])
        #expect(held.help?.contains("replaced") == true && held.help?.contains("merged") == true)
        #expect(held.help?.contains("cannot be stopped") == true && fresh.help?.contains("cannot be stopped") == true)
        #expect(held.cancel != nil)

        let one = PackageSummary(
            sources: [], posts: 1, timelines: 0, takenAt: Self.summary.takenAt, withPictures: false, bytes: 0,
            hasSecrets: false, device: "", appVersion: "", entryCount: 0
        )
        #expect(ShellQuestion.readBack(one, held: false, language: .english).title == "Read back one post?")
        #expect(ShellQuestion.readBack(one, held: false, language: .taiwanese).title == "要讀回 1 則貼文嗎？")
    }

    @Test("Each refusal is its own sentence, and neither a refusal nor a done notice has anything to choose")
    func refusalsAreEachTheirOwn() {
        let refusals: [ShellCarry.Trouble] = [
            .package(.notOurs), .package(.newer), .package(.wrongPassword), .package(.altered), .package(.cutShort),
            .noRoom(needed: 2_000_000, free: 1_000), .emptyPassword, .shortPassword, .indexIsNewer,
            .unwound(["secrets", "index"]), .other("the disk said no"),
        ]
        for language in [DummyLanguage.english, .taiwanese] {
            let said = refusals.map { ShellQuestion.carryRefused($0, language: language) }
            #expect(Set(said.map(\.title)).count == refusals.count, "each has its own title in \(language)")
            #expect(Set(said.map(\.line)).count == refusals.count, "each has its own line in \(language)")
            for question in said {
                #expect(question.choices.isEmpty && question.cancel != nil)
                #expect(!question.title.contains("carry.") && !question.line.contains("carry."), "\(question.title) is a key")
                #expect(!question.line.contains("%"))
            }
        }
        let room = ShellQuestion.carryRefused(.noRoom(needed: 2_000_000, free: 1_000), language: .english)
        #expect(room.line.contains(UsagePane.size(2_000_000, language: .english)) && room.line.contains(UsagePane.size(1_000, language: .english)))
        #expect(ShellQuestion.carryRefused(.other("the disk said no"), language: .english).line.contains("the disk said no"))
        #expect(ShellQuestion.carryDone(.taken, language: .english).choices.isEmpty)
        #expect(ShellQuestion.carryDone(.readBack(Self.summary), language: .english).line.hasPrefix("12 posts"))
    }

    @Test("The password sheet goes on only with something typed, and typed twice when it is being set")
    func passwordReady() {
        #expect(!CarryPasswordSheet.ready(password: "", again: "", setting: true))
        #expect(!CarryPasswordSheet.ready(password: "a", again: "", setting: true))
        #expect(!CarryPasswordSheet.ready(password: "a", again: "b", setting: true))
        #expect(!CarryPasswordSheet.ready(password: "a", again: "a", setting: true), "too short to set")
        #expect(!CarryPasswordSheet.ready(password: "password", again: "passwor", setting: true))
        #expect(CarryPasswordSheet.ready(password: "password", again: "password", setting: true))
        #expect(CarryPasswordSheet.ready(password: "a", again: "", setting: false))
        #expect(!CarryPasswordSheet.ready(password: "", again: "", setting: false))
    }

    @Test("The progress line says which way and how far")
    func progressLine() {
        let line = CarrySection.progressLine(PackageProgress(done: 1_000_000, total: 3_000_000), reading: false, language: .english)
        #expect(line == "Taking away · \(UsagePane.size(1_000_000, language: .english)) of \(UsagePane.size(3_000_000, language: .english))")
        #expect(CarrySection.progressLine(PackageProgress(done: 0, total: 0), reading: true, language: .english) == "Reading back")
        #expect(PackageProgress(done: 0, total: 0).fraction == 1)
        #expect(PackageProgress(done: 1, total: 4).fraction == 0.25)
    }

    @Test("Every word said is there in every language, and the two purposes have glyphs")
    func theWords() throws {
        let keys = [
            "work.purpose.takeAway", "work.purpose.readBack", "work.thisDevice",
            "carry.title", "carry.line", "carry.help", "carry.idle", "carry.take", "carry.take.help", "carry.read",
            "carry.read.help", "carry.taking", "carry.reading", "carry.progress",
            "carry.take.ask.title", "carry.take.ask.line", "carry.take.ask.help", "carry.take.with", "carry.take.without",
            "carry.read.ask.title", "carry.read.ask.line", "carry.read.ask.help", "carry.read.ask.help.held",
            "carry.read.go", "carry.read.replace",
            "carry.done.taken.title", "carry.done.taken.line", "carry.done.read.title", "carry.done.read.line",
            "carry.password.set.title", "carry.password.set.line", "carry.password.set.help",
            "carry.password.open.title", "carry.password.open.line", "carry.password.open.help",
            "carry.password.field", "carry.password.again", "carry.password.set.go", "carry.password.open.go",
        ] + ["notOurs", "newer", "wrongPassword", "altered", "cutShort", "noRoom", "empty", "short", "indexNewer", "unwound", "other"]
            .flatMap { ["carry.refused.\($0).title", "carry.refused.\($0).line"] }
            + ["secrets", "index", "pictures", "settings"].map { "carry.step.\($0)" }

        let unwound = ShellQuestion.carryRefused(.unwound(["secrets", "index"]), language: .english)
        #expect(unwound.line.contains("the sign-ins, the posts") && !unwound.line.contains("Nothing changed"))
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in keys {
                #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)")
            }
        }
        #expect(SourceWork.Purpose.takeAway.symbol != SourceWork.Purpose.readBack.symbol)
        #expect(L10n.t("carry.password.set.line", language: .english) == "A lost password cannot be recovered.")
        #expect(L10n.t("carry.password.set.help", language: .english).contains("eight"))
        #expect(ShellQuestion.carryRefused(.shortPassword, language: .english).line.contains("8"))
    }

    @Test("The group is on Preferences' Move tab, its flow is one modifier on the pane, and the root's chain is untouched")
    func wherItLives() throws {
        let shell = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI")
        let prefs = try String(contentsOf: shell.appendingPathComponent("Shell/PreferencesPane.swift"), encoding: .utf8)
        #expect(prefs.contains("CarrySection(session: session)"))
        #expect(prefs.contains(".modifier(CarryFlow(session: session))"))
        let move = try #require(prefs.range(of: "private var move: some View {"))
        #expect(prefs.range(of: "CarrySection(session: session)")!.lowerBound > move.upperBound, "on the Move tab")
        let flow = try #require(prefs.range(of: ".modifier(CarryFlow(session: session))"))
        #expect(flow.upperBound < prefs.range(of: "private var page: some View {")!.lowerBound, "on the pane, not the tab")
        let root = try String(contentsOf: shell.appendingPathComponent("FediqoRootView.swift"), encoding: .utf8)
        #expect(!root.contains("Carry"), "the root's chain grows by nothing")
        let section = try String(contentsOf: shell.appendingPathComponent("Shell/CarrySection.swift"), encoding: .utf8)
        #expect(section.contains("ShellSectionHead(title: \"carry.title\", line: \"carry.line\", help: \"carry.help\")"))
        #expect(section.contains("ShellIconButton(\"square.and.arrow.up\"") && section.contains("ShellIconButton(\"square.and.arrow.down\""))
        #expect(section.contains(".fileMover(") && section.contains(".fileImporter("))
        for reach in ["http", "URLSession", "SecItem"] {
            #expect(!section.contains(reach), "the screen reaches for \(reach)")
        }
    }
}
