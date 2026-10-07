import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// A dim mark can still be seen: `ShellChrome.markDim` holds `placeFloor`, 3:1, on every plate of
/// the chassis a row's control is drawn on — the wash of a selected list row and a pointer over a
/// plate among them — in light and in dark.
///
/// **3:1 and not 4.5:1**: a glyph that says which control is there is a graphical object a reader
/// needs (WCAG 1.4.11), not text. Measured as every such floor is (`ShellContrast`) — the
/// ink composited over the layers of its ground — so a change of the ground that drops the dim
/// ink under the floor fails here rather than on a screen.
@Suite("A dim mark can be seen")
@MainActor
struct MarkContrastTests {
    /// Every plate a row's control is drawn on: the chassis', and the washes over them.
    private static func plates(_ scheme: ColorScheme) -> [(String, [Color])] {
        ShellContrast.plates(scheme, washed: true)
    }

    /// The floor with a little kept in hand, so a ground nudged by a hair does not land on it.
    private static let held = ShellChrome.placeFloor + 0.1

    @Test("The dim ink is the ink ramp at 0.52 in light and 0.44 in dark")
    func theDimInkIsAStepOfTheRamp() {
        #expect(ShellChrome.markDim(.light) == ShellChrome.ink(.light).opacity(0.52))
        #expect(ShellChrome.markDim(.dark) == ShellChrome.ink(.dark).opacity(0.44))
    }

    @Test("A dim mark clears 3:1 on every plate of the chassis")
    func theDimMarkStandsApart() {
        for scheme in [ColorScheme.light, .dark] {
            for reason in DimReason.allCases {
                for on in [false, true] {
                    let ink = ShellMark.ink(.dim(reason), on: on, scheme)
                    for (named, ground) in Self.plates(scheme) {
                        let ratio = ShellContrast.ratio(ink, on: ground, scheme)
                        #expect(ratio >= Self.held, "a dim mark is \(ratio):1 on \(named) in \(scheme)")
                    }
                }
            }
        }
    }

    /// Dim has to read as a step down from live, or the two looks are one: on every plate the
    /// quiet live ink stands further from the ground than the dim one does.
    @Test("A live mark stands further from its ground than a dim one, on every plate")
    func liveAndDimAreAStepApart() {
        for scheme in [ColorScheme.light, .dark] {
            for (named, ground) in Self.plates(scheme) {
                let dim = ShellContrast.ratio(ShellChrome.markDim(scheme), on: ground, scheme)
                let live = ShellContrast.ratio(ShellMark.ink(.live, on: false, scheme), on: ground, scheme)
                #expect(live >= dim * 1.5, "live is \(live):1 and dim \(dim):1 on \(named) in \(scheme)")
            }
        }
    }
}
