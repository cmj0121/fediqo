import CoreGraphics
import FediqoCore
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import FediqoUI

/// What the cache decides without a screen: which key a picture is filed under, how much of one
/// it will decode, what it throws away, what it declines outright, and which kinds of nothing it
/// remembers. Every fetch goes through an injected `HTTPClient`, so nothing here reaches the
/// network.
///
/// The tests that build a cache with `enforcingViewerContract: false` hold more viewer-tier
/// addresses than unit 7 is allowed to, on purpose: six keys is where admission can first decline
/// anything, so exceeding the contract is the only way to reach the branch under test. Saying so
/// at the call site is the point — an exemption that has to be typed is one a reviewer can see.
@MainActor
@Suite("Pictures")
struct ShellPicturesTests {
    private let mb = 1024 * 1024

    private func address(_ n: Int) -> URL {
        URL(string: "https://example.test/\(n).png")!
    }

    private func key(_ n: Int, scale: CGFloat = 2, tier: ShellPictures.Tier = .deck)
        -> ShellPictures.Key {
        ShellPictures.Key(url: address(n), scale: scale, tier: tier)
    }

    private var plate: Image { Image(systemName: "photo") }

    /// Somewhere for an observation callback to leave a mark. `withObservationTracking` hands its
    /// `onChange` a `@Sendable` closure, which cannot write to a local.
    private final class Signal: @unchecked Sendable {
        var fired = false
    }

