import FediqoCore
import SwiftUI

// A hashtag, pressed (#124): the posts this device holds under it.
//
// #123 drew a tag as a pill and deliberately gave it no press, because there was nothing for one
// to open. This version has it: a tag is a query of the store like every other screen, so what it
// opens is the posts already here that carry it, and a source of the timeline in front that can be
// asked for more under it is asked, and what it brings lands in the store first, an item like any
// other (`ShellReload.tag`, #296). What is drawn is never a
// source's answer read straight off the wire.

/// Where a press on a hashtag in a post's words goes: the root's walk, handed down once as the
/// link reader is, so every line reads one object rather than a closure that differs each pass.
///
/// **Nothing, and a tag stays the label #123 drew.** Outside the shell — a preview, a test that
/// draws a row alone — there is no page for a tag to open, so it is neither inked nor pressable.
@MainActor
final class ShellTags {
    /// The walk's own answer to a press: whether a page was opened. Set by the root.
    var placing: (@MainActor (PostTag, _ row: String?) -> Bool)?

    /// A tag pressed on the row `row`, or on words that stand on no row.
    @discardableResult
    func press(_ tag: PostTag, from row: String?) -> Bool {
        placing?(tag, row) ?? false
    }

    /// The address a tag's letters carry, so a press on them reaches `openURL` as a link's does.
    /// Never a way out of the app: `ProseLinks` answers it before anything else sees it.
    static func url(for tag: PostTag) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "tag"
        components.path = "/" + tag.name
        return components.url
    }

    /// The tag an address pressed in a line stands for, or nothing where it is an address.
    static func tag(in url: URL) -> PostTag? {
        guard url.scheme == scheme, url.host == "tag" else { return nil }
        return PostTag("#" + url.path.dropFirst())
    }

    private static let scheme = "fediqo-tag"
}

extension EnvironmentValues {
    /// See `ShellTags`.
    @Entry var shellTags: ShellTags?
    /// The row a line of words stands on, where it stands on one — what a tag pressed in it
    /// gives back when its page is left (#124).
    @Entry var shellRow: String?
}

/// What this device holds under a tag, newest first.
///
/// **Carried in the words, compared without regard to case.** A post is under `#Swift` when its
/// words carry `#swift` as `PostTag` reads a tag — the same rule the pill is drawn by — and the
/// servers this app reads treat a tag the same way whatever case it was typed in.
///
/// **Or sent under it** (#197): a forum files a topic under a tag beside its words, not in them,
/// so what a source sent when asked for the tag is under it too.
enum HeldUnderTag {
    static func held(under tag: PostTag, in notes: [Note], sent: Set<NoteKey> = []) -> [Note] {
        let name = folded(tag)
        return notes.filter { note in
            sent.contains(note.key) || PostTag.found(in: note.body).contains { folded($0) == name }
        }
            .sorted { $0.postedAt > $1.postedAt }
    }

    static func folded(_ tag: PostTag) -> String {
        tag.name.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// Whether two tags are one tag.
    static func same(_ a: PostTag, _ b: PostTag) -> Bool { folded(a) == folded(b) }
}

/// A tag's page is kept against what it was worked out from, as a person's is — the timeline in
/// front among it, whose rules the page answers to (#197).
struct HeldTag {
    struct Key: Equatable {
        let tag: String
        let heldRevision: Int
        let definition: TimelineDefinition
        let sent: Set<NoteKey>
        let latest: LatestDate?
        /// The hosts still here (#250), as `DrawnTimeline.Key` carries them.
        let hosts: Set<String>
    }

    let key: Key
    let items: [DummyItem]
}

/// A hashtag, opened: a page of its own (F10), drawn in the frame every opened page stands in
/// (`OpenedPage`) — what this device holds under it, and what its sources were asked (#124).
///
///     ‹ Back                                                    Esc or q
///     ─────────────────────────────────────────────────────────────────────
///     #swift                                                  [ Follow ]
///     (bubble 41)  [✓ mastodon.social]
///     ─────────────────────────────────────────────────────────────────────
///     Asking mastodon.social, example.org for #swift…        the page's line
///     ─────────────────────────────────────────────────────────────────────
///     (bubble Posts)  (i About)         only where a source keeps it followed
///     ─────────────────────────────────────────────────────────────────────
///     post rows, newest first
///
/// **It is handed everything it draws** (`TagPageSaid`) and asks nothing: which tabs it has,
/// which is in front, the marks of its head and what About holds are worked out where the
/// sources are asked. **A page handed its posts alone draws no strip, no mark and no Follow**
/// — a forum's reader, and nobody signed in, have the one list.
///
/// **Unlike somebody's page, this one has nobody to ask again from its bar**: what a source
/// sends under the tag is asked as the page opens, lands in the store and the list renews
/// from it; while it is on its way, and where it failed, that is said in the page's line, with
/// a way to ask again.
struct TagPane: View {
    let said: TagPageSaid
    /// What this device holds under it, newest first — `ShellSession.heldPosts(under:)`.
    let items: [DummyItem]
    /// How far a sideways swipe has slid what is under the tabs.
    var slide = PageSlide()
    var acts = TagPageActs()
    let catalogues: EmojiCatalogueStore
    var catalogueSettled: Bool = false
    let posts: ForumPosts
    @Binding var selectedID: String?
    var acting: (DummyItem) -> ItemActing = { _ in ItemActing() }
    @Binding var decks: ShellDecks
    let playback: ShellPlayback
    var onPlayRow: (DummyItem) -> Void
    var onViewRow: (DummyItem) -> Void
    var onTurnRow: (DummyItem) -> Void
    var onOpenThread: (String) -> Void
    var onOpenPerson: ((DummyPerson) -> Void)?
    var jumpToTop: Int

