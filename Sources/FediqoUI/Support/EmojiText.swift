import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import FediqoCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A line of a post, with the pictures in it drawn as pictures — moving, where they move.
///
/// One `Text` and not a row of views: a post is prose, and prose wraps, is selected, and is cut
/// off with an ellipsis. Laying it out as a stack of words and images would take all three away
/// — so the pictures are interpolated into the `Text` itself, which is the one way SwiftUI
/// offers to put an image inside a line and have the line still behave like a line.
///
/// Two things follow from that, and they are the whole of this file.
///
/// **Nothing inside a `Text` can be resized**, so a picture has to be drawn at the size it will
/// be shown. That size is the font's own — the ink between its ascender and its descender at
/// the reader's text scale — so a custom emoji stands exactly as tall as the letters beside it
/// rather than at some fraction of the point size that happens to look close.
///
/// **Nothing inside a `Text` animates either**, so an animated emoji is animated the only way
/// left: the frames are decoded once, and the line is rebuilt with the next one on a clock.
/// That is why the clock only runs where there is something moving in this particular line, and
/// why a reader who has asked for less movement gets the first frame and no clock at all.
struct EmojiText: View {
    let text: String
    let emojis: [CustomEmoji]
    var size: CGFloat = TypeScale.body
    var weight: Font.Weight = .regular

    @Environment(\.fediqoTextScale) private var scale
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Not `@State`: the cache is one object for the whole app, and observation follows from
    /// reading it in `body` rather than from owning it.
    private let cache = EmojiCache.shared

    init(_ text: String, emojis: [CustomEmoji], size: CGFloat = TypeScale.body, weight: Font.Weight = .regular) {
        self.text = text
        self.emojis = emojis
        self.size = size
        self.weight = weight
    }

    /// How tall a picture in this line is, and how far below the baseline it starts: the font's
    /// own ascender and descender at the size this line is set in. A picture as tall as the
    /// point size and sitting on the baseline is the usual approximation, and it is visibly
    /// wrong — too tall for the letters and floating above the line's own bottom.
    private var metrics: EmojiCache.Metrics { EmojiCache.metrics(size: size * scale) }

    /// A clock only where one is needed. A page of ordinary posts never starts one, and a line
    /// whose emoji are all stills does not either.
    private var moving: Bool {
        guard !reduceMotion else { return false }
        return emojis.contains { cache.moves($0, metrics: metrics, scale: displayScale) }
    }

    var body: some View {
        Group {
            if moving {
                // 20 a second: enough for the frame rates a custom emoji is drawn at, and far
                // enough below the display's own that a screen of them is not the app's
                // largest expense.
                TimelineView(.periodic(from: .now, by: 0.05)) { tick in
                    line(at: tick.date.timeIntervalSinceReferenceDate)
                }
            } else {
                line(at: 0)
            }
        }
        .font(.system(size: size * scale, weight: weight))
        // What a screen reader is given is what the author typed, shortcodes and all: it cannot
        // see a picture, and `:blobcat:` is at least the name of one.
        .accessibilityLabel(Text(verbatim: text))
        .task(id: EmojiCache.Request(emojis: emojis, metrics: metrics, scale: displayScale)) {
            await cache.fetch(emojis, metrics: metrics, scale: displayScale, still: reduceMotion)
        }
    }

    /// Words, with any address in them drawn as one.
    ///
    /// An `AttributedString` and not a `Link`: what is being built is one `Text`, and a link
    /// inside a line has to wrap with the line rather than sit in it as a view of its own.
    /// SwiftUI draws a `.link` run in the accent colour and hands a press of it to `openURL`,
    /// which is the one way out of this app and already the reader's browser.
    private static func written(_ words: String) -> Text {
        let runs = TextLinks.runs(in: words)
        guard runs.contains(where: { if case .link = $0 { true } else { false } }) else {
            return Text(verbatim: words)
        }
        var attributed = AttributedString()
        for run in runs {
            switch run {
            case .text(let plain):
                attributed += AttributedString(plain)
            case .link(let label, let url):
                var piece = AttributedString(label)
                piece.link = url
                // Underlined as well as tinted, because a link that is only a colour is not a
                // link to a reader who cannot tell the two colours apart.
                piece.underlineStyle = .single
                attributed += piece
            }
        }
        return Text(attributed)
    }

