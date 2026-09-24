import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence
@testable import FediqoUI

/// The store kept within the room the person gives it (#249), judged by the figures Usage
/// shows: the picture copies first, then the oldest posts, and whichever of the two limits is
/// reached acts and names itself. Through the session, against `LimitRoom`'s real index.
@MainActor
@Suite("The store kept within its room", .serialized)
struct RoomLimitTests {
    private let origin = LimitRoom.origin
    private let alpha = LimitRoom.alpha
    private let beta = LimitRoom.beta

    @Test("Past the room, picture copies go first, oldest first, and no post")
    func copiesGoFirst() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        try room.copies(3, of: 50_000, host: alpha.host)
        try room.copies(1, of: 50_000, host: beta.host, from: 10)
        let index = room.index
        room.session.roomBytes = index + 120_000

        let act = try #require(await room.session.keepWithinRoom(at: origin))

        #expect(act.limit == .room)
        #expect(act.posts == 0)
        #expect(act.copies == 2, "80 KB over: the two oldest copies")
        #expect(act.sources == ["alpha.test"], "both oldest copies were alpha's")
        #expect(room.cache.data(host: alpha.host, url: LimitRoom.address(0)) == nil)
        #expect(room.cache.data(host: alpha.host, url: LimitRoom.address(2)) != nil)
        #expect(room.cache.data(host: beta.host, url: LimitRoom.address(10)) != nil)
        #expect(room.session.holdings.posts == 60, "a post went before the copies were spent")
        #expect(room.index == index)
        #expect(room.session.storeBytes == index)
        #expect(room.session.limitAccount == [act])
    }

    @Test("Still over with every copy gone, the oldest posts go, oldest first across sources, aside included, until it fits")
    func oldestPostsGo() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        try room.copies(1, of: 10_000, host: alpha.host)
        let index = room.index
        #expect(index > 200_000)
        let limit = index / 2
        room.session.roomBytes = limit

        let act = try #require(await room.session.keepWithinRoom(at: origin))

        #expect(act.copies == 1)
        #expect(act.posts > 0)
        #expect(act.sources == ["alpha.test", "beta.test"])
        let left = room.session.notes + room.session.aside
        #expect(left.count == 60 - act.posts)
        #expect(room.session.holdings.posts == left.count, "Usage's count disagrees with what went")
        #expect(room.session.holdings.aside == 0, "the oldest row, held aside, should have gone first")
        let oldestLeft = try #require(left.map(\.postedAt).min())
        #expect(oldestLeft > origin.addingTimeInterval(-Double(act.posts) * 86_400), "a newer post went before an older one")
        #expect(room.index <= limit, "the index still weighs more than the room")
        #expect(room.session.storeBytes == room.index, "Usage's disk figure is not what was measured")
        #expect(try room.file.load().notes.count == left.count, "the drop was not written through the save path")
        #expect(await room.session.keepWithinRoom(at: origin) == nil, "under the room, nothing more goes")
    }

    @Test("A limit never set lets nothing go, and the check is not even asked for")
    func noLimitNothing() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        try room.copies(2, of: 50_000, host: alpha.host)
        let index = room.index
        #expect(await room.session.keepWithinRoom(at: origin) == nil)
        #expect(await room.session.keep(months: nil, from: origin) == 0)
        room.session.roomMayBeReached()
        #expect(room.session.roomCheck == nil)
        #expect(room.session.holdings.posts == 60)
        #expect(room.index == index)
        #expect(room.cache.count() == 2)
        #expect(room.session.limitAccount.isEmpty)
    }

    @Test("Nothing goes while the store is held still, and the room is judged once it is not")
    func heldStill() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        room.session.roomBytes = 1_000
        room.session.holdsStill = true
        #expect(await room.session.keepWithinRoom(at: origin) == nil)
        #expect(room.session.holdings.posts == 60)
        room.session.holdsStill = false
        #expect(room.session.roomCheck != nil, "clearing the hold did not ask for the check")
        room.session.roomCheck?.cancel()
        room.session.roomCheck = nil
    }

    @Test("Both set, whichever is reached acts and its line names it; the months limit writes a line too")
    func whicheverIsReachedActs() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held() + [LimitRoom.note("old", daysAgo: 400, from: beta)])
        room.session.roomBytes = 100_000_000

        #expect(await room.session.keep(months: 3, from: origin) == 1)
        #expect(await room.session.keepWithinRoom(at: origin) == nil, "the room was not reached")
        let months = try #require(room.session.limitAccount.first)
        #expect(months.limit == .months)
        #expect(months.posts == 1)
        #expect(months.sources == ["beta.test"])
        #expect(months.at == origin)

        room.session.roomBytes = room.index / 2
        let later = origin.addingTimeInterval(60)
        let act = try #require(await room.session.keepWithinRoom(at: later))
        #expect(act.limit == .room)
        #expect(room.session.limitAccount.map(\.limit) == [.room, .months], "newest first")
        #expect(room.session.limitAccount.first?.at == later)
    }

    @Test("What the Keep tab says of the room, in every language", arguments: [DummyLanguage.english, .taiwanese])
    func words(language: DummyLanguage) throws {
        let keys = [
            "prefs.keep.line", "prefs.keep.help", "prefs.room", "prefs.room.none", "prefs.room.figure",
            "prefs.room.within", "prefs.room.tighten.title", "prefs.room.tighten.line", "prefs.room.tighten.detail",
        ]
        for key in keys {
            #expect(L10n.t(key, language: language) != key, "\(key) is missing")
        }
        let line = try #require(UsagePane.roomLine(index: 1_000, copies: 2_000, room: 100_000_000, language: language))
        #expect(line.contains(UsagePane.size(3_000, language: language)))
        #expect(line.contains(UsagePane.size(100_000_000, language: language)))
        #expect(UsagePane.roomLine(index: nil, copies: 2_000, room: nil, language: language) == nil)
        #expect(UsagePane.roomLine(index: 1_000, copies: nil, room: nil, language: language) == nil)
        let bare = try #require(UsagePane.roomLine(index: 1_000, copies: 2_000, room: nil, language: language))
        #expect(!bare.contains(UsagePane.size(3_000, language: language)), "no room, no 'of'")
    }

    @Test("A smaller room asks first, as a loss with a way out")
    func tightenAsks() {
        let tighten = ShellQuestion.tighten(room: 100_000_000, language: .english)
        #expect(tighten.title == "Give the store 100 MB of room?")
        #expect(tighten.choices.map(\.role) == [.destructive])
        #expect(tighten.cancel != nil)
    }
}
