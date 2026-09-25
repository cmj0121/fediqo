import FediqoCore
import SwiftUI

/// The group on Preferences that moves what this device holds to a device nearby, or holds what
/// one sends (#253, #6): a heading with its short line and (?), two icon presses, and — while a
/// move runs — how far it has come, with the code and the other device's name beside it, so both
/// screens say the same thing. Everything asked is asked by `NearbyFlow`, on the pane.
///
/// Drawn only where the shell handed the session a carrier and a link: a preview or a test
/// without them draws nothing, and does not offer a press that could do nothing.
struct NearbySection: View {
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let carrier = session.carrier, let link = session.nearbyLink {
            Section {
                HStack(spacing: ShellSpace.snug) {
                    line
                    Spacer(minLength: ShellSpace.snug)
                    ShellIconButton("antenna.radiowaves.left.and.right", name: "nearby.hold", help: "nearby.hold.help") {
                        session.nearby.beginHold(
                            with: carrier, link: link, device: session.deviceName, pictures: session.pictures.disk
                        ) { await session.adoptReadBack(prefs: prefs) }
                    }
                    ShellIconButton("paperplane", name: "nearby.offer", help: "nearby.offer.help") {
                        session.nearby.beginOffer(with: carrier, link: link)
                    }
                }
                .disabled(session.nearby.isUp || session.carry.isUp)
                .padding(.vertical, ShellSpace.tight)
            } header: {
                ShellSectionHead(title: "nearby.title", line: "nearby.line", help: "nearby.help")
            }
        }
    }

    @Environment(DummyPrefs.self) private var prefs

    /// What is happening, or what the group is for while nothing is.
    @ViewBuilder
    private var line: some View {
        let nearby = session.nearby
        if let progress = Self.measured(nearby.step) {
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                ProgressView(value: progress.fraction)
                Text(Self.summaryLine(nearby.step, peer: nearby.peer ?? "", sending: nearby.side == .offering, since: nearby.since))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                code
            }
        } else if let key = Self.statusKey(nearby.step, side: nearby.side) {
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                HStack(spacing: ShellSpace.snug) {
                    ProgressView().controlSize(.small)
                    Text(String(format: L10n.t(key), nearby.peer ?? ""))
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
                code
            }
        } else {
            Text(L10n.t("nearby.idle"))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
    }

    /// The code both screens show while the two are joined.
    @ViewBuilder
    private var code: some View {
        if !session.nearby.code.isEmpty {
            Text(String(format: L10n.t("nearby.code.line"), NearbyCode.spaced(session.nearby.code)))
                .shellFont(.meta)
                .monospacedDigit()
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
    }

    /// The line a step that is not bytes on the wire says, with the peer's name to format in.
    /// The receiver proving what arrived says so of itself.
    static func statusKey(_ step: ShellNearby.Step?, side: ShellNearby.Side? = .offering) -> String? {
        switch step {
        case .settling where side == .holding: "nearby.stage.proving"
        case .packing: "nearby.packing"
        case .connecting: "nearby.connecting"
        case .waiting: "nearby.waiting"
        case .reconnecting: "nearby.reconnecting"
        case .settling: "nearby.settling"
        default: nil
        }
    }

    /// A step that is bytes whose fraction is known — on the wire, or the receiver's read back —
    /// drawn as a bar rather than a spinner.
    static func measured(_ step: ShellNearby.Step?) -> PackageProgress? {
        switch step {
        case .moving(let progress, _), .settling(let progress?, _): progress
        default: nil
        }
    }

    /// The row's line under its bar: "Moving to a tablet · 1.2 GB of 3.4 GB · …" on the wire,
    /// "Reading it back · 1.2 GB of 3.4 GB" once the receiver reads back.
    static func summaryLine(
        _ step: ShellNearby.Step?, peer: String, sending: Bool, since: Date?, now: Date = Date(),
        language: DummyLanguage? = nil
    ) -> String {
        switch step {
        case .settling(let progress?, _):
            let line = L10n.t("nearby.stage.reading", language: language)
            return amountLine(progress, since: nil, language: language).map { line + " · " + $0 } ?? line
        case .moving(let progress, _):
            return progressLine(progress, peer: peer, sending: sending, since: since, now: now, language: language)
        default:
            return ""
        }
    }

    /// "Moving to a laptop · 1.2 GB of 3.4 GB · about 2 minutes left" — the estimate plain, from
    /// the pace so far, and left out until there is a pace.
    static func progressLine(
        _ progress: PackageProgress, peer: String, sending: Bool, since: Date?, now: Date = Date(),
        language: DummyLanguage? = nil
    ) -> String {
        let line = String(format: L10n.t(sending ? "nearby.moving.to" : "nearby.moving.from", language: language), peer)
        guard let amount = amountLine(progress, since: since, now: now, language: language) else { return line }
        return line + " · " + amount
    }

    /// "1.2 GB of 3.4 GB · about 2 minutes left" — the bytes, and the estimate where `since`
    /// gives a pace; nothing until there is a total.
    static func amountLine(
        _ progress: PackageProgress, since: Date?, now: Date = Date(), language: DummyLanguage? = nil
    ) -> String? {
        guard progress.total > 0 else { return nil }
        var line = String(
            format: L10n.t("carry.progress", language: language),
            UsagePane.size(progress.done, language: language), UsagePane.size(progress.total, language: language)
        )
        if let left = estimate(progress, since: since, now: now) {
            line += " · " + left.text(language: language)
        }
        return line
    }

    /// How long is left, by the pace so far: nothing until a second has passed and a byte moved.
    enum Estimate: Equatable {
        case underAMinute
        case minutes(Int)

        func text(language: DummyLanguage? = nil) -> String {
            switch self {
            case .underAMinute: L10n.t("nearby.left.soon", language: language)
            case .minutes(let count): L10n.count("nearby.left.minutes", count, language: language)
            }
        }
    }

    static func estimate(_ progress: PackageProgress, since: Date?, now: Date) -> Estimate? {
        guard let since, progress.done > 0, progress.total > progress.done else { return nil }
        let elapsed = now.timeIntervalSince(since)
        guard elapsed >= 1 else { return nil }
        let rate = Double(progress.done) / elapsed
        let seconds = Double(progress.total - progress.done) / rate
        return seconds < 60 ? .underAMinute : .minutes(Int((seconds / 60).rounded(.up)))
    }
}

