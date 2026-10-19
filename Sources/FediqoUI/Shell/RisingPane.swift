import FediqoCore
import SwiftUI

// The hashtags and the links rising on the sources (#320), as Trends' two tabs of them draw
// them.
//
// **One list, in each source's own order** (decision 22). What is rising is each source's own
// ranking, woven: every source's first, then every second (`RisingListed.merged`). A hashtag or
// a link stands once, naming its sources as a post row names its own ("m.example +1") and with
// their uses added; a source that gave none says so at the foot of the list. Being asked,
// failing and being stopped are the tab's toast's to say.
//
// **A hashtag opens its page; a link opens as any link does.** A hashtag's row is the hashtag
// as a post's words would carry it, and opens the page such a hashtag opens. A link's row is
// an address this device would follow from a post's words: what its source says of it is drawn
// as text, the host it leads to is the address's own, and a press takes it through the door a
// post's link goes through. **Nothing of a link is fetched by drawing its row** — no picture,
// no page.

extension RisingSaid {
    // MARK: - Words

    /// What the page is called, whichever tab is in front.
    static func pageTitle(language: DummyLanguage? = nil) -> String {
        L10n.t("rising.title", language: language)
    }

    /// The one line under the title: whose ranking this is.
    static func headLine(language: DummyLanguage? = nil) -> String {
        L10n.t("rising.line", language: language)
    }

    /// How much a hashtag or a link was used of late, as its source counts: one sentence, or
    /// nothing where the source gave no figure. **Its figures, written whole**, with "not
    /// said" where it gave one and not the other.
    static func used(_ use: RisingUse, language: DummyLanguage? = nil) -> String? {
        guard use.isSaid else { return nil }
        func figure(_ value: Int?) -> String {
            value.map { L10n.grouped($0, language: language) } ?? L10n.t("rising.unsaid", language: language)
        }
        return String(
            format: L10n.t(use.days > 1 ? "rising.use.two" : "rising.use.one", language: language),
            figure(use.posts), figure(use.people)
        )
    }

    /// What a link's row is called: what the source says the page is called, or the address
    /// itself where it says nothing.
    static func called(_ link: RisingLink) -> String {
        link.title.isEmpty ? LineText.oneLine(link.link.text, limit: RisingLink.titleLength) : link.title
    }

    /// What a row's pill draws of the sources that named it: the first, and how many more did —
    /// a post row's pill's words (`item.source.more`). Nothing where no source is named.
    static func drawnSources(_ sources: [String], language: DummyLanguage? = nil) -> String? {
        sources.first.map { DummyItemRow.drawnSource($0, others: Array(sources.dropFirst()), language: language) }
    }

    /// What a listener hears of them: **every source, by name**, as of a post that came
    /// through more than one (`item.source.also`) — a listener cannot see a count and look further.
    static func spokenSources(_ sources: [String], language: DummyLanguage? = nil) -> String? {
        sources.first.map { DummyItemRow.spokenSource($0, others: Array(sources.dropFirst()), language: language) }
    }

    /// A row as a listener hears it: what it is, where a link leads, what the source says of
    /// it, and how much it was used.
    static func spoken(_ row: RisingRow, language: DummyLanguage? = nil) -> String {
        let between = L10n.t("people.row.between", language: language)
        switch row {
        case .tag(let tag, _):
            return [tag.tag.text, used(tag.use, language: language)].compactMap { $0 }.joined(separator: between)
        case .link(let link, _):
            let leads = String(format: L10n.t("rising.link.leads", language: language), link.link.host)
            // Where it leads is said first, in words of ours: nothing a stranger called the
            // page can be heard as the place it goes.
            return [leads, called(link), link.words.isEmpty ? nil : link.words, used(link.use, language: language)]
                .compactMap { $0 }.joined(separator: between)
        }
    }
}

extension RisingSaid.Answer {
    /// What is said at the foot of the list of a source that answered with nothing: that it
    /// gave none — **never that it has none, or that it is switched off**: a
    /// source answers the same either way. An ask on the wire, failed or stopped is the tab's
    /// toast to say (DESIGN-reload), and nothing here.
    func stateLine(_ which: RisingWhich, language: DummyLanguage? = nil) -> String? {
        guard reading == .said, rows.isEmpty else { return nil }
        return String(format: L10n.t("rising.none.\(which.rawValue)", language: language), source)
    }
}

/// The tab of what is rising in front: the one list of what the sources say is rising on them,
/// led by `lead` where a page hands it its first rows, and at its foot each source that gave none.
///
/// **A tab of Trends** (decision 2), so the lamp and the row given back on leaving a hashtag's
/// page opened from it are Trends' walk's own. It draws what it is handed and asks nothing: the asking
/// is `ShellRising`'s, and which kind of source this is is never looked at here.
struct RisingPane<Lead: View>: View {
    let said: RisingSaid
    @Binding var selectedID: String?
    /// A row opened, answered by the root: a hashtag's page, or a link through the door a
    /// post's link goes through, of the first source that named it.
    var onOpen: (RisingListed) -> Void
    var jumpToTop: Int = 0
    /// The page's head, where it is the first rows of the list.
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    /// Under a finger one press on a row opens it (#303); the lamp here is where the walk left it.
    @Environment(\.shellTouch) private var touch

