import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #344: the timelines a person wrote and what they let through beyond a source are kept in
/// files beside the store. What reads them takes a list that could not be read for unknown —
/// never for empty — and writes nothing over it.
@Suite("The person's own lists are read from beside the store, and one not read is not an empty one")
@MainActor
struct ListsBesideStoreTests {
    private static let forum = "forum.example"

    /// One device's folder and preferences, and the lists in it.
    private final class Place {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "fediqo.test.\(UUID().uuidString)"
        let defaults: UserDefaults
        let lists: ListFiles

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            lists = ListFiles(directory: directory, defaults: defaults, protected: .always)
        }

        deinit {
            close(false)
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }

        /// Makes both files refuse to be read, or lets them be read again.
        func close(_ closed: Bool) {
            for name in names {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: closed ? 0o000 : 0o644], ofItemAtPath: directory.appendingPathComponent(name).path
                )
            }
        }

        var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }
        func onDisk(_ name: String) -> Data? { try? Data(contentsOf: directory.appendingPathComponent(name)) }
        var keys: [String] { defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("fediqo.") }.sorted() }
    }

    // MARK: - Timelines

    @Test("Timelines kept under the key by an earlier build are read, and from then on kept in the file: saved there at the act, and under no key")
    func timelinesMove() throws {
        let place = try Place()
        WrittenTimelineStore(defaults: place.defaults).save([TimelineDefinition(name: "Mine", rules: [])])
        #expect(place.keys == ["fediqo.timelines"] && place.names.isEmpty, "the premise: as an earlier build left it")
        let store = WrittenTimelineStore(defaults: place.defaults, file: place.lists.timelines)
        guard case .timelines(let read) = store.load() else {
            Issue.record("not read")
            return
        }
        #expect(read.map(\.name) == ["Mine"])
        #expect(place.keys.isEmpty && place.names == ["timelines.json"])
        store.save(read + [TimelineDefinition(name: "Second", rules: [])])
        #expect(place.keys.isEmpty)
        guard case .timelines(let again) = WrittenTimelineStore(defaults: place.defaults, file: place.lists.timelines).load() else {
            Issue.record("not read again")
            return
        }
        #expect(again.map(\.name) == ["Mine", "Second"])
    }

    @Test("With nothing kept there are no timelines and no file is made; the first one written makes it")
    func noTimelines() throws {
        let place = try Place()
        let store = WrittenTimelineStore(defaults: place.defaults, file: place.lists.timelines)
        #expect(store.load() == .timelines([]))
        #expect(place.names.isEmpty && place.keys.isEmpty)
        store.save([TimelineDefinition(name: "First", rules: [])])
        #expect(place.names == ["timelines.json"] && place.keys.isEmpty)
    }

    @Test("Timelines that will not be read are unreadable, as a shape this build does not know is — and are not written over")
    func timelinesNotRead() throws {
        let place = try Place()
        let store = WrittenTimelineStore(defaults: place.defaults, file: place.lists.timelines)
        store.save([TimelineDefinition(name: "Mine", rules: [])])
        let kept = try #require(place.onDisk("timelines.json"))
        place.close(true)
        #expect(store.load() == .unreadable)
        store.save([])
        let session = ShellSession(http: FixtureHTTP([:]), timelines: store)
        #expect(session.timelinesUnreadable)
        place.close(false)
        #expect(place.onDisk("timelines.json") == kept)
    }

    // MARK: - What is let through

    private func book(_ place: Place, work: SourceWork = SourceWork()) -> AllowanceBook {
        work.govern(sources: [Self.forum])
        return AllowanceBook(defaults: place.defaults, work: work, file: place.lists.allowances)
    }

    @Test("What an earlier build kept under the key is read, and from then on kept in the file: every change written there at the act, and under no key")
    func allowancesMove() throws {
        let place = try Place()
        let earlier = AllowanceBook(defaults: place.defaults, work: SourceWork())
        earlier.set(.directory, on: false)
        #expect(place.keys == [AllowanceBook.key] && place.names.isEmpty, "the premise: as an earlier build left it")
        let now = book(place)
        #expect(now.off == [.directory] && !now.unread)
        #expect(place.keys.isEmpty && place.names == ["allowances.json"])
        #expect(now.add("cdn.example", for: Self.forum) == nil)
        #expect(place.keys.isEmpty)
        let again = book(place)
        #expect(again.off == [.directory] && again.own == now.own)
    }

    @Test("With no decision ever made no file is made — not at launch, not as sources come and go; the first decision makes it")
    func noDecisions() throws {
        let place = try Place()
        let fresh = book(place)
        fresh.launched(with: [Self.forum], read: true)
        fresh.sourcesChanged([Self.forum])
        fresh.sourcesChanged([])
        #expect(!fresh.unread && place.names.isEmpty && place.keys.isEmpty)
        fresh.set(.directory, on: false)
        #expect(place.names == ["allowances.json"])
    }

    @Test("A list that will not be read is not an empty one: nothing beyond a source is let through, no switch or host changes, nothing is written — and read again, it is what it was")
    func allowancesNotRead() throws {
        let place = try Place()
        let before = book(place)
        before.set(.directory, on: false)
        #expect(before.add("cdn.example", for: Self.forum) == nil)
        let kept = try #require(place.onDisk("allowances.json"))
        place.close(true)
        let work = SourceWork()
        let unread = book(place, work: work)
        #expect(unread.unread)
        #expect(unread.effective.isEmpty && work.allowances.isEmpty, "what was switched off is not let through for want of reading it")
        #expect(Allowance.ID.builtIn.allSatisfy { !unread.isOn($0) })
        unread.set(.directory, on: true)
        unread.set(.signInPage, on: false)
        #expect(unread.add("other.example", for: Self.forum) == .unread)
        #expect(unread.off.isEmpty && unread.own.isEmpty, "nothing is decided about a list that is not known")
        unread.launched(with: [], read: true)
        unread.sourcesChanged([])
        place.close(false)
        #expect(place.onDisk("allowances.json") == kept, "written over")
        unread.reread()
        #expect(!unread.unread && unread.off == [.directory] && unread.own == before.own)
        #expect(work.allowances.contains { $0.source == Self.forum })
    }

    @Test("Why nothing was added to a list that could not be read is said, in every language", arguments: [DummyLanguage.english, .taiwanese])
    func saidWhy(_ language: DummyLanguage) {
        let said = OwnHostAdding.sentence(.unread, language: language)
        #expect(said != "allow.own.refused.unread" && !said.isEmpty)
        #expect(said != OwnHostAdding.sentence(.notAHost, language: language))
    }

    // MARK: - Not written, and said

    /// A folder that takes no file at the class, on a volume that takes the class.
    private static let refusing = Guarded.Device(
        asks: .complete, held: { _ in nil }, canaryTook: { true }, count: {},
        asking: { throw CocoaError(.fileWriteNoPermission) }
    )

    @Test("A timeline the device would not keep is said on the strip, once, and the line stands until timelines are next written")
    func aTimelineNotKept() throws {
        let place = try Place()
        let refused = ListFiles(directory: place.directory, defaults: place.defaults, protected: .always, device: Self.refusing)
        let session = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: place.defaults, file: refused.timelines))
        var announced = 0
        session.said.announce = { _ in announced += 1 }
        for (place, name) in ["One", "Two"].enumerated() {
            var draft = TimelineDraft(new: place + 1)
            draft.name = name
            session.commit(draft)
        }
        #expect(session.written.count == 2 && place.names.isEmpty, "the premise: shown, and not on disk")
        #expect(session.said.lines.map(\.what) == [.unkept(.timelines)] && announced == 1)
        // A save of the store landing is nothing to do with it.
        session.said.written()
        #expect(session.said.lines.map(\.what) == [.unkept(.timelines)])
        // Written, the line comes down.
        session.kept(.timelines, written: true)
        #expect(session.said.lines.isEmpty)
    }

    @Test("A change to what is allowed that the device would not keep is said by every session that follows that list — once each — and shown above the rows; a change that is written, or the list read again, takes it down in all of them")
    func anAllowanceNotKept() throws {
        let place = try Place()
        let refused = ListFiles(directory: place.directory, defaults: place.defaults, protected: .always, device: Self.refusing)
        let work = SourceWork()
        work.govern(sources: [Self.forum])
        var announced = 0
        let sessions = (0..<2).map { _ in
            let session = ShellSession(http: FixtureHTTP([:]))
            session.work = work
            session.said.announce = { _ in announced += 1 }
            return session
        }
        // A session on another list says nothing of this one.
        let elsewhere = ShellSession(http: FixtureHTTP([:]))
        elsewhere.work = SourceWork()
        let book = AllowanceBook(defaults: place.defaults, work: work, file: refused.allowances)
        #expect(AllowanceSection.standing(book) == nil && sessions.allSatisfy { $0.said.lines.isEmpty })
        book.set(.directory, on: false)
        book.set(.signInPage, on: false)
        #expect(book.unwritten && place.names.isEmpty, "the premise: decided, and not on disk")
        for session in sessions { #expect(session.said.lines.map(\.what) == [.unkept(.allowances)]) }
        #expect(announced == 2 && elsewhere.said.lines.isEmpty)
        #expect(AllowanceSection.standing(book, language: .english) == L10n.t("said.unkept.allowances", language: .english))
        // Read again — a read back replaced the lists: nothing of that change is unwritten.
        book.reread()
        #expect(!book.unwritten && AllowanceSection.standing(book) == nil)
        #expect(sessions.allSatisfy { $0.said.lines.isEmpty })
        // And a change that is written takes it down.
        book.set(.directory, on: false)
        #expect(sessions.allSatisfy { $0.said.lines.count == 1 })
        let written = AllowanceBook(defaults: place.defaults, work: work, file: place.lists.allowances)
        written.set(.directory, on: false)
        #expect(!written.unwritten && sessions.allSatisfy { $0.said.lines.isEmpty })
    }

    @Test("What the list says above its rows, state by state: nothing where it is read and written; one sentence each where it was not read, cannot be kept, or was not written — no two the same",
          arguments: [DummyLanguage.english, .taiwanese])
    func standingByState(_ language: DummyLanguage) throws {
        let read = try Place()
        #expect(AllowanceSection.standing(book(read), language: language) == nil)
        let closed = try Place()
        #expect(closed.lists.allowances.write(Data(#"{"off":[],"own":[]}"#.utf8)))
        closed.close(true)
        let none = ProtectedData(
            flag: { true }, canary: { .none }, remade: { .none }, unlockedForSomebody: { false },
            changes: { AsyncStream { $0.finish() } }
        )
        let nowhere = try Place()
        let cannot = AllowanceBook(
            defaults: nowhere.defaults, work: SourceWork(),
            file: ListFiles(directory: nowhere.directory, defaults: nowhere.defaults, protected: none).allowances
        )
        let refusedPlace = try Place()
        let unwritten = AllowanceBook(
            defaults: refusedPlace.defaults, work: SourceWork(),
            file: ListFiles(directory: refusedPlace.directory, defaults: refusedPlace.defaults, protected: .always, device: Self.refusing).allowances
        )
        unwritten.set(.directory, on: false)
        let said = [book(closed), cannot, unwritten].compactMap { AllowanceSection.standing($0, language: language) }
        closed.close(false)
        #expect(said.count == 3 && Set(said).count == 3)
        #expect(said == ["allow.unknown.notRead", "allow.unknown.cannotKeep", "said.unkept.allowances"].map { L10n.t($0, language: language) })
        #expect(said.allSatisfy { !$0.contains("allow.") && !$0.contains("said.") })
    }

    @Test("Each list not kept has a sentence of its own, in every language", arguments: [DummyLanguage.english, .taiwanese])
    func notKeptIsSaid(_ language: DummyLanguage) {
        let said = Said.Unkept.allCases.map { Said(.unkept($0), .unreachable, host: "").words(language: language) }
        #expect(Set(said).count == Said.Unkept.allCases.count)
        for (list, words) in zip(Said.Unkept.allCases, said) {
            #expect(!words.contains("said.unkept") && !words.isEmpty, "\(list)")
        }
        #expect(Said(.unkept(.timelines), .unreachable, host: "").id != Said(.unkept(.allowances), .unreachable, host: "").id)
    }

    // MARK: - Not known, and said

    @Test("A list not known says so above its rows, and why: one that could not be read says to open Fediqo again; one the device will not keep at all does not, and says that instead",
          arguments: [DummyLanguage.english, .taiwanese])
    func notKnownIsSaid(_ language: DummyLanguage) throws {
        let place = try Place()
        #expect(place.lists.allowances.write(Data(#"{"off":["directory"],"own":[]}"#.utf8)))
        place.close(true)
        let notRead = book(place)
        #expect(notRead.unknown == .notRead)
        let again = language == .english ? "Open Fediqo again" : "再打開 Fediqo 一次"
        let nothing = language == .english ? "Nothing beyond your sources is reached" : "不會連到你的來源之外"
        let first = try #require(AllowanceSection.standing(notRead, language: language))
        #expect(first.contains(again) && first.contains(nothing) && !first.contains("allow."))
        place.close(false)
        // No canary, and nothing kept: nothing says the device is unlocked, and no first list
        // is made.
        let other = try Place()
        let none = ProtectedData(
            flag: { true }, canary: { .none }, remade: { .none }, unlockedForSomebody: { false },
            changes: { AsyncStream { $0.finish() } }
        )
        let work = SourceWork()
        let cannot = AllowanceBook(
            defaults: other.defaults, work: work,
            file: ListFiles(directory: other.directory, defaults: other.defaults, protected: none).allowances
        )
        #expect(cannot.unknown == .cannotKeep && cannot.effective.isEmpty)
        let second = try #require(AllowanceSection.standing(cannot, language: language))
        #expect(!second.contains(again) && second.contains(nothing) && second != first && !second.contains("allow."))
        cannot.set(.directory, on: false)
        #expect(other.names.isEmpty && !cannot.unwritten)
    }

    @Test("Something under the allowances key that no build wrote is an empty list, as it always was, and the first change replaces it; under the timelines key it is unreadable, as it always was")
    func anotherTypeUnderTheKey() throws {
        let place = try Place()
        place.defaults.set("not a list", forKey: AllowanceBook.key)
        place.defaults.set("not a list", forKey: "fediqo.timelines")
        let read = book(place)
        #expect(read.unknown == nil && read.off.isEmpty && read.own.isEmpty)
        #expect(place.names.isEmpty && place.defaults.string(forKey: AllowanceBook.key) == "not a list")
        read.set(.directory, on: false)
        #expect(place.names == ["allowances.json"] && place.defaults.object(forKey: AllowanceBook.key) == nil)
        #expect(book(place).off == [.directory])
        #expect(WrittenTimelineStore(defaults: place.defaults, file: place.lists.timelines).load() == .unreadable)
        #expect(place.defaults.string(forKey: "fediqo.timelines") == "not a list")
    }

    // MARK: - The wiring

    @Test("The app's own book is told its file before it is first touched, and the root and the app hand the lists on")
    func wired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/FediqoUI/FediqoRootView.swift"), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent("Apps/Shared/FediqoApp.swift"), encoding: .utf8)
        let told = try #require(view.range(of: "if let lists { AllowanceBook.kept = lists.allowances }"))
        let touched = try #require(view.range(of: "let book = AllowanceBook.shared"))
        #expect(told.lowerBound < touched.lowerBound)
        #expect(view.components(separatedBy: "AllowanceBook.shared").count - 1 == 1, "touched nowhere else in the root")
        #expect(view.contains("WrittenTimelineStore(defaults: .standard, file: lists?.timelines)"))
        #expect(app.contains("lists = ListFiles(directory: StoreFile.applicationSupportDirectory, defaults: .standard, protected: protected)"))
        #expect(app.contains("            lists: lists\n") && app.contains("            lists: launch.lists,\n"))
        // Nothing in the app reaches the book itself, which would be before it is told.
        #expect(!app.contains("AllowanceBook"))
    }
}