    private func line(at instant: TimeInterval) -> Text {
        CustomEmoji.runs(in: text, from: emojis).reduce(Text(verbatim: "")) { line, run in
            switch run {
            case .text(let words):
                return line + Self.written(words)
            case .emoji(let emoji):
                // Until the picture is here the shortcode stands in for it, which is what the
                // reader would have seen anyway and is never a blank.
                guard let image = cache.image(emoji, metrics: metrics, scale: displayScale, at: instant) else {
                    return line + Text(verbatim: ":\(emoji.shortcode):")
                }
                return line + Text(image).baselineOffset(metrics.baseline)
            }
        }
    }
}

/// The pictures, fetched once each, decoded to the size they will be drawn at, and kept.
///
/// Keyed by address, size **and** screen, because none of the three can be changed after the
/// fact: a picture that goes into a `Text` is already the size it will be, and a picture
/// decoded for one screen's pixels is soft on another's.
///
/// Shared for the reason a cache is: a hundred rows carrying `:blobcat:` are one request and
/// one decode, and what is already in hand is drawn on the first pass rather than after a
/// flash of the shortcode.
@MainActor
@Observable
final class EmojiCache {
    static let shared = EmojiCache()

    /// The two numbers a line of text gives a picture standing in it: how tall it is, and how
    /// far under the baseline it sits. Both come from the font rather than from the point size,
    /// which is not the same thing — a 13-point font's letters are not 13 points of ink.
    struct Metrics: Hashable {
        let side: CGFloat
        let baseline: CGFloat
    }

    /// What `task(id:)` watches: a line asks again when its emoji, its size or its screen
    /// change, and never in between.
    struct Request: Hashable {
        let emojis: [CustomEmoji]
        let metrics: Metrics
        let scale: CGFloat
    }

    /// One emoji, decoded: the frames in order, and how long each of them stands. A still is
    /// one frame and no duration, and is drawn without a clock ever starting.
    ///
    /// Not private, and neither is `decode`: how many frames a file has and how long each of
    /// them stands is the part of this worth testing, and it is testable without a screen.
    struct Frames {
        let images: [Image]
        /// The instant each frame gives way to the next, measured from the start of the loop.
        let ends: [TimeInterval]
        var moves: Bool { images.count > 1 }
        var total: TimeInterval { ends.last ?? 0 }
    }

    private struct Key: Hashable {
        let url: URL
        let metrics: Metrics
        let scale: CGFloat
    }

    private var frames: [Key: Frames] = [:]
    /// What is already on its way, so a screenful of the same emoji is one request.
    private var inFlight: Set<Key> = []

