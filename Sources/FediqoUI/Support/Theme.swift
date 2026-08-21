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
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.hairline(colorScheme)))
            .foregroundStyle(.secondary)
    }
}

extension View {
    func fediqoCard(radius: CGFloat = 10, raised: Bool = true, shadow: Bool = false) -> some View {
        modifier(Card(radius: radius, raised: raised, shadow: shadow))
    }

    func fediqoPill() -> some View {
        modifier(Pill())
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
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
