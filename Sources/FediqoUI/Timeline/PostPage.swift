import SwiftUI
import Observation
import FediqoCore

/// The conversation around one post, as it is being read.
///
/// The store answers first because it can answer now: whatever of the thread the timeline
/// already carried past us is on the screen before anything is asked of anybody. Then the
/// post's own server is asked once, and what it says is folded in — and kept, so the next
/// opening of the same post starts from a fuller store rather than a fresh request.
@MainActor
@Observable
final class ThreadModel {
    private(set) var conversation: Conversation
    private(set) var loading = false
    /// Which post in the conversation the ring is on, by `mergeKey`. It starts on the one the
    /// reader opened — they are already looking at it — and `j`/`k` walk from there.
    private(set) var selection: String
    /// Why the server could not be asked, where that happened. The thread already on screen
    /// is not taken away for it: what the store held is still true.
    private(set) var failure: SourceFailure?
    /// Whether the post this page is about has gone. **Not a failure** — a post the author
    /// deleted while the reader was looking at it is a real answer, and it must not read as a
    /// page that would not load (#125).
    private(set) var isGone = false

    /// The post this conversation is around, as it was when the reader opened it.
    ///
    /// Held rather than read back off `conversation`, because the conversation is replaced by
    /// what the store and the server say and this is the one thing about a level that must not
    /// move: it is what the page draws, and what says whether a press would open this level
    /// again rather than a new one.
    let root: Post

    private let loader: TimelineLoader
    /// Whether the two reads below have already happened for this level.
    ///
    /// The view asks when the page appears, and with a stack a page appears again every time
    /// the reader comes back down to it — so without this, walking four replies deep and back
    /// out would ask four servers a second time for conversations already on the screen.
    private var hasRead = false

    init(post: Post, loader: TimelineLoader) {
        self.root = post
        self.conversation = Conversation(post: post)
        self.selection = post.mergeKey
        self.loader = loader
    }

    /// The conversation in the order it is drawn: what is answered, the post, the answers.
    var inOrder: [Post] { conversation.ancestors + [conversation.post] + conversation.descendants }

    /// An answer the reader has just sent, put where it belongs without asking anybody again.
    ///
    /// Only where it answers something in this conversation. A reply sent from the timeline to a
    /// post that is not what this page is about belongs in somebody else's thread, and putting it
    /// here would draw an answer under a post it is not an answer to.
    func joined(by reply: Post) {
        guard inOrder.contains(where: { $0.uri == reply.inReplyToURI }) else { return }
        conversation = conversation.with(reply)
    }

    /// The post the ring is on, which is what the keys act on while this page is open.
    var selected: Post? { inOrder.first { $0.mergeKey == selection } }

    /// Puts the ring on one post of the conversation, because the reader clicked it.
    ///
    /// The same thing `FeedModel.select` is for the list, and here for the same reason: a click
    /// is the reader saying which post they mean, and every key that acts on "this post" reads
    /// the ring. Without this a reader could click a reply, press `l`, and favourite whichever
    /// post `j` had last walked to.
    func select(_ post: Post) {
        guard selection != post.mergeKey else { return }
        selection = post.mergeKey
    }

    /// Moves the ring through the conversation, and says whether it moved. It stops at both
    /// ends for the reason the timeline's does: a conversation has a top and a bottom, and
    /// wrapping from the last reply back to the first would be a jump nobody asked for.
    @discardableResult
    func move(by steps: Int) -> Bool {
        let posts = inOrder
        guard let here = posts.firstIndex(where: { $0.mergeKey == selection }) else {
            selection = posts.first?.mergeKey ?? selection
            return !posts.isEmpty
        }
        let landing = min(max(here + steps, 0), posts.count - 1)
        guard landing != here else { return false }
        selection = posts[landing].mergeKey
        return true
    }

    /// The store, then the server. Both, in that order, and only once per opening.
    func read() async {
        guard !hasRead else { return }
        hasRead = true
        conversation = await loader.storedThread(around: conversation.post)
        loading = true
        let asked = await loader.conversation(around: conversation.post)
        failure = asked.failure
        if asked.failure == nil { conversation = conversation.merged(with: asked.conversation) }
        loading = false
    }

    /// What all of this says now, asked because the reader asked (#125).
    ///
    /// **Both halves, because both are on the screen.** The post's own status carries the counts
    /// and the words as they stand after an edit; the conversation carries every reply, which is
    /// what the rest of the page is. `context` is one call for all of them rather than one call
    /// per post.
    ///
    /// Nothing here is on a clock. This is a reader asking what a post says at this moment, and
    /// a page that polled would be telling somebody else's server how long somebody sat here.
    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }

        let again = await loader.reread(conversation.post)
        if again.gone {
            isGone = true
            failure = nil
            return
        }
        isGone = false
        // The conversation second and regardless: a post that could not be re-read may still
        // have replies that can be, and half the page arriving beats none of it.
        let asked = await loader.conversation(around: again.post ?? conversation.post)
        failure = again.failure ?? asked.failure
        var next = asked.failure == nil ? conversation.merged(with: asked.conversation) : conversation
        if let fresh = again.post { next = next.replacing(fresh) }
        conversation = next
    }
}

