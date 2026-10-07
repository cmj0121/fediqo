import Foundation
import SwiftUI
@testable import FediqoUI

/// How the suites that hold an ink to a floor measure it, and the plates they measure it on —
/// written once, so two suites cannot measure one ink two ways.
@MainActor
enum ShellContrast {
    /// Every plate of the chassis, as the layers it is made of; a translucent one is measured
    /// over the page it lies on. `washed` adds the plates a row's control is also drawn on: the
    /// wash of a selected list row, and a pointer over a plate that is already one.
    static func plates(_ scheme: ColorScheme, washed: Bool = false) -> [(String, [Color])] {
        let page = ShellChrome.page(scheme)
        let chassis: [(String, [Color])] = [
            ("the page", [page]),
            ("the rail", [ShellChrome.rail(scheme)]),
            ("a recess", [page, ShellChrome.well(scheme)]),
            ("a raised plate", [page, ShellChrome.raised(scheme)]),
            ("a selected row", [page, ShellChrome.floatFill(scheme)]),
            ("a row under the pointer", [page, ShellChrome.hoverFill(scheme)]),
        ]
        guard washed else { return chassis }
        return chassis + [
            ("a selected list row", [page, ShellChrome.selectFill(scheme)]),
            ("a selected row under the pointer", [page, ShellChrome.floatFill(scheme), ShellChrome.hoverFill(scheme)]),
            ("a recess under the pointer", [page, ShellChrome.well(scheme), ShellChrome.hoverFill(scheme)]),
        ]
    }

    static func resolved(_ colour: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return colour.resolve(in: environment)
    }

    /// The WCAG 2.1 contrast ratio of `ink`, drawn at `opacity` over the layered `ground`, against
    /// that ground.
    ///
    /// Composited in the encoded sRGB space a renderer blends in, with the linearisation applied
    /// once afterwards — the choice `BoardChoiceTests.contrast(_:on:_:)` argues, extended to a
    /// ground made of more than one layer and an ink drawn at an opacity of its own.
    static func ratio(
        _ ink: Color, at opacity: Double = 1, on ground: [Color], _ scheme: ColorScheme
    ) -> Double {
        var under = (red: 0.0, green: 0.0, blue: 0.0)
        for layer in ground {
            under = over(resolved(layer, scheme), under, alpha: 1)
        }
        let drawn = over(resolved(ink, scheme), under, alpha: opacity)
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
