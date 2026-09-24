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
    /// Where a press on a hashtag goes (#124), and the row these words stand on. Nothing outside
    /// the shell, where a tag stays the label #123 drew.
    @Environment(\.shellTags) private var tags
    @Environment(\.shellRow) private var row
    /// The hosts still on this device (#250): a line read through one that has gone asks for no
    /// pictures, and draws its names as written. See `RemoteImage.isHere`.
    @Environment(\.shellSourcesHere) private var sourcesHere

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
        self.init(text, emojis: emojis, host: host, role: role, cache: cache, linked: false)
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
        self.init(text, emojis: emojis, host: host, role: .body, cache: cache, linked: true)
    }

    private init(_ text: String, emojis: [CustomEmoji], host: String, role: EmojiTextRole,
                 cache: EmojiCache, linked: Bool) {
        self.text = text
        self.emojis = emojis
        self.host = host
        self.role = role
        self.cache = cache
        self.linked = linked
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
        let cut = self.cut
        let baseline = request.metrics.baseline
        let links = Self.links(in: cut)
        let tagged = Self.tags(in: cut)
        let ink = ShellChrome.selectInk(colorScheme)
        // A tag takes the control's ink once a press opens something (#124), and only then.
        let tagInk: Color? = tags == nil ? nil : ink
        let plate = ShellChrome.well(colorScheme)

        Group {
            if let clock = Self.clock(for: pictures, reduceMotion: reduceMotion) {
                TimelineView(.periodic(from: .now, by: clock)) { instant in
                    Self.line(cut, pictures, at: instant.date.timeIntervalSinceReferenceDate,
                              baseline: baseline, linkInk: ink, tagInk: tagInk)
                }
            } else {
                Self.line(cut, pictures, at: 0, baseline: baseline, linkInk: ink, tagInk: tagInk)
            }
        }
        // Only where a pill is drawn: a line with no tag keeps the system's own drawing.
        .modifier(TagPlating(plate: plate, active: Self.hasTags(cut)))
        .font(role.font(at: typeSize))
        // One element carrying one label. Without `.ignore` the label would be landing on a
        // `TimelineView` whenever a clock is running — a container rather than a piece of text —
        // and a screen reader would be free to read the interpolated `Text` inside it instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(cut))
        // **Both ways in, named, on the element the reader lands on.** A press on the drawn link
        // and a secondary press on the words are both gestures, and a reader who makes neither
        // would otherwise be read an address and given no way to follow it. `DummyItemRow`'s way
        // out already keeps this rule for the same reason.
        .accessibilityActions {
            LinkWays(links: links, reader: reader, browser: openURL, source: host)
            TagWays(tags: tagged, pressing: tags, row: row)
        }
        .modifier(ProseLinks(
            links: links, reader: reader, browser: openURL, source: host,
            tags: tags == nil ? [] : tagged, pressing: tags, row: row
        ))
        .task(id: Asking(request: request, here: RemoteImage.isHere(host, among: sourcesHere))) {
            guard RemoteImage.isHere(host, among: sourcesHere) else { return }
            await cache.fetch(request)
            arrived = Arrived(request: request, frames: cache.held(request))
        }
    }

    /// Whether a cut line has a tag in it, and so a pill to draw.
    static func hasTags(_ cut: [EmojiRun]) -> Bool {
        cut.contains { if case .tag = $0 { true } else { false } }
    }

    /// The hashtags in a cut line, in the order they were written. None in a label's cut.
    static func tags(in cut: [EmojiRun]) -> [PostTag] {
        cut.compactMap { run in
            if case .tag(let tag) = run { return tag }
            return nil
        }
    }

    /// The addresses in a cut line, in the order they were written.
    static func links(in cut: [EmojiRun]) -> [PostLink] {
        cut.compactMap { run in
            if case .link(let link) = run { return link }
            return nil
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

    /// What the fetch re-fires on: the request, and whether its host is here (#250) — the
    /// latter in the identity for `RemoteImage.Wanted`'s reason, so a source added again fills
    /// the lines kept from it.
    struct Asking: Equatable {
        let request: EmojiCache.Request
        let here: Bool
    }

    /// The cut this line is drawn from: the prose cut where the call site asked for a post's own
    /// words, the label cut everywhere else. Both are remembered by the cache.
    @MainActor
    private var cut: [EmojiRun] {
        linked ? cache.proseRuns(in: text, from: emojis) : cache.runs(in: text, from: emojis)
    }

    /// What a screen reader is given for this line — see `spoken(_:)`.
    @MainActor
    var accessibilityText: Text { Self.spoken(cut) }

    /// What a screen reader is given: what the author typed, shortcodes and all. It cannot see a
    /// picture, and `:blobcat:` is at least the name of one.
    ///
    /// **Read back from the cut rather than from `text`**, and that is what makes one sentence
    /// true: a word is said to be a hashtag exactly where a pill is drawn round it, and nowhere
    /// else. A name with a `#` in it, a covered post and a `#` inside an address are all cut
    /// without a `.tag`, so they are read as the letters they are. The cut concatenated is the
    /// words exactly — `EmojiRun.prose` promises it — so a line with no tag is read as it always
    /// was, and reading it costs a walk of runs the cache already holds rather than a second scan.
    ///
    /// A tag is read as the word the author wrote, named as a tag. Where a press opens it (#124)
    /// the way in is an action on the element (`TagWays`), not a word in the label.
    static func spoken(_ cut: [EmojiRun]) -> Text {
        Text(verbatim: cut.reduce(into: "") { spoken, run in
            switch run {
            case .text(let words): spoken += words
            case .link(let link): spoken += link.text
            case .emoji(let emoji): spoken += ":\(emoji.shortcode):"
            case .tag(let tag): spoken += String(format: L10n.t("post.tag.spoken"), tag.name)
            }
        })
    }

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
                     linkInk: Color = .accentColor, tagInk: Color? = nil) -> Text {
        cut.reduce(Text(verbatim: "")) { line, run in
            switch run {
            case .text(let words):
                return line + Text(verbatim: words)
            case .link(let link):
                return line + Self.drawn(link, in: linkInk)
            case .tag(let tag):
                return line + Self.drawn(tag, ink: tagInk)
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

    /// A hashtag, drawn as one: the word, with a little room either side of it, marked so that
    /// `TagPlates` draws a pill of the shell's grey behind it.
    ///
    /// **A label, and drawn so that it cannot be taken for a control.** `ShellChrome.well` is the
    /// milled recess the shell puts a pill or a keycap in — neutral on purpose, because a
    /// container that borrows the lamp's hue makes every container look selected. The letters
    /// keep the line's own ink, carry no underline and no `link`, so nothing about the run says
    /// *press here*: an address is the phosphor and a line under it, a tag is the grey and the
    /// ordinary ink, and the two are told apart by colour, by edge and by whether there is a
    /// line under the word, which is three differences and not one. There is no press for it to
    /// have — that is a later unit — and a pill that looked pressable and did nothing would be
    /// worse than the plain word it replaced.
    ///
    /// **A mark rather than a colour.** A background attribute inside a `Text` is a rectangle on
    /// both platforms and cannot be given a radius, which is a grey highlight and not a pill. So
    /// the run carries `PostTagMark` and nothing else, and the capsule is drawn by the line's
    /// renderer from where the run was actually laid out. The tag stays letters in the one
    /// `Text` — it wraps, is selected and is the author's spelling — and the plate is paint, not
    /// layout, so nothing about it can move a line or change a row's height.
    ///
    /// **The room is a narrow no-break space each side**, inside the marked run so the capsule's
    /// round ends fall in it rather than on the `#` and the last letter. No-break, so the plate
    /// cannot be split from its word at the end of a line and the line breaks round the pill as
    /// it would round the word. The spaces are drawing only: `tag.text` is still exactly what
    /// was typed, and what a screen reader hears is built from the tag and not from this.
    ///
    /// **Pressable once there is somewhere to go** (#124). With `ink` — inside the shell, where a
    /// press opens what this device holds under the tag — the letters take the control's ink and
    /// carry `ShellTags.url(for:)`, which is how a press on them reaches `ProseLinks`; the pill,
    /// its grey and the absence of an underline stay exactly as they were. That is the whole of
    /// what #124 may change about how a tag looks.
    static func drawn(_ tag: PostTag, ink: Color? = nil) -> Text {
        guard let ink, let url = ShellTags.url(for: tag) else {
            return Text(verbatim: tagRoom + tag.text + tagRoom).customAttribute(PostTagMark())
        }
        var letters = AttributedString(tagRoom + tag.text + tagRoom)
        letters.link = url
        letters.foregroundColor = ink
        return Text(letters).customAttribute(PostTagMark())
    }

    /// The room inside a tag's plate, each side: `U+202F NARROW NO-BREAK SPACE`.
    static let tagRoom = "\u{202F}"
}

/// The mark a hashtag's run carries, and the only thing that tells `TagPlates` where a pill goes.
///
/// No fields: it says *this run is a tag* and nothing about what the tag is, because the drawing
/// needs nothing more and a mark that carried the tag would be a second copy of the cut.
struct PostTagMark: TextAttribute {}

/// Draws a line with a capsule of the shell's grey behind every run marked `PostTagMark`, and
/// otherwise exactly as the system would.
///
/// **Every plate first, then every line of letters.** A plate is outset a little past its run, so
/// drawing line by line would let the next line's plate lie over the last line's descenders; all
/// the paint goes down before any of the ink does, and no plate can cover a letter.
///
/// **One capsule per line a tag is on.** Its runs on a line are joined first — see
/// `plateBounds` — so a word set in two faces is still one pill. A tag has no space in it and its
/// room is no-break, so it moves to the next line whole; the only way it is split is a single tag
/// longer than the line, which the system then breaks by character. That draws as two capsules,
/// one per line, which is what the letters are doing too.
///
/// **Paint, not layout.** The capsule is the tag's typographic bounds outset sideways by
/// `plateOutset` of its height and not at all upright, so it sits inside the line's own height
/// and a line — and so a row — is exactly as tall as it was. `displayPadding` tells SwiftUI about
/// the few points it reaches past the text's frame at either end, so they are not clipped.
struct TagPlates: TextRenderer {
    let plate: Color

    /// How far past its letters the capsule reaches at each end, as a share of its height. A
    /// tenth is two points at the body size: enough air round the room, and less than half the
    /// ordinary space between two tags, so `#a #b` is two pills and not one.
    static let plateOutset: CGFloat = 0.1

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
    }

    /// The capsule behind one run: its bounds, outset sideways, with round ends.
    static func plate(around bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: -bounds.height * plateOutset, dy: 0)
        return Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
    }

    /// Where the plates go on one line: each unbroken stretch of marked runs, as one box.
    ///
    /// **One tag is often several runs, and this is where that stops showing.** A run is a
    /// stretch of one font, and `#台灣` is `#` in the system face and `台灣` in the CJK fallback
    /// beside it — measured, three runs for `#二` with its room, and a capsule per run would be a
    /// row of overlapping pills of slightly different heights round one word. Two tags can never
    /// meet here: a `#` straight after a tag's letter opens nothing, so there is always an
    /// unmarked character between two pills. The box is the union, so a taller fallback face
    /// sets the plate's height for the whole word rather than for its own letters.
    static func plateBounds(_ runs: [(marked: Bool, bounds: CGRect)]) -> [CGRect] {
        var plates: [CGRect] = []
        var open: CGRect?
        for run in runs {
            if run.marked {
                open = open.map { $0.union(run.bounds) } ?? run.bounds
            } else if let done = open {
                plates.append(done)
                open = nil
            }
        }
        if let done = open { plates.append(done) }
        return plates
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            let runs = line.map { ($0[PostTagMark.self] != nil, $0.typographicBounds.rect) }
            for bounds in Self.plateBounds(runs) {
                context.fill(Self.plate(around: bounds), with: .color(plate))
            }
        }
        for line in layout {
            context.draw(line)
        }
    }
}

