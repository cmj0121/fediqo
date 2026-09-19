import FediqoCore
import Foundation
import ImageIO
import SwiftUI
#if DEBUG
import Synchronization
#endif

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The pictures a post is partly written in: fetched once, decoded at the size the line will
/// draw them at, and held under a budget a hostile instance cannot talk its way past.
///
/// Keyed by address, ink height, screen scale, the source it was read through **and** whether
/// the reader asked for stillness, because none of those can be changed after the fact: a
/// picture that goes into a `Text` is already the size it will be drawn, a picture decoded for
/// one screen's pixels is soft on another's, and a still is one frame where a moving one is
/// forty.
///
/// Not `@Observable`, and that is the point. A hundred lines of a timeline each carry a handful
/// of shortcodes through here, so a cache that announced every arrival would wake every line on
/// screen for one emoji that only one of them draws. What a line watches instead is its own
/// `@State`, filled by its own `.task` — the finest granularity there is. Eviction announces
/// nothing at all.
@MainActor
final class EmojiCache {
    static let shared = EmojiCache()

    private let http: HTTPClient
    private var entries: [Key: Entry] = [:]
    private var cost = 0
    /// A counter, not a date: what recency needs is an order, and a monotonic tick is one that
    /// no clock change can walk backwards.
    private var tick: UInt64 = 0
    private var inFlight: [Key: Task<Void, Never>] = [:]
    /// One download per address, whoever asked for it — see `download(_:)`.
    private var downloads: [URL: Task<Data?, Never>] = [:]
    private let gate = EmojiGate(ceiling: EmojiCache.maxInFlight)
    private var cuts: [Cut: [EmojiRun]] = [:]
    private var cutOrder: [Cut] = []
    /// Which cohort of work is current. Bumped by every one of the three ways of forgetting, and
    /// checked by a task before it files what it decoded — see `work(for:pixels:)`.
    ///
    /// Private, and it publishes nothing: this is not a signal any view subscribes to, which is
    /// the one thing a counter like this must not become here.
    private var epoch: UInt64 = 0

    init(http: HTTPClient = URLSessionClient()) {
        self.http = http
    }

    // MARK: - The bounds
    //
    // These are not independent. The budget is only *provable* if no entry the cache will admit
    // can be larger than the mark eviction runs down to — otherwise the freshest arrival is
    // evicted to make room for itself, the view finds nothing held, and it asks again for ever.
    // That inequality is
    //
    //     entryOverhead + maxFrameBytes × maxFramesPerEmoji ≤ lowWaterBytes
    //
    // and `theBoundsAreMutuallyConsistent` holds it, so moving any one of these numbers without
    // moving the others fails a test rather than shipping a refetch loop.
    //
    // **A worst-case budget term must be solved against what can occur, not against what might
    // occur someday.** This is the distinction that matters for the next constant of this kind,
    // because it will look like the first case and behave like the second.
    // `ShellPictures.maxPixels` is a *clamp on incoming data*: ImageIO never scales up, so a
    // small preview stays small and headroom there costs nothing unless a large picture actually
    // arrives — an unreached ceiling is free. `maxDrawnPixelSide` below is a *term in a
    // worst-case inequality* that statically bounds the frame ceiling for every emoji, so its
    // headroom is paid unconditionally, by every animated file, in frames it may not have. A
    // clamp may be generous; a budget term may not.
    //
    // The first solution of these got that backwards — not wrong by judgement, but **solved in
    // the wrong direction**. The frame ceiling was derived from the pixel cap, when the pixel cap
    // should be derived from the ladder and the frame ceiling from the content. At a cap of 192
    // no value of `maxFramesPerEmoji` could exceed 49, so a two-second loop at 25 frames a second
    // — 50 frames, the realistic content maximum — was not expressible at all: a structural
    // exclusion of a real shape rather than a conservative number. Both constants are fine once
    // the order is reversed, and `theCeilingClearsRealContent` and `thePixelCapIsPinnedToTheLadder`
    // now pin the ceiling from below and the cap from both sides, so the same mistake fails the
    // suite instead of waiting to be computed out of the source by a reviewer a unit later.

    /// Everything the cache holds at once, counted in decoded bytes.
    ///
    /// Counted in bytes and never in entries: this branch has shipped a cache bounded by how
    /// many things were in it while the things differed in size by three orders of magnitude,
    /// and it was demonstrated refetching in a loop. An emoji is drawn at the font's own ink
    /// height, so at the default text size on a 2× screen one still frame is about
    /// 50 × 50 × 4 ≈ 10 KB — 24 MB is on the order of two thousand of them, far more than a
    /// timeline ever has on screen, and a quarter of the 96 MB the picture cache is given for
    /// photographs. That is the right proportion for something numerous and individually tiny.
    nonisolated static let maxCachedBytes = 24 << 20

    /// What one record costs before a single pixel is counted.
    ///
    /// A fetch that came back with nothing, and a decode too large to keep, are both recorded
    /// rather than forgotten — otherwise "not held" and "never asked for" look the same to
    /// every view and the line asks again for ever. Charging those records a fixed overhead is
    /// what keeps them bounded: the byte budget then caps the number of entries too, at
    /// `maxCachedBytes / entryOverhead`, so one bound governs both and no separate count bound
    /// can drift away from it.
    nonisolated static let entryOverhead = 1024

