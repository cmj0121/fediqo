import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #142 — what is on its way can be seen, in light as well as in dark.
///
/// What a test can reach: the colour every waiting plate and every still placeholder is drawn in,
/// the opacity it is drawn at at every instant of its pulse, and what that measures against every
/// ground it is drawn on — which is the whole of the claim, since a plate is a colour over a colour.
/// What it cannot: that the plate reads as a pulse and not as a flicker on a running screen, which
/// is named in the report rather than claimed here.
///
/// **The figure is `ShellChrome.placeFloor`, 3:1** — WCAG 1.4.11's floor for a graphical object a
/// reader needs in order to understand the screen. Before this, the plates wore `well`: 1.14:1 on
/// the page in light, 1.07:1 at the bottom of the pulse, and 1.01:1 on a selected row in dark.
///
/// **The suite is `@MainActor`** for the reason `WaitingTests` states: `ShellWaiting`'s and
/// `ForumWaiting`'s statics belong to a `View`.
@Suite("What is on its way can be seen")
@MainActor
struct WaitingContrastTests {
    /// Every ground a waiting plate or an empty place is drawn on in the chassis, as the layers it
    /// is made of: the page; the lifted plate a selected row sits on, which is the lighter surface
    /// in dark and so the harder of the two there; and the wash under a pointer on a source row,
    /// which is translucent in dark and is measured over the page it lies on.
    ///
    /// The rail is not here because nothing waits in it: no plate, face or picture is drawn there.
    private static func grounds(_ scheme: ColorScheme) -> [(String, [Color])] {
        let page = ShellChrome.page(scheme)
        return [
            ("the page", [page]),
            ("a selected row", [page, ShellChrome.floatFill(scheme)]),
            ("a row under the pointer", [page, ShellChrome.hoverFill(scheme)]),
        ]
    }

    /// Where a picture is opened: `behindPicture` over the page, nearly black in both schemes.
    private static func stage(_ scheme: ColorScheme) -> [Color] {
        [ShellChrome.page(scheme), ShellChrome.behindPicture]
    }

    /// One pass of the pulse, finely enough to land on its bottom, plus the bottom itself.
    private static let instants: [TimeInterval] =
        (0...120).map { Double($0) * ShellWaiting.period / 120 }

    // MARK: - The figure

    /// The figure is chosen, not measured: 3:1, and not a number read off whatever the colours
    /// happened to be.
    @Test("The shell holds its placeholders to 3:1")
    func theFigureIsThreeToOne() {
        #expect(ShellChrome.placeFloor == 3)
    }

    // MARK: - The waiting plate, at every point of its pulse

