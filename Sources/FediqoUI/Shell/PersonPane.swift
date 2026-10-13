import AVKit
import FediqoCore
import SwiftUI

/// The posts a tab of somebody's page lists, as it is handed them: the rows, what is said
/// over them, what stands where they would, and what stands under them.
///
/// **A value for both tabs that list posts** — their posts, and the ones they pinned — so one
/// list draws either, and neither tab's words are worked out where they are drawn.
struct PostRowsSaid: Equatable {
    /// Where the asking stands, over the rows.
    struct Line: Equatable {
        let words: String
        /// Whether it says an ask came to nothing, and so is in full ink.
        var failed = false
        /// Whether the press that asks again stands beside it.
        var again = false
    }

    /// What stands under the rows.
    struct Foot: Equatable {
        let symbol: String
        let words: String
        /// Whether it is a press: it reads on, or asks again for a stretch that did not come.
        let presses: Bool
    }

    var items: [DummyItem] = []
    var line: Line?
    /// What stands where rows would and none are drawn.
    var quiet: String?
    var foot: Foot?

    /// The Posts tab of a page: the source's posts once it has answered, and what this device
    /// holds of theirs until then — and for good where it did not answer, has not heard of
    /// them, or is not asked who people are: a failure takes nothing away.
    static func posts(
        of said: PersonSaid?, held: [DummyItem], standing: PersonActing?, language: DummyLanguage? = nil
    ) -> PostRowsSaid {
        guard let said else {
            // **The honest sentence, and it is about this device rather than about them.** A
            // page that said "they have written nothing" would be this app speaking for
            // somebody whose server it has not asked.
            return PostRowsSaid(items: held, quiet: held.isEmpty ? L10n.t("person.none", language: language) : nil)
        }
        return PostRowsSaid(
            items: said.posts ?? held,
            quiet: said.emptyLine(held: held.count, standing: standing, language: language),
            foot: said.foot.map { Foot(symbol: $0.symbol, words: $0.words(said.source, language: language), presses: $0.presses) }
        )
    }

    /// The Pinned tab of a page: what they pinned, in the source's own order.
    static func pinned(_ said: PersonPinnedSaid, language: DummyLanguage? = nil) -> PostRowsSaid {
        PostRowsSaid(
            items: said.posts,
            line: said.stateLine(language: language).map { Line(words: $0, failed: said.failed, again: said.failed) },
            quiet: said.nothing(language: language),
            foot: said.foot.map { Foot(symbol: $0.symbol, words: said.footWords($0, language: language), presses: $0.presses) }
        )
    }
}

extension PersonSaid {
    /// What stands where posts would and none are drawn, or nothing where some are, or where
    /// their newest are still being asked for. About the source where the source answered with
    /// none, about this device where what it holds is all there is to draw.
    ///
    /// **For a signed-in reader the source counts posts of theirs for and gives none, the
    /// sentence is the one decided** (#310): that the source gives this sign-in none of them,
    /// and nothing else — where they block the reader, since the head has said why, and
    /// where how the reader stands to them is not known (`PersonActing.givesNoneUnexplained`),
    /// since then no reason is known and no figure is set beside the lack of one. Where the
    /// source has said how the reader stands and it is not a block, and where nobody stands to
    /// them here at all, what it gave and what it counts are said as they always were.
    ///
    /// **Nothing while how the reader stands to them is still being asked** (decided
    /// 2026-10-13): which sentence it is hangs on the answer, and a line that read one way and
    /// then another would change under the reader. The place is the foot of the list, with
    /// nothing drawn under it, so the line arriving moves nothing.
    func emptyLine(held: Int, standing: PersonActing? = nil, language: DummyLanguage? = nil) -> String? {
        if let posts {
            // A suspended account's line has said why already; a stretch that did not come is
            // the foot's to say.
            guard posts.isEmpty, foot == nil, person?.suspended != true else { return nil }
            if let standing, standing.stillAsked { return nil }
            if let standing, standing.givesNone(counted: person?.tally.posts) {
                return String(format: L10n.t("person.posts.noneGiven", language: language), source)
            }
            return PersonSaid.gaveNone(source, counted: person?.tally.posts, language: language)
        }
        guard held == 0, reading == .unheardOf || reading == .failed else { return nil }
        return L10n.t("person.none", language: language)
    }
}

