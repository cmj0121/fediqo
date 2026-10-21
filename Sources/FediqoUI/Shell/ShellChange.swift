import FediqoCore
import Observation
import Foundation

/// Changing one's own post after it was published (#332, X0 §1): the sheet opened on it, what
/// the post was written from asked of its source, the change written in a draft of its own, and
/// Save handing it to the outbox — where a change waits as a post does until its source says
/// yes, and lands on the post's own row.
///
/// **The editor is drawn only from the source's own words** (`MastodonWrite.source`). The row's
/// rendered words are never a stand-in: HTML read back loses mentions and line breaks, and the
/// person would save the loss. While the source is asked, and where it could not be, there is
/// no editor — nothing can be lost because nothing was typed.
@MainActor
@Observable
final class ShellChange {
    /// The post a sheet is open on: its row, the copy that is the reader's own, and — where the
    /// sheet was opened again on a change that waits — that change.
    struct Open: Identifiable, Equatable {
        let id = UUID()
        let item: DummyItem
        let copy: DummyItem
        /// Who may read it and whom it answers, as the post says: what the change cannot move.
        let audience: Audience?
        let answering: String?
        let reopening: UUID?

        @MainActor
        init(item: DummyItem, copy: DummyItem, reopening: UUID?, in session: ShellSession) {
            self.item = item
            self.copy = copy
            let note = session.note(ofRow: copy.id)
            audience = note?.audience
            answering = note?.reply?.handle
            self.reopening = reopening
        }
    }

    /// A post that waits at its source to be sent later (#333), opened to be changed: a new post,
    /// so everything but what it answers may change, the time among it (Decision 8, §7.1).
    struct Waiting: Identifiable, Equatable {
        let id = UUID()
        let post: WaitingPost
        let host: String
    }

    enum Phase: Equatable {
        case asking
        case failed
        case ready
    }

    /// The sheet's subject; nothing while no sheet is up. What presents it.
    var open: Open?
    /// A waiting post's change, where the sheet is open on one.
    private(set) var waiting: Waiting?

    /// Which sheet is up, whichever it is open on: what presents it.
    struct Shown: Identifiable, Equatable { let id: UUID }
    var shown: Shown? { open.map { Shown(id: $0.id) } ?? waiting.map { Shown(id: $0.id) } }
    private(set) var phase: Phase = .asking
    /// What the post was written from, as its source said.
    private(set) var source: PostSource?
    /// The change being written. The composer's new post is another value (`composeDraft`).
    var draft = PostDraft()
    /// The draft as the sheet opened, so a Cancel over nothing changed asks nothing.
    private(set) var started = PostDraft()
    /// Why a file was not added, or nothing.
    var mediaNote: String?
    /// Whether the system file picker is up for this sheet.
    var importing = false
    /// The question Save asks before it loses votes, while it is up.
    var askingVotes: PostSource?
    /// The question Cancel asks over a change typed and not saved, while it is up: the host.
    var askingDiscard: String?

    @ObservationIgnored private var reading: Task<Void, Never>?

    /// The host of the post the sheet is open on.
    var host: String { open?.copy.source.host ?? waiting?.host ?? "" }

    /// Whether anything was changed since the sheet opened.
    var touched: Bool { phase == .ready && draft != started }

    // MARK: - Opening

    /// Opens the sheet on the reader's own copy of `item`, and asks its source what it was
    /// written from. Nothing where the row offers no change.
    func start(_ item: DummyItem, in session: ShellSession) {
        guard let offer = session.changeOffer(on: item), offer.lock == nil else { return }
        begin(Open(item: item, copy: offer.copy, reopening: nil, in: session), from: nil, in: session)
    }

    /// Opens the sheet again on a change that waits in the outbox (its line's Open), with what
    /// was typed in it, and asks the source again for what the post says now.
    func reopen(_ unsent: Unsent, in session: ShellSession) {
        guard let changes = unsent.changes,
              let held = session.held(changes.item.rowID) ?? session.outbox.changeTarget(unsent.id).map({ DummyItem($0) }),
              let offer = session.changeOffer(on: held), offer.lock == nil, offer.copy.id == changes.item.rowID
        else { return }
        begin(Open(item: held, copy: offer.copy, reopening: unsent.id, in: session), from: unsent, in: session)
    }

