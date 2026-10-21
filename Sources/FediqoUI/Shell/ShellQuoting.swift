import FediqoCore
import Foundation
import Observation

/// Quoting from the UI (#330, X0 §3): the quote mark and why it is dim, a quote begun in the
/// composer's own draft, who may quote one's own post — picked when writing and changed from its
/// `…` — and the quotes of one's own post, each taken back behind a question.
///
/// **What may be quoted is its source's word** (`Note.mayQuote`): live where it lets the reader,
/// dim with the author's reason where it does not, and absent of a host whose own account of itself
/// says it has no quotes (D6).
@MainActor
@Observable
final class ShellQuoting {
    /// The quotes list a sheet is open on: one own post's.
    struct Open: Identifiable, Equatable {
        let post: Note
        var id: String { post.key.rowID }
        var host: String { post.source.host }
    }

    enum Reading: Equatable { case reading, read, failed }

    /// A quote pressed while the draft holds what a quote cannot carry: asked first (D3).
    struct Ask: Identifiable, Equatable {
        let item: DummyItem
        let files: Int
        let poll: Bool
        var id: String { item.id }
    }

    var open: Open?
    private(set) var reading: Reading = .reading
    private(set) var rows: [Note] = []
    private(set) var next: String?
    private(set) var revoking: Set<String> = []
    private(set) var missed: String?
    /// The question before a quote is taken back, while it is up.
    var askingRevoke: Note?
    /// The question before a quote drops what the draft carries, while it is up.
    var asking: Ask?
    /// Moves when the composer is to open on a quote: the root opens it (`QuotePresenter`).
    private(set) var composeRequest = 0
    /// Who may quote each own post, as pressed, until its source answers: drawn at once.
    private(set) var policies: [String: QuotePolicy] = [:]

    @ObservationIgnored private var task: Task<Void, Never>?
    /// What this run knows each host has, as the people pages hold it — whether it has quotes
    /// (D6). Handed over by the root, which owns them; the session keeps none of it.
    @ObservationIgnored weak var hosts: ShellHostsKnown?

    func settled() async { await task?.value }

    // MARK: - The list

    func show(_ post: Note, in session: ShellSession) {
        open = Open(post: post)
        rows = []
        next = nil
        missed = nil
        askingRevoke = nil
        reading = .reading
        task?.cancel()
        task = Task { await self.read(after: nil, in: session) }
    }

    func close() {
        task?.cancel()
        open = nil
        askingRevoke = nil
    }

    func readOn(in session: ShellSession) {
        guard reading == .read, let next else { return }
        reading = .reading
        task = Task { await self.read(after: next, in: session) }
    }

    private func door(_ host: String, in session: ShellSession) -> MastodonAuthorized? {
        session.mastodon.authorized(host: host, within: session.reload.deadline, for: .write)
    }

    private func read(after: String?, in session: ShellSession) async {
        guard let post = open?.post, let door = door(post.source.host, in: session) else {
            reading = .failed
            return
        }
        do {
            let stretch = try await MastodonQuotes(door: door).quotes(of: post, after: after)
            guard open?.post.key == post.key else { return }
            var seen = Set(rows.map(\.key))
            rows += stretch.posts.filter { seen.insert($0.key).inserted }
            next = stretch.next
            reading = .read
        } catch {
            guard open?.post.key == post.key else { return }
            reading = .failed
        }
    }

    /// Takes back `quoting`'s permission, at the yes: the row reads taken back once its source
    /// says so, and is drawn as it was on a miss, saying why.
    func revoke(_ quoting: Note, of post: Note, in session: ShellSession) {
        guard open?.post.key == post.key, let door = door(post.source.host, in: session) else { return }
        missed = nil
        revoking.insert(quoting.key.rowID)
        task = Task {
            defer { self.revoking.remove(quoting.key.rowID) }
            do {
                let answered = try await session.reach.write(door, landingIn: session.store).revoke(quoting, of: post)
                if let index = self.rows.firstIndex(where: { $0.key == quoting.key }) { self.rows[index] = answered }
            } catch {
                self.missed = String(format: L10n.t("quotes.revoke.missed"), post.source.host)
            }
        }
    }

    // MARK: - Who may quote one's own post

    /// Who may quote `post` from now on: shown at once, and sent after; a miss put back and said.
    func choose(_ policy: QuotePolicy, on post: Note, in session: ShellSession) {
        let row = post.key.rowID
        guard let door = door(post.source.host, in: session) else { return }
        policies[row] = policy
        task = Task {
            defer { self.policies[row] = nil }
            do {
                _ = try await session.reach.write(door, landingIn: session.store).quotePolicy(of: post, to: policy)
                await session.reloadFromStore()
            } catch {
                session.said.say(Said(.quote(.policy, row: row), .unreachable, host: post.source.host))
            }
        }
    }

    // MARK: - A quote begun

