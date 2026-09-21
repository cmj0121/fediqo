import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The type scale. Eight roles, and every piece of copy in the shell picks one of them.
///
/// What is chosen here is which role a line plays and what weight it carries — not how many
/// points it happens to be.
///
/// ## Why this is a role and no longer a `Font` — #96
///
/// These were eight `static let`s holding semantic fonts, and on iPhone that was right: a
/// semantic `Font` is what Dynamic Type moves, so the type-size preference moved the whole
/// scale for free.
///
/// **On a Mac it moved nothing.** SwiftUI there does not scale a semantic `Font` with
/// `dynamicTypeSize` — `EmojiTextRole.points` measured it and wrote it down: `Font.body`
/// renders at the same size at every rung from xSmall to accessibility5. So the preference was
/// a control that did nothing on half the platforms this app ships to, and its own note said
/// what closing that would cost: *"`ShellType`'s tokens stop being static constants."*
///
/// This is that. A role is resolved to a `Font` by `shellFont(_:weight:monospaced:)`, which
/// reads the chosen size out of the environment — so the resolution happens where a view can be
/// invalidated by it, which a static constant can never be.
///
/// **iPhone is untouched by construction.** There the role still resolves to exactly the
/// semantic font it used to be, and Dynamic Type goes on doing the moving. Only the macOS
/// branch computes points.
enum ShellType: Hashable, Sendable, CaseIterable {
    /// The one loud thing on a page that has one. First run only.
    case display
    /// A pane's own title. One per page.
    case pane
    /// The line you read to know what this is: an author, a host, a group header.
    case name
    /// The words themselves.
    case body
    /// Present, read second: handles, summaries, the rule a timeline is under.
    case meta
    /// The smallest engraving: a decorator above a row, a hint under a field.
    case mark
    /// A reading off the instrument — a count, an age, a figure. Monospaced so a column of them
    /// does not wobble as the numbers change.
    case reading
    /// A key, written as the cap it is printed on.
    case keycap

    /// The semantic style this role is built on. **The one place the scale is stated**: every
    /// platform reads its own idea of what the style measures out of this.
    var style: Font.TextStyle {
        switch self {
        case .display: .title
        case .pane: .title3
        case .name: .callout
        case .body: .body
        case .meta: .caption
        case .mark: .caption2
        case .reading: .caption
        case .keycap: .body
        }
    }

    /// What the role carries by default. A call site may override it — a row that is lit reads
    /// its name heavier than one that is not — and most do not.
    var weight: Font.Weight {
        switch self {
        case .display, .pane, .name: .semibold
        case .body, .meta, .mark, .reading, .keycap: .regular
        }
    }

    /// Monospaced where a column of these has to line up, proportional otherwise.
    var design: Font.Design {
        switch self {
        case .reading, .keycap: .monospaced
        case .display, .pane, .name, .body, .meta, .mark: .default
        }
    }

    /// This role as a font, at the size the reader chose.
    ///
    /// **Two branches, and they are not the same kind of answer.** On iOS the semantic font is
    /// returned unchanged and the system moves it, which is the behaviour this app has always
    /// had there and must keep. On macOS nothing will move it, so the points are worked out
    /// here: the platform's own size for the style, times the rung.
    func font(at size: DynamicTypeSize, weight override: Font.Weight? = nil, monospaced: Bool = false)
        -> Font
    {
        let design = monospaced ? Font.Design.monospaced : self.design
        let weight = override ?? self.weight
        #if os(macOS)
        return .system(size: Self.platformPoints(style) * Self.multiple(at: size),
                       weight: weight, design: design)
        #else
        // **`.weight(.regular)` is not applied, and that is not tidiness.** It wraps the
        // semantic font in a modifier that states a weight, and a stated weight is one the
        // system's Bold Text setting no longer moves — so spelling the default out loud would
        // quietly opt every ordinary line out of an accessibility setting it honours today.
        // `EmojiTextRole.font` carried this rule before this type did.
        let base = Font.system(style, design: design)
        return weight == .regular ? base : base.weight(weight)
        #endif
    }

