import SwiftUI

/// Every pop-up this app draws over its own page, and what it dims that page to.
///
/// **A table, because "what happens when the reader presses beside it" is a question every
/// pop-up owes an answer to and nothing was asking it.** Two overlays hand-rolled a ground with
/// a tap gesture on it — `ShortcutGuide` and `AttachmentViewer`, agreeing because they were
/// written the same week and one's comment says it copied the other. That is the shape the four
/// defects risk 12 counts all had: a correct rule, attached where nothing can see it, so the
/// third one to be written would simply not have been asked.
///
/// **No `default:`.** A third pop-up breaks the build at `shade` until somebody says what the
/// page looks like behind it.
///
/// **What this table is not about.** `.sheet` and `.confirmationDialog` are the platform's
/// pop-ups, not this app's, and they are absent on purpose:
///
/// - On iOS both already go away on a press outside them, and the join sheet is swipe-cancellable
///   by a deliberate decision — see `JoinSheet`'s note on what `interactiveDismissDisabled` got.
/// - **On macOS a `.sheet` is window-modal: there is no outside to press.** Making the join sheet
///   dismissible that way means not being a sheet, which costs the modality a screen reader is
///   told about, the detents and the swipe. That is a redesign and not a rule.
enum ShellPopUp: CaseIterable {
    /// The dummy keys, written down over the page.
    case shortcutGuide
    /// One post's pictures, over everything — including over the guide.
    case attachmentViewer

    /// What the page looks like behind this pop-up.
    ///
    /// **Two veils and not one, which is `ShellChrome`'s ruling and not this table's.** A panel
    /// the reader *reads* wants the page still legible around it; a photograph wants a ground that
    /// cannot be mistaken for part of the picture. See `ShellChrome.behindPicture`.
    func shade(_ scheme: ColorScheme) -> Color {
        switch self {
        case .shortcutGuide: ShellChrome.dim(scheme)
        case .attachmentViewer: ShellChrome.behindPicture
        }
    }
}

/// What is behind a pop-up, **and the way out of it** — one thing, because they are one thing.
///
/// **There is no ground without a dismissal, and that is the whole point of this type.** The
/// dimming and the press that takes the pop-up away were two independent lines in two files, so
/// a pop-up drawn without the second one looked exactly like a pop-up with it — dimmed page,
/// dead tap. Here the veil cannot be built without saying what pressing it does: a pop-up that
/// does not close when the reader presses beside it is now unspellable rather than merely
/// discouraged, which is the same move `RowActionState` made for a row's controls.
///
/// **`contentShape` before the gesture**, because a `Color` fills its frame but only a shape
/// takes a hit — without it the press lands on whatever is behind the veil, which is the page the
/// pop-up is covering.
struct ShellGround: View {
    let popUp: ShellPopUp

    /// Not optional. See the type's own note: the absence of this is the defect.
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        popUp.shade(colorScheme)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
            // The ground is the page being covered, not a control. A reader using VoiceOver
            // leaves by the pop-up's own named button, and `.isModal` on the pop-up is what tells
            // them there is nothing behind it to reach.
            .accessibilityHidden(true)
    }
}