    /// Opens the sheet on a post waiting at `host` (#333): filled from what it waits as, nothing
    /// asked — the source holds nothing else of it.
    ///
    /// `draft` is what was typed in it before, where a Save could not go — the sheet opens again on
    /// it, saying why (`refused`).
    func startWaiting(
        _ post: WaitingPost, host: String, in session: ShellSession, draft typed: PostDraft? = nil, refused: String? = nil
    ) {
        close()
        waiting = Waiting(post: post, host: host)
        source = nil
        mediaNote = refused
        let fresh = PostDraft(
            text: post.text, cover: post.spoiler, language: post.language ?? "", coversMedia: post.sensitive,
            media: post.media.enumerated().map { ChangeWords.kept($0.element, at: $0.offset) }, poll: post.poll,
            audience: post.audience ?? .everyone, at: post.at, quotePolicy: post.quotePolicy
        )
        started = fresh
        draft = typed ?? fresh
        phase = .ready
    }

    private func begin(_ opening: Open, from unsent: Unsent?, in session: ShellSession) {
        reading?.cancel()
        waiting = nil
        open = opening
        phase = .asking
        source = nil
        mediaNote = nil
        askingVotes = nil
        askingDiscard = nil
        reading = Task { await self.read(opening, from: unsent, in: session) }
    }

    /// Returns once the source has answered what the post was written from, or could not.
    /// For a test to wait on.
    func settled() async {
        await reading?.value
    }

    /// Try again, after the source could not be asked.
    func retry(in session: ShellSession) {
        guard let open, phase == .failed else { return }
        let unsent = open.reopening.flatMap { session.outbox.sending($0)?.unsent }
        begin(open, from: unsent, in: session)
    }

    private func read(_ opening: Open, from unsent: Unsent?, in session: ShellSession) async {
        let copy = opening.copy
        guard let note = session.note(ofRow: copy.id),
              let door = session.mastodon.authorized(host: copy.source.host, within: session.reload.deadline, for: .write)
        else { return settle(opening, nil, from: unsent) }
        // The source's words and its post limit, asked together.
        async let said = try? session.reach.write(door, landingIn: session.store).source(of: note)
        async let limit: Void = session.refreshPostLimit(of: copy.source.host)
        let (words, _) = await (said, limit)
        settle(opening, words, from: unsent)
    }

    private func settle(_ opening: Open, _ said: PostSource?, from unsent: Unsent?) {
        guard open == opening else { return }
        guard let said else {
            phase = .failed
            return
        }
        source = said
        let fresh = ChangeWords.draft(from: said, audience: opening.audience)
        started = fresh
        draft = unsent.map(Self.draft(of:)) ?? fresh
        phase = .ready
    }

    /// What a change that waits says, as a draft.
    static func draft(of unsent: Unsent) -> PostDraft {
        PostDraft(
            text: unsent.text, cover: unsent.spoiler ?? "", language: unsent.language ?? "",
            coversMedia: unsent.sensitive, media: unsent.media, poll: unsent.poll, audience: unsent.audience
        )
    }

    /// The sheet went away, by any way: nothing typed in it is kept.
    func close() {
        reading?.cancel()
        reading = nil
        open = nil
        waiting = nil
        importing = false
        askingVotes = nil
        askingDiscard = nil
    }

    // MARK: - What the sheet draws from

    func controls(in session: ShellSession) -> DraftControls {
        let host = host
        let polls = session.pollLimits(of: host)
        return DraftControls(
            host: host, limit: session.postLimit(of: host), media: session.mediaLimits(of: host), polls: polls,
            mediaNote: mediaNote, pollSays: pollSays(in: session),
            runs: ChangeWords.runs(draft, offered: polls.offeredRuns),
            addMedia: { [weak self] in self?.addMedia(in: session) },
            addPoll: { [weak self] in self?.addPoll(in: session) },
            chooseLanguage: { [weak self] in self?.draft.language = $0 },
            chooseCoversMedia: { [weak self] in self?.draft.coversMedia = $0 },
            // A waiting post's time is part of what changes, and is never taken off.
            later: waiting == nil ? nil : session.laterSlot(host: host).map { slot in
                var always = slot
                always.optional = false
                return always
            },
            // A waiting quote stays a quote (#330): files and a poll dim, as when writing one (D3).
            quoteBlocks: quotesFixed ? L10n.t("compose.quote.noMedia") : nil
        )
    }

    /// Whether the sheet is open on a waiting post that quotes another: what it quotes is fixed,
    /// and it carries no file nor poll. Who may quote it changes, as on any waiting post.
    var quotesFixed: Bool { waiting?.post.quoting != nil }

    /// What the poll's place says: that a file keeps a poll out, or why the poll cannot go.
    func pollSays(in session: ShellSession) -> String? {
        guard draft.poll != nil else { return nil }
        if draft.poll?.runs == 0 { return ChangeWords.endedLine() }
        return draft.pollRefusal(within: session.pollLimits(of: host)).map { ComposeWords.refusalLine($0, host: host) }
    }

    /// Whether the poll as drafted starts the post's again, losing its votes.
    var resets: Bool { source.map { ChangeWords.resets($0, draft) } ?? false }

