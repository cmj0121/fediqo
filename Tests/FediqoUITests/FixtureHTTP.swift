import Foundation
import FediqoCore

enum FixtureHTTPError: Error {
    case unmapped
    case unreachable
}

actor FixtureHTTP: HTTPClient {
    enum Outcome: Sendable {
        case body(Data, status: Int = 200)
        case text(String, status: Int = 200)
        case fail
        /// The reader walked away. `URLError(.cancelled)` and **not** `CancellationError`, because
        /// that is what `URLSessionClient.data(from:)` actually throws — a harness that threw the
        /// tidy one would be testing a translation the app never has to make. The Core harness
        /// carries the same case for the same reason; this is its twin rather than a second idea.
        case cancelled
    }

    private let routes: [String: Outcome]
    private(set) var requested: [URL] = []

    init(_ routes: [String: Outcome] = [:]) {
        self.routes = routes
    }

    var paths: [String] {
        requested.map { url in
            url.path.isEmpty ? "/" : url.path
        }
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requested.append(url)
        let path = url.path.isEmpty ? "/" : url.path
        guard let outcome = routes[path] ?? routes[url.absoluteString] else {
            throw FixtureHTTPError.unmapped
        }
        switch outcome {
        case .body(let data, let status):
            return (data, Self.response(url, status))
        case .text(let text, let status):
            return (Data(text.utf8), Self.response(url, status))
        case .fail:
            throw FixtureHTTPError.unreachable
        case .cancelled:
            throw URLError(.cancelled)
        }
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// Waits for a condition, and **gives up rather than spinning for ever**.
///
/// A bare `while !x { await Task.yield() }` survives `.timeLimit` — yielding does not throw on
/// cancellation — so a press that stopped setting the flag it spins on would **hang the suite
/// instead of failing it**, and a hung suite reports nothing at all. This returns `false` on the
/// bound so the call site can say what went unmet.
///
/// **Here rather than private to one suite.** It was written in `JoinStageTests` with that
/// argument in its doc, while three sites in `BoardChoiceTests` spun unbounded — the rationale
/// was written down but not reachable from the file that needed it. Target-visible, beside
/// `FixtureHTTP`, is the fix.
///
/// The bound is generous by orders of magnitude on purpose: a press needs its `Task` only to be
/// *scheduled* to set its flag, so a real one trips in single digits and only a broken one
/// reaches the end.
///
/// **The predicate is `async`** so an actor's own state can be the condition — `await http.asks
/// == 1`, which is the only way to ask whether a request has actually reached the wire. A sync
/// closure still passes unchanged, so `{ session.checking }` reads as before.
///
/// **`checking` and "on the wire" are not the same instant.** A press sets its progress report
/// before it calls out, so a test that spins on `checking` and then reads a request count is
/// reading it one hop too early. Spin on the count when the count is what you mean.
@MainActor
func spun(_ limit: Int = 100_000, until condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<limit {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

/// Opens only when a test lets it, so a press can be caught mid-flight.
///
/// The flag is set **before** the waiters are resumed, so a caller arriving after the gate is
/// open does not park on a continuation nobody will resume.
actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

/// A fixture that holds one address until the test says otherwise.
///
/// **Here rather than private to one suite.** Four suites had written their own; the two in this
/// target had drifted apart, and the one missing `asks` had no way to ask the question its own
/// flaky pin turned on. One copy, and the counters come with it.
actor GatedHTTP: HTTPClient {
    private let inner: FixtureHTTP
    private let held: String
    let gate = Gate()

    init(_ routes: [String: FixtureHTTP.Outcome], holding held: String) {
        self.inner = FixtureHTTP(routes)
        self.held = held
    }

    /// Whether the held address has actually been asked for.
    ///
    /// **`checking` is not a discriminator between two phases of one press.** A look and the
    /// take after it both set it, so a test that spins on `checking` alone asserts against
    /// whichever phase it happened to catch — and a resumed sign-in runs both, back to back,
    /// with no await between the look returning and the take claiming the errand. This says
    /// *the take is parked on the wire*, which is the state those tests are about.
    private(set) var reached = false

    /// How many times the held address has been **asked for**, counted where the request starts
    /// rather than where it lands.
    ///
    /// **A request that is refused before it is made never reaches `FixtureHTTP.paths`**, and
    /// neither does one still parked on the gate — so a test asking "did a second fetch start?"
    /// cannot ask `paths`. It has to ask here, in front of the gate.
    private(set) var asks = 0

    /// Matched on the path as well as the whole address, because a Mastodon's timeline carries a
    /// query a test has no business knowing the value of.
    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if url.absoluteString == held || url.path == held {
            reached = true
            asks += 1
            await gate.wait()
        }
        return try await inner.data(from: url)
    }
}
