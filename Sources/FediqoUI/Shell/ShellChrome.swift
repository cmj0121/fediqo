import SwiftUI

/// Cool chassis chrome. One phosphor, no candy sky, no system navy.
///
/// Two hues and no more. `phosphor` says where the reader is and says nothing else;
/// `filament` is the warm counter-hue a mark takes once it is on. Everything between
/// them is the ink ramp and the machined greys — engraved, never printed.
enum ShellChrome {
    // MARK: The chassis

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

    /// A milled recess: pills, keycaps, the plate a glyph sits in. Neutral on purpose —
    /// a container that borrows the lamp's hue makes every container look selected.
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.133, 0.161, 0.180) : rgb(0.886, 0.906, 0.918)
    }

    static func hoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? rgb(0.18, 0.28, 0.32).opacity(0.55)
            : rgb(0.918, 0.949, 0.957)
    }

    /// The lifted plate a focused row sits on.
    static func floatFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.11, 0.16, 0.19) : rgb(0.988, 0.992, 0.995)
    }

    static func dim(_ scheme: ColorScheme) -> Color {
        rgb(0.08, 0.12, 0.14).opacity(scheme == .dark ? 0.55 : 0.42)
    }

    // MARK: The ink

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.890, 0.918, 0.925) : rgb(0.098, 0.129, 0.145)
    }

    /// Present, read second: handles, hosts, a server's own summary.
    static func inkDim(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(0.80)
    }

    /// Engraved rather than written: decorators, counts nobody is looking for.
    ///
    /// The faintest step is still text, and text has a floor. At 0.45 this sat at
    /// 2.7:1 on the chassis — under the 4.5:1 that small type needs, and under the
    /// 3:1 that large type needs, which made the quietest line in the shell one that
    /// some readers could not read at all. Hierarchy is worth less than legibility.
    static func inkFaint(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(0.64)
    }

    // MARK: The two hues

    /// The lamp. Where the reader is, and nothing else.
    static func phosphor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.494, 0.784, 0.816) : rgb(0.184, 0.427, 0.471)
    }

    /// The wash a selected pill sits on. Light enough that the phosphor written on
    /// it still clears 4.5:1 — at 0.14 the pair measured 4.4, which is the floor this
    /// file sets for the faintest ink and then missed here.
    static func selectFill(_ scheme: ColorScheme) -> Color {
        phosphor(scheme).opacity(scheme == .dark ? 0.22 : 0.10)
    }

    static func selectInk(_ scheme: ColorScheme) -> Color {
        phosphor(scheme)
    }

    /// What a mark turns when the reader has switched it on. One warm hue for all of
    /// them: a favourite, a bookmark and a kept item differ by glyph, not by colour.
    static func filament(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.855, 0.694, 0.404) : rgb(0.541, 0.404, 0.176)
    }

    /// The warning lamp. A refusal has to read as a refusal, and no amount of ink
    /// weight does that on its own. One place only: the line that says a host was
    /// not added and why.
    static func alarm(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.898, 0.478, 0.443) : rgb(0.643, 0.212, 0.180)
    }

    // MARK: The cover

    /// The guard-plate hatch a covered post carries. Covered is neither where the reader is nor
    /// a mark they switched on nor a refusal, so it takes no hue: the ink ramp carries it and the
    /// pattern does the work. Decoration rather than text, so it has no contrast floor.
    static func hatch(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(scheme == .dark ? 0.16 : 0.12)
    }

    // MARK: On top of somebody's photograph

    /// The ink of a mark drawn over an attachment, and the shade it sits on.
    ///
    /// The only pair here that takes no colour scheme, and the reason is that the scheme does not
    /// decide the ground. Everywhere else in this file the ink is on the chassis and the two are
    /// chosen together; over a stranger's photograph the ground is whatever they photographed, so
    /// the pair has to carry its own contrast and carries the same one in both schemes. A token
    /// from the ramp would be legible against the page and invisible against a bright sky.
    static let overPicture = Color.white

    static let scrim = Color.black.opacity(0.55)

    /// The hatch drawn over a covered picture. No scheme, for the reason `scrim` takes none.
    static let hatchOverPicture = overPicture.opacity(0.28)

    /// The ground a picture is opened on, when `v` gives it the whole app.
    ///
    /// Scheme-independent for the reason the pair above is, and then darker than either: what
    /// sits on it is a photograph, and the one thing a ground behind a photograph must not do is
    /// look like part of it. Nearly opaque rather than a wash — `ShellChrome.dim` is right behind
    /// a panel the reader reads *and* keeps the page legible around it, which is exactly what is
    /// not wanted here.
    static let behindPicture = Color.black.opacity(0.92)

    /// Audience is carried by the glyph. Colour only says how far the post travels:
    /// what anyone can read recedes, what was narrowed to somebody stays legible.
    static func vis(_ audience: DummyAudience, _ scheme: ColorScheme) -> Color {
        switch audience {
        case .everyone, .unlisted: inkFaint(scheme)
        case .followers, .mentioned: inkDim(scheme)
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}
