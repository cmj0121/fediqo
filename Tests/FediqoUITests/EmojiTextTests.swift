import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FediqoCore
@testable import FediqoUI

// MARK: - Pictures a test can make

/// Synthetic files, so that every decode in this suite is decidable and none of it is a socket.
enum EmojiFixture {
    /// An animated GIF of `delays.count` frames at the given size, each frame standing for the
    /// delay beside it.
    static func gif(delays: [Double], width: Int = 32, height: Int = 32) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, delays.count, nil
        )!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (index, delay) in delays.enumerated() {
            let frame = square(width: width, height: height, grey: CGFloat(index) / CGFloat(delays.count))
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A still PNG at the given depth, so the normalisation can be checked against a source that
    /// really does carry sixteen bits a channel.
    static func png(width: Int = 64, height: Int = 64, bitsPerComponent: Int = 8,
                    space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> Data {
        let image = square(width: width, height: height, grey: 0.5,
                           bitsPerComponent: bitsPerComponent, space: space)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A multi-image TIFF whose frames disagree about their size — the shape a hostile instance
    /// uses to put a tiny frame first and an enormous one behind it.
    static func tiff(sizes: [(width: Int, height: Int)]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, sizes.count, nil
        )!
        for size in sizes {
            CGImageDestinationAddImage(destination,
                                       square(width: size.width, height: size.height, grey: 0.5),
                                       nil)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func square(width: Int, height: Int, grey: CGFloat, bitsPerComponent: Int = 8,
                       space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if bitsPerComponent == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                                space: space, bitmapInfo: info)!
        context.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

/// Spins — never sleeps — until a condition holds or the spin runs out, so a test can wait for a
/// task to reach a gate without a timer. Bounded, so a mistake fails the test instead of hanging
/// it.
@MainActor
func spin(until reached: () async -> Bool) async {
    var spins = 0
    while !(await reached()), spins < 10_000 {
        await Task.yield()
        spins += 1
    }
}

/// A client that holds every request open until it is let go, so a test can do something to the
/// cache while a fetch is genuinely in flight.
actor HeldHTTP: HTTPClient {
    private let body: Data
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var requested = 0

    init(body: Data) { self.body = body }

    var waiting: Int { gates.count }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requested += 1
        await withCheckedContinuation { gates.append($0) }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                      headerFields: nil)!)
    }

    func release() {
        for gate in gates { gate.resume() }
        gates = []
    }
}

// MARK: - The clock

@Suite("The emoji clock")
struct EmojiClockTests {
    @Test("A frame that says nothing stands for the tenth every renderer gives it")
    func aSilentFrameGetsTheStandIn() {
        #expect(EmojiClock.step(declared: 0) == EmojiClock.standIn)
        #expect(EmojiClock.step(declared: 0.001) == EmojiClock.standIn)
        #expect(EmojiClock.step(declared: 0.05) == 0.05)
        #expect(EmojiClock.step(declared: 1.5) == 1.5)
    }

    @Test("Ends are the delays added up, per frame and not at one rate")
    func endsAreCumulative() {
        let ends = EmojiClock.ends(from: [0.1, 0.2, 0.05])
        #expect(ends.count == 3)
        #expect(abs(ends[0] - 0.1) < 1e-9)
        #expect(abs(ends[1] - 0.3) < 1e-9)
        #expect(abs(ends[2] - 0.35) < 1e-9)
        #expect(EmojiClock.ends(from: []).isEmpty)
    }

    @Test("The frame standing at an instant is the one whose end it has not reached")
    func theRightFrameStandsAtAnInstant() {
        let ends = EmojiClock.ends(from: [0.1, 0.4, 0.5])
        #expect(EmojiClock.index(at: 0, ends: ends) == 0)
        #expect(EmojiClock.index(at: 0.09, ends: ends) == 0)
        #expect(EmojiClock.index(at: 0.1, ends: ends) == 1)
        #expect(EmojiClock.index(at: 0.49, ends: ends) == 1)
        #expect(EmojiClock.index(at: 0.5, ends: ends) == 2)
        #expect(EmojiClock.index(at: 0.99, ends: ends) == 2)
    }

    @Test("A wall clock is folded back into the loop, forwards and backwards")
    func theLoopWrapsAWallClock() {
        let ends = EmojiClock.ends(from: [0.1, 0.4, 0.5])
        #expect(EmojiClock.index(at: 1.0, ends: ends) == 0)
        #expect(EmojiClock.index(at: 1.45, ends: ends) == 1)
        #expect(EmojiClock.index(at: 700_000.05, ends: ends) == 0)
        #expect(EmojiClock.index(at: -0.05, ends: ends) == 2)
    }

    @Test("One frame never asks which frame it is")
    func aStillIsAlwaysFrameZero() {
        #expect(EmojiClock.index(at: 12.3, ends: [0.1]) == 0)
        #expect(EmojiClock.index(at: 12.3, ends: []) == 0)
        #expect(EmojiClock.index(at: 12.3, ends: [0, 0]) == 0)
    }

    @Test("The clock runs at the file's own rate, floored so nothing can ask for a thousand a second")
    func theClockFollowsTheFile() {
        #expect(EmojiClock.tick(shortestFrame: 0.1) == 0.1)
        #expect(EmojiClock.tick(shortestFrame: 0.04) == 0.04)
        #expect(EmojiClock.tick(shortestFrame: 0.001) == EmojiClock.fastestTick)
        #expect(EmojiClock.tick(shortestFrame: 0) == EmojiClock.fastestTick)
    }

    @Test("A line's shortest frame is what its clock is set by")
    func framesReportTheirShortestStep() {
        let uneven = EmojiCache.Frames(images: [], ends: EmojiClock.ends(from: [0.3, 0.02, 0.3]), bytes: 0)
        #expect(abs(uneven.shortestFrame - 0.02) < 0.0001)
        #expect(EmojiCache.Frames(images: [], ends: [0.1], bytes: 0).shortestFrame == 0)
    }
}

// MARK: - The ink a line gives a picture

@Suite("The ink of a line")
struct EmojiMetricsTests {
    @Test("A picture is as tall as the ink, not as tall as the point size")
    func inkIsAscenderToDescender() {
        let metrics = EmojiCache.metrics(ascender: 13.4, descender: -3.6)
        #expect(metrics.side == 17)
        #expect(metrics.baseline == -4)
    }

    @Test("A font with no ink still gives a picture one point to stand in")
    func theSideHasAFloor() {
        #expect(EmojiCache.metrics(ascender: 0, descender: 0).side == 1)
    }

    @Test("The system's own font gives a taller ink than the point size, and sits below the baseline")
    func theSystemFontAgrees() {
        let small = EmojiCache.metrics(points: 12)
        let large = EmojiCache.metrics(points: 28)
        #expect(small.side > 12)
        #expect(large.side > small.side)
        #expect(small.baseline < 0)
    }

    @Test("A role's font, its ink and its token are one statement")
    func theRolePinsBothEdges() {
        // One edge: the role is drawn in the token the type scale sets.
        #expect(EmojiTextRole.name.font == ShellType.name)
        #expect(EmojiTextRole.body.font == ShellType.body)
        #expect(EmojiTextRole.meta.font == ShellType.meta)
        // Those three are the whole guard, and they bite: `font` is *built from* `textStyle`,
        // which is also what `platformStyle` — and so the ink the picture is decoded at — is
        // derived from. Move a role to a different style in `ShellType` alone and they fail.
        // Restating that construction here would only be asserting the implementation against
        // itself, so it is not restated.
        #expect(Set(EmojiTextRole.allCases.map(\.textStyle)).count == EmojiTextRole.allCases.count)
    }

    @Test("The picture is set in the same points as the letters beside it")
    func pointsFollowThePlatform() {
        for role in EmojiTextRole.allCases {
            #expect(EmojiTextRole.points(for: role, at: .large) > 0)
        }
        #expect(EmojiTextRole.points(for: .name, at: .large) > EmojiTextRole.points(for: .meta, at: .large))
        #if os(macOS)
        // SwiftUI on macOS pins a semantic `Font` at every rung — `Font.body` renders at 16.0
        // from xSmall to accessibility5 — so a picture that grew with the reader's setting grew
        // alone, up to 3.1× the letters. Where the letters do not move, the picture does not.
        for role in EmojiTextRole.allCases {
            let smallest = EmojiTextRole.points(for: role, at: .xSmall)
            for size in DynamicTypeSize.allCases {
                #expect(EmojiTextRole.points(for: role, at: size) == smallest)
            }
        }
        #else
        // UIKit does move, and is asked exactly rather than approximated by a single multiple.
        for role in EmojiTextRole.allCases {
            #expect(EmojiTextRole.points(for: role, at: .accessibility1)
                > EmojiTextRole.points(for: role, at: .large))
        }
        #endif
    }

    @Test("How tall a picture is decoded is clamped whatever the screen says")
    func theDecodedHeightIsClamped() {
        let huge = EmojiCache.Request(emojis: [], metrics: .init(side: 4000, baseline: -2),
                                      scale: 3, host: "h", still: false)
        #expect(huge.pixels == EmojiCache.maxDrawnPixelSide)
        let ordinary = EmojiCache.Request(emojis: [], metrics: .init(side: 20, baseline: -4),
                                          scale: 2, host: "h", still: false)
        #expect(ordinary.pixels == 40)
        let nothing = EmojiCache.Request(emojis: [], metrics: .init(side: 0, baseline: 0),
                                         scale: 0, host: "h", still: false)
        #expect(nothing.pixels == 1)
    }
}

