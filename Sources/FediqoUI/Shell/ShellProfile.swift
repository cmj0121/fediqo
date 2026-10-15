import FediqoCore
import Foundation
import Observation
import SwiftUI

// The reader changing their own account at a source (#312): what is asked, when, and what
// the sheet and their own page are handed of the answers.
//
// **Read afresh every time the sheet opens, and never from what the page holds**: the page may
// be minutes old, and the fields are sent whole, so a sheet opened on stale words would put
// them back over a change made elsewhere. A sheet left open is not read again. **Save waits on
// that read** — there is nothing to change from until it lands — and sends one change.
//
// **Every letter typed is kept** through a refusal, a failure, a sign-in that ended and the
// account part gone; only Cancel, Discard and the answer put the sheet down. **A failure
// changes nothing held**: the page stays as it was last read.
//
// **After an answer, every place that draws the reader's own account draws the answer**: the
// head and About of their own page (`ShellPersonPages.ownAnswered`), its Posts and Pinned asked
// again, and how many ask to follow them (`MastodonSessions.askingAnswered`).
//
// **As whoever asked, and nobody else's — told by the account, not the token.** Asking for the
// account part in place hands back a new token for the same account, and the typing must
// outlive that; so at each press the sheet looks at who the sign-in is now (`PageReaders`,
// which lets the pages go), and is put down only where that is another account. An answer
// lands only while its ask is still the one awaited. **Held nowhere**: for this run, in memory.

/// Which sheet is up: the host whose account it changes, and the opening it is.
struct ProfileOpen: Identifiable, Equatable {
    let host: String
    let id: Int
}

/// The reader's own account at the source whose sheet is up, as it was read, what is typed
/// over it, and the change sent.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask.
@MainActor
@Observable
final class ShellProfile {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// The sheet up, or nothing. One at a time.
    private(set) var open: ProfileOpen?
    private(set) var state: ProfileState = .asking
    /// What the sheet edits, once the read has landed.
    var draft: ProfileDraft?

    @ObservationIgnored private var askedAs: AskedAs = .nobody
    /// The id the source gave the reader the sheet was opened for, where it had said.
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The number of the ask whose answer the sheet awaits.
    @ObservationIgnored private var awaits = 0
    /// What each host stated of its limits this run: asked once a run for a host.
    @ObservationIgnored private var stated: [String: OwnLimits] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// The reader's own page told of an answer: set by `ShellPersonPages`.
    @ObservationIgnored var answered: ((Person, String, ShellSession) async -> Void)?
    /// What a listener is told as the sheet closes on an answer. A test listens.
    @ObservationIgnored var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    init(errands: PageErrands, readers: PageReaders) {
        self.errands = errands
        self.readers = readers
    }

    // MARK: - What the sheet is handed

    /// What the sheet up is handed, or nothing where none is.
    func said(in session: ShellSession) -> ProfileSaid? {
        guard let open else { return nil }
        let lock = session.mastodon.place(.account, host: open.host)
        // The part asked for again and held: the sheet is as it was before the refusal.
        let now: ProfileState = state == .partGone && lock == nil ? .read : state
        let waiting = session.mastodon.asking(host: open.host).flatMap { $0 > 0 ? $0 : nil }
        return ProfileSaid(host: open.host, state: now, draft: draft, waiting: waiting, lock: now == .partGone ? lock : nil)
    }

    // MARK: - Asking

    /// The sheet for the reader's own account at `host` up, and the account read. **Nothing
    /// while a sheet is up**, and nothing where nobody is signed in there. The task the read
    /// runs in.
    @discardableResult
    func open(_ host: String, in session: ShellSession) -> Task<Void, Never>? {
        guard open == nil, let source = ShellPersonPages.source(at: host, in: session),
              let held = readers.look(at: source.host, in: session).held
        else { return nil }
        askedAs = ShellPersonPages.askedAs(at: source.host, in: session)
        accountID = session.mastodon.reader(host: source.host)?.id
        open = ProfileOpen(host: source.host, id: errands.next())
        return read(source, with: held, in: session)
    }

    /// "Try again", where the read failed.
    @discardableResult
    func readAgain(in session: ShellSession) -> Task<Void, Never>? {
        guard let open, state == .readFailed, let source = ShellPersonPages.source(at: open.host, in: session) else { return nil }
        guard let held = held(at: source, in: session) else { return nil }
        return read(source, with: held, in: session)
    }

    private func read(_ source: Source, with held: MastodonToken, in session: ShellSession) -> Task<Void, Never> {
        state = .asking
        draft = nil
        let errand = errands.next()
        awaits = errand
        let own = session.reach.ownAccount(session.mastodon.authorized(token: held, within: deadline, for: .ownSettings))
        let known = stated[source.host]
        let task = Task { await self.reading(source, through: own, known: known, errand: errand, in: session) }
        self.task = task
        return task
    }

