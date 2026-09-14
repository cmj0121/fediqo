import SwiftUI

/// Cool chassis chrome. One phosphor, no candy sky, no system navy.
enum ShellChrome {
    static func page(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.063, 0.086, 0.102) : rgb(0.949, 0.961, 0.969)
    }

    static func rail(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.047, 0.067, 0.078) : rgb(0.894, 0.922, 0.933)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? rgb(0.45, 0.62, 0.66) : rgb(0.35, 0.48, 0.52))
            .opacity(scheme == .dark ? 0.28 : 0.22)
    }

    static func well(_ scheme: ColorScheme) -> Color {
        phosphor(scheme).opacity(scheme == .dark ? 0.16 : 0.10)
    }

    static func selectFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.090, 0.188, 0.220) : rgb(0.831, 0.894, 0.910)
    }

    static func selectInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.561, 0.804, 0.831) : rgb(0.141, 0.345, 0.384)
    }

    static func hoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? rgb(0.18, 0.28, 0.32).opacity(0.55)
            : rgb(0.918, 0.949, 0.957)
    }

    static func phosphor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.494, 0.784, 0.816) : rgb(0.184, 0.427, 0.471)
    }

    static func reblog(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.478, 0.659, 0.627) : rgb(0.239, 0.435, 0.416)
    }

    static func favourite(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.769, 0.647, 0.416) : rgb(0.541, 0.439, 0.251)
    }

    static func bookmark(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.478, 0.608, 0.690) : rgb(0.239, 0.353, 0.451)
    }

    static func dim(_ scheme: ColorScheme) -> Color {
        rgb(0.08, 0.12, 0.14).opacity(scheme == .dark ? 0.55 : 0.42)
    }

    static func vis(_ audience: DummyAudience, _ scheme: ColorScheme) -> Color {
        switch audience {
        case .everyone: phosphor(scheme).opacity(0.85)
        case .unlisted: scheme == .dark ? rgb(0.45, 0.72, 0.68) : rgb(0.23, 0.48, 0.45)
        case .followers: scheme == .dark ? rgb(0.78, 0.62, 0.42) : rgb(0.54, 0.42, 0.28)
        case .mentioned: scheme == .dark ? rgb(0.62, 0.64, 0.78) : rgb(0.35, 0.37, 0.47)
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}