/// A post, opened: the whole of it, and the conversation it sits in.
///
/// A place you go to and come back from. It arrives over the timeline rather than replacing
/// it, `Escape` closes it, and the list underneath keeps its scroll position and its ring —
/// which is the whole reason it is drawn this way rather than as a screen you navigate to.
struct PostPage: View {
    let post: Post
    let done: () -> Void

    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    /// The app holds it rather than this view, because the keys are answered outside the view
    /// that draws it — the same reason `expanded` itself lives there.
    private var model: ThreadModel? { app.thread }

    var body: some View {
        ScrollViewReader { rows in
            VStack(spacing: 0) {
                header
                Hairline()
                thread
            }
            .onChange(of: model?.selection) { _, key in
                guard let key else { return }
                withAnimation(Motion.appearing) { rows.scrollTo(key, anchor: .center) }
            }
            // Measured for the widest column on the page, which is the opened post's, and with
            // the deepest indent taken off — the reply furthest in has the least room and is the
            // one that has to fit (#121).
            .fediqoMeasuresRows(rowsInsetBy: Space.gap + Self.deepestIndent / 2,
                                card: Size.openedCard)
        }
        .background(Palette.surface(colorScheme))
        .task(id: post.mergeKey) { await app.thread?.read() }
    }

    /// A run told to open the page about this post does it once it has one. The same shape
    /// every other launch variable has, and the same reason (#30).
    private var openingAbout: some View {
        Color.clear.frame(width: 0, height: 0)
            .task {
                guard app.launchedOnAbout, app.about == nil else { return }
                app.openAbout(model?.conversation.post ?? post)
            }
    }

