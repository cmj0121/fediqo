import FediqoCore
import SwiftUI

/// The Admin place (#416): the list of the hosts the person answers for, and — one of them
/// pressed — that host's page, which takes the whole place, with a tab for each task its
/// standing allows (`TendingPane`).
///
///     Admin
///     The servers you answer for
///     ─────────────────────────────────────────────────────────────────────
///     ◈ m.example                                 [! 2]  [person.badge.clock 3]
///       ! ◷ ◎ ✋ ▥ ↗ ≡                       each a tab its standing allows
///     ─────────────────────────────────────────────────────────────────────
///     ◈ n.example
///       ⚿ This sign-in was not asked to tend the server. Update permission
///
/// **The list comes first, even of one host**: the place is predictable, and a host is one press
/// away. **Its figures and its standing are icons that open their tab**, and each host reads its
/// own figures as its row is drawn. **It is handed everything it draws but the stores**: the
/// root holds where the person stands (`AdminFront`), and every act goes through `ShellTending`.
struct AdminPane: View {
    let session: ShellSession
    let tending: ShellTending
    @Binding var front: AdminFront
    /// Whether `r` asks again here, and what the page's bar mark does.
    var canReload: Bool
    var onReload: () -> Void = {}
    /// Somebody a row names, opened: a page drawn in the timeline place, come back from by leaving it.
    var onOpenPerson: (DummyPerson) -> Void = { _ in }
    /// A server's own page — a report's, the rules' — through the door a post's link goes through.
    var onOpenServerPage: (URL, String) -> Void = { _, _ in }
    /// The page's Back: the list again.
    var onBack: () -> Void = {}

    var body: some View {
        if let page = front.shown(in: session) {
            hostPage(page)
        } else {
            AdminHostsList(
                rows: AdminHostsList.said(in: session, tending: tending),
                lamp: $front.lamp,
                jump: front.jump,
                onOpen: { host, tab in _ = front.open(host, on: tab, in: session) },
                tending: tending,
                session: session
            )
        }
    }

    /// One host's page: the whole place, in the frame every opened page stands in. Its bar's mark
    /// asks again where `r` would, and is Stop while the server is asked.
    private func hostPage(_ page: Tending) -> some View {
        let people = tending.people
        let askWords = { _ = session.askFor([.tending], host: page.host) }
        let asked = tending.ask(of: page)
        return TendingPane(
            page: page,
            tabs: ShellTending.tabs(at: page.host, in: session),
            reports: page.tab == .reports ? tending.said(of: page, in: session) : nil,
            people: page.tab == .people ? people.said(of: page, in: session) : nil,
            servers: page.tab == .federation || page.tab == .blocks ? tending.servers.said(of: page, in: session) : nil,
            server: [.dashboard, .rising, .rules].contains(page.tab) ? tending.server.said(of: page, in: session) : nil,
            counts: tending.counts(of: page, in: session),
            acts: ShellTending.acts(at: page.host, in: session),
            reload: TendingPane.reloadName(page.host, canReload: canReload),
            slide: session.slide("tending"),
            frame: OpenedPageActs(
                onBack: onBack,
                onTab: { tab in front.turn(to: tab, tending: tending, in: session) },
                onReload: onReload,
                onPull: { await tending.again(page, in: session) },
                onStop: asked.stoppable ? { tending.stop(page) } : nil
            ),
            onReport: TendingReportActs(
                onAct: { act, report in Task { await tending.act(act, on: report.id, of: page, in: session) } },
                onAskWords: askWords,
                onOpenPage: { report in
                    if let url = ShellTending.page(of: report, host: page.host) { onOpenServerPage(url, page.host) }
                },
                onActOnAccount: ShellTendingPeople.actsOn(at: page.host, in: session) ? { report in
                    guard let target = report.target else { return }
                    people.openAct(
                        on: target.accountID, handle: target.handle, local: target.livesHere, at: page.host, report: report.id,
                        in: session
                    )
                } : nil
            ),
            onPeople: TendingPeopleActs(
                onFind: { filter in Task { await people.find(filter, on: page, in: session) } },
                onLetIn: { account in Task { await people.letIn(account.id, of: page, in: session) } },
                onTurnAway: { account in Task { await people.turnAway(account.id, of: page, in: session) } },
                onUndo: { act, account in Task { await people.undo(act, on: account.id, of: page, in: session) } },
                onActOn: { account in
                    people.openAct(
                        on: account.id, handle: account.person?.handle ?? account.id, local: account.local, at: page.host, in: session
                    )
                },
                onAskWords: askWords
            ),
            onServers: TendingServersActs(
                onAdd: { list in tending.servers.open(TendingServersActs.kind(of: list), at: page.host, in: session) },
                onChange: { block in tending.servers.open(.block(block), at: page.host, in: session) },
                onRemove: { list, id in Task { await tending.servers.remove(list, id: id, on: page, in: session) } },
                onReadOn: { list in Task { await tending.servers.readOn(list, of: page, in: session) } },
                onAskWords: askWords
            ),
            onServer: TendingServerActs(
                onSpan: { days in Task { await tending.server.choose(days: days, on: page, in: session) } },
                onReview: { item, rise in Task { await tending.server.review(item, rise: rise, on: page, in: session) } },
                onReadOn: { kind in Task { await tending.server.readOn(kind, of: page, in: session) } },
                onOpenRules: { url in onOpenServerPage(url, page.host) },
                onAskWords: askWords
            ),
            onOpenPerson: onOpenPerson,
            onReadOn: { Task { await tending.readOn(page, pressed: true, in: session) } },
            onReachFoot: { Task { await tending.readOn(page, pressed: false, in: session) } },
            catalogues: session.emoji,
            posts: session.posts,
            selectedID: $front.lamp,
            jumpToTop: front.jump
        )
        .id(page.host)
        // **The ask is the tab coming in front**, once a run; and again where who is signed in changes.
        .task(id: tending.opening(page, in: session)) { await tending.opened(page, in: session) }
        // **And the head's figures, as the page opens**: the open reports and those waiting, once.
        .task(id: tending.opening(Tending(host: page.host, tab: .reports), in: session)) { await tending.headOpened(page, in: session) }
        // What the tab in front asks, its wait, miss and stop at the foot, as every page's.
        .modifier(ReloadToast(toast: TimelineToast.asked(asked, note: nil)))
    }
}

