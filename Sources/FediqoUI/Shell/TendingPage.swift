import FediqoCore
import SwiftUI

/// Tending a server the reader answers for (#380), opened: a page of its own (F10), drawn in the
/// frame every opened page stands in (`OpenedPage`), with a tab for each task the reader's
/// standing there allows — Reports (#381) and People (#382).
///
///     ‹ Back                                                   ↻   Esc or q
///     ─────────────────────────────────────────────────────────────────────
///     Tending m.example                      [! 2]  [person.badge.clock 3]
///     What m.example keeps for those who answer for it, as far as …
///     ─────────────────────────────────────────────────────────────────────
///     (Reports)  (People)                          where the standing allows both
///     ─────────────────────────────────────────────────────────────────────
///     the tab in front: its rows, and the foot that reads on
///
/// **Its head's figures are icons that open their tab**: the open reports, and those waiting to
/// be let in, each as far as it has been read. **It is handed everything it draws** and asks
/// nothing: the asking and the acts are `ShellTending`'s, and it is drawn only where the standing
/// allows (`ShellTending.drawn`).
struct TendingPane: View {
    let page: Tending
    let tabs: [TendingTab]
    /// What the tab in front is handed: one of the two, by the tab.
    var reports: TendingReportsSaid?
    var people: TendingPeopleSaid?
    var servers: TendingServersSaid?
    /// The head's figures, each opening its tab.
    var counts: [TendingCount] = []
    /// Whether the sign-in holds tending's word that changes: said in the head where it does not.
    var acts = true
    var reload: String?
    var slide = PageSlide()
    var frame = OpenedPageActs<TendingTab>()
    var onReport = TendingReportActs()
    var onPeople = TendingPeopleActs()
    var onServers = TendingServersActs()
    var onOpenPerson: (DummyPerson) -> Void
    var onReadOn: () -> Void
    var onReachFoot: () -> Void
    let catalogues: EmojiCatalogueStore
    let posts: ForumPosts
    @Binding var selectedID: String?
    var jumpToTop: Int

    @State private var asked: ShellMoreAsk?

    var body: some View {
        OpenedPage(
            tabs: tabs, front: page.tab, slide: slide, reload: reload, acts: frame,
            head: {
                TendingHead(host: page.host, acts: acts, counts: counts, onTab: frame.onTab)
                ShellRule()
            },
            inFront: { lead in front(lead: lead) }
        )
        .modifier(ShellMoreAsks(asked: $asked))
    }

    @ViewBuilder
    private func front<Lead: View>(lead: Lead) -> some View {
        switch page.tab {
        case .reports:
            if let reports {
                TendingReportsList(
                    said: reports, acts: onReport, onOpenPerson: onOpenPerson, onReadOn: onReadOn, onReachFoot: onReachFoot,
                    catalogues: catalogues, posts: posts, selectedID: $selectedID, asked: $asked, jumpToTop: jumpToTop
                ) { lead }
            }
        case .people:
            if let people {
                TendingPeopleList(
                    said: people, acts: onPeople, onOpenPerson: onOpenPerson, onReadOn: onReadOn, onReachFoot: onReachFoot,
                    selectedID: $selectedID, asked: $asked, jumpToTop: jumpToTop
                ) { lead }
            }
        case .servers:
            if let servers {
                TendingServersList(said: servers, acts: onServers, selectedID: $selectedID, asked: $asked, jumpToTop: jumpToTop) { lead }
            }
        }
    }

    /// What the bar's mark is called, where `r` may ask.
    static func reloadName(_ host: String, canReload: Bool, language: DummyLanguage? = nil) -> String? {
        canReload ? PersonPage.reloadName(host, language: language) : nil
    }
}

/// What a report's `…` presses, each answered by the page's owner.
struct TendingReportActs {
    var onAct: (ReportAct, AdminReport) -> Void = { _, _ in }
    /// Tending's lock pressed, where the sign-in may not act: the words that act, asked alone.
    var onAskWords: () -> Void = {}
    /// The report's own page on the server: a note.
    var onOpenPage: (AdminReport) -> Void = { _ in }
    /// The sheet of an act on the account the report names (#382), where the reader may act.
    var onActOnAccount: ((AdminReport) -> Void)?
}

/// One of the head's figures: how many a tab holds, as far as it has been read, opening it.
struct TendingCount: Equatable, Identifiable {
    let tab: TendingTab
    let count: Int
    /// Whether the server named more than were read.
    let more: Bool

    var id: TendingTab { tab }

    /// The figure drawn: the count, and "+" where more were named.
    func figure(language: DummyLanguage? = nil) -> String {
        L10n.grouped(count, language: language) + (more ? "+" : "")
    }

    /// What a listener is read: the figure in words, and what it counts.
    func spoken(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("tend.count.\(tab.rawValue)", language: language), figure(language: language))
    }
}

