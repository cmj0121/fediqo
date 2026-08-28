import SwiftUI
import FediqoCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A line of a post, with the pictures in it drawn as pictures.
///
/// One `Text` and not a row of views: a post is prose, and prose wraps, is selected, and is cut
/// off with an ellipsis. Laying it out as a stack of words and images would take all three away
/// — so the pictures are interpolated into the `Text` itself, which is the one way SwiftUI
/// offers to put an image inside a line and have the line still behave like a line.
///
/// The price of that is the picture has to be sized before it goes in: nothing inside a `Text`
/// can be resized afterwards. So the cache is asked for a picture at a height, and the height
/// is the reader's own text size — which is why the scale is read here rather than left to
/// `fediqoFont`.
struct EmojiText: View {
    let text: String
    let emojis: [CustomEmoji]
    var size: CGFloat = TypeScale.body
    var weight: Font.Weight = .regular

    @Environment(\.fediqoTextScale) private var scale
    /// Not `@State`: the cache is one object for the whole app, and observation follows from
    /// reading it in `body` rather than from owning it.
    private let cache = EmojiCache.shared

    init(_ text: String, emojis: [CustomEmoji], size: CGFloat = TypeScale.body, weight: Font.Weight = .regular) {
        self.text = text
        self.emojis = emojis
        self.size = size
        self.weight = weight
    }

    /// The height a picture is drawn at: the line's own, so a custom emoji sits at the weight
    /// of the letters beside it rather than looming over them.
    private var side: CGFloat { (size * scale).rounded() }

    var body: some View {
        composed
            .font(.system(size: size * scale, weight: weight))
            .task(id: emojis) { await cache.fetch(emojis, side: side) }
    }

    private var composed: Text {
        CustomEmoji.runs(in: text, from: emojis).reduce(Text(verbatim: "")) { line, run in
            switch run {
            case .text(let words):
                return line + Text(verbatim: words)
            case .emoji(let emoji):
                // Until the picture is here the shortcode stands in for it, which is what the
                // reader would have seen anyway and is never a blank.
                guard let image = cache.image(emoji, side: side) else {
                    return line + Text(verbatim: ":\(emoji.shortcode):")
                }
                return line + Text("\(image)").baselineOffset(-size * scale * 0.1)
            }
        }
    }
}

/// The pictures, fetched once each and kept.
///
/// Keyed by address **and height**, because a picture that goes into a `Text` cannot be resized
/// once it is there: a display name and the words under it ask for two different sizes of the
/// same emoji, and each of them has to be drawn at the size it will be shown.
///
/// Shared for the reason a cache is: a hundred rows carrying `:blobcat:` are one request, and
/// what is already in hand is drawn on the first pass rather than after a flash of the
/// shortcode.
@MainActor
@Observable
final class EmojiCache {
    static let shared = EmojiCache()

    private struct Key: Hashable {
        let url: URL
        let side: CGFloat
    }

    private var images: [Key: Image] = [:]
    /// What is already on its way, so a screenful of the same emoji is one request.
    private var inFlight: Set<Key> = []

    /// The picture at this height, or nothing where it is not here yet.
    func image(_ emoji: CustomEmoji, side: CGFloat) -> Image? {
        images[Key(url: Self.address(of: emoji), side: side)]
    }

    /// Fetches whatever of these is not already in hand. Every one of them is drawn as a still:
    /// a `Text` cannot animate what is inside it, so the moving copy would be a first frame
    /// fetched at the size of a film — and a reader who asked for less movement is answered by
    /// the same picture rather than by a second code path.
    func fetch(_ emojis: [CustomEmoji], side: CGFloat) async {
        for emoji in emojis {
            let key = Key(url: Self.address(of: emoji), side: side)
            guard images[key] == nil, inFlight.insert(key).inserted else { continue }
            defer { inFlight.remove(key) }
            guard let data = try? await Self.load(key.url), let image = Self.image(from: data, side: side) else { continue }
            images[key] = image
        }
    }

    private static func address(of emoji: CustomEmoji) -> URL { emoji.staticURL ?? emoji.url }

    private static func load(_ url: URL) async throws -> Data {
        try await URLSession.shared.data(from: url).0
    }

    /// Scaled here rather than by the view, for the reason the key carries the height: the
    /// image goes into a line of text at whatever size it arrives as.
    private static func image(from data: Data, side: CGFloat) -> Image? {
        #if os(macOS)
        guard let source = NSImage(data: data), source.size.height > 0 else { return nil }
        let width = side * (source.size.width / source.size.height)
        let scaled = NSImage(size: CGSize(width: width, height: side))
        scaled.lockFocus()
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: side))
        scaled.unlockFocus()
        return Image(nsImage: scaled)
        #else
        guard let source = UIImage(data: data), source.size.height > 0 else { return nil }
        let width = side * (source.size.width / source.size.height)
        let size = CGSize(width: width, height: side)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        return Image(uiImage: scaled)
        #endif
    }
}
