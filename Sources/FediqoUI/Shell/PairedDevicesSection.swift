import FediqoCore
import SwiftUI

/// The group on Preferences' Move tab that keeps this device's sources and timelines merged with
/// the devices it is paired with (D1, D6): a heading with its short line and (?), what is happening
/// beside three presses — show a pairing code, pair with one, Sync now — how often it runs, and
/// one row per paired device with when it last merged and Forget behind its `…`.
///
/// Everything pairing asks is on its own sheet (`SyncPairFlow`), hung on the pane as the move's is.
struct PairedDevicesSection: View {
    let sync: ShellSync
    /// The window this pane is on, which keeps a pairing begun here.
    let session: ShellSession?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ShellSpace.snug) {
                    line
                    Spacer(minLength: ShellSpace.snug)
                    presses
                }
                VStack(alignment: .leading, spacing: ShellSpace.snug) {
                    line
                    HStack(spacing: ShellSpace.snug) { presses }
                }
            }
            .padding(.vertical, ShellSpace.tight)
            @Bindable var sync = sync
            Picker(L10n.t("sync.period"), selection: $sync.period) {
                ForEach(SyncPeriod.allCases, id: \.self) { period in
                    Text(Self.periodLabel(period)).tag(period)
                }
            }
            ForEach(sync.paired) { device in
                PairedDeviceRow(device: device) { sync.forget(device) }
            }
        } header: {
            ShellSectionHead(title: "sync.title", line: "sync.line", help: "sync.help")
        }
    }

    @ViewBuilder
    private var presses: some View {
        Group {
            ShellIconButton("number", name: "sync.pair.hold", help: "sync.pair.hold.help") { sync.beginPairHold(from: session) }
            ShellIconButton("link", name: "sync.pair.join", help: "sync.pair.join.help") { sync.beginPairBrowse(from: session) }
        }
        .disabled(sync.pairStep != nil || sync.paired.count >= PairLimit.most)
        ShellIconButton("arrow.triangle.2.circlepath", name: "sync.now", help: "sync.now.help") { sync.syncNow() }
            .disabled(sync.lookingNow || sync.paired.isEmpty)
    }

    /// What is happening, or what the group does while nothing is.
    @ViewBuilder
    private var line: some View {
        let said = Self.status(sync)
        HStack(spacing: ShellSpace.snug) {
            if said.busy { ProgressView().controlSize(.small) }
            ShellStatusLine(said.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The status line's sentence, and whether something is under way: looking, the other device
    /// answering, a look refused or empty, the last merge, or what the period does.
    static func status(_ sync: ShellSync, language: DummyLanguage? = nil) -> (text: String, busy: Bool) {
        if sync.lookingNow { return (L10n.t("sync.status.looking", language: language), true) }
        if let peer = sync.waiting {
            return (String(format: L10n.t("sync.status.waiting", language: language), peer.name), true)
        }
        switch sync.looked {
        case .notAllowed?: return (L10n.t("sync.status.notAllowed", language: language), false)
        case .nobodyFound?: return (L10n.t("sync.status.nobody", language: language), false)
        case nil: break
        }
        if let told = sync.told { return (ShellSync.outcomeLine(told.outcome, peer: told.peer.name, language: language), false) }
        return (idle(paired: sync.paired.count, period: sync.period, language: language), false)
    }

    /// What the group does with nothing under way.
    static func idle(paired: Int, period: SyncPeriod, language: DummyLanguage? = nil) -> String {
        guard paired > 0 else { return L10n.t("sync.status.none", language: language) }
        switch period {
        case .never: return L10n.t("sync.status.never", language: language)
        case .tenMinutes: return L10n.t("sync.status.10m", language: language)
        case .hour: return L10n.t("sync.status.1h", language: language)
        case .sixHours: return L10n.t("sync.status.6h", language: language)
        }
    }

    /// A period as the picker names it.
    static func periodLabel(_ period: SyncPeriod, language: DummyLanguage? = nil) -> String {
        switch period {
        case .tenMinutes: L10n.t("sync.period.10m", language: language)
        case .hour: L10n.t("sync.period.1h", language: language)
        case .sixHours: L10n.t("sync.period.6h", language: language)
        case .never: L10n.t("sync.period.never", language: language)
        }
    }
}

/// One paired device: its name, when it last merged, and Forget behind `…`, asked first.
struct PairedDeviceRow: View {
    let device: PairedDevice
    let forget: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: ShellSpace.snug) {
            Image(systemName: "laptopcomputer.and.iphone")
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                Text(device.name)
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                ShellReadingLine(Self.merged(device))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            ShellMoreButton(Self.more(device, forget: forget))
        }
        .padding(.vertical, ShellSpace.tight)
        .shellMoreHeld()
    }

    /// "Last merged 5 minutes ago", or that the first merge has not happened yet.
    static func merged(_ device: PairedDevice, now: Date = Date(), language: DummyLanguage? = nil) -> String {
        guard device.firstMerged, let last = device.lastMerged else {
            return L10n.t("sync.row.notMerged", language: language)
        }
        let when = last.formatted(.relative(presentation: .named).locale(L10n.locale(language)))
        return String(format: L10n.t("sync.row.merged", language: language), when)
    }

    /// The row's `…`: Forget, destructive, asking first.
    static func more(_ device: PairedDevice, language: DummyLanguage? = nil, forget: @escaping () -> Void) -> ShellMore {
        ShellMore(items: [
            .danger(
                "xmark.circle", L10n.t("sync.forget", language: language),
                asks: ShellQuestion.forgetPaired(device.name, language: language), act: forget
            ),
        ])
    }
}