// MARK: - The property the file exists for

@Suite("A picture stands as tall as the letters")
struct EmojiDrawnHeightTests {
    @Test("A square picture is drawn at the line's ink, whatever size the source was")
    func squaresLandOnTheInk() {
        #expect(EmojiCache.drawnHeight(sourceWidth: 32, sourceHeight: 32, side: 45) == 45)
        #expect(EmojiCache.drawnHeight(sourceWidth: 512, sourceHeight: 512, side: 45) == 45)
        #expect(EmojiCache.drawnHeight(sourceWidth: 64, sourceHeight: 64, side: 14) == 14)
    }

    @Test("A banner is capped by its width and comes out shorter than the ink")
    func bannersAreCappedByWidth() {
        // 50:1 against a bound of 3:1 — the height gives way, not the bound.
        let height = EmojiCache.drawnHeight(sourceWidth: 500, sourceHeight: 10, side: 192)
        #expect(abs(height - 192 * 3 / 50) < 0.001)
        #expect(height * 50 <= 192 * EmojiCache.maxDrawnAspect + 0.001)
        // Exactly at the bound nothing gives way.
        #expect(EmojiCache.drawnHeight(sourceWidth: 90, sourceHeight: 30, side: 40) == 40)
    }

    @Test("A picture too short to see is refused, so the shortcode stands instead")
    func avanishinglyShortPictureIsRefused() {
        // Height is only ever given up to the aspect cap, so a quarter of the ink is exactly
        // "wider than twelve to one".
        #expect(EmojiCache.isVisible(drawnHeight: 20, side: 20))
        #expect(EmojiCache.isVisible(drawnHeight: 5, side: 20))
        #expect(!EmojiCache.isVisible(drawnHeight: 4.99, side: 20))
        #expect(!EmojiCache.isVisible(drawnHeight: 0.14, side: 20))
        #expect(!EmojiCache.isVisible(drawnHeight: 20, side: 0))
        // The two shapes that measured 0.14pt and 0.38pt tall.
        #expect(!EmojiCache.isVisible(
            drawnHeight: EmojiCache.drawnHeight(sourceWidth: 1024, sourceHeight: 1, side: 20),
            side: 20))
        #expect(!EmojiCache.isVisible(
            drawnHeight: EmojiCache.drawnHeight(sourceWidth: 500, sourceHeight: 1, side: 20),
            side: 20))
        // Twelve to one is the edge, and a three-to-one banner is still drawn.
        #expect(EmojiCache.isVisible(
            drawnHeight: EmojiCache.drawnHeight(sourceWidth: 12, sourceHeight: 1, side: 20),
            side: 20))
        #expect(EmojiCache.isVisible(
            drawnHeight: EmojiCache.drawnHeight(sourceWidth: 3, sourceHeight: 1, side: 20),
            side: 20))
    }

    @Test("A tall picture keeps the ink, because height is what the line fixes")
    func tallPicturesKeepTheInk() {
        #expect(EmojiCache.drawnHeight(sourceWidth: 10, sourceHeight: 500, side: 40) == 40)
    }

    @Test("The scale is read off the frame that came back, not off the screen")
    func theScaleComesFromTheFrame() {
        // A 32-pixel frame drawn 45 points tall needs a scale of 32/45, not the screen's 2 or 3.
        #expect(abs(EmojiCache.imageScale(pixelHeight: 32, points: 45) - 32.0 / 45.0) < 1e-12)
        #expect(EmojiCache.imageScale(pixelHeight: 90, points: 45) == 2)
        #expect(abs(EmojiCache.imageScale(pixelHeight: 0, points: 45) - 1.0 / 45.0) < 1e-12)
        #expect(EmojiCache.imageScale(pixelHeight: 32, points: 0) == 1)
        // What the scale is for: a frame of this many pixels comes out this many points tall.
        for pixels in [8, 32, 64, 192] {
            let points: CGFloat = 45
            #expect(abs(CGFloat(pixels) / EmojiCache.imageScale(pixelHeight: pixels, points: points)
                - points) < 1e-9)
        }
    }

    @Test("A source smaller than the line is still drawn at the line's ink")
    func aSmallSourceIsNotLeftSmall() throws {
        // What Mastodon serves: a 32x32 emoji, and it does not resize an upload. ImageIO never
        // upscales, so the frame comes back 32 pixels however tall the line asked for — and the
        // line must still draw it at the ink beside it.
        let decoded = try #require(EmojiCache.decode(EmojiFixture.png(width: 32, height: 32),
                                                     ink: 135, stillOnly: false))
        #expect(decoded.images[0].height == 32)
        #expect(EmojiCache.Frames(decoded, side: 45).drawnHeight == 45)
    }

    @Test("A source larger than the line is drawn at the line's ink too")
    func aLargeSourceIsBroughtDown() throws {
        let decoded = try #require(EmojiCache.decode(EmojiFixture.png(width: 512, height: 512),
                                                     ink: 40, stillOnly: false))
        #expect(decoded.images[0].height == 40)
        #expect(EmojiCache.Frames(decoded, side: 20).drawnHeight == 20)
    }

    @Test("A wide source drawn in a line keeps its shape and respects the width bound")
    func aWideSourceKeepsItsShape() throws {
        let decoded = try #require(EmojiCache.decode(EmojiFixture.png(width: 500, height: 10),
                                                     ink: 192, stillOnly: false))
        let frames = EmojiCache.Frames(decoded, side: 64)
        #expect(frames.drawnHeight < 64)
        #expect(frames.drawnHeight * 50 <= 64 * EmojiCache.maxDrawnAspect + 0.001)
    }
}

