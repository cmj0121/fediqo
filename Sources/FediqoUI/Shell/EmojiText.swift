import FediqoCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A line of somebody's writing, with the pictures in it drawn as pictures and moving where they
/// move.
///
/// One `Text` and not a row of views: a post is prose, and prose wraps, is selected, and is cut
/// off with an ellipsis. Laying it out as a stack of words and images takes all three away — so
/// the pictures are interpolated into the `Text` itself, which is the one way SwiftUI offers to
/// put an image inside a line and have the line still behave like a line.
///
/// Two things follow from that, and they are the whole of this file.
///
/// **Nothing inside a `Text` can be resized**, so each picture has to be decoded at the size it
/// will be drawn. That size is the font's own — the ink between its ascender and its descender
/// at the reader's text scale — so an emoji stands exactly as tall as the letters beside it,
/// rather than at some fraction of the point size that merely looks close.
///
/// **Nothing inside a `Text` animates either**, so an animated emoji is animated the only way
/// left: the frames are decoded once and the line is rebuilt with the next one on a clock. The
/// clock runs only where this particular line has something moving in it, at the rate the file
/// itself asks for, and a reader who has asked for less motion gets the first frame and no clock
/// at all.
struct EmojiText: View {
    let text: String
    let emojis: [CustomEmoji]
    let role: EmojiTextRole
    /// The source this line was read through. Not the address's own host, which is usually a CDN
    /// — it is what the reader's per-server Clear button reaches these pictures by, and a
    /// `CustomEmoji` carries no source of its own, so the call site has to say.
    let host: String

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Not `@State`: the cache is one object for the whole app, and this view owns none of it.
    /// What it watches is `arrived` — its own state, filled by its own task — so one emoji
    /// coming back wakes the lines that asked for it and no others.
    private let cache: EmojiCache

    @State private var arrived: Arrived?

    /// A line of somebody's writing, drawn in one of the type scale's roles.
    ///
    /// **This initialiser does not turn an address in `text` into a link, and when link handling
    /// arrives it must not start to.** A name, a handle and a spoiler line are labels written by
    /// a stranger: a person may call themselves `example.com`, and a row that quietly turns that
    /// into a control the reader can press is a row inventing something about a post. The
    /// previous incarnation of this app did exactly that in five places. Linking, when it comes,
    /// belongs to a second `init(prose:)` that a call site has to ask for by name.
    init(_ text: String, emojis: [CustomEmoji], host: String, role: EmojiTextRole = .body,
         cache: EmojiCache = .shared) {
        self.text = text
        self.emojis = emojis
        self.host = host
        self.role = role
        self.cache = cache
    }

    var body: some View {
        let request = request
        let pictures = pictures(for: request)
        // Once per pass of this line, never once per tick: the `TimelineView` below re-runs its
        // own content and not this body, so the cut is captured rather than remade at 25 a
        // second — and the cache remembers it across passes of the row as well.
        let cut = cache.runs(in: text, from: emojis)
        let baseline = request.metrics.baseline

        Group {
            if let clock = Self.clock(for: pictures, reduceMotion: reduceMotion) {
                TimelineView(.periodic(from: .now, by: clock)) { instant in
                    Self.line(cut, pictures, at: instant.date.timeIntervalSinceReferenceDate,
                              baseline: baseline)
                }
            } else {
                Self.line(cut, pictures, at: 0, baseline: baseline)
            }
        }
        .font(role.font)
        // One element carrying one label. Without `.ignore` the label would be landing on a
        // `TimelineView` whenever a clock is running — a container rather than a piece of text —
        // and a screen reader would be free to read the interpolated `Text` inside it instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: request) {
            await cache.fetch(request)
            arrived = Arrived(request: request, frames: cache.held(request))
        }
    }

    // MARK: - What this line asks the cache for

    private var metrics: EmojiCache.Metrics {
        EmojiCache.metrics(points: EmojiTextRole.points(for: role, at: typeSize))
    }

    private var request: EmojiCache.Request {
        EmojiCache.Request(emojis: emojis, metrics: metrics, scale: displayScale,
                           host: host, still: reduceMotion)
    }

    private struct Arrived {
        let request: EmojiCache.Request
        let frames: [String: EmojiCache.Frames]
    }

    /// What a screen reader is given: what the author typed, shortcodes and all. It cannot see a
    /// picture, and `:blobcat:` is at least the name of one.
    var accessibilityText: Text { Text(verbatim: text) }

    /// What the task brought back, or — before it has run — whatever the cache already holds, so
    /// a line whose emoji another row has already fetched draws them on its first pass rather
    /// than after a flash of the shortcode.
    private func pictures(for request: EmojiCache.Request) -> [String: EmojiCache.Frames] {
        guard let arrived, arrived.request == request else { return cache.held(request) }
        return arrived.frames
    }

    /// A clock only where one is needed, and only as fast as the files it is drawing. A page of
    /// ordinary posts never starts one, a line whose emoji are all stills does not either, and a
    /// reader who asked for less movement never does.
    static func clock(for pictures: [String: EmojiCache.Frames],
                      reduceMotion: Bool) -> TimeInterval? {
        guard !reduceMotion else { return nil }
        guard let shortest = pictures.values.filter(\.moves).map(\.shortestFrame).min() else {
            return nil
        }
        return EmojiClock.tick(shortestFrame: shortest)
    }

    /// The line itself. Static and given everything it needs, so the thing this file exists to
    /// build can be compared against an expected `Text` without a screen.
    static func line(_ cut: [EmojiRun], _ pictures: [String: EmojiCache.Frames],
                     at instant: TimeInterval, baseline: CGFloat) -> Text {
        cut.reduce(Text(verbatim: "")) { line, run in
            switch run {
            case .text(let words):
                return line + Text(verbatim: words)
            case .emoji(let emoji):
                // Until the picture is here the shortcode stands in for it, which is what the
                // reader would have seen anyway and is never a blank.
                guard let image = pictures[emoji.shortcode]?.image(at: instant) else {
                    return line + Text(verbatim: ":\(emoji.shortcode):")
                }
                // The picture's bottom sits on the font's descender rather than on the baseline,
                // which is what stops an emoji floating above the line it is written in.
                return line + Text(image).baselineOffset(baseline)
            }
        }
    }
}