    /// How many frames of one emoji are ever decoded. Refused from `CGImageSourceGetCount`
    /// before a single frame is rasterised, because counting is cheap and decoding 500 frames
    /// to discover there were 500 is not.
    ///
    /// **Chosen by content, not by what the budget happens to allow.** At the cap below the
    /// inequality would admit 71; 60 is taken because decision 2 sets a 20-frames-a-second clock,
    /// so 60 frames is exactly three seconds of this app's own animation — past the one- and
    /// two-second loops real custom emoji are authored as, and past the 50-frame realistic worst
    /// case (two seconds at 25 fps) with twenty per cent to spare. A file needing more than three
    /// seconds of animation inside a line of text is not an emoji.
    ///
    /// A file with more frames than this is drawn as its first frame. That is correct rather than
    /// a degradation: the reader still sees the right picture, and "first frame, no clock" is
    /// already a designed state — it is what a reader who asked for reduced motion gets — so
    /// there is nothing to announce and no way to tell the two apart. What *was* missing is the
    /// developer-facing half, since nothing said a ceiling of 40 was excluding real files; that
    /// is `clippedForFrameCount` below.
    nonisolated static let maxFramesPerEmoji = 60

    /// The tallest a frame is ever decoded, in device pixels.
    ///
    /// **Derived from the ladder, which is the only thing that can reach it.** The preference
    /// tops out at `.accessibility1`, whose body ink measures 33 points, so the largest ink the
    /// app can ask for on a 3× screen is 99 device pixels. 160 clears that with room for a rung
    /// or a scale to be added before anybody has to re-solve, and puts one square frame at
    /// 160 × 160 × 4 = 100 KB.
    ///
    /// Not 192, which was speculation about a 4× screen that does not exist — and because this is
    /// a budget term rather than a clamp, that speculation was paid for by every animated emoji
    /// in frames it could not have. Not the measured 99 either: the ink is derived as a height
    /// rather than read off a point size, so pinning to exactly the reachable maximum risks a
    /// rounding difference making every emoji soft.
    nonisolated static let maxDrawnPixelSide = 160

    /// How much wider than tall a frame may be drawn.
    ///
    /// Height is what the line fixes; width follows the picture's own shape, so without this a
    /// 50:1 banner served as an emoji would make a "192-pixel" frame a megabyte and the pixel
    /// cap above would not be a byte cap at all. Three times as wide as it is tall is already a
    /// banner rather than an emoji; past that the picture is drawn shorter than the ink rather
    /// than wider than the bound.
    nonisolated static let maxDrawnAspect: CGFloat = 3

    /// The least of the line's ink a picture may be drawn at before the shortcode serves the
    /// reader better.
    ///
    /// The width cap keeps a banner in shape by giving up height, which is the right trade right
    /// up until the height is gone: a 1024 × 1 source comes out 0.14 points tall and a 500 × 1 at
    /// 0.38 — bounded, consistent, and invisible. Because height is only ever given up to the
    /// aspect cap, a quarter of the ink is exactly "wider than twelve to one", which no emoji
    /// anybody registers is and a hostile instance's vanishing act is. Below it the picture is
    /// refused and the shortcode stands, which is at least readable.
    nonisolated static let minimumDrawnFraction: CGFloat = 0.25

    /// The most one frame can occupy, which is the term that makes the budget checkable rather
    /// than merely asserted: the widest a frame may be is `maxDrawnPixelSide × maxDrawnAspect`,
    /// the tallest is `maxDrawnPixelSide`, and eight bits a channel over four channels is what
    /// the normalisation below guarantees.
    nonisolated static var maxFrameBytes: Int {
        maxDrawnPixelSide * Int((CGFloat(maxDrawnPixelSide) * maxDrawnAspect).rounded()) * 4
    }

    /// The largest source this will decode at all, in pixels on a side, read from the source's
    /// properties before anything is rasterised — and read for **every** frame it will decode,
    /// not only the first. A multi-image container can put a tiny frame first and an enormous
    /// one after it, which is exactly the transient decode this bound exists to refuse.
    ///
    /// Sixteen times the largest an emoji is ever drawn, so nothing a server legitimately
    /// serves is refused, and small enough that the full decode ImageIO may perform on its way
    /// to a thumbnail stays at 1024 × 1024 × 4 = 4 MB rather than the sixteen the picture cache
    /// was caught holding.
    nonisolated static let maxSourcePixelSide = 1024

    /// How many of this cache's requests are open at once, across every line on screen.
    ///
    /// Six, the browser convention for per-host concurrency over HTTP/1.1 and so the closest
    /// thing to a norm a stranger's instance will have been provisioned against. Deliberately
    /// not the picture cache's four: that number is sized as resident body bytes — four
    /// multi-megabyte photographs — and an emoji body is tiny and numerous, so bytes do not bind
    /// here at any plausible number. What binds an emoji budget is politeness to somebody else's
    /// server, which is a different quantity with a different answer.
    ///
    /// Emoji and attachments come from the **same host**, so the app's worst case is ten
    /// simultaneous connections to one stranger's instance, which is within what a browser
    /// opens. One per-host gate spanning both caches would be more correct and is the thing to
    /// build if a real instance ever objects; it is not built because it is shared machinery
    /// across two files for the difference between ten and six, and `httpMaximumConnectionsPerHost`
    /// is unenforced here, so it would be from scratch.
    ///
    /// First come, first served, with no priority and no queue-jumping between lines — and that
    /// is structural rather than a taste for simplicity. The queue is filled by `body` being
    /// evaluated, and SwiftUI evaluates bodies only for rows it has realised, so a reader
    /// scrolled to the bottom never enqueues the top of the timeline at all. First-come
    /// therefore already approximates "what is on screen, in reading order" — which is what a
    /// priority scheme would be reconstructing — and building one would need the cache to know
    /// which line the reader is looking at, a signal it does not have.
    nonisolated static let maxInFlight = 6

