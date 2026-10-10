import FediqoCore
import SwiftUI

// What a source says of itself beyond its one document (#321), as its own page draws it: under
// what that page shows already, a heading and up to three lines — "More about it", "Servers it
// knows", "How busy it has been".
//
// **Each line unfolds in place.** The source's page is a sheet with no walk under it and no
// slot for a detail, and what it shows of its own at length — the server's rules — it shows
// where it stands, in the sheet's one scrolling body. So a line is a press that opens what it
// names under itself and closes it again; nothing is presented over the sheet, and nothing
// waits for the sheet to come down.
//
// **A thing the host does not offer is not here**: no line, no dimmed line, no sentence. Where
// a host was asked and offers none of the three, the heading stands with one sentence saying
// so and the press that asks again — so nothing stays absent until the app is quit.
//
// **The servers it knows are asked for at their line's press**, so the line is drawn without a
// figure until then: the figure and the names appear once the source has answered. A thing that failed says so in full ink
// with the press that asks again; a thing that answered with nothing written says that, as a
// sentence about the source.
//
// **The servers a host knows are its word about other hosts, drawn as words.** A name is text:
// not a link, not a press, never looked up. A hundred are drawn, and a press draws a hundred
// more — of the names already held; no press here asks anybody anything but "Ask again".

extension SourceMoreSaid {
    /// One of the three, as a line that unfolds.
    enum Part: String, Hashable, CaseIterable {
        case account, servers, activity
    }

    /// How many names are drawn at first, and how many more a press draws.
    static let serversStep = 100

    // MARK: - Words

    static func title(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.more.title", language: language), source)
    }

    static func help(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.more.help", language: language), source)
    }

    /// What stands under the heading where the source was asked and offers none of the three.
    static func offersNone(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.more.none", language: language), source)
    }

    /// What stands in the servers' place where the source named more than is read here.
    static func tooMany(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.more.servers.tooMany", language: language), source)
    }

    static func askingLine(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.more.asking", language: language), source)
    }

    /// What a line is called.
    static func label(_ part: Part, language: DummyLanguage? = nil) -> String {
        L10n.t("source.more.\(part.rawValue)", language: language)
    }

    /// What stands in a line's place where the source answered with nothing written.
    static func nothing(_ part: Part, source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.more.\(part.rawValue).none", language: language), source)
    }

    /// What stands in a line's place where the source could not be asked for it.
    static func failed(_ part: Part, source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.more.\(part.rawValue).failed", language: language), source)
    }

    /// The figure beside "Servers it knows": what the source counts, written whole.
    static func serversFigure(_ servers: HostServers, language: DummyLanguage? = nil) -> String {
        L10n.grouped(servers.counted, language: language)
    }

    /// What a line says to a listener: its name, and its figure where it has one.
    static func spoken(_ part: Part, figure: String?, language: DummyLanguage? = nil) -> String {
        guard part == .servers, let figure else { return label(part, language: language) }
        return String(format: L10n.t("source.more.servers.spoken", language: language), figure)
    }

    /// What is said under the names drawn: how many of how many, that these are all — and,
    /// where the source named more than are kept, that too. **The source's count is its
    /// figure**, and the names held may be fewer.
    static func serversFoot(
        _ servers: HostServers, shown: Int, source: String, language: DummyLanguage? = nil
    ) -> String {
        let drawn = min(shown, servers.names.count)
        if drawn < servers.names.count {
            return String(
                format: L10n.t("source.more.servers.showing", language: language),
                L10n.grouped(drawn, language: language), L10n.grouped(servers.counted, language: language)
            )
        }
        if servers.counted > servers.names.count {
            return String(
                format: L10n.t("source.more.servers.kept", language: language), source,
                L10n.grouped(servers.counted, language: language), L10n.grouped(servers.names.count, language: language)
            )
        }
        return String(format: L10n.t("source.more.servers.all", language: language), L10n.grouped(drawn, language: language))
    }

    /// Whether a press draws more of the names held.
    static func offersMore(_ servers: HostServers, shown: Int) -> Bool {
        shown < servers.names.count
    }

    /// A figure of a week as it is drawn: written whole, or a dash where the source did not say.
    static func figure(_ value: Int?, language: DummyLanguage? = nil) -> String {
        value.map { L10n.grouped($0, language: language) } ?? "–"
    }

