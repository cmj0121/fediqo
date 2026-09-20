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

    /// Whether this line is a post's **own words** rather than a label somebody chose. Only prose
    /// grows links — see the two initialisers below.
    let linked: Bool

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Where a press on a link goes. Nothing outside the shell, in which case the system browser
    /// takes it — see `EnvironmentValues.shellReader`.
    @Environment(\.shellReader) private var reader
    /// The way **out** of the app, read here at the top of this view so that the browser item in
    /// the menu below reaches the system rather than the override this view installs for the
    /// press. The two gestures must not be able to become the same gesture.
    @Environment(\.openURL) private var openURL

    /// Not `@State`: the cache is one object for the whole app, and this view owns none of it.
    /// What it watches is `arrived` — its own state, filled by its own task — so one emoji
    /// coming back wakes the lines that asked for it and no others.
    private let cache: EmojiCache

    @State private var arrived: Arrived?

    /// A line of somebody's writing, drawn in one of the type scale's roles.
    ///
    /// **This initialiser does not turn an address in `text` into a link, and it has not
    /// started to.** A name, a handle and a spoiler line are labels written by a stranger: a
    /// person may call themselves `example.com`, and a row that quietly turns that into a control
    /// the reader can press is a row inventing something about a post. The previous incarnation
    /// of this app did exactly that in five places. Linking belongs to `init(prose:)` below,
    /// which a call site has to ask for by name.
    init(_ text: String, emojis: [CustomEmoji], host: String, role: EmojiTextRole = .body,
         cache: EmojiCache = .shared) {
        self.text = text
        self.emojis = emojis
        self.host = host
        self.role = role
        self.cache = cache
        linked = false
    }

    /// A post's **own words** — the one line on a row that the author wrote as writing rather
    /// than chose as a label, and therefore the one line an address in it means to be followed.
    ///
    /// Asked for by name, which is the whole arrangement: a call site that wants links says so,
    /// and the four other lines this view draws cannot grow one by being edited near it.
    ///
    /// The role is `.body` and is not a parameter. Prose is prose; a name set in the body scale
    /// would be the type scale being decided at a call site, and the roles this view offers are
    /// the three places a stranger's words are drawn.
    init(prose text: String, emojis: [CustomEmoji], host: String, cache: EmojiCache = .shared) {
        self.text = text
        self.emojis = emojis
        self.host = host
        role = .body
        self.cache = cache
        linked = true
    }

    /// A post's own words, drawn as prose where the reader can read them and as plain letters
    /// where a cover stands in front of them.
    ///
    /// **A cover must never draw a control.** Behind the blur the letters are still laid out and
    /// still hit-tested, so prose under a cover is a covered post whose links are live: a press
    /// meant to lift the cover lands on the text layer and opens the author's page instead, and a
    /// secondary press opens a menu naming the very hosts the warning was put in front of.
    /// `accessibilityHidden` answers for VoiceOver and for nothing else. So the cut itself is what
    /// changes — the label cut grows no `.link` run, and with no links there is no menu, no
    /// tooltip and no `openURL` override to land in. The whole rectangle is the way in again.
    ///
    /// The role is `.body` either way, which is what keeps the cover the same shape as the words
    /// under it: this chooses which cut the line is drawn from, never what size it is set in.
    static func words(_ text: String, emojis: [CustomEmoji], host: String,
                      covered: Bool) -> EmojiText {
        covered
            ? EmojiText(text, emojis: emojis, host: host)
            : EmojiText(prose: text, emojis: emojis, host: host)
    }

    var body: some View {
        let request = request
        let pictures = pictures(for: request)
        // Once per pass of this line, never once per tick: the `TimelineView` below re-runs its
        // own content and not this body, so the cut is captured rather than remade at 25 a
        // second — and the cache remembers it across passes of the row as well.
        let cut = linked ? cache.proseRuns(in: text, from: emojis) : cache.runs(in: text, from: emojis)
        let baseline = request.metrics.baseline
        let links = Self.links(in: cut)
        let ink = ShellChrome.selectInk(colorScheme)

        Group {
            if let clock = Self.clock(for: pictures, reduceMotion: reduceMotion) {
                TimelineView(.periodic(from: .now, by: clock)) { instant in
                    Self.line(cut, pictures, at: instant.date.timeIntervalSinceReferenceDate,
                              baseline: baseline, linkInk: ink)
                }
            } else {
                Self.line(cut, pictures, at: 0, baseline: baseline, linkInk: ink)
            }
        }
        .font(role.font)
        // One element carrying one label. Without `.ignore` the label would be landing on a
        // `TimelineView` whenever a clock is running — a container rather than a piece of text —
        // and a screen reader would be free to read the interpolated `Text` inside it instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        // **Both ways in, named, on the element the reader lands on.** A press on the drawn link
        // and a secondary press on the words are both gestures, and a reader who makes neither
        // would otherwise be read an address and given no way to follow it. `DummyItemRow`'s way
        // out already keeps this rule for the same reason.
        .accessibilityActions { LinkWays(links: links, reader: reader, browser: openURL) }
        .modifier(ProseLinks(links: links, reader: reader, browser: openURL))
        .task(id: request) {
            await cache.fetch(request)
            arrived = Arrived(request: request, frames: cache.held(request))
        }
    }

    /// The addresses in a cut line, in the order they were written.
    static func links(in cut: [EmojiRun]) -> [PostLink] {
        var links: [PostLink] = []
        for run in cut {
            if case .link(let link) = run { links.append(link) }
        }
        return links
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
                     at instant: TimeInterval, baseline: CGFloat,
                     linkInk: Color = .accentColor) -> Text {
        cut.reduce(Text(verbatim: "")) { line, run in
            switch run {
            case .text(let words):
                return line + Text(verbatim: words)
            case .link(let link):
                return line + Self.drawn(link, in: linkInk)
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

    /// An address, drawn as one.
    ///
    /// **Hue and an underline, not hue alone.** The lamp's colour against the body ink is a
    /// difference some readers cannot see at all, and this app's own contrast note already says
    /// hierarchy is worth less than legibility; the underline is what makes a link read as a link
    /// in both schemes and in neither colour. `selectInk` is the phosphor — the shell's one hue
    /// for "this is a way somewhere" — and it is passed in rather than read here so that this
    /// stays a function of its arguments and can be compared against an expected `Text`.
    ///
    /// The letters are `link.text`: what the author typed, unaltered. `link.url` is that same
    /// string parsed. A reader looking at this is looking at the address.
    static func drawn(_ link: PostLink, in ink: Color) -> Text {
        var address = AttributedString(link.text)
        address.link = link.url
        address.foregroundColor = ink
        address.underlineStyle = .single
        return Text(address)
    }
}

/// Both ways to follow each address in a line, said rather than gestured.
///
/// **A gesture is not an affordance for everybody.** The press is the link's own and the browser
/// is a secondary press; a reader using VoiceOver makes neither, and would otherwise be read an
/// address out of a post with no way at all to follow it. Each address is named by its host,
/// which is the fact a reader checks before following one and the one this app parsed rather than
/// read out of anybody's markup.
///
/// `browser` is handed in rather than read here, and that is load-bearing: `ProseLinks` overrides
/// `openURL` for the line's own subtree so a press lands inside the app, and an action that read
/// the environment where it is drawn would pick up that override and quietly make the two ways
/// one way. The call site reads it above the override and passes it down.
struct LinkWays: View {
    let links: [PostLink]
    let reader: ShellReader?
    let browser: OpenURLAction

    var body: some View {
        ForEach(links, id: \.self) { link in
            Button(String(format: L10n.t("link.open.here"), link.host)) {
                // Told no — or asked outside the shell — the address goes to the browser rather
                // than nowhere. The same fallback the press makes, in the same order.
                if reader?.open(link.url) != true { browser(link.url) }
            }
            Button(String(format: L10n.t("link.open.browser"), link.host)) {
                browser(link.url)
            }
        }
    }
}

/// The same two ways, for a surface that draws a post's words inside an accessibility element of
/// its own.
///
/// `ForumPostBand` and `ForumReplyRow` are each one element by design — a band that names what
/// state the post is in, a reply that is read as one thing — so the actions `EmojiText` offers
/// inside them are thrown away with the rest of their children. The words are the same words, so
/// the addresses are found from the same text and offered on the element the reader lands on.
struct SpokenLinks: ViewModifier {
    let text: String

    @Environment(\.shellReader) private var reader
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.accessibilityActions {
            LinkWays(links: PostLink.found(in: text), reader: reader, browser: openURL)
        }
    }
}

extension View {
    func spokenLinks(in text: String) -> some View { modifier(SpokenLinks(text: text)) }
}

/// The two ways a link in a post's words can be followed.
///
/// ## A press opens it here, and a secondary press opens it in the browser
///
/// **The press is the link's own.** A `Text` carrying an address hands it to `openURL`, so the
/// way to make a press land inside this app is to say what `openURL` means for this line — and
/// for this line only. The override is installed on the words and nowhere above them, which is
/// what keeps `DummyItemRow.wayOut` and `DummyThreadPane.outward` leaving the app as they always
/// have: they read the environment their own ancestors set, not this one.
///
/// **The secondary press is a context menu, which is one gesture with two names.** On iOS it is a
/// long press; on macOS it is a right or control click. That is the same argument `WayOut` makes
/// one file over, and it is the answer to "a long press is not the natural gesture on macOS": the
/// gesture is *the secondary press*, and each platform already spells it its own way. Nothing
/// platform-specific is written here, and neither platform is given the lesser affordance.
///
/// **What it costs, stated.** Over the words of a post that carries a link, this menu stands in
/// front of the row's own way-out menu. That is the right way round — the reader's pointer is on
/// an address, and the menu is about that address — and the row's menu is still a secondary press
/// away anywhere else on the row. A post with no links installs no menu at all, so the row's is
/// reached over its words as before.
///
/// ## Absent, not disabled
///
/// No links, no menu, no tooltip, no override: `decision 4`'s rule, and the same shape `WayOut`
/// uses — the condition is on the modifier rather than inside the menu's builder, because an
/// empty menu builder is still a menu and a right click that opens an empty grey rectangle is a
/// disabled control wearing a different hat.
private struct ProseLinks: ViewModifier {
    let links: [PostLink]
    /// Where a press goes. Nothing outside the shell.
    let reader: ShellReader?
    /// The way out of the app, taken from above this view — see `EmojiText.openURL`.
    let browser: OpenURLAction

    @ViewBuilder
    func body(content: Content) -> some View {
        if links.isEmpty {
            content
        } else {
            content
                .environment(\.openURL, OpenURLAction { url in
                    // **Decision 9 once more, at the one place a press becomes a navigation.**
                    // Everything drawn as a link came through `PostLink` and is already checked;
                    // what this refuses is anything that reaches this action by another route.
                    guard Host.allowsFetch(url) else { return .discarded }
                    guard let reader else { return .systemAction }
                    return reader.open(url) ? .handled : .discarded
                })
                .contextMenu {
                    ForEach(links, id: \.self) { link in
                        Button {
                            browser(link.url)
                        } label: {
                            Label(String(format: L10n.t("link.open.browser"), link.host),
                                  systemImage: "arrow.up.forward.app")
                        }
                    }
                }
                // How a reader finds the second gesture at the moment they are looking for it.
                // A tooltip is a pointer's affordance, which is the platform where the gesture
                // needs announcing — on a phone a long press on something pressable is the
                // gesture people already make.
                .help(L10n.t(Self.hintKey))
        }
    }

    private static var hintKey: String {
        #if os(macOS)
        "link.hint.pointer"
        #else
        "link.hint.touch"
        #endif
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
        // `UIContentSizeCategory.init(_: DynamicTypeSize)` is non-failable, so the `?? .large`
        // this used to carry was dead code that warned on every iOS compilation — and warned
        // only there, which is why it survived a unit, its review and two branch-wide "zero
        // warnings" claims. It is not reachable from a macOS build at all.
        UIContentSizeCategory(size)
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
            prose: "A line long enough to wrap, so that a picture standing in it wraps with the "
                + "words rather than beside them :blob-cat-wave: — and a colon that opens nothing, "
                + "12:30, stays exactly as it was typed. The address in it, "
                + "https://example.test/a, is drawn as one: press it to read it here, and press it "
                + "the other way for the browser. http://example.test/b is not, and neither is "
                + "example.test on its own.",
            emojis: emojis,
            host: "example.test"
        )
    }
    .padding(ShellSpace.pad)
    .frame(width: 360, alignment: .leading)
    .background(ShellChrome.page(scheme))
}
