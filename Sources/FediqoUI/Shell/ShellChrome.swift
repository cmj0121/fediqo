import SwiftUI

/// Cool chassis chrome. One phosphor, no candy sky, no system colour for a ground.
///
/// Two hues for the marks and no more. `phosphor` says where the reader is and says
/// nothing else; `filament` is the warm counter-hue a mark takes once it is on.
/// Everything between them is the ink ramp and the plates — engraved, never printed.
///
/// **The plates are one ground, and it is the octopus' ink**: a violet (OKLCH hue 285) so faint
/// in light that it reads as paper and so deep in dark that it reads as night, with every plate
/// the same hue a step lighter or darker than the page. It is neither of the two hues above —
/// the lamp is teal and the on-mark amber, and amber sits across the wheel from violet, so a
/// mark that is on is the strongest thing on the page. `ChassisGroundTests` holds each plate to
/// the floors this file states: 4.5:1 for whatever is written on it, `placeFloor` for a glyph.
/// The one wash it does not hold every ink on is `selectFill`: `ink`, `inkDim` and the lamp are
/// written on a selected row and are held there, and `inkFaint` is not — it is 4.47:1 on that
/// wash in light, so nothing is written in it there, and a row that is chosen writes a step up.
///
/// The one family outside that rule is the audience ramp at the foot of this file, and
/// `vis(_:_:)` says why it had to be one: how far a post travels is four facts, and four
/// facts cannot be told apart on a ramp that has only more and less of the same grey.
enum ShellChrome {
    // MARK: The chassis

