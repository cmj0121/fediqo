import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FediqoUI

/// What a custom emoji is drawn as: the size of the letters beside it, and every frame it has.
@Suite("A picture inside a line of text")
@MainActor
struct EmojiDrawingTests {
    /// A GIF of `frames` frames, each standing for `delay` seconds. Built rather than kept as a
    /// fixture file, so what is under test is the decoding and not somebody's checked-in blob.
    private func gif(frames: Int, delay: Double) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for index in 0..<frames {
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red: Double(index) / Double(frames), green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            CGImageDestinationAddImage(destination, context.makeImage()!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private let metrics = EmojiCache.metrics(size: 13)

    @Test("A picture stands as tall as the ink of the line it is in, and sits on its descender")
    func sizedByTheFontAndNotByThePointSize() {
        // The usual approximation is the point size itself, and it is visibly wrong: the ink of
        // a line is taller than its point size, and its bottom is below the baseline.
        #expect(metrics.side > 13)
        #expect(metrics.side < 13 * 1.5)
        #expect(metrics.baseline < 0)
        // Twice the size is twice the ink, so a reader who enlarges the text enlarges these too.
        #expect(EmojiCache.metrics(size: 26).side > metrics.side)
    }

    @Test("Every frame is decoded, and each one keeps how long it stands")
    func everyFrameSurvives() {
        let decoded = EmojiCache.decode(gif(frames: 3, delay: 0.08), metrics: metrics, scale: 2,
                                        firstFrameOnly: false)
        #expect(decoded?.images.count == 3)
        #expect(decoded?.moves == true)
        // The ends are cumulative, so the frame to draw is a search rather than a division.
        #expect(decoded.map { $0.ends.map { ($0 * 100).rounded() / 100 } } == [0.08, 0.16, 0.24])
    }

    @Test("A frame with no honest duration is given the tenth of a second every renderer gives it")
    func absurdDelaysAreReplaced() {
        let decoded = EmojiCache.decode(gif(frames: 2, delay: 0), metrics: metrics, scale: 2,
                                        firstFrameOnly: false)
        #expect(decoded?.ends == [0.1, 0.2])
    }

    @Test("A reader who asked for less movement is given one frame and no clock")
    func reduceMotionTakesTheFirstFrame() {
        let decoded = EmojiCache.decode(gif(frames: 4, delay: 0.05), metrics: metrics, scale: 2,
                                        firstFrameOnly: true)
        #expect(decoded?.images.count == 1)
        #expect(decoded?.moves == false)
    }

    @Test("A still is one frame, and it moves nothing")
    func aStillIsAStill() {
        let decoded = EmojiCache.decode(gif(frames: 1, delay: 0.1), metrics: metrics, scale: 2,
                                        firstFrameOnly: false)
        #expect(decoded?.images.count == 1)
        #expect(decoded?.moves == false)
    }

    @Test("Something that is not a picture at all is nothing, not a blank")
    func rubbishIsRefused() {
        #expect(EmojiCache.decode(Data("not a picture".utf8), metrics: metrics, scale: 2,
                                  firstFrameOnly: false) == nil)
    }
}
