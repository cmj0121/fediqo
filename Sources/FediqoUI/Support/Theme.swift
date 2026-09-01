import SwiftUI
import FediqoCore

// MARK: - Text size

/// macOS has no Dynamic Type, so the text scale is carried down the view tree by hand.
/// On iOS this multiplies whatever the system already decided.
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var fediqoTextScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.fediqoTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    func fediqoFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

// MARK: - Tokens

/// Every gap and every padding, named. A number written in a view is a number that cannot be
/// changed anywhere else — two of them written a week apart disagree, and the disagreement is
/// invisible until the two screens are put side by side.
enum Space {
    static let hair: CGFloat = 2
    static let tight: CGFloat = 4
    static let snug: CGFloat = 6
    static let step: CGFloat = 8
    static let mid: CGFloat = 10
    static let gap: CGFloat = 12
    /// What a card holds its contents in.
    static let pad: CGFloat = 14
    /// Controls that belong together. Its pair is `betweenGroups`, which is at least twice it —
    /// that ratio is what does the grouping now that no line is drawn between them.
    static let withinGroup: CGFloat = 16
    /// What a panel keeps between itself and its own edge.
    static let room: CGFloat = 20
    /// One band of a page from the next.
    static let band: CGFloat = 24
    static let betweenGroups: CGFloat = 34
    /// What a page that is mostly empty leaves round what little it has.
    static let page: CGFloat = 40
}

/// Every corner. Four, because there are four things with corners: a card, something inside
/// one, a panel over the page, and a picture off a server.
enum Radius {
    static let inner: CGFloat = 8
    static let card: CGFloat = 10
    /// A panel that stands over the page rather than in it: the composer, a sheet, the keys.
    static let panel: CGFloat = 12
    static let thumbnail: CGFloat = 7
}

/// Every symbol size. A glyph does not follow the reader's text scale — a row's height is
/// worked out from the text in it, and marks that grew with it would overflow the card.
enum Glyph {
    /// What can be done to a post, in the interaction bar.
    static let action: CGFloat = 19
    /// A mark that sits beside words, at the weight of the words.
    static let inline: CGFloat = 12
    /// A mark inside a pill, a capsule, or over a picture.
    static let badge: CGFloat = 10
    /// The width a leading icon is aligned in, so what follows it lines up down a list.
    static let column: CGFloat = 14
    /// A mark that leads a heading rather than a line, and the width one is aligned in.
    static let lead: CGFloat = 18
    /// A mark that is the only thing in its own space: an empty screen, a landing page.
    static let big: CGFloat = 26
    static let huge: CGFloat = 34
}

/// Every text size. Always reached through `fediqoFont`, which is what carries the reader's own
/// text size down a tree macOS gives no Dynamic Type to.
enum TypeScale {
    static let micro: CGFloat = 9
    static let caption: CGFloat = 10
    static let minor: CGFloat = 11
    static let small: CGFloat = 12
    static let body: CGFloat = 13
    static let lead: CGFloat = 15
    static let section: CGFloat = 17
    static let title: CGFloat = 20
    static let display: CGFloat = 26
    /// The one line on a page that has the page to itself.
    static let banner: CGFloat = 34
}

/// The smallest thing worth pressing, which is not the same for a finger as for a cursor: 44 is
/// Apple's touch minimum, 28 is enough to aim at with a pointer.
enum Hit {
    #if os(iOS)
    static let target: CGFloat = 44
    #else
    static let target: CGFloat = 28
    #endif
}

