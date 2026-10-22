import FediqoCore
import SwiftUI

/// What the People tab presses, each answered by the page's owner.
struct TendingPeopleActs {
    /// The tab asked again for another state, or a name.
    var onFind: (AdminAccountFilter) -> Void = { _ in }
    var onLetIn: (AdminAccount) -> Void = { _ in }
    /// Reached only through the question its item puts.
    var onTurnAway: (AdminAccount) -> Void = { _ in }
    var onUndo: (AccountAct, AdminAccount) -> Void = { _, _ in }
    /// The sheet of an act on the account.
    var onActOn: (AdminAccount) -> Void = { _ in }
    /// Tending's lock pressed, where the sign-in may not act.
    var onAskWords: () -> Void = {}
}

/// The People tab (#382): the state asked for and a name to find, then the accounts — those
/// waiting first, as it opens — each with what only staff see of them and its `…`; the
/// sentence where there are none, and the foot that reads on. A row opens the person, as any
/// person's row does.
struct TendingPeopleList<Lead: View>: View {
    let said: TendingPeopleSaid
    let acts: TendingPeopleActs
    var onOpenPerson: (DummyPerson) -> Void
    var onReadOn: () -> Void
    var onReachFoot: () -> Void
    @Binding var selectedID: String?
    @Binding var asked: ShellMoreAsk?
    var jumpToTop: Int
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellTouch) private var touch
    @State private var words = ""

    private static var top: String { "tending.people.top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    finding
                    ShellRule()
                    ForEach(Array(said.accounts.enumerated()), id: \.element.id) { index, account in
                        row(account)
                            .id(TendingPeopleSaid.rowID(account.id))
                        if index < said.accounts.count - 1 { ShellRule() }
                    }
                    if let quiet = said.quiet {
                        Text(quiet)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(ShellSpace.pad)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let foot = said.foot {
                        ShellRule()
                        PersonFootRow(
                            symbol: foot.symbol, words: TendingPeopleSaid.footWords(foot, host: said.host), presses: foot.presses,
                            onPress: onReadOn
                        )
                        .onAppear { if foot.presses { onReachFoot() } }
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onAppear {
                words = said.filter.words
                if let id = DummyCommand.centredOnAppear(selected: selectedID) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(Self.top, anchor: .top) }
            }
        }
    }

    /// What is asked for: a state, and a name or an address; Return, or another state, asks.
    private var finding: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Picker(L10n.t("tend.people.state"), selection: Binding(
                get: { said.filter.state },
                set: { acts.onFind(AdminAccountFilter(state: $0, words: words)) }
            )) {
                ForEach(AdminAccountState.allCases, id: \.self) { state in
                    Text(TendingPeopleSaid.stateName(state)).tag(state)
                }
            }
            .pickerStyle(.menu)
            .shellFont(.reading)
            TextField(L10n.t("tend.people.find"), text: $words)
                .shellField(.alone)
                .shellFont(.reading)
                .onSubmit { acts.onFind(AdminAccountFilter(state: said.filter.state, words: words)) }
                .accessibilityLabel(L10n.t("tend.people.find"))
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
    }

    private func row(_ account: AdminAccount) -> some View {
        let id = TendingPeopleSaid.rowID(account.id)
        let menu = NoticeRow.Menu(
            more: {
                AccountRowView.more(
                    account, host: said.host, acts: said.acts, manages: said.manages, acting: said.acting.contains(account.id),
                    lock: said.lock, actions: acts
                )
            },
            asks: $asked
        )
        return AccountRowView(
            account: account, selected: selectedID == id, menu: menu,
            onPress: {
                switch DummyCommand.tapped(id, selected: selectedID, touch: touch) {
                case .select: selectedID = id
                case .open: if let person = account.person { onOpenPerson(DummyPerson(person)) }
                }
            },
            onOpen: account.person.map { person in { onOpenPerson(DummyPerson(person)) } }
        )
    }
}

extension TendingPeopleSaid {
    /// What a state is called, in the list's picker.
    static func stateName(_ state: AdminAccountState, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.people.state.\(state.rawValue)", language: language)
    }