    #if DEBUG
    /// How many files have been drawn as a still because they carried more frames than the
    /// ceiling. Debug builds only, and nothing draws with it.
    ///
    /// The reader is told nothing and should not be — see `maxFramesPerEmoji`. This is the other
    /// half: a ceiling that quietly excludes real content is invisible to whoever set it, which
    /// is how a ceiling of 40 survived until somebody worked the inequality out by hand. A number
    /// that moves while a developer is looking at a timeline is what should have said so.
    nonisolated static let clippedForFrameCount = Mutex<Int>(0)
    #endif

    /// Eviction runs down to here rather than to the budget itself, so a full cache does not
    /// order its keys again on every single arrival.
    nonisolated static var lowWaterBytes: Int { maxCachedBytes - maxCachedBytes / 8 }

    /// How many cut lines are remembered, and how long a line may be to be worth remembering.
    ///
    /// **Both, because a count bound alone is the defect this branch keeps shipping.** The memo
    /// key holds the line itself, and a post body comes from an untrusted instance with no
    /// length bound anywhere in Core — 512 remembered lines of 200 KB is a hundred megabytes
    /// held outside the budget above for the life of the process. So a long line is not
    /// remembered at all, which bounds what the memo can hold at
    /// `maxRememberedLines × maxMemoisedLine` and a copy again for the runs.
    ///
    /// Skipping the long ones costs nothing: hashing a 200 KB `String` walks all 200 KB, which
    /// is the same order as the scan the memo exists to save. Mastodon's own post limit is 500
    /// characters, and a name, a handle and a spoiler line are shorter still.
    ///
    /// The length is counted in UTF-8 bytes, so a CJK line reaches the bound at about 680
    /// characters where an ASCII one reaches it at 2048 — a third of the allowance, in the script
    /// where the scan the memo exists to avoid is most expensive. Deliberate: 680 still clears
    /// the 500-character limit in any script, and counting graphemes to be fair about it would
    /// mean walking the clusters this is trying not to walk.
    nonisolated static let maxRememberedLines = 256
    nonisolated static let maxMemoisedLine = 2048

    // MARK: - What a line asks for

    /// The two numbers a line of text gives a picture standing in it: how tall it is, and how
    /// far under the baseline it sits. Both come from the font rather than from the point size,
    /// which is not the same thing — a 13-point font's letters are not 13 points of ink.
    struct Metrics: Hashable, Sendable {
        let side: CGFloat
        let baseline: CGFloat
    }

    /// One picture, at one size, on one screen, read through one source, for one reader's
    /// answer about movement.
    struct Key: Hashable, Sendable {
        let url: URL
        let metrics: Metrics
        let scale: CGFloat
        /// The source the post was read through — not the address's own host, which is usually
        /// a CDN and cannot be read back off the URL. It is what the reader's per-server Clear
        /// button reaches these pictures by.
        ///
        /// In the key, so one emoji read through two sources is two entries. A set of hosts on
        /// one shared entry was considered and refused: **an entry shared by a set frees no
        /// memory until the last host goes**, which is the opposite of what the button promises
        /// the reader. What it costs instead is about ten kilobytes per (host, size) pair against
        /// a 24 MB budget — three orders of magnitude cheaper than duplicating a photograph —
        /// and `download(_:)` below has already removed the expensive half, which is the request
        /// rather than the decode.
        let host: String
        /// In the key because it changes what is decoded, not only what is fetched: where a
        /// server offered no still, the still and the moving copy are the same address and
        /// would otherwise share one entry holding whichever was asked for first.
        let still: Bool

        /// Folds the host — **belt, not the statement of the rule.**
        ///
        /// Decision 21 puts the rule at the boundary: a host is folded once, where it enters,
        /// and every consumer may then compare exactly. See `ShellPictures.tag` for where those
        /// boundaries are and why bare `lowercased()` is the only acceptable form. This key is
        /// one consumer among several and does not get to redefine the contract; what it buys is
        /// that the *particular* miss below cannot happen even if a call site is wrong.
        ///
        /// That miss is worth naming, because it is why this is cheap enough to keep. Before the
        /// fold, `forget(host:)` and `holding(host:)` compared the same unfolded way, so **the
        /// leak and the reading were wrong together**: entries up to the whole 24MB budget could
        /// sit there for the run while the pane printed "No pictures held" beside them, and
        /// nothing anywhere would report it. Matching the reading to the sweep — which is what
        /// the first version of `holding` did — deletes the symptom and keeps the bug.
        init(url: URL, metrics: Metrics, scale: CGFloat, host: String, still: Bool) {
            self.url = url
            self.metrics = metrics
            self.scale = scale
            self.host = host.lowercased()
            self.still = still
        }
    }