// MARK: - Decoding, and the bounds on it

// Serialized because `clippingIsCountedForADeveloper` and `theFrameCountIsBounded` both move
// `clippedForFrameCount`. A concurrent bump could only ever carry that assertion, never fail it,
// but the fix costs nothing.
@Suite("Decoding an emoji", .serialized)
struct EmojiDecodeTests {
    @Test("Every frame is decoded, and each one keeps its own delay")
    func perFrameDelaysAreHonoured() throws {
        let data = EmojiFixture.gif(delays: [0.1, 0.4, 0.05])
        let decoded = try #require(EmojiCache.decode(data, ink: 32, stillOnly: false))
        #expect(decoded.images.count == 3)
        #expect(decoded.ends.count == 3)
        #expect(abs(decoded.ends[0] - 0.1) < 0.01)
        #expect(abs(decoded.ends[1] - 0.5) < 0.01)
        #expect(abs(decoded.ends[2] - 0.55) < 0.01)
    }

    @Test("A frame the file gave no time is given the tenth every renderer gives it")
    func aFrameWithNoDelayGetsTheStandIn() throws {
        let decoded = try #require(EmojiCache.decode(EmojiFixture.gif(delays: [0, 0]), ink: 32, stillOnly: false))
        #expect(abs(decoded.ends[1] - 2 * EmojiClock.standIn) < 0.01)
    }

    @Test("More frames than the bound are refused, and the first one is drawn instead")
    func theFrameCountIsBounded() throws {
        let many = EmojiFixture.gif(delays: Array(repeating: 0.02, count: EmojiCache.maxFramesPerEmoji + 1),
                                    width: 8, height: 8)
        let decoded = try #require(EmojiCache.decode(many, ink: 16, stillOnly: false))
        #expect(decoded.images.count == 1)

        let just = EmojiFixture.gif(delays: Array(repeating: 0.02, count: EmojiCache.maxFramesPerEmoji),
                                    width: 8, height: 8)
        #expect(EmojiCache.decode(just, ink: 16, stillOnly: false)?.images.count == EmojiCache.maxFramesPerEmoji)
    }

    @Test("A reader who asked for less motion gets one frame out of a moving file")
    func stillOnlyDecodesOneFrame() throws {
        let decoded = try #require(EmojiCache.decode(EmojiFixture.gif(delays: [0.1, 0.1, 0.1]),
                                                     ink: 32, stillOnly: true))
        #expect(decoded.images.count == 1)
        #expect(decoded.ends.count == 1)
    }

    @Test("A source larger than an emoji can be is refused before it is decoded")
    func anOversizedSourceIsRefused() {
        let over = EmojiCache.maxSourcePixelSide + 1
        #expect(EmojiCache.decode(EmojiFixture.png(width: over, height: 8), ink: 32, stillOnly: false) == nil)
        #expect(EmojiCache.decode(EmojiFixture.png(width: 8, height: over), ink: 32, stillOnly: false) == nil)
        #expect(EmojiCache.decode(EmojiFixture.png(width: EmojiCache.maxSourcePixelSide,
                                                   height: EmojiCache.maxSourcePixelSide),
                                  ink: 32, stillOnly: false) != nil)
    }

    @Test("A container that hides an enormous frame behind a tiny one is refused too")
    func everyFrameIsMeasuredNotJustTheFirst() {
        let over = EmojiCache.maxSourcePixelSide + 1
        // The shape a hostile instance uses: frame 0 passes, frame 1 is the decode it wanted.
        let smuggled = EmojiFixture.tiff(sizes: [(8, 8), (over, over)])
        #expect(EmojiCache.decode(smuggled, ink: 32, stillOnly: false) == nil)
        // Asking for the still only decodes frame 0, so only frame 0 has to be within bounds.
        #expect(EmojiCache.decode(smuggled, ink: 32, stillOnly: true) != nil)
        // And frames that merely differ in size, both within bounds, are still fine: an
        // optimised GIF stores sub-rectangles, so disagreement on its own is not an attack.
        #expect(EmojiCache.decode(EmojiFixture.tiff(sizes: [(32, 32), (16, 16)]),
                                  ink: 32, stillOnly: false) != nil)
    }

    #if DEBUG
    @Test("A file clipped to a still is counted, so a wrong ceiling surfaces in development")
    func clippingIsCountedForADeveloper() {
        // Monotonic, and other suites decode too, so the assertion is that it moved rather than
        // that it landed on a number.
        let before = EmojiCache.clippedForFrameCount.withLock { $0 }
        let tooMany = EmojiFixture.gif(delays: Array(repeating: 0.02,
                                                     count: EmojiCache.maxFramesPerEmoji + 1),
                                       width: 8, height: 8)
        _ = EmojiCache.decode(tooMany, ink: 16, stillOnly: false)
        #expect(EmojiCache.clippedForFrameCount.withLock { $0 } > before)
    }
    #endif

    @Test("Something that is not a picture is not a picture")
    func rubbishIsRefused() {
        #expect(EmojiCache.decode(Data("not a picture".utf8), ink: 32, stillOnly: false) == nil)
        #expect(EmojiCache.decode(Data(), ink: 32, stillOnly: false) == nil)
    }

    @Test("A sixteen-bit source is normalised, so the pixel cap really is a byte cap")
    func sixteenBitsAreNormalisedToEight() throws {
        let deep = EmojiFixture.png(width: 128, height: 128, bitsPerComponent: 16)
        let decoded = try #require(EmojiCache.decode(deep, ink: 64, stillOnly: false))
        #expect(decoded.images[0].bitsPerComponent == 8)
        #expect(decoded.bytes <= 64 * 64 * 4 + 64 * 4)
    }

    @Test("An eight-bit source is left exactly as it came off the decoder")
    func eightBitsAreUntouched() throws {
        let decoded = try #require(EmojiCache.decode(EmojiFixture.png(width: 128, height: 128),
                                                     ink: 64, stillOnly: false))
        #expect(decoded.images[0].bitsPerComponent == 8)
    }

    @Test("A wide-gamut source stays wide-gamut")
    func displayP3Survives() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let wide = EmojiFixture.png(width: 128, height: 128, bitsPerComponent: 16, space: space)
        let decoded = try #require(EmojiCache.decode(wide, ink: 64, stillOnly: false))
        #expect(decoded.images[0].colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test("No frame this will ever decode is larger than the bound the budget is stated in")
    func noFrameExceedsTheFrameBound() throws {
        for (width, height) in [(1024, 1024), (1024, 342), (500, 10), (32, 32), (10, 1000)] {
            let decoded = try #require(EmojiCache.decode(EmojiFixture.png(width: width, height: height),
                                                         ink: EmojiCache.maxDrawnPixelSide,
                                                         stillOnly: false))
            #expect(decoded.bytes <= EmojiCache.maxFrameBytes)
        }
    }
}

