import SwiftUI
#if os(macOS)
import AppKit
#else
import GameController
#endif

/// A question asked before something that cannot be undone (#232) — **#231's rules, applied to
/// the one screen that must not be answered by accident.**
///
/// What it says, already in words: a title naming the act, **one line** saying what will happen,
/// and the rest behind a (?). Strings rather than keys because most of these carry a count or a
/// host (`L10n.count`, `String(format:)`), and the caller already builds that sentence.
///
/// **Choices, not one yes.** Removing a source is one destructive press; signing in is a choice
/// between reading and writing, neither of them a loss; a store written by a newer build is a
/// notice with nothing to choose but that it was read. The three are one shape: some choices, and
/// the press that leaves everything as it was — named Cancel unless it is named otherwise, and
/// absent only where there is nothing to leave.
struct ShellConfirmation: Equatable {
    /// One press that acts. `id` is what the answer hands back, so a caller switches on its own
    /// words rather than on a position.
    struct Choice: Equatable, Identifiable {
        enum Role: Equatable {
            /// A loss: drawn in the alarm hue and said to be destructive.
            case destructive
            /// The wider or usual answer, drawn in the lamp's hue.
            case primary
            /// The answer a key gives (⌘Return), drawn as one of several: a yes that is not a
            /// loss and must not look like an invitation either — Clear, or reading only.
            case keyed
            /// One of several answers, none of them a loss.
            case plain
        }

        let id: String
        let label: String
        let role: Role

        init(_ id: String, _ label: String, role: Role) {
            self.id = id
            self.label = label
            self.role = role
        }
    }

    /// The glyph of the act: `trash` for removing, `arrow.uturn.backward` for taking back.
    var symbol: String
    var title: String
    var line: String
    /// What the question used to say at length. Nothing where the line says it all.
    var help: String?
    var choices: [Choice]
    /// The press that changes nothing. Escape and every other way out answer it too. Never absent
    /// from a question with a loss in it.
    var cancel: String?

    init(
        symbol: String, title: String, line: String, help: String?, choices: [Choice],
        cancel: String? = L10n.t("board.choose.cancel")
    ) {
        self.symbol = symbol
        self.title = title
        self.line = line
        self.help = help
        self.choices = choices
        self.cancel = cancel
        assert(Self.wellFormed(choices: choices, cancel: cancel), "a destructive choice needs a way out")
    }

    /// A question with a loss in it always has a press that changes nothing.
    static func wellFormed(choices: [Choice], cancel: String?) -> Bool {
        cancel != nil || !choices.contains { $0.role == .destructive }
    }

    /// Where the keyboard starts: Cancel, or else the first choice that is not a loss.
    var firstFocus: String? {
        cancel != nil ? ShellConfirmCard.cancelFocus : choices.first { $0.role != .destructive }?.id
    }

    /// Whether the question is a warning. Only then is its glyph drawn in the alarm hue.
    var warns: Bool { choices.contains { $0.role == .destructive } }

    /// The one choice a deliberate chord answers: the first destructive one, or else the first
    /// primary or keyed one. Never bare Return, and never the chord that asks: see
    /// `ShellConfirmChord`.
    var chorded: Choice? {
        choices.first { $0.role == .destructive } ?? choices.first { $0.role == .primary || $0.role == .keyed }
    }
}

/// What the reader answered. A choice by its id; Escape, Cancel, a click outside or a swipe down
/// are all `.cancel`.
enum ShellConfirmAnswer: Equatable {
    case choice(String)
    case cancel

    /// The one door to the act. The question is taken down first, whatever the answer; only a
    /// choice then acts, and on the value that was asked about — not on whatever `item` holds by
    /// the time the answer lands.
    ///
    /// **Heard once.** A question already taken down — answered, or put away — takes no second
    /// answer: a second click on a sheet still sliding away, or Cancel and then a stray yes, acts
    /// on nothing.
    static func settle<Value>(
        _ answer: Self, asked value: Value, item: Binding<Value?>, onChoice: (Value, String) -> Void
    ) {
        guard item.wrappedValue != nil else { return }
        item.wrappedValue = nil
        if case .choice(let id) = answer { onChoice(value, id) }
    }

    /// **For a binding whose clearing is itself an act** — a flow that goes back, or out, when its
    /// question is put away (`CarryFlow`, `NearbyFlow`). `settle` takes the question down before
    /// it hands over the answer, so such a setter runs first on a yes too, and acting there
    /// undid the step the yes was about to take: "The same" and a take-away's choice did nothing
    /// (#253). Handing the answer over first is no cure — an answer that asks the next question
    /// (a take-away with no room is refused) would then have it cleared at once.
    ///
    /// So the put-away is judged one main-actor turn later, and acted on only if the question
    /// is still the one asked: an answer has moved it on by then, and only a question left
    /// standing was put away unanswered. `asked` and `now` are the question up, never the step
    /// under it — a clearing written back with no question up is no put-away.
    @MainActor
    static func putAway<Step: Equatable>(
        _ asked: Step?, now: @escaping @MainActor () -> Step?, act: @escaping @MainActor (Step) -> Void
    ) {
        guard let asked else { return }
        Task { @MainActor in
            guard now() == asked else { return }
            act(asked)
        }
    }
}

