import AVKit
import FediqoCore
import SwiftUI

/// The conversation around one item: the way up, the post, then answers related-on.
struct DummyThreadPane: View {
    let root: DummyItem
    /// Passed through to every row: a thread draws the same four bands the stream does, and its
    /// names, words and cover lines are somebody else's writing in exactly the same way.
    let catalogues: EmojiCatalogueStore
    /// Passed through with the store: the pane above owns the wait for this source's catalogue.
    /// A thread is one post's conversation, so every row in it reads through the same server.
    var catalogueSettled: Bool = false
    /// Where the opening post and the rest of the topic are kept. Passed through to every row,
    /// and read here for D31's list.
    let posts: ForumPosts
    @Binding var selectedID: String?
    var marks: (DummyItem) -> Binding<DummyMarks>
    @Binding var decks: ShellDecks
    /// What is playing, and the one player in the app. See `ShellPlayback`.
    let playback: ShellPlayback
    /// A press on a card's own play mark, which the root answers under the same rule as `a`.
    var onPlayRow: (DummyItem) -> Void
    var jumpToTop: Int
    var onToast: (String) -> Void
    var onBack: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let step: CGFloat = 16
    private let deepest = 4

    private var conversation: DummyConversation { root.dummyConversation() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ShellSpace.snug) {
                Button(action: onBack) {
                    Label(L10n.t("thread.back"), systemImage: "chevron.left")
                        .font(ShellType.meta.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                Text(L10n.t("thread.title"))
                    .font(ShellType.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Spacer()
                Text(L10n.t("thread.leaveHint"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(conversation.ancestors) { above in
                            threaded(above, dimmed: true)
                        }
                        threaded(conversation.post, dimmed: false)
                        ForEach(conversation.descendants, id: \.item.id) { entry in
                            threaded(entry.item, dimmed: false)
                        }
                        if let thread { rest(of: thread) }
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: jumpToTop) { _, _ in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(conversation.post.id, anchor: .top)
                    }
                }
            }
        }
    }

    private func threaded(_ item: DummyItem, dimmed: Bool) -> some View {
        let depth = conversation.depth(of: item.id)
        return DummyItemRow(
            item: item,
            catalogues: catalogues,
            catalogueSettled: catalogueSettled,
            posts: posts,
            marks: marks(item),
            selected: item.id == selectedID,
            top: decks.top(of: item.id, of: item.attachments.count),
            lifted: decks.isLifted(item.id),
            player: player(of: item),
            onSelect: { selectedID = item.id },
            onToggleCover: { _ = decks.toggleCover(item.id) },
            onPlay: { onPlayRow(item) },
            onEnded: { playback.stop() },
            onToast: onToast
        )
        .opacity(dimmed ? 0.85 : 1)
        .padding(.leading, indent(depth))
        .overlay(alignment: .leading) { rail(depth) }
        .id(item.id)
    }

    /// The player for this row's slot, where this row's card is the thing that is playing.
    private func player(of item: DummyItem) -> AVPlayer? {
        playback.player(
            for: ShellPlaying.playable(decks.showing(item.attachments, of: item.id)),
            of: item.id,
            on: .row
        )
    }

    // MARK: - The rest of the topic — D31

    /// The thread this pane is standing on, where it is a Discuz! one there is more of to read.
    private var thread: ForumThreadRef? { ForumThreadRef(root) }

    /// **Where "load other threads" lives, and why it is here rather than on the row.**
    ///
    /// The reader asked for "the options to load other threads" and, asked directly, said that
    /// "other threads" means the replies of the same topic — D31. That leaves one question, which
    /// is where the way in goes: the row, or this pane.
    ///
    /// **This pane, for three reasons that all point the same way.**
    ///
    /// 1. *The row is four fixed bands and one height.* That invariant is the row's whole design
    ///    and it is a defence as much as a look — a hostile instance sizing a row is a layout
    ///    attack that lands on every row of a timeline at once. Twenty replies of unbounded
    ///    length cannot go in it, and a control in it that opened them somewhere else would be a
    ///    second door to the place `Return` already goes.
    /// 2. *There is already a door, and the reader already knows it.* `Return` and `Space` mean
    ///    expand — `DummyCommand.expandPost` — and this pane is what they open. Adding a key or a
    ///    button for "the rest of this topic" would be a second way to say the same thing, and
    ///    this branch's own rule is that keys do not navigate implicitly and controls do not
    ///    multiply.
    /// 3. *This pane was built to draw answers and draws none.* Its own doc says "the way up, the
    ///    post, then answers", and `DummyItem.dummyConversation()` hands it an empty list because
    ///    fetching a conversation was out of the branch that wrote it. A forum thread is the
    ///    first thing this app has ever had real answers for.
    ///
    /// **Pressed, not automatic**, which is the other half of D31. Opening a thread already costs
    /// a request for the page the opening post came off — `post(tid:)` and `replies(tid:)` each
    /// fetch it for themselves, which is Core's shape and is recorded for the plan rather than
    /// worked around here. So the reader gets the topic they opened and asks for the rest of it
    /// if they want it, which is the same bargain the row makes one level up.
    @ViewBuilder
    private func rest(of thread: ForumThreadRef) -> some View {
        // Read in `body`, so this pane's interest in the replies is stamped on every pass. I8.
        let standing = posts.standing(of: thread)
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)
            // **No `default:`.** A sixth standing has to be given a shape here.
            switch standing {
            case .unasked:
                Button {
                    Task { await posts.fetchReplies(thread) }
                } label: {
                    Label(L10n.t("thread.replies.load"), systemImage: "arrow.down.circle")
                        .font(ShellType.meta.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
            case .coming:
                quiet(L10n.t("thread.replies.loading"))
            case .none:
                quiet(L10n.t("thread.replies.none"))
            case .loaded(let replies):
                Text(String(format: L10n.t("thread.replies.count"), replies.count))
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                ForEach(replies) { reply in
                    ForumReplyRow(post: reply)
                }
            case .absent(let absence):
                quiet(ForumPostBand.sentence(for: absence))
            }
        }
        .padding(.top, ShellSpace.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(ShellType.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func indent(_ depth: Int) -> CGFloat {
        CGFloat(min(depth, deepest)) * step
    }

    @ViewBuilder
    private func rail(_ depth: Int) -> some View {
        if depth > 0 {
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(width: ShellSpace.hair)
                .padding(.leading, indent(depth) - ShellSpace.snug)
                .padding(.vertical, 6)
        }
    }
}

/// One reply of a forum topic — D31's payload.
///
/// **Not a `DummyItemRow`, and that is a decision rather than a shortcut.** A reply is not the
/// same object as a thread: it has a floor, it may quote somebody, it has no title, no board, no
/// attachment deck and no marks, and — on one of the four measured installs — it usually has no
/// words at all, because a signed-out reader is shown the forum's notice instead. Dressing it as
/// a `DummyItem` would mean inventing a `Note` in the UI layer to satisfy a row built for a
/// timeline, and every one of those five differences would have to be thrown away to do it.
///
/// **It is not held to one height either, and that is also deliberate.** The timeline's one-height
/// rule is about a list the reader is scrolling, where a row that grows moves everything under
/// the thumb. This pane is what the reader opened in order to *read*, its contents arrive in one
/// answer to one press rather than a row at a time, and truncating the replies would be the
/// complaint this whole unit exists to answer, one level down.
struct ForumReplyRow: View {
    let post: DiscuzPost
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            who
            if let quoted = post.quoted, !quoted.isEmpty { quotation(quoted) }
            words
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ShellSpace.tight)
        .accessibilityElement(children: .combine)
    }

    /// Who wrote it, which floor it is, and when — each drawn only where the page said.
    ///
    /// **A figure the forum did not state draws nothing, never a zero**, which is this branch's
    /// standing rule and is unusually live here: the mobile template writes `昨天 22:48` with no
    /// machine-readable date, so `postedAt` is `nil` far more often on a post than on a thread
    /// row, and a floor is missing entirely on the third-party template `install-a.example` serves.
    private var who: some View {
        HStack(spacing: ShellSpace.snug) {
            if let floor = post.floor {
                Text(String(format: L10n.t("thread.reply.floor"), floor))
                    .font(ShellType.reading)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
            Text(post.author)
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
            if let at = post.postedAt {
                Text(at, format: .relative(presentation: .named))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// What this reply reproduced of somebody else's, drawn as a quotation.
    ///
    /// Core keeps it out of `body` and keeps it rather than dropping it, and says why: a reply
    /// that opens by quoting the whole post above it would fill the words with a stranger's
    /// sentence and never show its own. Drawn behind a rule and dimmed, so whose words are whose
    /// is a thing the reader can see rather than infer.
    private func quotation(_ text: String) -> some View {
        Text(text)
            .font(ShellType.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, ShellSpace.snug)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(ShellChrome.hairline(colorScheme))
                    .frame(width: ShellSpace.hair)
            }
            .accessibilityLabel(Text(String(format: L10n.t("thread.reply.quoted"), text)))
    }

    /// The three things a reply's words can be, and they are three rather than two.
    ///
    /// **Withheld is not empty.** `install-a.example` answers a signed-out reader
    /// `游客请登录后查看回复内容` for 19 replies in 20, and Core marks that rather than putting the
    /// forum's sentence in `body` under this person's name. If this drew nothing for it, the row
    /// would say that nineteen people wrote nothing — which is false about all nineteen of them,
    /// and is the reader being quietly told the forum is empty when what happened is that they
    /// are not signed in to it.
    @ViewBuilder
    private var words: some View {
        if post.isWithheld {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                Image(systemName: "lock")
                Text(L10n.t("item.forum.withheld"))
            }
            .font(ShellType.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        } else if post.body.isEmpty {
            // The forum answered, the post was not withheld, and there were no words in it: a
            // picture, an attachment, a poll. Nothing drawn, for the reason `ForumPostBand` draws
            // nothing in the same case — a sentence here would be this app talking over somebody
            // who posted a photograph.
            EmptyView()
        } else {
            Text(post.body)
                .font(ShellType.body)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