/// The head of tending a server: whose it is, what the page is, its figures — each a press that
/// opens its tab — and, where the sign-in holds only the word that reads, that nothing here can
/// be acted on.
struct TendingHead: View {
    let host: String
    let acts: Bool
    var counts: [TendingCount] = []
    var onTab: (TendingTab) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    static func spoken(_ host: String, acts: Bool, language: DummyLanguage? = nil) -> String {
        [
            String(format: L10n.t("tend.title", language: language), host),
            String(format: L10n.t("tend.line", language: language), host),
            acts ? nil : L10n.t("tend.readOnly", language: language),
        ].compactMap { $0 }.joined(separator: L10n.t("people.row.between", language: language))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Text(String(format: L10n.t("tend.title"), host))
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                ForEach(counts) { count in
                    Button { onTab(count.tab) } label: {
                        Label(count.figure(), systemImage: count.tab.symbol)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel(count.spoken())
                    .help(count.spoken())
                }
            }
            Text(String(format: L10n.t("tend.line"), host))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if !acts {
                Text(L10n.t("tend.readOnly"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
    }
}

/// The reports, as the list under the head: open ones first, each row its report, the sentence
/// where there are none, and the foot that reads on.
struct TendingReportsList<Lead: View>: View {
    let said: TendingReportsSaid
    let acts: TendingReportActs
    var onOpenPerson: (DummyPerson) -> Void
    var onReadOn: () -> Void
    var onReachFoot: () -> Void
    let catalogues: EmojiCatalogueStore
    let posts: ForumPosts
    @Binding var selectedID: String?
    @Binding var asked: ShellMoreAsk?
    var jumpToTop: Int
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellTouch) private var touch

    private static var top: String { "tending.top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    ForEach(Array(said.reports.enumerated()), id: \.element.id) { index, report in
                        row(report)
                            .id(TendingReportsSaid.rowID(report.id))
                        if index < said.reports.count - 1 { ShellRule() }
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
                            symbol: foot.symbol, words: TendingReportsSaid.footWords(foot, host: said.host), presses: foot.presses,
                            onPress: onReadOn
                        )
                            .onAppear { if foot.presses { onReachFoot() } }
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

    private func row(_ report: AdminReport) -> some View {
        let id = TendingReportsSaid.rowID(report.id)
        return ReportRowView(
            report: report,
            host: said.host,
            selected: selectedID == id,
            menu: NoticeRow.Menu(
                more: {
                    ReportRowView.more(
                        report, host: said.host, acts: said.acts, acting: said.acting.contains(report.id), lock: said.lock,
                        onAct: acts.onAct, onAskWords: acts.onAskWords, onOpenPage: acts.onOpenPage,
                        onActOnAccount: acts.onActOnAccount
                    )
                },
                asks: $asked
            ),
            onPress: {
                switch DummyCommand.tapped(id, selected: selectedID, touch: touch) {
                case .select, .open: selectedID = id
                }
            },
            onOpenPerson: onOpenPerson,
            catalogues: catalogues,
            posts: posts
        )
    }
}

/// One report: whether it is open, what it is about and when; whom it is about and who said it;
/// what they wrote and the rules they named; and the posts it names, each drawn as a post's
/// row. **Every word of it is drawn as text** — a stranger's words through the reporter.
struct ReportRowView: View {
    let report: AdminReport
    let host: String
    var selected = false
    var menu: NoticeRow.Menu?
    var onPress: (() -> Void)?
    var onOpenPerson: (DummyPerson) -> Void = { _ in }
    let catalogues: EmojiCatalogueStore
    let posts: ForumPosts

    @Environment(\.colorScheme) private var colorScheme

    /// What `category` is called: the server's four words, and any other as the last.
    static func category(_ word: String, language: DummyLanguage? = nil) -> String {
        let known = ReportCategory(rawValue: word) ?? .other
        return L10n.t("tend.reports.category.\(known.rawValue)", language: language)
    }

    /// The line at the top: open or closed, what it is about, and who has taken it on.
    static func state(_ report: AdminReport, language: DummyLanguage? = nil) -> String {
        [
            L10n.t(report.closed ? "tend.reports.closed" : "tend.reports.open", language: language),
            category(report.category, language: language),
            report.takenBy.map { String(format: L10n.t("tend.reports.takenBy", language: language), LineText.oneLine($0)) },
            report.forwarded ? L10n.t("tend.reports.forwarded", language: language) : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whom it is about, and who said it.
    static func who(_ report: AdminReport, language: DummyLanguage? = nil) -> String {
        [
            report.target.map { String(format: L10n.t("tend.reports.about", language: language), LineText.oneLine($0.handle)) },
            report.reporter.map { String(format: L10n.t("tend.reports.by", language: language), LineText.oneLine($0.handle)) }
                ?? L10n.t("tend.reports.byServer", language: language),
        ].compactMap { $0 }.joined(separator: " — ")
    }

    /// What a listener is read of the row: all of it, in the order it is drawn, the posts counted.
    static func spoken(_ report: AdminReport, language: DummyLanguage? = nil) -> String {
        [
            state(report, language: language), who(report, language: language),
            report.words.isEmpty ? nil : report.words,
            report.rules.isEmpty ? nil : String(format: L10n.t("tend.reports.rules", language: language), report.rules.joined(separator: "; ")),
            report.posts.isEmpty ? nil : String(format: L10n.t("tend.reports.posts", language: language), L10n.grouped(report.posts.count, language: language)),
        ].compactMap { $0 }.joined(separator: L10n.t("people.row.between", language: language))
    }

    /// The row's `…`: take it on or hand it back, close it or open it again — each the server's
    /// own act, taking nothing from anybody — and the report's own page on the server, where a
    /// note is written and the account acted on. **Where the sign-in may not act** the acts are
    /// not offered: tending's lock stands in their place, whose press asks for the words that
    /// act, alone — or, where they may not be asked for, the acts are dim for good. While one act
    /// is on the wire, every act is dim for now.
    @MainActor
    static func more(
        _ report: AdminReport, host: String, acts: Bool, acting: Bool, lock: PartWords.Place? = nil,
        onAct: @escaping (ReportAct, AdminReport) -> Void, onAskWords: @escaping () -> Void = {},
        onOpenPage: @escaping (AdminReport) -> Void, onActOnAccount: ((AdminReport) -> Void)? = nil,
        language: DummyLanguage? = nil
    ) -> ShellMore {
        let page = ShellMoreItem.plain("safari", String(format: L10n.t("tend.act.page", language: language), host)) { onOpenPage(report) }
        // The account it names acted on from the report itself (#382), where the reader may.
        let account = onActOnAccount.flatMap { onActOnAccount in
            report.target.map { target in
                ShellMoreItem.plain(
                    "person.crop.circle.badge.exclamationmark",
                    String(format: L10n.t("tend.act.account", language: language), LineText.oneLine(target.handle))
                ) { onActOnAccount(report) }
            }
        }
        if !acts, let lock, lock.asks {
            let line = String(format: L10n.t(lock.key, language: language), host)
            return ShellMore(items: [.plain(ShellMark(SourceRow.permissionSymbol, line, look: .live), act: onAskWords), page])
        }
        let look: MarkLook = !acts ? .dim(.never) : acting ? .dim(.notNow) : .live
        func item(_ act: ReportAct, _ symbol: String) -> ShellMoreItem {
            ShellMoreItem.plain(
                ShellMark(symbol, L10n.t("tend.act.\(String(describing: act))", language: language), look: look),
                act: { onAct(act, report) }
            )
            // Dim for good, in the menu's own words: this sign-in reads and does not act.
            .because(acts ? nil : L10n.t("tend.readOnly", language: language))
        }
        var items = [report.takenBy == nil ? item(.take, "person.badge.plus") : item(.handBack, "person.badge.minus")]
        items.append(report.closed ? item(.reopen, "arrow.uturn.backward.circle") : item(.close, "checkmark.circle"))
        if let account { items.append(account) }
        items.append(page)
        return ShellMore(items: items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    Text(Self.state(report))
                        .shellFont(.meta)
                        .foregroundStyle(report.closed ? ShellChrome.inkFaint(colorScheme) : ShellChrome.ink(colorScheme))
                    Text(Self.who(report))
                        .shellFont(.name)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if !report.words.isEmpty {
                        Text(verbatim: report.words)
                            .shellFont(.body)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !report.rules.isEmpty {
                        Text(String(format: L10n.t("tend.reports.rules"), report.rules.joined(separator: "; ")))
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let menu {
                    ShellMoreButton(label: L10n.t("tend.more.label"), asks: menu.asks, more: menu.more)
                        .fixedSize()
                }
            }
            .padding(.horizontal, ShellSpace.pad)
            .contentShape(Rectangle())
            .onTapGesture { onPress?() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(report))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityActions {
                if let menu { NoticeMenuActions(more: menu.more, asks: menu.asks) }
            }
            // Its panel under a long press, and on a Mac the pointer's other button, as every row's.
            .modifier(NoticeRowMenu(menu: menu, label: L10n.t("tend.more.label")))
            if let target = report.target {
                Button { onOpenPerson(DummyPerson(target)) } label: {
                    Label(String(format: L10n.t("tend.reports.about"), LineText.oneLine(target.handle)), systemImage: "person.crop.circle")
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, ShellSpace.pad)
            }
            ForEach(postItems, id: \.id) { item in
                DummyItemRow(item: item, catalogues: catalogues, posts: posts, onOpenPerson: onOpenPerson)
            }
        }
        .padding(.vertical, ShellSpace.step)
        .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(ShellChrome.phosphor(colorScheme)).frame(width: DummyItemRow.Box.lamp)
            }
        }
    }

    /// The posts it names, each as a post's row of its own — drawn from the report, never held.
    private var postItems: [DummyItem] {
        let targets = ReblogTargets(report.posts + report.carried)
        return report.posts.map { DummyItem($0, among: targets) }
    }
}
