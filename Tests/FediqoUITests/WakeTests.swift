import CoreGraphics
import FediqoCore
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import FediqoUI

/// The kick that starts an outage recovery. The cache can finish one and cannot begin one: every
/// stranded row re-asks the moment any fetch gets through, and nothing inside the cache can
/// produce that first success. This is the half that lives outside it.
///
/// **The wake is asked of what a screen draws, not of the cache as a whole**, because a `Key`
/// carries no host — decision 19 put the source in a set on the entry — and a fetch needs one to
/// file its answer under. The screen has `item.source.host` beside every address it draws, so the
/// screen hands both halves over as `DrawnPicture`s and the cache says which of them an outage
/// wrote off.
@MainActor
@Suite("Waking the pictures")
struct WakeTests {
    private let alpha = "alpha.test"
    private let beta = "beta.test"

    private func address(_ n: Int) -> URL {
        URL(string: "https://example.test/\(n).png")!
    }

    private func key(_ n: Int) -> ShellPictures.Key {
        ShellPictures.Key(url: address(n), scale: 2, tier: .deck)
    }

    /// What a screen would hand over for rows it is drawing, all from one source.
    private func drawn(_ range: Range<Int>, host: String? = nil) -> [DrawnPicture] {
        range.map { DrawnPicture(url: address($0), host: host ?? alpha) }
    }

    /// A row that drew, found nothing, and had the reason written down — in that order, which is
    /// the order the app does it in. `RemoteImage.body` reads before its `.task` fetches, so a
    /// key with a mark against it has always been stamped first; a test that only calls `note`
    /// builds a state the app cannot produce, and the `interest` guard would rightly skip it.
    private func drewAndLost(_ cache: ShellPictures, _ n: Int, _ absence: ShellPictures.Absence) {
        _ = cache.picture(address(n), scale: 2, tier: .deck, host: alpha)
        cache.note(absence, for: key(n))
    }

