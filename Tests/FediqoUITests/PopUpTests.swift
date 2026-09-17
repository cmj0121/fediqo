import SwiftUI
import Testing

@testable import FediqoUI

/// **What every pop-up owes the reader who presses beside it.**
///
/// The rule existed and was drawn twice, by hand, in two `View` bodies — `ShortcutGuide` dimmed
/// the page and took a tap on it, and `AttachmentViewer` did the same with a darker veil and a
/// comment naming the other one as its authority. Neither was reachable from a test, which is the
/// shape all four of the defects risk 12 counts had, and a third pop-up would have been written
/// without the question ever being put to it.
@MainActor
@Suite("Pop-ups, and the way out of one")
struct PopUpTests {
    init() { L10n.language = .english }

    private static func alpha(_ colour: Color, _ scheme: ColorScheme) -> Double {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return Double(colour.resolve(in: environment).opacity)
    }

    /// **Every pop-up names a ground, because the `switch` has no `default:`.**
    ///
    /// This is a compile-time pin before it is an assertion: a third case cannot be added to
    /// `ShellPopUp` without `shade(_:)` failing to build until somebody says what the page looks
    /// like behind it. What is asserted here is the half a compiler cannot check — that the
    /// answer given is a veil and not a pane of glass.
    ///
    /// **A ground the reader cannot see is worse than none.** The press still lands on it, so the
    /// pop-up still closes — and nothing on screen ever said the page was covered, so a reader
    /// who pressed a row and watched a panel vanish instead has no account of what happened.
    @Test("Every pop-up covers the page it is over, in both schemes")
    func everyPopUpVeilsThePageBehindIt() {
        for popUp in ShellPopUp.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let alpha = Self.alpha(popUp.shade(scheme), scheme)
                #expect(alpha >= 0.3, """
                    \(popUp) draws a ground at \(alpha) alpha in \(scheme) — a press beside the \
                    pop-up lands on something the reader was never shown.
                    """)
            }
        }
    }

    /// The one rule that distinguishes the two veils, and it is `ShellChrome`'s rather than the
    /// table's: a panel the reader *reads* keeps the page legible around it, and a photograph
    /// must not be mistakeable for the ground behind it.
    @Test("A picture's ground is heavier than a panel's, in both schemes")
    func thePictureGroundIsTheDarkerOfTheTwo() {
        for scheme in [ColorScheme.light, .dark] {
            let panel = Self.alpha(ShellPopUp.shortcutGuide.shade(scheme), scheme)
            let picture = Self.alpha(ShellPopUp.attachmentViewer.shade(scheme), scheme)
            #expect(picture > panel, """
                In \(scheme) the ground behind a photograph (\(picture)) is no heavier than the \
                one behind a panel (\(panel)) — so the picture reads as part of what is under it.
                """)
        }
    }

    /// **The table is the list of this app's own pop-ups, and a new one has to join it.**
    ///
    /// Nothing can enumerate the overlays a `View` body draws — there is no UI test target, which
    /// is risk 12 — so this cannot prove the table is complete. What it does is make the count a
    /// stated fact: a pop-up added without a `ShellGround` leaves this number unchanged while the
    /// screen has grown one, and the reader of this failure is somebody who has just added one.
    ///
    /// **`.sheet` and `.confirmationDialog` are deliberately not here.** They are the platform's
    /// pop-ups: on iOS both already close on a press outside them, and on macOS a sheet is
    /// window-modal, so there is no outside to press. See `ShellPopUp`'s own note.
    @Test("This app draws two pop-ups of its own, and both have a way out")
    func theTableNamesEveryPopUpThisAppDraws() {
        #expect(ShellPopUp.allCases.count == 2, """
            A pop-up was added to or removed from this app. If it was added: it needs a case here \
            and a `ShellGround`, or it is a panel over a dimmed page that a press beside does \
            nothing to.
            """)
        // Built at all, which is the structural half: `ShellGround` has no initialiser that omits
        // the dismissal, so a veil without a way out of it cannot be spelled.
        for popUp in ShellPopUp.allCases {
            var closed = false
            let ground = ShellGround(popUp: popUp) { closed = true }
            #expect(ground.popUp == popUp)
            ground.dismiss()
            #expect(closed, "\(popUp)'s ground was handed a dismissal that does nothing")
        }
    }
}