    /// The acceptance line itself: at the faintest point of its pulse, in light and in dark, on
    /// every ground a waiting plate is drawn on.
    @Test("The waiting plate clears the figure at every instant of its pulse, on every ground")
    func theWaitingPlateStandsApartThroughItsPulse() {
        for scheme in [ColorScheme.light, .dark] {
            let ink = ShellWaiting.ink(scheme, on: .chassis)
            for (named, ground) in Self.grounds(scheme) {
                let floor = Self.contrast(ink, at: ShellWaiting.banked, on: ground, scheme)
                #expect(floor >= ShellChrome.placeFloor, """
                    the waiting plate banks to \(floor):1 on \(named) in \(scheme)
                    """)
                for instant in Self.instants {
                    let glow = ShellWaiting.glow(at: instant)
                    let ratio = Self.contrast(ink, at: glow, on: ground, scheme)
                    #expect(ratio >= ShellChrome.placeFloor, """
                        at \(instant)s the waiting plate is \(ratio):1 on \(named) in \(scheme)
                        """)
                }
            }
        }
    }

    /// The viewer's plate is its own ink, because its ground is not the chassis: the light
    /// scheme's plate is a dark grey and would vanish into `behindPicture`.
    @Test("A picture opened while it is still coming waits as a plate that clears the figure")
    func theStagePlateStandsApart() {
        for scheme in [ColorScheme.light, .dark] {
            let ink = ShellWaiting.ink(scheme, on: .stage)
            for instant in Self.instants {
                let ratio = Self.contrast(ink, at: ShellWaiting.glow(at: instant), on: Self.stage(scheme), scheme)
                #expect(ratio >= ShellChrome.placeFloor, """
                    at \(instant)s the stage plate is \(ratio):1 in \(scheme)
                    """)
            }
            // The chassis plate would not have done, which is why the stage has its own.
            if scheme == .light {
                let chassis = ShellWaiting.ink(scheme, on: .chassis)
                #expect(Self.contrast(chassis, at: 1, on: Self.stage(scheme), scheme) < ShellChrome.placeFloor)
            }
        }
        #expect(RemoteImage.waitingPlate(on: .stage).ground == .stage)
        #expect(RemoteImage.waitingPlate().ground == .chassis)
    }

    /// With motion turned off there is no pulse, and the frame that is drawn is the plate at full.
    /// It clears the figure because every point of the pulse does; this says so for that one frame.
    @Test("With reduced motion the still plate clears the figure")
    func theStillPlateStandsApart() {
        #expect(ShellWaiting.clock(reduceMotion: true) == nil)
        let still = ShellWaiting.glow(at: 0)
        for scheme in [ColorScheme.light, .dark] {
            for (named, ground) in Self.grounds(scheme) {
                let ratio = Self.contrast(ShellWaiting.ink(scheme, on: .chassis), at: still, on: ground, scheme)
                #expect(ratio >= ShellChrome.placeFloor, "the still plate is \(ratio):1 on \(named) in \(scheme)")
            }
        }
    }

    /// The run of three that trails a sentence is a waiting plate too, and every plate of it
    /// clears the figure at every instant — a banked plate that goes out turns three plates into
    /// one plate and two gaps.
    @Test("Every plate of a sentence's waiting run clears the figure at every instant")
    func theWaitingRunStandsApart() {
        for scheme in [ColorScheme.light, .dark] {
            let ink = ForumWaiting.plateInk(scheme)
            for (named, ground) in Self.grounds(scheme) {
                for instant in Self.instants {
                    for plate in 0..<ForumWaiting.plates {
                        let ratio = Self.contrast(ink, at: ForumWaiting.glow(plate, at: instant), on: ground, scheme)
                        #expect(ratio >= ShellChrome.placeFloor, """
                            plate \(plate) at \(instant)s is \(ratio):1 on \(named) in \(scheme)
                            """)
                    }
                }
            }
        }
    }

    // MARK: - The still placeholders

    /// A forum row's words band waits as two still plates. They are the waiting plate's own ink
    /// at full, and they clear the figure wherever a row is drawn.
    @Test("A post's still waiting plates clear the figure")
    func thePostBandPlatesStandApart() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(ForumPostBand.plateInk(scheme) == ShellWaiting.ink(scheme, on: .chassis))
            for (named, ground) in Self.grounds(scheme) {
                let ratio = Self.contrast(ForumPostBand.plateInk(scheme), at: 1, on: ground, scheme)
                #expect(ratio >= ShellChrome.placeFloor, "the band's plate is \(ratio):1 on \(named) in \(scheme)")
            }
        }
    }

    /// An empty place — no face, no picture, nothing coming — is held to the same figure by its
    /// edge, on every chassis ground and against its own fill. On the stage its pale fill does it
    /// in light and its edge in dark.
    @Test("An empty place clears the figure by its edge")
    func theEmptyPlaceStandsApart() {
        for scheme in [ColorScheme.light, .dark] {
            let edge = ShellChrome.vacantEdge(scheme)
            for (named, ground) in Self.grounds(scheme) {
                let ratio = Self.contrast(edge, at: 1, on: ground, scheme)
                #expect(ratio >= ShellChrome.placeFloor, "the empty edge is \(ratio):1 on \(named) in \(scheme)")
            }
            let inside = Self.contrast(edge, at: 1, on: [ShellChrome.well(scheme)], scheme)
            #expect(inside >= ShellChrome.placeFloor, "the edge is \(inside):1 against its own fill in \(scheme)")

            let fill = Self.contrast(ShellChrome.well(scheme), at: 1, on: Self.stage(scheme), scheme)
            let ring = Self.contrast(edge, at: 1, on: Self.stage(scheme), scheme)
            #expect(max(fill, ring) >= ShellChrome.placeFloor, """
                on the stage in \(scheme) the empty place is \(fill):1 by its fill and \(ring):1 by its edge
                """)
        }
    }

    /// The glyph inside an empty place is what says which kind of nothing it is, and it is still
    /// legible on the fill it sits on — the reason the fill stayed `well`.
    @Test("The glyph in an empty place is legible on its fill")
    func theEmptyGlyphIsLegible() {
        for scheme in [ColorScheme.light, .dark] {
            let ratio = Self.contrast(ShellChrome.inkFaint(scheme), at: 1, on: [ShellChrome.well(scheme)], scheme)
            #expect(ratio >= ShellChrome.placeFloor, "the glyph is \(ratio):1 on its fill in \(scheme)")
        }
    }

    // MARK: - Empty is never waiting

    /// Solid against hollow, and far enough apart in a still frame to be told apart by the fill
    /// alone: the waiting plate at the bottom of its pulse clears the figure against the empty
    /// place's fill, so the two are not one grey in two places. And the empty place always carries
    /// a glyph, which a waiting plate never does.
    @Test("An empty place and a waiting one cannot be taken for each other")
    func emptyAndWaitingAreApart() {
        for scheme in [ColorScheme.light, .dark] {
            let well = [ShellChrome.page(scheme), ShellChrome.well(scheme)]
            for instant in Self.instants {
                let ratio = Self.contrast(
                    ShellWaiting.ink(scheme, on: .chassis), at: ShellWaiting.glow(at: instant), on: well, scheme)
                #expect(ratio >= ShellChrome.placeFloor, """
                    at \(instant)s a waiting plate is \(ratio):1 from an empty one in \(scheme)
                    """)
            }
            #expect(ShellChrome.vacantEdge(scheme) != ShellWaiting.ink(scheme, on: .chassis))
        }
        #expect(ShellVacant.glyph(.avatar) == "person.fill")
        #expect(ShellVacant.glyph(.picture) == "photo")
        // A picture that will never come is the empty place, not a plate that waits for ever.
        #expect(RemoteImage.fill(have: false, url: nil, missing: false) == .absent)
    }

    // MARK: - Measuring

    /// The WCAG 2.1 contrast ratio of `ink`, drawn at `opacity` over the layered `ground`, against
    /// that ground.
    ///
    /// Composited in the encoded sRGB space a renderer blends in, with the linearisation applied
    /// once afterwards — the choice `BoardChoiceTests.contrast(_:on:_:)` argues, extended to a
    /// ground made of more than one layer and an ink drawn at an opacity of its own.
    private static func contrast(
        _ ink: Color, at opacity: Double, on ground: [Color], _ scheme: ColorScheme
    ) -> Double {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        var under = (red: 0.0, green: 0.0, blue: 0.0)
        for layer in ground {
            under = over(layer.resolve(in: environment), under, alpha: 1)
        }
        let drawn = over(ink.resolve(in: environment), under, alpha: opacity)
        let first = luminance(drawn.red, drawn.green, drawn.blue)
        let second = luminance(under.red, under.green, under.blue)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func over(
        _ front: Color.Resolved, _ back: (red: Double, green: Double, blue: Double), alpha: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let a = Double(front.opacity) * alpha
        return (
            red: Double(front.red) * a + back.red * (1 - a),
            green: Double(front.green) * a + back.green * (1 - a),
            blue: Double(front.blue) * a + back.blue * (1 - a)
        )
    }

    /// WCAG 2.1 relative luminance, from sRGB components as they are encoded.
    private static func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
