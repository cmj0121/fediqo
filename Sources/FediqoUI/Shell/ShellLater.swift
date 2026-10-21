import FediqoCore
import Foundation
import Observation

/// The posts a source holds to send later (#333, X0 §2): read when the list is opened — from the
/// line on one's own page at that source, or from the strip's See what waits — each moved, changed
/// (through the change sheet) or let go, and D2's pair flagged.
///
/// **Nothing waiting is held on this device**: the list is the source's, read each time it is
/// opened. What this keeps is the list as last read while it is open, what is on its way for one
/// row, and — for the run alone (Decision 8, §7.5) — which two wait because a change could not let
/// the one before go. After a relaunch the two are two rows.
@MainActor
@Observable
final class ShellLater {
    /// The list a sheet is open on: one source's.
    struct Open: Identifiable, Equatable {
        let host: String
        var id: String { host }
    }

    enum Reading: Equatable {
        case reading, read, failed
    }

    /// Two that wait because a change could not let the one before go (Decision 2): the new one
    /// by its id — nothing where its making could not be confirmed — and the old.
    struct Pair: Equatable {
        let new: String?
        let old: String
        /// The old one waits without its files: the new one took them (`WaitingChange`).
        let lostMedia: Bool
    }

    var open: Open?
    private(set) var reading: Reading = .reading
    /// What waits, as last read, soonest first.
    private(set) var posts: [WaitingPost] = []
    /// Where the next stretch is read on from; nothing at the end.
    private(set) var next: String?
    /// The rows with something on its way: moved, changed or let go.
    private(set) var moving: Set<String> = []
    private(set) var changing: Set<String> = []
    private(set) var leaving: Set<String> = []
    /// What the last press on the list could not do, in a sentence, until the next press.
    private(set) var missed: String?
    /// What the last press did that was not what was asked, in a sentence: a time come too near,
    /// moved forward. Until the next press.
    private(set) var told: String?
    /// D2's pairs, by source, for the run.
    private(set) var pairs: [String: [Pair]] = [:]
    /// The question before a waiting post is let go, while it is up.
    var askingWithdraw: WaitingPost?
    /// The small sheet that moves one, while it is up, and the time it holds.
    var askingMove: WaitingPost?
    var moveTo = Date()

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Opens the list for `host` and reads it from its start.
    func show(host: String, in session: ShellSession) {
        open = Open(host: host.lowercased())
        posts = []
        next = nil
        missed = nil
        told = nil
        // A question or a move left from another source's list is not this one's.
        askingWithdraw = nil
        askingMove = nil
        reading = .reading
        task?.cancel()
        task = Task { await self.read(after: nil, in: session) }
    }

    func close() {
        task?.cancel()
        open = nil
        askingMove = nil
        askingWithdraw = nil
    }

    /// Returns once the last read or press begun has ended. For a test to wait on.
    func settled() async { await task?.value }

    /// The next stretch.
    func readOn(in session: ShellSession) {
        guard reading != .reading, let next else { return }
        reading = .reading
        task = Task { await self.read(after: next, in: session) }
    }

    /// The list read again from its start: Try again, and after a change.
    func again(in session: ShellSession) {
        guard let open else { return }
        show(host: open.host, in: session)
    }

    private func write(_ host: String, in session: ShellSession) -> MastodonWrite? {
        guard let door = session.mastodon.authorized(host: host, within: session.reload.deadline, for: .write) else { return nil }
        return session.reach.write(door, landingIn: session.store)
    }

    private func read(after: String?, in session: ShellSession) async {
        guard let host = open?.host, let write = write(host, in: session) else {
            reading = .failed
            return
        }
        do {
            let stretch = try await write.waiting(after: after)
            guard open?.host == host else { return }
            var seen = Set(posts.map(\.id))
            posts = (posts + stretch.posts.filter { seen.insert($0.id).inserted }).sorted { $0.at < $1.at }
            next = stretch.next
            reading = .read
        } catch {
            guard open?.host == host else { return }
            reading = .failed
        }
    }

    // MARK: - On a row

    /// Moves `post` to `at`, its time alone. The row says it is being moved, and then the time the
    /// source answered — **not at once**: a time is true only once the source says it. Too near by
    /// the source's clock, it is moved forward, as the composer's is.
    func move(_ post: WaitingPost, to at: Date, at host: String, in session: ShellSession) {
        // The row's own source, as it was pressed: never another list's.
        guard open?.host == host.lowercased(), let write = write(host, in: session) else { return }
        askingMove = nil
        missed = nil
        told = nil
        moving.insert(post.id)
        task = Task {
            defer { self.moving.remove(post.id) }
            do {
                let clock = try await write.sourceNow()
                let (when, forward) = MastodonLater.sendable(at, now: clock)
                let moved = try await write.move(post, to: when, sourceNow: clock)
                if forward { self.told = LaterWords.movedForward(host: host, to: moved.at) }
                if let index = self.posts.firstIndex(where: { $0.id == post.id }) { self.posts[index] = moved }
                self.posts.sort { $0.at < $1.at }
            } catch {
                self.missed = LaterWords.missed(error, host: host)
            }
        }
    }