    /// What one line wants, and what its `.task(id:)` watches: it asks again when its emoji, its
    /// size, its screen or the reader's answer about movement change, and never in between.
    struct Request: Hashable, Sendable {
        let emojis: [CustomEmoji]
        let metrics: Metrics
        let scale: CGFloat
        /// The source this line was read through. Required, and not derived from the address: a
        /// `CustomEmoji` carries no source of its own, so the call site has to say.
        let host: String
        let still: Bool

        /// Where the picture is fetched from. A reader who asked for less movement is given the
        /// copy the server says does not move; where a server offered none, the moving one is
        /// decoded to its first frame, which is the same picture standing still.
        func address(of emoji: CustomEmoji) -> URL {
            still ? (emoji.staticURL ?? emoji.url) : emoji.url
        }

        func key(for emoji: CustomEmoji) -> Key {
            Key(url: address(of: emoji), metrics: metrics, scale: scale, host: host, still: still)
        }

        /// How tall the picture is decoded, in device pixels, clamped to the bound so that no
        /// environment this view is placed in can ask for a frame larger than the budget was
        /// reasoned about.
        var pixels: Int {
            min(max(1, Int((metrics.side * scale).rounded())), EmojiCache.maxDrawnPixelSide)
        }
    }

    /// One emoji, decoded: the frames in order, the instant each gives way to the next measured
    /// from the start of the loop, and how tall the line draws them. A still is one frame and is
    /// drawn without a clock ever starting.
    struct Frames {
        let images: [Image]
        let ends: [TimeInterval]
        let bytes: Int
        /// How tall the picture is drawn, in points. Held rather than recomputed because it is
        /// the property this whole file exists for, and a test can read it without a screen.
        let drawnHeight: CGFloat

        init(images: [Image], ends: [TimeInterval], bytes: Int, drawnHeight: CGFloat = 0) {
            self.images = images
            self.ends = ends
            self.bytes = bytes
            self.drawnHeight = drawnHeight
        }

        /// Nothing came back, or what came back could not be kept. The line draws the shortcode
        /// it would have drawn anyway, and nobody asks again until something clears the record.
        static let absent = Frames(images: [], ends: [], bytes: 0)

        var moves: Bool { images.count > 1 }
        var span: TimeInterval { ends.last ?? 0 }
        var isAbsent: Bool { images.isEmpty }

        /// The shortest a frame of this one stands for. What the line's clock is set by, so a
        /// file authored at ten frames a second costs ten redraws and not twenty-five.
        var shortestFrame: TimeInterval {
            guard ends.count > 1 else { return 0 }
            var shortest = ends[0]
            for index in 1..<ends.count {
                shortest = min(shortest, ends[index] - ends[index - 1])
            }
            return shortest
        }

        /// The frame to draw at this instant. The instant is a wall clock rather than a position
        /// in the loop, so every emoji on the screen runs off the same one and none of them has
        /// to remember where it had got to.
        func image(at instant: TimeInterval) -> Image? {
            guard let first = images.first else { return nil }
            guard images.count > 1 else { return first }
            return images[EmojiClock.index(at: instant, ends: ends)]
        }
    }

    // MARK: - The ink a line gives a picture