extension ShellQuestion {
    /// Forgetting a paired device: nothing merged changes, and merging stops.
    static func forgetPaired(_ name: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "xmark.circle", title: String(format: L10n.t("sync.forget.title", language: language), name),
            line: L10n.t("sync.forget.line", language: language),
            help: L10n.t("sync.forget.help", language: language),
            choices: [.init(yes, L10n.t("sync.forget", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }
}

/// Pairing, on the pane: one sheet up from the first press to the end, redrawn as each step lands
/// — the code, the list, the mark, the first merge, how it ended. **A modifier, and the only way
/// it is presented**, so the pane adds one line. Put away by any route, it stops what is running.
///
/// **On the window it began on** (`ShellSync.showsPairing`), whichever leads — the lead's once that
/// window closes: pairing is the run's, so a second window shows no second sheet, and closing one
/// never stops it for the other.
struct SyncPairFlow: ViewModifier {
    let sync: ShellSync?
    let session: ShellSession?

    func body(content: Content) -> some View {
        content.sheet(isPresented: shown) {
            if let sync { SyncPairSheet(sync: sync) }
        }
    }

    private var shown: Binding<Bool> {
        Binding(get: { shows }, set: { if !$0, shows { sync?.stopPairing() } })
    }

    private var shows: Bool {
        sync?.showsPairing(on: session) ?? false
    }
}

/// The pairing sheet: whatever step pairing is at.
struct SyncPairSheet: View {
    let sync: ShellSync

    @State private var code = ""
    @State private var picked: NearbyPeer?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 380

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                step
            }
            .padding(ShellSpace.room)
            .frame(maxWidth: measure, alignment: .leading)
        }
        .background(ShellChrome.page(colorScheme))
        .presentationSizing(.fitted)
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var step: some View {
        switch sync.pairStep {
        case .holding(let code, let mark)?: holding(code: code, mark: mark)
        case .browsing(let peers)?: browsing(peers)
        case .checkingMark(let peer, _, let mark)?: checking(peer: peer, mark: mark)
        case .running(let step)?: running(step)
        case .ended(let step)?: ended(step)
        case nil: EmptyView()
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .shellFont(.pane)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func said(_ text: String) -> some View {
        Text(text)
            .shellFont(.body)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Holding

    @ViewBuilder
    private func holding(code: String?, mark: String?) -> some View {
        title(L10n.t("sync.hold.title"))
        NearbyCodeDigits(code: code, shrinks: true)
        NearbyNameMark(name: sync.deviceName, mark: mark)
        said(String(format: L10n.t("sync.hold.line"), sync.deviceName))
            .shellHelp("sync.hold.help", about: L10n.t("sync.title"))
        presses {
            ProgressView().controlSize(.small)
            cancel
        }
    }

    // MARK: - Joining

    @ViewBuilder
    private func browsing(_ peers: [NearbyPeer]) -> some View {
        title(L10n.t("sync.join.title"))
        said(L10n.t("sync.join.line"))
            .shellHelp("sync.join.help", about: L10n.t("sync.title"))
        if peers.isEmpty {
            HStack(spacing: ShellSpace.snug) {
                ProgressView().controlSize(.small)
                ShellReadingLine(L10n.t("sync.join.looking"))
            }
        } else {
            VStack(spacing: ShellSpace.hair) {
                ForEach(peers) { peer in
                    ShellListRow(
                        id: peer, title: peer.name, brief: L10n.t("sync.join.row.brief"), leads: false,
                        selection: $picked, onOpen: { focused = true }
                    ) {
                        Image(systemName: "number")
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    } control: {
                        EmptyView()
                    }
                }
            }
            .onChange(of: peers) { _, now in
                if let picked, !now.contains(picked) { self.picked = nil }
            }
        }
        if picked != nil { NearbyCodeField(code: $code, focused: $focused, onSubmit: join) }
        presses {
            cancel
            Button(L10n.t("sync.join.go"), action: join)
                .tint(ShellChrome.selectInk(colorScheme))
                .disabled(picked == nil || !NearbyCode.isWellFormed(code))
        }
    }

    private func join() {
        guard let picked, NearbyCode.isWellFormed(code) else { return }
        sync.typed(code: code, for: picked)
    }

    /// The mark asked about in Move's own words (`ShellQuestion.nearbyMark`), the mark itself
    /// in the display size.
    @ViewBuilder
    private func checking(peer: NearbyPeer, mark: String) -> some View {
        let asked = ShellQuestion.nearbyMark(mark, peer: peer.name)
        title(asked.title)
        Text(mark)
            .shellFont(.code)
            .monospacedDigit()
            .tracking(4)
            .foregroundStyle(ShellChrome.selectInk(colorScheme))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .accessibilityLabel(String(format: L10n.t("nearby.mark.spoken"), mark))
            .accessibilityValue(mark.map(String.init).joined(separator: " "))
        if let help = asked.help {
            said(asked.line).shellHelp(verbatim: help, about: L10n.t("sync.title"))
        } else {
            said(asked.line)
        }
        presses {
            if let different = asked.cancel {
                Button(different, role: .cancel) {
                    code = ""
                    sync.markMismatched()
                }
                .keyboardShortcut(.cancelAction)
            }
            ForEach(asked.choices) { same in
                Button(same.label) { sync.markMatched() }
                    .tint(ShellChrome.selectInk(colorScheme))
            }
        }
    }

    // MARK: - Paired, and the first merge

    @ViewBuilder
    private func running(_ step: ShellSync.PairStep.Running) -> some View {
        if let ask = sync.asking {
            SyncPreviewCard(ask: ask) { sync.answer($0) }
        } else {
            title(L10n.t("sync.hold.title"))
            HStack(spacing: ShellSpace.snug) {
                ProgressView().controlSize(.small)
                ShellStatusLine(Self.runningLine(step))
                    .fixedSize(horizontal: false, vertical: true)
            }
            presses { cancel }
        }
    }

    /// What a running pairing is doing.
    static func runningLine(_ step: ShellSync.PairStep.Running, language: DummyLanguage? = nil) -> String {
        switch step {
        case .connecting: L10n.t("sync.pairing.connecting", language: language)
        case .paired(let peer): String(format: L10n.t("sync.pairing.paired", language: language), peer.name)
        case .merging(let peer): String(format: L10n.t("sync.pairing.merging", language: language), peer.name)
        case .waiting(let peer): String(format: L10n.t("sync.status.waiting", language: language), peer.name)
        }
    }

    @ViewBuilder
    private func ended(_ step: ShellSync.PairStep.Ended) -> some View {
        let said = Self.endedWords(step)
        title(said.title)
        self.said(said.line)
        presses {
            Button(L10n.t("sync.pairing.done")) { sync.stopPairing() }
                .keyboardShortcut(.defaultAction)
                .tint(ShellChrome.selectInk(colorScheme))
        }
    }

    /// How a pairing ended: paired and what the first merge came to, this very device, or why not.
    static func endedWords(_ step: ShellSync.PairStep.Ended, language: DummyLanguage? = nil) -> (title: String, line: String) {
        switch step {
        case .done(let peer, let outcome):
            (String(format: L10n.t("sync.pairing.paired", language: language), peer.name),
             ShellSync.outcomeLine(outcome, peer: peer.name, language: language))
        case .sameDevice:
            (L10n.t("sync.pairing.same.title", language: language), L10n.t("sync.pairing.same.line", language: language))
        case .refused(let refusal):
            refused(ShellQuestion.nearbyRefused(refusal, language: language))
        }
    }

    private static func refused(_ said: ShellConfirmation) -> (title: String, line: String) {
        (said.title, said.line)
    }

    // MARK: - Presses

    private var cancel: some View {
        Button(L10n.t("board.choose.cancel"), role: .cancel) { sync.stopPairing() }
            .keyboardShortcut(.cancelAction)
    }

    private func presses<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ShellPressRow { content() }
            .onePressLine()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .buttonStyle(.bordered)
            .controlSize(.large)
    }
}