/// Sizes that are a role rather than a step on a scale.
enum Size {
    static let avatar: CGFloat = 30
    /// A popover wide enough for a row of words and narrow enough not to cover the post it
    /// was opened from.
    static let popover: CGFloat = 300
    /// The width at which a row has room to put its attachments beside its words:
    /// `AttachmentDeck.side` for the deck, `Space.gap` for the gap, and 348 left for the words.
    ///
    /// Out here rather than on the screen that measures it, because the closure that asks the
    /// geometry is `Sendable` and a `View`'s own static is isolated to the main actor.
    static let wideRows: CGFloat = 560
    /// One pixel of edge, where a gradient or a shape has to draw it rather than `Hairline`.
    static let hairline: CGFloat = 1
    /// The mark that says a list has ended.
    static let dot: CGFloat = 5
    /// The box a mark sits in beside a line of text, and the wider one it sits in where it is
    /// standing in for the text rather than beside it — a rail with its words put away.
    static let iconColumn: CGFloat = 24
    static let wideIconColumn: CGFloat = 34
    /// A picture a server sent to stand for itself.
    static let thumbnail: CGFloat = 56
    /// A button wide enough not to shrink to its two words.
    static let button: CGFloat = 96
    /// The box every mark in the interaction bar is drawn in, and the column the count beside
    /// it sits in. Together they make one control the same width on every row.
    ///
    /// A bar that sized itself to its own contents put the star in a different place on every
    /// post — a reply count of 3 and one of 41 are different widths, and everything after them
    /// moved — so scrolling a list of forty was a row of marks that would not sit still. These
    /// two are what hold the columns; nothing in them is centred on its own contents.
    ///
    /// The glyph box is a fixed width, and it may be: `Glyph.action` does not follow the
    /// reader's text size, so the widest action symbol is the widest it will ever be.
    ///
    /// The count column is **not** fixed, and that is the whole trick. It is three monospaced
    /// digits at `TypeScale.small` **and must be multiplied by the reader's text scale**, which
    /// runs to 1.6 — a column measured in points would hold three digits for one reader and
    /// less than two for the next, and the bar would go back to drifting for exactly the people
    /// who set the text larger. Three digits is every count a timeline shows; a bigger number
    /// widens its own row rather than being cut off or rounded off, because a count this app
    /// draws is the count it was told.
    static let actionGlyph: CGFloat = 24
    static let actionCount: CGFloat = 22
    /// The box the audience mark is hovered over. A glyph is only as hoverable as its own ink,
    /// and a padlock at `Glyph.inline` is a few strokes with holes between them — without a
    /// shape behind it the hint appears and disappears as the pointer crosses one.
    static let audienceMark: CGFloat = 18
    /// A panel of prose, and the column a page of settings is read in. Wider than either and
    /// the eye loses the start of the next line.
    static let prose: CGFloat = 420
    static let pageColumn: CGFloat = 620
}

extension View {
    /// A symbol at one of the `Glyph` sizes. The counterpart of `fediqoFont`, and the only way
    /// a view is allowed to set the size of an `Image(systemName:)`.
    func fediqoSymbol(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight))
    }
}

// MARK: - Palette

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The chassis behind the octopus, turned into a palette. Nothing here is decorative:
/// the rail, the timeline and the pickers all need the same three surfaces to read as
/// one app on macOS and, later, on iOS.
enum Palette {
    static let accent = Color(red: 0.55, green: 0.78, blue: 0.94)

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.055, green: 0.067, blue: 0.078) : Color(red: 0.97, green: 0.97, blue: 0.98)
    }

    static func raised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.12, blue: 0.14) : .white
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    /// The accent at the weight a mark needs to hold the page it is drawn on. The pale blue
    /// was chosen against a dark surface and it reads there; on white it is a whisper, and a
    /// mark saying where the reader is cannot be a whisper. Same hue either way — this is
    /// still the accent, not a second colour with a second meaning.
    static func focus(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? accent : Color(red: 0.13, green: 0.42, blue: 0.66)
    }
}

/// How a thing in this app arrives and how it leaves: one short ease-out, so the composer,
/// the written-down keys and the button back to the top are the same movement rather than
/// three guesses at it.
enum Motion {
    static let appearing = Animation.easeOut(duration: 0.15)
    /// What a thing that is still coming does while it waits.
    ///
    /// Slow on purpose, and one movement rather than a spinner. A spinner on a thirty-point
    /// avatar is a machine part in the middle of a face; a shape that breathes says the same
    /// thing — this is coming — without pretending to be a control. Long enough that a picture
    /// which arrives quickly is never seen to pulse at all.
    static let breathing = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
}

// MARK: - The room the screen has

/// A phone held upright, where a header has one column's worth of room and not two.
///
/// The shell is the one place that asks the platform how much room there is — a size class
/// only exists on iOS — and every screen below it reads the answer here rather than working
/// it out again from an environment value half of them cannot see.
private struct CompactKey: EnvironmentKey {
    static let defaultValue = false
}

/// Whether a row has the width to put its attachments beside its words rather than under them.
///
/// Measured once by the screen that draws the list and read by every row, for the reason
/// `fediqoCompact` is: a row asking the geometry for itself is the same question answered
/// however many times there are rows on screen, and they would all answer the same.
private struct WideRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var fediqoCompact: Bool {
        get { self[CompactKey.self] }
        set { self[CompactKey.self] = newValue }
    }

    var fediqoWideRows: Bool {
        get { self[WideRowsKey.self] }
        set { self[WideRowsKey.self] = newValue }
    }
}

// MARK: - Chrome

/// A raised panel with a hairline edge — a post, a settings group, a picker row, the
/// composer. Written once so a palette or radius change is one edit and the corners cannot
/// drift apart, and it reads the colour scheme itself so its users need not carry one.
private struct Card: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let radius: CGFloat
    let raised: Bool
    let shadow: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var background: some View {
        let fill = raised ? Palette.raised(colorScheme) : Palette.surface(colorScheme)
        return shape
            .fill(fill)
            .overlay(shape.strokeBorder(Palette.hairline(colorScheme), lineWidth: 1))
    }

    func body(content: Content) -> some View {
        if shadow {
            let depth = colorScheme == .dark ? 0.55 : 0.18
            content.background(background.shadow(color: Color.black.opacity(depth), radius: 18, y: 8))
        } else {
            content.background(background)
        }
    }
}