    /// The ink of a line set at this many points: from the top of an ascender to the bottom of a
    /// descender, rounded to whole points so two lines a fraction apart share one decode.
    nonisolated static func metrics(points: CGFloat) -> Metrics {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: points)
        #else
        let font = UIFont.systemFont(ofSize: points)
        #endif
        return metrics(ascender: font.ascender, descender: font.descender)
    }

    /// The arithmetic on its own, so it can be checked without a screen or a font.
    nonisolated static func metrics(ascender: CGFloat, descender: CGFloat) -> Metrics {
        Metrics(side: max(1, (ascender - descender).rounded()), baseline: descender.rounded())
    }

    /// How tall a picture of this shape is drawn, in points, in a line whose ink is `side`.
    ///
    /// The height is the line's ink — that is the property this file exists for — except where
    /// keeping the source's own shape would make the picture wider than `maxDrawnAspect`, when
    /// the width is what is capped and the picture comes out shorter than the ink rather than
    /// wider than the bound.
    nonisolated static func drawnHeight(sourceWidth: Int, sourceHeight: Int, side: CGFloat) -> CGFloat {
        guard sourceWidth > 0, sourceHeight > 0, side > 0 else { return max(side, 0) }
        let aspect = CGFloat(sourceWidth) / CGFloat(sourceHeight)
        return side * min(1, maxDrawnAspect / aspect)
    }

    /// Whether a picture drawn this tall in a line of this ink is worth drawing at all.
    nonisolated static func isVisible(drawnHeight: CGFloat, side: CGFloat) -> Bool {
        guard side > 0 else { return false }
        return drawnHeight >= side * minimumDrawnFraction
    }

    /// What `Image(decorative:scale:)` has to be given so a frame of this many pixels draws
    /// exactly `points` points tall.
    ///
    /// **It cannot be the screen's scale.** `kCGImageSourceThumbnailMaxPixelSize` is a maximum
    /// and ImageIO never upscales, so a 32-pixel emoji — which is what Mastodon serves, because
    /// it does not resize an upload — comes back 32 pixels however tall the line asked for.
    /// Handing that to the screen's scale drew it at half the height of the letters beside it.
    /// The scale is therefore read off the frame that actually came back.
    nonisolated static func imageScale(pixelHeight: Int, points: CGFloat) -> CGFloat {
        guard points > 0 else { return 1 }
        return max(CGFloat(pixelHeight), 1) / points
    }

    // MARK: - Reading

    /// What is in hand for this line, by shortcode. A pure read: recency is taken in `fetch`,
    /// once per line rather than once per frame of every render.
    func held(_ request: Request) -> [String: Frames] {
        var found: [String: Frames] = [:]
        for emoji in request.emojis {
            if let entry = entries[request.key(for: emoji)] {
                found[emoji.shortcode] = entry.frames
            }
        }
        return found
    }

    /// The cut of one line, made once and remembered.
    ///
    /// `CustomEmoji.runs` is linear and fast on post-sized input, but about 25 times slower per
    /// character when the text is built from long grapheme clusters — a ZWJ family sequence
    /// assembles and heap-allocates a 25-byte `Character` on every read — and a line is asked
    /// for on every pass of every row it appears in. So the scan happens once per line and every
    /// later pass is a dictionary lookup whose key hashes over UTF-8 rather than over graphemes.
    func runs(in text: String, from emojis: [CustomEmoji]) -> [EmojiRun] {
        // A post nobody sent a picture for is the fast path in the scanner itself — one run and
        // no scan. A line longer than the memo will hold is not remembered either: see
        // `maxMemoisedLine` for why remembering it would cost what it saves and hold what the
        // budget above cannot see.
        guard !emojis.isEmpty, text.utf8.count <= Self.maxMemoisedLine else {
            return CustomEmoji.runs(in: text, from: emojis)
        }
        let cut = Cut(text: text, emojis: emojis)
        if let remembered = cuts[cut] { return remembered }
        let made = CustomEmoji.runs(in: text, from: emojis)
        cuts[cut] = made
        cutOrder.append(cut)
        if cutOrder.count > Self.maxRememberedLines {
            cuts.removeValue(forKey: cutOrder.removeFirst())
        }
        return made
    }

    // MARK: - Fetching

    /// Fetches and decodes whatever of this line is not already in hand.
    ///
    /// Every picture of the line is started at once and the ceiling does the bounding: a line is
    /// a handful of shortcodes but a screen is a hundred lines, so what must be bounded is the
    /// cache's total, not each line's. Serialising within a line bounded nothing — a hundred
    /// lines still opened a hundred requests — while costing the one case parallelism helps: a
    /// line with fifty distinct emoji was fifty sequential round trips, some seven seconds of
    /// the reader watching shortcodes. Through the gate it is nine rounds of six, about a
    /// second, which is what makes "draw the shortcode while waiting" a reasonable interim state
    /// rather than a visible defect.
    ///
    /// The work belongs to the cache and not to the view that asked for it. A `.task(id:)` is
    /// cancelled every time its view is laid out again with a different id, and a cancelled
    /// fetch that had claimed the key would leave every other line waiting on work nobody was
    /// doing. So `inFlight` holds the task rather than the fact of one, every caller awaits the
    /// same task, and cancelling a view cancels only that view's waiting.
    func fetch(_ request: Request) async {
        var running: [Task<Void, Never>] = []
        for emoji in request.emojis {
            let key = request.key(for: emoji)
            if entries[key] != nil {
                touch(key)
                continue
            }
            running.append(work(for: key, pixels: request.pixels))
        }
        for task in running { await task.value }
    }

    /// The one task decoding this picture at this size, started if nobody has started it.
    private func work(for key: Key, pixels: Int) -> Task<Void, Never> {
        if let running = inFlight[key] { return running }
        // Read before the first suspension, so it is the cohort this work belongs to rather than
        // whatever the epoch has become by the time the picture lands.
        let mine = epoch
        let started = Task { @MainActor [weak self] in
            defer { self?.inFlight[key] = nil }
            guard let self else { return }
            var decoded: Decoded?
            if let data = await download(key.url).value {
                decoded = await Task.detached(priority: .utility) {
                    Self.decode(data, ink: pixels, stillOnly: key.still)
                }.value
            }
            // Struck off if anything was forgotten while this was on the wire. Without it a
            // reader who pressed Clear watches the emoji they just cleared reappear a moment
            // later, filed under the very host they cleared — and the kick that drops records of
            // nothing is undone by a decode that was already running.
            guard epoch == mine else { return }
            store(Self.kept(decoded, side: key.metrics.side), for: key)
        }
        inFlight[key] = started
        return started
    }

    /// What to keep for this key: the frames, or a record of nothing — because there was nothing
    /// to decode, or because the picture would be drawn too short to be seen.
    private static func kept(_ decoded: Decoded?, side: CGFloat) -> Frames {
        guard let decoded else { return .absent }
        let frames = Frames(decoded, side: side)
        return isVisible(drawnHeight: frames.drawnHeight, side: side) ? frames : .absent
    }

    /// One request per address, whoever asked for it.
    ///
    /// **Separate from `inFlight`, and that is the point.** A cache key carries the ink height,
    /// the screen and the source as well as the address, because those decide what is *decoded*
    /// — but they do not decide what is *downloaded*. The same `:blobcat:` stands in a dozen
    /// posts, and in the name and the body of one post at two different sizes; keyed by the
    /// whole entry, that was a separate request every time. Custom emoji repeat heavily on a
    /// real timeline, so this is the difference between a handful of requests and a hundred,
    /// and it comes before any ceiling.
    ///
    /// **It spans concurrent flight only** — this is a map of what is on the wire, not a cache of
    /// bodies. Two inks asking for one address at the same moment is one request; asking one
    /// after the other, once the first has landed and been filed, is two. That is the intended
    /// shape: holding decoded frames per size is the cache's job, and holding the bytes as well
    /// would be a second budget to bound.
    ///
    /// Every address goes through `HTTPClient`: the live one carries the `https`-only rule and
    /// refuses anything that is not an HTTP response, which is what stops a `file:` or `data:`
    /// address out of a stranger's JSON from reaching `URLSession` at all.
    private func download(_ url: URL) -> Task<Data?, Never> {
        if let running = downloads[url] { return running }
        let http = http
        let started = Task<Data?, Never> { @MainActor [weak self] in
            defer { self?.downloads[url] = nil }
            guard let self else { return nil }
            await gate.enter()
            defer { gate.leave() }
            guard let (data, response) = try? await http.data(from: url),
                  (200..<300).contains(response.statusCode)
            else { return nil }
            return data
        }
        downloads[url] = started
        return started
    }

    // MARK: - Keeping

    private struct Entry {
        let frames: Frames
        let cost: Int
        var used: UInt64
    }

    private struct Cut: Hashable {
        let text: String
        let emojis: [CustomEmoji]
    }

    private func touch(_ key: Key) {
        tick &+= 1
        entries[key]?.used = tick
    }

    /// Admission control, then eviction.
    ///
    /// A decode that cannot be kept is declined rather than emptying the cache to make room for
    /// it, and the decline is recorded so that "arrived and was not kept" is a state the cache
    /// can rest in. Without that, the one key that will never fit evicts everything else on
    /// every pass and the screen refetches for ever — which is the failure this cache is
    /// downstream of, in a cache that had no such rule.
    func store(_ frames: Frames, for key: Key) {
        let cost = frames.bytes + Self.entryOverhead
        guard cost <= Self.maxCachedBytes else {
            store(.absent, for: key)
            return
        }
        if let existing = entries.removeValue(forKey: key) { self.cost -= existing.cost }
        tick &+= 1
        entries[key] = Entry(frames: frames, cost: cost, used: tick)
        self.cost += cost
        evict(keeping: key)
    }

    /// Down to the low-water mark, oldest first, and **never the entry just handed in**.
    ///
    /// The bounds above are solved so that no admissible entry is larger than the low-water
    /// mark, which already forbids an arrival being evicted to make room for itself. This is the
    /// second belt: the failure it prevents — a view finding nothing held, `fetch` seeing no
    /// entry, and a multi-megabyte body fetched again every turn — is the one this branch has
    /// shipped twice, and it is too expensive to rest on arithmetic alone.
    private func evict(keeping newest: Key) {
        guard cost > Self.maxCachedBytes else { return }
        for key in entries.keys.sorted(by: { entries[$0]!.used < entries[$1]!.used }) {
            guard cost > Self.lowWaterBytes else { return }
            guard key != newest else { continue }
            cost -= entries.removeValue(forKey: key)?.cost ?? 0
        }
    }

    // MARK: - Forgetting

    /// Everything read through one source: its emoji pictures and its records of nothing.
    ///
    /// What the reader's per-server Clear button reaches these pictures by. The host is the one
    /// the post was read through, recorded in the key where it was stored, because an emoji
    /// address usually points at a CDN and cannot be traced back to a server.
    func forget(host: String) {
        let host = host.lowercased()
        epoch &+= 1
        for (key, entry) in entries where key.host == host {
            cost -= entry.cost
            entries.removeValue(forKey: key)
        }
    }

    /// Every record of a fetch that came back with nothing.
    ///
    /// Recording an absence is what stops the refetch loop, but it makes a reader who opened the
    /// app offline see shortcodes for the rest of the run: the record costs 1024 bytes and would
    /// not age out of a 24 MB budget until some twenty thousand more arrived, while an offline
    /// reader makes perhaps fifty. So the way back is a kick from outside rather than eviction —
    /// this is what the scene becoming active calls.
    func forgetAbsences() {
        epoch &+= 1
        for (key, entry) in entries where entry.frames.isAbsent {
            cost -= entry.cost
            entries.removeValue(forKey: key)
        }
    }

    /// Every picture and every remembered cut.
    func clear() {
        epoch &+= 1
        entries.removeAll()
        cuts.removeAll()
        cutOrder.removeAll()
        cost = 0
    }

    /// What this device is holding that was read through one source: how many pictures, and what
    /// they cost. The reading beside the reader's Clear button on Usage.
    ///
    /// Records of nothing are not counted. They cost `entryOverhead` each and they are real
    /// state a Clear drops, but "3 emoji held" beside a server that drew none of them is a
    /// reading about the cache's bookkeeping rather than about anything the reader saw.
    /// Folds the host exactly as `Key` and `forget(host:)` do. The three have to agree: a
    /// reading that folds where the sweep does not counts pictures the button will not drop, and
    /// one that does not fold where the sweep does reports zero for pictures that are there.
    func holding(host: String) -> (count: Int, bytes: Int) {
        let host = host.lowercased()
        var count = 0
        var bytes = 0
        for (key, entry) in entries where key.host == host && !entry.frames.isAbsent {
            count += 1
            bytes += entry.cost
        }
        return (count, bytes)
    }

    /// What the cache is holding. For a test to read; nothing draws with any of it.
    var bytesHeld: Int { cost }
    var entriesHeld: Int { entries.count }
    var linesRemembered: Int { cuts.count }

    // MARK: - Decoding

    /// Every frame there is, drawn at the size the line will show it at.
    ///
    /// `ImageIO` and not `NSImage`/`UIImage`: it is the one API on both platforms that will say
    /// how many frames a file has and how long each of them stands, and it reads GIF, APNG and
    /// WebP — which between them is what a server's custom emoji are.
    ///
    /// `ink` is how tall the picture is wanted, in device pixels. The thumbnail cap is set from
    /// the source's own shape so that the *height* lands on the ink rather than the longer side,
    /// because the height is what a line of text fixes. ImageIO will hand back something smaller
    /// when the source is smaller — it never upscales — and `Frames.init` corrects for that by
    /// reading the scale off the frame rather than off the screen.
    nonisolated static func decode(_ data: Data, ink: Int, stillOnly: Bool) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let available = CGImageSourceGetCount(source)
        guard available > 0 else { return nil }

        let wanted = stillOnly || available > maxFramesPerEmoji ? 1 : available
        #if DEBUG
        if !stillOnly, available > maxFramesPerEmoji {
            clippedForFrameCount.withLock { $0 += 1 }
        }
        #endif
        guard let size = sourceSize(source, frames: wanted) else { return nil }

        let height = min(max(1, ink), maxDrawnPixelSide)
        let ratio = CGFloat(size.width) / CGFloat(max(1, size.height))
        let longest = ratio > 1 ? Int((CGFloat(height) * min(ratio, maxDrawnAspect)).rounded()) : height
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, longest),
        ]

        var images: [CGImage] = []
        var delays: [TimeInterval] = []
        var bytes = 0
        for index in 0..<wanted {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
                  let frame = eightBit(thumbnail)
            else { continue }
            images.append(frame)
            bytes += frame.bytesPerRow * frame.height
            delays.append(EmojiClock.step(declared: duration(of: source, at: index)))
        }
        guard !images.isEmpty else { return nil }
        return Decoded(images: images, ends: EmojiClock.ends(from: delays), bytes: bytes,
                       sourceWidth: size.width, sourceHeight: size.height)
    }

    /// One emoji's frames as they come off the decoder, before a screen has seen them, and the
    /// shape of the source they were read from — which is what decides how tall the line draws
    /// them.
    struct Decoded: @unchecked Sendable {
        let images: [CGImage]
        let ends: [TimeInterval]
        let bytes: Int
        let sourceWidth: Int
        let sourceHeight: Int
    }

    /// How big the source says it is, refused here if any frame that will be decoded is larger
    /// than an emoji can be.
    ///
    /// Read from the source's properties, which rasterise nothing: refusing a frame count and a
    /// pixel size *before* decoding them is the whole point, since the cost this bounds is the
    /// decode and not the answer.
    ///
    /// **Checked is exactly decoded.** `frames` is `wanted`, and `wanted` is the set the loop
    /// below rasterises, in all three modes — every frame of an ordinary animation, frame zero
    /// alone for a reader who asked for stillness, and frame zero alone for a container with more
    /// frames than the bound. So the guarantee is not "the first frame" and not "every frame in
    /// the file": it is that nothing is rasterised that was not measured first. Before this, a
    /// multi-image container could put an 8 × 8 frame first and a 4000 × 4000 one behind it and
    /// only the first was ever looked at. A source that will not say how big it is is refused
    /// too: a picture that cannot be measured cannot be bounded.
    ///
    /// Frames are allowed to disagree about their size. An optimised GIF stores each frame as
    /// the sub-rectangle that changed, and ImageIO composites those onto the canvas when it
    /// decodes them — so demanding agreement here would refuse the ordinary animated emoji.
    /// The shape returned is frame zero's, which for such a file is the canvas.
    private nonisolated static func sourceSize(_ source: CGImageSource,
                                               frames: Int) -> (width: Int, height: Int)? {
        var first: (width: Int, height: Int)?
        for index in 0..<frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  width <= maxSourcePixelSide, height <= maxSourcePixelSide
            else { return nil }
            if first == nil { first = (width, height) }
        }
        return first
    }

    /// Eight bits a channel, whatever the source carried.
    ///
    /// `kCGImageSourceThumbnailMaxPixelSize` caps pixels, not bytes: ImageIO carries a 16-bit
    /// source's depth straight through the thumbnail, so an instance serving 16-bit PNG halves
    /// every bound above for free. Neither `kCGImageSourceShouldAllowFloat: false` nor
    /// `kCGImageSourceDecodeRequest: DecodeToSDR` prevents it — both were tried and measured.
    /// Redrawing into an eight-bit context is what does, and it is what makes the pixel cap
    /// above into the byte cap the budget is stated in.
    ///
    /// The source's colour space is carried over so a Display P3 emoji stays Display P3, and
    /// sRGB stands in where the space cannot be drawn into — an input-only profile, or a grey
    /// one that does not fit the four-channel context this draws. A source already at eight
    /// bits is returned untouched, which is every emoji anybody actually serves.
    private nonisolated static func eightBit(_ image: CGImage) -> CGImage? {
        guard image.bitsPerComponent > 8 else { return image }
        let carried = image.colorSpace.flatMap { space in
            space.model == .rgb && space.supportsOutput ? space : nil
        }
        guard let space = carried ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// How long one frame stands, whichever of the three formats it came out of. The unclamped
    /// time is asked for first: it is what the file actually says, where the other has already
    /// been rounded up to what a browser was once willing to draw.
    private nonisolated static func duration(of source: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else { return 0 }
        let dictionaries = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary,
                            kCGImagePropertyWebPDictionary]
        let unclamped = [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyAPNGUnclampedDelayTime,
                         kCGImagePropertyWebPUnclampedDelayTime]
        let clamped = [kCGImagePropertyGIFDelayTime, kCGImagePropertyAPNGDelayTime,
                       kCGImagePropertyWebPDelayTime]
        for (which, dictionary) in dictionaries.enumerated() {
            guard let frame = properties[dictionary] as? [CFString: Any] else { continue }
            if let time = frame[unclamped[which]] as? TimeInterval, time > 0 { return time }
            if let time = frame[clamped[which]] as? TimeInterval, time > 0 { return time }
        }
        return 0
    }
}

