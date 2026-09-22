import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #97 — the audience mark on a row is larger, and coloured for how far the post travels.
///
/// What a test can reach: the role the mark is drawn in, the box that holds it, the four colours
/// and what they measure against the two grounds a row is ever drawn on, and the name the mark is
/// given to a pointer and to a screen reader in each of the three languages the app ships. What it
/// cannot: that the glyph looks right beside a host and an age on a running screen, which is named
/// in the report rather than claimed here.
///
/// **The suite is `@MainActor`** for the reason `TouchTests` states: `DummyItemRow`'s statics
/// belong to a `View` and are isolated to the main actor.
@Suite("The audience mark")
@MainActor
struct AudienceMarkTests {
    init() {
        L10n.language = .english
    }

    /// The two grounds an audience mark is ever drawn on: the page a row sits on, and the lifted
    /// plate it sits on once the reader is standing on it. The second is the harder of the two in
    /// dark, where it is the lighter surface — measuring only the page would pass a colour that
    /// fades out on exactly the row being read.
    private static func grounds(_ scheme: ColorScheme) -> [(String, Color)] {
        [("the page", ShellChrome.page(scheme)), ("a selected row", ShellChrome.floatFill(scheme))]
    }

    // MARK: - Larger than the caption beside it

    /// The first half of #97. The mark was `.meta` — the caption the handle takes — and the
    /// acceptance line is that it is now larger than that.
    ///
    /// **Asserted as points and not as "it is a different role".** A role swapped for another of
    /// the same size would satisfy the second spelling and none of the issue, and the ladder the
    /// two roles sit on is the one `ShellType` already computes.
    @Test("The mark is drawn a rung above the caption it used to share")
    func theMarkIsLargerThanTheCaption() {
        #expect(DummyItemRow.visRole != .meta, "the mark no longer takes the handle's caption")
        #if os(macOS)
        // The Mac is the platform that resolves points itself, so it is the platform that can be
        // asked. iOS hands the semantic style to the system, where `.callout` is larger than
        // `.caption` by the system's own scale and not by anything this package sets.
        let mark = ShellType.platformPoints(DummyItemRow.visRole.style)
        let caption = ShellType.platformPoints(ShellType.meta.style)
        #expect(mark > caption, "the audience mark measures \(mark)pt against the caption's \(caption)pt")
        // And it still fits the band the meta line stands in, which is the avatar's. A mark taller
        // than the face beside it would make the headline taller and the row with it.
        #expect(DummyItemRow.Box.vis <= DummyItemRow.Box.avatar)
        // The box is wide enough for the glyph it holds at the standard rung. A box that did not
        // grow with the role would clip the larger mark, which is the fix undone.
        #expect(DummyItemRow.Box.vis >= mark)
        #endif
    }

    // MARK: - A colour of its own, in both schemes