/// The renderer, only on a line with a tag in it.
///
/// **Absent, not idle** — `ProseLinks`' shape. A renderer that draws every line as the system
/// would is still a renderer in the path of every post; a post with no tag keeps the system's own
/// drawing, which is the one way to be sure it looks exactly as it did.
private struct TagPlating: ViewModifier {
    let plate: Color
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.textRenderer(TagPlates(plate: plate))
        } else {
            content
        }
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
    /// The source the words were read through (#218).
    let source: String

    var body: some View {
        ForEach(links, id: \.self) { link in
            Button(String(format: L10n.t("link.open.here"), link.host)) {
                // Told no — or asked outside the shell — the address goes to the browser rather
                // than nowhere. The same fallback the press makes, in the same order.
                if reader?.open(link.url, from: source) != true { browser(link.url) }
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
    /// The source the words were read through, which a page opened from them is listed under.
    let source: String

    @Environment(\.shellReader) private var reader
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        // **The cut the words beside this were already drawn from**, rather than a second scan of
        // the same text on every pass of the band. Both call sites draw this text as prose with
        // no picture list, which is this exact key in the cache's memo, so what this costs is a
        // dictionary lookup. `PostLink.found` rescanned instead — bounded by `maxLinks`, and paid
        // again on every pass of every reply.
        let links = EmojiText.links(in: EmojiCache.shared.proseRuns(in: text, from: []))
        return content.accessibilityActions {
            LinkWays(links: links, reader: reader, browser: openURL, source: source)
        }
    }
}

extension View {
    func spokenLinks(in text: String, from source: String) -> some View {
        modifier(SpokenLinks(text: text, source: source))
    }
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
    /// The source the words were read through, which a page opened from them is listed under.
    let source: String
    /// The line's hashtags, where a press on one opens something (#124), where it goes, and the
    /// row the line stands on.
    var tags: [PostTag] = []
    var pressing: ShellTags?
    var row: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if links.isEmpty && tags.isEmpty {
            content
        } else if links.isEmpty {
            // Only tags: the press, and no menu — a tag has no browser to be opened in.
            content.environment(\.openURL, press)
        } else {
            content
                .environment(\.openURL, press)
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
                .linkHint()
        }
    }

    /// What a press on the words means: a tag's page for a tag (#124), and for an address the
    /// reader in the app.
    private var press: OpenURLAction {
        OpenURLAction { url in
            if let tag = ShellTags.tag(in: url) {
                return pressing?.press(tag, from: row) == true ? .handled : .discarded
            }
            // **Decision 9 once more, at the one place a press becomes a navigation.**
            // Everything drawn as a link came through `PostLink` and is already checked;
            // what this refuses is anything that reaches this action by another route.
            guard Host.allowsFetch(url) else { return .discarded }
            guard let reader else { return .systemAction }
            return reader.open(url, from: source) ? .handled : .discarded
        }
    }
}