    private var header: some View {
        HStack(spacing: Space.mid) {
            Button(action: done) {
                Label(t("post.back"), systemImage: "chevron.left")
                    .fediqoFont(TypeScale.small, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .keyboardShortcut(.escape, modifiers: [])

            Text(t("post.title")).fediqoFont(TypeScale.lead, weight: .semibold)
            if model?.loading == true { ProgressView().controlSize(.small) }
            Spacer(minLength: Space.snug)
            // A post the author deleted while the reader was looking at it. Said here rather
            // than by closing the page out from under them: they are still looking at what it
            // said, and being told it has gone is the news (#125).
            if model?.isGone == true {
                Label(t("post.gone"), systemImage: "trash")
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let failure = model?.failure {
                Label(message(for: failure), systemImage: "exclamationmark.triangle")
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            // What it says now, asked because the reader asked. `r` is the same press, so the
            // key that refreshes a timeline refreshes the thing in front of it here (#125).
            IconButton(symbol: "arrow.clockwise", labelKey: "post.reload") {
                Task { await model?.reload() }
            }
            // The numbers on the row below are numbers; this is where they have names (#126).
            IconButton(symbol: "info.circle", labelKey: "post.aboutIt") {
                app.openAbout(model?.conversation.post ?? post)
            }
        }
        .padding(.horizontal, Space.pad)
        .padding(.vertical, Space.mid)
        .background(PageHeaderBackground())
        .background { openingAbout }
    }

    /// The chain above, the post, and everything under it. The post itself is drawn as the
    /// row it is, with its ring on: a reader who pressed `Return` on it should find the same
    /// thing here, not a second design for the same post.
    /// One post in the conversation. It is the same row the timeline draws — a reader who
    /// pressed `Return` on a post should find the same thing here — and clicking one opens
    /// nothing, because they are already looking at the whole of it.
    ///
    /// **This page measures like the timeline, and reserves a wider column than it (#121).**
    ///
    /// It did not measure at all, and the comment here argued for that: nothing is clamped
    /// — `condensed` is false, because a reader who opened a post came to read all of it — and
    /// beside a column of words that may run for a screen, a 200-point card is a stamp in the
    /// corner of a page. That argument was made from the code and never checked against somebody
    /// reading a conversation, and what they see is one post drawn one way in the timeline and
    /// another way a keypress later.
    ///
    /// So the picture goes beside the words, and it keeps the size #120 gave it: the column here
    /// is `Size.openedCard`, not the share of a row that a list reserves. The page is measured
    /// for that wider column, and **every row on it takes the same answer** — a two-column reply
    /// above a stacked one would be two arrangements down one list, which is what S6 will not
    /// have.
    ///
    /// The indent comes off the width before the comparison, because the deepest reply is the
    /// one with least room and it is the one that has to fit.
    private func row(_ post: Post, selected: Bool, answering: Answering = .nothing) -> some View {
        PostRow(post: post, selected: selected,
                turns: selected ? app.mediaTurns : 0,
                plays: selected ? app.mediaPlays : 0,
                covers: selected ? app.mediaCovers : 0,
                revealed: app.preferences.showSensitive,
                answering: answering,
                condensed: false,
                // The post this page is about gets a picture the page can justify; the
                // conversation around it keeps the timeline's card, because the chain above and
                // the replies below are a list again and a list is scanned (#120).
                widest: selected ? Size.openedCard : Size.card,
                // Clicking one opens nothing — the reader is already looking at the whole of
                // it — but it does say which post they mean, and the ring has to agree.
                focus: { app.focus(post) },
                openAuthor: { app.openPerson(of: post) },
                openTag: { app.openTag($0) })
            .id(post.mergeKey)
    }

    /// Whom a row answers: what the conversation worked out, or what the post itself carries,
    /// or nothing.
    ///
    /// The conversation's answer first, because it is the surer one — it is a post this page is
    /// holding. The post's own is what a reply from a server the reader has not joined carries,
    /// and it is the only answer there is when the post answered was never handed over (#87).
    private func named(_ known: String?, on post: Post) -> Answering {
        if let known { return .handle(known) }
        if let carried = post.answering, !carried.isEmpty { return .handle(carried) }
        return post.inReplyToURI == nil ? .nothing : .somebody
    }

    /// How far in a reply sits, and where that stops.
    ///
    /// One step per generation, up to four. Past that the indent stops growing: a conversation
    /// twenty deep would otherwise walk off the right-hand edge, and a row squeezed to nothing
    /// says less about the shape than a row that has stopped moving does.
    private static let deepest = 4

    /// How far in the deepest reply sits. Taken off the page's width before the arrangement is
    /// decided, because that reply is the one with the least room for two columns.
    static var deepestIndent: CGFloat { CGFloat(deepest) * Space.withinGroup }

    private func indent(_ depth: Int) -> CGFloat {
        CGFloat(min(depth, Self.deepest)) * Space.withinGroup
    }

    /// The line down the gutter of a reply, in the column its parent's own line stands in.
    ///
    /// It is what says "these belong together" without saying it in colour, and it is the one
    /// mark here that survives a reader who cannot tell the indent apart from the edge of the
    /// card — which, at four levels in a narrow window, is most readers.
    @ViewBuilder
    private func rail(_ depth: Int) -> some View {
        // Nothing at the left edge. The line stands in the gutter a row was pushed out of, and
        // a row that was pushed out of nothing has no gutter to stand in — the furthest
        // ancestor, and the post on a page that has no way up at all.
        if depth > 0 {
            Hairline(axis: .vertical)
                .padding(.leading, indent(depth) - Space.mid)
                .padding(.vertical, Space.hair)
        }
    }

    private var thread: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.step) {
                let conversation = model?.conversation ?? Conversation(post: post)
                let ring = model?.selection
                // The way up, drawn as the shape it is. It used to be a flat list above the
                // post — the same rows, in a column, saying nothing about which answered
                // which — while the way down had been indented since #43. One page, two
                // drawings of one idea.
                //
                // Dimmer than the post, because they are the way to it rather than the thing
                // the reader opened.
                ForEach(conversation.climbed()) { above in
                    row(above.post, selected: above.post.mergeKey == ring,
                        // Whom it answers where the page cannot show it — the furthest one
                        // answers a post nobody handed us. That used to be silence, because
                        // there was nothing to say; the post itself carries a name now where
                        // its server sent one, and where it does not it is silence still.
                        answering: named(above.answering, on: above.post))
                        .opacity(0.85)
                        .padding(.leading, indent(above.depth))
                        .overlay(alignment: .leading) { rail(above.depth) }
                }
                // One step past the last ancestor: the post is the deepest thing on the way
                // down to it, and everything answering it goes deeper still.
                // The post itself says whom it answers only where nothing above it does. With
                // ancestors on the page the way up is drawn, and a line naming what is one row
                // higher would be the page saying twice what it already shows.
                row(conversation.post, selected: conversation.post.mergeKey == ring,
                    answering: conversation.climbed().isEmpty
                        ? named(nil, on: conversation.post) : .nothing)
                    .padding(.leading, indent(conversation.depthOfPost))
                    .overlay(alignment: .leading) { rail(conversation.depthOfPost) }
                ForEach(conversation.laidOut()) { reply in
                    row(reply.post, selected: reply.post.mergeKey == ring,
                        // A direct answer to the post says nothing: the post is above it, and
                        // the page is the conversation.
                        answering: named(reply.answering, on: reply.post))
                        // `laidOut` counts from the post and `climbed` from the top; they meet
                        // here, so the whole page is drawn against one left edge.
                        .padding(.leading, indent(conversation.depthOfPost + reply.depth))
                        .overlay(alignment: .leading) { rail(conversation.depthOfPost + reply.depth) }
                }
                if conversation.isAlone, model?.loading != true {
                    Text(t("post.alone"))
                        .fediqoFont(TypeScale.minor)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Space.snug)
                }
            }
            .padding(Space.gap)
        }
    }
}