// MARK: - The cache

@MainActor
@Suite("The emoji cache")
struct EmojiCacheTests {
    private static func emoji(_ shortcode: String, still: String? = nil) -> CustomEmoji {
        CustomEmoji(shortcode: shortcode,
                    url: URL(string: "https://example.test/\(shortcode).gif")!,
                    staticURL: still.map { URL(string: "https://example.test/\($0).png")! })
    }

    private static func request(_ emojis: [CustomEmoji], host: String = "example.test",
                                still: Bool = false) -> EmojiCache.Request {
        EmojiCache.Request(emojis: emojis, metrics: .init(side: 20, baseline: -4),
                           scale: 2, host: host, still: still)
    }

    @Test("The bounds are mutually consistent, so no admissible entry can evict itself")
    func theBoundsAreMutuallyConsistent() {
        let worst = EmojiCache.entryOverhead + EmojiCache.maxFrameBytes * EmojiCache.maxFramesPerEmoji
        #expect(worst <= EmojiCache.lowWaterBytes)
        #expect(EmojiCache.lowWaterBytes < EmojiCache.maxCachedBytes)
        #expect(EmojiCache.maxFrameBytes
            == EmojiCache.maxDrawnPixelSide
            * Int((CGFloat(EmojiCache.maxDrawnPixelSide) * EmojiCache.maxDrawnAspect).rounded()) * 4)
    }

    @Test("The ceiling clears the content that really exists, which nothing pinned before")
    func theCeilingClearsRealContent() {
        // The inequality pins the ceiling from above. Nothing pinned it from below, which is
        // exactly how 40 came to exclude a real shape and stay that way: real custom emoji are
        // one- to two-second loops at 10-25 fps, so fifty frames is the realistic worst case and
        // the ceiling must clear it or the budget has been solved at the cost of content nobody
        // noticed losing.
        #expect(EmojiCache.maxFramesPerEmoji >= 50)
        // And three seconds of this app's own 20 fps clock, which is where 60 comes from.
        #expect(EmojiCache.maxFramesPerEmoji >= 60)
    }

    @Test("The pixel cap is solved against the ladder, from both directions")
    func thePixelCapIsPinnedToTheLadder() {
        // The preference reaches exactly this rung and no further; if it grows one, or Apple
        // adds one, this is what has to be looked at again.
        #expect(DummyFontSize.allCases.map(\.dynamicType).max() == .accessibility1)
        // The body point size at that rung. Stated rather than asked, because on macOS the
        // ladder is pinned by the platform and the number that has to be guarded is iOS's.
        let reachable = EmojiCache.metrics(points: 28).side * Self.maxDisplayScale

        // From below: a cap under the reachable ink makes every emoji soft at the largest text.
        #expect(CGFloat(EmojiCache.maxDrawnPixelSide) >= reachable)
        // From above: this is a term in a worst-case inequality, not a clamp, so headroom is paid
        // by every animated file in frames it may not have. A small multiple, and no more.
        #expect(CGFloat(EmojiCache.maxDrawnPixelSide) <= reachable * 2)

        #if !os(macOS)
        // Where the platform does move, the same number can be asked of it rather than stated.
        let live = DummyFontSize.allCases
            .map { EmojiCache.metrics(points: EmojiTextRole.points(for: .body, at: $0.dynamicType)).side }
            .max() ?? 0
        #expect(live * Self.maxDisplayScale == reachable)
        #endif
    }

    /// The largest screen this app is built for.
    private static let maxDisplayScale: CGFloat = 3

    @Test("What is held is counted in bytes, not in entries")
    func bytesAreWhatIsCounted() {
        let cache = EmojiCache(http: FixtureHTTP())
        let one = Self.emoji("a")
        let request = Self.request([one])
        cache.store(EmojiCache.Frames(images: [], ends: [], bytes: 4096), for: request.key(for: one))
        #expect(cache.bytesHeld == 4096 + EmojiCache.entryOverhead)
        #expect(cache.entriesHeld == 1)
    }

    @Test("Past the budget the oldest go, down to the low-water mark")
    func evictionIsByAgeAndDownToLowWater() {
        let cache = EmojiCache(http: FixtureHTTP())
        let emojis = ["a", "b", "c", "d"].map { Self.emoji($0) }
        let request = Self.request(emojis)
        for emoji in emojis {
            cache.store(EmojiCache.Frames(images: [], ends: [], bytes: 8 << 20), for: request.key(for: emoji))
        }
        #expect(cache.bytesHeld <= EmojiCache.lowWaterBytes)
        let held = cache.held(request)
        #expect(held["a"] == nil)
        #expect(held["b"] == nil)
        #expect(held["c"] != nil)
        #expect(held["d"] != nil)
    }

    @Test("The entry just handed in is never the one evicted to make room for it")
    func theNewestSurvivesItsOwnArrival() {
        // Two entries each larger than the low-water mark and each individually admissible. The
        // freshest is last in the eviction order, so without the guard the loop walks past the
        // terminator and empties the cache — the view then finds nothing held, `fetch` sees no
        // entry, and a multi-megabyte body is fetched again every single turn.
        let cache = EmojiCache(http: FixtureHTTP())
        let emojis = ["first", "second"].map { Self.emoji($0) }
        let request = Self.request(emojis)
        for emoji in emojis {
            cache.store(EmojiCache.Frames(images: [], ends: [], bytes: EmojiCache.lowWaterBytes + 1024),
                        for: request.key(for: emoji))
        }
        #expect(cache.entriesHeld == 1)
        #expect(cache.held(request)["second"] != nil)
    }

    @Test("A decode too large to keep is declined, and the decline is remembered")
    func admissionControlDeclinesRatherThanEmptying() throws {
        let cache = EmojiCache(http: FixtureHTTP())
        let keeper = Self.emoji("keeper")
        let monster = Self.emoji("monster")
        let request = Self.request([keeper, monster])
        // A real frame, so that `isAbsent` actually discriminates below. With a stand-in of no
        // images the keeper would report absent too, and the expectation would read as a check
        // on admission while being unable to fail.
        let picture = EmojiCache.Frames(
            try #require(EmojiCache.decode(EmojiFixture.png(width: 32, height: 32),
                                           ink: 40, stillOnly: false)),
            side: 20
        )
        cache.store(picture, for: request.key(for: keeper))
        cache.store(EmojiCache.Frames(images: [], ends: [], bytes: EmojiCache.maxCachedBytes + 1),
                    for: request.key(for: monster))
        let held = cache.held(request)
        // The one that fitted is still there, with its picture: nothing was emptied to make room.
        #expect(held["keeper"]?.isAbsent == false)
        // And the one that did not is a record rather than a hole, so nobody asks again.
        #expect(held["monster"]?.isAbsent == true)
        #expect(cache.bytesHeld < EmojiCache.maxCachedBytes)
    }

    @Test("Nothing that arrives is ever held past the budget")
    func theBudgetIsNeverExceeded() {
        let cache = EmojiCache(http: FixtureHTTP())
        for index in 0..<200 {
            let one = Self.emoji("e\(index)")
            cache.store(EmojiCache.Frames(images: [], ends: [], bytes: 512 << 10),
                        for: Self.request([one]).key(for: one))
            #expect(cache.bytesHeld <= EmojiCache.maxCachedBytes)
            #expect(cache.entriesHeld > 0)
        }
    }

    @Test("Records of nothing are bounded too, because every entry is charged for itself")
    func emptyRecordsAreBounded() {
        let cache = EmojiCache(http: FixtureHTTP())
        let ceiling = EmojiCache.maxCachedBytes / EmojiCache.entryOverhead
        for index in 0..<(ceiling + 50) {
            let one = Self.emoji("n\(index)")
            cache.store(.absent, for: Self.request([one]).key(for: one))
        }
        #expect(cache.entriesHeld <= ceiling)
        #expect(cache.bytesHeld <= EmojiCache.maxCachedBytes)
    }

    @Test("A still and a moving copy of the same address are not the same entry")
    func stillnessIsPartOfTheKey() {
        let one = Self.emoji("only")
        #expect(Self.request([one], still: true).key(for: one)
            != Self.request([one], still: false).key(for: one))
    }

    @Test("A reader who asked for less motion is fetched the still the server offered")
    func theStillAddressIsPreferred() {
        let offered = Self.emoji("wave", still: "wave-still")
        let notOffered = Self.emoji("plain")
        #expect(Self.request([offered], still: true).address(of: offered).lastPathComponent == "wave-still.png")
        #expect(Self.request([offered], still: false).address(of: offered).lastPathComponent == "wave.gif")
        #expect(Self.request([notOffered], still: true).address(of: notOffered).lastPathComponent == "plain.gif")
    }

    // MARK: Forgetting

    @Test("An entry carries the source it was read through, and Clear reaches it by that")
    func forgettingOneSourceLeavesTheOthers() {
        let cache = EmojiCache(http: FixtureHTTP())
        let one = Self.emoji("shared")
        let here = Self.request([one], host: "here.test")
        let there = Self.request([one], host: "there.test")
        #expect(here.key(for: one) != there.key(for: one))

        cache.store(EmojiCache.Frames(images: [], ends: [], bytes: 2048), for: here.key(for: one))
        cache.store(EmojiCache.Frames(images: [], ends: [], bytes: 2048), for: there.key(for: one))
        cache.forget(host: "here.test")

        #expect(cache.held(here).isEmpty)
        #expect(cache.held(there)["shared"] != nil)
        #expect(cache.bytesHeld == 2048 + EmojiCache.entryOverhead)
    }

    @Test("A record of nothing can be dropped from outside, which is the way back from an outage")
    func absencesCanBeForgotten() throws {
        let cache = EmojiCache(http: FixtureHTTP())
        let gone = Self.emoji("gone")
        let kept = Self.emoji("kept")
        let request = Self.request([gone, kept])
        // A real picture, not a stand-in: what tells a record of nothing from a record of
        // something is that the second one has a frame in it.
        let picture = EmojiCache.Frames(
            try #require(EmojiCache.decode(EmojiFixture.png(width: 32, height: 32),
                                           ink: 40, stillOnly: false)),
            side: 20
        )
        cache.store(.absent, for: request.key(for: gone))
        cache.store(picture, for: request.key(for: kept))

        cache.forgetAbsences()
        #expect(cache.held(request)["gone"] == nil)
        #expect(cache.held(request)["kept"] != nil)
        #expect(cache.bytesHeld == picture.bytes + EmojiCache.entryOverhead)
    }

    @Test("Clearing takes the pictures and the remembered lines with it")
    func clearingTakesEverything() {
        let cache = EmojiCache(http: FixtureHTTP())
        let one = Self.emoji("blobcat")
        cache.store(EmojiCache.Frames(images: [], ends: [], bytes: 4096),
                    for: Self.request([one]).key(for: one))
        _ = cache.runs(in: "hi :blobcat:", from: [one])

        cache.clear()
        #expect(cache.entriesHeld == 0)
        #expect(cache.bytesHeld == 0)
        #expect(cache.linesRemembered == 0)
    }

    // MARK: The memoised cut

    @Test("The cut of a line is made once and remembered")
    func theCutIsMemoised() {
        let cache = EmojiCache(http: FixtureHTTP())
        let emojis = [Self.emoji("blobcat")]
        let first = cache.runs(in: "hi :blobcat: there", from: emojis)
        let again = cache.runs(in: "hi :blobcat: there", from: emojis)
        #expect(first == again)
        #expect(first == CustomEmoji.runs(in: "hi :blobcat: there", from: emojis))
        #expect(cache.linesRemembered == 1)
        _ = cache.runs(in: "a different line", from: emojis)
        #expect(cache.linesRemembered == 2)
        // A line nobody sent a picture for is the scanner's own fast path; the memo is not spent
        // on it.
        _ = cache.runs(in: "no pictures here", from: [])
        #expect(cache.linesRemembered == 2)
    }

    @Test("A line too long to be worth remembering is cut and not kept")
    func longLinesAreNotRemembered() {
        // The memo key holds the line itself, and a post body comes off an untrusted instance
        // with no length bound anywhere in Core: remembering 512 of these was a hundred megabytes
        // held outside the byte budget for the life of the process.
        let cache = EmojiCache(http: FixtureHTTP())
        let emojis = [Self.emoji("blobcat")]
        let huge = String(repeating: "a", count: EmojiCache.maxMemoisedLine + 1) + " :blobcat:"
        let cut = cache.runs(in: huge, from: emojis)

        #expect(cut == CustomEmoji.runs(in: huge, from: emojis))
        #expect(cache.linesRemembered == 0)

        let atTheBound = String(repeating: "b", count: EmojiCache.maxMemoisedLine)
        _ = cache.runs(in: atTheBound, from: emojis)
        #expect(cache.linesRemembered == 1)
    }

    @Test("What the memo can hold is bounded in bytes, by count and by line length together")
    func rememberedLinesAreBounded() {
        let cache = EmojiCache(http: FixtureHTTP())
        let emojis = [Self.emoji("blobcat")]
        for index in 0..<(EmojiCache.maxRememberedLines + 40) {
            _ = cache.runs(in: "line \(index) :blobcat:", from: emojis)
        }
        #expect(cache.linesRemembered == EmojiCache.maxRememberedLines)
        // The pair is what bounds it: neither number alone says how much can be held.
        #expect(EmojiCache.maxRememberedLines * EmojiCache.maxMemoisedLine <= 1 << 20)
    }
}