    /// Four audiences, four colours, and no two of them the same in either scheme.
    ///
    /// This is what the shipped code failed: public and unlisted were both `inkFaint` and
    /// followers and mentioned were both `inkDim`, so the four facts were two, and the pair a
    /// reader most needs to tell apart differed by 16% of one grey.
    @Test("Every audience has a colour of its own, in light and in dark")
    func everyAudienceHasItsOwnColour() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let drawn = DummyAudience.allCases.map {
                let ink = ShellChrome.vis($0, scheme).resolve(in: environment)
                return [ink.red, ink.green, ink.blue]
            }
            #expect(Set(drawn.map(\.description)).count == DummyAudience.allCases.count, """
                two audiences share a colour in \(scheme): \(drawn)
                """)
        }
        // And the two schemes are not one answer painted twice: a ramp that ignored the scheme
        // would be legible on one chassis and nearly invisible on the other.
        for audience in DummyAudience.allCases {
            #expect(ShellChrome.vis(audience, .light) != ShellChrome.vis(audience, .dark),
                    "\(audience.rawValue) is the same ink in both schemes")
        }
    }

    /// The colour holds, which is what "in both light and dark" has to mean if it is to mean
    /// anything a reader can check.
    ///
    /// 4.5:1 is the floor `ShellChrome.inkFaint` sets for small type in this file, and an audience
    /// mark is small type. Measured against both grounds a row is drawn on, because the selected
    /// row's plate is the lighter surface in dark and a colour chosen against the page alone can
    /// wash out on it.
    @Test("Every audience colour is legible on both grounds a row is drawn on")
    func everyAudienceColourHoldsOnBothGrounds() {
        for scheme in [ColorScheme.light, .dark] {
            for (named, ground) in Self.grounds(scheme) {
                for audience in DummyAudience.allCases {
                    let ratio = Self.contrast(ShellChrome.vis(audience, scheme), on: ground, scheme)
                    #expect(ratio >= 4.5, """
                        \(audience.rawValue) measures \(ratio):1 on \(named) in \(scheme). \
                        It was two steps of the ink ramp, which is the floor this replaces.
                        """)
                }
            }
        }
    }

    /// The ramp keeps clear of the chassis' own two hues and of the warning lamp. A lock in the
    /// filament amber reads as a mark the reader switched on, and a mention in the alarm red reads
    /// as a refusal — both are the colour saying something nobody said.
    @Test("No audience borrows the lamp, the filament or the alarm")
    func noAudienceBorrowsTheChassisHues() {
        for scheme in [ColorScheme.light, .dark] {
            let taken = [
                ShellChrome.phosphor(scheme), ShellChrome.filament(scheme),
                ShellChrome.alarm(scheme), ShellChrome.selectInk(scheme),
            ]
            for audience in DummyAudience.allCases {
                let ink = ShellChrome.vis(audience, scheme)
                #expect(!taken.contains(ink), "\(audience.rawValue) is a chassis hue in \(scheme)")
            }
        }
    }

    // MARK: - Still named, to a pointer and to a listener

    /// The mark is a glyph, and a glyph is nothing to a listener. The name is what carries the
    /// fact, so it has to be there in every language the app ships and it has to be the audience's
    /// own word rather than the key it was looked up by.
    @Test("The audience is named, in every language the app ships")
    func theAudienceIsStillNamed() {
        for language in DummyLanguage.allCases {
            L10n.language = language
            for audience in DummyAudience.allCases {
                let spoken = DummyItemRow.spokenAudience(audience)
                #expect(!spoken.isEmpty, "\(audience.rawValue) in \(language)")
                // `L10n.t` answers with the key where a table has no line for it, so a key read
                // back is a string table that lost an entry rather than a translation.
                #expect(spoken != "item.visibility.\(audience.rawValue)", """
                    \(language) has no line for \(audience.rawValue)
                    """)
            }
            // Four audiences, four words: a table that gave two of them the same name would leave
            // a listener unable to tell them apart, which is the defect this issue fixes for the
            // eye repeated for the ear.
            let spoken = DummyAudience.allCases.map(DummyItemRow.spokenAudience)
            #expect(Set(spoken).count == DummyAudience.allCases.count, "\(language): \(spoken)")
        }
        L10n.language = .english
    }

    // MARK: - Measuring

    /// The WCAG 2.1 contrast ratio between two of this app's tokens, one drawn on the other.
    ///
    /// The composite is done in the encoded sRGB space a renderer blends in, and the
    /// linearisation is applied once afterwards — `BoardChoiceTests.contrast(_:on:_:)` is where
    /// that choice is argued at length, and this is the same measurement applied to a different
    /// pair of tokens.
    private static func contrast(_ ink: Color, on ground: Color, _ scheme: ColorScheme) -> Double {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let over = ground.resolve(in: environment)
        let on = ink.resolve(in: environment)
        let alpha = Double(on.opacity)
        func blended(_ front: Float, _ back: Float) -> Double {
            Double(front) * alpha + Double(back) * (1 - alpha)
        }
        let first = Self.luminance(
            blended(on.red, over.red),
            blended(on.green, over.green),
            blended(on.blue, over.blue)
        )
        let second = Self.luminance(Double(over.red), Double(over.green), Double(over.blue))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// WCAG 2.1 relative luminance, from sRGB components as they are encoded.
    private static func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
