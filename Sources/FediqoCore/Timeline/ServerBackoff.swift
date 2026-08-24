import Foundation

/// How long each server is to be left alone, kept by `Server.endpoint`.
///
/// Fediqo is a guest on other people's machines. A server that could not answer is asked
/// again later rather than sooner: the wait starts at the refresh interval, doubles every
/// time nothing arrives, and stops growing at a quarter of an hour. Any answer at all —
/// posts, a refusal, a credential turned down — forgets the whole thing.
///
/// In memory, for as long as the app runs, and per endpoint rather than per host: one
/// hostname can be a source twice under two protocols, and their fates are not the same
/// fact. It is held by whoever reads a feed, so a timeline that cannot be had says nothing
/// about the same server's trending list.
actor ServerBackoff {
    /// Nobody is left alone for longer than this, however many times they failed.
    static let ceiling: Duration = .seconds(15 * 60)

    private struct Wait {
        /// The earliest this endpoint may be asked again.
        var until: Date
        /// How long this wait was, so the next one can be twice it.
        var length: Duration
    }

    private var waits: [String: Wait] = [:]

    /// Everything that may not be asked at `now`. Named the other way round from the
    /// question a load asks, because the answer is empty almost always — nothing is failing,
    /// so nothing is skipped, and a healthy load allocates nothing to find that out.
    ///
    /// One hop per load, not one per server: a fan-out asks this once and filters itself.
    func blocked(at now: Date) -> Set<String> {
        guard !waits.isEmpty else { return [] }
        return Set(waits.filter { now < $0.value.until }.keys)
    }

    /// These servers answered. Whatever they said, they are reachable, so nothing is owed.
    func answered(_ endpoints: some Sequence<String>) {
        for endpoint in endpoints { waits[endpoint] = nil }
    }

    /// Nothing arrived from these. Each wait is twice the last one it was given, or `base`
    /// where this is the first — and never longer than the ceiling.
    func failed(_ endpoints: some Sequence<String>, base: Duration, at now: Date) {
        for endpoint in endpoints {
            let length = min(waits[endpoint].map { $0.length * 2 } ?? base, Self.ceiling)
            waits[endpoint] = Wait(until: now.addingTimeInterval(length.seconds), length: length)
        }
    }
}

extension Duration {
    /// The same length as a `TimeInterval`, for the `Date` arithmetic backoff is written in.
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}
