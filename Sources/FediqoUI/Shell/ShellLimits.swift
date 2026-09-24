import FediqoCore
import Foundation
import SwiftUI

/// The room limit (#249), and the account both limits keep (#251).
///
/// **Two limits side by side, and whichever is reached first acts.** The months limit is the
/// store's own window (`keep(months:)`): a post older than it is refused at the door and let go
/// where it is already in. The room limit is judged after the fact, by what the index and the
/// picture copies weigh on disk — **the same two figures Usage shows**, `readStoreBytes()` and
/// the copies on disk, so what the limit is held to is what the person sees. Past it, the
/// picture copies go first, oldest written first, because they come back when a picture is read
/// again; only where every copy gone still leaves the store over do posts go, oldest posted first
/// across every source, rows held aside included (`ItemStore.letGoOldest`).
///
/// **Judged round by round on what the rows weigh, not on the file** (`weighStore`). A deleted
/// row leaves its pages in the file until the index is rebuilt, so the file's size cannot say
/// whether a round did anything; the pages in use can, and a round that shrank them by nothing —
/// a save that did not land — ends the check rather than being tried again. The rebuild
/// (`compactStore`) is asked for once, at the end, and only where something went or the file
/// still holds room the rows gave back; where it throws, the file keeps its size, nothing more
/// goes for it, and the next check asks again.
///
/// **When the check runs.** At launch, in the root task after the months limit has had its
/// turn; when the room changes (`KeepingWithinRoom`); and after each landing — asked for by
/// `followStore`, waited out for `roomDebounce`, and one check for however many landings asked
/// meanwhile. What it costs the hot path is a flag and a sleeping task; the measure is a few
/// file sizes and, once, a walk of the copies. Never while the store is held still (`holdsStill`
/// for an export or import, `holdingStill(_:)` for this session's own moves), and never two at
/// once: a check asked for while one runs is run once it ends.
///
/// **What a limit lets go is written down**, once per act, through `record`: never a post, only
/// the limit, the moment, the counts and the sources.
extension ShellSession {
    /// How long after a landing the room is measured, so a burst of pages is one check.
    static let roomDebounce: Duration = .seconds(2)

    /// How many rounds of letting posts go one check makes before it stops: each round takes at
    /// most half of what the average post suggests (`RoomPolicy.postsToLetGo`), so a check that
    /// stops short is asked again by the next landing rather than cutting past the room.
    static let roomRounds = 12

    /// Whether anything is moving the store right now, from outside or from here.
    var storeHeldStill: Bool { holdsStill || holding > 0 }

    /// Runs `body` as one of this session's own moves: the room check does nothing until it is
    /// done, and is asked for once it is. Nests, so a remove that clears inside it holds once.
    func holdingStill<T>(_ body: () async -> T) async -> T {
        holding += 1
        defer {
            holding -= 1
            if holding == 0 { roomMayBeReached() }
        }
        return await body()
    }

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
    /// then the oldest posts, writing and weighing again until it fits. Returns what the limit
    /// let go, or nil where nothing went — no room set, nothing over, a move in progress, or
    /// no index this run to be measured.
    @discardableResult
    func keepWithinRoom(at now: Date = Date()) async -> LimitAct? {
        guard let room = roomBytes, !storeHeldStill, let measureStore, let weighStore else { return nil }
        guard !roomChecking else {
            roomAskedAgain = true
            return nil
        }
        roomChecking = true
        defer {
            roomChecking = false
            if roomAskedAgain {
                roomAskedAgain = false
                roomMayBeReached()
            }
        }
        let hosts = sources.map(\.host)
        var held = await weighStore()
        var copyBytes = await pictures.diskTotal() ?? 0
        var over = RoomPolicy.over(total: held + copyBytes, room: room)
        var copies = 0
        var posts = 0
        var from: Set<String> = []
        if over > 0, copyBytes > 0, let trimmed = await pictures.trimDisk(toBytes: max(0, copyBytes - over), hosts: hosts) {
            copies = trimmed.dropped
            copyBytes = trimmed.kept
            from.formUnion(trimmed.sources)
            over = RoomPolicy.over(total: held + copyBytes, room: room)
        }
        var rounds = 0
        while over > 0, rounds < Self.roomRounds {
            rounds += 1
            let count = RoomPolicy.postsToLetGo(over: over, bytes: held, posts: holdings.posts)
            let went = await store.letGoOldest(count: count)
            guard went.posts > 0 else { break }
            posts += went.posts
            from.formUnion(went.sources)
            await reloadFromStore()
            await persist?()
            let after = await weighStore()
            // A round that gave nothing back — a save that did not land — is not tried again.
            guard after < held else { break }
            held = after
            over = RoomPolicy.over(total: held + copyBytes, room: room)
        }
        // The file is rebuilt once, where posts went or where it still holds room its rows gave
        // back and that room is what puts it over. Where the rebuild throws, the file keeps its
        // size; nothing more goes for that, and the next check asks again.
        let onDisk = await measureStore()
        if posts > 0 || RoomPolicy.over(total: onDisk + copyBytes, room: room) > 0 {
            try? await compactStore?()
            storeBytes = await measureStore()
        } else {
            storeBytes = onDisk
        }
        let act = LimitAct(limit: .room, at: now, posts: posts, copies: copies, sources: from.sorted())
        guard act.isSomething else { return nil }
        await record(act)
        return act
    }

    /// The account read back from where it outlives a relaunch, off the main actor. Read once a
    /// run: a line recorded before this ran is kept ahead of what was read.
    func loadLimitAccount() async {
        guard !limitAccountLoaded else { return }
        limitAccountLoaded = true
        guard let limitStore else { return }
        let read = await Task.detached { limitStore.read() }.value
        let recorded = limitAccount
        limitAccount = Array((recorded + read).prefix(LimitAccount.capacity))
        if !recorded.isEmpty { await writeLimitAccount() }
    }

    /// The account as it now is on disk, in place of what this run held (#251): after a read
    /// back, the package's lines are the account and this device's old lines are about a store
    /// no longer here. Nothing is written: what is on disk is what was just put there.
    func replaceLimitAccount() async {
        limitAccount = []
        limitAccountLoaded = false
        await loadLimitAccount()
    }

    /// Clears the account (#251). Only the lines go: nothing held, and nothing on disk but the
    /// file they were in, is touched.
    func clearLimitAccount() async {
        await loadLimitAccount()
        limitAccount = []
        await writeLimitAccount()
    }

    /// One act, at the head of the account and written down — after the account has been read,
    /// so a line never writes over the lines of earlier runs.
    func record(_ act: LimitAct) async {
        await loadLimitAccount()
        limitAccount = LimitAccount.adding(act, to: limitAccount)
        await writeLimitAccount()
    }

    private func writeLimitAccount() async {
        guard let limitStore else { return }
        let lines = limitAccount
        await Task.detached { try? limitStore.write(lines) }.value
    }
}

/// Holds the store within the room the person set (#249) **whenever the room changes**: the
/// launch's own check is the root task's, after the months limit has had its turn, and each
/// landing between is `followStore`'s ask. A modifier of its own, so the root view's chain gains
/// one line and no closure.
struct KeepingWithinRoom: ViewModifier {
    @Environment(DummyPrefs.self) private var prefs
    let session: ShellSession

    func body(content: Content) -> some View {
        content.onChange(of: prefs.roomBytes) { _, room in
            session.roomBytes = room
            Task { await session.keepWithinRoom() }
        }
    }
}