// MARK: - The ceiling on open requests

@MainActor
@Suite("The in-flight gate")
struct EmojiGateTests {
    @Test("Up to the ceiling nobody waits")
    func underTheCeilingNobodyWaits() async {
        let gate = EmojiGate(ceiling: 3)
        for _ in 0..<3 { await gate.enter() }
        #expect(gate.openCount == 3)
        #expect(gate.waitingCount == 0)
    }

    @Test("Past the ceiling the rest queue, and a slot is handed straight on")
    func pastTheCeilingTheRestQueue() async {
        let gate = EmojiGate(ceiling: 2)
        await gate.enter()
        await gate.enter()

        let third = Task { @MainActor in await gate.enter() }
        let fourth = Task { @MainActor in await gate.enter() }
        await spin { gate.waitingCount == 2 }
        #expect(gate.waitingCount == 2)
        #expect(gate.openCount == 2)

        gate.leave()
        await third.value
        // The slot passed straight to the waiter rather than being released and re-taken, so the
        // count never dipped and no slot was lost.
        #expect(gate.openCount == 2)
        #expect(gate.waitingCount == 1)

        gate.leave()
        await fourth.value
        #expect(gate.waitingCount == 0)
        gate.leave()
        gate.leave()
        #expect(gate.openCount == 0)
    }

