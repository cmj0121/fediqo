import SwiftUI
import FediqoCore

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
    @State private var warning = ""
    @State private var showingWarning = false
    @State private var audience: Audience = .everyone
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
        // That server's rule, asked of it rather than written here, and asked when the panel
        // opens because it is theirs to change between one post and the next.
        .task { await app.askTheLimit() }
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
                room
            }

            if showingWarning {
                TextField(t("composer.warning"), text: $warning)
                    .textFieldStyle(.plain)
                    .fediqoFont(TypeScale.small)
                    .padding(Space.mid)
                    .fediqoCard(radius: Radius.inner, raised: false)
            }

            TextField(t("compose.placeholder"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($typing)
                .fediqoFont(TypeScale.small)
                .padding(Space.mid)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .fediqoCard(radius: Radius.inner, raised: false)
                .onChange(of: typing) { _, now in app.setTyping(now) }

            destinations
            controls
        }
        .padding(Space.pad)
        .frame(width: Self.size.width, alignment: .topLeading)
    }

    /// How much room is left, or nothing at all where the server never said.
    ///
    /// Nothing rather than a number of ours: how long a post may be is that server's rule, and
    /// a composer counting down to a figure this app invented would be lying quietly until the
    /// moment it mattered. It turns when the room runs out, because that is the one moment the
    /// count is worth reading.
    @ViewBuilder
    private var room: some View {
        if let limit = app.postingLimit {
            // Counted the way the check counts it, so what the reader watches run out and what
            // a server would refuse are one number rather than two that nearly agree.
            let left = limit - written.length
            Text(verbatim: "\(left)")
                .fediqoFont(TypeScale.caption, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(left < 0 ? .red : .secondary)
        }
    }

    /// Where it is going, and what became of each of them last time it was sent.
    ///
    /// Drawn only where there is a choice to make: a reader with one account has already chosen
    /// by having one, and a row of one toggle is a question with one answer.
    ///
    /// The marks beside them are the per-destination answer #8 asks for. A post that reached two
    /// servers of three is two ticks and one cross, said where the reader chose them and where
    /// they can choose again — a notice can only say one thing, and this is three things.
    @ViewBuilder
    private var destinations: some View {
        let choices = app.actingChoices
        if choices.count > 1 {
            FlowRow(spacing: Space.tight) {
                ForEach(choices, id: \.endpoint) { choice in
                    let host = Server.normalise(choice.endpoint)
                    let chosen = app.postingTo.isEmpty
                        ? host == app.lastPosted : app.postingTo.contains(choice.endpoint)
                    Button {
                        if app.postingTo.isEmpty { app.postingTo = Set(choices.map(\.endpoint)) }
                        if app.postingTo.contains(choice.endpoint) {
                            app.postingTo.remove(choice.endpoint)
                        } else {
                            app.postingTo.insert(choice.endpoint)
                        }
                        Task { await app.askTheLimit() }
                    } label: {
                        HStack(spacing: Space.tight) {
                            if let sent = app.lastSent[host] {
                                Image(systemName: sent.went ? "checkmark" : "exclamationmark.triangle.fill")
                                    .fediqoSymbol(Glyph.badge, weight: .semibold)
                                    .foregroundStyle(sent.went ? Color.green : .orange)
                            }
                            Text(host).fediqoFont(TypeScale.caption, weight: .medium)
                        }
                        .fediqoPill()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(chosen ? Palette.accent : Color.secondary)
                }
            }
        }
    }

    /// Who it is for, whether there is a warning, and the press that sends it.
    private var controls: some View {
        HStack(spacing: Space.step) {
            Menu {
                Picker("", selection: $audience) {
                    ForEach(Audience.allCases, id: \.self) { choice in
                        Text(t("post.visibility.\(choice.rawValue)")).tag(choice)
                    }
                }
                .labelsHidden()
            } label: {
                Image(systemName: Self.mark(for: audience)).fediqoSymbol(Glyph.inline, weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(t("post.visibility.\(audience.rawValue)"))

            // The warning is a field that is not there until it is asked for: most posts have
            // none, and an empty box above every draft is a question nobody was asking.
            Button {
                showingWarning.toggle()
                if !showingWarning { warning = "" }
            } label: {
                Image(systemName: showingWarning ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    .fediqoSymbol(Glyph.inline, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(showingWarning ? .orange : .secondary)
            .help(t("composer.warning"))

            Spacer(minLength: Space.snug)

            Button(t(app.isSending ? "composer.sending" : "composer.send")) {
                let going = written
                Task {
                    // The draft is cleared only where it all went. A post that a server refused
                    // is still written, and losing it is the worst thing this could do.
                    if await app.publish(going) { draft = ""; warning = ""; showingWarning = false }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .fediqoFont(TypeScale.small, weight: .medium)
            .disabled(!canSend)
        }
    }

    /// What is written, as the one value everything here reads: the counter, the check and the
    /// send are three questions about one draft, and building it three times is three chances
    /// for them to differ.
    private var written: Draft {
        Draft(text: draft, audience: audience, warning: showingWarning ? warning : nil)
    }

    /// Nothing to send, no room left, or one already on its way.
    private var canSend: Bool {
        guard !app.isSending else { return false }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let limit = app.postingLimit else { return true }
        return written.length <= limit
    }

    /// The same four glyphs a row draws for the same four audiences. One idea, drawn the same
    /// way wherever it is: what a reader chooses here is what they will see on the row.
    private static func mark(for audience: Audience) -> String {
        switch audience {
        case .everyone: "globe"
        case .unlisted: "moon"
        case .followers: "lock"
        case .mentioned: "at"
        }
    }

    /// Fixed, and scrolled if the chosen text size overflows it, so the panel is the same
    /// shape at every text size and the shell can place it without asking how tall it is.
    static let size = CGSize(width: 320, height: 250)

    /// Eight asks, 25ms apart: 200ms in all, comfortably past the 0.15s the panel animates
    /// for, in steps short enough that the cursor is there before anybody has begun to type.
    private static let focusAttempts = 8
    private static let focusRetry = Duration.milliseconds(25)
}