    var body: some View {
        // Woven once a pass: the rows, their rules and the jump to the top read the same list.
        let rows = said.rows
        let none = said.answers.compactMap { $0.stateLine(said.which) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    lead
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, listed in
                        rowView(listed)
                            .id(listed.id)
                        if index < rows.count - 1 { ShellRule() }
                    }
                    if !rows.isEmpty, !none.isEmpty { ShellRule() }
                    ForEach(none, id: \.self) { line in
                        stateLine(line)
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            // Come back to from a hashtag's page, the row it was opened from is in view.
            .onAppear {
                if let id = DummyCommand.centredOnAppear(selected: selectedID) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                guard let first = rows.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    /// What stands at the foot of the list for a source that gave no rows.
    private func stateLine(_ line: String) -> some View {
        Text(line)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row. A press lights it, and a second on the row it is already on opens it —
    /// `DummyCommand.tapped`, as on every list; under a finger one press opens.
    private func rowView(_ listed: RisingListed) -> some View {
        RisingRowView(
            row: listed.row,
            sources: listed.sources,
            selected: listed.id == selectedID,
            onPress: {
                switch DummyCommand.tapped(listed.id, selected: selectedID, touch: touch) {
                case .select: selectedID = listed.id
                case .open: onOpen(listed)
                }
            },
            onOpen: { onOpen(listed) }
        )
    }
}

/// The head of the page of what is rising: what the page is, and whose ranking it shows —
/// said once, whichever tab is in front.
struct RisingHead: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(RisingSaid.pageTitle())
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(RisingSaid.headLine())
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One hashtag or one link that a source says is rising, as a row: what it is, what its source
/// says of it, and the mark that says a press leads on — a person's row's lamp and wash.
///
/// **Every word of it is drawn as text.** A link's title and the line about it are a stranger's
/// words through a stranger's server: no part of them is a press of its own, and the host
/// under them is read out of the address, never out of what the source calls the site.
struct RisingRowView: View {
    let row: RisingRow
    /// The sources that named it, where the list it stands on is of more than one source: drawn
    /// in a pill as a post row draws its own. None on a list of one source's.
    var sources: [String] = []
    var selected = false
    var onPress: (() -> Void)?
    var onOpen: (() -> Void)?
    /// What the page it stands on says of it under its name, where that page has something
    /// to say: how the reader stands to a hashtag they follow (#318).
    var said: String?
    /// A press on it that did not arrive, in full ink.
    var missed: String?
    /// The row's `…`, and what it is called, where the list it stands on has something to do
    /// to a row. Nothing on a list that has not.
    var menu: NoticeRow.Menu?
    var menuLabel: String?
    @Environment(\.colorScheme) private var colorScheme

    /// What a listener is read: the row, every source that named it, and then what the page
    /// says of it.
    static func spoken(
        _ row: RisingRow, sources: [String] = [], said: String?, missed: String?, language: DummyLanguage? = nil
    ) -> String {
        [RisingSaid.spoken(row, language: language), RisingSaid.spokenSources(sources, language: language), said, missed]
            .compactMap { $0 }
            .joined(separator: L10n.t("people.row.between", language: language))
    }

    var body: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                switch row {
                case .tag(let tag, _): tagLines(tag)
                case .link(let link, _): linkLines(link)
                }
                if let named = RisingSaid.drawnSources(sources), let spoken = RisingSaid.spokenSources(sources) {
                    SourcePill(said: named, spoken: spoken)
                }
                if let said { figures(said) }
                if let missed {
                    Text(missed)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .shellFont(.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityHidden(true)
            if let menu {
                ShellMoreButton(label: menuLabel ?? ShellMore.label(), asks: menu.asks, more: menu.more)
                    .fixedSize()
            }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) { lamp }
        .animation(.easeInOut(duration: 0.18), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { onPress?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(row, sources: sources, said: said, missed: missed))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityAction(.default) { onOpen?() }
        // Each item of its `…` is a named action on the row, as on a person's.
        .accessibilityActions {
            if let menu { NoticeMenuActions(more: menu.more, asks: menu.asks) }
        }
        .modifier(NoticeRowMenu(menu: menu))
    }

    /// Where the reader is: a post row's own lamp.
    @ViewBuilder
    private var lamp: some View {
        if selected {
            Rectangle()
                .fill(ShellChrome.phosphor(colorScheme))
                .frame(width: DummyItemRow.Box.lamp)
        }
    }

    @ViewBuilder
    private func tagLines(_ tag: RisingTag) -> some View {
        Text(verbatim: tag.tag.text)
            .shellFont(.name)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
        if let used = RisingSaid.used(tag.use) { figures(used) }
    }

    @ViewBuilder
    private func linkLines(_ link: RisingLink) -> some View {
        Text(verbatim: RisingSaid.called(link))
            .shellFont(.name)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .lineLimit(2)
        if !link.words.isEmpty {
            Text(verbatim: link.words)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(2)
        }
        Text(verbatim: link.link.host)
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
        if let used = RisingSaid.used(link.use) { figures(used) }
    }

    private func figures(_ words: String) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}