    func canSave(in session: ShellSession) -> Bool {
        guard phase == .ready, open != nil || (waiting != nil && draft.at != nil) else { return false }
        if waiting != nil, session.laterSlot(host: host)?.locked != nil { return false }
        if quotesFixed, draft.poll != nil || !draft.media.isEmpty { return false }
        return draft.canSend(
            limit: session.postLimit(of: host), hasSource: session.mastodon.authorized(host: host, for: .write) != nil,
            media: session.mediaLimits(of: host), polls: session.pollLimits(of: host)
        )
    }

    private func addPoll(in session: ShellSession) {
        guard !quotesFixed else { return }
        guard draft.media.isEmpty else {
            mediaNote = ComposeWords.refusalLine(.pollWithMedia, host: host)
            return
        }
        draft.poll = draft.freshPoll(within: session.pollLimits(of: host))
    }

    private func addMedia(in session: ShellSession) {
        guard !quotesFixed else { return }
        switch session.mediaPress(host: host, hasPoll: draft.poll != nil) {
        case .refused(let note): mediaNote = note
        case .opens: importing = true
        case .asked(let note): if let note { mediaNote = note }
        }
    }

    /// What the system picker handed back, added within what the source takes.
    func read(_ result: Result<[URL], Error>, in session: ShellSession) {
        if let note = ShellSession.readPicked(result, into: &draft, host: host, limits: session.mediaLimits(of: host)) {
            mediaNote = note
        }
    }

    // MARK: - Saving

    /// Save pressed. Where the change loses votes there are, the question goes up first and
    /// nothing is taken; otherwise the outbox takes the change. Whether the sheet closes.
    func save(in session: ShellSession) -> Bool {
        if let waiting {
            guard canSave(in: session) else { return false }
            // The new one first and the old one after, by the list that shows them (Decision 2).
            session.later.change(waiting.post, to: draft, at: waiting.host, in: session)
            close()
            return true
        }
        guard canSave(in: session), let source else { return false }
        if ChangeWords.asksAtSave(source, draft) {
            askingVotes = source
            return false
        }
        return commit(in: session)
    }

    /// The yes to losing the votes, or a Save that loses none: the outbox takes the change, and
    /// the sheet closes. A change of this post that waits and is not on its way is replaced by
    /// this one; one already on its way is followed by it.
    @discardableResult
    func commit(in session: ShellSession) -> Bool {
        // Asked again at the press: the post may have stopped being one to change while the
        // sheet was up — taken back, the sign-in narrowed, another account signed in.
        guard canSave(in: session), let open,
              let offer = session.changeOffer(on: session.held(open.item.id) ?? open.item), offer.lock == nil,
              offer.copy.id == open.copy.id, let id = offer.copy.statusID,
              let note = session.note(ofRow: offer.copy.id) ?? open.reopening.flatMap({ session.outbox.changeTarget($0) })
        else { return false }
        let writer = session.mastodon.reader(host: host)
        let unsent = Unsent(
            host: host, text: ComposerSheet.trimmed(draft.text), audience: draft.audience,
            writerID: writer?.id, writer: writer?.handle,
            spoiler: draft.cover, language: draft.language.isEmpty ? nil : draft.language,
            sensitive: draft.coversMedia, media: draft.media, poll: draft.poll,
            changes: Unsent.Changes(item: note.key, statusID: id)
        )
        session.outbox.takeChange(unsent, in: session)
        close()
        return true
    }

    /// Cancel pressed: with nothing changed, the sheet goes; with something, it asks first.
    func cancel() -> Bool {
        guard touched else {
            close()
            return true
        }
        askingDiscard = host
        return false
    }
}

extension ShellSession {
    /// What a post's `…` offers of changing it (#332): the copy that is the reader's own, at a
    /// source of a kind whose posts change, named there and not gone or leaving — and the lock
    /// where the sign-in lacks the writing part. Nothing on anybody else's post, a reblog, a
    /// forum's, or one being taken back.
    func changeOffer(on item: DummyItem) -> (copy: DummyItem, lock: ItemActing.Lock?)? {
        guard !item.isReblog else { return nil }
        for copy in item.actCopies {
            let host = copy.source.host
            guard let kind = sources.first(where: { $0.host == host })?.kind, kind.offers.changesPosts,
                  copy.statusID != nil, copy.goneSince == nil, isMine(copy),
                  !acts.leaving.contains(copy.id), !acts.isOnItsWay(copy.id, .withdraw)
            else { continue }
            let place = mastodon.standing(.acting, host: host) == .held ? nil : mastodon.place(.acting, host: host)
            return (copy, place.map { ItemActing.Lock(place: $0, host: host) })
        }
        return nil
    }
}
