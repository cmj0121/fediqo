import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
@testable import FediqoUI

/// The cache that holds a picture where a row cannot lose it (#91).
///
/// What is asserted here is the bookkeeping, because the bookkeeping is what the bug was: a
/// picture that arrived and was then thrown away by a rebuild, and a picture that never came
/// asked for again on every pass.
@MainActor
@Suite("A picture a row cannot lose")
struct PictureCacheTests {
    /// One real PNG on disk, because the cache decodes what it is given rather than trusting a
    /// stub — a test that handed it a `Data()` would be testing the failure path twice.
    private func png(_ name: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("picture-cache-\(name).png")
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CacheTestFailure.cannotDraw }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CacheTestFailure.cannotDraw }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CacheTestFailure.cannotDraw }
        return file
    }

    enum CacheTestFailure: Error { case cannotDraw }

    /// The whole point. Once it is in hand, a view that has just been rebuilt finds it there and
    /// draws on its first pass rather than starting again from nothing — which is what
    /// `AsyncImage` could not do, and why the same attachment printed `success`, `empty`, `empty`.
    @Test("Once it has arrived, it is there for whoever asks next")
    func heldAfterItArrives() async throws {
        let cache = PictureCache()
        let url = try png("held")

        #expect(cache.picture(url, scale: 2) == nil)
        await cache.fetch(url, scale: 2)
        #expect(cache.picture(url, scale: 2) != nil)
    }

    /// Decoded for one screen's pixels is soft on another's, so the two are different pictures
    /// and the cache keeps them apart.
    @Test("A picture for one screen is not the picture for another")
    func keptPerScreen() async throws {
        let cache = PictureCache()
        let url = try png("scale")

        await cache.fetch(url, scale: 2)
        #expect(cache.picture(url, scale: 2) != nil)
        #expect(cache.picture(url, scale: 1) == nil)
    }

    /// "Nothing came" has to be a state of its own. Without it a row draws the waiting shape for
    /// ever for a picture that is never coming, and asks for it again on every rebuild.
    @Test("A picture that never comes is missing, not forever arriving")
    func nothingCameIsAState() async throws {
        let cache = PictureCache()
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("picture-cache-does-not-exist.png")

        #expect(!cache.isMissing(nowhere, scale: 2))
        await cache.fetch(nowhere, scale: 2)
        #expect(cache.isMissing(nowhere, scale: 2))
        #expect(cache.picture(nowhere, scale: 2) == nil)
    }

    /// Nothing is asked of a row that has no picture, and nothing is remembered about it either.
    @Test("No address is not a missing picture")
    func noAddressIsNotMissing() async {
        let cache = PictureCache()
        await cache.fetch(nil, scale: 2)
        #expect(!cache.isMissing(nil, scale: 2))
        #expect(cache.picture(nil, scale: 2) == nil)
    }

    /// A timeline read for an hour would otherwise hold every photograph it had ever drawn, and a
    /// photograph is not a twenty-point emoji.
    @Test("It lets go of the oldest rather than growing for ever")
    func lettingGoOfTheOldest() async throws {
        let cache = PictureCache()
        var urls: [URL] = []
        for index in 0...PictureCache.held {
            let url = try png("evict-\(index)")
            urls.append(url)
            await cache.fetch(url, scale: 2)
        }

        // The first one asked for is the first one let go, and the newest is still in hand.
        #expect(cache.picture(urls[0], scale: 2) == nil)
        #expect(cache.picture(urls[urls.count - 1], scale: 2) != nil)
    }
}