    /// Dark for as long as it is told to be, then answering. The outage and its end, without one.
    private actor Flaky: HTTPClient {
        private var dark: Int
        private let png: Data
        private(set) var count = 0

        init(dark: Int, png: Data) {
            self.dark = dark
            self.png = png
        }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            count += 1
            if dark > 0 {
                dark -= 1
                throw URLError(.notConnectedToInternet)
            }
            return (png, HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!)
        }
    }

    @Test("Only an outage is worth asking about again")
    func strandedIsOnlyTheOutage() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        drewAndLost(cache, 1, .unreachable)
        drewAndLost(cache, 2, .refused)
        drewAndLost(cache, 3, .crowded)

        #expect(cache.stranded(among: drawn(1 ..< 4), scale: 2, from: 0) == drawn(1 ..< 2))
    }

    // A server that said no will say no again, and a decline is terminal for the life of the
    // process by design. Asking for either is a request whose answer is already known.
    @Test("A refusal and a decline are never asked about again")
    func settledAnswersAreLeftAlone() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0 ..< 20 {
            drewAndLost(cache, n, n.isMultiple(of: 2) ? .refused : .crowded)
        }
        #expect(cache.stranded(among: drawn(0 ..< 20), scale: 2, from: 0).isEmpty)
    }

    /// **The reason the filter is `.unreachable` and not "there is no picture here".** A screen's
    /// addresses arrive in a fixed order, so a bound applied before the filter would take the
    /// same first few on every activation — and a screen whose first few absences are refusals
    /// would then wake nothing at all, forever. The one stranded row is at the back on purpose.
    @Test("A screen whose first rows are refusals still wakes the one that was stranded")
    func settledAnswersDoNotSpendTheBudget() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0 ..< 12 {
            drewAndLost(cache, n, .refused)
        }
        drewAndLost(cache, 12, .unreachable)

        #expect(cache.stranded(among: drawn(0 ..< 13), scale: 2, from: 0) == drawn(12 ..< 13))
    }

    // A handful, not the whole cohort: the first answer that gets through clears the rest by
    // itself, so asking for all of them is a herd at somebody else's server for a fact one
    // request settles. The bound is the cache's own limit on what may be in the air at once.
    @Test("Never more at once than the cache was already willing to have in the air")
    func theKickIsBounded() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0 ..< 50 {
            drewAndLost(cache, n, .unreachable)
        }
        let woken = cache.stranded(among: drawn(0 ..< 50), scale: 2, from: 0)
        #expect(woken.count == ShellPictures.maxInFlight)
        #expect(Set(woken).count == ShellPictures.maxInFlight)
    }

    /// One address is one request however many rows are drawing it — `work` folds the second
    /// asker into the first's task — so the bound counts addresses. The source that misses out
    /// loses nothing: its own row tags the entry on the read that follows the arrival.
    @Test("One address drawn by two sources spends one of the handful, not two")
    func oneAddressIsOneRequest() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0 ..< 4 {
            drewAndLost(cache, n, .unreachable)
        }
        let both = drawn(0 ..< 1, host: alpha) + drawn(0 ..< 1, host: beta) + drawn(1 ..< 4)
        let woken = cache.stranded(among: both, scale: 2, from: 0)

        #expect(woken.count == ShellPictures.maxInFlight)
        #expect(woken.map(\.url) == (0 ..< 4).map(address))
        #expect(woken.first == DrawnPicture(url: address(0), host: alpha))
    }

    /// The wake is asked of a screen, so a stranded address nothing is drawing is not woken —
    /// which is the whole point of the view-side shape. A key nobody has read carries no
    /// `interest`, so a fetch for it can evict nothing and on a full cache is declined and marked
    /// `.crowded`, terminal for the life of the process. A global wake could strand pictures
    /// nobody was even looking at.
    @Test("A stranded address no screen is drawing is left alone")
    func offScreenIsNotWoken() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0 ..< 10 {
            drewAndLost(cache, n, .unreachable)
        }
        #expect(cache.stranded(among: drawn(0 ..< 2), scale: 2, from: 0) == drawn(0 ..< 2))
        #expect(cache.stranded(among: [], scale: 2, from: 0).isEmpty)
    }

    /// A key carries the screen's scale, so a window dragged onto another display wants keys
    /// nobody has asked for — and those carry no mark, stranded or otherwise.
    @Test("The mark belongs to a scale, and the wake asks at the screen's own")
    func theWakeAsksAtTheScreensScale() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        drewAndLost(cache, 1, .unreachable)
        #expect(cache.stranded(among: drawn(1 ..< 2), scale: 2, from: 0) == drawn(1 ..< 2))
        #expect(cache.stranded(among: drawn(1 ..< 2), scale: 1, from: 0).isEmpty)
    }

    @Test("Nothing to wake when nothing was written off")
    func nothingToWake() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        #expect(cache.stranded(among: drawn(0 ..< 8), scale: 2, from: 0).isEmpty)
    }


    /// **The property an ordered list took away, restored.** A screen's addresses are stable, so
    /// a bound applied from a fixed start asks after the same handful for ever: four addresses on
    /// a CDN that stays dark would be the whole of every activation, while a fifth on a CDN that
    /// has come back sits behind them — never asked, and never re-asking on its own either, since
    /// with no success there is no `forgetUnreachable`, no generation bump, and a mounted row's
    /// `.task` identity does not change. The global version this replaces was saved from it by
    /// the arbitrariness of `Dictionary.keys`.
    @Test("Two activations against the same screen do not ask after the same handful")
    func theHandfulIsRedrawnEachTime() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0 ..< 5 {
            drewAndLost(cache, n, .unreachable)
        }
        let screen = drawn(0 ..< 5)

        let first = cache.stranded(among: screen, scale: 2, from: 0)
        let second = cache.stranded(among: screen, scale: 2, from: first.count)

        #expect(first.count == ShellPictures.maxInFlight)
        #expect(second.count == ShellPictures.maxInFlight)
        #expect(Set(first) != Set(second), "the same handful came back a second time")
    }

    /// And the guarantee that makes the rotation worth having: every stranded address is reached,
    /// within a number of activations the eligible count and the bound decide between them.
    @Test(
        "Every stranded address is reached within a bounded number of activations",
        arguments: [5, 6, 9, 17]
    )
    func everyStrandedAddressIsReached(rows: Int) {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0 ..< rows {
            drewAndLost(cache, n, .unreachable)
        }
        let screen = drawn(0 ..< rows)

        // Not vacuous: more stranded than one activation can ask about.
        #expect(rows > ShellPictures.maxInFlight)

        var cursor = 0
        var asked: Set<URL> = []
        let bound = (rows + ShellPictures.maxInFlight - 1) / ShellPictures.maxInFlight
        for _ in 0 ..< bound {
            let woken = cache.stranded(among: screen, scale: 2, from: cursor)
            cursor += woken.count
            asked.formUnion(woken.map(\.url))
        }

        #expect(
            asked.count == rows,
            "after \(bound) activations, \(rows - asked.count) were never asked about"
        )
    }

    /// The `interest` guard, and the damage it exists to prevent. A screen hands over its whole
    /// list rather than the rows actually on screen, so an address nothing has drawn in a long
    /// while can still be in `drawn` — and `trimInterest` will have dropped its stamp. A fetch for
    /// it would arrive with a stamp of zero, evict nothing, and on a full cache be declined and
    /// marked `.crowded`, which is terminal for the life of the process.
    @Test("An address whose stamp has been trimmed away is not woken")
    func aTrimmedStampIsNotWoken() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        drewAndLost(cache, 1, .unreachable)
        #expect(cache.stranded(among: drawn(1 ..< 2), scale: 2, from: 0) == drawn(1 ..< 2))

        // Push the interest map far past its bound with keys nothing is holding a picture for,
        // which is what a reader scrolling a long way does.
        for n in 10_000 ..< (10_000 + ShellPictures.remembered * 3) {
            _ = cache.picture(address(n), scale: 2, tier: .deck, host: alpha)
        }

        #expect(cache.interest[key(1)] == nil, "the stamp survived; this test measures nothing")
        #expect(cache.missing[key(1)] == .unreachable, "the mark went too; this measures nothing")
        #expect(cache.stranded(among: drawn(1 ..< 2), scale: 2, from: 0).isEmpty)
    }

    /// The whole loop, driven through a client rather than modelled: a dark network strands a
    /// picture, the kick asks again, and the answer that comes back is what lets every other
    /// stranded row ask again — which is the generation bump, and the reason one kick is enough.
    ///
    /// It also pins the half of the wake that only exists once a source is carried: what lands is
    /// filed under the server the screen said it was drawn through, so the reader's Clear button
    /// can reach it. See `ShellPictures`, I10.
    @Test("A kick after the network comes back clears the whole cohort")
    func aKickEndsTheOutage() async throws {
        let http = Flaky(dark: 2, png: try png())
        let cache = ShellPictures(http: http)

        // Read first, then fetch, which is the order `RemoteImage` does it in and the order the
        // `interest` guard in `stranded` is written against.
        _ = cache.picture(address(1), scale: 2, tier: .deck, host: alpha)
        _ = cache.picture(address(2), scale: 2, tier: .deck, host: alpha)
        await cache.fetch(address(1), scale: 2, tier: .deck, host: alpha)
        await cache.fetch(address(2), scale: 2, tier: .deck, host: alpha)
        #expect(cache.missing[key(1)] == .unreachable)
        #expect(cache.missing[key(2)] == .unreachable)
        let before = cache.generation

        let stranded = cache.stranded(among: drawn(1 ..< 3), scale: 2, from: 0)
        #expect(stranded.count == 2)
        // One of them is enough: the arrival clears the cohort and tells every view to try again.
        let first = try #require(stranded.first)
        await cache.fetch(first.url, scale: 2, tier: .deck, host: first.host)

        // **Before the read below, not after.** `picture(…)` tags the entry with the host it is
        // read under, so asking it first would insert `alpha` itself and an implementation that
        // filed nothing on arrival would still pass. What is pinned here is that `keep` filed it,
        // which is only visible while nothing has read it back.
        #expect(cache.sources[ShellPictures.Key(url: first.url, scale: 2, tier: .deck)] == [alpha])
        #expect(cache.picture(first.url, scale: 2, tier: .deck, host: alpha) != nil)
        #expect(cache.missing.isEmpty)
        #expect(cache.generation == before + 1)
        #expect(cache.stranded(among: drawn(1 ..< 3), scale: 2, from: 0).isEmpty)
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }
}