    /// The day a week is named by, in the shell's language.
    static func day(_ week: HostWeek, language: DummyLanguage? = nil) -> String {
        week.week.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale(language)))
    }

    /// A week as a listener hears it: one sentence, with "not said" where a figure is none.
    static func spoken(_ week: HostWeek, language: DummyLanguage? = nil) -> String {
        func said(_ value: Int?) -> String {
            value.map { L10n.grouped($0, language: language) } ?? L10n.t("source.more.unsaid", language: language)
        }
        return String(
            format: L10n.t("source.more.week.spoken", language: language),
            day(week, language: language), said(week.posts), said(week.signIns), said(week.newPeople)
        )
    }

    /// When the source says it last wrote its longer account, where it says.
    static func updatedLine(_ account: HostAccount, source: String, language: DummyLanguage? = nil) -> String? {
        account.updated.map {
            String(
                format: L10n.t("source.more.account.updated", language: language), source,
                $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale(language)))
            )
        }
    }

    static func cutLine(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("source.more.account.cut", language: language), L10n.grouped(HostAccount.length, language: language))
    }
}

/// The block a source's page draws of what the host says of itself beyond its document.
///
/// It draws what it is handed and asks nothing: the asking is `ShellSourceMore`'s. What is
/// unfolded, and how many names are drawn, are this view's own and go when the sheet does.
struct SourceMoreSection: View {
    typealias Part = SourceMoreSaid.Part

    let said: SourceMoreSaid
    /// "Ask again", and a failure's "Try again".
    var onAgain: () -> Void = {}
    /// The press on "Servers it knows": the one ask for them, where they are not had yet.
    var onServers: () -> Void = {}

    @State private var unfolded: Set<Part>
    @State private var shown = SourceMoreSaid.serversStep
    @Environment(\.colorScheme) private var colorScheme

    /// `unfolded` is what stands open when the block is first drawn: nothing, in the app.
    init(
        said: SourceMoreSaid, onAgain: @escaping () -> Void = {}, onServers: @escaping () -> Void = {},
        unfolded: Set<Part> = []
    ) {
        self.said = said
        self.onAgain = onAgain
        self.onServers = onServers
        _unfolded = State(initialValue: unfolded)
    }

    var body: some View {
        ShellRule()
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            head
            if said.asking { ShellStatusLine(SourceMoreSaid.askingLine(said.source)) }
            if said.isAbsent, !said.asking { sentence(SourceMoreSaid.offersNone(said.source)) }
            account
            servers
            weeks
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
    }

