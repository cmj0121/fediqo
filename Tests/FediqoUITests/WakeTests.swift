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
@MainActor
@Suite("Waking the pictures")
struct WakeTests {
    private func address(_ n: Int) -> URL {
        URL(string: "https://example.test/\(n).png")!
    }

    private func key(_ n: Int) -> ShellPictures.Key {
        ShellPictures.Key(url: address(n), scale: 2, tier: .deck)
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
        cache.note(.unreachable, for: key(1))
        cache.note(.refused, for: key(2))
        cache.note(.crowded, for: key(3))

        #expect(cache.stranded == [key(1)])
    }

    // A server that said no will say no again, and a decline is terminal for the life of the
    // process by design. Asking for either is a request whose answer is already known.
    @Test("A refusal and a decline are never asked about again")
    func settledAnswersAreLeftAlone() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0..<20 {
            cache.note(n.isMultiple(of: 2) ? .refused : .crowded, for: key(n))
        }
        #expect(cache.stranded.isEmpty)
    }

    // A handful, not the whole cohort: the first answer that gets through clears the rest by
    // itself, so asking for all of them is a herd at somebody else's server for a fact one
    // request settles. The bound is the cache's own limit on what may be in the air at once.
    @Test("Never more at once than the cache was already willing to have in the air")
    func theKickIsBounded() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        for n in 0..<50 {
            cache.note(.unreachable, for: key(n))
        }
        #expect(cache.stranded.count == ShellPictures.maxInFlight)
        #expect(Set(cache.stranded).count == ShellPictures.maxInFlight)
    }

    @Test("Nothing to wake when nothing was written off")
    func nothingToWake() {
        let cache = ShellPictures(http: Flaky(dark: 0, png: Data()))
        #expect(cache.stranded.isEmpty)
    }

    /// The whole loop, driven through a client rather than modelled: a dark network strands a
    /// picture, the kick asks again, and the answer that comes back is what lets every other
    /// stranded row ask again — which is the generation bump, and the reason one kick is enough.
    @Test("A kick after the network comes back clears the whole cohort")
    func aKickEndsTheOutage() async throws {
        let http = Flaky(dark: 2, png: try png())
        let cache = ShellPictures(http: http)

        await cache.fetch(address(1), scale: 2, tier: .deck)
        await cache.fetch(address(2), scale: 2, tier: .deck)
        #expect(cache.missing[key(1)] == .unreachable)
        #expect(cache.missing[key(2)] == .unreachable)
        let before = cache.generation

        let stranded = cache.stranded
        #expect(stranded.count == 2)
        // One of them is enough: the arrival clears the cohort and tells every view to try again.
        let first = try #require(stranded.first)
        await cache.fetch(first.url, scale: first.scale, tier: first.tier)

        #expect(cache.picture(first.url, scale: 2, tier: .deck) != nil)
        #expect(cache.missing.isEmpty)
        #expect(cache.generation == before + 1)
        #expect(cache.stranded.isEmpty)
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
