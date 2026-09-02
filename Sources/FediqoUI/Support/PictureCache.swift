import SwiftUI
#if canImport(ImageIO)
import ImageIO
#endif

/// Every picture a row draws, held somewhere a row cannot lose it.
///
/// **The bug this exists for (#91).** `AsyncImage` keeps its result for the lifetime of the view
/// that asked for it and nowhere else, so a row rebuilt for any reason starts again from nothing.
/// Whether a reader ever sees a picture then depends on whether the rebuilding stops before they
/// look — and it was measured not stopping: the same attachment printed `success`, then `empty`,
/// then `empty`, and the third is what a screenshot caught. A taller card means taller rows, taller
/// rows mean more re-measuring, and the reader's largest text means more again, so what a reader
/// gets was decided by how much layout their screen happened to be doing.
///
/// **This app already learned this once.** `EmojiCache` exists because a picture inside a `Text`
/// cannot be re-fetched per view. Attachments and avatars were the last thing still relying on a
/// view staying alive, and they are the ones a reader actually looks at.
///
/// Kept by address and by screen: a picture decoded for one screen's pixels is soft on another's.
/// **Not by the size it is drawn at**, unlike `EmojiCache` — what goes in a row is `resizable`, so
/// one decode serves an avatar, a card and the opened viewer, and keying by size would decode the
/// same photograph three times over.
@MainActor
@Observable
final class PictureCache {
    static let shared = PictureCache()

    struct Key: Hashable {
        let url: URL
        let scale: CGFloat
    }

    private var pictures: [Key: Image] = [:]
    /// What has been asked for and answered with nothing. Held so that a picture which is not
    /// there is drawn as absent rather than as forever arriving — and so it is asked for once
    /// rather than on every rebuild of every row that shows it.
    private var missing: Set<Key> = []

    /// The task drawing each picture while it is being drawn, so that every view wanting the same
    /// one waits on the same work and a view going away does not take that work with it.
    ///
    /// `@ObservationIgnored` because a task starting is not a reason to redraw anything. What a
    /// view watches is `pictures`, which changes once — when there is something to draw.
    @ObservationIgnored private var inFlight: [Key: Task<Void, Never>] = [:]

    /// How many decoded pictures are kept. A timeline read for an hour would otherwise hold every
    /// photograph it had ever drawn, and a photograph is not a 20-point emoji.
    ///
    /// Least recently *asked for* rather than least recently drawn: asking is what a row does on
    /// every pass, so the ones on screen keep themselves alive without anything having to watch
    /// what is on screen.
    static let held = 120
    @ObservationIgnored private var order: [Key] = []

    /// The picture, where it is already in hand. Draws on the first pass, which is what removes
    /// the flash of the waiting shape every time a reader scrolls back to a row.
    func picture(_ url: URL?, scale: CGFloat) -> Image? {
        guard let url else { return nil }
        let key = Key(url: url, scale: scale)
        guard let picture = pictures[key] else { return nil }
        touch(key)
        return picture
    }

    /// Whether this one has been asked for and came back with nothing.
    func isMissing(_ url: URL?, scale: CGFloat) -> Bool {
        guard let url else { return false }
        return missing.contains(Key(url: url, scale: scale))
    }

    /// Fetches and decodes it, unless somebody already is or already has.
    func fetch(_ url: URL?, scale: CGFloat) async {
        guard let url else { return }
        let key = Key(url: url, scale: scale)
        guard pictures[key] == nil, !missing.contains(key) else { return }
        await work(for: key).value
    }

    private func work(for key: Key) -> Task<Void, Never> {
        if let running = inFlight[key] { return running }
        let started = Task { @MainActor [weak self] in
            defer { self?.inFlight[key] = nil }
            guard let data = try? await URLSession.shared.data(from: key.url).0 else {
                self?.missing.insert(key)
                return
            }
            let decoded = await Task.detached(priority: .utility) { Self.decode(data) }.value
            guard let decoded else {
                self?.missing.insert(key)
                return
            }
            self?.keep(Image(decorative: decoded, scale: key.scale), for: key)
        }
        inFlight[key] = started
        return started
    }

    private func keep(_ picture: Image, for key: Key) {
        pictures[key] = picture
        touch(key)
        while order.count > Self.held, let oldest = order.first {
            order.removeFirst()
            pictures[oldest] = nil
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// The first frame of whatever it is. `ImageIO` rather than `NSImage`/`UIImage` for the reason
    /// `EmojiCache` uses it: it is the one API on both platforms that reads every format a server
    /// sends without being told which it is.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
