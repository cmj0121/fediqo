import SwiftUI

/// What the New Post button opens. It is deliberately not a screen: composing is something
/// you do from wherever you already are, so it arrives over the timeline and leaves the
/// moment you look at anything else.
///
/// Posting lands with #8. This is the room it will land in — and the editor is already in
/// it, because it is the app's one text field inside the shell and so the one thing that can
/// say whether text is being typed. Every single-key shortcut depends on that answer, so the
/// field is here before the sending is.
struct ComposerView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    /// The keyboard, and where it is. SwiftUI will not say whether a text field somewhere
    /// has it, so this says it for the one field that could.
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .fediqoCard(radius: Radius.panel, shadow: true)
        // A composer you have to reach for the mouse to type in is a composer that failed on
        // a keyboard. `c` opens it and the cursor is already here; `Escape` is how you leave,
        // and it is the one key that still works while this has the keyboard.
        .task { await takeTheKeyboard() }
    }

    /// Asks the field for the keyboard until it has it.
    ///
    /// Not in `onAppear`, and not once after a fixed wait either. The panel arrives on an
    /// animation, and a field asked for the keyboard before it is on screen is not yet in
    /// the responder chain to take it — the ask is simply dropped. A single sleep timed
    /// against that animation is a bet, and losing it leaves a reader with no pointer in a
    /// panel they can neither type in nor get out of. So it asks again until the field says
    /// it has the keyboard, and stops the moment it does — or the moment the panel goes and
    /// `.task` is cancelled with it.
    private func takeTheKeyboard() async {
        for _ in 0..<Self.focusAttempts {
            if Task.isCancelled { return }
            typing = true
            try? await Task.sleep(for: Self.focusRetry)
            if typing { return }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            HStack(spacing: Space.step) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                Text(t("compose.title")).fediqoFont(TypeScale.lead, weight: .semibold)
                Spacer()
                Text(t("compose.wip")).fediqoFont(TypeScale.caption, weight: .medium).fediqoPill()
            }

            TextField(t("compose.placeholder"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($typing)
                .fediqoFont(TypeScale.small)
                .padding(Space.mid)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .fediqoCard(radius: Radius.inner, raised: false)
                .onChange(of: typing) { _, now in app.setTyping(now) }

            Text(t("compose.soon"))
                .fediqoFont(TypeScale.minor)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.pad)
        .frame(width: Self.size.width, alignment: .topLeading)
    }

    /// Fixed, and scrolled if the chosen text size overflows it, so the panel is the same
    /// shape at every text size and the shell can place it without asking how tall it is.
    static let size = CGSize(width: 320, height: 250)

    /// Eight asks, 25ms apart: 200ms in all, comfortably past the 0.15s the panel animates
    /// for, in steps short enough that the cursor is there before anybody has begun to type.
    private static let focusAttempts = 8
    private static let focusRetry = Duration.milliseconds(25)
}
