import FediqoCore
import SwiftUI

/// A link rising on the sources, opened as the posts that share it (#379): a page of its own
/// (F10), drawn in the frame every opened page stands in (`OpenedPage`), with no tabs.
///
///     ‹ Back                                         [↗ Open the page] [↻]   Esc or q
///     ──────────────────────────────────────────────────────────────────────────
///     A story rising & more
///     What the page says of itself.
///     elsewhere.example
///     Posts that share it  [m.example +1]
///     ──────────────────────────────────────────────────────────────────────────
///     post rows, newest first
///     the sources that list none of it · the foot, which reads on
///
/// **The link's own page is one press away**: the bar's mark, which opens it through the door
/// a post's link goes through. **It is handed everything it draws** and asks nothing: the
/// asking is `ShellSharedLinks`'s, a row's press is the walk's own, and which kind of source
/// this is is never looked at here. Its head is what the link's row said of it, drawn as text —
/// a stranger's words through a stranger's server — and the host it leads to is the address's own.
struct SharedLinkPane: View {
    let said: SharedLinkSaid
    /// What the bar's mark is called — the sources it asks again — or nothing where there is
    /// nobody to ask: then the mark is absent, and a pull asks nothing.
    var reload: String?
    /// How far a sideways swipe has slid the list.
    var slide = PageSlide()
    var acts = OpenedPageActs<SoleTab>()
    /// The link's own page, opened.
    var onOpenPage: () -> Void
    /// The foot pressed: the next stretch, and again one that did not come.
    var onReadOn: () -> Void
    /// The foot come into view: the next stretch, where the last one came.
    var onReachFoot: () -> Void
    let rows: PersonPageRows
    var onOpenPerson: (DummyPerson) -> Void
    @Binding var selectedID: String?
    @Binding var decks: ShellDecks
    var jumpToTop: Int

    /// What the bar's mark is called, where `r` may ask: the sources it asks again.
    static func reloadName(of said: SharedLinkSaid, canReload: Bool, language: DummyLanguage? = nil) -> String? {
        canReload ? PersonPage.reloadName(said.page.sources.joined(separator: ", "), language: language) : nil
    }

    /// The bar's mark that opens the link's own page, named for where it leads.
    static func openMark(_ said: SharedLinkSaid, language: DummyLanguage? = nil, action: @escaping () -> Void) -> PageMark {
        PageMark(
            symbol: "arrow.up.right.square",
            name: L10n.t("shared.open", language: language),
            hint: String(format: L10n.t("rising.link.leads", language: language), said.page.link.link.host),
            action: action
        )
    }

    /// What stands where rows would, and under them, as one block of lines.
    static func quiet(_ said: SharedLinkSaid) -> String? {
        said.quiet.isEmpty ? nil : said.quiet.joined(separator: "\n")
    }

    var body: some View {
        OpenedPage(
            tabs: SoleTab.tabs, front: .sole, slide: slide, marks: [Self.openMark(said, action: onOpenPage)],
            reload: reload, acts: acts,
            head: {
                SharedLinkHead(said: said)
                ShellRule()
            },
            inFront: { lead in
                PersonPane(
                    said: PostRowsSaid(
                        items: said.items, quiet: Self.quiet(said),
                        foot: said.foot.map { PostRowsSaid.Foot(symbol: $0.symbol, words: said.footWords ?? "", presses: $0.presses) }
                    ),
                    catalogues: rows.catalogues, catalogueSettled: rows.catalogueSettled, posts: rows.posts,
                    selectedID: $selectedID, acting: rows.acting, decks: $decks, playback: rows.playback,
                    onPlayRow: rows.onPlayRow, onViewRow: rows.onViewRow, onTurnRow: rows.onTurnRow,
                    onOpenThread: rows.onOpenThread, jumpToTop: jumpToTop, onReadOn: onReadOn, onReachFoot: onReachFoot,
                    onOpenPerson: onOpenPerson, lead: { lead }
                )
            }
        )
    }
}

/// The head of a rising link's posts: what the source says the page is called and of it, the
/// host it leads to, and that these are the posts that share it, with the sources that said so.
/// One heading to a listener.
struct SharedLinkHead: View {
    let said: SharedLinkSaid
    @Environment(\.colorScheme) private var colorScheme

    /// What a listener is read: where it leads first, in words of ours, then what the source
    /// says of it, then what the list is and whose.
    static func spoken(_ said: SharedLinkSaid, language: DummyLanguage? = nil) -> String {
        let link = said.page.link
        return [
            String(format: L10n.t("rising.link.leads", language: language), link.link.host), RisingSaid.called(link),
            link.words.isEmpty ? nil : link.words, L10n.t("shared.heading", language: language),
            RisingSaid.spokenSources(said.page.sources, language: language),
        ].compactMap { $0 }.joined(separator: L10n.t("people.row.between", language: language))
    }

    var body: some View {
        let link = said.page.link
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(verbatim: RisingSaid.called(link))
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if !link.words.isEmpty {
                Text(verbatim: link.words)
                    .shellFont(.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(3)
            }
            Text(verbatim: link.link.host)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
                Text(L10n.t("shared.heading"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                if let named = RisingSaid.drawnSources(said.page.sources),
                   let spoken = RisingSaid.spokenSources(said.page.sources)
                {
                    SourcePill(said: named, spoken: spoken)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(said))
        .accessibilityAddTraits(.isHeader)
    }
}