/// The posts of a tab of somebody's page, drawn: a list of post rows, with what is said over
/// them, what stands where they would, and the foot (#99, #310).
///
/// **The list alone.** The bar, the head and the tabs are the page's (`PersonPage`); this is
/// what stands under them on the Posts tab and on the Pinned one, and the whole of what a
/// forum author's page draws under its heading.
///
/// ## The rows open, and the face on them does not
///
/// A row here opens the conversation that post belongs to, the way a row anywhere else in the
/// app does (#122) — the page and the conversation are steps of one walk (`ShellWalk`), and
/// leaving the conversation gives this page back, standing on the row it was opened from.
///
/// **The face is still not a press here**, and that is the one thing this list does
/// differently from every other: it is already this person's page, so a face that opened it
/// would be a control that promises a journey and stands still. Absent, rather than drawn and
/// refused.
struct PersonPane<Lead: View>: View {
    let said: PostRowsSaid
    /// Passed through to every row, exactly as the thread pane passes them: a person's list draws
    /// the same four bands the stream does.
    let catalogues: EmojiCatalogueStore
    var catalogueSettled: Bool = false
    let posts: ForumPosts
    @Binding var selectedID: String?
    /// Each row's share of #54's acts, asked of the pane above rather than worked out here: the
    /// session holds what decides them and this pane has no session. See `ItemActing`.
    var acting: (DummyItem) -> ItemActing = { _ in ItemActing() }
    @Binding var decks: ShellDecks
    let playback: ShellPlayback
    var onPlayRow: (DummyItem) -> Void
    var onViewRow: (DummyItem) -> Void
    var onTurnRow: (DummyItem) -> Void
    /// A press on a row: the conversation that post belongs to, answered by the root under the
    /// walk's own rule (#122) — the same closure the stream's rows are given.
    var onOpenThread: (String) -> Void
    var jumpToTop: Int
    /// "Try again", beside a line that says the list could not be asked for.
    var onAskAgain: () -> Void = {}
    /// The foot's press: the stretch after what is drawn.
    var onReadOn: () -> Void = {}
    /// What stands over the rows and scrolls away with them: the page's head, at a text size
    /// where it would fill the page.
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    /// Under a finger one press on a row opens it (#303); the lamp here is where the walk left it.
    @Environment(\.shellTouch) private var touch

    /// The head of the list: what `g` scrolls back to.
    private static var top: String { "person.top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    if let line = said.line {
                        stateLine(line)
                        ShellRule()
                    }
                    ForEach(Array(said.items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .id(item.id)
                        if index < said.items.count - 1 { ShellRule() }
                    }
                    if let sentence = said.quiet { quiet(sentence) }
                    if let foot = said.foot {
                        ShellRule()
                        PersonFootRow(symbol: foot.symbol, words: foot.words, presses: foot.presses, onPress: onReadOn)
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            // Come back to from a conversation, or brought in front again, the row the lamp is
            // on is in view.
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

    /// Where the asking stands, and beside a failure the press that asks again.
    private func stateLine(_ line: PostRowsSaid.Line) -> some View {
        WordsThenPress(
            words: Text(line.words)
                .shellFont(.meta)
                .foregroundStyle(line.failed ? ShellChrome.ink(colorScheme) : ShellChrome.inkFaint(colorScheme)),
            press: Group {
                if line.again { ShellLinkButton(L10n.t("person.retry"), action: onAskAgain).fixedSize() }
            }
        )
    }

    private func quiet(_ sentence: String) -> some View {
        Text(sentence)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One of theirs.
    ///
    /// **One closure is deliberately nothing.** `onOpenPerson` is nothing because this *is*
    /// their page — a face that opened the page it is already on is a control that promises a
    /// journey and stands still, so it is absent rather than drawn and refused.
    private func row(_ item: DummyItem) -> some View {
        DummyItemRow(
            item: item,
            catalogues: catalogues,
            catalogueSettled: catalogueSettled,
            posts: posts,
            acting: acting(item),
            selected: item.id == selectedID,
            top: decks.top(of: item.id, of: item.attachments.count),
            lifted: decks.isLifted(item.id),
            player: playback.rowPlayer(for: item, decks: decks),
            // A press lights the row; a second press on the row it is already on opens the
            // conversation, which is `DummyCommand.tapped` and is exactly what a press does on
            // the stream (#122).
            onSelect: {
                switch DummyCommand.tapped(item.id, selected: selectedID, touch: touch) {
                case .select: selectedID = item.id
                case .open: onOpenThread(item.id)
                }
            },
            // Lit and opened in one, for the reader who activates a row once.
            onOpen: { onOpenThread(item.id) },
            onOpenPerson: nil,
            quoteLifted: decks.isQuoteLifted(of: item),
            onToggleQuoteCover: { decks.toggleQuoteCover(of: item) },
            onToggleCover: { _ = decks.toggleCover(item.id) },
            onPlay: { onPlayRow(item) },
            onView: { onViewRow(item) },
            onViewAt: { at in
                decks.show(item.id, at: at, of: item.attachments.count)
                onViewRow(item)
            },
            onTurn: { onTurnRow(item) },
            onEnded: { playback.stop() }
        )
    }
}
