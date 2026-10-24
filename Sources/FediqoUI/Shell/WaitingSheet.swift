import FediqoCore
import SwiftUI

/// The time to send (#333, X0 §2): a switch at the foot of the extras, and beside it while it is
/// on a date and a time from the first the source takes; under it, that the source holds the post
/// and this device does not. Dim with the lock's words where the sign-in lacks the writing part.
struct LaterControl: View {
    @Binding var at: Date?
    let slot: DraftControls.LaterSlot
    let host: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            if let locked = slot.locked {
                Label(L10n.t("compose.later"), systemImage: SourceRow.permissionSymbol)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.markDim(colorScheme))
                Text(locked)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if slot.optional {
                    Toggle(isOn: Binding(get: { at != nil }, set: { at = $0 ? LaterWords.start() : nil })) {
                        Label(L10n.t("compose.later"), systemImage: "clock")
                    }
                    .shellFont(.meta)
                    .accessibilityLabel(L10n.t("compose.later"))
                }
                if let chosen = at {
                    DatePicker(
                        L10n.t("compose.later.when"),
                        selection: Binding(get: { chosen }, set: { at = $0 }),
                        in: LaterWords.earliest()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .shellFont(.meta)
                    .accessibilityLabel(L10n.t("compose.later.when"))
                    Text(LaterWords.line(host: host))
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The list of what waits at one source, drawn (X0 §2): soonest first, each row its time, who may
/// read it, its first words and what it carries, with its `…` — and D2's pair under one band.
struct WaitingSheet: View {
    let said: WaitingSaid
    var onChange: (WaitingPost) -> Void
    var onMove: (WaitingPost) -> Void
    /// The press that asks before letting one go: the pair's band.
    var onWithdraw: (WaitingPost) -> Void
    /// Letting one go, at the yes of the `…` item's own question.
    var onWithdrawNow: (WaitingPost) -> Void
    var onReadOn: () -> Void
    var onAgain: () -> Void
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.t("waiting.title"))
                        .shellFont(.pane)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: ShellSpace.step)
                    Button(L10n.t("servers.close"), action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                Text(String(format: L10n.t("waiting.whose"), said.host))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(ShellSpace.room)
            ShellRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let locked = said.locked { quiet(locked, again: false) }
                    if let missed = said.missed {
                        Label(missed, systemImage: SaidStrip.symbol)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(ShellSpace.pad)
                    }
                    if let told = said.told { quiet(told, again: false) }
                    if let line = said.line() { quiet(line, again: said.reading == .failed) }
                    ForEach(said.rows) { post in
                        if !said.isNewOfPair(post) {
                            if let pair = said.pair(before: post) {
                                band(pair, old: post)
                            } else {
                                row(post)
                                ShellRule()
                            }
                        }
                    }
                    if let foot = said.foot() {
                        Button(action: said.more ? onReadOn : {}) {
                            Text(foot)
                                .shellFont(.meta)
                                .foregroundStyle(said.more ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkFaint(colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(!said.more)
                        .padding(ShellSpace.pad)
                    }
                }
            }
        }
        .background(ShellChrome.page(colorScheme))
        .frame(minWidth: 320, idealWidth: 420, minHeight: 320, idealHeight: 480)
    }

    /// One row's `…`: change it, move it, and — under the divider, asked first — don't send it.
    static func more(
        _ post: WaitingPost, host: String, change: @escaping (WaitingPost) -> Void, move: @escaping (WaitingPost) -> Void,
        withdraw: @escaping (WaitingPost) -> Void, language: DummyLanguage? = nil
    ) -> ShellMore {
        ShellMore(items: [
            .plain("pencil", L10n.t("waiting.change", language: language)) { change(post) },
            .plain("clock.arrow.circlepath", L10n.t("waiting.move", language: language)) { move(post) },
            .danger(
                "xmark.bin", L10n.t("waiting.withdraw", language: language),
                asks: ShellQuestion.withdrawWaiting(host: host, post: post, language: language)
            ) { withdraw(post) },
        ])
    }

    private func quiet(_ line: String, again: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(line)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if again { ShellLinkButton(L10n.t("person.retry"), action: onAgain).fixedSize() }
        }
        .padding(ShellSpace.pad)
    }