    /// The states the server holds an account in, as words: waiting, frozen, limited, sensitive,
    /// suspended, its mail not confirmed — nothing for an account held in none.
    static func states(_ account: AdminAccount, language: DummyLanguage? = nil) -> [String] {
        [
            account.waiting ? "waiting" : nil, account.disabled ? "frozen" : nil, account.silenced ? "limited" : nil,
            account.sensitized ? "sensitive" : nil, account.suspended ? "suspended" : nil,
            account.local && !account.confirmed ? "unconfirmed" : nil,
        ].compactMap { $0 }.map { L10n.t("tend.people.is.\($0)", language: language) }
    }
}

/// One account: the person as any row of people draws them, and under them what only staff see
/// — the states it is held in, its mail, and what they wrote asking to join.
struct AccountRowView: View {
    let account: AdminAccount
    var selected = false
    var menu: NoticeRow.Menu?
    var onPress: (() -> Void)?
    var onOpen: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    /// The lines under the person: states, mail, and what they wrote.
    static func lines(_ account: AdminAccount, language: DummyLanguage? = nil) -> [String] {
        let states = TendingPeopleSaid.states(account, language: language)
        return [
            states.isEmpty ? nil : states.joined(separator: " · "),
            account.email,
            account.reason.isEmpty ? nil : String(format: L10n.t("tend.people.wrote", language: language), account.reason),
        ].compactMap { $0 }
    }

    /// The row's `…`. Somebody waiting is let in, or turned away — which asks first, since the
    /// server deletes their sign-up and it cannot be taken back. Anybody else is acted on, on a
    /// sheet of its own, and each state they are held in is taken back. Where the sign-in may not
    /// act, tending's lock stands in the acts' place.
    @MainActor
    static func more(
        _ account: AdminAccount, host: String, acts: Bool, manages: Bool, acting: Bool, lock: PartWords.Place?,
        actions: TendingPeopleActs, language: DummyLanguage? = nil
    ) -> ShellMore {
        if !acts, let lock, lock.asks {
            let line = String(format: L10n.t(lock.key, language: language), host)
            return ShellMore(items: [.plain(ShellMark(SourceRow.permissionSymbol, line, look: .live), act: actions.onAskWords)])
        }
        let look: MarkLook = !acts || !manages ? .dim(.never) : acting ? .dim(.notNow) : .live
        let why = acts ? nil : L10n.t("tend.readOnly", language: language)
        let handle = LineText.oneLine(account.person?.handle ?? account.id)
        if account.waiting {
            return ShellMore(items: [
                ShellMoreItem.plain(ShellMark("person.badge.plus", L10n.t("tend.people.letIn", language: language), look: look)) {
                    actions.onLetIn(account)
                }.because(why),
                ShellMoreItem.danger(
                    ShellMark("person.badge.minus", L10n.t("tend.people.turnAway", language: language), look: look),
                    asks: turnAwayQuestion(handle, host: host, language: language)
                ) { actions.onTurnAway(account) }.because(why),
            ])
        }
        var items = [
            ShellMoreItem.danger(
                "person.crop.circle.badge.exclamationmark", String(format: L10n.t("tend.act.account", language: language), handle),
                look: acts && !acting ? .live : look, sheet: { actions.onActOn(account) }
            ).because(why),
        ]
        for act in AccountAct.allCases where act.undoes && account.holds(act) {
            items.append(ShellMoreItem.plain(
                ShellMark("arrow.uturn.backward.circle", L10n.t("tend.undo.\(String(describing: act))", language: language), look: look)
            ) { actions.onUndo(act, account) }.because(why))
        }
        return ShellMore(items: items)
    }

