import Foundation
import os

/// The lines a move nearby writes for Console, so a test on two devices can be read back with
/// `log show --predicate 'subsystem == "Fediqo" AND category == "nearby"'`.
///
/// **A line holds a side, a fixed phrase and a kind, and nothing else**, so it is logged whole
/// as public: never the code, the session, a key, a path, a device's name, or an error's own
/// description.
enum NearbyLog {
    enum Side: String, Sendable {
        case sender, receiver
    }

    static func note(_ side: Side, _ step: StaticString) {
        NetLog.nearby.notice("\(line(side, step), privacy: .public)")
    }

    /// `step` and the kind of `error` — a type and its case, never a description.
    static func note(_ side: Side, _ step: StaticString, error: any Error) {
        NetLog.nearby.notice("\(line(side, step, NetLog.kind(of: error)), privacy: .public)")
    }

    /// `step` and a detail that is itself fixed: a transport error's kind, a count, a percent.
    static func note(_ side: Side, _ step: StaticString, _ detail: String) {
        NetLog.nearby.notice("\(line(side, step, detail), privacy: .public)")
    }

    /// `receiver joined`, `sender dropped on read: posix 54`, `receiver bytes: 40%`.
    static func line(_ side: Side, _ step: StaticString, _ detail: String? = nil) -> String {
        let head = "\(side.rawValue) \(step)"
        guard let detail else { return head }
        return "\(head): \(detail)"
    }

    /// The bytes' progress in tenths: a line each time a new tenth is passed, and the first
    /// one wherever it starts, so a resume shows where it resumed from.
    struct Milestones: Sendable {
        private var last = -1

        /// The percent to log now, or nothing where no new tenth was passed.
        mutating func passed(done: Int64, total: Int64) -> Int? {
            let tenth: Int
            if total > 0 {
                let ratio: Int64 = done * 10 / total
                tenth = Int(min(ratio, 10))
            } else {
                tenth = 10
            }
            guard tenth > last else { return nil }
            last = tenth
            return tenth * 10
        }
    }
}