    @Test("Leaving more often than entering cannot drive the count below nothing")
    func leavingTooOftenIsHarmless() {
        let gate = EmojiGate(ceiling: 2)
        gate.leave()
        gate.leave()
        #expect(gate.openCount == 0)
    }

    @Test("A ceiling of nothing is still a ceiling of one")
    func theCeilingHasAFloor() {
        #expect(EmojiGate(ceiling: 0).ceiling == 1)
        #expect(EmojiCache.maxInFlight >= 1)
    }
}

// MARK: - Fetching, without a socket

@MainActor
@Suite("Fetching an emoji")
struct EmojiFetchTests {
    private static func emoji(_ shortcode: String, file: String, still: String? = nil) -> CustomEmoji {
        CustomEmoji(shortcode: shortcode,
                    url: URL(string: "https://example.test/\(file)")!,
                    staticURL: still.map { URL(string: "https://example.test/\($0)")! })
    }

    private static func request(_ emojis: [CustomEmoji], host: String = "example.test",
                                side: CGFloat = 20, still: Bool = false) -> EmojiCache.Request {
        EmojiCache.Request(emojis: emojis, metrics: .init(side: side, baseline: -4),
                           scale: 2, host: host, still: still)
    }

    @Test("A picture that comes back is decoded, kept, and drawn from the cache")
    func aPictureThatArrivesIsKept() async {
        let http = FixtureHTTP(["/blobcat.gif": .body(EmojiFixture.gif(delays: [0.1, 0.1]))])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("blobcat", file: "blobcat.gif")
        let request = Self.request([one])

        await cache.fetch(request)
        let held = cache.held(request)["blobcat"]
        #expect(held?.images.count == 2)
        #expect(held?.moves == true)
        #expect(held?.image(at: 0) != nil)
        #expect(held?.drawnHeight == 20)
        #expect(cache.bytesHeld > EmojiCache.entryOverhead)
    }

    @Test("One address is one request, however many lines and sizes ask for it")
    func oneAddressIsOneRequest() async {
        // The same `:blobcat:` in a name and in a body is two entries — different ink, different
        // decode — but one download. Custom emoji repeat heavily on a real timeline, so this is
        // the difference between a handful of requests and a hundred.
        let http = FixtureHTTP(["/blobcat.gif": .body(EmojiFixture.gif(delays: [0.1]))])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("blobcat", file: "blobcat.gif")
        let asName = Self.request([one], side: 18)
        let asBody = Self.request([one], side: 24)
        let elsewhere = Self.request([one], host: "other.test", side: 18)

        async let first: Void = cache.fetch(asName)
        async let second: Void = cache.fetch(asBody)
        async let third: Void = cache.fetch(elsewhere)
        _ = await (first, second, third)

        #expect(await http.requested.count == 1)
        #expect(cache.entriesHeld == 3)
        #expect(cache.held(asName)["blobcat"]?.drawnHeight == 18)
        #expect(cache.held(asBody)["blobcat"]?.drawnHeight == 24)
    }

    @Test("The dedupe spans concurrent flight, which is what it is for and all it claims")
    func theDedupeIsInFlightOnly() async {
        // `downloads` is a map of what is on the wire, not a cache of bodies: a second ink asking
        // once the first has landed is a second request. Asserted rather than left implied, so
        // the test above is not read as a general one-request-per-address guarantee.
        let http = FixtureHTTP(["/blobcat.gif": .body(EmojiFixture.gif(delays: [0.1]))])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("blobcat", file: "blobcat.gif")

        await cache.fetch(Self.request([one], side: 18))
        await cache.fetch(Self.request([one], side: 24))
        #expect(await http.requested.count == 2)
    }

    @Test("A reader who asked for less motion gets the still and no second frame")
    func reduceMotionFetchesTheStill() async {
        let http = FixtureHTTP([
            "/wave.gif": .body(EmojiFixture.gif(delays: [0.1, 0.1, 0.1])),
            "/wave.png": .body(EmojiFixture.png()),
        ])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("wave", file: "wave.gif", still: "wave.png")
        let request = Self.request([one], still: true)

        await cache.fetch(request)
        #expect(cache.held(request)["wave"]?.moves == false)
        #expect(await http.paths == ["/wave.png"])
    }