/// The question, drawn by the app rather than the system's alert.
///
///     (glyph)  Title
///              What will happen, in one line  (?)
///                                 [ Cancel ] [ Remove ]
///
/// **Cancel holds the keyboard.** It is the default focus and Escape's key; bare Return is given
/// to nothing, so a reader who pressed Return to open this cannot answer it with the same finger.
/// A yes has a chord of its own — ⌘D for a destructive one, ⌘Return for the usual one — that no
/// reflex reaches, heard only once the question has settled (`ShellConfirmChord`). A destructive
/// press is drawn in the alarm hue, and its hint tells VoiceOver it cannot be undone. Only the
/// first answer is taken; the card hears nothing after it.
struct ShellConfirmCard: View {
    let question: ShellConfirmation
    let answer: (ShellConfirmAnswer) -> Void

    @FocusState private var focus: String?
    /// Whether a choice may answer yet. See `ShellConfirmChord`.
    @State private var armed = false
    /// Whether this card has been answered. Only the first answer counts.
    @State private var answered = false
    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .title3) private var side: CGFloat = 36
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 340

    /// Where the keyboard starts: Cancel, or the only press there is.
    static let cancelFocus = "\u{1F}cancel"

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                glyph
                words
            }
            presses
        }
        .padding(ShellSpace.room)
        .frame(maxWidth: measure)
        .background(ShellChrome.page(colorScheme))
        .defaultFocus($focus, question.firstFocus)
        .task {
            try? await Task.sleep(for: ShellConfirmChord.settle)
            // Not while a key is still held down from before the question.
            while ShellConfirmChord.keyHeld(), !Task.isCancelled {
                try? await Task.sleep(for: ShellConfirmChord.poll)
            }
            armed = true
        }
    }

    private var glyph: some View {
        Image(systemName: question.symbol)
            .shellFont(.pane)
            .foregroundStyle(question.warns ? ShellChrome.alarm(colorScheme) : ShellChrome.selectInk(colorScheme))
            .frame(width: side, height: side)
            .background(Circle().fill(ShellChrome.well(colorScheme)))
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(question.title)
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ShellConfirmLine(line: question.line, help: question.help, subject: question.title)
        }
    }

    /// In a row where they fit, and one above another where they do not — three choices at the
    /// largest type on a phone.
    private var presses: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ShellSpace.snug) {
                Spacer(minLength: 0)
                pressList
            }
            VStack(alignment: .trailing, spacing: ShellSpace.snug) { pressList }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var pressList: some View {
        if let cancel = question.cancel {
            Button(cancel, role: .cancel) { once(.cancel) }
                .keyboardShortcut(.cancelAction)
                .focused($focus, equals: Self.cancelFocus)
        }
        ForEach(question.choices) { choice in
            ShellConfirmPress(choice: choice, chorded: choice == question.chorded, armed: armed) {
                once(.choice(choice.id))
            }
            .focused($focus, equals: choice.id)
        }
    }
}

extension ShellConfirmCard {
    /// Hands on the first answer, and nothing after it.
    fileprivate func once(_ given: ShellConfirmAnswer) {
        guard !answered else { return }
        answered = true
        answer(given)
    }
}

/// How a yes is answered from the keyboard, and when it is not.
///
/// **⌘D for a loss and ⌘Return for the usual answer.** ⌘D is the Mac's own key for the
/// destructive answer of a question ("Delete", "Don't Save"), and nothing in this app asks with it.
/// ⌘⌫ is not used, because the timeline editor asks to remove a timeline with ⌘⌫, and the key that
/// asks must never be the key that answers.
///
/// **A choice is heard only once the question has been up a moment, and a key never as a
/// repeat.** A key held down from before the question — ⌘Return saving a timeline, say — repeats
/// into it, and that repeat must not be taken for a yes. A pointer or a finger is held to the same
/// moment: a double click or tap that opened the question must not also answer it. On a phone or
/// tablet, where a key's repeat cannot be read, the moment also waits for every key to be let go.
enum ShellConfirmChord {
    static let settle: Duration = .milliseconds(350)
    static let poll: Duration = .milliseconds(50)

    static func chord(for role: ShellConfirmation.Choice.Role) -> KeyboardShortcut {
        role == .destructive
            ? KeyboardShortcut("d", modifiers: .command)
            : KeyboardShortcut(.return, modifiers: .command)
    }

    /// Whether an answer is heard: only once the question has settled, and from a key only when
    /// that key was not held down into it.
    static func heard(byKey: Bool, armed: Bool, repeating: Bool) -> Bool {
        armed && !(byKey && repeating)
    }

