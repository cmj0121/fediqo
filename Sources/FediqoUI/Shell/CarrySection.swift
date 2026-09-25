import FediqoCore
import SwiftUI
import UniformTypeIdentifiers

/// The group on Preferences that takes what this device holds away, and reads it back (#247):
/// a heading with its short line and (?), two icon presses, and — while either runs — how far
/// it has come. Everything asked is asked by `CarryFlow`, on the pane.
///
/// Drawn only where the shell handed the session a carrier: a preview or a test without one
/// draws nothing, and does not offer a press that could do nothing.
struct CarrySection: View {
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let carrier = session.carrier {
            Section {
                HStack(spacing: ShellSpace.snug) {
                    line
                    Spacer(minLength: ShellSpace.snug)
                    ShellIconButton("square.and.arrow.up", name: "carry.take", help: "carry.take.help") {
                        session.carry.beginTakeAway(with: carrier)
                    }
                    ShellIconButton("square.and.arrow.down", name: "carry.read", help: "carry.read.help") {
                        session.carryPicking = true
                    }
                }
                .disabled(session.carry.isUp || session.nearby.isUp)
                .padding(.vertical, ShellSpace.tight)
            } header: {
                ShellSectionHead(title: "carry.title", line: "carry.line", help: "carry.help")
            }
        }
    }

    /// What is happening, or what the group is for while nothing is.
    @ViewBuilder
    private var line: some View {
        if let progress = session.carry.progress {
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                ProgressView(value: progress.fraction)
                Text(Self.progressLine(progress, reading: { if case .reading = session.carry.step { true } else { false } }()))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        } else if case .weighing = session.carry.step {
            ProgressView()
        } else {
            Text(L10n.t("carry.idle"))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
    }

    /// "Taking away · 1.2 GB of 3.4 GB", or the whole where the total is not yet known.
    static func progressLine(_ progress: PackageProgress, reading: Bool, language: DummyLanguage? = nil) -> String {
        let what = L10n.t(reading ? "carry.reading" : "carry.taking", language: language)
        guard progress.total > 0 else { return what }
        return what + " · " + String(
            format: L10n.t("carry.progress", language: language),
            UsagePane.size(progress.done, language: language), UsagePane.size(progress.total, language: language)
        )
    }
}

/// Everything the flow asks, on the pane: the questions (`ShellQuestion`), the password sheet,
/// the progress sheet while the package is written or read back (`ShellProgressSheet`, shared
/// with the move nearby), the system's mover once the package is written, and its picker for a
/// file to read back.
///
/// **The password and the progress are one presenter** (`Sheet`), so the hand-off from one to
/// the other is a change of item SwiftUI sequences itself. **The mover waits for the progress
/// sheet to have gone** (`progressUp`): the system's panel is not asked up while a sheet is still
/// sliding away, which a small package written in a blink would otherwise race.
///
/// **A modifier, and the only way this is presented**, so the pane adds one line and the
/// presenters stay out of any long view chain (the runner's type checker).
struct CarryFlow: ViewModifier {
    /// Nothing where the pane has no session — a preview, a test — and then nothing is asked.
    let session: ShellSession?
    @Environment(DummyPrefs.self) private var prefs
    /// Whether the progress sheet is on screen — up from its first draw until its dismissal has
    /// finished — which the mover waits on.
    @State private var progressUp = false

    /// The sheet up: a password asked, or how far the package has come.
    enum Sheet: Identifiable, Equatable {
        case password(ShellCarry.Ask)
        case progress

        var id: String {
            switch self {
            case .password(let ask): "password " + ask.id
            case .progress: "progress"
            }
        }
    }

    static func sheet(for carry: ShellCarry) -> Sheet? {
        if let ask = carry.ask { return .password(ask) }
        return ShellCarry.showsProgress(carry.step) ? .progress : nil
    }

    func body(content: Content) -> some View {
        content
            .shellConfirm(asking, question: Self.question, onChoice: answer)
            .sheet(item: sheet, onDismiss: { progressUp = false }) { sheet in
                switch sheet {
                case .password(let ask):
                    CarryPasswordSheet(ask: ask, onDone: gave, onCancel: { session?.carry.dismiss() })
                case .progress:
                    if let session { CarryProgressSheet(carry: session.carry).onAppear { progressUp = true } }
                }
            }
            .fileMover(isPresented: moverUp, file: session?.carry.moving) { session?.carry.moved($0) }
            .fileImporter(isPresented: pickerUp, allowedContentTypes: [.data], onCompletion: picked)
    }

    /// Put away unanswered is out; judged a turn later, as a yes clears this too
    /// (`ShellConfirmAnswer.putAway`), and on the question up rather than the step, so a
    /// clearing written back with none up stops nothing.
    var asking: Binding<ShellCarry.Step?> {
        Binding(get: { session?.carry.asking }, set: {
            guard $0 == nil, let carry = session?.carry else { return }
            ShellConfirmAnswer.putAway(carry.asking, now: { carry.asking }) { _ in carry.dismiss() }
        })
    }