    /// D2's pair: one band in full ink over the two, saying why both wait, with the press that
    /// lets the one before go — a heading over its rows to VoiceOver.
    private func band(_ pair: ShellLater.Pair, old: WaitingPost) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Label(LaterWords.pair(pair), systemImage: SaidStrip.symbol)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if said.locked == nil {
                ShellLinkButton(L10n.t("waiting.pair.press")) { onWithdraw(old) }.fixedSize()
            }
            row(old, named: L10n.t("waiting.pair.old"))
            if let new = pair.new.flatMap({ id in said.rows.first { $0.id == id } }) {
                row(new, named: L10n.t("waiting.pair.new"))
            }
            ShellRule()
        }
        .padding(.top, ShellSpace.snug)
    }

    private func row(_ post: WaitingPost, named: String? = nil) -> some View {
        let busy = said.moving.contains(post.id) || said.changing.contains(post.id)
        let goes = said.moving.contains(post.id)
            ? L10n.t("waiting.move.moving")
            : said.changing.contains(post.id) ? L10n.t("waiting.changing")
            : String(format: L10n.t("waiting.goes"), LaterWords.when(post.at))
        return VStack(alignment: .leading, spacing: ShellSpace.hair) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Text([named, goes].compactMap { $0 }.joined(separator: " · "))
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                if let reach = LaterWords.reach(post) {
                    Text(reach).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
                Spacer(minLength: ShellSpace.step)
                if said.locked == nil, !busy {
                    ShellMoreButton(Self.more(post, host: said.host, change: onChange, move: onMove, withdraw: onWithdrawNow))
                        .fixedSize()
                }
            }
            Text(post.text)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(2)
            if let carries = LaterWords.carries(post) {
                Text(carries).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        }
        .padding(ShellSpace.pad)
        .contentShape(Rectangle())
        .onTapGesture { if said.locked == nil, !busy { onChange(post) } }
        .shellMoreHeld()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LaterWords.spoken(post))
        .accessibilityAction { if said.locked == nil, !busy { onChange(post) } }
        .accessibilityAction(named: Text(L10n.t("waiting.move"))) { onMove(post) }
        .accessibilityAction(named: Text(L10n.t("waiting.withdraw"))) { onWithdraw(post) }
    }
}

/// The small sheet that moves a waiting post: the time alone, from the first the source takes.
struct MoveSheet: View {
    @Binding var at: Date
    var onMove: () -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            Text(L10n.t("waiting.move.title"))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .accessibilityAddTraits(.isHeader)
            DatePicker(L10n.t("compose.later.when"), selection: $at, in: LaterWords.earliest()..., displayedComponents: [.date, .hourAndMinute])
                .shellFont(.meta)
            HStack {
                Spacer()
                Button(L10n.t("compose.cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.t("waiting.move.confirm"), action: onMove).keyboardShortcut(.defaultAction)
            }
        }
        .padding(ShellSpace.room)
        .background(ShellChrome.page(colorScheme))
        .frame(minWidth: 300, idealWidth: 360)
    }
}

/// The list put up and taken down, with its two questions: **in a modifier of its own**, never in
/// the root's chain of presenters (`test-before-push`).
struct LaterPresenter: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { session.later.open }, set: { if $0 == nil { session.later.close() } })) { _ in
            LaterSheetBody(session: session)
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
    }
}

/// The sheet's own body: the list, the move sheet over it, and the question before letting go.
private struct LaterSheetBody: View {
    let session: ShellSession

    var body: some View {
        @Bindable var later = session.later
        if let said = later.said(in: session) {
            WaitingSheet(
                said: said,
                onChange: { post in session.changes.startWaiting(post, host: said.host, in: session) },
                onMove: { post in
                    later.moveTo = max(post.at, LaterWords.earliest())
                    later.askingMove = post
                },
                onWithdraw: { later.askingWithdraw = $0 },
                onWithdrawNow: { later.withdraw($0, at: said.host, in: session) },
                onReadOn: { later.readOn(in: session) },
                onAgain: { later.again(in: session) },
                onClose: { later.close() }
            )
            .sheet(item: $later.askingMove) { post in
                MoveSheet(at: $later.moveTo, onMove: { later.move(post, to: later.moveTo, at: said.host, in: session) }, onCancel: { later.askingMove = nil })
            }
            .shellConfirm($later.askingWithdraw, question: { ShellQuestion.withdrawWaiting(host: said.host, post: $0) }) { post, _ in
                later.withdraw(post, at: said.host, in: session)
            }
        }
    }
}