extension EmojiCache.Frames {
    /// Each frame given the scale that draws it at the height the line fixed, rather than the
    /// screen's — see `EmojiCache.imageScale` for why those are not the same number.
    init(_ decoded: EmojiCache.Decoded, side: CGFloat) {
        let height = EmojiCache.drawnHeight(sourceWidth: decoded.sourceWidth,
                                            sourceHeight: decoded.sourceHeight,
                                            side: side)
        self.init(
            images: decoded.images.map {
                Image(decorative: $0, scale: EmojiCache.imageScale(pixelHeight: $0.height, points: height))
            },
            ends: decoded.ends,
            bytes: decoded.bytes,
            drawnHeight: height
        )
    }
}

/// The arithmetic of a moving emoji, with no picture and no screen in it, so that every part of
/// it can be checked by a test that never sleeps.
enum EmojiClock {
    /// Below this a file has said nothing about how long its frame stands.
    static let shortestHonoured: TimeInterval = 0.011

    /// What every renderer gives a frame that said nothing.
    static let standIn: TimeInterval = 0.1

    /// The fastest a line is ever redrawn. A file claiming a one-millisecond frame would
    /// otherwise ask a timeline for a thousand redraws a second.
    static let fastestTick: TimeInterval = 1.0 / 30

    /// How long one frame actually stands.
    static func step(declared: TimeInterval) -> TimeInterval {
        declared < shortestHonoured ? standIn : declared
    }