    /// A password sheet put away is Cancel, as ever; the progress sheet put away by the system
    /// stops nothing — only its Cancel does (`sheetPutAway`).
    private var sheet: Binding<Sheet?> {
        Binding(get: { session.flatMap { Self.sheet(for: $0.carry) } }, set: {
            guard $0 == nil, let carry = session?.carry else { return }
            Self.sheetPutAway(carry)
        })
    }

    /// Judged on the sheet up: a password sheet put away is out; the progress sheet, or none,
    /// is nothing.
    static func sheetPutAway(_ carry: ShellCarry) {
        if case .password = sheet(for: carry) { carry.dismiss() }
    }

    private var moverUp: Binding<Bool> {
        Binding(get: { session?.carry.moving != nil && !progressUp }, set: { if !$0 { session?.carry.moveCancelled() } })
    }

    private var pickerUp: Binding<Bool> {
        Binding(get: { session?.carryPicking ?? false }, set: { session?.carryPicking = $0 })
    }

    static func question(_ step: ShellCarry.Step) -> ShellConfirmation {
        switch step {
        case .choosing(let weight): ShellQuestion.takeAway(weight)
        case .previewing(let preview): ShellQuestion.readBack(preview.summary, held: preview.held)
        case .refused(let trouble): ShellQuestion.carryRefused(trouble)
        case .done(let done): ShellQuestion.carryDone(done)
        default: ShellQuestion.carryDone(.taken)
        }
    }

    func answer(_ step: ShellCarry.Step, _ id: String) {
        guard let session, let carrier = session.carrier else { return }
        switch step {
        case .choosing:
            session.carry.chose(pictures: id == ShellQuestion.withPictures)
        case .previewing:
            session.carry.confirmReadBack(with: carrier, pictures: session.pictures.disk) {
                await session.adoptReadBack(prefs: prefs)
            }
        default:
            session.carry.dismiss()
        }
    }

    private func gave(_ password: String) {
        guard let session, let carrier = session.carrier, let ask = session.carry.ask else { return }
        switch ask {
        case .set: session.carry.set(password: password, with: carrier) { await session.persist?() }
        case .open: session.carry.open(password: password, with: carrier)
        }
    }

    private func picked(_ result: Result<URL, any Error>) {
        session?.carryPicking = false
        if case .success(let url) = result { session?.carry.picked(url) }
    }
}

/// The progress sheet while a package is written or read back: `ShellCarry.progress`, redrawn
/// as each figure lands.
struct CarryProgressSheet: View {
    let carry: ShellCarry

    var body: some View {
        if let progress = ShellCarry.progress(carry.step) {
            ShellProgressSheet(progress: progress) { carry.dismiss() }
        }
    }
}

/// The password, asked in the question's own shape (#238): a title naming the act, one line, the
/// rest behind (?), and the field. Setting one asks for it twice, and says before either that a
/// lost password cannot be recovered; giving one asks once.
struct CarryPasswordSheet: View {
    let ask: ShellCarry.Ask
    let onDone: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var again = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .title3) private var side: CGFloat = 36
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                glyph
                words
            }
            fields
            presses
        }
        .padding(ShellSpace.room)
        .frame(maxWidth: measure)
        .background(ShellChrome.page(colorScheme))
        .presentationSizing(.fitted)
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    private var setting: Bool {
        if case .set = ask { true } else { false }
    }

    /// Whether what was typed may be handed on: not empty, and where it is being set, long
    /// enough and the same twice.
    var ready: Bool { Self.ready(password: password, again: again, setting: setting) }

    static func ready(password: String, again: String, setting: Bool) -> Bool {
        guard !password.isEmpty else { return false }
        return !setting || (password.count >= PackageFormat.minPasswordCount && password == again)
    }

    private var glyph: some View {
        Image(systemName: "key")
            .shellFont(.pane)
            .foregroundStyle(ShellChrome.selectInk(colorScheme))
            .frame(width: side, height: side)
            .background(Circle().fill(ShellChrome.well(colorScheme)))
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(L10n.t(setting ? "carry.password.set.title" : "carry.password.open.title"))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t(setting ? "carry.password.set.line" : "carry.password.open.line"))
                .shellFont(.body)
                .foregroundStyle(setting ? ShellChrome.alarm(colorScheme) : ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .shellHelp(setting ? "carry.password.set.help" : "carry.password.open.help", about: L10n.t("carry.title"))
        }
    }

    @ViewBuilder
    private var fields: some View {
        SecureField(L10n.t("carry.password.field"), text: $password)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(submit)
        if setting {
            SecureField(L10n.t("carry.password.again"), text: $again)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
        }
    }

    private var presses: some View {
        ShellPressRow {
            Button(L10n.t("board.choose.cancel"), role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(L10n.t(setting ? "carry.password.set.go" : "carry.password.open.go"), action: submit)
                .tint(ShellChrome.selectInk(colorScheme))
                .disabled(!ready)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func submit() {
        guard ready else { return }
        onDone(password)
    }
}