    private func reading(
        _ source: Source, through own: MastodonOwnAccount, known: OwnLimits?, errand: Int, in session: ShellSession
    ) async {
        async let limits = Self.limits(known, of: own)
        do {
            let account = try await own.read()
            let limits = await limits
            guard awaits == errand, open?.host == source.host else { return }
            if let limits { stated[source.host] = limits }
            draft = ProfileDraft(account, limits: limits ?? .none)
            state = .read
        } catch {
            _ = await limits
            guard awaits == errand, open?.host == source.host, !Cancellation.happened(error) else { return }
            ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
            state = (error as? MastodonAuthError) == .signedOut ? .ended : .readFailed
        }
    }

    /// The limits a host states, where they were not known already; nothing where it could
    /// not be asked — the next opening asks again.
    private nonisolated static func limits(_ known: OwnLimits?, of own: MastodonOwnAccount) async -> OwnLimits? {
        if let known { return known }
        return try? await own.limits()
    }

    /// Save: what is typed sent as one change, where the sheet may send. The task it runs in.
    @discardableResult
    func save(in session: ShellSession) -> Task<Void, Never>? {
        guard let open, let draft, said(in: session)?.canSave == true,
              let source = ShellPersonPages.source(at: open.host, in: session)
        else { return nil }
        guard let held = held(at: source, in: session) else { return nil }
        let errand = errands.next()
        awaits = errand
        state = .sending
        let own = session.reach.ownAccount(session.mastodon.authorized(token: held, within: deadline, for: .write))
        let (before, after) = (draft.before, draft.after)
        let task = Task { await self.saving(before, after, at: source, through: own, errand: errand, in: session) }
        self.task = task
        return task
    }

    private func saving(
        _ before: OwnAccount, _ after: OwnAccount, at source: Source, through own: MastodonOwnAccount, errand: Int,
        in session: ShellSession
    ) async {
        let host = source.host
        do {
            let answer = try await own.change(from: before, to: after)
            guard awaits == errand, open?.host == host else { return }
            close()
            guard let answer else { return }
            announce(String(format: L10n.t("profile.saved"), host))
            session.mastodon.askingAnswered(answer.asking, host: host)
            await answered?(answer.person, host, session)
        } catch {
            guard awaits == errand, open?.host == host, !Cancellation.happened(error) else { return }
            switch error as? OwnAccountError {
            case .refused(let sentence, let rows): state = .refused(sentence: sentence, rows: rows)
            case .forbidden: state = .forbidden
            case .locked: state = .partGone
            case .unreadable, nil:
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                state = (error as? MastodonAuthError) == .signedOut ? .ended : .failed
            }
        }
    }

    /// The sign-in a press goes through, after the one look at it: nothing — and the sheet put
    /// down — where it is another account's than the sheet was opened for, or where nobody is
    /// signed in there now, which says the sign-in ended.
    private func held(at source: Source, in session: ShellSession) -> MastodonToken? {
        let held = readers.look(at: source.host, in: session).held
        guard let held else {
            state = .ended
            return nil
        }
        let now = ShellPersonPages.askedAs(at: source.host, in: session)
        let was = accountID, id = session.mastodon.reader(host: source.host)?.id
        guard now.isTheSame(as: askedAs), was == nil || id == nil || was == id else {
            close()
            return nil
        }
        if accountID == nil { accountID = id }
        return held
    }

    /// The press on the lock where the sign-in no longer holds the account part.
    func askForPart(in session: ShellSession) {
        guard let open else { return }
        session.askFor([.account], host: open.host)
    }

    /// Cancel, or Discard: the sheet put down and nothing sent. **Nothing while a change is out.**
    func putDown() {
        guard state != .sending else { return }
        close()
    }

    private func close() {
        task?.cancel()
        task = nil
        awaits = errands.next()
        open = nil
        draft = nil
        state = .asking
    }
}

// MARK: - Change, on the reader's own page

extension ShellPersonPages {
    /// What stands where Follow would on the page of `who`, where it is the reader's own and
    /// the source has said who they are: Change, or its lock where the sign-in does not hold
    /// the account part. Nothing on anybody else's page, and nothing for an account suspended.
    func changeEntry(of who: DummyPerson, in session: ShellSession) -> OwnChangeEntry? {
        guard Self.own(at: who.host, in: session)?.id == who.id,
              let person = said(of: who, in: session)?.person, !person.suspended
        else { return nil }
        return OwnChangeEntry(host: who.host, lock: session.mastodon.place(.account, host: who.host))
    }

    /// A press on Change, or `l`, on the page of `who`: the sheet up, or — where the sign-in
    /// does not hold the account part — the question that asks for it, and no sheet. Whether
    /// the page has Change at all.
    @discardableResult
    func changeOwn(_ who: DummyPerson, in session: ShellSession) -> Bool {
        guard let entry = changeEntry(of: who, in: session) else { return false }
        if let lock = entry.lock {
            if lock.asks { session.askFor([.account], host: entry.host) }
        } else {
            profile.open(entry.host, in: session)
        }
        return true
    }
}