extension NearbyCode {
    /// Six digits as two groups of three, for reading aloud across a room.
    static func spaced(_ code: String) -> String {
        guard code.count == digits else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}

/// Everything the flow asks, on the pane: the questions (`ShellQuestion`), the receiver's code
/// sheet, the sender's pick sheet, and — on both devices, while the move runs — its progress
/// sheet. **A modifier, and the only way this is presented**, so the pane adds one line and the
/// presenters stay out of any long view chain.
///
/// **On the pane, not the root.** Every move begins from a press on the Move tab, and from then
/// on a sheet is up for the whole of it — the code, the list, a question, the progress — which
/// holds the window: the person cannot leave Preferences while it runs, so a presenter at the
/// root would show nothing more, and would split one flow's hand-offs (code → question →
/// progress → notice) across two presenters that could each be mid-animation at once.
struct NearbyFlow: ViewModifier {
    let session: ShellSession?

    func body(content: Content) -> some View {
        content
            .shellConfirm(asking, question: Self.question, onChoice: answer)
            .sheet(item: sheet) { sheet in
                switch sheet {
                case .hold(let code):
                    NearbyHoldSheet(
                        code: code, name: session?.deviceName ?? "", mark: session?.nearby.mark ?? "",
                        onCancel: { session?.nearby.dismiss() }
                    )
                case .pick:
                    if let session { NearbyPickSheet(session: session) }
                case .progress:
                    if let session { NearbyProgressSheet(session: session) }
                }
            }
    }

    /// Put away unanswered — Escape, Cancel, a swipe — is "not the same" for the mark question
    /// (back to the list, not out) and out for the rest; judged a turn later, as a yes clears
    /// this too (`ShellConfirmAnswer.putAway`). Judged on the question up, not the step: a
    /// clearing written back with no question up — the sheet let down after a yes moved the
    /// step on — puts nothing away, and never stops the move the yes began.
    var asking: Binding<ShellNearby.Step?> {
        Binding(get: { session?.nearby.asking }, set: {
            guard $0 == nil, let nearby = session?.nearby else { return }
            ShellConfirmAnswer.putAway(nearby.asking, now: { nearby.asking }) { asked in
                if case .checkingMark = asked { nearby.markMismatched() } else { nearby.dismiss() }
            }
        })
    }