    /// Under a finger one press on a row opens it (#303); the lamp here is where the walk left it.
    @Environment(\.shellTouch) private var touch
    @Environment(\.colorScheme) private var colorScheme

    /// The head of the list: what `g` scrolls back to.
    private static var top: String { "tag.top" }

    var body: some View {
        OpenedPage(
            tabs: said.tabs, front: said.front, slide: slide,
            acts: OpenedPageActs(onBack: acts.onBack, onTab: acts.onTab),
            head: { heading },
            inFront: { lead in inFront { lead } }
        )
    }

    /// What the ask of the sources has to say, or nothing once it has landed whole.
    enum Said: Equatable {
        case asking(String)
        case failed(String)
    }

    /// A function of what it reads, so a test can ask it without standing a pane up.
    static func said(asking: [String], failed: [String], tag: PostTag, language: DummyLanguage? = nil) -> Said? {
        if !asking.isEmpty {
            return .asking(String(format: L10n.t("tag.asking", language: language), asking.joined(separator: ", "), tag.text))
        }
        if !failed.isEmpty {
            return .failed(String(format: L10n.t("tag.failed", language: language), failed.joined(separator: ", "), tag.text))
        }
        return nil
    }

    /// The empty page's sentence: about this device, never about the tag — a page that said
    /// "nobody has used this tag" would be this app speaking for servers it did not ask.
    static func none(_ tag: PostTag, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("tag.none", language: language), tag.text)
    }

    /// The tag and what stands with it, and under it the page's line where there is one.
    @ViewBuilder
    private var heading: some View {
        TagHead(said: said, onTab: acts.onTab, onFollow: acts.onHeadFollow)
        ShellRule()
        if said.line != nil || said.reach != nil || !said.troubles.isEmpty {
            TagPageLine(
                line: said.line, retrySpoken: said.retrySpoken, troubles: said.troubles, reach: said.reach,
                onRetry: acts.onRetry, onAgain: acts.onFollow
            )
            ShellRule()
        }
    }

    /// The tab in front, with `lead` as the first rows of its list.
    @ViewBuilder
    private func inFront<Lead: View>(@ViewBuilder lead: () -> Lead) -> some View {
        switch said.front {
        case .about:
            if let about = said.about {
                TagAbout(
                    said: about, lit: selectedID, jumpToTop: jumpToTop, onPress: acts.onFollow, onUnfollow: acts.onUnfollow,
                    onAsk: acts.onAskFollows, onFeature: acts.onFeature, onUnfeature: acts.onUnfeature, lead: lead
                )
            }
        case .posts:
            rows(lead: lead())
        }
    }

    /// The posts under the tag — or, with none, that there are none, said so and never left
    /// blank — under `lead`, which scrolls away with them.
    private func rows<Lead: View>(lead: Lead) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    if let none = said.none { quiet(none) }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .id(item.id)
                        if index < items.count - 1 { ShellRule() }
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

    private func quiet(_ sentence: String) -> some View {
        Text(sentence)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One post under the tag, drawn and pressed as a row anywhere else is.
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
            onSelect: {
                switch DummyCommand.tapped(item.id, selected: selectedID, touch: touch) {
                case .select: selectedID = item.id
                case .open: onOpenThread(item.id)
                }
            },
            onOpen: { onOpenThread(item.id) },
            onOpenPerson: onOpenPerson,
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

/// The page's line of a hashtag's page, between its head and its tabs and seen from every
/// tab: the sources being asked, or those that could not be, with the press that asks again ·
/// what a source failed at about following — a press that did not arrive, a source that could
/// not say whether it is followed, with its press · which sources were asked and why not the
/// rest, where the page has no About to say it. What is said, is `TagPageSaid`'s to say.
struct TagPageLine: View {
    let line: TagPane.Said?
    /// What the press beside a failed ask is called, where its word alone does not say.
    var retrySpoken: String?
    var troubles: [TagPageSaid.Trouble] = []
    let reach: String?
    var onRetry: () -> Void = {}
    /// The press beside a source that could not be asked whether it is followed.
    var onAgain: (TagFollowLine) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch line {
            case .asking(let words):
                quiet(words).accessibilityAddTraits(.updatesFrequently)
            case .failed(let words):
                // Full ink, and where the answer would have been: a way to ask again.
                failure(words, press: L10n.t("tag.retry"), spoken: retrySpoken, action: onRetry)
            case nil:
                EmptyView()
            }
            ForEach(troubles) { trouble in
                failure(trouble.words, press: trouble.again?.pressWords(), spoken: trouble.spoken) {
                    if let line = trouble.again { onAgain(line) }
                }
            }
            // Where the page's rows came from, as a search says it under its field (#197).
            // Wraps rather than truncates, since the names are the point.
            if let reach { quiet(reach) }
        }
    }

