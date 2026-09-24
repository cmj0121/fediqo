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

/// The room check under what can go wrong around it (#249, review): a rebuild that fails, a
/// save that does not land, a launch with both limits, a check asked for while one runs, and
/// the store's own moves.
@MainActor
@Suite("The room check, judged by what the rows weigh", .serialized)
struct RoomCheckTests {
    private let origin = LimitRoom.origin
    private let alpha = LimitRoom.alpha
    private let beta = LimitRoom.beta

    @Test("A rebuild that throws costs no extra post: the rounds are judged by what the rows weigh, and the next check rebuilds")
    func failedCompactDropsNothingExtra() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        room.compaction.failing = 1
        let limit = room.index / 2
        room.session.roomBytes = limit

        let act = try #require(await room.session.keepWithinRoom(at: origin))

        #expect(room.compaction.ran == 1)
        #expect(room.compaction.landed == 0)
        #expect(room.file.bytesHeld() <= limit, "the rows still weigh more than the room")
        #expect(room.index > limit, "the file kept its size, as a failed rebuild leaves it")
        let held = room.session.holdings.posts
        #expect(held == 60 - act.posts)
        #expect(room.file.bytesHeld() > limit - 8 * 4_100, "more went than the room asked for")

        #expect(await room.session.keepWithinRoom(at: origin) == nil, "posts went for a file size the rows did not have")
        #expect(room.session.holdings.posts == held)
        #expect(room.compaction.landed == 1, "the next check did not rebuild")
        #expect(room.index <= limit)
        #expect(room.session.storeBytes == room.index)
    }

    @Test("A save that does not land ends the check after one round rather than being tried again")
    func saveThatDoesNotLandStops() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        room.session.persist = {}
        room.session.roomBytes = room.index / 2

        let act = try #require(await room.session.keepWithinRoom(at: origin))

        #expect(act.posts == RoomPolicy.postsToLetGo(over: room.index / 2, bytes: room.index, posts: 60), "one round and no more")
        #expect(try room.file.load().notes.count == 60, "nothing landed on disk")
        #expect(room.session.holdings.posts == 60 - act.posts)
    }

    @Test("At a launch with both limits set, each acts once, in order, and the room is not cut past")
    func launchSequence() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = try await LimitRoom(at: dir, notes: LimitRoom.held() + [LimitRoom.note("old", daysAgo: 400, from: beta)])
        await earlier.session.record(LimitAct(limit: .room, at: origin.addingTimeInterval(-86_400), posts: 1, sources: ["alpha.test"]))
        let limit = earlier.index / 2

        // The root task's order: the account, the months, what is held, then the room.
        let opened = StoreFile.open(at: dir)
        let room = try await LimitRoom(at: dir, notes: opened.notes)
        await room.session.loadLimitAccount()
        #expect(await room.session.keep(months: 3, from: origin) == 1)
        await room.session.reloadFromStore()
        room.session.roomBytes = limit
        let act = try #require(await room.session.keepWithinRoom(at: origin))

        #expect(room.session.limitAccount.map(\.limit) == [.room, .months, .room], "the earlier run's line was written over")
        #expect(act.posts > 0)
        #expect(room.index <= limit)
        #expect(room.file.bytesHeld() > limit - 4 * 4_100, "cut past the room by more than the last rounds could")
        #expect(try LimitAccountFile(directory: dir).read().count == 3)
    }

    @Test("A check asked for while one runs is run once it ends")
    func askedAgainRuns() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        room.session.roomBytes = 100_000_000
        room.session.roomChecking = true
        #expect(await room.session.keepWithinRoom(at: origin) == nil)
        #expect(room.session.roomAskedAgain)
        room.session.roomChecking = false
        #expect(await room.session.keepWithinRoom(at: origin) == nil)
        #expect(!room.session.roomAskedAgain)
        #expect(room.session.roomCheck != nil, "the check that ended did not ask again")
        room.session.roomCheck?.cancel()
        room.session.roomCheck = nil
    }

    @Test("The session's own moves hold the store still, nested, and ask for the check as they end")
    func ownMovesHoldStill() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held())
        room.session.roomBytes = 1_000
        let inside: LimitAct? = await room.session.holdingStill {
            await room.session.holdingStill {
                await room.session.keepWithinRoom(at: origin)
            }
        }
        #expect(inside == nil)
        #expect(room.session.holdings.posts == 60)
        #expect(room.session.holding == 0)
        #expect(room.session.roomCheck != nil, "the move ending did not ask for the check")
        room.session.roomCheck?.cancel()
        room.session.roomCheck = nil
        // Through a real move: a span let go holds too, and what went is not the room's.
        room.session.roomBytes = 100_000_000
        #expect(await room.session.letGo(span: origin.addingTimeInterval(-86_400 * 3)..<origin, host: nil) == 3)
        #expect(room.session.limitAccount.isEmpty)
        room.session.roomCheck?.cancel()
        room.session.roomCheck = nil
    }
}

/// A take-away or a read back (#247) holds the room limit still for as long as it runs, and no
/// longer — `ShellSession.holdsStill`'s contract, kept by the carry flow.
@MainActor
@Suite("The carry flow holds the room limit still", .serialized)
struct CarryHoldsStillTests {
    private func settle(_ carry: ShellCarry, until done: (ShellCarry.Step?) -> Bool) async {
        for _ in 0..<200 where !done(carry.step) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A take-away holds the store still from before the save to after the write, and releases when done or refused")
    func takeAwayHolds() async throws {
        let session = ShellSession(http: FixtureHTTP())
        let carry = session.carry
        let carrier = CarryTests.FakeCarrier()
        carry.beginTakeAway(with: carrier)
        await settle(carry) { $0 != .weighing }
        carry.chose(pictures: false)
        #expect(!session.holdsStill)
        let seen = Seen()
        carry.set(password: "open sesame", with: carrier) { seen.heldAtSave = session.holdsStill }
        #expect(session.holdsStill, "not held before the first byte moved")
        await settle(carry) { if case .moving = $0 { true } else { false } }
        #expect(seen.heldAtSave == true, "the save before the write ran unheld")
        #expect(!session.holdsStill, "still held after the package was written")
        carry.dismiss()
        #expect(!session.holdsStill)

        carrier.refuse = PackageRefusal.wrongPassword
        carry.beginTakeAway(with: carrier)
        await settle(carry) { $0 != .weighing }
        carry.chose(pictures: false)
        carry.set(password: "open sesame", with: carrier) {}
        await settle(carry) { if case .refused = $0 { true } else { false } }
        #expect(!session.holdsStill, "a refusal did not release the hold")
        carry.dismiss()
    }

    @Test("Dismissing a take-away midway releases the hold")
    func dismissReleases() async throws {
        let session = ShellSession(http: FixtureHTTP())
        let carry = session.carry
        let carrier = CarryTests.FakeCarrier()
        carry.beginTakeAway(with: carrier)
        await settle(carry) { $0 != .weighing }
        carry.chose(pictures: false)
        carry.set(password: "open sesame", with: carrier) { try? await Task.sleep(for: .seconds(5)) }
        #expect(session.holdsStill)
        carry.dismiss()
        // The running task releases as it ends, which its cancelled sleep makes now.
        for _ in 0..<200 where session.holdsStill {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.holdsStill)
        // And with nothing running, dismiss itself releases.
        session.holdsStill = true
        carry.dismiss()
        #expect(!session.holdsStill)
    }

    private final class Seen: @unchecked Sendable {
        var heldAtSave: Bool?
    }
}