    static func metrics(size: CGFloat) -> Metrics {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: size)
        #else
        let font = UIFont.systemFont(ofSize: size)
        #endif
        // The ink of a line: from the top of an ascender to the bottom of a descender. Rounded
        // to whole points so two lines of the same size share one decode.
        let side = (font.ascender - font.descender).rounded()
        return Metrics(side: side, baseline: font.descender.rounded())
    }

    /// Whether this one moves — asked by the line, so that a clock only runs where it must.
    func moves(_ emoji: CustomEmoji, metrics: Metrics, scale: CGFloat) -> Bool {
        frames[Key(url: emoji.url, metrics: metrics, scale: scale)]?.moves ?? false
    }

    /// The frame to draw at this instant. `instant` is a wall clock rather than a position in
    /// the loop, so every emoji on the screen runs off the same one and none of them needs to
    /// remember where it had got to.
    func image(_ emoji: CustomEmoji, metrics: Metrics, scale: CGFloat, at instant: TimeInterval) -> Image? {
        let key = Key(url: emoji.url, metrics: metrics, scale: scale)
        guard let held = frames[key] else {
            // Reduce-motion asked for the still, which is a different address and a different
            // row in the cache.
            guard let still = emoji.staticURL else { return nil }
            return frames[Key(url: still, metrics: metrics, scale: scale)]?.images.first
        }
        guard held.moves, held.total > 0 else { return held.images.first }
        let position = instant.truncatingRemainder(dividingBy: held.total)
        let index = held.ends.firstIndex { position < $0 } ?? 0
        return held.images[index]
    }

    /// Fetches and decodes whatever of these is not already in hand.
    ///
    /// `still` is the reader's answer about movement: it asks for the copy the server says does
    /// not move, and where a server offered none the moving one is decoded and its first frame
    /// drawn — which is the same picture, standing still.
    func fetch(_ emojis: [CustomEmoji], metrics: Metrics, scale: CGFloat, still: Bool) async {
        for emoji in emojis {
            let address = still ? (emoji.staticURL ?? emoji.url) : emoji.url
            let key = Key(url: address, metrics: metrics, scale: scale)
            guard frames[key] == nil, inFlight.insert(key).inserted else { continue }
            defer { inFlight.remove(key) }
            guard let data = try? await URLSession.shared.data(from: address).0 else { continue }
            let decoded = await Task.detached(priority: .utility) {
                Self.decode(data, metrics: metrics, scale: scale, firstFrameOnly: still)
            }.value
            guard let decoded else { continue }
            frames[key] = decoded
        }
    }

    // MARK: - Decoding

    /// Every frame there is, drawn at the size the line will show it at.
    ///
    /// `ImageIO` and not `NSImage`/`UIImage`: it is the one API on both platforms that will say
    /// how many frames a file has and how long each of them stands, and it reads GIF, APNG and
    /// WebP — which between them is what a server's custom emoji are.
    nonisolated static func decode(_ data: Data, metrics: Metrics, scale: CGFloat,
                                           firstFrameOnly: Bool) -> Frames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = firstFrameOnly ? min(1, CGImageSourceGetCount(source)) : CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var images: [Image] = []
        var ends: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let drawn = scaled(frame, metrics: metrics, scale: scale) else { continue }
            images.append(Image(decorative: drawn, scale: scale))
            // A frame with no duration, or one so short nothing could draw it, is given the
            // tenth of a second every renderer gives it.
            let delay = duration(of: source, at: index)
            elapsed += delay < 0.011 ? 0.1 : delay
            ends.append(elapsed)
        }
        return images.isEmpty ? nil : Frames(images: images, ends: ends)
    }

    /// The frame, drawn into a rectangle of the height the line has and whatever width keeps it
    /// the shape it was. Done here rather than by the view for the reason the key carries the
    /// size: what goes into a `Text` is already what will be shown.
    private nonisolated static func scaled(_ frame: CGImage, metrics: Metrics, scale: CGFloat) -> CGImage? {
        let height = metrics.side
        let ratio = frame.height > 0 ? CGFloat(frame.width) / CGFloat(frame.height) : 1
        let pixels = CGSize(width: max(1, (height * ratio * scale).rounded()), height: max(1, (height * scale).rounded()))
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(origin: .zero, size: pixels))
        return context.makeImage()
    }

    /// How long one frame stands, whichever of the three formats it came out of. The unclamped
    /// time is asked for first: it is what the file actually says, where the other has already
    /// been rounded up to what a browser was once willing to draw.
    private nonisolated static func duration(of source: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0
        }
        let dictionaries = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary]
        let unclamped = [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyAPNGUnclampedDelayTime,
                         kCGImagePropertyWebPUnclampedDelayTime]
        let clamped = [kCGImagePropertyGIFDelayTime, kCGImagePropertyAPNGDelayTime, kCGImagePropertyWebPDelayTime]
        for (which, dictionary) in dictionaries.enumerated() {
            guard let frame = properties[dictionary] as? [CFString: Any] else { continue }
            if let time = frame[unclamped[which]] as? TimeInterval, time > 0 { return time }
            if let time = frame[clamped[which]] as? TimeInterval, time > 0 { return time }
        }
        return 0
    }
}
