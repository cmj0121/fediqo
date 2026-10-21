import Foundation
import os

// What a changed post said before, filled in from its source (#332, Decision 1).
//
// A read that brings a post whose source says it changed — a later `edited_at` than the history
// the row holds was answered for — owes one ask of that post's history. It is asked in the
// source's line of loads (`LoadPacer`): paced, behind nothing the reader is waiting on, and let
// go with the source. The source's wordings then replace what this device saw, held to the
// bounds every kept wording is (`Wording.bounded`). A failed ask leaves what the device saw,
// and says nothing.

extension Note {
    /// Whether this row owes an ask of its source's history: a Mastodon post that can be named
    /// there, which its source says was changed, and whose history was not answered for that
    /// change (`historyAt`) — to the millisecond, as rows are compared.
    public var historyOwed: Bool {
        guard source.kind == .mastodon, !isReblog, sendableID != nil, let editedAt else { return false }
        guard let historyAt else { return true }
        return Self.moment(historyAt) < Self.moment(editedAt)
    }
}

/// Fills in what changed posts said before, one ask at a time in each source's line.
public struct MastodonHistoryFill: Sendable {
    private let store: ItemStore
    private let loads: LoadPacer

    public init(store: ItemStore, loads: LoadPacer) {
        self.store = store
        self.loads = loads
    }

    /// The id a history ask takes in its source's line: never one a load of a post takes.
    static func lineID(_ owed: ItemStore.HistoryOwed) -> String {
        "history\u{1e}\(owed.statusID)"
    }

    /// Asks `owed`'s source for its history, in that source's line, and lands what it says.
    /// Returns how the ask ended — `.notTaken(.already)` where it was taken already, by this
    /// session or another on the same store, or is no longer owed.
    ///
    /// **Only ever the item's own source, by that source's id.** `reading` makes the reader of
    /// posts for that host at each try — as the reader where they are signed in, unsigned where
    /// that is right — or nothing, where it must not be asked now: the try then ends with
    /// nothing landed, and the post still owes its ask.
    ///
    /// **A failure says nothing and changes nothing held**: tried as often as a load is, or
    /// answered with no history this can read, or with none at all (404, 410), it is given up
    /// for the run and the row keeps what this device saw. Let go of, taken back, or never
    /// taken, it may be asked again.
    @discardableResult
    public func fill(
        _ owed: ItemStore.HistoryOwed, reading: @escaping @Sendable () async -> MastodonPost?
    ) async -> LoadEnd {
        guard await store.takeHistory(owed) else { return .notTaken(.already) }
        let store = self.store
        let unasked = OSAllocatedUnfairLock(initialState: false)
        let end = await loads.load(host: owed.item.host, id: Self.lineID(owed)) {
            guard let post = await reading() else {
                unasked.withLock { $0 = true }
                return .answered()
            }
            unasked.withLock { $0 = false }
            do {
                let history = try await post.fullHistory(id: owed.statusID, quotes: owed.quotes)
                await store.landHistory(history, for: owed)
                return .answered()
            } catch {
                switch NetLog.status(of: error) {
                case 429: return .slowDown()
                case .some(400..<500): return .answered()
                default: return error is MastodonWriteError ? .answered() : .failed
                }
            }
        }
        switch end {
        case .done:
            await store.releaseHistory(owed, givenUp: !unasked.withLock { $0 })
        case .gaveUp, .sourceGivenUp:
            await store.releaseHistory(owed, givenUp: true)
        case .notTaken, .letGo, .withdrawn:
            await store.releaseHistory(owed, givenUp: false)
        }
        return end
    }
}
