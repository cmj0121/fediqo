import FediqoCore
import Foundation
import SwiftUI

/// The room limit (#249), and the account both limits keep (#251).
///
/// **Two limits side by side, and whichever is reached first acts.** The months limit is the
/// store's own window (`keep(months:)`): a post older than it is refused at the door and let go
/// where it is already in. The room limit is judged after the fact, by what the index and the
/// picture copies weigh on disk — **the same two figures Usage shows**, `readStoreBytes()` and
/// `ShellPictures.diskBytes`, so what the limit is held to is what the person sees. Past it,
/// the picture copies go first, oldest written first, because they come back when a picture is
/// read again; only where every copy gone still leaves the store over do posts go, oldest posted
/// first across every source, rows held aside included (`ItemStore.letGoOldest`).
///
/// **When the check runs.** At launch and when the room changes (`KeepingWithinRoom`), and after
/// each landing — asked for by `followStore`, waited out for `roomDebounce`, and one check for
/// however many landings asked meanwhile. What it costs the hot path is a flag and a sleeping
/// task; the measure is four file sizes and a walk of the copies, and only when the wait is out.
/// Never while `holdsStill` — an export or a move of the store is running — and never two at once.
///
/// **What a limit lets go is written down**, once per act, through `record`: never a post, only
/// the limit, the moment, the counts and the sources.
extension ShellSession {
    /// How long after a landing the room is measured, so a burst of pages is one check.
    static let roomDebounce: Duration = .seconds(2)

    /// How many times posts are let go and measured again in one check before it stops: the
    /// count is judged by the average post, and a store of a few very large posts can fall
    /// short a round or two. A check that stops short is asked again by the next landing.
    static let roomRounds = 8

    /// A landing, or the room limit set: the check runs once `roomDebounce` is out, and a second
    /// ask meanwhile joins it. Nothing where there is no room limit.
    func roomMayBeReached() {
        guard roomBytes != nil, roomCheck == nil else { return }
        roomCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.roomDebounce)
            guard let self, !Task.isCancelled else { return }
            self.roomCheck = nil
            await self.keepWithinRoom()
        }
    }

    /// Holds the store within the room now (#249): measures, lets the picture copies go first,
    /// then the oldest posts, writing and measuring again until it fits. Returns what the limit
    /// let go, or nil where nothing went — no room set, nothing over, a move in progress, or
    /// no index this run to be measured.
    @discardableResult
    func keepWithinRoom(at now: Date = Date()) async -> LimitAct? {
        guard let room = roomBytes, !holdsStill, !roomChecking, let measureStore else { return nil }
        roomChecking = true
        defer { roomChecking = false }
        let hosts = sources.map(\.host)
        var indexBytes = await measureStore()
        var copyBytes = await pictures.diskBytes(hosts: hosts).values.reduce(0, +)
        var over = RoomPolicy.over(total: indexBytes + copyBytes, room: room)
        storeBytes = indexBytes
        guard over > 0 else { return nil }
        var copies = 0
        var posts = 0
        var from: Set<String> = []
        if copyBytes > 0, let trimmed = await pictures.trimDisk(toBytes: max(0, copyBytes - over), hosts: hosts) {
            copies = trimmed.dropped
            copyBytes = trimmed.kept
            from.formUnion(trimmed.sources)
            over = RoomPolicy.over(total: indexBytes + copyBytes, room: room)
        }
        var rounds = 0
        while over > 0, rounds < Self.roomRounds {
            rounds += 1
            let count = RoomPolicy.postsToLetGo(over: over, bytes: indexBytes, posts: holdings.posts)
            let went = await store.letGoOldest(count: count)
            guard went.posts > 0 else { break }
            posts += went.posts
            from.formUnion(went.sources)
            await reloadFromStore()
            await persist?()
            await compactStore?()
            indexBytes = await measureStore()
            storeBytes = indexBytes
            over = RoomPolicy.over(total: indexBytes + copyBytes, room: room)
        }
        let act = LimitAct(limit: .room, at: now, posts: posts, copies: copies, sources: from.sorted())
        guard act.isSomething else { return nil }
        await record(act)
        return act
    }

    /// The account read back from where it outlives a relaunch, off the main actor.
    func loadLimitAccount() async {
        guard let limitStore else { return }
        limitAccount = await Task.detached { limitStore.read() }.value
    }

    /// Clears the account (#251). Only the lines go: nothing held, and nothing on disk but the
    /// file they were in, is touched.
    func clearLimitAccount() async {
        limitAccount = []
        await writeLimitAccount()
    }

    /// One act, at the head of the account and written down.
    func record(_ act: LimitAct) async {
        limitAccount = LimitAccount.adding(act, to: limitAccount)
        await writeLimitAccount()
    }

    private func writeLimitAccount() async {
        guard let limitStore else { return }
        let lines = limitAccount
        await Task.detached { try? limitStore.write(lines) }.value
    }
}

/// Holds the store within the room the person set (#249): at launch, and again whenever the
/// room changes — each landing between is `followStore`'s ask. A modifier of its own, so the
/// root view's chain gains one line and no closure.
struct KeepingWithinRoom: ViewModifier {
    @Environment(DummyPrefs.self) private var prefs
    let session: ShellSession

    func body(content: Content) -> some View {
        content.task(id: prefs.roomBytes) {
            session.roomBytes = prefs.roomBytes
            await session.keepWithinRoom()
        }
    }
}