private extension View {
    /// How a reader finds the second gesture at the moment they are looking for it.
    ///
    /// **Two platforms, two surfaces, and that is the fix rather than the split.** A tooltip is a
    /// pointer's affordance and reaches nobody on a phone, so `link.hint.touch` shipped, was
    /// translated three times, and was never once said out loud: `.help` on iOS draws nothing and
    /// a reader was told about a long press only if they had a mouse. On touch the sentence goes
    /// on the accessibility element `EmojiText` already builds for this line, which is where a
    /// reader who cannot see the underline is standing when they need it.
    @ViewBuilder
    func linkHint() -> some View {
        #if os(macOS)
        help(L10n.t("link.hint.pointer"))
        #else
        accessibilityHint(Text(L10n.t("link.hint.touch")))
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

    /// The shell role this is drawn in — **one statement, not a second copy of the scale.**
    ///
    /// The style and the weight used to be spelled again here, beside a test asserting the two
    /// tables agreed. Naming the role instead makes them the same table: a role moved to a
    /// different style in `ShellType` moves the picture's ink with it by construction, which is
    /// what the test was there to catch after the fact.
    var shellRole: ShellType {
        switch self {
        case .name: .name
        case .body: .body
        case .meta: .meta
        }
    }

    /// The letters this role is set in, at the size the reader chose — the same resolution
    /// `shellFont(_:)` makes, because it is the same role.
    func font(at size: DynamicTypeSize) -> Font { shellRole.font(at: size) }

    #if !os(macOS)
    var platformStyle: UIFont.TextStyle { EmojiTextRole.uiKitStyle(shellRole.style) }

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
    /// **The picture matches the letters beside it, whatever the letters are doing** — which is
    /// the rule this has always stated, and which now means the opposite of what it used to on
    /// a Mac.
    ///
    /// It used to ignore the chosen size there, and said why: SwiftUI on macOS does not scale a
    /// semantic `Font` with `dynamicTypeSize` — measured through `NSHostingView.fittingSize`,
    /// `Font.body` rendered at 16.0 at every rung from xSmall to accessibility5. The letters
    /// were pinned, so the picture was pinned with them; stepping it by the text size would
    /// have grown the picture alone.
    ///
    /// #96 unpinned the letters: `ShellType` resolves a role to points itself on that platform,
    /// by the platform's size for the style times `ShellType.multiple(at:)`. So the picture
    /// steps by exactly the same product, and the rule is kept by following rather than by
    /// standing still.
    static func points(for role: EmojiTextRole, at size: DynamicTypeSize) -> CGFloat {
        #if os(macOS)
        // **The letters' own arithmetic, called rather than repeated.** `ShellType.font(at:)`
        // sets this role at exactly this product on this platform, so asking it is what makes
        // "the picture matches the letters" true by construction instead of by agreement.
        ShellType.platformPoints(role.shellRole.style) * ShellType.multiple(at: size)
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
