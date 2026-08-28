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

    private let loader: TimelineLoader

    init(post: Post, loader: TimelineLoader) {
        self.conversation = Conversation(post: post)
        self.selection = post.mergeKey
        self.loader = loader
    }

    /// The conversation in the order it is drawn: what is answered, the post, the answers.
    var inOrder: [Post] { conversation.ancestors + [conversation.post] + conversation.descendants }

    /// The post the ring is on, which is what the keys act on while this page is open.
    var selected: Post? { inOrder.first { $0.mergeKey == selection } }

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
        conversation = await loader.storedThread(around: conversation.post)
        loading = true
        let asked = await loader.conversation(around: conversation.post)
        failure = asked.failure
        if asked.failure == nil { conversation = conversation.merged(with: asked.conversation) }
        loading = false
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
        }
        .background(Palette.surface(colorScheme))
        .task(id: post.mergeKey) { await app.thread?.read() }
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
            if let failure = model?.failure {
                Label(message(for: failure), systemImage: "exclamationmark.triangle")
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Space.pad)
        .padding(.vertical, Space.mid)
        .background(PageHeaderBackground())
    }

    /// The chain above, the post, and everything under it. The post itself is drawn as the
    /// row it is, with its ring on: a reader who pressed `Return` on it should find the same
    /// thing here, not a second design for the same post.
    /// One post in the conversation. It is the same row the timeline draws — a reader who
    /// pressed `Return` on a post should find the same thing here — and clicking one opens
    /// nothing, because they are already looking at the whole of it.
    private func row(_ post: Post, selected: Bool, answering: String? = nil) -> some View {
        PostRow(post: post, selected: selected,
                turns: selected ? app.mediaTurns : 0,
                plays: selected ? app.mediaPlays : 0,
                covers: selected ? app.mediaCovers : 0,
                revealed: app.preferences.showSensitive,
                answering: answering,
                condensed: false)
            .id(post.mergeKey)
    }

    /// How far in a reply sits, and where that stops.
    ///
    /// One step per generation, up to four. Past that the indent stops growing: a conversation
    /// twenty deep would otherwise walk off the right-hand edge, and a row squeezed to nothing
    /// says less about the shape than a row that has stopped moving does.
    private static let deepest = 4

    private func indent(_ depth: Int) -> CGFloat {
        CGFloat(min(depth, Self.deepest)) * Space.withinGroup
    }

    /// The line down the gutter of a reply, in the column its parent's own line stands in.
    ///
    /// It is what says "these belong together" without saying it in colour, and it is the one
    /// mark here that survives a reader who cannot tell the indent apart from the edge of the
    /// card — which, at four levels in a narrow window, is most readers.
    private func rail(_ depth: Int) -> some View {
        Hairline(axis: .vertical)
            .padding(.leading, indent(depth) - Space.mid)
            .padding(.vertical, Space.hair)
    }

    private var thread: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.step) {
                let conversation = model?.conversation ?? Conversation(post: post)
                let ring = model?.selection
                ForEach(conversation.ancestors) { above in
                    row(above, selected: above.mergeKey == ring).opacity(0.85)
                }
                row(conversation.post, selected: conversation.post.mergeKey == ring)
                ForEach(conversation.laidOut()) { reply in
                    row(reply.post, selected: reply.post.mergeKey == ring, answering: reply.answering)
                        .padding(.leading, indent(reply.depth))
                        .overlay(alignment: .leading) { rail(reply.depth) }
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
