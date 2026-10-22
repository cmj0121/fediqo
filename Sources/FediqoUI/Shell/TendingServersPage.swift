import FediqoCore
import SwiftUI

/// What the Servers tab presses, each answered by the page's owner.
struct TendingServersActs {
    /// A list's Add: its sheet.
    var onAdd: (ServerList) -> Void = { _ in }
    /// A server refused, changed on its sheet.
    var onChange: (ServerBlock) -> Void = { _ in }
    /// A row taken off — reached only through the question its item puts.
    var onRemove: (ServerList, String) -> Void = { _, _ in }
    /// A list's foot pressed: its next stretch.
    var onReadOn: (ServerList) -> Void = { _ in }
    /// Tending's lock pressed, where the sign-in may not change them.
    var onAskWords: () -> Void = {}

    /// What a list's Add opens a sheet for.
    static func kind(of list: ServerList) -> FederationAsk.Kind {
        switch list {
        case .blocks: .block(nil)
        case .allows: .allow
        case .mail: .mail
        case .addresses: .address
        }
    }
}

/// The Servers tab (#383): the servers this one refuses, then those it allows — where the role
/// answers for them — and the mail domains and address ranges it refuses to let sign up — where
/// it answers for those. Each list under its own head, with its Add; each row with what it is
/// refused and why, and its `…`; the sentence where a list is empty, and the foot that reads on.
///
///     Servers refused                                              + Add
///     suspended.example
///     Suspended · Said to all: Spam · Kept among staff: spam      …
///     ─────────────────────────────────────────────────────────────────
///     Servers allowed                                              + Add
///     allowed.example                                                 …
///
/// **It is handed everything it draws**: what each list holds and whether it may change them are
/// `ShellTendingServers`'.
struct TendingServersList<Lead: View>: View {
    let said: TendingServersSaid
    let acts: TendingServersActs
    @Binding var selectedID: String?
    @Binding var asked: ShellMoreAsk?
    var jumpToTop: Int
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellTouch) private var touch

    private static var top: String { "tending.servers.top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    if let blocks = said.blocks {
                        section(.blocks, blocks) { block in
                            row(.blocks, block.id, title: block.domain, lines: TendingServersSaid.lines(of: block),
                                more: TendingServersSaid.more(block, said: said, actions: acts))
                        }
                    }
                    if let allows = said.allows {
                        section(.allows, allows) { allow in
                            row(.allows, allow.id, title: allow.domain, lines: [],
                                more: TendingServersSaid.more(.allows, id: allow.id, name: allow.domain, said: said, actions: acts))
                        }
                    }
                    if let mail = said.mail {
                        section(.mail, mail) { domain in
                            row(.mail, domain.id, title: domain.domain, lines: [],
                                more: TendingServersSaid.more(.mail, id: domain.id, name: domain.domain, said: said, actions: acts))
                        }
                    }
                    if let addresses = said.addresses {
                        section(.addresses, addresses) { address in
                            row(.addresses, address.id, title: address.ip, lines: TendingServersSaid.lines(of: address),
                                more: TendingServersSaid.more(.addresses, id: address.id, name: address.ip, said: said, actions: acts))
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onAppear {
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

    /// One list: its head and Add, its rows, the sentence where it has none, and its foot.
    @ViewBuilder
    private func section<Item: Identifiable & Equatable, Row: View>(
        _ list: ServerList, _ shown: ServerListSaid<Item>, @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View where Item.ID == String {
        ShellRule()
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Text(TendingServersSaid.title(list))
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            add(list)
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
        ForEach(shown.items) { item in
            ShellRule()
            row(item)
                .id(TendingServersSaid.rowID(list, item.id))
        }
        if let quiet = shown.quiet {
            Text(quiet)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(ShellSpace.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if shown.more {
            ShellRule()
            PersonFootRow(
                symbol: PersonSaid.Foot.more.symbol, words: L10n.t("person.foot.more"), presses: true,
                onPress: { acts.onReadOn(list) }
            )
        }
    }

    /// A list's Add: where the sign-in may not change it, tending's lock in its place — or nothing.
    @ViewBuilder
    private func add(_ list: ServerList) -> some View {
        if said.acts {
            Button { acts.onAdd(list) } label: {
                Label(L10n.t("tend.servers.add"), systemImage: "plus")
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.selectInk(colorScheme))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(TendingServersSaid.addName(list))
            .help(TendingServersSaid.addName(list))
        } else if let lock = said.lock, lock.asks {
            Button(action: acts.onAskWords) {
                Label(String(format: L10n.t(lock.key), said.host), systemImage: SourceRow.permissionSymbol)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private func row(_ list: ServerList, _ itemID: String, title: String, lines: [String], more: ShellMore) -> some View {
        let id = TendingServersSaid.rowID(list, itemID)
        let menu = NoticeRow.Menu(more: { more }, asks: $asked)
        let selected = selectedID == id
        return HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(verbatim: title)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ShellMoreButton(label: L10n.t("tend.more.label"), asks: menu.asks, more: menu.more)
                .fixedSize()
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .contentShape(Rectangle())
        .onTapGesture {
            switch DummyCommand.tapped(id, selected: selectedID, touch: touch) {
            case .select, .open: selectedID = id
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title] + lines).joined(separator: L10n.t("people.row.between")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions { NoticeMenuActions(more: menu.more, asks: menu.asks) }
        .modifier(NoticeRowMenu(menu: menu, label: L10n.t("tend.more.label")))
        .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(ShellChrome.phosphor(colorScheme)).frame(width: DummyItemRow.Box.lamp)
            }
        }
    }
}

extension TendingServersSaid {
    /// What a list's head says.
    static func title(_ list: ServerList, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.servers.list.\(list.rawValue)", language: language)
    }

    /// What a list's Add is read as.
    static func addName(_ list: ServerList, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.servers.add.\(list.rawValue)", language: language)
    }

    static func severityName(_ severity: ServerSeverity, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.servers.severity.\(String(describing: severity))", language: language)
    }

    static func severityName(_ severity: AddressSeverity, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.servers.address.\(String(describing: severity))", language: language)
    }

    /// The lines under a server refused: how hard and what besides; why, as said to all; and why,
    /// as kept among those who answer for the server.
    static func lines(of block: ServerBlock, language: DummyLanguage? = nil) -> [String] {
        let how = [
            severityName(block.severity, language: language),
            block.rejectMedia ? L10n.t("tend.servers.rejectMedia", language: language) : nil,
            block.rejectReports ? L10n.t("tend.servers.rejectReports", language: language) : nil,
            block.obfuscate ? L10n.t("tend.servers.obfuscate", language: language) : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        return [
            how,
            block.publicWords.isEmpty ? nil : String(format: L10n.t("tend.servers.public", language: language), LineText.oneLine(block.publicWords)),
            block.privateWords.isEmpty ? nil : String(format: L10n.t("tend.servers.private", language: language), LineText.oneLine(block.privateWords)),
        ].compactMap { $0 }
    }

    /// The lines under a range refused: how hard, why, and until when.
    static func lines(of address: RefusedAddress, language: DummyLanguage? = nil) -> [String] {
        [
            severityName(address.severity, language: language),
            address.words.isEmpty ? nil : LineText.oneLine(address.words),
            address.until.map {
                String(format: L10n.t("tend.servers.until", language: language), $0.formatted(date: .abbreviated, time: .shortened))
            },
        ].compactMap { $0 }
    }

    /// A server refused's `…`: changed on its sheet, or taken off.
    @MainActor
    static func more(_ block: ServerBlock, said: Self, actions: TendingServersActs, language: DummyLanguage? = nil) -> ShellMore {
        if let locked = locked(said, actions: actions, language: language) { return locked }
        let look = look(.blocks, id: block.id, said: said)
        let change = ShellMoreItem.plain(ShellMark("slider.horizontal.3", L10n.t("tend.servers.change", language: language), look: look)) {
            actions.onChange(block)
        }.because(said.acts ? nil : L10n.t("tend.readOnly", language: language))
        return ShellMore(items: [change, remove(.blocks, id: block.id, name: block.domain, said: said, actions: actions, language: language)])
    }

    /// A row's `…`: taken off, after its question. Where the sign-in may not change it,
    /// tending's lock stands in its place, or the item is dim for good.
    @MainActor
    static func more(
        _ list: ServerList, id: String, name: String, said: Self, actions: TendingServersActs, language: DummyLanguage? = nil
    ) -> ShellMore {
        if let locked = locked(said, actions: actions, language: language) { return locked }
        return ShellMore(items: [remove(list, id: id, name: name, said: said, actions: actions, language: language)])
    }

    @MainActor
    private static func remove(
        _ list: ServerList, id: String, name: String, said: Self, actions: TendingServersActs, language: DummyLanguage?
    ) -> ShellMoreItem {
        ShellMoreItem.danger(
            ShellMark("minus.circle", L10n.t("tend.servers.remove", language: language), look: look(list, id: id, said: said)),
            asks: removeQuestion(list, name: name, host: said.host, language: language)
        ) { actions.onRemove(list, id) }
            .because(said.acts ? nil : L10n.t("tend.readOnly", language: language))
    }

    private static func look(_ list: ServerList, id: String, said: Self) -> MarkLook {
        !said.acts ? .dim(.never) : said.acting.contains(rowID(list, id)) ? .dim(.notNow) : .live
    }

    @MainActor
    private static func locked(_ said: Self, actions: TendingServersActs, language: DummyLanguage?) -> ShellMore? {
        guard !said.acts, let lock = said.lock, lock.asks else { return nil }
        let line = String(format: L10n.t(lock.key, language: language), said.host)
        return ShellMore(items: [.plain(ShellMark(SourceRow.permissionSymbol, line, look: .live), act: actions.onAskWords)])
    }

    /// The question taking a row off puts, in one line: what it lets back in — and, for a server
    /// allowed, that it cuts the server off from it.
    static func removeQuestion(_ list: ServerList, name: String, host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        let name = LineText.oneLine(name)
        return ShellConfirmation(
            symbol: "minus.circle",
            title: String(format: L10n.t("tend.servers.remove.title.\(list.rawValue)", language: language), name),
            line: String(format: L10n.t("tend.servers.remove.line.\(list.rawValue)", language: language), host, name),
            help: nil,
            choices: [.init("remove", L10n.t("tend.servers.remove", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }
}

// MARK: - The sheet

/// The sheet a change is written on (#383): a server refused — how hard, what besides, why — a
/// server allowed, a mail domain, or a range refused. **What cuts the server off from another asks
/// once more, in one line, in red, before it is sent.** A refusal stays on the sheet, in the
/// server's words.
struct FederationAskSheet: View {
    @Binding var ask: FederationAsk
    var onSend: () -> Void
    var onConfirm: () -> Void
    var onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// The sheet's head.
    static func title(_ ask: FederationAsk, language: DummyLanguage? = nil) -> String {
        if case .block(let held?) = ask.kind {
            return String(format: L10n.t("tend.servers.change.title", language: language), LineText.oneLine(held.domain))
        }
        return String(format: L10n.t("tend.servers.add.title.\(ask.list.rawValue)", language: language), ask.host)
    }

    /// The one line a change that cuts the server off says before it is sent.
    static func cutsOffLine(_ ask: FederationAsk, language: DummyLanguage? = nil) -> String {
        switch ask.kind {
        case .address:
            String(format: L10n.t("tend.servers.address.ask", language: language), LineText.oneLine(ask.ip), ask.host)
        default:
            String(format: L10n.t("tend.servers.suspend.ask", language: language), LineText.oneLine(ask.draft.domain), ask.host)
        }
    }

    /// The red yes of that question.
    static func cutsOffYes(_ ask: FederationAsk, language: DummyLanguage? = nil) -> String {
        if case .address = ask.kind { return L10n.t("tend.servers.refuse", language: language) }
        return L10n.t("tend.servers.suspend", language: language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                Text(Self.title(ask))
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
        switch ask.kind {
        case .block(let held):
            field(L10n.t("tend.servers.domain"), text: $ask.draft.domain)
                .disabled(held != nil)
            choices(ServerSeverity.allCases, chosen: $ask.draft.severity) { severity in
                (TendingServersSaid.severityName(severity), L10n.t("tend.servers.severity.line.\(String(describing: severity))"),
                 severity == .suspend)
            }
            Toggle(L10n.t("tend.servers.rejectMedia"), isOn: $ask.draft.rejectMedia).shellFont(.reading)
            Toggle(L10n.t("tend.servers.rejectReports"), isOn: $ask.draft.rejectReports).shellFont(.reading)
            Toggle(L10n.t("tend.servers.obfuscate"), isOn: $ask.draft.obfuscate).shellFont(.reading)
            words(L10n.t("tend.servers.publicWords"), text: $ask.draft.publicWords)
            words(L10n.t("tend.servers.privateWords"), text: $ask.draft.privateWords)
        case .allow, .mail:
            field(L10n.t(ask.kind == .mail ? "tend.servers.mailDomain" : "tend.servers.domain"), text: $ask.domain)
        case .address:
            field(L10n.t("tend.servers.ip"), text: $ask.ip)
            choices(AddressSeverity.allCases, chosen: $ask.addressSeverity) { severity in
                (TendingServersSaid.severityName(severity), nil, severity == .noAccess)
            }
            words(L10n.t("tend.servers.addressWords"), text: $ask.words)
        }
        // Why Send is dim, where what is written names nothing it can send.
        if let whyNot = ask.whyNot {
            Text(whyNot)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
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
            Button(L10n.t("tend.servers.send"), role: ask.cutsOff ? .destructive : nil, action: onSend)
                .tint(ask.cutsOff ? ShellChrome.alarm(colorScheme) : ShellChrome.selectInk(colorScheme))
                .disabled(ask.stage == .sending || !ask.sendable)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// Cutting the server off, asked once more: in one line, in red, and the red yes.
    @ViewBuilder
    private var confirming: some View {
        Text(Self.cutsOffLine(ask))
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.alarm(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: ShellSpace.snug) {
            Spacer(minLength: 0)
            Button(L10n.t("board.choose.cancel"), role: .cancel) { ask.stage = .writing }
                .keyboardShortcut(.cancelAction)
            Button(Self.cutsOffYes(ask), role: .destructive, action: onConfirm)
                .tint(ShellChrome.alarm(colorScheme))
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(label)
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            TextField(label, text: text)
                .shellField(.alone)
                .shellFont(.reading)
                .accessibilityLabel(label)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
        }
    }

    private func words(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(label)
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            TextEditor(text: text)
                .shellFont(.body)
                .scrollContentBackground(.hidden)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .frame(minHeight: 56)
                .overlay(RoundedRectangle(cornerRadius: ShellRadius.field).stroke(ShellChrome.hairline(colorScheme)))
                .accessibilityLabel(label)
            if text.wrappedValue.unicodeScalars.count > FederationAsk.wordsLength {
                Text(String(format: L10n.t("tend.servers.tooLong"), L10n.grouped(FederationAsk.wordsLength)))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.alarm(colorScheme))
            }
        }
    }

    /// One of several, chosen: each its name, a line under it where it has one, red where it cuts off.
    private func choices<Choice: Hashable>(
        _ all: [Choice], chosen: Binding<Choice>, said: @escaping (Choice) -> (name: String, line: String?, red: Bool)
    ) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ForEach(all, id: \.self) { choice in
                let words = said(choice)
                Button { chosen.wrappedValue = choice } label: {
                    HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                        Image(systemName: chosen.wrappedValue == choice ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(chosen.wrappedValue == choice ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(words.name)
                                .foregroundStyle(words.red ? ShellChrome.alarm(colorScheme) : ShellChrome.ink(colorScheme))
                            if let line = words.line {
                                Text(line)
                                    .shellFont(.meta)
                                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .shellFont(.reading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(chosen.wrappedValue == choice ? [.isSelected] : [])
            }
        }
    }
}

/// The change's sheet put up and taken down: **in a modifier of its own**, never in the root's
/// chain of presenters.
struct FederationAskSheetPresenter: ViewModifier {
    let servers: ShellTendingServers
    let session: ShellSession

    func body(content: Content) -> some View {
        content
            // A sheet that closed by itself, with nothing sent, says why.
            .onChange(of: servers.gone) { _, gone in
                guard let gone else { return }
                session.showToast(gone)
                servers.gone = nil
            }
            .sheet(item: shown) { _ in
                if let ask = servers.asking {
                    let page = Tending(host: ask.host, tab: .servers)
                    FederationAskSheet(
                        ask: Binding(get: { servers.asking ?? ask }, set: { if servers.asking != nil { servers.asking = $0 } }),
                        onSend: { Task { await servers.send(on: page, in: session) } },
                        onConfirm: { Task { await servers.send(on: page, in: session, confirmed: true) } },
                        onClose: { servers.close() }
                    )
                }
            }
    }

    private var shown: Binding<FederationAsk?> {
        Binding(get: { servers.asking }, set: { if $0 == nil { servers.close() } })
    }
}
