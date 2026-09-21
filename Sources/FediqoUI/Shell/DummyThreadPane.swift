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
    /// Where the conversation around a microblog post is kept — the other half of the same
    /// question, for the sources that answer it in one request (#90).
    let conversations: ShellConversations
    /// The reader pressing for the conversation again, after one that could not be had. The ask
    /// itself is the pane above's, which is the one place that has the session to ask through.
    var onAskAround: () -> Void = {}
    @Binding var selectedID: String?
    var marks: (DummyItem) -> Binding<DummyMarks>
    @Binding var decks: ShellDecks
    /// What is playing, and the one player in the app. See `ShellPlayback`.
    let playback: ShellPlayback
    /// A press on a card's own play mark, which the root answers under the same rule as `a`.
    var onPlayRow: (DummyItem) -> Void
    /// A press on a card, and on the counter in its corner: `v` and `m` (#33).
    var onViewRow: (DummyItem) -> Void
    var onTurnRow: (DummyItem) -> Void
    /// A second press on the row the lamp is already on: `Return`, which from inside a thread
    /// opens the conversation around the reply that was pressed. See `DummyCommand.tapped`.
    /// The press carries the post it means, for the reason `TimelinePane.onOpenThread` gives.
    var onOpenThread: (String) -> Void
    var jumpToTop: Int
    var onToast: (String) -> Void
    var onBack: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private let step: CGFloat = 16
    /// How many steps a reply is indented by at most — **the conversation's depth, not a
    /// quotation's**. `DiscuzQuotation.deepest` is the other ceiling in this feature and counts
    /// a different tree in different units; the two are unrelated and neither derives from the
    /// other, which is worth the longer name to say.
    private let deepestIndent = 4

    /// What this pane draws: the conversation the source handed back, or this post alone until
    /// one has. Built each pass rather than held, for `ShellConversationStanding.loaded`'s reason.
    private var conversation: DummyConversation { conversations.conversation(around: root) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ShellSpace.snug) {
                Button(action: onBack) {
                    Label(L10n.t("thread.back"), systemImage: "chevron.left")
                        .shellFont(.meta, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                Text(L10n.t("thread.title"))
                    .shellFont(.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Spacer()
                outward
                Text(L10n.t("thread.leaveHint"))
                    .shellFont(.meta)
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
                        if let thread {
                            rest(of: thread)
                        } else {
                            around
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                }
                .scrollIndicators(.never)
                .onAppear {
                    guard let id = DummyCommand.centredOnAppear(selected: selectedID, opening: root.id)
                    else { return }
                    // A tick later: a lazy stack just built has not laid out the row to scroll to.
                    Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
                }
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

    // MARK: - Out of the app, and on purpose

    /// **Where this post actually lives** — the reader's "give a interactive button to open the
    /// native browser of the original link".
    ///
    /// ## Why it is here and not on the row
    ///
    /// Three reasons, and they are the same three that put the way in to the replies in this pane
    /// rather than on the row.
    ///
    /// 1. *`Note.url` names a thread, and this pane is the thread.* On a timeline row it would be
    ///    a control for somewhere the reader has not decided to go yet; here it is a control for
    ///    the thing they are looking at.
    /// 2. *The row is four fixed bands and one height.* A fifth mark in the marks band is a
    ///    control multiplying, which is the thing this branch keeps writing down that it will not
    ///    do — and it would be forty of them down a list, each one a way out of the app.
    /// 3. *Leaving the app is not something to do by accident.* Forty small glyphs under a pointer
    ///    are forty chances to; one control, in a header the reader navigated to deliberately, is
    ///    none. It sits beside `Back` and `Esc or q` — the bar that is already about leaving —
    ///    rather than among the marks that act on the post.
    ///
    /// ## Why it names the host
    ///
    /// "Open in browser" tells the reader what will happen and not where they will end up. The
    /// host is the fact that matters about an outward link, it is the fact a reader checks before
    /// following one, and it is the one thing this app knows for certain — `source.host` is
    /// parsed, and not lifted from anybody's markup.
    ///
    /// ## What is refused
    ///
    /// **`Host.allowsFetch`, at a boundary that is not a fetch**, and that is deliberate rather
    /// than sloppy naming: it is `Host.isFetchable` re-exported, decision 9's "this device will
    /// go there" — `https`, and a host to reach — and handing a `URL` to the system browser is
    /// exactly as much of a wire boundary as handing one to `URLSession`. `URL(string:)` will
    /// build `javascript:`, `data:` and `file:///` out of a stranger's JSON, and `openURL` would
    /// do as it was told with any of them.
    ///
    /// Core admits the address at ingestion and this admits it again at the door. That is belt and
    /// braces on purpose and not the convention this branch warns about: the rule is *in the
    /// data* — `Mastodon` and `Discuz` both build `Note.url` through it — and this is a second
    /// reading of the same one function, not a second expression of the rule.
    ///
    /// **The reading itself now lives at `DummyItem.outwardURL`**, because the row grew the same
    /// way out and two surfaces spelling the check separately is how one of them comes to be
    /// spelled differently. The sentence on the button comes from `outwardName` for the same
    /// reason. Everything this comment says is still true; it is true in one place.
    ///
    /// **No button at all where the address does not pass**, rather than a disabled one. A
    /// control the reader cannot press is a question about this app; nothing is the honest answer
    /// to "this post named nowhere to go".
    @ViewBuilder
    private var outward: some View {
        if let url = root.outwardURL {
            Button {
                openURL(url)
            } label: {
                Label(root.outwardName, systemImage: "arrow.up.forward.app")
                    .shellFont(.meta, weight: .medium)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShellChrome.selectInk(colorScheme))
            .help(String(format: L10n.t("thread.open.hint"), url.absoluteString))
            .accessibilityHint(Text(L10n.t("thread.open.leaves")))
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
            // **Every row in this pane, not only the root.** The pane is the place a post is read
            // rather than scanned, which is as true of a post the reader arrived through as of
            // the one they opened — and a rule that held only for the middle row would be one
            // more thing to remember. `ForumReplyRow` below has said the same since F6.
            inFull: true,
            top: decks.top(of: item.id, of: item.attachments.count),
            lifted: decks.isLifted(item.id),
            player: player(of: item),
            // The same one rule the stream's rows read: a press lights the row, and a second
            // press on the row already lit is `Return` (#33).
            onSelect: {
                switch DummyCommand.tapped(item.id, selected: selectedID) {
                case .select: selectedID = item.id
                case .open: onOpenThread(item.id)
                }
            },
            // **Nothing on the post this pane is already about.** Opening it again is refused —
            // `FediqoRootView.openThread` says so — and an action announced and then refused is
            // worse than one never announced.
            onOpen: item.id == root.id ? nil : { onOpenThread(item.id) },
            onToggleCover: { _ = decks.toggleCover(item.id) },
            onPlay: { onPlayRow(item) },
            onView: { onViewRow(item) },
            onTurn: { onTurnRow(item) },
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
                way(in: thread)
            case .coming:
                // **The reader pressed something and is owed a sign that it took.** A static
                // "Loading the replies…" is indistinguishable from the same sentence a minute
                // later, which is what the reader wrote in about first. See `ForumWaiting`.
                ForumWaiting(line: L10n.t("thread.replies.loading"))
            case .none:
                if let notice = EmptyNotice.thread(
                    descendantCount: 0,
                    replyCount: 0,
                    standing: ForumRepliesStanding.none
                ) {
                    ShellNotice(notice)
                }
            case .loaded(let replies):
                Text(String(format: L10n.t("thread.replies.count"), replies.count))
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                ForEach(replies) { reply in
                    ForumReplyRow(post: reply, host: thread.host)
                }
            case .absent(let absence):
                quiet(ForumPostBand.sentence(for: absence))
                if standing.wantsPressing { way(in: thread) }
            }
        }
        .padding(.top, ShellSpace.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The conversation around a microblog post — #90

    /// What is under the post where the source answers for a whole thread in one request.
    ///
    /// **The mirror of `rest(of:)`, and deliberately not the same view.** A forum topic's
    /// replies are a list this pane draws itself, under a rule of their own; a microblog's
    /// answers *are* rows of this conversation and are already drawn above, nested, by the same
    /// `threaded(_:dimmed:)` every other post in the pane goes through. So what is left down
    /// here is only what the rows cannot say: that the thread is still coming, that it could not
    /// be had, or that there is genuinely nobody else in it.
    ///
    /// **`unasked` waits rather than saying "nothing".** The ask is the pane opening — one turn
    /// away, not a state the reader can be left in — and drawing the empty notice for that turn
    /// would say "nothing under this post" about a post whose thread is about to arrive.
    /// `ShellConversations` never leaves a standing unasked once it has looked at a post: a
    /// source with no conversation to read is settled as `none` there rather than left waiting
    /// here, which is what makes this branch safe.
    ///
    /// **No `default:`.** A sixth standing has to be given a shape.
    @ViewBuilder
    private var around: some View {
        switch conversations.standing(of: root.id) {
        case .unasked, .coming:
            ForumWaiting(line: L10n.t("thread.replies.loading"))
                .padding(.top, ShellSpace.snug)
        case .none:
            // The forum's own sentence for the same fact, so one thing is worded one way: the
            // post arrived, the source answered, and nobody has said anything under it. It is
            // told over `root.counts.replies`, which is the server's own count and may claim
            // answers this reader is not allowed to see.
            if let notice = EmptyNotice.thread(
                descendantCount: 0, replyCount: 0, standing: ForumRepliesStanding.none
            ) {
                ShellNotice(notice)
            }
        case .loaded:
            // The answers are the rows above. Nothing belongs down here.
            EmptyView()
        case .absent(let absence):
            let standing = conversations.standing(of: root.id)
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                quiet(absence.sentence(host: root.source.host))
                if standing.wantsPressing { wayAround }
            }
            .padding(.top, ShellSpace.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The way in to the thread again — `way(in:)`'s twin, and the same bargain: drawn exactly
    /// where `ShellConversationStanding.wantsPressing` is true, so a reader never finds a button
    /// for an answer that cannot change.
    ///
    /// No key cap beside it. `s` is the forum's press and means the rest of a topic that was
    /// never asked for; this is a second attempt at one that was, and giving it the same cap
    /// would teach the letter for a thing it does not do here.
    private var wayAround: some View {
        Button(action: onAskAround) {
            Label(L10n.t("thread.around.again"), systemImage: "arrow.clockwise")
                .shellFont(.meta, weight: .medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShellChrome.selectInk(colorScheme))
    }

    /// The way in to the rest of the topic — **the pointer's half of the key `s`**.
    ///
    /// The mark and the key are one rule and not two: this is drawn exactly where
    /// `ForumRepliesStanding.wantsPressing` is true, and that is the second half of what
    /// `DummyCommand.reveal(hasCover:repliesWanted:)` reads, so a reader cannot find a button the
    /// key will not press or press a key on a state that offers no button. That is this branch's
    /// own arrangement for `a` and the card's play mark, stated in `FediqoRootView.playRow`.
    ///
    /// The key cap is drawn beside the words. A reader who has never opened the guide finds the
    /// shortcut at the moment they are looking for the thing it does, which is the only moment it
    /// is worth telling them — and this is the post whose cover `s` would otherwise be for, so
    /// seeing the cap here is also how they learn that on a forum it is free.
    private func way(in thread: ForumThreadRef) -> some View {
        Button {
            Task { await posts.fetchReplies(thread) }
        } label: {
            HStack(spacing: ShellSpace.snug) {
                Label(L10n.t("thread.replies.load"), systemImage: "arrow.down.circle")
                    .shellFont(.meta, weight: .medium)
                Text(verbatim: "s")
                    .shellFont(.mark, monospaced: true)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .padding(.horizontal, ShellSpace.tight)
                    .background(
                        RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous)
                            .fill(ShellChrome.well(colorScheme))
                    )
                    // The cap is a hint for the eye; a screen reader is already told the key by
                    // the guide, and a lone letter read out in the middle of a label is noise.
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShellChrome.selectInk(colorScheme))
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func indent(_ depth: Int) -> CGFloat {
        CGFloat(min(depth, deepestIndent)) * step
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
    /// The forum this reply was read through — what the reader's per-server Clear button reaches
    /// its picture by. Handed in because a `DiscuzPost` carries a `tid` and not a host, and
    /// because an avatar address is often on a different machine entirely.
    let host: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    /// How big a reply's picture is drawn.
    ///
    /// **Smaller than the row's 36pt, on purpose.** A reply is not a thread: the pane's one
    /// `DummyItemRow` at the top is what the reader opened, and twenty replies each carrying a
    /// full-size avatar would read as twenty more of those. Scaled with the type, for the reason
    /// every other fitting in this shell is — the alternative is big text beside small furniture.
    @ShellMetric(relativeTo: .body) private var side: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: ShellSpace.snug) {
            avatar
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                who
                // **Keyed by position, because a quotation has no id and does not need one.**
                // Nothing reorders this list: it is the order the page wrote, read once, and
                // rebuilt whole whenever the post is. Over the indices rather than over
                // `enumerated()`, which would allocate a fresh array of pairs every time a body
                // is evaluated to arrive at the same identity.
                ForEach(post.quoted.indices, id: \.self) { level in
                    ForumQuotation(quotation: post.quoted[level])
                }
                words
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ShellSpace.tight)
        .wayOut(named: DummyItem.wayOutName(host: host), to: outwardURL)
        // **On the row itself, and that is safe here where it would not be on a timeline row.**
        // This reply is `.combine`d into one element rather than being a container, so a custom
        // action put here is offered to the element a reader actually lands on. `DummyItemRow`
        // has to hang its action on the headline for exactly the opposite reason.
        .accessibilityElement(children: .combine)
        .accessibilityActions { outwardAction }
        // **Here rather than inside the words**, for `SpokenLinks`' reason: `.combine` above
        // makes this reply one element, and what its children offered goes with the rest of them.
        .spokenLinks(in: post.isWithheld ? "" : post.body)
    }

    // MARK: - The way out

    /// Where this reply lives on the forum, or nothing where it cannot be addressed honestly.
    ///
    /// **Built in Core out of two integers and a parsed host** — `DiscuzPost.url(onHost:)`, which
    /// is where the reasoning lives, including why the post's own `#pid` anchor resolves and the
    /// one change that would stop it resolving. Nothing is read out of the page: a Discuz! reply
    /// has no address in this app that a stranger's markup contributed to.
    ///
    /// **Why a reply gets this at all.** The reader asked for a way to open a thread or post on
    /// the web, and a reply is a post they are reading. Without it, a reader inside a forum thread
    /// sees the opening post offering a way out and twenty replies beneath it offering nothing,
    /// which reads as an oversight rather than as a decision — and it would be one.
    ///
    /// **Checked here as well as in `WayOut`, because this property has a second reader.**
    /// `outwardAction` and `openOutward` are the VoiceOver path and never pass through the
    /// modifier, so a check that lived only there would cover the context menu and not the rotor.
    /// `DiscuzPost.url(onHost:)` applies `Host.isFetchable` of its own accord — a guarantee two
    /// files away that nothing at this site stated.
    private var outwardURL: URL? {
        guard let url = post.url(onHost: host), Host.allowsFetch(url) else { return nil }
        return url
    }

    /// The way out, as a reader using VoiceOver reaches it. A context menu is a gesture; this is
    /// for the reader who makes neither of the two gestures that open one.
    @ViewBuilder
    private var outwardAction: some View {
        if outwardURL != nil {
            Button(DummyItem.wayOutName(host: host)) { openOutward() }
        }
    }

    /// Leaves the app for the forum this reply was read from. Named, not a closure, for the
    /// reason `DummyItemRow.openOutward` is: this milestone's three wiring defects all lived
    /// where no test could call them.
    private func openOutward() {
        guard let url = outwardURL else { return }
        openURL(url)
    }

    /// Whoever wrote this reply, drawn.
    ///
    /// **The picture came off the page the words came off**, which is the whole reason a reply can
    /// have one at all: `DiscuzClient.replies(tid:)` reads the thread page, and every template
    /// that writes an avatar writes it beside the post it belongs to. No second request, and no
    /// address guessed out of a uid.
    ///
    /// The plate where there is none, exactly as the row draws it — and there are three ways to
    /// have none, all of them measured: the member uploaded nothing and the forum serves its
    /// `noavatar` placeholder, the forum has hidden the picture (`頭像被屏蔽`, three posts in ten
    /// on one `install-d.example` thread), or the template writes its avatars in with JavaScript and
    /// there was nothing on the page to read.
    @ViewBuilder
    private var avatar: some View {
        Group {
            if let url = post.avatarURL {
                RemoteImage(
                    url: url,
                    tier: .deck,
                    // **The forum this reply was read through, never the address's own host.**
                    // Decision 14: the Clear button can only ever name a server the reader added,
                    // and `install-d.example` serves its avatars off `avatars-d.example` — filing them under
                    // that would make exactly the entry no Clear can reach that I10 exists to
                    // prevent. The same rule, and the same wording, as `DummyItemRow.avatar`.
                    host: host,
                    standing: .avatar,
                    alt: nil,
                    speaks: false,
                    radius: ShellSpace.tight
                )
            } else {
                RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous)
                    .fill(ShellChrome.well(colorScheme))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
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
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
            Text(post.author)
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
            if let at = post.postedAt {
                Text(at, format: .relative(presentation: .named))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
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
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        } else if post.body.isEmpty {
            // The forum answered, the post was not withheld, and there were no words in it: a
            // picture, an attachment, a poll. Nothing drawn, for the reason `ForumPostBand` draws
            // nothing in the same case — a sentence here would be this app talking over somebody
            // who posted a photograph.
            EmptyView()
        } else {
            // Prose with no picture list, exactly as `ForumPostBand` draws the opening post: a
            // forum sends no custom emoji, and an address in a reply is one a reader wants to
            // follow. The font is the same token — `EmojiTextRole.body` is `ShellType.body`.
            EmojiText(prose: post.body, emojis: [], host: host)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// What a reply reproduced of somebody else's, drawn as a quotation — **and, where they quoted
/// somebody in turn, that one inside it** (#94).
///
/// Core keeps a quotation out of `body` and keeps it rather than dropping it, and says why: a
/// reply that opens by quoting the whole post above it would fill the words with a stranger's
/// sentence and never show its own. Drawn behind a rule and dimmed, so whose words are whose is
/// a thing the reader can see rather than infer.
///
/// ## Why this is a type and not a function
///
/// It draws itself. A `private func quotation(_:) -> some View` that called itself would be an
/// opaque return type defined in terms of itself, which does not compile — the recursion has to
/// go through a nominal type, and this is it. The same shape `DummyThreadPane` uses for its own
/// nesting one level up, where `threaded(_:dimmed:)` indents by a depth the conversation
/// carries; here the depth **is** the view tree, because a quotation's depth is its structure
/// rather than a number beside it.
///
/// ## One rule per level, and it is the same rule
///
/// Each level gets its own rule and its own inset, so three nested quotations read as three
/// rules stepping right rather than as one border drawn thicker. The inset is `ShellSpace.snug`
/// at every level rather than growing: the rules are what say how deep this is, and a widening
/// step would run a deep quotation off a phone's screen for no more information.
///
/// **No cap here.** `DiscuzQuotation.deepest` bounds the tree where it is read, so what arrives
/// is already shallow enough to draw; a second ceiling in the view would be a rule that could
/// disagree with the one in Core.
///
/// ## What it says out loud
///
/// Every level carries the same "Quoted: …" label over its own words, so a reader using
/// VoiceOver hears each person's sentence introduced as a quotation instead of one label over
/// everybody's. A level that is only a wrapper — words empty, one quotation inside it, which
/// some templates write — draws no text and no label, only its rule.
struct ForumQuotation: View {
    let quotation: DiscuzQuotation

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            if !quotation.words.isEmpty {
                Text(quotation.words)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        Text(String(format: L10n.t("thread.reply.quoted"), quotation.words))
                    )
            }
            ForEach(quotation.quoting.indices, id: \.self) { level in
                ForumQuotation(quotation: quotation.quoting[level])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, ShellSpace.snug)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(width: ShellSpace.hair)
        }
    }
}