    /// Something that went wrong, in full ink, and the press that asks again where there is one.
    /// `spoken` is what the press is called to a listener and a pointer, who meet it apart
    /// from the words beside it.
    private func failure(_ words: String, press: String?, spoken: String?, action: @escaping () -> Void) -> some View {
        WordsThenPress(
            words: Text(words).shellFont(.meta).foregroundStyle(ShellChrome.ink(colorScheme)),
            press: Group {
                if let press {
                    ShellLinkButton(press, action: action)
                        .accessibilityLabel(spoken ?? press)
                        .help(spoken ?? press)
                        .fixedSize()
                }
            }
        )
    }

    private func quiet(_ words: String) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
    }
}

/// One source's row on a hashtag's About (#318, F10): at which source, whether the reader
/// follows the hashtag there as the source last said, and Follow where it is not — or, where it
/// is, the row's `…` with Unfollow in it, as a person's page has it — or, where the sign-in
/// does not hold who the reader follows, how it stands, dim with the lock.
///
/// It draws what it is handed and asks nothing: the asking and the press are
/// `ShellTagFollow`'s.
struct TagFollowRow: View {
    let line: TagFollowLine
    var onPress: () -> Void
    /// The item of the `…` that unfollows.
    var onUnfollow: () -> Void = {}
    var onAsk: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tagAboutProbe) private var probe

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if line.isLocked {
                locked
            } else {
                WordsThenPress(words: words, press: press)
            }
            if let missed = line.missedWords() {
                // A press that did not arrive, in full ink under the line it left as it was.
                Text(missed)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.bottom, ShellSpace.snug)
            }
        }
    }

    private var words: some View {
        Text(line.words())
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .accessibilityAddTraits(line.offers == nil ? .updatesFrequently : [])
    }

    /// The row's press — follow, or ask again — or, where it is followed, its `…`, which holds
    /// unfollowing: no press stands for it on the row.
    @ViewBuilder
    private var press: some View {
        if let word = line.pressWords() {
            let spoken = line.pressSpoken() ?? word
            ShellLinkButton(word, action: onPress)
                .accessibilityLabel(spoken)
                .help(spoken)
                .fixedSize()
                .background(drawn { $0.presses[line.host] = word })
        } else if line.offers == .unfollow {
            let label = line.moreLabel()
            ShellMoreButton(label: label, more: menu)
                .fixedSize()
                .background(drawn { $0.menus[line.host] = label })
        }
    }

    /// Tells a hosted About's probe what was drawn. Nothing in the app.
    private func drawn(_ record: @escaping (TagAboutProbe) -> Void) -> some View {
        GeometryReader { _ in
            let _ = probe.map(record)
            Color.clear
        }
    }

    /// The `…`, built when it is opened: its one item unfollows, and only that.
    private func menu() -> ShellMore {
        line.more(act: onUnfollow) ?? ShellMore(items: [])
    }

    /// How the sign-in stands, dim, after the glyph a source's row draws where its sign-in
    /// must be asked again: the whole line is the press where it asks, and words where not.
    @ViewBuilder
    private var locked: some View {
        let label = Label(line.words(), systemImage: SourceRow.permissionSymbol)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.markDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
        if line.offers == .ask {
            Button(action: onAsk) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(L10n.t("mark.dim.askAgain"))
        } else {
            label
        }
    }
}

/// The tags in a line of words, offered to VoiceOver as actions on the element the reader lands
/// on — the press a finger makes on the pill, for a reader who makes none (#124). `LinkWays`'s
/// reason, for a tag.
struct TagWays: View {
    let tags: [PostTag]
    let pressing: ShellTags?
    let row: String?

    var body: some View {
        if let pressing {
            ForEach(tags, id: \.self) { tag in
                Button(String(format: L10n.t("link.open.here"), tag.text)) {
                    pressing.press(tag, from: row)
                }
            }
        }
    }
}