    /// Throws whatever it is told to, so the difference between a refusal and a dark network can
    /// be tested without either.
    private struct Offline: HTTPClient {
        let code: URLError.Code

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            throw URLError(code)
        }
    }

    /// Fails once, then answers. The retry after an outage needs a client that changes its mind.
    private actor Flaky: HTTPClient {
        private var asked = 0
        private let png: Data

        init(png: Data) { self.png = png }

        var count: Int { asked }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            asked += 1
            if asked == 1 { throw URLError(.notConnectedToInternet) }
            return (png, Self.ok(url))
        }

        static func ok(_ url: URL) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
    }

    /// Answers every address with the same picture and counts how many times it was asked.
    private actor Counting: HTTPClient {
        private(set) var requests = 0
        private let png: Data

        init(png: Data) { self.png = png }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            requests += 1
            return (png, Flaky.ok(url))
        }
    }

    /// A barrier a test opens by hand. `opened` is checked **before** waiting, so a caller that
    /// arrives after the gate is open does not park on a continuation nobody will resume.
    private actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            opened = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    /// Holds every request open until the gate is opened, so "these fetches were all still in the
    /// air" is a fact the test arranges rather than a race it hopes to win.
    private actor Holding: HTTPClient {
        private var current = 0
        private(set) var peak = 0
        private let png: Data
        private let gate: Gate

        private var awaited: Int?
        private var arrival: CheckedContinuation<Void, Never>?

        init(png: Data, gate: Gate) {
            self.png = png
            self.gate = gate
        }

        /// Returns once `n` requests are simultaneously parked at the gate. A barrier rather than
        /// a sleep: on a starved machine this takes longer and still means the same thing.
        func whenHolding(_ n: Int) async {
            guard current < n else { return }
            awaited = n
            await withCheckedContinuation { arrival = $0 }
        }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            current += 1
            peak = max(peak, current)
            if let target = awaited, current >= target, let waiter = arrival {
                awaited = nil
                arrival = nil
                waiter.resume()
            }
            await gate.wait()
            current -= 1
            return (png, Flaky.ok(url))
        }
    }

    // MARK: Nothing but https ever reaches a socket

    /// The hole this suite exists to keep shut. A hostile instance can put anything in an
    /// `avatar` field; a cache that fetches whatever it is handed will read it. `URLSessionClient`
    /// refuses every scheme but `https` before any request is made, so none of these touch the
    /// disk, the network, or anything else.
    @Test(
        "A picture is only ever fetched over https",
        arguments: [
            "file:///etc/passwd",
            "file:///tmp/secret.png",
            "data:image/png;base64,iVBORw0KGgo=",
            "http://example.test/cleartext.png",
            "ftp://example.test/pic.png",
        ]
    )
    func refusesEveryOtherScheme(_ address: String) async throws {
        let url = try #require(URL(string: address))
        let answer = await ShellPictures.body(url, using: URLSessionClient())
        guard case .failure(let absence) = answer else {
            Issue.record("\(address) was not refused")
            return
        }
        #expect(absence == .refused)
    }

    @Test("A refused scheme is remembered as refused, not as an outage")
    func refusedSchemeIsPermanent() async throws {
        let cache = ShellPictures(http: URLSessionClient())
        let url = try #require(URL(string: "file:///etc/passwd"))
        await cache.fetch(url, scale: 2, tier: .deck)
        #expect(cache.missing[ShellPictures.Key(url: url, scale: 2, tier: .deck)] == .refused)
        #expect(cache.picture(url, scale: 2, tier: .deck) == nil)
    }

    // MARK: The key and the tiers

    @Test("The same address on two screens is two pictures")
    func keyCarriesTheScale() {
        #expect(key(1, scale: 2) == key(1, scale: 2))
        #expect(key(1, scale: 2) != key(1, scale: 3))
        #expect(key(1, scale: 2) != key(2, scale: 2))
        #expect(Set([key(1, scale: 2), key(1, scale: 3), key(1, scale: 2)]).count == 2)
    }

    @Test("The same address in two tiers is two entries")
    func keyCarriesTheTier() {
        let cache = ShellPictures()
        #expect(key(1, tier: .deck) != key(1, tier: .viewer))
        cache.keep(plate, cost: mb, for: key(1, tier: .deck), startedAt: 0)
        cache.keep(plate, cost: mb, for: key(1, tier: .viewer), startedAt: 0)
        #expect(cache.picture(address(1), scale: 2, tier: .deck) != nil)
        #expect(cache.picture(address(1), scale: 2, tier: .viewer) != nil)
        #expect(cache.order.count == 2)
    }

    /// I2 — the budget must fund every **key** the contract's **addresses** can produce, and the
    /// factor between them is display scale: dragging a window between a 2× and a 1× display
    /// holds both decodes of every address until the stale-scale keys are evicted.
    ///
    /// Written as a derivation rather than a constant. The old form asserted `budget >= 6 ×
    /// ceiling` and justified the six as headroom over the three the app shows; it was
    /// accidentally right, because six *is* three addresses at two scales and there was no
    /// headroom in it at all. Raising `viewerAddresses` without raising the budget now fails
    /// here rather than stranding rows in the app.
    @Test("The budget funds every key the contract's addresses can produce")
    func budgetFundsTheContract() {
        let scales = 2
        #expect(
            ShellPictures.budget
                >= scales * ShellPictures.viewerAddresses * ShellPictures.Tier.viewer.ceiling
        )
        // At the contract limit the margin is exactly zero, not two-fold: a scale change fills
        // the viewer tier completely. Safe, because full is not declining — but nothing spare.
        #expect(
            ShellPictures.budget / ShellPictures.Tier.viewer.ceiling
                == scales * ShellPictures.viewerAddresses
        )
    }

    @Test("A tier is a decode budget, and there are only two of them")
    func tiersAreBounded() {
        #expect(ShellPictures.Tier.allCases.count == 2)
        for tier in ShellPictures.Tier.allCases {
            #expect(tier.ceiling == tier.maxPixels * tier.maxPixels * 4)
            #expect(tier.ceiling <= ShellPictures.budget)
        }
        #expect(ShellPictures.Tier.deck.maxPixels < ShellPictures.Tier.viewer.maxPixels)
    }

    @Test("No address is no picture and no key")
    func noAddress() {
        let cache = ShellPictures()
        #expect(cache.picture(nil, scale: 2, tier: .deck) == nil)
        #expect(!cache.isMissing(nil, scale: 2, tier: .deck))
    }

    // MARK: I1 — a decode never costs more than its tier allows

    /// The bound `maxPixels` alone does not give. ImageIO carries a 16-bit source's depth through
    /// the thumbnail, so without `normalise` a hostile instance doubles every byte in this file
    /// by sending a deeper PNG than anyone asked for.
    @Test("A sixteen-bit picture costs what its eight-bit twin costs", arguments: ShellPictures.Tier.allCases)
    func deepSourcesCostNoMore(tier: ShellPictures.Tier) throws {
        let wide = tier.maxPixels * 2
        let shallow = try #require(ShellPictures.decode(
            try picture(width: wide, height: wide, bits: 8), maxPixels: tier.maxPixels
        ))
        let deep = try #require(ShellPictures.decode(
            try picture(width: wide, height: wide, bits: 16), maxPixels: tier.maxPixels
        ))

        #expect(deep.bitsPerComponent == 8)
        #expect(deep.height * deep.bytesPerRow == shallow.height * shallow.bytesPerRow)
        #expect(deep.height * deep.bytesPerRow <= tier.ceiling)
        #expect(shallow.height * shallow.bytesPerRow <= tier.ceiling)
    }

    @Test("An eight-bit picture is handed back untouched")
    func shallowSourcesAreNotRedrawn() throws {
        let image = try #require(ShellPictures.decode(
            try picture(width: 40, height: 24, bits: 8), maxPixels: 320
        ))
        #expect(image.bitsPerComponent == 8)
        #expect(ShellPictures.normalise(image) === image)
    }

    @Test("A picture larger than the cap is decoded down to it, and keeps its shape")
    func decodeIsCapped() throws {
        let cap = ShellPictures.Tier.deck.maxPixels
        let decoded = try #require(ShellPictures.decode(
            try picture(width: cap * 2, height: cap, bits: 8), maxPixels: cap
        ))
        #expect(max(decoded.width, decoded.height) == cap)
        let ratio = Double(decoded.width) / Double(decoded.height)
        #expect(abs(ratio - 2) < 0.01)
    }

    @Test("A picture smaller than the cap is left the size it was sent")
    func decodeDoesNotUpscale() throws {
        let decoded = try #require(ShellPictures.decode(
            try picture(width: 40, height: 24, bits: 8), maxPixels: 2048
        ))
        #expect(decoded.width == 40)
        #expect(decoded.height == 24)
    }

    @Test("What is not a picture decodes to nothing")
    func decodeRefusesRubbish() {
        #expect(ShellPictures.decode(Data("this is not a picture".utf8), maxPixels: 320) == nil)
        #expect(ShellPictures.decode(Data(), maxPixels: 320) == nil)
    }

    // MARK: I5 — a screen that cannot hold all its pictures settles

    /// The livelock this unit's rework introduced and then had to close.
    ///
    /// Modelled the way SwiftUI actually runs a frame: **every visible body reads, and only then
    /// do the tasks fire**. That ordering is the whole of it — a fetch started after its
    /// neighbours were read is not newer than them, and treating it as newer is what made every
    /// picture on screen look evictable and turned one eviction into an endless chain.
    /// Parameterised entirely **above** what fits. Rows at or below `fits` never reach the
    /// admission mechanism at all — zero evictions, zero declines — so they are vacuous here
    /// rather than merely weak, and they would make I5b's assertion false outright.
    ///
    /// Worth recording why this is written down rather than quietly corrected: the first version
    /// of this test ran `[4, 5, 8, 120]`, and four and five are both under `fits`. Two of its
    /// four arguments entered nothing at all. The mechanism this whole review has been about was
    /// covered by half the cases it appeared to be covered by, and it read as thorough.
    @Test(
        "A screen that cannot hold all its pictures settles instead of asking forever",
        arguments: [7, 8, 9, 12]
    )
    func crowdedScreenSettles(rows: Int) {
        let cache = ShellPictures(enforcingViewerContract: false)
        let cost = ShellPictures.Tier.viewer.ceiling
        var asked = 0
        var seen: [Int] = []

        for _ in 0 ..< 20 {
            var absent: [ShellPictures.Key] = []
            for n in 0 ..< rows where cache.picture(address(n), scale: 2, tier: .viewer) == nil {
                absent.append(key(n, tier: .viewer))
            }
            for k in absent {
                guard cache.missing[k]?.asksAgain ?? true else { continue }
                asked += 1
                cache.keep(plate, cost: cost, for: k, startedAt: cache.interest[k] ?? 0)
            }
            seen.append(asked)
        }

        // Every argument must actually exercise admission, or this passes by never entering it.
        #expect(rows > ShellPictures.budget / ShellPictures.Tier.viewer.ceiling)
        #expect(seen.last == seen.first, "kept growing: \(seen.prefix(8))")
        #expect(asked == rows)
        #expect(cache.generation == 0)
        #expect(cache.heldBytes <= ShellPictures.budget)
    }

    /// I5b — **a documented non-guarantee, kept deliberately.**
    ///
    /// The same screen driven the way SwiftUI cannot drive it: each row read and then satisfied
    /// before the next row is read. Admission by recency needs the set of wanted things to be
    /// established before any of them is met, and this ordering never does that — the newcomer
    /// is genuinely the most recently wanted thing every single time, so everything else looks
    /// older and stays evictable.
    ///
    /// It is here because it is the only thing that detects a `startedAt` falling back to the
    /// clock instead of to zero. It is allowed to loop; what it must not do is quietly become
    /// the shape the real code takes.
    ///
    /// Takes the same band as I5 and for a sharper reason: at or below `fits` there is no
    /// pressure, so nothing is ever re-asked and `asked > rows` is simply false. The floor is
    /// written against the budget rather than as a literal so it follows the budget.
    @Test(
        "Reading and satisfying in the same pass is allowed to loop, and shows what that costs",
        arguments: [7, 8, 9, 12]
    )
    func interleavedIsNotGuaranteed(rows: Int) {
        let cache = ShellPictures(enforcingViewerContract: false)
        let cost = ShellPictures.Tier.viewer.ceiling
        var asked = 0

        #expect(rows > ShellPictures.budget / cost)

        for _ in 0 ..< 10 {
            for n in 0 ..< rows {
                let k = key(n, tier: .viewer)
                guard cache.picture(address(n), scale: 2, tier: .viewer) == nil else { continue }
                guard cache.missing[k]?.asksAgain ?? true else { continue }
                asked += 1
                cache.keep(plate, cost: cost, for: k, startedAt: cache.interest[k] ?? 0)
            }
        }

        // Far more than one ask per picture — that is the cost, and it is why the rule is
        // written against the pass rather than against the call.
        #expect(asked > rows)
    }

    @Test("The same, driven through real fetches rather than costs")
    func crowdedScreenSettlesThroughFetches() async throws {
        let wide = ShellPictures.Tier.viewer.maxPixels
        let http = Counting(png: try picture(width: wide, height: wide, bits: 8))
        let cache = ShellPictures(http: http, enforcingViewerContract: false)
        let rows = 8

        for _ in 0 ..< 4 {
            var absent: [URL] = []
            for n in 0 ..< rows where cache.picture(address(n), scale: 2, tier: .viewer) == nil {
                absent.append(address(n))
            }
            for url in absent {
                await cache.fetch(url, scale: 2, tier: .viewer)
            }
        }

        #expect(await http.requests == rows)
        #expect(cache.heldBytes <= ShellPictures.budget)
        #expect(cache.missing.values.contains(.crowded))
    }

    /// The queued path, which nothing else here reaches: `crowdedScreenSettlesThroughFetches`
    /// goes through `work()` but never waits, so a fetch that lands several passes after it was
    /// commissioned was until now untested — which is why the sampling question was found by
    /// inspection rather than by this suite.
    ///
    /// The equality is the assertion that matters. It pins production's sampling to the
    /// harness's, and fails if the two ever drift apart again.
    @Test("A fetch that waited behind the gate lands the same way as one that did not")
    func queuedPathMatchesDirectPath() async throws {
        let wide = ShellPictures.Tier.viewer.maxPixels
        let png = try picture(width: wide, height: wide, bits: 8)
        let rows = 8
        let passes = 8

        // Every request is held open until this test opens the gate, so "the passes overlapped"
        // is arranged rather than hoped for. It used to be a 3ms sleep, which is a bet that the
        // machine will schedule this test often enough — and under CPU starvation that bet loses:
        // the sleeps stop holding anything, every fetch lands inside the pass that commissioned
        // it, the cache never overflows, and nothing is declined. Measured 4 red in 14 runs under
        // a 12-way load. A timing stand-in for a barrier is the same defect as a bounded spin.
        let gate = Gate()
        let holding = Holding(png: png, gate: gate)
        let queued = ShellPictures(http: holding, enforcingViewerContract: false)

        // Nothing can land while this runs, so every pass is commissioned against a cache that
        // is still empty.
        let outstanding = await commission(queued, rows: rows, passes: passes)

        // **Pin the premise the conclusion rests on, in a form that fails when it is false.**
        // The old pin — `peak == maxInFlight` — passed in every one of the red runs: the gate
        // had genuinely queued, the passes simply had not overlapped. Those are different facts
        // and only this one is what the test is about.
        #expect(
            queued.order.isEmpty,
            "a fetch landed while passes were still being commissioned; they did not overlap"
        )
        #expect(await holding.peak == ShellPictures.maxInFlight)

        // A watchdog, not a timeout: twenty seconds because it only has to beat the job limit,
        // and a quick one buys nothing while costing false failures on a loaded machine — at
        // five seconds the equivalent guard elsewhere opened before a starved body reached the
        // line it was gating.
        let rescued = Signal()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            rescued.fired = true
            await gate.open()
        }

        await gate.open()
        for task in outstanding { await task.value }
        watchdog.cancel()
        #expect(!rescued.fired, "the watchdog opened the gate; the test never got there itself")

        // The same screen with nothing to wait for, each pass drained before the next.
        let direct = ShellPictures(http: Counting(png: png), enforcingViewerContract: false)
        await drivePromptly(direct, rows: rows, passes: passes)

        let crowdedWhenQueued = queued.missing.values.filter { $0 == .crowded }.count
        let crowdedWhenDirect = direct.missing.values.filter { $0 == .crowded }.count

        #expect(crowdedWhenQueued == crowdedWhenDirect)
        // Not vacuous: this screen really does overflow, so the equality has something to be
        // about. Measured at two on both paths, stable across repeated runs.
        #expect(
            crowdedWhenDirect
                == rows - ShellPictures.budget / ShellPictures.Tier.viewer.ceiling
        )
        #expect(queued.generation == 0)
        #expect(direct.generation == 0)
        #expect(queued.heldBytes <= ShellPictures.budget)
        #expect(direct.heldBytes <= ShellPictures.budget)
    }

    /// Commissions every pass without letting any of them be satisfied, and hands back the work
    /// for the caller to drain once it has opened the gate. Splitting commissioning from draining
    /// is what makes the overlap structural: with the client held shut, no arrival can race the
    /// loop no matter how little CPU this test is given.
    private func commission(
        _ cache: ShellPictures,
        rows: Int,
        passes: Int
    ) async -> [Task<Void, Never>] {
        var outstanding: [Task<Void, Never>] = []
        for _ in 0 ..< passes {
            var absent: [URL] = []
            for n in 0 ..< rows where cache.picture(address(n), scale: 2, tier: .viewer) == nil {
                absent.append(address(n))
            }
            for url in absent {
                outstanding.append(Task { @MainActor in
                    await cache.fetch(url, scale: 2, tier: .viewer)
                })
            }
            await Task.yield()
        }
        return outstanding
    }

    /// The other half of the comparison: every pass commissioned and then **fully drained**
    /// before the next begins, so a fetch always lands in the pass that asked for it.
    ///
    /// Drained rather than yielded to. The version this replaces relied on `Task.yield()` to let
    /// passes overlap, which is the same timing bet as the sleep it sat beside — under load the
    /// fetches completed inline, the run degenerated into the interleaved shape I5b documents,
    /// and it declined nothing. That produced the mirror image of the failure this test is named
    /// for: `crowdedWhenDirect → 0`, measured, in the same stress runs.
    private func drivePromptly(_ cache: ShellPictures, rows: Int, passes: Int) async {
        for _ in 0 ..< passes {
            var absent: [URL] = []
            for n in 0 ..< rows where cache.picture(address(n), scale: 2, tier: .viewer) == nil {
                absent.append(address(n))
            }
            var running: [Task<Void, Never>] = []
            for url in absent {
                running.append(Task { @MainActor in
                    await cache.fetch(url, scale: 2, tier: .viewer)
                })
            }
            for task in running { await task.value }
        }
    }

    /// The tripwire counts **addresses**, which is what unit 7's contract limits, not keys.
    ///
    /// A key carries the screen's scale, so dragging a window from a 2× display to a 1× one gives
    /// every address a second key at the same tier. Counting keys would trap on that ordinary
    /// drag while unit 7 sat exactly inside its stated budget — three addresses becoming six keys
    /// spends the whole of the slack.
    ///
    /// Uses the shared cache deliberately: the tripwire is scoped to it, so nothing else can
    /// reach the branch under test. Reaching the end of this test at all is the assertion — a key
    /// count traps on the fourth `keep` rather than failing an expectation.
    @Test("Two screens' worth of three addresses does not trip the contract tripwire")
    func tripwireCountsAddressesNotKeys() {
        let cache = ShellPictures.shared
        let cost = ShellPictures.Tier.viewer.ceiling

        for n in 0 ..< 3 {
            for scale in [CGFloat(2), CGFloat(1)] {
                cache.keep(
                    plate,
                    cost: cost,
                    for: ShellPictures.Key(url: address(900 + n), scale: scale, tier: .viewer),
                    startedAt: cache.clock + 1
                )
            }
        }

        let addresses = Set(cache.order.filter { $0.tier == .viewer }.map(\.url))
        #expect(addresses.count == 3)
        #expect(cache.order.count(where: { $0.tier == .viewer }) == 6)
    }

    @Test("Scrolling still evicts rather than declining")
    func scrollingEvicts() {
        let cache = ShellPictures(enforcingViewerContract: false)
        let cost = ShellPictures.Tier.viewer.ceiling
        var asked = 0

        for top in 0 ..< 40 {
            var absent: [ShellPictures.Key] = []
            for n in top ..< (top + 4)
            where cache.picture(address(n), scale: 2, tier: .viewer) == nil {
                absent.append(key(n, tier: .viewer))
            }
            for k in absent {
                guard cache.missing[k]?.asksAgain ?? true else { continue }
                asked += 1
                cache.keep(plate, cost: cost, for: k, startedAt: cache.interest[k] ?? 0)
            }
        }

        // Forty-three distinct pictures pass through a window that holds four. Each is asked for
        // once, none is declined, and the cache stays inside its budget throughout.
        #expect(asked == 43)
        #expect(!cache.missing.values.contains(.crowded))
        #expect(cache.heldBytes <= ShellPictures.budget)
    }

    /// I5c — **a documented non-guarantee, and the one the latch cannot catch.**
    ///
    /// The same screen under *narrow* observation: only the bodies that lost a picture re-run, so
    /// only they re-stamp their interest. Every other held key keeps the stamp from its own
    /// admission, which is older than the newcomer's read — so the newcomer is structurally the
    /// newest thing in the cache every pass, there is always exactly one older key to evict, and
    /// **`.crowded` is never written at all.** That is why I9 is not a backstop for I8.
    ///
    /// **Sized one and two rows over budget on purpose.** The failure is worst just over budget
    /// and *improves* as the screen gets more crowded: a large lacking set re-stamps itself
    /// inside one frame and self-limits, so a storm looks healthiest of all and is the wrong size
    /// to test at.
    @Test(
        "Narrow observation livelocks, and nothing is ever declined",
        arguments: [7, 8]
    )
    func narrowObservationIsNotGuaranteed(rows: Int) {
        let cache = ShellPictures(enforcingViewerContract: false)
        let cost = ShellPictures.Tier.viewer.ceiling
        let fits = ShellPictures.budget / cost

        // **The warm start is the whole point, not scaffolding.** It has to be a settled screen
        // that one row then scrolls into. Driven cold — every row absent in the first pass — the
        // rows admitted during that pass are re-stamped by `keep` and land *newer* than the
        // newcomer's read, so the branch declines, the run terminates, and both assertions below
        // invert. That looks healthy while measuring a transient the real app passes through
        // once, instead of the steady state it lives in.
        for n in 0 ..< fits {
            let k = key(n, tier: .viewer)
            _ = cache.picture(k.url, scale: 2, tier: .viewer)
            cache.keep(plate, cost: cost, for: k, startedAt: cache.interest[k] ?? 0)
        }

        let passes = 30
        var asked = 0
        for _ in 0 ..< passes {
            let held = Set(cache.order)
            var absent: [ShellPictures.Key] = []
            for n in 0 ..< rows {
                let k = key(n, tier: .viewer)
                // A body that still has its picture does not re-run, so it does not re-stamp.
                guard !held.contains(k) else { continue }
                _ = cache.picture(k.url, scale: 2, tier: .viewer)
                absent.append(k)
            }
            for k in absent {
                guard cache.missing[k]?.asksAgain ?? true else { continue }
                asked += 1
                cache.keep(plate, cost: cost, for: k, startedAt: cache.interest[k] ?? 0)
            }
        }

        // One real multi-megabyte refetch per row over budget, per pass, forever.
        #expect(asked == (rows - fits) * passes)
        #expect(
            !cache.missing.values.contains(.crowded),
            "the latch cannot catch this: the declining branch is never reached"
        )
    }

    /// Item 1 — the rule the fallback encodes: **speculative work never displaces work a view
    /// has actually asked for.** A prefetch reaching `work` before any body has read the row has
    /// no interest entry, and a `startedAt` of zero is older than everything, so it can take
    /// nobody's room.
    @Test("A row that asked can take room; a prefetch nobody asked for cannot")
    func onlyAskedForWorkDisplaces() {
        let cost = ShellPictures.Tier.viewer.ceiling
        let newcomer = key(99, tier: .viewer)

        let asked = ShellPictures(enforcingViewerContract: false)
        for n in 0 ..< 6 {
            asked.keep(plate, cost: cost, for: key(n, tier: .viewer), startedAt: 0)
        }
        // A body read is what stamps interest, and interest is what buys room.
        _ = asked.picture(address(99), scale: 2, tier: .viewer)
        asked.keep(plate, cost: cost, for: newcomer, startedAt: asked.interest[newcomer] ?? 0)
        #expect(asked.picture(address(99), scale: 2, tier: .viewer) != nil)
        #expect(asked.order.count == 6)

        let speculative = ShellPictures(enforcingViewerContract: false)
        for n in 0 ..< 6 {
            speculative.keep(plate, cost: cost, for: key(n, tier: .viewer), startedAt: 0)
        }
        // No read, so no interest — exactly what `work` computes for a prefetch.
        speculative.keep(
            plate, cost: cost, for: newcomer, startedAt: speculative.interest[newcomer] ?? 0
        )
        #expect(speculative.missing[newcomer] == .crowded)
        #expect(speculative.order.count == 6)
    }

    /// Declining frees nothing and signals nothing: there is no relief path left to reach.
    @Test("Declining is silent")
    func decliningIsSilent() {
        let cache = ShellPictures(enforcingViewerContract: false)
        let cost = ShellPictures.Tier.viewer.ceiling
        for n in 0 ..< 6 {
            cache.keep(plate, cost: cost, for: key(n, tier: .viewer), startedAt: 0)
        }
        let before = cache.generation
        cache.keep(plate, cost: cost, for: key(99, tier: .viewer), startedAt: 0)

        #expect(cache.missing[key(99, tier: .viewer)] == .crowded)
        #expect(cache.generation == before)
        #expect(cache.heldBytes == 6 * cost)
    }

    // MARK: I7 — the count bounds, and what interest may never forget

    @Test("The cache is bounded by how many as well as by how much")
    func boundedByCount() {
        let cache = ShellPictures()
        // Cheap enough that the byte budget never bites — emoji and avatars are this shape.
        for n in 0 ..< (ShellPictures.held + 400) {
            cache.keep(plate, cost: 1024, for: key(n), startedAt: cache.clock + 1)
        }
        #expect(cache.order.count <= ShellPictures.held)
        #expect(cache.interest.count <= ShellPictures.remembered)
        #expect(cache.heldBytes <= ShellPictures.budget)
    }

    /// I7 — the eviction predicate reads `interest`, so a held key missing from it would look
    /// infinitely stale and be evictable however recently it was drawn. That is the thrash this
    /// mechanism exists to stop, so the clause is load-bearing rather than tidy.
    @Test("Interest never forgets a key it is holding a picture for")
    func interestPinsHeldKeys() {
        let cache = ShellPictures()
        for n in 0 ..< 200 {
            cache.keep(plate, cost: 1024, for: key(n), startedAt: cache.clock + 1)
        }
        let holding = cache.order
        #expect(!holding.isEmpty)

        // Push the map far past its bound with keys that have no picture behind them.
        for n in 10_000 ..< (10_000 + ShellPictures.remembered * 3) {
            _ = cache.picture(address(n), scale: 2, tier: .deck)
        }

        #expect(cache.interest.count <= ShellPictures.remembered)
        for key in holding {
            #expect(cache.interest[key] != nil, "dropped the interest of a held picture")
        }
    }

    @Test("Trimming interest can always reach its mark without touching a held key")
    func interestOutgrowsWhatIsHeld() {
        #expect(ShellPictures.remembered >= 2 * ShellPictures.held)
    }

    @Test("What was declined reads as absent and is not asked for again")
    func crowdedReadsAsAbsent() {
        let cache = ShellPictures()
        cache.note(.crowded, for: key(1))
        #expect(cache.isMissing(address(1), scale: 2, tier: .deck))
        #expect(!ShellPictures.Absence.crowded.asksAgain)
    }

    // MARK: I3 and I4 — which signals are global and which are not

    @Test("Ordinary eviction leaves the generation alone")
    func evictionIsSilent() {
        let cache = ShellPictures(enforcingViewerContract: false)
        let cost = ShellPictures.Tier.viewer.ceiling
        for n in 0 ..< 6 {
            cache.keep(plate, cost: cost, for: key(n, tier: .viewer), startedAt: cache.clock)
        }
        #expect(cache.generation == 0)
        // The seventh, wanted more recently than any of them, evicts the oldest.
        cache.keep(plate, cost: cost, for: key(6, tier: .viewer), startedAt: cache.clock + 1)
        #expect(cache.order.count == 6)
        #expect(cache.generation == 0)
    }

    @Test("A network coming back is a cohort, and bumps once")
    func outageRecoveryBumps() {
        let cache = ShellPictures()
        cache.note(.unreachable, for: key(1))
        cache.note(.unreachable, for: key(2))
        cache.note(.refused, for: key(3))
        let before = cache.generation

        cache.keep(plate, cost: mb, for: key(4), startedAt: 0)

        #expect(!cache.isMissing(address(1), scale: 2, tier: .deck))
        #expect(!cache.isMissing(address(2), scale: 2, tier: .deck))
        #expect(cache.missing[key(3)] == .refused)
        #expect(cache.generation == before + 1)
    }

    /// I9 — the latch is the floor, not a wart on it. It is the only thing that makes "arrived
    /// and was not kept" a stable state, which is the whole property admission control creates.
    /// Every automatic relief tried re-opened the loop, because the crowded cohort's own
    /// re-asking produces the evictions that would trigger the next relief.
    @Test("What was declined stays declined, whatever else the cache goes on to do")
    func crowdedIsTerminal() {
        let cache = ShellPictures()
        cache.note(.crowded, for: key(1))
        let before = cache.generation

        // Plenty of room appears and plenty of other work succeeds; none of it is an event this
        // cohort could not have caused itself, so none of it lifts the mark.
        for n in 2 ..< 40 {
            cache.keep(plate, cost: 1024, for: key(n), startedAt: cache.clock + 1)
        }

        #expect(cache.missing[key(1)] == .crowded)
        #expect(cache.isMissing(address(1), scale: 2, tier: .deck))
        #expect(cache.generation == before)
    }

    /// I8 — the property the whole mechanism rests on, tested at the seam because the behaviour
    /// it protects cannot be reached from here. This fails the moment cache-side observation is
    /// narrowed.
    ///
    /// **It covers one of the three intolerable changes.** The cache cannot see where `picture`
    /// was called from, so moving the read out of `body` into `onAppear` or `task` — the one most
    /// likely to be proposed, and the one with the best-sounding justification — is invisible
    /// from here and from anywhere else in this suite. Nothing catches it but the comment on
    /// `RemoteImage`. An `EquatableView` wrapper is equally invisible for the same reason.
    @Test("Reading one picture makes a view depend on every picture")
    func observationIsCoarse() {
        let cache = ShellPictures()
        // `onChange` is a `@Sendable` closure, so the flag it sets cannot be a local `var`.
        let signal = Signal()
        withObservationTracking {
            _ = cache.picture(address(1), scale: 2, tier: .deck)
        } onChange: {
            signal.fired = true
        }
        cache.keep(plate, cost: 1024, for: key(2), startedAt: 0)

        #expect(signal.fired, """
            Admission terminates only because a view reading any picture is invalidated by \
            every picture. Narrowing this to per-key observable storage restores the unbounded \
            refetch chain. See I8.

            This assertion covers only cache-side narrowing. The other two changes I8 forbids — \
            wrapping RemoteImage in an EquatableView, and moving the cache.picture(...) read out \
            of body into onAppear or task — are invisible from here, because the cache cannot \
            see where it was called from. Nothing in this suite covers them.
            """)
    }

    // MARK: I6 — how much can be in the air at once

    /// Both halves structurally rather than by timing. `whenHolding` returns only once the gate
    /// has admitted everything it will ever admit at once, so the lower bound is a fact this test
    /// waits for; the upper bound is then whatever the counter reached across the whole run.
    ///
    /// It used to assert `peak > 1` after letting every request sleep for 2ms, which is the same
    /// "usually enough" promise as the sleep that made the queued test flaky — it survived a
    /// 12-way load here, but only because the margin happened to be wide.
    @Test("No more than a handful of bodies are ever resident at once")
    func boundedInFlight() async throws {
        let gate = Gate()
        let http = Holding(png: try picture(width: 32, height: 32, bits: 8), gate: gate)
        let cache = ShellPictures(http: http)

        // Started together rather than one after another, so the gate has something to hold back.
        var started: [Task<Void, Never>] = []
        for n in 0 ..< 24 {
            let url = address(n)
            started.append(Task { @MainActor in
                await cache.fetch(url, scale: 2, tier: .deck)
            })
        }

        let rescued = Signal()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            rescued.fired = true
            await gate.open()
        }

        // Twenty-four asked for at once, and exactly `maxInFlight` are ever held at once.
        await http.whenHolding(ShellPictures.maxInFlight)
        #expect(await http.peak == ShellPictures.maxInFlight)

        await gate.open()
        for task in started { await task.value }
        watchdog.cancel()

        #expect(!rescued.fired, "the watchdog opened the gate; the test never got there itself")
        #expect(await http.peak == ShellPictures.maxInFlight)
        #expect(cache.inFlight.isEmpty)
    }

    // MARK: What came back with nothing, and why

    @Test("What came back with nothing is absent, not arriving")
    func missingIsRemembered() {
        let cache = ShellPictures()
        cache.note(.refused, for: key(1))
        #expect(cache.isMissing(address(1), scale: 2, tier: .deck))
        #expect(!cache.isMissing(address(1), scale: 3, tier: .deck))
        #expect(!cache.isMissing(address(1), scale: 2, tier: .viewer))
        #expect(cache.picture(address(1), scale: 2, tier: .deck) == nil)
    }

    @Test("A picture that arrives clears the note that it was not there")
    func arrivingClearsMissing() {
        let cache = ShellPictures()
        cache.note(.refused, for: key(1))
        cache.keep(plate, cost: mb, for: key(1), startedAt: 0)
        #expect(!cache.isMissing(address(1), scale: 2, tier: .deck))
        #expect(cache.picture(address(1), scale: 2, tier: .deck) != nil)
    }

    @Test("Refusals are bounded like everything else here")
    func refusalsAreBounded() {
        let cache = ShellPictures()
        for n in 0 ..< (ShellPictures.refusals + 20) {
            cache.note(.refused, for: key(n))
        }
        #expect(cache.missing.count <= ShellPictures.refusals)
        #expect(cache.missing[key(ShellPictures.refusals + 19)] == .refused)
    }

    @Test("Interest is bounded, and never forgets a picture it is holding")
    func interestIsBounded() {
        let cache = ShellPictures()
        cache.keep(plate, cost: mb, for: key(0), startedAt: 0)
        for n in 1 ..< (ShellPictures.remembered + 50) {
            _ = cache.picture(address(n), scale: 2, tier: .deck)
        }
        #expect(cache.interest.count <= ShellPictures.remembered)
        #expect(cache.interest[key(0)] != nil)
    }

    @Test("A dark network is classified apart from a refusal")
    func classifiesAbsence() {
        for code in [
            URLError.notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .dnsLookupFailed,
        ] {
            #expect(ShellPictures.absence(from: URLError(code)) == .unreachable)
        }
        #expect(ShellPictures.absence(from: URLError(.unsupportedURL)) == .refused)
        #expect(ShellPictures.absence(from: URLError(.badServerResponse)) == .refused)
        #expect(ShellPictures.absence(from: FixtureHTTPError.unmapped) == .refused)
    }

    @Test("Only an outage asks again")
    func onlyOutageAsksAgain() {
        #expect(ShellPictures.Absence.unreachable.asksAgain)
        #expect(!ShellPictures.Absence.refused.asksAgain)
        #expect(!ShellPictures.Absence.crowded.asksAgain)
    }

    // MARK: What the seam opened

    @Test("Several askers share one piece of work and one request")
    func askersShareOneRequest() async throws {
        let http = FixtureHTTP(["/1.png": .body(try picture(width: 32, height: 32, bits: 8))])
        let cache = ShellPictures(http: http)

        async let a: Void = cache.fetch(address(1), scale: 2, tier: .deck)
        async let b: Void = cache.fetch(address(1), scale: 2, tier: .deck)
        async let c: Void = cache.fetch(address(1), scale: 2, tier: .deck)
        _ = await (a, b, c)

        #expect(await http.requested.count == 1)
        #expect(cache.picture(address(1), scale: 2, tier: .deck) != nil)
        #expect(cache.inFlight.isEmpty)
        #expect(cache.heldBytes > 0)
    }

    @Test("A server that says no is a refusal, remembered and not asked again")
    func refusesNon2xx() async {
        let http = FixtureHTTP(["/1.png": .text("gone", status: 404)])
        let cache = ShellPictures(http: http)

        await cache.fetch(address(1), scale: 2, tier: .deck)
        #expect(cache.missing[key(1)] == .refused)

        await cache.fetch(address(1), scale: 2, tier: .deck)
        #expect(await http.requested.count == 1)
    }

    @Test("Bytes that are not a picture are a refusal too")
    func refusesUndecodableBody() async {
        let http = FixtureHTTP(["/1.png": .text("<html>not a picture</html>")])
        let cache = ShellPictures(http: http)
        await cache.fetch(address(1), scale: 2, tier: .deck)
        #expect(cache.missing[key(1)] == .refused)
    }

    @Test("A body past the cap is refused even when the server never said how big it was")
    func refusesOversizedBody() async {
        let huge = Data(count: ShellPictures.maxBytes + 1)
        let http = FixtureHTTP(["/1.png": .body(huge)])
        let cache = ShellPictures(http: http)
        await cache.fetch(address(1), scale: 2, tier: .deck)
        #expect(cache.missing[key(1)] == .refused)
        #expect(cache.picture(address(1), scale: 2, tier: .deck) == nil)
    }

    @Test("A dark network is recorded as an outage and asked for again")
    func retriesAfterAnOutage() async throws {
        let http = Flaky(png: try picture(width: 32, height: 32, bits: 8))
        let cache = ShellPictures(http: http)

        await cache.fetch(address(1), scale: 2, tier: .deck)
        #expect(cache.missing[key(1)] == .unreachable)
        #expect(cache.picture(address(1), scale: 2, tier: .deck) == nil)

        await cache.fetch(address(1), scale: 2, tier: .deck)
        #expect(cache.picture(address(1), scale: 2, tier: .deck) != nil)
        #expect(cache.missing.isEmpty)
        #expect(await http.count == 2)
    }

    @Test("An outage is never mistaken for a refusal")
    func outageIsNotRefusal() async {
        let cache = ShellPictures(http: Offline(code: .notConnectedToInternet))
        await cache.fetch(address(1), scale: 2, tier: .deck)
        #expect(cache.missing[key(1)] == .unreachable)
        #expect(cache.isMissing(address(1), scale: 2, tier: .deck))
    }

    @Test("Nothing is asked for twice: neither what is held nor what was refused")
    func fetchDoesNotRepeatItself() async {
        let cache = ShellPictures()
        cache.note(.refused, for: key(1))
        cache.keep(plate, cost: mb, for: key(2), startedAt: 0)

        await cache.fetch(address(1), scale: 2, tier: .deck)
        await cache.fetch(address(2), scale: 2, tier: .deck)
        await cache.fetch(nil, scale: 2, tier: .deck)

        #expect(cache.inFlight.isEmpty)
    }

    // MARK: Helpers

    /// A PNG of a flat colour at a chosen bit depth, made here so the decode has something real
    /// to read and the suite still never leaves the machine.
    private func picture(width: Int, height: Int, bits: Int) throws -> Data {
        let order: CGBitmapInfo = bits == 16 ? .byteOrder16Little : .byteOrder32Big
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bits,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | order.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let written = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            written, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        // Checked, because a false here is an empty `Data` and a puzzling nil two tests away.
        #expect(CGImageDestinationFinalize(destination))
        return written as Data
    }
}