    static func page(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.075, 0.075, 0.141) : rgb(0.937, 0.941, 1.000)
    }

    static func rail(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.059, 0.055, 0.118) : rgb(0.902, 0.902, 0.961)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? rgb(0.45, 0.62, 0.66) : rgb(0.35, 0.48, 0.52))
            .opacity(scheme == .dark ? 0.28 : 0.22)
    }

    /// A milled recess: pills, keycaps, the plate a glyph sits in. The ground's own
    /// hue and never the lamp's — a container that borrows the lamp's hue makes every container
    /// look selected.
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.149, 0.149, 0.220) : rgb(0.894, 0.894, 0.953)
    }

    static func hoverFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? rgb(0.255, 0.255, 0.333).opacity(0.55)
            : rgb(0.922, 0.925, 0.980)
    }

    /// The lifted plate a focused row sits on.
    static func floatFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.145, 0.145, 0.216) : rgb(0.973, 0.973, 1.000)
    }

    /// A plate standing a little proud of the pane: a quoted post inside the post that quotes it
    /// (#214). Lighter than the page in dark and a shade darker in light, so it reads as
    /// a surface of its own in both — and apart from `well`, the recess a cover's plate sits in,
    /// so a covered quote's hatch still reads on it.
    static func raised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0.114, 0.114, 0.180) : rgb(0.914, 0.918, 0.973)
    }

    /// The soft shadow under `raised`. Low in light, where it is what lifts the plate; fainter
    /// still in dark, where a shadow on a dark page turns to a halo and the lighter fill lifts it.
    static func lift(_ scheme: ColorScheme) -> Color {
        Color.black.opacity(scheme == .dark ? 0.22 : 0.10)
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

    /// A control that is drawn and cannot be pressed for what it stands for: the same glyph as
    /// its live look, a step down the ramp. **A graphical object, so `placeFloor` is its line** —
    /// the reader has to see which control is there to know what the row would offer — and not
    /// the 4.5:1 of text; the count beside a dim mark is text and takes `inkFaint` instead.
    ///
    /// The opacity is set by the hardest ground a row's control is drawn on, which is the wash of
    /// a selected row over the page in both schemes: 3.19:1 there in light and 3.17:1 in dark
    /// (0.41 in dark measured 2.95 on it), and 3.2–3.4 light, 3.2–3.8 dark on the other plates.
    /// Live quiet is `inkDim`, 6.7:1 at its lowest, so the two looks are a clear step apart.
    /// `MarkContrastTests` measures every plate rather than trusting this.
    static func markDim(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(scheme == .dark ? 0.44 : 0.52)
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

    // MARK: On its way, and nothing here

    /// The contrast a placeholder holds against the ground it is drawn on — **3:1, WCAG's floor
    /// for a graphical object a reader needs in order to understand the screen** (1.4.11).
    ///
    /// A waiting plate is exactly that: it is the only thing saying a row is still coming rather
    /// than empty, so a reader who cannot tell it from the page has been told nothing. It is not
    /// text, so the 4.5:1 `inkFaint` holds for small type is the wrong line, and it is not
    /// decoration, so `hatch`'s "no floor" is the wrong line too. 3:1 is the figure for this kind
    /// of thing, chosen before the colours below and not read off them: the plates wore `well`,
    /// which measures 1.14:1 on the page in light, 1.07:1 at the bottom of its pulse, and 1.01:1
    /// on a selected row in dark.
    ///
    /// Held at **every** point of a pulse and by every still placeholder, on every ground a
    /// placeholder is drawn on. `WaitingContrastTests` measures that rather than trusting this.
    static let placeFloor: Double = 3

    /// What a waiting plate is drawn in — the ink ramp, not the milled recess.
    ///
    /// `well` is a container's colour and is meant to be quiet; a plate is standing in for a
    /// thing, so it takes the ramp the thing's own ink is on. At full this is 4.7:1 on the page
    /// in light and 4.8:1 in dark (in light, the same step as `inkFaint`), so that the bottom of
    /// `ShellWaiting`'s pulse still clears `placeFloor` on the page, on a selected row, and under
    /// a pointer. Over the ground rather than opaque, so it is measured against whichever of
    /// those it is on instead of against one of them.
    static func waiting(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(scheme == .dark ? 0.52 : 0.64)
    }

    /// The waiting plate where a picture is opened, on `behindPicture`. No scheme, for the reason
    /// that ground takes none: it is nearly black in both, and the light scheme's ink would
    /// vanish into it.
    static let waitingOnStage = overPicture.opacity(0.50)

    /// The edge of a place that holds nothing and is waiting for nothing — no face, no picture.
    ///
    /// **Hollow where a waiting plate is solid**, so the two cannot be taken for each other even
    /// in a still frame: an empty place keeps `well` as its fill, carries a glyph, and is outlined
    /// in this; a waiting one is filled in `waiting` and carries nothing. The edge is what holds
    /// the empty place to `placeFloor` — the fill stays the quiet recess the glyph was measured
    /// on — and it sits a step under `waiting` so a ring does not outweigh the glyph inside it.
    static func vacantEdge(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(scheme == .dark ? 0.44 : 0.56)
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

    // MARK: How far a post travels

    /// How far the post travels, as a colour — **four of them, one per audience, and the
    /// only place in this file where a hue is not the chassis' own.**
    ///
    /// It was two steps of the ink ramp: public and unlisted both `inkFaint`, followers and
    /// mentioned both `inkDim`. Two greys 16% apart cannot carry four facts — the pair a
    /// reader most needs to tell apart, a post anyone can read and a post written for
    /// nobody but them, differed by how faded they were and by nothing else. The glyph
    /// carried the whole of the answer and the colour carried none of it, which is the same
    /// as saying there was no colour.
    ///
    /// **A ramp and not four tastes.** It runs cool to warm the way the post's reach runs
    /// wide to narrow: green where anyone may read it, blue where it is public but not
    /// announced, violet where it stops at the people who follow, magenta where it stops at
    /// the people named in it. A reader who learns one end of it has learnt the direction.
    ///
    /// **It steers clear of the chassis' own two hues and of `alarm`.** A lock in the
    /// filament amber would read as a mark somebody had switched on, and a mention in the
    /// alarm red would read as a refusal. Neither is what an audience is.
    ///
    /// Every one of the eight clears 4.5:1 on the page it is drawn on — small type's floor,
    /// which is the floor `inkFaint` sets for this file — and on the lifted plate a selected
    /// row sits on, which is the lighter of the two grounds in dark. `AudienceMarkTests`
    /// measures both rather than trusting the numbers written here.
    static func vis(_ audience: DummyAudience, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch audience {
        case .everyone: return dark ? rgb(0.443, 0.816, 0.596) : rgb(0.106, 0.427, 0.243)
        case .unlisted: return dark ? rgb(0.522, 0.694, 0.976) : rgb(0.145, 0.349, 0.702)
        case .followers: return dark ? rgb(0.749, 0.655, 0.976) : rgb(0.392, 0.259, 0.671)
        case .mentioned: return dark ? rgb(0.945, 0.573, 0.792) : rgb(0.616, 0.176, 0.478)
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}