    /// Lets `post` go, at the yes to its question: the row leaves, and is drawn again on a miss.
    func withdraw(_ post: WaitingPost, at host: String, in session: ShellSession) {
        guard open?.host == host.lowercased(), let write = write(host, in: session) else { return }
        missed = nil
        told = nil
        leaving.insert(post.id)
        task = Task {
            defer { self.leaving.remove(post.id) }
            do {
                try await write.withdraw(post)
                self.posts.removeAll { $0.id == post.id }
                self.pairs[host]?.removeAll { $0.old == post.id || $0.new == post.id }
            } catch {
                self.missed = LaterWords.missed(error, host: host)
            }
        }
    }

    /// Changes `old` to what `draft` says (Decision 2, Decision 8 §7.1): everything but what it
    /// answers. Its new files go up first; the new one is made, and the old let go after. Where
    /// the old could not be let go, the two are flagged as a pair for the run.
    func change(_ old: WaitingPost, to draft: PostDraft, at host: String, in session: ShellSession) {
        guard let write = write(host, in: session) else { return }
        missed = nil
        told = nil
        changing.insert(old.id)
        task = Task {
            defer { self.changing.remove(old.id) }
            do {
                var ids: [String] = []
                for piece in draft.media {
                    if let id = piece.remoteID, !id.isEmpty {
                        ids.append(id)
                    } else {
                        ids.append(try await write.upload(
                            bytes: piece.bytes, name: piece.name, type: piece.mime, description: piece.description,
                            byteLimit: session.mediaLimits(of: host).byteLimit(for: piece.mime)
                        ))
                    }
                }
                let clock = try await write.sourceNow()
                let (at, forward) = MastodonLater.sendable(draft.at ?? old.at, now: clock)
                if forward { self.told = LaterWords.movedForward(host: host, to: at) }
                let changed = try await write.change(
                    old, to: ComposerSheet.trimmed(draft.text), visibility: draft.audience, at: at, spoiler: draft.cover,
                    language: draft.language.isEmpty ? nil : draft.language, sensitive: draft.coversMedia, mediaIDs: ids,
                    poll: draft.poll, pollLimits: session.composeRooms[host]?.polls, sourceNow: clock,
                    quotePolicy: .some(draft.quotePolicySent)
                )
                if changed.oldStays {
                    self.pairs[host, default: []].append(Pair(new: changed.new?.id, old: old.id, lostMedia: changed.oldLostMedia))
                }
            } catch MastodonLaterError.sentNow {
                self.missed = String(format: L10n.t("outbox.later.sentNow"), host)
            } catch {
                // Nothing typed is lost to a refusal or a miss: the sheet opens again on what was
                // typed, saying why (Decision 2).
                let said = LaterWords.missed(error, host: host)
                self.missed = said
                session.changes.startWaiting(old, host: host, in: session, draft: draft, refused: said)
            }
            if self.open?.host == host {
                self.posts = []
                self.next = nil
                await self.read(after: nil, in: session)
            }
        }
    }

    // MARK: - What the sheet draws

    /// The sheet's value: what it draws, made here so a test reads it.
    func said(in session: ShellSession) -> WaitingSaid? {
        guard let host = open?.host else { return nil }
        let lock = session.laterSlot(host: host)?.locked
        return WaitingSaid(
            host: host, reading: reading, posts: posts, more: next != nil, moving: moving, changing: changing,
            leaving: leaving, missed: missed, told: told, pairs: pairs[host] ?? [], locked: lock
        )
    }
}

/// What the list of waiting posts draws (X0 §2): a value, so what is drawn and what a test reads
/// are one.
struct WaitingSaid: Equatable {
    let host: String
    let reading: ShellLater.Reading
    let posts: [WaitingPost]
    let more: Bool
    let moving: Set<String>
    let changing: Set<String>
    let leaving: Set<String>
    let missed: String?
    var told: String? = nil
    let pairs: [ShellLater.Pair]
    /// The lock's words where the sign-in lacks the writing part: rows are read, not acted on.
    let locked: String?

    /// The rows, soonest first, less any let go.
    var rows: [WaitingPost] { posts.filter { !leaving.contains($0.id) } }

    /// The pair `post` is the one before of, where it is.
    func pair(before post: WaitingPost) -> ShellLater.Pair? {
        pairs.first { $0.old == post.id }
    }

    /// Whether `post` is the new one of a pair.
    func isNewOfPair(_ post: WaitingPost) -> Bool {
        pairs.contains { $0.new == post.id }
    }

    /// The line under the head: reading, nothing waits, failed — or nothing where rows say it.
    @MainActor
    func line(language: DummyLanguage? = nil) -> String? {
        switch reading {
        case .reading where posts.isEmpty: String(format: L10n.t("waiting.asking", language: language), host)
        case .failed: String(format: L10n.t("waiting.failed", language: language), host)
        case .read where rows.isEmpty: String(format: L10n.t("waiting.none", language: language), host)
        default: nil
        }
    }

    /// The foot: more to read, or the end.
    @MainActor
    func foot(language: DummyLanguage? = nil) -> String? {
        guard reading == .read, !rows.isEmpty else { return nil }
        return more ? L10n.t("waiting.more", language: language) : String(format: L10n.t("waiting.end", language: language), host)
    }
}