    private var head: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            ShellSectionHead(
                SourceMoreSaid.title(said.source), line: L10n.t("source.more.line"), help: SourceMoreSaid.help(said.source)
            )
            ShellLinkButton(L10n.t("source.more.again"), symbol: "arrow.clockwise", action: onAgain)
                .disabled(said.asking)
                .fixedSize()
        }
    }

    // MARK: - The three

    @ViewBuilder
    private var account: some View {
        switch said.account {
        case .said(let account):
            if account.paragraphs.isEmpty {
                sentence(SourceMoreSaid.nothing(.account, source: said.source))
            } else {
                line(.account)
                if unfolded.contains(.account) { words(account) }
            }
        case .failed: failure(.account)
        case .waiting, .tooLarge, nil: EmptyView()
        }
    }

    @ViewBuilder
    private var servers: some View {
        switch said.servers {
        case .said(let servers):
            if servers.counted == 0 {
                sentence(SourceMoreSaid.nothing(.servers, source: said.source))
            } else {
                line(.servers, figure: SourceMoreSaid.serversFigure(servers))
                if unfolded.contains(.servers) { names(servers) }
            }
        // Not asked for yet: the line, with no figure, whose press asks.
        case .waiting:
            line(.servers)
            if unfolded.contains(.servers), said.askingServers { ShellStatusLine(SourceMoreSaid.askingLine(said.source)) }
        case .tooLarge: sentence(SourceMoreSaid.tooMany(said.source))
        case .failed: failure(.servers)
        case nil: EmptyView()
        }
    }

    @ViewBuilder
    private var weeks: some View {
        switch said.weeks {
        case .said(let weeks):
            if weeks.isEmpty {
                sentence(SourceMoreSaid.nothing(.activity, source: said.source))
            } else {
                line(.activity)
                if unfolded.contains(.activity) { table(weeks) }
            }
        case .failed: failure(.activity)
        case .waiting, .tooLarge, nil: EmptyView()
        }
    }

    // MARK: - Their parts

    /// A line that unfolds: its name, its figure where it has one, and the mark that says there
    /// is more under it — pointing down once there is.
    private func line(_ part: Part, figure: String? = nil) -> some View {
        let open = unfolded.contains(part)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if open { unfolded.remove(part) } else { unfolded.insert(part) }
            }
            // Asked where they are not had: the pages take a second press for none.
            if !open, part == .servers { onServers() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Text(SourceMoreSaid.label(part))
                    .shellFont(.body)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                if let figure {
                    Text(verbatim: figure)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
                Spacer(minLength: ShellSpace.snug)
                Image(systemName: "chevron.right")
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SourceMoreSaid.spoken(part, figure: figure))
        .accessibilityValue(L10n.t(open ? "source.more.shown" : "source.more.hidden"))
        .accessibilityAddTraits(.isButton)
    }

    /// A sentence about the source, where a line would stand and there is nothing to unfold.
    private func sentence(_ text: String) -> some View {
        Text(text)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A small line under what is unfolded: whose word it is, how much of it is drawn.
    private func note(_ text: String) -> some View {
        Text(text)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What could not be asked, in full ink, and the press that asks again.
    private func failure(_ part: Part) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                failed(part).fixedSize()
                Spacer(minLength: 0)
                retry(part)
            }
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                failed(part).fixedSize(horizontal: false, vertical: true)
                retry(part)
            }
        }
    }

    private func failed(_ part: Part) -> some View {
        Text(SourceMoreSaid.failed(part, source: said.source))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.ink(colorScheme))
    }

    /// The servers are asked for by themselves; the two asked at the opening, together.
    private func retry(_ part: Part) -> some View {
        ShellLinkButton(L10n.t("person.retry"), action: part == .servers ? onServers : onAgain)
            .disabled(part == .servers ? said.askingServers : said.asking)
            .fixedSize()
    }

    /// The longer account: its paragraphs as words, and what is known of how whole it is.
    private func words(_ account: HostAccount) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            ForEach(Array(account.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(verbatim: paragraph)
                    .shellFont(.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if account.cut { note(SourceMoreSaid.cutLine()) }
            if let updated = SourceMoreSaid.updatedLine(account, source: said.source) { note(updated) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The names the source gave, a stretch of those held at a time. **Words and nothing more.**
    private func names(_ servers: HostServers) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            note(String(format: L10n.t("source.more.servers.note"), said.source))
            LazyVStack(alignment: .leading, spacing: ShellSpace.hair) {
                ForEach(Array(servers.names.prefix(shown).enumerated()), id: \.offset) { _, name in
                    Text(verbatim: name)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            note(SourceMoreSaid.serversFoot(servers, shown: shown, source: said.source))
            if SourceMoreSaid.offersMore(servers, shown: shown) {
                ShellLinkButton(L10n.t("source.more.servers.more"), symbol: "arrow.down.circle") {
                    shown += SourceMoreSaid.serversStep
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The weeks, newest first: a week to a row, a figure to a column, each row one sentence
    /// to a listener.
    private func table(_ weeks: [HostWeek]) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Grid(alignment: .trailing, horizontalSpacing: ShellSpace.step, verticalSpacing: ShellSpace.tight) {
                GridRow {
                    heading("source.more.week").gridColumnAlignment(.leading)
                    heading("source.more.posts")
                    heading("source.more.signIns")
                    heading("source.more.newPeople")
                }
                .accessibilityHidden(true)
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        cell(SourceMoreSaid.day(week)).gridColumnAlignment(.leading)
                        cell(SourceMoreSaid.figure(week.posts))
                        cell(SourceMoreSaid.figure(week.signIns))
                        cell(SourceMoreSaid.figure(week.newPeople))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(SourceMoreSaid.spoken(week))
                }
            }
            note(String(format: L10n.t("source.more.activity.note"), said.source))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ key: String) -> some View {
        Text(L10n.t(key))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func cell(_ text: String) -> some View {
        Text(verbatim: text)
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// That block on a joined source's page: what `ShellSourceMore` hands for the host, drawn —
/// and **the asking that is the page opening**, once a run for a host. Nothing is drawn, and
/// nobody asked, for a source the pages hand nothing for.
struct SourceMoreBlock: View {
    let host: String
    let more: ShellSourceMore
    let session: ShellSession

    var body: some View {
        if let said = more.said(at: host, in: session) {
            SourceMoreSection(
                said: said, onAgain: { Task { await more.again(host, in: session) } },
                onServers: { Task { await more.servers(host, in: session) } }
            )
                .task(id: ShellSourceMore.opening(host, in: session)) { await more.opened(host, in: session) }
        }
    }
}