    /// How much bigger or smaller than the standard rung this one is.
    ///
    /// **The ladder is iOS's own, read off `UIFont` at `.body` and divided by the standard
    /// rung's 17 points.** Taken from there rather than invented so that a Mac and a phone set
    /// to the same rung read at the same relative size, and so that the numbers have a
    /// provenance somebody can check rather than a designer's taste nobody can.
    ///
    /// It is one curve for every role, where iOS uses a slightly different one per style —
    /// caption grows more slowly than body does. That difference is real and is lost here; the
    /// alternative is eleven tables of platform constants maintained by hand against a system
    /// that revises them. One curve is the honest approximation, and the letters move, which is
    /// what the preference promises.
    ///
    /// **No `default:`.** A rung added by a later SDK has to be given a number here — but
    /// `DynamicTypeSize` is not frozen, so `@unknown default` is required and answers with the
    /// standard rung, which is the safe reading of a size this build has never heard of.
    static func multiple(at size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 14.0 / 17
        case .small: 15.0 / 17
        case .medium: 16.0 / 17
        case .large: 1
        case .xLarge: 19.0 / 17
        case .xxLarge: 21.0 / 17
        case .xxxLarge: 23.0 / 17
        case .accessibility1: 28.0 / 17
        case .accessibility2: 33.0 / 17
        case .accessibility3: 40.0 / 17
        case .accessibility4: 47.0 / 17
        case .accessibility5: 53.0 / 17
        @unknown default: 1
        }
    }

    #if os(macOS)
    /// What this platform sets the style in before the rung is applied. Asked of the system
    /// rather than written down, so a Mac that revises its own scale is followed rather than
    /// contradicted.
    ///
    /// `caption1` and `caption2` are both 10 points here, which is the platform's own choice and
    /// not this table's: `meta` and `mark` already drew the same size on a Mac before anything
    /// moved, and they still do.
    static func platformPoints(_ style: Font.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: platformStyle(style)).pointSize
    }

    private static func platformStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
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
}

extension View {
    /// The role this line plays, set at the size the reader chose — **the one way copy in this
    /// shell is given a font.**
    ///
    /// A modifier and not a `Font` value, because the size has to be read out of the
    /// environment: that is what makes a view redraw when the preference moves, and it is the
    /// whole of why `ShellType` stopped being a table of constants (#96).
    ///
    /// **Two overrides, one per axis, and that is why the second one is not a role.** A role
    /// states a style, a weight and a design; `weight` overrides the second for the lines that
    /// read heavier when they are lit, and `monospaced` overrides the third for the small key
    /// cap that wants a letter to sit in a figure's box. Spelling that one out as a ninth role
    /// would name a size (`mark`) and a design twice over, and the axis is already named here.
    func shellFont(
        _ role: ShellType, weight: Font.Weight? = nil, monospaced: Bool = false
    ) -> some View {
        modifier(ShellFont(role: role, weight: weight, monospaced: monospaced))
    }
}

/// Resolves a role against the reader's chosen size. See `View.shellFont(_:weight:monospaced:)`.
struct ShellFont: ViewModifier {
    let role: ShellType
    var weight: Font.Weight?
    var monospaced: Bool = false

    @Environment(\.dynamicTypeSize) private var size

    func body(content: Content) -> some View {
        content.font(role.font(at: size, weight: weight, monospaced: monospaced))
    }
}

/// A measurement that grows with the letters — **`@ScaledMetric`, made to work on a Mac.**
///
/// ## Why this exists
///
/// `@ScaledMetric` is the right tool and it is inert on macOS, for exactly the reason a semantic
/// `Font` is: measured through `NSHostingView.fittingSize`, a `@ShellMetric(relativeTo: .callout)`
/// of 16 answers 16.0 at every rung from xSmall to accessibility5. So the app's avatars, glyphs,
/// touch targets and boxes stood still there — which nobody noticed while the letters stood still
/// beside them.
///
/// #96 moved the letters. A row whose words grow by 1.65× inside a 44-point box that does not is
/// the same defect the other way up, and the rail is the sharp case: a 148-point label column with
/// `lineLimit(1)` truncates the moment the name inside it grows. **So the two have to move
/// together, and there has to be one ladder rather than two mechanisms.**
///
/// ## What it is
///
/// On iOS, `@ScaledMetric` itself — unchanged behaviour, the system's own per-style curve, which
/// is better than any multiple this app could apply. On macOS, the base times
/// `ShellType.multiple(at:)`: the same product `ShellType.font(at:)` sets the letters by, read out
/// of the same environment, so a box and the words in it cannot come apart.
///
/// `relativeTo` is carried for the iOS half and ignored on macOS, where one curve serves every
/// style — `ShellType.multiple(at:)` says why.
@propertyWrapper
struct ShellMetric: DynamicProperty {
    #if os(macOS)
    @Environment(\.dynamicTypeSize) private var size
    private let base: CGFloat

    init(wrappedValue: CGFloat, relativeTo _: Font.TextStyle = .body) {
        base = wrappedValue
    }

    var wrappedValue: CGFloat { base * ShellType.multiple(at: size) }
    #else
    @ScaledMetric private var scaled: CGFloat

    init(wrappedValue: CGFloat, relativeTo style: Font.TextStyle = .body) {
        _scaled = ScaledMetric(wrappedValue: wrappedValue, relativeTo: style)
    }

    var wrappedValue: CGFloat { scaled }
    #endif
}
