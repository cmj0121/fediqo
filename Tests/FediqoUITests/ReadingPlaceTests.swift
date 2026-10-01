import Foundation
@testable import FediqoCore
import Testing
@testable import FediqoUI

/// #273: where the reader stopped reading is kept on this device, and comes back as it was kept.
///
/// Every test but one keeps its place in memory, so none reads or writes the reader's and none
/// leaves a plist behind; `onASuite` is the one that goes through a defaults suite of its own.
@Suite("Where reading stopped is kept")
struct ReadingPlaceTests {
    private static let mine = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    /// Defaults of its own that count what is written to them.
    private final class Shelf {
        let defaults = CountingDefaults()

        /// A store made again each time it is asked for, the way a relaunch makes one: nothing
        /// passes from one to the next but what the defaults hold.
        var store: ReadingPlaceStore { ReadingPlaceStore(defaults: defaults) }
    }

    // MARK: Acceptance: on a defaults suite, saved comes back and the unreadable is left alone

    @Test("On a defaults suite: a place comes back equal, and an unreadable or newer one is no place and is left as it is")
    func onASuite() throws {
        let suite = "fediqo.test.place.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ReadingPlaceStore(defaults: defaults).key
        let place = ReadingPlace(timeline: .written(Self.mine), lamp: "m1", top: "a2", thread: "m1")

        #expect(ReadingPlaceStore(defaults: defaults).load() == nil)
        ReadingPlaceStore(defaults: defaults).save(place)
        #expect(ReadingPlaceStore(defaults: defaults).load() == place)

        let unreadable = Data(#"{"version":1,"timeline":"all","lamp":3}"#.utf8)
        let newer = Data(#"{"version":2,"timeline":"all","lamp":"a3"}"#.utf8)
        for kept in [unreadable, newer] {
            defaults.set(kept, forKey: key)
            #expect(ReadingPlaceStore(defaults: defaults).load() == nil)
            ReadingPlaceStore(defaults: defaults).save(place)
            #expect(defaults.data(forKey: key) == kept)
        }
    }

    // MARK: Acceptance: a place saved then loaded is equal

    @Test("A place saved comes back equal, whatever it names",
          arguments: [
            ReadingPlace(timeline: .all),
            ReadingPlace(timeline: .trends, lamp: "t2"),
            ReadingPlace(timeline: .all, top: "a7"),
            ReadingPlace(timeline: .written(mine), lamp: "m1", top: "a2"),
            ReadingPlace(timeline: .written(mine), lamp: "m1", top: "a2", thread: "m1"),
          ])
    func savedComesBack(place: ReadingPlace) {
        let shelf = Shelf()
        shelf.store.save(place)
        #expect(shelf.store.load() == place)
    }

    @Test("A later place takes the earlier one's, and a part it does not name is not left behind")
    func laterReplaces() {
        let shelf = Shelf()
        shelf.store.save(ReadingPlace(timeline: .trends, lamp: "t2", top: "t1", thread: "t2"))
        shelf.store.save(ReadingPlace(timeline: .all, top: "a7"))
        #expect(shelf.store.load() == ReadingPlace(timeline: .all, top: "a7"))
    }

    @Test("Nothing kept yet is no place, and loading keeps nothing")
    func nothingKept() {
        let shelf = Shelf()
        #expect(shelf.store.load() == nil)
        #expect(shelf.defaults.object(forKey: shelf.store.key) == nil)
        #expect(shelf.defaults.writes == 0)
    }

    @Test("The place is kept under fediqo.place as version 1, a part it does not name left out")
    func shape() throws {
        let shelf = Shelf()
        #expect(shelf.store.key == "fediqo.place")
        shelf.store.save(ReadingPlace(timeline: .written(Self.mine), lamp: "m1", top: "a2", thread: "m1"))
        let full = try #require(shelf.defaults.data(forKey: "fediqo.place"))
        let top = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        #expect(Set(top.keys) == ["version", "timeline", "lamp", "top", "thread"])
        #expect(top["version"] as? Int == 1)
        #expect(top["timeline"] as? String == "written:11111111-1111-1111-1111-111111111111")
        #expect(top["lamp"] as? String == "m1")
        #expect(top["top"] as? String == "a2")
        #expect(top["thread"] as? String == "m1")

        shelf.store.save(ReadingPlace(timeline: .all))
        let bare = try #require(shelf.defaults.data(forKey: "fediqo.place"))
        let least = try #require(try JSONSerialization.jsonObject(with: bare) as? [String: Any])
        #expect(Set(least.keys) == ["version", "timeline"])
        #expect(least["timeline"] as? String == "all")
    }

    @Test("A timeline this build does not know is read as All, with the rest of the place kept")
    func unknownTimelineIsAll() {
        let shelf = Shelf()
        let kept = Data(#"{"version":1,"timeline":"board:42","lamp":"a3","top":"a1"}"#.utf8)
        shelf.defaults.set(kept, forKey: shelf.store.key)
        #expect(shelf.store.load() == ReadingPlace(timeline: .all, lamp: "a3", top: "a1"))
    }

    // MARK: Acceptance: fail closed

    @Test("A version, field or shape this build does not know is no place, and is left as it is",
          arguments: [
            #"{"version":2,"timeline":"all","lamp":"a3"}"#,
            #"{"version":0,"timeline":"all","lamp":"a3"}"#,
            #"{"timeline":"all","lamp":"a3"}"#,
            #"{"version":"1","timeline":"all"}"#,
            #"{"version":1,"timeline":"all","tab":"timeline"}"#,
            #"{"version":1,"lamp":"a3"}"#,
            #"{"version":1,"timeline":7}"#,
            #"{"version":1,"timeline":"all","lamp":3}"#,
            #"{"version":1,"timeline":"all","top":["a1"]}"#,
            #"{"version":1,"timeline":"all","thread":{"id":"a3"}}"#,
            #"[{"version":1,"timeline":"all"}]"#,
            #"not json"#,
            "",
          ])
    func unknownFailsClosed(json: String) {
        let shelf = Shelf()
        let kept = Data(json.utf8)
        shelf.defaults.set(kept, forKey: shelf.store.key)
        let before = shelf.defaults.writes

        #expect(shelf.store.load() == nil)
        shelf.store.save(ReadingPlace(timeline: .trends, lamp: "would overwrite"))
        #expect(shelf.defaults.data(forKey: shelf.store.key) == kept)
        #expect(shelf.defaults.writes == before)
        #expect(shelf.store.load() == nil)
    }

    @Test("A value of another type under the key is no place, and is never written over")
    func otherTypeIsUnreadable() {
        let shelf = Shelf()
        shelf.defaults.set("not data", forKey: shelf.store.key)
        #expect(shelf.store.load() == nil)
        shelf.store.save(ReadingPlace(timeline: .trends, lamp: "would overwrite"))
        #expect(shelf.defaults.object(forKey: shelf.store.key) as? String == "not data")
    }

    // MARK: Written only when it differs

    @Test("The place already kept is not written again; one that differs in any part is")
    func equalIsNotWrittenAgain() {
        let shelf = Shelf()
        let place = ReadingPlace(timeline: .written(Self.mine), lamp: "m1", top: "a2", thread: "m1")
        shelf.store.save(place)
        #expect(shelf.defaults.writes == 1)
        shelf.store.save(place)
        // A store made after a relaunch knows what is kept as well as the one that wrote it.
        shelf.store.save(place)
        #expect(shelf.defaults.writes == 1)

        var writes = 1
        var moved = place
        moved.timeline = .all
        shelf.store.save(moved)
        writes += 1
        #expect(shelf.defaults.writes == writes)
        moved.lamp = "a3"
        shelf.store.save(moved)
        writes += 1
        #expect(shelf.defaults.writes == writes)
        moved.top = nil
        shelf.store.save(moved)
        writes += 1
        #expect(shelf.defaults.writes == writes)
        moved.thread = nil
        shelf.store.save(moved)
        writes += 1
        #expect(shelf.defaults.writes == writes)
        #expect(shelf.store.load() == ReadingPlace(timeline: .all, lamp: "a3"))
    }
}

/// Defaults whose values live in this object only, and which count each value set on them:
/// nothing reaches `cfprefsd` or the disk.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private(set) var writes = 0

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) {
        writes += 1
        values[key] = value
    }
    override func removeObject(forKey key: String) { values[key] = nil }
}