    /// Whether a key is held down right now, where that can be told apart from a repeat only this
    /// way — a hardware keyboard on a phone or tablet. A Mac reads the repeat itself.
    @MainActor
    static func keyHeld() -> Bool {
        #if os(macOS)
        false
        #else
        GCKeyboard.coalesced?.keyboardInput?.isAnyKeyPressed ?? false
        #endif
    }

    /// What the press in hand came from: a key, and whether that key is repeating.
    @MainActor
    static func current() -> (byKey: Bool, repeating: Bool) {
        #if os(macOS)
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return (false, false) }
        return (true, event.isARepeat)
        #else
        return (false, false)
        #endif
    }
}

/// One choice: its role said and drawn, and its chord where it has one — held off until the
/// question has settled.
private struct ShellConfirmPress: View {
    let choice: ShellConfirmation.Choice
    let chorded: Bool
    let armed: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(choice.label, role: choice.role == .destructive ? .destructive : nil, action: press)
            .tint(tint)
            .accessibilityHint(choice.role == .destructive ? L10n.t("confirm.destructive.hint") : "")
            .keyboardShortcut(chorded && armed ? ShellConfirmChord.chord(for: choice.role) : nil)
    }

    private func press() {
        let source = ShellConfirmChord.current()
        guard ShellConfirmChord.heard(byKey: source.byKey, armed: armed, repeating: source.repeating) else { return }
        action()
    }

    private var tint: Color? {
        switch choice.role {
        case .destructive: ShellChrome.alarm(colorScheme)
        case .primary: ShellChrome.selectInk(colorScheme)
        case .keyed, .plain: nil
        }
    }
}

/// The one line, and its (?) where there is more.
private struct ShellConfirmLine: View {
    let line: String
    let help: String?
    let subject: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            Text(line)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if let help { ShellHelp(verbatim: help, about: subject) }
        }
    }
}

/// Puts the question up while `item` holds a value, and takes it down however it is answered.
///
/// **A modifier, and the only way this is presented**, so a screen asks in one line and the
/// closure presenter stays out of any long view chain (the runner's type checker). `item` is what
/// the act is about — how many months, which source — and is what `onChoice` is handed.
///
/// **What was asked is kept until the sheet has gone**, in `shown`: `item` is cleared the moment
/// the question is answered, and a sheet still sliding away that read `item` would slide away
/// blank.
struct ShellConfirm<Value>: ViewModifier {
    @Binding var item: Value?
    let question: (Value) -> ShellConfirmation
    let onChoice: (Value, String) -> Void

    @State private var shown: Value?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: asking) { sheet }
            .onChange(of: item != nil, initial: true) { _, now in if now { shown = item } }
    }

    @ViewBuilder
    private var sheet: some View {
        if let value = item ?? shown {
            ShellConfirmSheet(question: question(value)) { answer in
                shown = value
                ShellConfirmAnswer.settle(answer, asked: value, item: $item, onChoice: onChoice)
            }
        }
    }

    /// Up while there is something to ask about; any way down clears it.
    private var asking: Binding<Bool> {
        Binding(get: { item != nil }, set: { up in
            guard !up else { return }
            // What is on the sheet as it leaves: the value asked about last, even if it changed
            // while the sheet was up.
            if let asked = item { shown = asked }
            item = nil
        })
    }
}

/// The card as a sheet: fitted to it on a Mac, and on a phone a medium height that can be pulled
/// to full — with the card scrolling where even that is too short, at the largest type.
private struct ShellConfirmSheet: View {
    let question: ShellConfirmation
    let answer: (ShellConfirmAnswer) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            card
            ScrollView { card }
        }
        .presentationSizing(.fitted)
        .presentationDetents([.medium, .large])
    }

    private var card: some View {
        ShellConfirmCard(question: question, answer: answer)
    }
}

extension View {
    /// Asks the question `item` makes while it is set; hands `onChoice` the value asked about and
    /// the id of the choice made. Escape, Cancel and every other way out clear `item` and change
    /// nothing else.
    func shellConfirm<Value>(
        _ item: Binding<Value?>, question: @escaping (Value) -> ShellConfirmation,
        onChoice: @escaping (Value, String) -> Void
    ) -> some View {
        modifier(ShellConfirm(item: item, question: question, onChoice: onChoice))
    }

    /// The same, for a question about nothing but itself — the flag a screen already holds.
    func shellConfirm(
        _ isPresented: Binding<Bool>, question: ShellConfirmation, onChoice: @escaping (String) -> Void
    ) -> some View {
        let item = Binding<Bool?>(
            get: { isPresented.wrappedValue ? true : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        )
        return modifier(ShellConfirm(item: item, question: { _ in question }, onChoice: { _, id in onChoice(id) }))
    }
}
