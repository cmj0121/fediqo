import Foundation

/// What one address — or every address together — was asked for, and how much of it worked.
///
/// Two time scales live here and the names say which is which. Anything `SinceStart` is the
/// whole of this launch, so a success rate read off those is exact rather than a guess from a
/// recent slice. `callsPerMinute` is the other question answered the other way: a rate has to
/// be recent to mean anything, so it comes from the ledger's rolling window and nothing older.
/// The two must never be put side by side as though they covered the same period.
public struct APIUsage: Sendable, Hashable {
    /// Every request sent since counting started, whether or not anything usable came back.
    public let callsSinceStart: Int
    /// How many of those did not come back usable — a refusal and a broken connection alike.
    public let failuresSinceStart: Int
    /// Calls a minute over the window only, averaged across the minutes there have actually
    /// been. The one number here that is not the whole launch.
    public let callsPerMinute: Double

    public init(callsSinceStart: Int, failuresSinceStart: Int, callsPerMinute: Double) {
        self.callsSinceStart = callsSinceStart
        self.failuresSinceStart = failuresSinceStart
        self.callsPerMinute = callsPerMinute
    }

    public var succeededSinceStart: Int { callsSinceStart - failuresSinceStart }

    /// Over the whole launch, exactly — and `nil` where nothing has been asked at all. There
    /// is no rate of nothing: an address nobody has spoken to is a different thing from one
    /// that answered a hundred times, and a screen showing both as 100% would say they were
    /// the same. Render the `nil` as a dash.
    public var successRate: Double? {
        guard callsSinceStart > 0 else { return nil }
        return Double(succeededSinceStart) / Double(callsSinceStart)
    }
}

/// The ledger read in one piece, as a screen would show it.
///
/// A failure counted here is not a `TimelineResult.failures` entry, and the two must not be
/// shown as the same number. This counts requests; that counts what became of a server on one
/// load. A token turned down and then re-read as a stranger is two requests and one failure
/// here, and one entry there — and the instance probe falling from `/api/v2/instance` to
/// `/api/v1/instance` is two requests here — usually one of them a failure — and no entry there
/// at all. This is
/// the more literal count of the two: it is what we actually asked of somebody else's machine.
public struct APIAccounting: Sendable, Hashable {
    /// When counting started. Nothing here predates it, and a screen showing these numbers
    /// has to say so — a small count is a short launch, not a quiet app.
    public let startedAt: Date
    /// How many minutes back `callsPerMinute` looks. Nothing else here is windowed.
    public let windowMinutes: Int
    /// One entry per address we asked something of, keyed the way `Server.endpoint` spells an
    /// address so a screen can join these to the rows without translating.
    ///
    /// Not the same set as the user's sources, and wider than it: the suggested-server
    /// directory at `api.joinmastodon.org` is here, and so is every hostname somebody typed
    /// into the picker and then did not add. That is right — they are all somebody else's
    /// machines and we asked them all for something — but it means the screen, not this, is
    /// what decides which of these to show as a source and which to fold into the total.
    public let bySource: [String: APIUsage]
    /// Every address above, together.
    public let total: APIUsage

    public init(startedAt: Date, windowMinutes: Int, bySource: [String: APIUsage], total: APIUsage) {
        self.startedAt = startedAt
        self.windowMinutes = windowMinutes
        self.bySource = bySource
        self.total = total
    }
}

/// How much this app has asked of other people's machines, counted as it asks.
///
/// In memory and since launch, on purpose: what we take from a server is a fact about this
/// run, and writing it down would turn "we asked twice" into a permanent record of somebody
/// else's server. Nothing here touches the store, and a ledger that has just been made reads
/// as zero because there is nowhere for an older number to come back from.
///
/// A lock rather than an actor: the write is a pair of dictionary bumps on the path every
/// request already takes, and a screen wants to read the whole thing at once without the
/// reading itself becoming asynchronous. An actor would buy isolation this does not need and
/// charge a suspension per request for it. `StubRoutes` in the tests is guarded the same way.
public final class APILedger: @unchecked Sendable {
    /// The one every client falls back to. `JSONTransport` is a static helper by design —
    /// there is no instance for a caller to hand a ledger to — and the app's clients are
    /// built by `SourceRegistry.standard()` deep under a screen. So the default is shared and
    /// the seam is still open: every client takes a ledger, and anything that wants its own
    /// count (a test, above all) passes one and is not touched by anybody else's requests.
    public static let shared = APILedger()