    /// The composer opens on `item` quoted, where nothing in the draft is in the way; otherwise
    /// the question goes up first (D3).
    func start(_ item: DummyItem, in session: ShellSession) {
        let draft = session.composeDraft
        guard draft.media.isEmpty, draft.poll == nil else {
            asking = Ask(item: item, files: draft.media.count, poll: draft.poll != nil)
            return
        }
        quote(item, in: session)
    }

    /// The yes to dropping what the draft carries: it goes, the words stay, and the quote is begun.
    func dropAndQuote(_ item: DummyItem, in session: ShellSession) {
        session.composeDraft.media = []
        session.composeDraft.poll = nil
        quote(item, in: session)
    }

    private func quote(_ item: DummyItem, in session: ShellSession) {
        guard let id = item.statusID, let note = session.note(ofRow: item.id) else { return }
        session.composeDraft.quoting = Unsent.Changes(item: note.key, statusID: id)
        session.composeHost = note.source.host
        composeRequest += 1
    }
}

extension ItemActing {
    /// The quote mark (#330, X0 §3): how it is drawn, the one reason it is dim where it is, and its
    /// press — a quote begun, or, where the sign-in lacks the writing part, the ask for it.
    struct QuoteMark {
        let look: MarkLook
        var why: String?
        var press: (() -> Void)?
    }

    /// Who may quote one's own post, and its quotes (#330), for the own post's `…`.
    struct OwnQuotes {
        let policy: QuotePolicy
        /// Fixed at nobody: a post only followers or those it names may read (asked of 4.6.6).
        let fixed: Bool
        var lock: Lock?
        let choose: (QuotePolicy) -> Void
        /// How many quote it, where any do, and the press that lists them.
        var count: Int?
        var openQuotes: (() -> Void)?
    }
}

extension ShellSession {
    /// Whether `host` has quotes, as its own account of itself says (D6): yes, no, or not heard.
    func quotesOffered(host: String) -> Bool? {
        switch quoting.hosts?.has(.quotes, at: host) {
        case .present?: true
        case .absent?: false
        default: nil
        }
    }

    /// The post a row's quote is of: on a reblog's row, the post it carries.
    private func quotedPost(of item: DummyItem) -> DummyItem {
        item.isReblog ? item.reblogged.first ?? item : item
    }

    /// The quote mark of `item`, or nothing where quoting is none of its source's — and the mark
    /// is then drawn dim as it always was.
    func quoteOffer(on item: DummyItem) -> ItemActing.QuoteMark? {
        let post = quotedPost(of: item)
        let host = post.source.host
        guard sources.first(where: { $0.host == host })?.kind.offers.saysQuotes == true,
              mastodon.token(host: host) != nil, let held = note(ofRow: post.id), held.sendableID != nil,
              held.goneSince == nil
        else { return nil }
        if quotesOffered(host: host) == false {
            return .init(look: .dim(.never), why: String(format: L10n.t("item.act.quote.host"), host))
        }
        if mastodon.standing(.acting, host: host) != .held {
            let place = mastodon.place(.acting, host: host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
            return .init(look: .dim(.askAgain), why: String(format: L10n.t(place.key), host)) { [weak self] in
                _ = self?.askFor([.acting], host: host)
            }
        }
        let author = LineText.oneLine(held.handle)
        switch held.mayQuote {
        case .automatic?:
            return .init(look: .live, why: nil) { [weak self] in self.map { $0.quoting.start(post, in: $0) } }
        case .manual?:
            return .init(look: .live, why: String(format: L10n.t("item.act.quote.manual"), author)) { [weak self] in
                self.map { $0.quoting.start(post, in: $0) }
            }
        case .denied?, nil:
            return .init(look: .dim(.notNow), why: String(format: L10n.t("item.act.quote.denied"), author))
        }
    }

    /// Who may quote `item` — the reader's own post — and its quotes, or nothing where it is not
    /// theirs, or its host has no quotes.
    func ownQuotesOffer(on item: DummyItem) -> ItemActing.OwnQuotes? {
        guard !item.isReblog, isMine(item), item.statusID != nil, item.goneSince == nil,
              let held = note(ofRow: item.id), held.source.kind.offers.saysQuotes,
              held.quoteApproval != nil || quotesOffered(host: held.source.host) == true
        else { return nil }
        let host = held.source.host
        let fixed = held.audience == .followers || held.audience == .mentioned
        let lock = mastodon.standing(.acting, host: host) == .held
            ? nil : mastodon.place(.acting, host: host).map { ItemActing.Lock(place: $0, host: host) }
        let counted = held.counts.quotes ?? 0
        return ItemActing.OwnQuotes(
            policy: fixed ? .nobody : quoting.policies[held.key.rowID] ?? held.quoteApproval?.policy ?? .anyone,
            fixed: fixed, lock: lock,
            choose: { [weak self] policy in
                guard let self else { return }
                if lock != nil { _ = self.askFor([.acting], host: host) } else { self.quoting.choose(policy, on: held, in: self) }
            },
            count: counted > 0 ? counted : nil,
            openQuotes: counted > 0 ? { [weak self] in self.map { $0.quoting.show(held, in: $0) } } : nil
        )
    }
}