/// The small grey capsule that marks a thing rather than says it: a source, a state, a
/// "not yet".
private struct Pill: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Space.step)
            .padding(.vertical, Space.hair)
            .background(Capsule().fill(Palette.hairline(colorScheme)))
            .foregroundStyle(.secondary)
    }
}

/// Where the reader is, for somebody steering by the keys rather than with a pointer.
///
/// Two marks and only one of them is a colour. The accent traces the whole card, and a bar
/// stands at its leading edge — and the bar is the one that does not ask anybody to tell
/// blue from grey: it is either there or it is not, at any contrast, in either scheme, and
/// on a screen showing a hundred cards it is the mark the eye finds first. That it is the
/// accent and not orange or red is deliberate: those two already mean a server is unwell
/// and a thing is about to be taken away, and where you are is neither a warning nor a
/// threat. And the row says as much to a screen reader, which cannot see either mark.
private struct FocusRing: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let selected: Bool

    private var ring: some View {
        let colour = Palette.focus(colorScheme)
        return RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(colour, lineWidth: 2)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(colour)
                    .frame(width: Space.tight)
                    .padding(.vertical, Space.gap)
                    .padding(.leading, Space.snug)
            }
    }

    func body(content: Content) -> some View {
        content
            .overlay { if selected { ring } }
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension View {
    func fediqoCard(radius: CGFloat = Radius.card, raised: Bool = true, shadow: Bool = false) -> some View {
        modifier(Card(radius: radius, raised: raised, shadow: shadow))
    }

    func fediqoFocusRing(_ selected: Bool) -> some View {
        modifier(FocusRing(selected: selected))
    }

    func fediqoPill() -> some View {
        modifier(Pill())
    }
}

/// One row of named choices where exactly one is true: the tabs of a page, and every
/// appearance preference. Both are the same control over the same shape of enum — a case per
/// segment, named by a string key derived from the case itself — so it is written once.
///
/// The options are handed in rather than taken from `allCases`, because a page's tabs are a
/// list the page decides and a preference's choices are the whole enum.
struct SegmentedChoice<Option>: View
where Option: Identifiable & Hashable & RawRepresentable, Option.RawValue == String {
    let options: [Option]
    let keyPrefix: String
    @Binding var selection: Option

    init(_ options: [Option], keyPrefix: String, selection: Binding<Option>) {
        self.options = options
        self.keyPrefix = keyPrefix
        self._selection = selection
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(t("\(keyPrefix).\(option.rawValue)")).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// One pixel of edge. Used everywhere something is divided, so two separators in the same
/// app cannot end up different weights.
struct Hairline: View {
    @Environment(\.colorScheme) private var colorScheme
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Palette.hairline(colorScheme))
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

/// A bare icon that does something, with the label the icon cannot say — as a tooltip for a
/// pointer and as the accessibility label for everything else.
struct IconButton: View {
    let symbol: String
    let labelKey: String
    /// What the glyph is worth saying in: grey for the ordinary, the accent for the one
    /// thing a row invites, red for the one that takes something away.
    var tint: Color = .secondary
    var action: () -> Void

    /// Every icon button in the app is one of these — the feed header as much as a Settings
    /// row — so what it is worth hitting is `Hit.target` and is decided here rather than at
    /// each of them.
        var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Hit.target, height: Hit.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(t(labelKey))
        .accessibilityLabel(Text(t(labelKey)))
    }
}

/// SF Symbols are a view's vocabulary, so a protocol's face lives here rather than in Core.
extension SocialProtocol {
    var symbolName: String {
        switch self {
        case .mastodon: "bubble.left.and.bubble.right"
        case .activityPub: "point.3.connected.trianglepath.dotted"
        case .atProto: "cloud"
        case .nostr: "bolt"
        }
    }
}

/// What happened, as a face. S1 says an action is a glyph; a notice is not an action, but a
/// list of them is scanned the same way — the eye finds the boosts among the mentions by their
/// shape long before it reads a word of any row.
extension NoticeKind {
    var symbolName: String {
        switch self {
        case .mention: "at"
        case .favourite: "star"
        case .boost: "arrow.2.squarepath"
        case .follow: "person.badge.plus"
        case .poll: "chart.bar"
        case .update: "pencil"
        }
    }
}

/// Where a suggestion list came from, and how to say so. The picker renders whatever it is
/// handed rather than branching on which directory answered.
extension DirectoryOrigin {
    var noteKey: String {
        self == .joinMastodon ? "onboarding.server.source.joinMastodon" : "onboarding.server.source.builtIn"
    }

    var symbolName: String {
        self == .joinMastodon ? "info.circle" : "wifi.slash"
    }
}