    @Test("A moving file with no still offered is decoded to its first frame and does not move")
    func reduceMotionWithoutAStillTakesTheFirstFrame() async {
        let http = FixtureHTTP(["/only.gif": .body(EmojiFixture.gif(delays: [0.1, 0.1, 0.1]))])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("only", file: "only.gif")
        let request = Self.request([one], still: true)

        await cache.fetch(request)
        let held = cache.held(request)["only"]
        #expect(held?.images.count == 1)
        #expect(held?.moves == false)
    }

    @Test("A fetch that fails is recorded, and the line does not ask for ever")
    func aFailureIsAskedForOnce() async {
        let http = FixtureHTTP(["/gone.gif": .fail])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("gone", file: "gone.gif")
        let request = Self.request([one])

        await cache.fetch(request)
        await cache.fetch(request)
        await cache.fetch(request)

        #expect(await http.requested.count == 1)
        #expect(cache.held(request)["gone"]?.isAbsent == true)
    }

    @Test("Once the record of nothing is dropped, the picture is asked for again")
    func forgettingAnAbsenceLetsItBeAskedAgain() async {
        let http = FixtureHTTP(["/late.gif": .body(EmojiFixture.gif(delays: [0.1]))])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("late", file: "late.gif")
        let request = Self.request([one])

        // Stand in for the outage: the record of nothing is already there.
        cache.store(.absent, for: request.key(for: one))
        await cache.fetch(request)
        #expect(await http.requested.isEmpty)

        cache.forgetAbsences()
        await cache.fetch(request)
        #expect(await http.requested.count == 1)
        #expect(cache.held(request)["late"]?.isAbsent == false)
    }

    @Test("A server that answers with something that is not a picture is recorded the same way")
    func rubbishIsRecordedNotRetried() async {
        let http = FixtureHTTP(["/bad.gif": .text("<html>nope</html>")])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("bad", file: "bad.gif")
        let request = Self.request([one])

        await cache.fetch(request)
        await cache.fetch(request)
        #expect(await http.requested.count == 1)
        #expect(cache.held(request)["bad"]?.isAbsent == true)
    }

    @Test("A status that is not a success is not a picture")
    func aNotFoundIsNotAPicture() async {
        let http = FixtureHTTP(["/missing.gif": .body(EmojiFixture.gif(delays: [0.1]), status: 404)])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("missing", file: "missing.gif")
        let request = Self.request([one])

        await cache.fetch(request)
        #expect(cache.held(request)["missing"]?.isAbsent == true)
    }

    @Test("A line whose pictures are already in hand asks for nothing")
    func whatIsHeldIsNotFetchedAgain() async {
        let http = FixtureHTTP(["/blobcat.gif": .body(EmojiFixture.gif(delays: [0.1]))])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("blobcat", file: "blobcat.gif")
        let request = Self.request([one])

        await cache.fetch(request)
        await cache.fetch(request)
        #expect(await http.requested.count == 1)
    }

    // MARK: Forgetting reaches work already on the wire

    @Test("Clearing while a picture is on the wire does not let it back in")
    func clearingStrikesOffWorkInFlight() async {
        let http = HeldHTTP(body: EmojiFixture.gif(delays: [0.1]))
        let cache = EmojiCache(http: http)
        let one = Self.emoji("blobcat", file: "blobcat.gif")
        let request = Self.request([one])

        let fetching = Task { await cache.fetch(request) }
        await spin { await http.waiting == 1 }
        cache.clear()
        #expect(cache.entriesHeld == 0)

        await http.release()
        await fetching.value
        // Without an epoch the decode lands behind the reader and files itself: entries=1,
        // bytes=5120, held=true, for a cache they just emptied.
        #expect(cache.entriesHeld == 0)
        #expect(cache.bytesHeld == 0)
        #expect(cache.held(request).isEmpty)
    }

    @Test("A fetch in the same pass as a clear joins the struck-off task and re-asks on the next")
    func aFetchAfterAClearJoinsTheStruckOffTask() async {
        // Unit 11's Clear button is exactly this sequence: clear, and the screen re-asks in the
        // same pass. `inFlight` still holds the struck-off task, so the second fetch joins it
        // rather than opening a second request — and that task files nothing, because its epoch
        // is stale. So the pass comes back empty. Recorded rather than discovered later: the
        // cost of the epoch is one re-request, and this is where it is paid.
        let http = HeldHTTP(body: EmojiFixture.gif(delays: [0.1]))
        let cache = EmojiCache(http: http)
        let one = Self.emoji("blobcat", file: "blobcat.gif")
        let request = Self.request([one])

        let first = Task { await cache.fetch(request) }
        await spin { await http.waiting == 1 }
        cache.clear()

        let second = Task { await cache.fetch(request) }
        await http.release()
        await first.value
        await second.value

        #expect(await http.requested == 1)
        #expect(cache.entriesHeld == 0)
        #expect(cache.held(request).isEmpty)

        // And it self-heals: the next pass finds nothing in flight and nothing held, asks once
        // more, and this time the picture lands.
        let third = Task { await cache.fetch(request) }
        await spin { await http.waiting == 1 }
        await http.release()
        await third.value

        #expect(await http.requested == 2)
        #expect(cache.held(request)["blobcat"]?.isAbsent == false)
    }

    @Test("A source cleared while its pictures were loading does not reappear under that source")
    func forgettingAHostStrikesOffWorkInFlight() async {
        let http = HeldHTTP(body: EmojiFixture.gif(delays: [0.1]))
        let cache = EmojiCache(http: http)
        let one = Self.emoji("blobcat", file: "blobcat.gif")
        let request = Self.request([one], host: "first.example")

        let fetching = Task { await cache.fetch(request) }
        await spin { await http.waiting == 1 }
        cache.forget(host: "first.example")

        await http.release()
        await fetching.value
        #expect(cache.held(request).isEmpty)
        #expect(cache.bytesHeld == 0)
    }

    @Test("The kick that drops records of nothing is not undone by a decode already running")
    func forgettingAbsencesStrikesOffWorkInFlight() async {
        // The in-flight work here will decide "absent" — the body is not a picture — which is
        // exactly what `forgetAbsences()` has just thrown away.
        let http = HeldHTTP(body: Data("not a picture".utf8))
        let cache = EmojiCache(http: http)
        let one = Self.emoji("blobcat", file: "blobcat.gif")
        let request = Self.request([one])

        let fetching = Task { await cache.fetch(request) }
        await spin { await http.waiting == 1 }
        cache.forgetAbsences()

        await http.release()
        await fetching.value
        #expect(cache.entriesHeld == 0)
        #expect(cache.held(request).isEmpty)
    }

