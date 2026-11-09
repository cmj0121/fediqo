import Foundation
import Synchronization

/// When a record was last written, and by which device (D3): a hybrid logical clock stamp.
/// Ordered by `ms`, then `counter`, then `device` — the device id is the tie-break, so two
/// devices never write the same stamp. `zero` is what every record migrated from an older
/// store or file carries (D8): two records at `zero` settle by content (`SyncMerge.wins`),
/// which is why the first merge after pairing is previewed.
public struct SyncStamp: Hashable, Comparable, Sendable, Codable {
    /// Wall-clock milliseconds since 1970, never less than any stamp this clock has seen.
    public let ms: Int64
    /// Orders stamps made within one `ms`.
    public let counter: UInt32
    /// The writing device's id (`DeviceIdentityStore.deviceID()`); "" for `zero`.
    public let device: String

    public init(ms: Int64, counter: UInt32, device: String) {
        self.ms = ms
        self.counter = counter
        self.device = device
    }

    public static let zero = SyncStamp(ms: 0, counter: 0, device: "")

    /// The latest `ms` a stamp read from disk may hold (the end of year 9999): far past any wall
    /// clock, and far enough from `Int64.max` that the clock never runs out of room.
    public static let latestMs: Int64 = 253_402_300_799_999

    /// A stamp as kept on disk, held within what the clock can carry on from: `ms` in
    /// `0...latestMs`, the counter in `UInt32`'s range.
    public static func bounded(ms: Int64, counter: Int64, device: String) -> SyncStamp {
        SyncStamp(ms: min(max(ms, 0), latestMs), counter: UInt32(clamping: counter), device: device)
    }

    public static func < (a: SyncStamp, b: SyncStamp) -> Bool {
        (a.ms, a.counter, a.device) < (b.ms, b.counter, b.device)
    }

    private enum CodingKeys: String, CodingKey {
        case ms
        case counter = "n"
        case device = "by"
    }
}

/// This device's hybrid logical clock: one per run, shared by the store and the timelines.
/// `now()` is strictly greater than every stamp it made or witnessed; `witness` is told every
/// stamp read at launch and every stamp a merge brought, so a local edit after a merge always
/// wins over what arrived.
public final class SyncClock: Sendable {
    /// The id stamped into every stamp this clock makes.
    public let device: String
    private let wall: @Sendable () -> Date
    /// The greatest (ms, counter) made or witnessed.
    private let last: Mutex<(ms: Int64, counter: UInt32)>

    public init(device: String, wall: @escaping @Sendable () -> Date = Date.init) {
        self.device = device
        self.wall = wall
        self.last = Mutex((0, 0))
    }

    /// A new stamp: ms = max(wall, last.ms); counter = last.counter + 1 where ms == last.ms, else 0.
    public func now() -> SyncStamp {
        let wallMs = Int64((wall().timeIntervalSince1970 * 1000).rounded(.down))
        let next = last.withLock { last in
            var next: (ms: Int64, counter: UInt32)
            if wallMs > last.ms {
                next = (wallMs, 0)
            } else if last.counter == .max {
                next = last.ms == .max ? last : (last.ms + 1, 0)
            } else {
                next = (last.ms, last.counter + 1)
            }
            last = next
            return next
        }
        return SyncStamp(ms: next.ms, counter: next.counter, device: device)
    }

    /// `stamp` seen: what `now()` returns next is greater than it.
    public func witness(_ stamp: SyncStamp) {
        last.withLock { last in
            if (stamp.ms, stamp.counter) > (last.ms, last.counter) {
                last = (stamp.ms, stamp.counter)
            }
        }
    }

    /// The clock of a store or session handed no identity (tests, previews, a staged launch,
    /// or a run whose Keychain read failed): device "". Stamps still order; ties lose.
    public static let unpaired = SyncClock(device: "")
}