/// The list of the hosts the person answers for: one row a host, in the order the sources stand,
/// the lamp on one of them.
struct AdminHostsList: View {
    /// One host's row, as it is handed.
    struct Row: Equatable, Identifiable {
        enum Standing: Equatable {
            /// Its page opens: the tabs its standing allows, as far as each figure has been read,
            /// and whether the sign-in may act or only read.
            case open(tabs: [AdminTab], counts: [TendingCount], acts: Bool)
            /// The standing is there and the sign-in lacks tending's word that reads: that
            /// part's lock, whose press asks for it alone.
            case lock(PartWords.Place)
            /// The standing is remembered and cannot be read now — a look that could not be
            /// had: the host is listed, and opens nothing until it can be.
            case unknown
        }

        let host: String
        let standing: Standing
        var id: String { AdminFront.hostRow(host) }
    }

    let rows: [Row]
    @Binding var lamp: String?
    var jump: Int
    var onOpen: (String, AdminTab?) -> Void
    let tending: ShellTending
    let session: ShellSession

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellTouch) private var touch

    private static var top: String { "admin.top" }

    /// Every host's row as it stands for whoever is signed in there now.
    @MainActor
    static func said(in session: ShellSession, tending: ShellTending) -> [Row] {
        ShellTending.hosts(in: session).map { host in
            switch ShellTending.entry(at: host, in: session) {
            case .open(let page)?:
                Row(host: host, standing: .open(
                    tabs: ShellTending.tabs(at: host, in: session), counts: tending.counts(of: page, in: session),
                    acts: ShellTending.acts(at: host, in: session)
                ))
            case .lock(let place)?: Row(host: host, standing: .lock(place))
            case nil: Row(host: host, standing: .unknown)
            }
        }
    }

    /// What a listener is read of a row: the host, what its standing allows or the lock's line,
    /// and its figures.
    static func spoken(_ row: Row, language: DummyLanguage? = nil) -> String {
        let between = L10n.t("people.row.between", language: language)
        var parts = [row.host]
        switch row.standing {
        case .open(let tabs, let counts, let acts):
            parts.append(tabs.map { L10n.t($0.titleKey, language: language) }.joined(separator: ", "))
            parts += counts.map { $0.spoken(language: language) }
            if !acts { parts.append(L10n.t("shell.admin.readOnly", language: language)) }
        case .lock(let place):
            parts.append(String(format: L10n.t(place.key, language: language), row.host))
        case .unknown:
            parts.append(L10n.t("shell.admin.unknown", language: language))
        }
        return parts.joined(separator: between)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    head
                    ShellRule()
                    ForEach(rows) { row in
                        AdminHostRow(
                            row: row, selected: lamp == row.id,
                            onPress: { press(row) },
                            onTab: { tab in onOpen(row.host, tab) }
                        )
                        .id(row.id)
                        // **Each host reads its own figures as its row is drawn**: the open reports
                        // and those waiting, once a run, and again as who is signed in changes.
                        .task(id: tending.opening(Tending(host: row.host, tab: .reports), in: session)) {
                            guard case .open = row.standing else { return }
                            await tending.headOpened(Tending(host: row.host, tab: .reports), in: session)
                        }
                        ShellRule()
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onAppear {
                if let id = DummyCommand.centredOnAppear(selected: lamp) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: lamp) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jump) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(Self.top, anchor: .top) }
            }
        }
    }

    /// The place's name, and what it holds — as the Notices place names itself.
    private var head: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(ShellPlace.admin.title)
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t("shell.admin.line"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellSpace.pad)
        .padding(.top, ShellSpace.step)
        .padding(.bottom, ShellSpace.snug)
    }

    /// A row pressed: lit with a keyboard or a pointer and opened by a second press, or opened
    /// at once under a finger — as every row of the app is.
    private func press(_ row: Row) {
        switch DummyCommand.tapped(row.id, selected: lamp, touch: touch) {
        case .select: lamp = row.id
        case .open:
            lamp = row.id
            onOpen(row.host, nil)
        }
    }
}