    @Test("A picture too short to see is recorded as nothing, so the line keeps the shortcode")
    func aVanishingPictureIsRecordedAsNothing() async {
        let http = FixtureHTTP(["/thin.png": .body(EmojiFixture.png(width: 1024, height: 1))])
        let cache = EmojiCache(http: http)
        let one = Self.emoji("thin", file: "thin.png")
        let request = Self.request([one])

        await cache.fetch(request)
        #expect(cache.held(request)["thin"]?.isAbsent == true)
        #expect(EmojiText.line(CustomEmoji.runs(in: ":thin:", from: [one]),
                               cache.held(request), at: 0, baseline: -4)
            == Text(verbatim: "") + Text(verbatim: ":thin:"))
    }

    @Test("One emoji read through two sources is two entries, and that is what Clear is for")
    func duplicationAcrossSourcesStaysSmall() throws {
        // A host *set* on one shared entry was refused: an entry shared by a set frees no memory
        // until the last host goes, which is the opposite of what the button promises the reader.
        // This is the price of that, and the test is here so nobody optimises it away later
        // without knowing what it was bought with.
        let picture = EmojiCache.Frames(
            try #require(EmojiCache.decode(EmojiFixture.png(width: 64, height: 64),
                                           ink: 40, stillOnly: false)),
            side: 20
        )
        let perCopy = picture.bytes + EmojiCache.entryOverhead
        #expect(perCopy < EmojiCache.maxCachedBytes / 1000)
    }

    @Test("Every address goes through the client, so nothing this suite does opens a socket")
    func everyAddressGoesThroughTheClient() async {
        let http = FixtureHTTP(["/a.gif": .body(EmojiFixture.gif(delays: [0.1]))])
        let cache = EmojiCache(http: http)
        let emojis = [Self.emoji("a", file: "a.gif"), Self.emoji("b", file: "b.gif")]
        let request = Self.request(emojis)

        await cache.fetch(request)
        #expect(await http.paths.sorted() == ["/a.gif", "/b.gif"])
    }
}

// MARK: - The view

@MainActor
@Suite("The line itself")
struct EmojiTextTests {
    private static let blobcat = CustomEmoji(shortcode: "blobcat",
                                             url: URL(string: "https://example.test/blobcat.gif")!)

    private static func cut(_ text: String) -> [EmojiRun] {
        CustomEmoji.runs(in: text, from: [blobcat])
    }

    private static func frames(_ decoded: EmojiCache.Decoded, side: CGFloat = 20) -> EmojiCache.Frames {
        EmojiCache.Frames(decoded, side: side)
    }

    @Test("Until the picture is here the shortcode stands in for it, exactly as typed")
    func theShortcodeStandsIn() {
        let line = EmojiText.line(Self.cut("hi :blobcat: there"), [:], at: 0, baseline: -4)
        #expect(line == Text(verbatim: "") + Text(verbatim: "hi ")
            + Text(verbatim: ":blobcat:") + Text(verbatim: " there"))
    }

    @Test("A picture that is here is drawn, and it sits on the font's descender")
    func thePictureSitsOnTheDescender() throws {
        let decoded = try #require(EmojiCache.decode(EmojiFixture.png(width: 32, height: 32),
                                                     ink: 40, stillOnly: false))
        let held = ["blobcat": Self.frames(decoded)]
        let image = try #require(held["blobcat"]?.image(at: 0))

        let line = EmojiText.line(Self.cut("hi :blobcat:"), held, at: 0, baseline: -4)
        #expect(line == Text(verbatim: "") + Text(verbatim: "hi ")
            + Text(image).baselineOffset(-4))
        // A picture sitting on the baseline instead of the descender floats above the line, so
        // the offset is part of what the line is, not decoration on top of it.
        #expect(line != Text(verbatim: "") + Text(verbatim: "hi ") + Text(image))
    }

    @Test("A moving line is rebuilt with the frame that stands at the instant")
    func theLineFollowsTheClock() throws {
        let decoded = try #require(EmojiCache.decode(EmojiFixture.gif(delays: [0.1, 0.4]),
                                                     ink: 40, stillOnly: false))
        let held = ["blobcat": Self.frames(decoded)]
        let cut = Self.cut(":blobcat:")
        let first = EmojiText.line(cut, held, at: 0, baseline: -4)
        let second = EmojiText.line(cut, held, at: 0.2, baseline: -4)
        #expect(first != second)
        #expect(EmojiText.line(cut, held, at: 0.5, baseline: -4) == first)
    }

    @Test("A line with nothing moving in it never starts a clock")
    func stillLinesStartNoClock() throws {
        #expect(EmojiText.clock(for: [:], reduceMotion: false) == nil)
        let still = try #require(EmojiCache.decode(EmojiFixture.png(), ink: 40, stillOnly: false))
        #expect(EmojiText.clock(for: ["blobcat": Self.frames(still)], reduceMotion: false) == nil)
        #expect(EmojiText.clock(for: ["gone": .absent], reduceMotion: false) == nil)
    }

    @Test("A moving line starts a clock at the file's own rate")
    func movingLinesStartAClock() throws {
        let slow = try #require(EmojiCache.decode(EmojiFixture.gif(delays: [0.2, 0.2]),
                                                  ink: 40, stillOnly: false))
        let clock = try #require(EmojiText.clock(for: ["blobcat": Self.frames(slow)],
                                                 reduceMotion: false))
        #expect(abs(clock - 0.2) < 0.01)
    }

    @Test("A reader who asked for less motion gets no clock at all")
    func reduceMotionStartsNoClock() throws {
        let moving = try #require(EmojiCache.decode(EmojiFixture.gif(delays: [0.1, 0.1]),
                                                    ink: 40, stillOnly: false))
        let held = ["blobcat": Self.frames(moving)]
        #expect(EmojiText.clock(for: held, reduceMotion: false) != nil)
        #expect(EmojiText.clock(for: held, reduceMotion: true) == nil)
    }

    @Test("What a screen reader is given is what the author typed, shortcodes and all")
    func theLabelIsWhatWasTyped() {
        let written = "Ada :blobcat: Lovelace"
        let view = EmojiText(written, emojis: [Self.blobcat], host: "example.test", role: .name,
                             cache: EmojiCache(http: FixtureHTTP()))
        #expect(view.accessibilityText == Text(verbatim: written))
        #expect(view.text == written)
        #expect(view.host == "example.test")
        #expect(view.role == .name)
    }

    @Test("A line of plain words is one run and no pictures")
    func plainWordsStayPlain() {
        let line = EmojiText.line([.text("just words")], [:], at: 0, baseline: -4)
        #expect(line == Text(verbatim: "") + Text(verbatim: "just words"))
        #expect(EmojiText.line([], [:], at: 0, baseline: -4) == Text(verbatim: ""))
    }
}