    /// Each frame's end, measured from the start of the loop.
    static func ends(from delays: [TimeInterval]) -> [TimeInterval] {
        var elapsed: TimeInterval = 0
        return delays.map { delay in
            elapsed += delay
            return elapsed
        }
    }

    /// Which frame stands at this instant. `instant` is a wall clock, so it is folded back into
    /// the loop rather than counted from the moment this particular line appeared.
    static func index(at instant: TimeInterval, ends: [TimeInterval]) -> Int {
        guard let span = ends.last, span > 0, ends.count > 1 else { return 0 }
        let position = instant.truncatingRemainder(dividingBy: span)
        let folded = position < 0 ? position + span : position
        return ends.firstIndex { folded < $0 } ?? 0
    }

    /// How often a line holding this file has to be rebuilt: as often as its shortest frame
    /// changes, and no faster than `fastestTick`. Per-frame rather than a fixed rate, because
    /// GIF and APNG both carry a delay per frame and a clock that ignores them plays every
    /// emoji at the wrong speed.
    static func tick(shortestFrame: TimeInterval) -> TimeInterval {
        max(shortestFrame, fastestTick)
    }
}

/// A ceiling on how many things are open at once, first come first served.
///
/// Its own type rather than a pair of fields on the cache, because a ceiling is the one part of
/// the fetching worth checking on its own: how many are open and how many are waiting are both
/// readable here, so a test can hold the gate shut and count without a socket and without
/// sleeping.
///
/// A slot is handed straight from the one leaving to the one at the front of the queue rather
/// than released and re-taken, so a slot cannot be lost and the order cannot be jumped.
@MainActor
final class EmojiGate {
    let ceiling: Int
    private var open = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(ceiling: Int) {
        self.ceiling = max(1, ceiling)
    }

    var openCount: Int { open }
    var waitingCount: Int { waiting.count }

    func enter() async {
        guard open >= ceiling else {
            open += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        guard !waiting.isEmpty else {
            open = max(0, open - 1)
            return
        }
        waiting.removeFirst().resume()
    }
}