/// One host on the Admin place's list: the host by name, its figures — each opening its tab —
/// and under it its standing as the icons of the tabs it allows, each opening that tab; or, where
/// the sign-in lacks the word that reads, the key and the line that asks for it.
struct AdminHostRow: View {
    let row: AdminHostsList.Row
    var selected = false
    var onPress: () -> Void
    var onTab: (AdminTab) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Label {
                    Text(verbatim: row.host)
                        .shellFont(.name)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: ShellPlace.admin.symbolName)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if case .open(_, let counts, _) = row.standing {
                    ForEach(counts) { count in
                        figure(count.tab, words: count.figure(), spoken: count.spoken())
                    }
                }
            }
            standing
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPress)
        .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(ShellChrome.phosphor(colorScheme)).frame(width: DummyItemRow.Box.lamp)
            }
        }
        // Read as one line, its figures and tabs each an act of its own.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AdminHostsList.spoken(row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onPress)
        .accessibilityActions {
            if case .open(let tabs, _, _) = row.standing {
                ForEach(tabs) { tab in
                    Button(L10n.t(tab.titleKey)) { onTab(tab) }
                }
            }
        }
    }

    @ViewBuilder
    private var standing: some View {
        switch row.standing {
        case .open(let tabs, _, let acts):
            HStack(spacing: ShellSpace.step) {
                ForEach(tabs) { tab in
                    figure(tab, words: nil, spoken: L10n.t(tab.titleKey))
                }
                if !acts {
                    Text(L10n.t("shell.admin.readOnly"))
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                }
            }
        case .lock(let place):
            Label(String(format: L10n.t(place.key), row.host), systemImage: SourceRow.permissionSymbol)
                .shellFont(.meta)
                .foregroundStyle(place.asks ? ShellChrome.ink(colorScheme) : ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            Text(L10n.t("shell.admin.unknown"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
    }

    /// A tab's icon — with its figure, where it counts something — a press that opens that tab.
    private func figure(_ tab: AdminTab, words: String?, spoken: String) -> some View {
        Button { onTab(tab) } label: {
            if let words {
                Label(words, systemImage: tab.symbol)
            } else {
                Image(systemName: tab.symbol)
            }
        }
        .shellFont(.meta)
        .foregroundStyle(ShellChrome.inkDim(colorScheme))
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(spoken)
        .help(spoken)
    }
}
