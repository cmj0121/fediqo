import FediqoCore
import SwiftUI

// A hashtag, pressed (#124): the posts this device holds under it.
//
// #123 drew a tag as a pill and deliberately gave it no press, because there was nothing for one
// to open. This version has it: a tag is a query of the store like every other screen, so what it
// opens is the posts already here that carry it — those every timeline draws and those held aside
// alike — and a source of the timeline in front that can be asked for more under it is asked, and
// what it brings is held aside in the store first (`ShellReload.tag`). What is drawn is never a
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
    static func held(under tag: PostTag, in notes: [Note], sent: Set<NoteKey> = []) -> [DummyItem] {
        let name = folded(tag)
        return notes.filter { note in
            sent.contains(note.key) || PostTag.found(in: note.body).contains { folded($0) == name }
        }
            .sorted { $0.postedAt > $1.postedAt }
            .map(DummyItem.init)
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
    }

    let key: Key
    let items: [DummyItem]
}

/// A hashtag, opened: what this device holds under it, and what its sources were asked (#124).
///
/// The person page's shape — a way back, a heading, a list — for the person page's reason: it is
/// a page of rows opened from a row, and a reader who has learnt to leave one has learnt to leave
/// this. **Unlike that page, this one may ask.** What a source sends under the tag lands in the
/// store and the list renews from it; while it is on its way, and where it failed, that is said
/// here, where the answer would have been, with a way to ask again.
struct TagPane: View {
    let tag: PostTag
    /// What this device holds under it, newest first — `ShellSession.heldPosts(under:)`.
    let items: [DummyItem]
    /// The sources being asked now, or nothing.
    var asking: [String] = []
    /// The sources the last ask could not reach.
    var failed: [String] = []
    /// Which of the timeline's sources were asked and why the rest were not (#197), or nothing.
    var reach: String?
    let catalogues: EmojiCatalogueStore
    var catalogueSettled: Bool = false
    let posts: ForumPosts
    @Binding var selectedID: String?
    var marks: (DummyItem) -> Binding<DummyMarks>
    var acting: (DummyItem) -> ItemActing = { _ in ItemActing() }
    @Binding var decks: ShellDecks
    let playback: ShellPlayback
    var onPlayRow: (DummyItem) -> Void
    var onViewRow: (DummyItem) -> Void
    var onTurnRow: (DummyItem) -> Void
    var onOpenThread: (String) -> Void
    var onOpenPerson: ((DummyPerson) -> Void)?
    /// Asks the sources again, after a failure.
    var onRetry: () -> Void
    var jumpToTop: Int
    var onToast: (String) -> Void
    var onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            ShellRule()
            heading
            ShellRule()
            // Where the page's rows came from, as a search says it under its field (#197). Wraps
            // rather than truncates, since the names are the point.
            if let reach {
                Text(reach)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.vertical, ShellSpace.snug)
                ShellRule()
            }
            if let said = Self.said(asking: asking, failed: failed, tag: tag) {
                answer(said)
                ShellRule()
            }
            list
        }
    }

    /// What the ask of the sources has to say, or nothing once it has landed whole.
    enum Said: Equatable {
        case asking(String)
        case failed(String)
    }

    /// A function of what it reads, so a test can ask it without standing a pane up.
    static func said(asking: [String], failed: [String], tag: PostTag) -> Said? {
        if !asking.isEmpty {
            return .asking(String(format: L10n.t("tag.asking"), asking.joined(separator: ", "), tag.text))
        }
        if !failed.isEmpty {
            return .failed(String(format: L10n.t("tag.failed"), failed.joined(separator: ", "), tag.text))
        }
        return nil
    }

    /// The empty page's sentence: about this device, never about the tag — a page that said
    /// "nobody has used this tag" would be this app speaking for servers it did not ask.
    static func none(_ tag: PostTag) -> String { String(format: L10n.t("tag.none"), tag.text) }

    private var bar: some View {
        HStack(spacing: ShellSpace.snug) {
            ShellBackButton("person.back", action: onBack)
            Spacer()
            Text(L10n.t("person.leaveHint"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
    }

    /// The tag as it was written where it was pressed, and how much is here under it.
    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            Text(verbatim: tag.text)
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
                .accessibilityLabel(String(format: L10n.t("post.tag.spoken"), tag.name))
            Spacer(minLength: 0)
            Text(PersonPane.heldLine(items.count))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// On its way, or failed and a way to ask again: where the answer would have been.
    private func answer(_ said: Said) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            switch said {
            case .asking(let line):
                Text(line)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            case .failed(let line):
                Text(line)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.t("tag.retry"), action: onRetry)
                    .buttonStyle(.plain)
                    .shellFont(.meta, weight: .semibold)
                    .foregroundStyle(ShellChrome.selectInk(colorScheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            // Empty, and said so — never left blank under a line that has finished asking, which
            // would read as still waiting.
            if asking.isEmpty {
                Text(Self.none(tag))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(ShellSpace.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        } else {
            rows
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .id(item.id)
                        if index < items.count - 1 { ShellRule() }
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                guard let first = items.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    /// One post under the tag, drawn and pressed as a row anywhere else is.
    private func row(_ item: DummyItem) -> some View {
        DummyItemRow(
            item: item,
            catalogues: catalogues,
            catalogueSettled: catalogueSettled,
            posts: posts,
            marks: marks(item),
            acting: acting(item),
            selected: item.id == selectedID,
            top: decks.top(of: item.id, of: item.attachments.count),
            lifted: decks.isLifted(item.id),
            player: playback.rowPlayer(for: item, decks: decks),
            onSelect: {
                switch DummyCommand.tapped(item.id, selected: selectedID) {
                case .select: selectedID = item.id
                case .open: onOpenThread(item.id)
                }
            },
            onOpen: { onOpenThread(item.id) },
            onOpenPerson: onOpenPerson,
            onToggleCover: { _ = decks.toggleCover(item.id) },
            onPlay: { onPlayRow(item) },
            onView: { onViewRow(item) },
            onTurn: { onTurnRow(item) },
            onEnded: { playback.stop() },
            onToast: onToast
        )
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
