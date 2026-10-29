import FediqoCore
import SwiftUI

/// What the Dashboard, Trends and Rules tabs press, each answered by the page's owner.
struct TendingServerActs {
    /// Another span of the figures chosen, in days.
    var onSpan: (Int) -> Void = { _ in }
    /// One of what rises let rise — `true` — or kept back.
    var onReview: (RisingReview, Bool) -> Void = { _, _ in }
    /// A list of what rises pressed at its foot.
    var onReadOn: (RisingKind) -> Void = { _ in }
    /// The server's own page of its rules, where they are changed.
    var onOpenRules: (URL) -> Void = { _ in }
    /// Tending's lock pressed, where the sign-in may not review.
    var onAskWords: () -> Void = {}
}

/// The Dashboard, Trends and Rules tabs (#384, #416), one view drawing the part its tab was
/// handed: how the server is doing, as its own figures over a span the person
/// chooses and as of when it said them; what waits to rise on it — hashtags, links, posts — each
/// with whether it waits for review and its `…`; and its rules, in order, with the way to its
/// own page, where they are changed. A part the role does not answer for is not drawn.
///
///     How m.example is doing             (7 days | 30 days | 90 days)
///     Joined 51 · Active 49 · Reported 2
///     As m.example said it at 08:30
///     ─────────────────────────────────────────────────────────────────
///     Hashtags rising
///     #FediqoWaiting       Waiting for review · 12 people over 2 days   …
///     ─────────────────────────────────────────────────────────────────
///     Rules                                        Change on m.example’s page
///     1. Be kind — hint
struct TendingServerList<Lead: View>: View {
    let said: TendingServerSaid
    let acts: TendingServerActs
    var onOpenPerson: (DummyPerson) -> Void
    let catalogues: EmojiCatalogueStore
    let posts: ForumPosts
    @Binding var selectedID: String?
    @Binding var asked: ShellMoreAsk?
    var jumpToTop: Int
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellTouch) private var touch

    private static var top: String { "tending.server.top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    if let measures = said.measures { figures(measures) }
                    if let rising = said.rising {
                        ForEach(rising) { list in risingList(list) }
                    }
                    if let rules = said.rules { rulesList(rules) }
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

    // MARK: - Figures

    @ViewBuilder
    private func figures(_ measures: TendingServerSaid.Measures) -> some View {
        ShellRule()
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            head(String(format: L10n.t("tend.server.measures.title"), said.host))
            Picker(L10n.t("tend.server.measures.span"), selection: Binding(get: { measures.days }, set: { acts.onSpan($0) })) {
                ForEach(TendingServerSaid.spans, id: \.self) { days in
                    Text(TendingServerSaid.spanName(days)).tag(days)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.t("tend.server.measures.span"))
            if let figures = measures.said {
                ForEach(figures.measures) { measure in
                    Text(TendingServerSaid.figure(measure))
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(TendingServerSaid.asOf(figures, host: said.host))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quiet = measures.quiet { quietLine(quiet) }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
    }

    // MARK: - What rises

    @ViewBuilder
    private func risingList(_ list: TendingServerSaid.Rising) -> some View {
        ShellRule()
        head(TendingServerSaid.title(list.kind))
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
        ForEach(list.items) { item in
            ShellRule()
            risingRow(item)
                .id(TendingServerSaid.rowID(item.kind, item.id))
        }
        if let quiet = list.quiet {
            quietLine(quiet)
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.snug)
        }
        if list.more {
            ShellRule()
            PersonFootRow(
                symbol: PersonSaid.Foot.more.symbol, words: L10n.t("person.foot.more"), presses: true,
                onPress: { acts.onReadOn(list.kind) }
            )
        }
    }

    private func risingRow(_ item: RisingReview) -> some View {
        let id = TendingServerSaid.rowID(item.kind, item.id)
        let menu = NoticeRow.Menu(more: { TendingServerSaid.more(item, said: said, actions: acts) }, asks: $asked)
        let selected = selectedID == id
        let lines = TendingServerSaid.lines(item)
        return VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: line)
                            .shellFont(index == 0 ? .reading : .meta)
                            .foregroundStyle(index == 0 ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ShellMoreButton(label: L10n.t("tend.more.label"), asks: menu.asks, more: menu.more)
                    .fixedSize()
            }
            .padding(.horizontal, ShellSpace.pad)
            .contentShape(Rectangle())
            .onTapGesture {
                switch DummyCommand.tapped(id, selected: selectedID, touch: touch) {
                case .select, .open: selectedID = id
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lines.joined(separator: L10n.t("people.row.between")))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityActions { NoticeMenuActions(more: menu.more, asks: menu.asks) }
            .modifier(NoticeRowMenu(menu: menu, label: L10n.t("tend.more.label")))
            // A post is drawn as a post's row, as it is everywhere.
            if case .post(let note) = item.what {
                DummyItemRow(item: DummyItem(note, among: ReblogTargets([note])), catalogues: catalogues, posts: posts, onOpenPerson: onOpenPerson)
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

    // MARK: - Rules

    @ViewBuilder
    private func rulesList(_ rules: TendingServerSaid.Rules) -> some View {
        ShellRule()
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            head(L10n.t("tend.server.rules.title"))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let page = rules.page {
                Button { acts.onOpenRules(page) } label: {
                    Label(String(format: L10n.t("tend.server.rules.change"), said.host), systemImage: "safari")
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.selectInk(colorScheme))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
        ForEach(Array(rules.rules.enumerated()), id: \.element.id) { index, rule in
            let line = TendingServerSaid.rule(rule, at: index)
            Text(verbatim: line)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.tight)
                .id(TendingServerSaid.ruleID(rule.id))
                .background(selectedID == TendingServerSaid.ruleID(rule.id) ? ShellChrome.floatFill(colorScheme) : .clear)
                .accessibilityAddTraits(selectedID == TendingServerSaid.ruleID(rule.id) ? .isSelected : [])
        }
        if let quiet = rules.quiet {
            quietLine(quiet)
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.snug)
        }
    }

    // MARK: - Pieces

    private func head(_ words: String) -> some View {
        Text(words)
            .shellFont(.name)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func quietLine(_ words: String) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TendingServerSaid {
    static func spanName(_ days: Int, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("tend.server.measures.days", language: language), L10n.grouped(days, language: language))
    }

    /// One figure: what it counts, how many, and — where the server said it — the span before.
    static func figure(_ measure: ServerMeasure, language: DummyLanguage? = nil) -> String {
        let name = L10n.t("tend.server.measure.\(String(describing: measure.key))", language: language)
        let now = String(format: L10n.t("tend.server.measure.line", language: language), name, L10n.grouped(measure.total, language: language))
        guard let before = measure.before else { return now }
        return now + " " + String(format: L10n.t("tend.server.measure.before", language: language), L10n.grouped(before, language: language))
    }

    /// Whose the figures are and as of when: the server's, as it said them then.
    static func asOf(_ measures: ServerMeasures, host: String, language: DummyLanguage? = nil) -> String {
        String(
            format: L10n.t("tend.server.measures.asOf", language: language), host,
            measures.asOf.formatted(date: .abbreviated, time: .shortened)
        )
    }

    static func title(_ kind: RisingKind, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.server.rising.\(kind.rawValue)", language: language)
    }

    /// Where it stands: waiting, let rise, kept back — or nothing, where the server did not say.
    static func standing(_ item: RisingReview, language: DummyLanguage? = nil) -> String? {
        if item.waiting { return L10n.t("tend.server.rising.waiting", language: language) }
        switch item.rises {
        case true?: return L10n.t("tend.server.rising.rises", language: language)
        case false?: return L10n.t("tend.server.rising.kept", language: language)
        case nil: return L10n.t("tend.server.rising.reviewed", language: language)
        }
    }

    /// The lines of a row: what it is, where it stands and how much it was used. A post is
    /// drawn as a post under them.
    static func lines(_ item: RisingReview, language: DummyLanguage? = nil) -> [String] {
        let use: RisingUse?
        let what: String
        var more: String?
        switch item.what {
        case .tag(let tag):
            what = tag.tag.text
            use = tag.use
        case .link(let link):
            what = link.title.isEmpty ? link.link.url.absoluteString : link.title
            more = link.link.host
            use = link.use
        case .post:
            what = L10n.t("tend.server.rising.post", language: language)
            use = nil
        }
        let people = use.flatMap { use in
            use.people.map { String(format: L10n.t("tend.server.rising.people", language: language), L10n.grouped($0, language: language)) }
        }
        let state = [standing(item, language: language), people].compactMap { $0 }.joined(separator: " · ")
        return [what, more, state.isEmpty ? nil : state].compactMap { $0 }
    }

    /// A row's `…`: let rise, kept back — the way it already stands, where the server said, not
    /// offered. Where the sign-in may not review, tending's lock in their place, or both dim.
    @MainActor
    static func more(_ item: RisingReview, said: Self, actions: TendingServerActs, language: DummyLanguage? = nil) -> ShellMore {
        if !said.acts, let lock = said.lock, lock.asks {
            let line = String(format: L10n.t(lock.key, language: language), said.host)
            return ShellMore(items: [.plain(ShellMark(SourceRow.permissionSymbol, line, look: .live), act: actions.onAskWords)])
        }
        let look: MarkLook = !said.acts ? .dim(.never) : said.acting.contains(rowID(item.kind, item.id)) ? .dim(.notNow) : .live
        let why = said.acts ? nil : L10n.t("tend.readOnly", language: language)
        var items: [ShellMoreItem] = []
        if item.waiting || item.rises != true {
            items.append(ShellMoreItem.plain(ShellMark("arrow.up.right.circle", L10n.t("tend.server.rise", language: language), look: look)) {
                actions.onReview(item, true)
            }.because(why))
        }
        if item.waiting || item.rises != false {
            items.append(ShellMoreItem.plain(ShellMark("hand.raised", L10n.t("tend.server.keep", language: language), look: look)) {
                actions.onReview(item, false)
            }.because(why))
        }
        return ShellMore(items: items)
    }

    /// A rule in its place: its number, its words, and its hint after them.
    static func rule(_ rule: ServerRule, at index: Int, language: DummyLanguage? = nil) -> String {
        let number = L10n.grouped(index + 1, language: language)
        return rule.hint.map { "\(number). \(rule.text) — \($0)" } ?? "\(number). \(rule.text)"
    }
}
