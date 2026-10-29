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
    /// A hashtag the server knows let rise or kept back, let be used or not (#419).
    var onTag: (AdminTag, TendingServerSaid.TagChange) -> Void = { _, _ in }
    /// A site let rise — `true` — or kept back, its links with it (#419).
    var onSite: (LinkSite, Bool) -> Void = { _, _ in }
    /// The hashtags known, or the sites, pressed at their foot.
    var onReadOnKnown: (KnownList) -> Void = { _ in }
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
///     Who stays, by month                               (over the same span)
///     Joined in September 2026
///       September 2026: 12 · 100%     October 2026: 5 · 42%
///     By language
///       English: 40   Japanese: 9          — or "Not given by m.example"
///     ─────────────────────────────────────────────────────────────────
///     Hashtags rising
///     #FediqoWaiting       Waiting for review · 12 people over 2 days   …
///     ─────────────────────────────────────────────────────────────────
///     Hashtags it knows                                  (#419, beside them)
///     #Fediqo419           Kept back · May be used                     …
///     Sites its links come from
///     fediqo419.example    Not yet decided                              …
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
                    if let tags = said.tags {
                        knownList(.tags, tags) { tag in
                            knownRow(TendingServerSaid.knownID(.tags, tag.id), lines: TendingServerSaid.lines(of: tag),
                                     more: TendingServerSaid.more(tag, said: said, actions: acts))
                        }
                    }
                    if let sites = said.sites {
                        knownList(.sites, sites) { site in
                            knownRow(TendingServerSaid.knownID(.sites, site.id), lines: TendingServerSaid.lines(of: site),
                                     more: TendingServerSaid.more(site, said: said, actions: acts))
                        }
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
        if measures.quiet == nil {
            retention(measures)
            breakdowns(measures)
        }
    }

    /// Who stays (#418): each month's joiners and how many of them were seen in each month after,
    /// said plainly as by month — the server counts by day or by month, never by week.
    @ViewBuilder
    private func retention(_ measures: TendingServerSaid.Measures) -> some View {
        if measures.retention != nil || measures.retentionQuiet != nil {
            ShellRule()
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                head(L10n.t("tend.server.retention.title"))
                quietLine(L10n.t("tend.server.retention.line"))
                if let retention = measures.retention {
                    if retention.cohorts.isEmpty { quietLine(L10n.t("tend.server.retention.none")) }
                    ForEach(retention.cohorts) { cohort in
                        VStack(alignment: .leading, spacing: ShellSpace.tight) {
                            Label(TendingServerSaid.cohortTitle(cohort), systemImage: "person.2")
                                .shellFont(.reading)
                                .foregroundStyle(ShellChrome.ink(colorScheme))
                            ForEach(Array(cohort.points.enumerated()), id: \.offset) { _, point in
                                figureLine(TendingServerSaid.pointLine(point))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    asOfLine(TendingServerSaid.asOf(retention.asOf, host: said.host))
                }
                if let quiet = measures.retentionQuiet { quietLine(quiet) }
            }
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
        }
    }

    /// What the server holds by language, by server, by software (#418): each its lines, or —
    /// where the server did not give it — that it did not, never a zero.
    @ViewBuilder
    private func breakdowns(_ measures: TendingServerSaid.Measures) -> some View {
        if let breakdowns = measures.breakdowns {
            ForEach(breakdowns.asked, id: \.self) { key in
                ShellRule()
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    Label(TendingServerSaid.breakdownTitle(key), systemImage: TendingServerSaid.breakdownSymbol(key))
                        .shellFont(.name)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(TendingServerSaid.breakdownLines(key, of: breakdowns, host: said.host), id: \.self) { line in
                        figureLine(line)
                    }
                }
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.step)
            }
            asOfLine(TendingServerSaid.asOf(breakdowns.asOf, host: said.host))
                .padding(.horizontal, ShellSpace.pad)
                .padding(.bottom, ShellSpace.step)
        } else if let quiet = measures.breakdownsQuiet {
            ShellRule()
            quietLine(quiet)
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.step)
        }
    }

    private func figureLine(_ words: String) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func asOfLine(_ words: String) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - What the server knows (#419)

    /// Every hashtag the server knows, or the sites its links come from: the head, a row each,
    /// the sentence where there are none, and the foot that reads on.
    @ViewBuilder
    private func knownList<Item: Identifiable & Equatable, Row: View>(
        _ list: KnownList, _ shown: ServerListSaid<Item>, @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View where Item.ID == String {
        ShellRule()
        head(TendingServerSaid.title(list))
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
        ForEach(shown.items) { item in
            ShellRule()
            row(item)
                .id(TendingServerSaid.knownID(list, item.id))
        }
        if let quiet = shown.quiet {
            quietLine(quiet)
                .padding(.horizontal, ShellSpace.pad)
                .padding(.vertical, ShellSpace.snug)
        }
        if shown.more {
            ShellRule()
            PersonFootRow(
                symbol: PersonSaid.Foot.more.symbol, words: L10n.t("person.foot.more"), presses: true,
                onPress: { acts.onReadOnKnown(list) }
            )
        }
    }

    private func knownRow(_ id: String, lines: [String], more: ShellMore) -> some View {
        let menu = NoticeRow.Menu(more: { more }, asks: $asked)
        let selected = selectedID == id
        return HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
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
        .padding(.vertical, ShellSpace.step)
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

    /// Whose figures and as of when, for a breakdown or who stays (#418).
    static func asOf(_ date: Date, host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("tend.server.measures.asOf", language: language), host, date.formatted(date: .abbreviated, time: .shortened))
    }

    /// A month by its name and year, on the server's calendar (UTC).
    static func month(_ date: Date, language: DummyLanguage? = nil) -> String {
        var style = Date.FormatStyle().year().month(.wide).locale(L10n.locale(language))
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return date.formatted(style)
    }

    /// Who joined in a month, as its head.
    static func cohortTitle(_ cohort: RetentionCohort, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("tend.server.retention.cohort", language: language), month(cohort.month, language: language))
    }

    /// One month after joining: how many of them were seen in it or later, and their share.
    static func pointLine(_ point: RetentionCohort.Point, language: DummyLanguage? = nil) -> String {
        String(
            format: L10n.t("tend.server.retention.point", language: language), month(point.month, language: language),
            L10n.grouped(point.count, language: language),
            point.rate.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale(language)))
        )
    }

    static func breakdownTitle(_ key: ServerBreakdown.Key, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.server.breakdown.\(String(describing: key))", language: language)
    }

    static func breakdownSymbol(_ key: ServerBreakdown.Key) -> String {
        switch key {
        case .languages: "character.bubble"
        case .servers: "network"
        case .software: "shippingbox"
        case .sources: "arrow.down.right.circle"
        case .space: "internaldrive"
        }
    }

    /// One breakdown's lines: each of its rows, the server's figure for it as the server says
    /// it; none over the span, where it gave the breakdown empty; and **not given** where it left
    /// it out — never a zero.
    static func breakdownLines(_ key: ServerBreakdown.Key, of breakdowns: ServerBreakdowns, host: String, language: DummyLanguage? = nil)
        -> [String]
    {
        guard let breakdown = breakdowns.breakdown(key) else {
            return [String(format: L10n.t("tend.server.breakdown.notGiven", language: language), host)]
        }
        guard !breakdown.rows.isEmpty else { return [L10n.t("tend.server.breakdown.none", language: language)] }
        return breakdown.rows.map { row in
            let value = row.shown ?? row.figure.map { L10n.grouped($0, language: language) } ?? row.value
            return String(format: L10n.t("tend.server.breakdown.row", language: language), row.name, value)
        }
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

    static func title(_ list: KnownList, language: DummyLanguage? = nil) -> String {
        L10n.t("tend.server.known.\(list.rawValue)", language: language)
    }

    /// A hashtag the server knows: the hashtag; whether it may rise and be used — and whether it
    /// waits for somebody to say — and how many used it.
    static func lines(of tag: AdminTag, language: DummyLanguage? = nil) -> [String] {
        let people = tag.tag.use.people.map {
            String(format: L10n.t("tend.server.rising.people", language: language), L10n.grouped($0, language: language))
        }
        let state = [
            tag.waiting ? L10n.t("tend.server.rising.waiting", language: language) : nil,
            L10n.t(tag.rises ? "tend.server.rising.rises" : "tend.server.rising.kept", language: language),
            L10n.t(tag.usable ? "tend.server.tag.usable" : "tend.server.tag.unusable", language: language),
            people,
        ].compactMap { $0 }.joined(separator: " · ")
        return [tag.tag.tag.text, state]
    }

    /// A site its links come from: its name, and whether its links may rise — or that nobody
    /// has said yet.
    static func lines(of site: LinkSite, language: DummyLanguage? = nil) -> [String] {
        let key = switch site.rises {
        case true?: "tend.server.site.rises"
        case false?: "tend.server.site.kept"
        case nil: "tend.server.site.undecided"
        }
        return [site.domain, L10n.t(key, language: language)]
    }

    /// A hashtag's `…`: let rise or kept back, and let be used or kept from use — each the way it
    /// does not stand already. Where the sign-in may not change it, tending's lock, or dim.
    @MainActor
    static func more(_ tag: AdminTag, said: Self, actions: TendingServerActs, language: DummyLanguage? = nil) -> ShellMore {
        if let locked = locked(said, actions: actions, language: language) { return locked }
        let look = look(knownID(.tags, tag.id), said: said)
        let why = said.acts ? nil : L10n.t("tend.readOnly", language: language)
        let rise: ShellMoreItem = tag.rises
            ? .plain(ShellMark("hand.raised", L10n.t("tend.server.keep", language: language), look: look)) { actions.onTag(tag, .rises(false)) }
            : .plain(ShellMark("arrow.up.right.circle", L10n.t("tend.server.rise", language: language), look: look)) { actions.onTag(tag, .rises(true)) }
        let use: ShellMoreItem = tag.usable
            ? .plain(ShellMark("nosign", L10n.t("tend.server.tag.unuse", language: language), look: look)) { actions.onTag(tag, .usable(false)) }
            : .plain(ShellMark("number", L10n.t("tend.server.tag.use", language: language), look: look)) { actions.onTag(tag, .usable(true)) }
        return ShellMore(items: [rise.because(why), use.because(why)])
    }

    /// A site's `…`: let rise or kept back, its links with it — both where nobody has said yet.
    @MainActor
    static func more(_ site: LinkSite, said: Self, actions: TendingServerActs, language: DummyLanguage? = nil) -> ShellMore {
        if let locked = locked(said, actions: actions, language: language) { return locked }
        let look = look(knownID(.sites, site.id), said: said)
        let why = said.acts ? nil : L10n.t("tend.readOnly", language: language)
        var items: [ShellMoreItem] = []
        if site.rises != true {
            items.append(ShellMoreItem.plain(ShellMark("arrow.up.right.circle", L10n.t("tend.server.site.rise", language: language), look: look)) {
                actions.onSite(site, true)
            }.because(why))
        }
        if site.rises != false {
            items.append(ShellMoreItem.plain(ShellMark("hand.raised", L10n.t("tend.server.site.keep", language: language), look: look)) {
                actions.onSite(site, false)
            }.because(why))
        }
        return ShellMore(items: items)
    }

    private static func look(_ id: String, said: Self) -> MarkLook {
        !said.acts ? .dim(.never) : said.acting.contains(id) ? .dim(.notNow) : .live
    }

    @MainActor
    private static func locked(_ said: Self, actions: TendingServerActs, language: DummyLanguage?) -> ShellMore? {
        guard !said.acts, let lock = said.lock, lock.asks else { return nil }
        let line = String(format: L10n.t(lock.key, language: language), said.host)
        return ShellMore(items: [.plain(ShellMark(SourceRow.permissionSymbol, line, look: .live), act: actions.onAskWords)])
    }

    /// A rule in its place: its number, its words, and its hint after them.
    static func rule(_ rule: ServerRule, at index: Int, language: DummyLanguage? = nil) -> String {
        let number = L10n.grouped(index + 1, language: language)
        return rule.hint.map { "\(number). \(rule.text) — \($0)" } ?? "\(number). \(rule.text)"
    }
}