    /// The question turning somebody away puts: in one line, that it cannot be taken back.
    static func turnAwayQuestion(_ handle: String, host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "person.badge.minus",
            title: String(format: L10n.t("tend.people.turnAway.title", language: language), handle),
            line: String(format: L10n.t("tend.people.turnAway.line", language: language), host),
            help: nil,
            choices: [.init("turnAway", L10n.t("tend.people.turnAway", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            if let person = account.person {
                PersonRow(person: person, selected: selected, onPress: onPress, onOpen: onOpen, menu: menu)
            } else {
                Text(verbatim: account.id)
                    .shellFont(.name)
                    .padding(.horizontal, ShellSpace.pad)
            }
            ForEach(Self.lines(account), id: \.self) { line in
                Text(verbatim: line)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ShellSpace.pad)
            }
        }
        .padding(.bottom, ShellSpace.snug)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The sheet

/// The sheet an act on an account is written on (#382): which act, the words the server sends
/// them, whether it tells them by mail; then Send. **A warning cannot be taken back, and says so
/// in one line before it is sent**; **suspending asks once more**, in red, before it is.
struct AccountActSheet: View {
    @Binding var ask: AccountActAsk
    var onSend: () -> Void
    var onConfirm: () -> Void
    var onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// The line under an act chosen: what it does, and — for a warning — that it cannot be taken back.
    static func line(_ act: AccountAct, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.act.line.\(String(describing: act))", language: language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                Text(String(format: L10n.t("tend.act.title"), ask.handle))
                    .shellFont(.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if ask.stage == .asking {
                    confirming
                } else {
                    writing
                }
            }
            .padding(ShellSpace.room)
        }
        .background(ShellChrome.page(colorScheme))
        .frame(minWidth: 340, idealWidth: 460, minHeight: 360, idealHeight: 560)
    }

    @ViewBuilder
    private var writing: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ForEach(ask.offered, id: \.self) { act in
                Button { ask.act = act } label: {
                    HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                        Image(systemName: ask.act == act ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(ask.act == act ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("tend.act.name.\(String(describing: act))"))
                                .foregroundStyle(act == .suspend ? ShellChrome.alarm(colorScheme) : ShellChrome.ink(colorScheme))
                            Text(Self.line(act))
                                .shellFont(.meta)
                                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .shellFont(.reading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(ask.act == act ? [.isSelected] : [])
            }
        }
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(L10n.t("tend.act.words"))
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            TextEditor(text: $ask.words)
                .shellFont(.body)
                .scrollContentBackground(.hidden)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: ShellRadius.field).stroke(ShellChrome.hairline(colorScheme)))
                .accessibilityLabel(L10n.t("tend.act.words"))
        }
        Toggle(L10n.t("tend.act.tell"), isOn: $ask.tell)
            .shellFont(.reading)
        if case .failed(let words) = ask.stage {
            Text(words)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.alarm(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: ShellSpace.snug) {
            Spacer(minLength: 0)
            Button(L10n.t("board.choose.cancel"), role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("tend.act.send.\(String(describing: ask.act))"), role: ask.act == .suspend ? .destructive : nil, action: onSend)
                .tint(ask.act == .suspend ? ShellChrome.alarm(colorScheme) : ShellChrome.selectInk(colorScheme))
                .disabled(ask.stage == .sending || ask.words.unicodeScalars.count > AccountActAsk.wordsLength)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// Suspending, asked once more: what it does, in one line, and the red yes.
    @ViewBuilder
    private var confirming: some View {
        Text(String(format: L10n.t("tend.act.suspend.ask"), ask.handle, ask.host))
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: ShellSpace.snug) {
            Spacer(minLength: 0)
            Button(L10n.t("board.choose.cancel"), role: .cancel) { ask.stage = .writing }
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("tend.act.send.suspend"), role: .destructive, action: onConfirm)
                .tint(ShellChrome.alarm(colorScheme))
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

/// The act's sheet put up and taken down: **in a modifier of its own**, never in the root's
/// chain of presenters.
struct AccountActSheetPresenter: ViewModifier {
    let people: ShellTendingPeople
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: shown) { _ in
            if people.asking != nil {
                AccountActSheet(
                    ask: Binding(get: { people.asking ?? AccountActAsk(host: "", accountID: "", handle: "", report: nil) },
                                 set: { if people.asking != nil { people.asking = $0 } }),
                    onSend: { Task { await people.sendAct(in: session) } },
                    onConfirm: { Task { await people.sendAct(in: session, confirmed: true) } },
                    onClose: { people.closeAct() }
                )
            }
        }
    }

    private var shown: Binding<AccountActAsk?> {
        Binding(get: { people.asking }, set: { if $0 == nil { people.closeAct() } })
    }
}