/// Which line of the type scale a piece of somebody's writing is set on.
///
/// Three roles and no more, because there are three places a stranger's words are drawn: a name,
/// the words themselves, and the quieter line beside them — a handle, a summary.
///
/// This list first counted a spoiler among the quiet lines and the call site settled it the other
/// way: while a row is covered the author's line stands in for the post's words rather than beside
/// them, so it is drawn as `.body`. A role is what a line *is*, which is a question its call site
/// answers.
///
/// **One statement, derived three ways.** The style below decides the `Font` the line is drawn
/// in *and* the platform style its ink is measured from, so the size a picture is decoded at and
/// the size of the letters beside it cannot come apart. `ShellType` stays the authority: a test
/// asserts `font` equals the token, which fails the moment the scale moves a role to a different
/// style and this does not follow.
enum EmojiTextRole: CaseIterable, Sendable {
    case name
    case body
    case meta

    var textStyle: Font.TextStyle {
        switch self {
        case .name: .callout
        case .body: .body
        case .meta: .caption
        }
    }

    var weight: Font.Weight {
        switch self {
        case .name: .semibold
        case .body, .meta: .regular
        }
    }

    /// Built from the style above, which is the same statement `platformStyle` is derived from.
    /// The weight is applied only where it is not the default, because `.weight(.regular)` wraps
    /// the font in a modifier and `ShellType.body` is the bare style — equal fonts that are not
    /// `==`, and the test below compares them.
    var font: Font {
        let base = Font.system(textStyle)
        return weight == .regular ? base : base.weight(weight)
    }

    #if os(macOS)
    var platformStyle: NSFont.TextStyle { EmojiTextRole.appKitStyle(textStyle) }

    private static func appKitStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
    #else
    var platformStyle: UIFont.TextStyle { EmojiTextRole.uiKitStyle(textStyle) }

    private static func uiKitStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
    #endif

    /// How many points this role is set in at the reader's chosen text size.
    ///
    /// On macOS the reader's chosen size is **not applied**, because the letters do not move
    /// either. SwiftUI on macOS does not scale a semantic `Font` with `dynamicTypeSize`:
    /// measured through `NSHostingView.fittingSize`, `Font.body` renders at 16.0 at every rung
    /// from xSmall to accessibility5, while an explicit `.system(size:)` moves correctly — and
    /// `NSFont.preferredFont(forTextStyle: .body).pointSize` is a constant 13.0. Stepping that
    /// constant by the text size therefore grew the picture alone: 1.9× the letters at
    /// `.accessibility1` and 3.1× at `.accessibility5`. **The picture matches the letters beside
    /// it, whatever the letters are doing**, so where they are pinned it is pinned too.
    ///
    /// That the font-size preference does nothing on macOS at all is a defect of its own and not
    /// this view's to fix — no supported route makes Dynamic Type work there, so closing it
    /// means `ShellType`'s tokens stop being static constants.
    static func points(for role: EmojiTextRole, at size: DynamicTypeSize) -> CGFloat {
        #if os(macOS)
        NSFont.preferredFont(forTextStyle: role.platformStyle).pointSize
        #else
        // UIKit answers exactly, for this style at this size, which is better than a multiple:
        // the ladder is not one curve — caption grows more slowly than body does.
        UIFont.preferredFont(forTextStyle: role.platformStyle,
                             compatibleWith: UITraitCollection(preferredContentSizeCategory: category(size)))
            .pointSize
        #endif
    }

    #if !os(macOS)
    private static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        UIContentSizeCategory(size) ?? .large
    }
    #endif
}

#Preview("A line written partly in pictures") {
    @Previewable @Environment(\.colorScheme) var scheme
    let emojis = [
        CustomEmoji(shortcode: "blobcat", url: URL(string: "https://example.test/blobcat.png")!),
        CustomEmoji(shortcode: "blob-cat-wave", url: URL(string: "https://example.test/wave.gif")!),
    ]
    VStack(alignment: .leading, spacing: ShellSpace.snug) {
        EmojiText("Ada :blobcat: Lovelace", emojis: emojis, host: "example.test", role: .name)
        EmojiText("@ada@example.test", emojis: emojis, host: "example.test", role: .meta)
        EmojiText(
            "A line long enough to wrap, so that a picture standing in it wraps with the words "
                + "rather than beside them :blob-cat-wave: — and a colon that opens nothing, 12:30, "
                + "stays exactly as it was typed.",
            emojis: emojis,
            host: "example.test"
        )
    }
    .padding(ShellSpace.pad)
    .frame(width: 360, alignment: .leading)
    .background(ShellChrome.page(scheme))
}