    /// Put away by any route but a press on it: judged on the sheet up (`sheetPutAway`), so the
    /// progress sheet taken down by the system never stops a move.
    private var sheet: Binding<ShellNearby.Sheet?> {
        Binding(get: { session?.nearby.sheet }, set: { if $0 == nil { session?.nearby.sheetPutAway() } })
    }

    /// What the progress sheet says at the step up, or nothing where no move is running.
    static func progress(
        _ nearby: ShellNearby, now: Date = Date(), language: DummyLanguage? = nil
    ) -> ShellProgress? {
        guard let stage = ShellNearby.stage(nearby.step, side: nearby.side) else { return nil }
        let sending = nearby.side != .holding
        let peer = nearby.peer ?? L10n.t("nearby.unnamed", language: language)
        let amount: String? = switch nearby.step {
        case .packing(let progress), .settling(let progress?, _):
            NearbySection.amountLine(progress, since: nil, now: now, language: language)
        case .moving(let progress, _):
            NearbySection.amountLine(progress, since: nearby.since, now: now, language: language)
        default: nil
        }
        return ShellProgress(
            symbol: sending ? "paperplane" : "antenna.radiowaves.left.and.right",
            title: String(format: L10n.t(sending ? "nearby.moving.to" : "nearby.progress.from", language: language), peer),
            stage: L10n.t(stage.line, language: language),
            fraction: stage.fraction,
            amount: amount,
            code: nearby.code.isEmpty
                ? nil : String(format: L10n.t("nearby.code.line", language: language), NearbyCode.spaced(nearby.code)),
            canCancel: stage.canCancel,
            cancelHelp: "nearby.progress.stop.help"
        )
    }

    static func question(_ step: ShellNearby.Step) -> ShellConfirmation {
        switch step {
        case .checkingMark(let check): ShellQuestion.nearbyMark(check.mark, peer: check.peer.name)
        case .asking(let ask): ShellQuestion.nearbyAsk(ask)
        case .refused(let refusal): ShellQuestion.nearbyRefused(refusal)
        case .done(let summary, let peer): ShellQuestion.nearbyDone(summary, peer: peer)
        default: ShellQuestion.nearbyRefused(.lost)
        }
    }

    func answer(_ step: ShellNearby.Step, _ id: String) {
        guard let session else { return }
        switch step {
        case .checkingMark:
            guard id == ShellQuestion.yes, let carrier = session.carrier, let link = session.nearbyLink else {
                session.nearby.markMismatched()
                return
            }
            session.nearby.markMatched(with: carrier, link: link, device: session.deviceName) { await session.persist?() }
        case .asking: session.nearby.answer(id == ShellQuestion.yes)
        default: session.nearby.dismiss()
        }
    }
}

/// Either device's sheet while the move runs: `NearbyFlow.progress`, redrawn as each step lands,
/// and Cancel ending the move while it still may.
struct NearbyProgressSheet: View {
    let session: ShellSession