    /// When this ledger started counting — launch, for `shared`.
    public let startedAt: Date
    /// How many one-minute buckets are kept. Older ones are dropped, so what this holds is
    /// bounded by the number of sources and never by how long the app has been running.
    public let windowMinutes: Int

    private let lock = NSLock()
    /// The whole launch, per endpoint.
    private var lifetime: [String: (calls: Int, failures: Int)] = [:]
    /// Calls per endpoint per minute, pruned to the window. Failures are not bucketed:
    /// the rate question is about volume, and the success question is answered from
    /// `lifetime`, exactly.
    private var window: [Bucket: Int] = [:]

    private struct Bucket: Hashable {
        let endpoint: String
        let minute: Int
    }

    public init(windowMinutes: Int = 15, startedAt: Date = Date()) {
        self.windowMinutes = windowMinutes
        self.startedAt = startedAt
    }

    /// One request, counted against the server it was asked of. `failed` is whether anything
    /// usable came back — a server refusing is as much a failure as a connection breaking,
    /// because either way we asked and got nothing.
    public func record(endpoint: String, failed: Bool, at moment: Date = Date()) {
        let minute = Self.minute(of: moment)
        lock.withLock {
            var counts = lifetime[endpoint] ?? (calls: 0, failures: 0)
            counts.calls += 1
            if failed { counts.failures += 1 }
            lifetime[endpoint] = counts
            window[Bucket(endpoint: endpoint, minute: minute), default: 0] += 1
            prune(olderThan: minute - windowMinutes + 1)
        }
    }

    /// Everything counted so far, per source and altogether.
    public func accounting(now: Date = Date()) -> APIAccounting {
        let minute = Self.minute(of: now)
        return lock.withLock {
            prune(olderThan: minute - windowMinutes + 1)

            // How many minutes the rate is allowed to average over: the window, or the whole
            // launch where that is shorter. A minute the app was not running for would only
            // flatter the number.
            let span = Double(max(1, min(windowMinutes, minute - Self.minute(of: startedAt) + 1)))

            var windowed: [String: Int] = [:]
            for (bucket, calls) in window {
                windowed[bucket.endpoint, default: 0] += calls
            }

            var bySource: [String: APIUsage] = [:]
            var totals = (calls: 0, failures: 0, windowed: 0)
            for (endpoint, counts) in lifetime {
                let recent = windowed[endpoint] ?? 0
                bySource[endpoint] = APIUsage(
                    callsSinceStart: counts.calls,
                    failuresSinceStart: counts.failures,
                    callsPerMinute: Double(recent) / span
                )
                totals.calls += counts.calls
                totals.failures += counts.failures
                totals.windowed += recent
            }

            return APIAccounting(
                startedAt: startedAt,
                windowMinutes: windowMinutes,
                bySource: bySource,
                total: APIUsage(
                    callsSinceStart: totals.calls,
                    failuresSinceStart: totals.failures,
                    callsPerMinute: Double(totals.windowed) / span
                )
            )
        }
    }

    /// How many one-minute buckets are actually being held. Not public: nothing on a screen
    /// wants this, but that the window stays bounded is a promise worth a test.
    var retainedBuckets: Int { lock.withLock { window.count } }

    /// Called under `lock`.
    private func prune(olderThan oldest: Int) {
        window = window.filter { $0.key.minute >= oldest }
    }

    /// Which minute a moment falls in, as a whole number of minutes since the epoch. Buckets
    /// are keyed by this, so two requests a second apart share one and none straddles two.
    private static func minute(of moment: Date) -> Int {
        Int((moment.timeIntervalSince1970 / 60).rounded(.down))
    }
}