    var body: some View {
        if let progress = NearbyFlow.progress(session.nearby) {
            ShellProgressSheet(progress: progress) { session.nearby.dismiss() }
        }
    }
}

/// The receiver's sheet: the code, large enough to read across a room, and this device's name
/// under it, which is what the sender will see in its list. Nothing to press but Cancel.
struct NearbyHoldSheet: View {
    let code: String
    let name: String
    /// The session's mark, beside the code: the same four characters the sender sees beside
    /// this name, so two devices with one name are told apart before a code is typed.
    let mark: String
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            Text(L10n.t("nearby.hold.sheet.title"))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .accessibilityAddTraits(.isHeader)
            digits
            HStack(spacing: ShellSpace.snug) {
                Text(name)
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                if !mark.isEmpty {
                    Text(mark)
                        .shellFont(.meta)
                        .monospaced()
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .accessibilityLabel(String(format: L10n.t("nearby.mark.spoken"), mark))
                }
            }
            Text(L10n.t("nearby.hold.sheet.line"))
                .shellFont(.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .shellHelp("nearby.hold.sheet.help", about: L10n.t("nearby.title"))
            HStack(spacing: ShellSpace.snug) {
                ProgressView().controlSize(.small)
                ShellPressRow {
                    Button(L10n.t("board.choose.cancel"), role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(ShellSpace.room)
        .frame(maxWidth: measure)
        .background(ShellChrome.page(colorScheme))
        .presentationSizing(.fitted)
        .presentationDetents([.medium, .large])
    }

    /// The one thing on this sheet that is not quiet: six digits in the display size, spaced by
    /// three, in the lamp's ink.
    @ViewBuilder
    private var digits: some View {
        if code.isEmpty {
            ProgressView()
        } else {
            Text(NearbyCode.spaced(code))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .tracking(4)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                .accessibilityLabel(L10n.t("nearby.code.spoken"))
                .accessibilityValue(code.map(String.init).joined(separator: " "))
        }
    }
}

/// The sender's sheet: the devices nearby that are holding, one lit; the six digits that
/// device shows; what rides; and the press that goes. A refused look nearby is said as that.
struct NearbyPickSheet: View {
    let session: ShellSession

    @State private var code = ""
    @State private var rides = ShellNearby.Rides.withoutPictures
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            Text(L10n.t("nearby.pick.sheet.title"))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t("nearby.pick.sheet.line"))
                .shellFont(.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .shellHelp("nearby.pick.sheet.help", about: L10n.t("nearby.title"))
            list
            if session.nearby.picked != nil { fields }
            presses
        }
        .padding(ShellSpace.room)
        .frame(maxWidth: measure)
        .background(ShellChrome.page(colorScheme))
        .presentationSizing(.fitted)
        .presentationDetents([.medium, .large])
    }

    /// Whether what was typed may go: a device lit, and six digits.
    var ready: Bool { session.nearby.picked != nil && NearbyCode.isWellFormed(code) }

    @ViewBuilder
    private var list: some View {
        let peers = session.nearby.peers
        if peers.isEmpty {
            HStack(spacing: ShellSpace.snug) {
                ProgressView().controlSize(.small)
                Text(L10n.t("nearby.pick.looking"))
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
        } else {
            @Bindable var nearby = session.nearby
            VStack(spacing: ShellSpace.hair) {
                ForEach(peers) { peer in
                    ShellListRow(
                        id: peer, title: peer.name, brief: L10n.t("nearby.pick.row.brief"),
                        selection: $nearby.picked, onOpen: { focused = true }
                    ) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    } control: {
                        EmptyView()
                    }
                }
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            TextField(L10n.t("nearby.pick.code"), text: $code)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .focused($focused)
                .onSubmit(go)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: code) { _, typed in
                    let digits = typed.filter(\.isNumber).prefix(NearbyCode.digits)
                    if String(digits) != typed { code = String(digits) }
                }
            Picker(L10n.t("nearby.pick.rides"), selection: $rides) {
                ForEach(ShellNearby.Rides.allCases) { choice in
                    Text(Self.ridesLabel(choice, weight: session.nearby.weight)).tag(choice)
                }
            }
            .pickerStyle(.menu)
        }
    }

    /// "Everything, with pictures (1.3 GB)": each choice with what it would come to.
    static func ridesLabel(_ rides: ShellNearby.Rides, weight: PackageWeight?, language: DummyLanguage? = nil) -> String {
        let label = L10n.t("nearby.rides.\(rides.rawValue)", language: language)
        let bytes: Int? = switch rides {
        case .withPictures: weight?.withPictures
        case .withoutPictures: weight?.withoutPictures
        case .signInsOnly: nil
        }
        guard let bytes else { return label }
        return "\(label) (\(UsagePane.size(bytes, language: language)))"
    }

    private var presses: some View {
        ShellPressRow {
            Button(L10n.t("board.choose.cancel"), role: .cancel) { session.nearby.dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("nearby.pick.go"), action: go)
                .tint(ShellChrome.selectInk(colorScheme))
                .disabled(!ready)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func go() {
        guard ready else { return }
        session.nearby.offer(code: code, rides: rides)
    }
}
