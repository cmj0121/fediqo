import FediqoCore
import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the person pressed to send and no source has said landed: the posts and answers on
/// their way, and the ones that did not arrive, each with every character it was pressed with.
///
/// **The press takes the text, and the sheet is gone.** Nothing here is waited for by whoever
/// pressed: a text is taken in memory, at once, and the rest — writing it down, asking its
/// source, taking the answer in — follows by itself.
///
/// **On disk before the request leaves, or the request does not leave.** A text is held in the
/// store (`ItemStore.hold`) and written (`ShellSession.persistUnsent`) as soon as it is taken,
/// and written again as *asked* before its request goes. Where that write did not land — it
/// failed, or this run has no store to write — the text stands in memory saying so (`unkept`),
/// and goes only at the person's own press.
///
/// **"Was not sent" is said only where that is known** (`notSent`): the request provably never
/// reached a server that could act on it, or the source answered that it would not. Everything
/// else — a deadline, a connection lost, any fault of a server's or of something in front of
/// it, an answer nobody could read — is "may have been posted", and once that is so nothing
/// but a yes says otherwise.
///
/// **Only as who wrote it** (`Unsent.writerID`). A text is sent, and sent again, only while
/// the account signed in at its source is the one that wrote it — in this run or a later one,
/// whatever sign-in is there now. Where nobody had yet said who was signed in at the press,
/// only that very sign-in sends it, and only in the run it was pressed in.
///
/// **Never sent again by itself**, and one that may have been posted is looked for first.
/// Send again reads the writer's own newest posts: found, the text is let go as arrived; not
/// found while the source still keeps the key it went under (`keyLife`), it goes again under
/// that key, which a source that honours it will not post twice; otherwise the person is asked
/// first, and told it may post twice. A read that brings such a post lets the text go by itself
/// (`reconcile`). A text the person changed is a different post, and takes a new name.
///
/// **Not said to be gone while the file holds it** (#292). Every write that takes a text's
/// words off the disk is asked whether it landed. Where the person said it goes — a discard,
/// its source removed — and the write did not land, its line stands saying so (`unremoved`),
/// and Discard tries again. Where its post exists — it landed, or was seen to have — the line
/// goes all the same, and the row left behind is taken out by the next save (`wroteGone`).
///
/// **A view over what the store holds** (`follow`). Every window has an outbox of its own and
/// all of them draw one store's texts: a text discarded, landed, changed or added through one
/// is so in each of them as the store says it changed, and where a text stands is the store's
/// word wherever the store knows it — its source was asked and it may have been posted, it was
/// refused, it was not sent, another window is sending it. What is this outbox's alone, and in
/// memory, is the request it has out itself (`out`), what was typed over a text in its sheet,
/// and that a write to this device's file did not land (`unkept`, `unremoved`).
///
/// **One sender a text, and the store says who** (`ItemStore.claim`). A send takes the text in
/// the store's own isolation before anything is asked of its source and gives it back when the
/// request has ended; an outbox that does not get it sends nothing and draws the text as on its
/// way. And **wherever the store will not hold a text, nothing is sent and its line goes**
/// (`ItemStore.hold`): it was let go of — through another window, or by its landing.
///
/// **One on the wire a source**, the rest waiting in the order pressed, so two posts reach
/// their source in the order written; one that fails does not hold the next back.
///
/// **No item is made for one** (#282): a post has no ID of its source's and no publish time
/// until the source gives it both, so no row is drawn for it in any timeline or conversation.
/// What is on its way is a line in the strip, and the post appears by itself when it lands.
@MainActor
@Observable
final class ShellOutbox {
    enum Standing: Equatable, Sendable {
        /// Pressed, and behind another to the same source.
        case waiting
        case onItsWay
        /// Being looked for among its writer's own posts, before it is sent again.
        case looking
        /// It was not sent, and what is known of why.
        case failed(WriteWhy)
        /// It went out and nothing says what became of it: it may have been posted.
        case unconfirmed
        /// It could not be written to this device, so its request did not leave.
        case unkept
        /// The person said it goes, and its words could not be taken out of this device's
        /// file: they are still there, and nothing is done with it but to try that again.
        case unremoved
    }

    struct Sending: Identifiable, Equatable, Sendable {
        var unsent: Unsent
        var standing: Standing

        var id: UUID { unsent.id }
        /// Waiting, looked for or on the wire: nothing the person can do to it until that ends.
        var isOut: Bool { standing == .waiting || standing == .onItsWay || standing == .looking }
    }

    /// Why a text that waits cannot be sent as things stand, read off the session as it is now.
    enum Hold: Equatable, Sendable {
        /// Its source is not one of this device's any more.
        case noSource
        /// Nobody is signed in to its source with writing.
        case signedOut
        /// Whoever is signed in to its source is not shown to be who wrote it: somebody else,
        /// by their handle as it is drawn (`MastodonSessions.Reader.shown`), or nobody the
        /// source has named yet.
        case otherAccount(here: String?)
        /// The post it answers is not held, or its source has said it is gone.
        case answeredGone
    }

    /// How long after a text's source was first asked it is still sent again under its key
    /// without asking: a Mastodon keeps a key for an hour, and this is short of that.
    static let keyLife: TimeInterval = 50 * 60
    /// How long one read made on a text's behalf may take — who is signed in, or the writer's
    /// own posts — before it is given up: a text's turn does not wait on the client's own.
    static let lookDeadline: Duration = .seconds(15)
    /// How far before the moment a text's source was asked a post may say it was published
    /// and still be that text: the source's clock is not this device's.
    static let clockSlack: TimeInterval = 60

    /// In the order pressed.
    private(set) var sendings: [Sending] = []
    /// What the person typed into the sheet opened on a text and has not sent, by the text.
    /// The text itself is untouched until it is sent: leaving the sheet changes nothing.
    private(set) var edits: [UUID: String] = [:]

    /// The access token at each text's source when it was pressed, for the run. What sends a
    /// text nobody could put a name to at the press, and nothing else. Never written down, and
    /// never moved to another sign-in.
    @ObservationIgnored private var wroteWith: [UUID: String] = [:]
    /// The row each answer was written to and the conversation it was written from, as the
    /// sheet held them, for the run: an answer read in an open conversation is in no store.
    @ObservationIgnored private var targets: [UUID: AnswerTarget] = [:]
    /// The texts whose source was asked and never said yes or no in a way that settles it —
    /// this run, the one before, or through another window, as the store says (`follow`).
    /// **Once a text may have landed, nothing but a yes says otherwise**: a later try that
    /// fails proves nothing about the first, so it goes on saying it may have been posted
    /// until it lands, is found, or is discarded.
    @ObservationIgnored private var mayHaveLanded: Set<UUID> = []
    /// When each text's source was last asked, this run: a post made by a later try is still
    /// that text's (`isPost`).
    @ObservationIgnored private var lastAsked: [UUID: Date] = [:]
    /// The texts being discarded: their words are on their way out of the file, and nothing
    /// sends, changes or opens one meanwhile — so no send can find its text let go under it.
    @ObservationIgnored private var discarding: Set<UUID> = []
    /// The texts the person said to send though they could not be written to this device.
    @ObservationIgnored private var sentUnkept: Set<UUID> = []
    /// This outbox's name among the store's senders (`ItemStore.claim`).
    @ObservationIgnored let sender = UUID()
    /// The texts this outbox has out itself — pressed here and waiting, looked for, or on the
    /// wire — until that has ended and the store was told. **What the store's word does not
    /// draw over** (`follow`): its own copy of each is the newer one meanwhile.
    @ObservationIgnored private var out: Set<UUID> = []
    /// The names this outbox let go of itself. Its line is gone here at once and the store is
    /// told behind that, so a view of the store read in between does not draw it again.
    @ObservationIgnored private var dropped: Set<UUID> = []
    /// The store's `unsentMark` as the last view followed had it: an older one is not taken.
    @ObservationIgnored private var followed = -1
    /// The one send running for each source.
    @ObservationIgnored private var pumps: [String: Task<Void, Never>] = [:]
    /// The write of each text asked for and not yet returned: its send waits for it.
    @ObservationIgnored private var keeps: [UUID: Task<Void, Never>] = [:]
    /// Everything else begun here and not yet done, for `settled()`.
    @ObservationIgnored private var works: [UUID: Task<Void, Never>] = [:]
    /// The moment a request is said to leave. A seam, so a test sets the clock.
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Waited for by a text's own write before it holds the text. A seam, so a test keeps
    /// one there while its source is removed.
    @ObservationIgnored var holding: (@MainActor () async -> Void)?

    /// Puts a text where the person can take it elsewhere. A seam, so a test reads what went.
    @ObservationIgnored var copy: (String) -> Void = { text in
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    func sending(_ id: UUID) -> Sending? {
        sendings.first { $0.id == id }
    }

    /// How many texts wait for one source — what its Remove says goes with it.
    func count(host raw: String) -> Int {
        let host = raw.lowercased()
        return sendings.count(where: { $0.unsent.host == host })
    }

    /// Whether `id` may have been posted already.
    func mayHaveBeenPosted(_ id: UUID) -> Bool { mayHaveLanded.contains(id) }

    // MARK: - What the store holds

    /// What the store holds of the texts, drawn: at a launch — what the last run left, each as
    /// it stands and none sent — and each time the store says they changed, through this
    /// window or another (`ShellSession.adopt`).
    ///
    /// - A text let go of in the store is gone here, and any sheet or question about it with
    ///   it — but for one whose words this outbox is still taking off the disk, or could not.
    /// - A text held that is not out from here is drawn as the store has it: on its way where
    ///   another outbox is sending it, may have been posted where its source was asked, and
    ///   otherwise not sent, by what its source answered.
    /// - A text out from here is left as it is (`out`), and one this outbox let go of is not
    ///   drawn again (`dropped`).
    ///
    /// Nothing is said aloud for it: whoever pressed heard it where they pressed. On the main
    /// actor, with no wait inside; the view was read in one hop of the store's.
    func follow(_ view: UnsentView, in session: ShellSession) {
        guard view.mark >= followed else { return }
        followed = view.mark
        let went = sendings.filter {
            view.gone.contains($0.id) && $0.standing != .unremoved && !discarding.contains($0.id)
        }.map(\.id)
        for id in went { drop(id) }
        unask(went, in: session)
        for text in view.texts where !out.contains(text.id) && !dropped.contains(text.id) && !discarding.contains(text.id) {
            let other = view.senders[text.id].flatMap { $0 == sender ? nil : $0 }
            if text.standing == .asked { mayHaveLanded.insert(text.id) } else { mayHaveLanded.remove(text.id) }
            guard let at = sendings.firstIndex(where: { $0.id == text.id }) else {
                sendings.append(Sending(unsent: text, standing: Self.standing(of: text, sentElsewhere: other != nil)))
                continue
            }
            // That it could not be written to this device is this run's to know, while the
            // text is as it was then and nobody else is sending it.
            if sendings[at].standing == .unkept, sendings[at].unsent == text, other == nil { continue }
            let drawn = Sending(unsent: text, standing: Self.standing(of: text, sentElsewhere: other != nil))
            if sendings[at] != drawn { sendings[at] = drawn }
        }
        // A sheet open on a text another window is now sending has nothing it may send: it
        // closes. What was typed there stays beside the text (`edits`), and is in the sheet
        // again where the text comes back as not sent.
        if let asked = session.editingUnsent, !out.contains(asked.id), sending(asked.id)?.isOut == true {
            session.editingUnsent = nil
        }
    }

    /// Where a text stands by what the store holds of it. One whose source was asked may have
    /// been posted; one that was not, was not sent.
    private static func standing(of text: Unsent, sentElsewhere: Bool) -> Standing {
        if sentElsewhere { return .onItsWay }
        switch text.standing {
        case .asked: return .unconfirmed
        case .refused: return .failed(.refused)
        case .declined: return .failed(.declined)
        case .fresh, .unreachable: return .failed(.unreachable)
        }
    }

    /// A sheet or a question about a text that went has nothing left to be about.
    private func unask(_ going: [UUID], in session: ShellSession) {
        if let asked = session.editingUnsent, going.contains(asked.id) { session.editingUnsent = nil }
        if let asked = session.discardingUnsent, going.contains(asked.id) { session.discardingUnsent = nil }
        if let asked = session.resendingUnsent, going.contains(asked.id) { session.resendingUnsent = nil }
    }

    /// The end of what this outbox had out of one text: the store is told nobody here is
    /// sending it, and it is drawn from the store again — as it was left, or as another
    /// window has it since. On the main actor but for the store's two hops.
    private func settle(_ id: UUID, in session: ShellSession) async {
        await session.store.release(unsent: id, from: sender)
        out.remove(id)
        follow(await session.store.unsentView(), in: session)
    }

    // MARK: - The press

    /// Takes a text at the press. In memory before this returns; written down and sent behind it.
    func take(_ unsent: Unsent, answering target: AnswerTarget? = nil, in session: ShellSession) {
        guard sending(unsent.id) == nil else { return }
        wroteWith[unsent.id] = session.mastodon.token(host: unsent.host)?.accessToken
        targets[unsent.id] = target
        let taken = Sending(unsent: unsent, standing: .waiting)
        sendings.append(taken)
        out.insert(unsent.id)
        keep(unsent, in: session)
        session.said.announce(OutboxWords.line(taken, hold: nil, whom: whom(taken, in: session)))
        pump(unsent.host, in: session)
    }

    /// The strip's Send again: the same text under the same name, as who wrote it. False where
    /// it is out already, or cannot be sent as things stand (`hold`).
    ///
    /// **A text that may have been posted is looked for first** (`lookThenSend`), and is not
    /// sent again on the strength of this press alone.
    @discardableResult
    func again(_ id: UUID, in session: ShellSession) -> Bool {
        guard let at = sendings.firstIndex(where: { $0.id == id }), !sendings[at].isOut, !leaving(id),
              sendings[at].standing != .unkept, hold(sendings[at], in: session) == nil
        else { return false }
        out.insert(id)
        guard mayHaveLanded.contains(id) else {
            sendings[at].standing = .waiting
            pump(sendings[at].unsent.host, in: session)
            return true
        }
        sendings[at].standing = .looking
        work { await self.lookThenSend(id, in: session) }
        return true
    }

    /// Sends a text though it could not be written to this device: the person's own press,
    /// having been told. False where it is not such a text, or cannot be sent as things stand.
    @discardableResult
    func sendUnkept(_ id: UUID, in session: ShellSession) -> Bool {
        guard let at = sendings.firstIndex(where: { $0.id == id }), sendings[at].standing == .unkept,
              !leaving(id), hold(sendings[at], in: session) == nil
        else { return false }
        sentUnkept.insert(id)
        out.insert(id)
        sendings[at].standing = .waiting
        pump(sendings[at].unsent.host, in: session)
        return true
    }

    /// The yes to the question before a text that may have been posted is sent all the same
    /// (`ShellSession.resendingUnsent`): as it was, under the name it had; or, where the person
    /// changed it in its sheet, as the different post it now is.
    @discardableResult
    func sendAnyway(_ id: UUID, in session: ShellSession) -> Bool {
        guard let at = sendings.firstIndex(where: { $0.id == id }), !sendings[at].isOut, !leaving(id),
              hold(sendings[at], in: session) == nil
        else { return false }
        if changed(id) != nil { return sendChanged(id, in: session) != nil }
        out.insert(id)
        sendings[at].standing = .waiting
        pump(sendings[at].unsent.host, in: session)
        return true
    }

    // MARK: - Changing one

    /// Opens the sheet on a text that waits. False where it is out, or is not here.
    @discardableResult
    func edit(_ id: UUID, in session: ShellSession) -> Bool {
        guard let held = sending(id), !held.isOut, !leaving(id) else { return false }
        session.editingUnsent = UnsentAsk(id: id)
        return true
    }

    /// What the sheet on a text shows: what was typed there and not sent, or the text.
    func draft(_ id: UUID) -> String {
        edits[id] ?? sending(id)?.unsent.text ?? ""
    }

    /// The sheet's editor writes here. **The text that waits is not touched**: leaving the
    /// sheet by any way changes nothing of it, and what was typed is there when it is opened
    /// again.
    func write(_ id: UUID, text: String) {
        guard sending(id) != nil else { return }
        edits[id] = text
    }

    /// What the person typed over a text, where it is sendable and not the text itself.
    func changed(_ id: UUID) -> String? {
        guard let typed = edits[id].map(ComposerSheet.trimmed), let held = sending(id),
              !typed.isEmpty, typed != held.unsent.text
        else { return nil }
        return typed
    }

    /// Sends what the person typed over a text in its place: **a different post**, under a new
    /// name and never asked of any source, written by who wrote the first. The old text and
    /// its row on disk go. Returns the name it goes by, or nothing where nothing was changed.
    @discardableResult
    func sendChanged(_ id: UUID, in session: ShellSession) -> UUID? {
        guard let typed = changed(id), let at = sendings.firstIndex(where: { $0.id == id }), !sendings[at].isOut,
              !leaving(id), hold(sendings[at], in: session) == nil
        else { return nil }
        let old = sendings[at].unsent
        let fresh = Unsent(
            host: old.host, text: typed, audience: old.audience, answers: old.answers, root: old.root,
            pressedAt: old.pressedAt, writerID: old.writerID, writer: old.writer
        )
        sendings[at] = Sending(unsent: fresh, standing: .waiting)
        out.insert(fresh.id)
        // The old one is this outbox's to let go of, behind this (`keep`).
        out.remove(id)
        dropped.insert(id)
        wroteWith[fresh.id] = wroteWith.removeValue(forKey: id)
        targets[fresh.id] = targets.removeValue(forKey: id)
        edits[id] = nil
        mayHaveLanded.remove(id)
        sentUnkept.remove(id)
        keep(fresh, replacing: id, in: session)
        pump(fresh.host, in: session)
        return fresh.id
    }

    // MARK: - Letting one go

    /// Discards a text the person said to discard. **Off the disk before it is off the page**
    /// (#292): the line stands until the write that takes its words out of the file has
    /// returned — and nothing sends it meanwhile (`discarding`), so what is read here before
    /// the waits is still so after them.
    ///
    /// **Where that write did not land the line does not go**: it stands as one that could
    /// not be removed from this device (`unremoved`), said aloud, and Discard on it tries the
    /// write again with no second question — the yes was given.
    ///
    /// **That it could not be removed is said in the window that discarded it, and in no
    /// other.** The store lets the text go before the write, so every other window's line
    /// goes then (`follow`), and a write that then fails is this window's to say: the store
    /// knows what it holds, not what the file does, and teaching it would be a second
    /// standing kept in step with the saver's for one person at one device. The saver tries
    /// the write again by itself, and a save that lands takes this line down (`written`).
    ///
    /// **Not one somebody is sending**: the sending of it is taken first, in the store
    /// (`ItemStore.claim`), so a window that has it on the wire is not discarded under — the
    /// line is drawn as on its way, as the store has it, and nothing goes.
    func discard(_ id: UUID, in session: ShellSession) async {
        guard let held = sending(id), !held.isOut, discarding.insert(id).inserted else { return }
        await keeps[id]?.value
        guard await session.store.claim(unsent: id, for: sender) else {
            discarding.remove(id)
            return follow(await session.store.unsentView(), in: session)
        }
        await session.store.letGo(unsent: id)
        // A session nobody gave a disk has no file for its words to be left in.
        let written = await session.persistUnsent?() ?? true
        discarding.remove(id)
        guard written else { return stand(id, .unremoved, in: session) }
        drop(id)
    }

    /// `discard`, begun and not waited for: what the question's yes calls.
    func discardSoon(_ id: UUID, in session: ShellSession) {
        work { await self.discard(id, in: session) }
    }

    /// Every text for one source, let go as the source is removed: off the page at once — its
    /// question said so — and off the disk before this returns, which is before the Remove
    /// that waits for it says it is done. One on the wire comes back to no entry, and lets go
    /// of whatever it wrote meanwhile (`gone`).
    ///
    /// **Where the write did not land they are not gone, and are not left unsaid**: each
    /// stands on the page again as one that could not be removed from this device
    /// (`unremoved`), behind what else waits, with Discard to try the write again.
    func forget(host raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        let lines = sendings.filter { $0.unsent.host == host }
        let going = lines.map(\.id)
        guard !going.isEmpty else { return }
        // Each text's own write, taken before the entry and its task are let go of.
        let writes = going.compactMap { keeps[$0] }
        for id in going { drop(id) }
        unask(going, in: session)
        for write in writes { await write.value }
        for id in going { await session.store.letGo(unsent: id) }
        guard let persist = session.persistUnsent, await !persist() else { return }
        for was in lines where sending(was.id) == nil {
            sendings.append(Sending(unsent: was.unsent, standing: .unremoved))
            stand(was.id, .unremoved, in: session)
        }
    }

    /// A save of the whole store landed, the texts with it (`ShellSession.write`): the words
    /// of each text that could not be taken off the disk are off it now, and its line goes —
    /// but for one whose own discard is trying that write this moment, which says so itself.
    func written() {
        for line in sendings where line.standing == .unremoved && !discarding.contains(line.id) { drop(line.id) }
    }

    /// Whether the person said `id` goes: its words are on their way out of the file, or
    /// could not be taken out of it. Nothing sends, changes or opens one.
    private func leaving(_ id: UUID) -> Bool {
        discarding.contains(id) || sending(id)?.standing == .unremoved
    }

    private func drop(_ id: UUID) {
        sendings.removeAll { $0.id == id }
        edits[id] = nil
        wroteWith[id] = nil
        targets[id] = nil
        keeps[id] = nil
        mayHaveLanded.remove(id)
        sentUnkept.remove(id)
        discarding.remove(id)
        lastAsked[id] = nil
        out.remove(id)
        dropped.insert(id)
    }

    /// Whether a text's entry went while something waited — its source removed, or its post
    /// seen to have arrived — and, where it did, whatever was held of it since is let go: a
    /// write that landed after the letting go must not leave the text in the store.
    ///
    /// One the person said goes and that could not be taken off the disk (`unremoved`) is
    /// gone to whoever asks here too, and this is one more try at that write.
    private func gone(_ id: UUID, in session: ShellSession) async -> Bool {
        guard sending(id).map({ $0.standing == .unremoved }) ?? true else { return false }
        await session.store.letGo(unsent: id)
        if await wroteGone(in: session), sending(id)?.standing == .unremoved { drop(id) }
        return true
    }

    /// Writes the texts down after one was let go that nothing is left to say of on the page,
    /// and says whether the write landed. **Where it did not, the row left in the file is
    /// stale and is not left to the next launch**: the store holds the text no longer, so a
    /// save is asked for here — every save writes the texts again where they have moved since
    /// the last write of them that landed (`StoreSaver`), this one and each after it. A run
    /// that reads the row back before any did draws it as it was written, and lets it go at
    /// once where its post is among what is held (`ShellSession.adoptUnsent`, `isPost`).
    @discardableResult
    private func wroteGone(in session: ShellSession) async -> Bool {
        guard let persist = session.persistUnsent, await !persist() else { return true }
        session.saveSoon()
        return false
    }

    // MARK: - What a line says

    /// Why `sending` cannot be sent as things stand, or nothing where it can.
    func hold(_ sending: Sending, in session: ShellSession) -> Hold? {
        let host = sending.unsent.host
        guard session.isAdded(host) else { return .noSource }
        guard session.writableSources.contains(where: { $0.host == host }),
              session.mastodon.authorized(host: host, for: .write) != nil
        else { return .signedOut }
        guard writes(sending.unsent, in: session) else {
            return .otherAccount(here: session.mastodon.reader(host: host)?.shown)
        }
        if sending.unsent.answers != nil, answered(sending.unsent, in: session) == nil { return .answeredGone }
        return nil
    }

    /// Whether the sign-in at a text's source is shown to be who wrote it: the same account,
    /// by the id its source gives it — or, for a text nobody could put a name to at the press,
    /// the very sign-in it was pressed under, in the run it was pressed in.
    private func writes(_ unsent: Unsent, in session: ShellSession) -> Bool {
        if let writer = unsent.writerID { return session.mastodon.reader(host: unsent.host)?.id == writer }
        guard let pressed = wroteWith[unsent.id] else { return false }
        return session.mastodon.token(host: unsent.host)?.accessToken == pressed
    }

    /// Who the post an answer is to is by, where this run can still say.
    func whom(_ sending: Sending, in session: ShellSession) -> String? {
        guard let row = sending.unsent.answers?.rowID else { return nil }
        let item = targets[sending.id]?.item ?? session.note(ofRow: row).map { DummyItem($0) }
        guard let item else { return nil }
        let name = item.author.isEmpty ? item.handle ?? "" : item.author
        return name.isEmpty ? nil : name
    }

    /// The post an answer is to, where it is held and still offers an answer — asked of the
    /// row as it is now, not as the sheet opened on it (#179).
    private func answered(_ unsent: Unsent, in session: ShellSession) -> Note? {
        guard let row = unsent.answers?.rowID, let note = session.note(ofRow: row) else { return nil }
        let item = session.held(row) ?? targets[unsent.id]?.item ?? DummyItem(note)
        return session.acts(on: item).offers(.answer) ? note : nil
    }

    // MARK: - Seen to have arrived

    /// A text's words and a post's, as they are compared: with no white space, and each
    /// `@name@host` as the `@name` a source may write it as.
    static func words(_ text: String) -> String {
        text.replacing(/@([A-Za-z0-9_.\-]+)@[A-Za-z0-9.\-]+/) { "@\($0.1)" }.filter { !$0.isWhitespace }
    }

    /// Whether `note` is the post `unsent` became: at its source, by who wrote it, not a
    /// reblog, published no earlier than its source was first asked (`clockSlack` aside), its
    /// words the text's (`words`) — `Note.body`, which is how this app turns what a source
    /// sent into words — and answering the post the text answers, or none where it answers none.
    /// `answering` is that post's id at the source. A text nobody put a name to, or that was
    /// never asked, is nobody's post.
    ///
    /// **And published no later than its source would still have made it**: within the key's
    /// life (`keyLife`) of the last time it was asked (`lastAsked`, or of the first where this
    /// run never asked). The same words posted long after, from anywhere, are another post.
    static func isPost(_ note: Note, of unsent: Unsent, answering: String?, lastAsked: Date? = nil) -> Bool {
        guard note.source.host == unsent.host, !note.isReblog,
              let writer = unsent.writer, note.handle.caseInsensitiveCompare(writer) == .orderedSame,
              let asked = unsent.askedAt, note.postedAt >= asked.addingTimeInterval(-clockSlack),
              note.postedAt <= (lastAsked ?? asked).addingTimeInterval(keyLife),
              words(note.body) == words(unsent.text)
        else { return false }
        let answers = note.refs.first { $0.kind == .answers }?.statusID
        return unsent.answers == nil ? answers == nil : answering != nil && answers == answering
    }

    /// The id at its source of the post a text answers, where this run can say.
    private func answeredID(_ unsent: Unsent, in session: ShellSession) -> String? {
        guard let row = unsent.answers?.rowID else { return nil }
        return session.note(ofRow: row)?.statusID ?? targets[unsent.id]?.item.statusID
    }

    /// Lets go of every text that may have been posted and is now seen to have been: a read
    /// landed its post (`isPost`). Asked each time the session adopts what the store holds.
    func reconcile(in session: ShellSession) {
        for held in sendings where mayHaveLanded.contains(held.id) && held.standing != .onItsWay && held.standing != .waiting {
            let answering = answeredID(held.unsent, in: session)
            let last = lastAsked[held.id]
            guard session.notes.contains(where: { Self.isPost($0, of: held.unsent, answering: answering, lastAsked: last) })
            else { continue }
            arrived(held.id, in: session)
        }
    }

    /// A text seen to have arrived: its line goes now, and its row on disk behind it. **Said
    /// once**, on the strip, as a line that asks nothing and goes at its `×`: words the person
    /// wrote are not let go of without a word.
    private func arrived(_ id: UUID, in session: ShellSession) {
        guard let was = sending(id)?.unsent else { return }
        let kept = keeps[id]
        drop(id)
        session.said.say(Said(.found(id, answer: was.answers != nil), .unconfirmed, host: was.host))
        unask([id], in: session)
        work {
            await kept?.value
            await session.store.letGo(unsent: id)
            await self.wroteGone(in: session)
        }
    }

    /// One read of the writer's own newest posts, which changes nothing this device holds
    /// but this: where the text is among them, **that one post** is landed as a post just
    /// written is — in the store, and under what it answers — and the text is let go. True
    /// where it was found, false where it was not, and nothing where the look could not be had.
    private func look(_ id: UUID, in session: ShellSession) async -> Bool? {
        guard let unsent = sending(id)?.unsent, let writer = unsent.writerID, writes(unsent, in: session),
              let door = session.mastodon.authorized(host: unsent.host, within: Self.lookDeadline, for: .ownPosts)
        else { return nil }
        guard let read = try? await session.reach.account(door, landingIn: session.store).own(of: writer) else {
            return nil
        }
        // Read after the wait: let go of meanwhile, it is not looked for any more.
        guard let held = sending(id)?.unsent else { return true }
        // And the sign-in is still the one the read went with, and may still write there:
        // what another sign-in's read brought is taken in for nobody, and the text stays.
        guard session.mastodon.token(host: held.host)?.accessToken == door.token.accessToken,
              session.mastodon.authorized(host: held.host, for: .write) != nil,
              session.writableSources.contains(where: { $0.host == held.host }), writes(held, in: session)
        else { return nil }
        let answering = answeredID(held, in: session)
        let last = lastAsked[id]
        guard let post = read.first(where: { Self.isPost($0, of: held, answering: answering, lastAsked: last) }) else {
            return false
        }
        await session.store.ingest([post], ifSourceHere: held.host)
        if let root = held.root {
            let rootID = targets[id]?.root.statusID ?? session.note(ofRow: root.rowID)?.statusID
            session.conversations.landed(post, under: root.rowID, rootID: rootID)
        }
        // Adopted, which lets the text go where its post is now held (`reconcile`); and where
        // its source went meanwhile and took nothing in, it is let go here all the same.
        await session.reloadFromStore()
        arrived(id, in: session)
        session.saveSoon()
        return true
    }

    /// Send again on a text that may have been posted: looked for first; where it is not
    /// found and its source still keeps its key, sent again under that key; and otherwise —
    /// not found past the key's life, or the look could not be had — the person is asked.
    private func lookThenSend(_ id: UUID, in session: ShellSession) async {
        let found = await look(id, in: session)
        // Read after the wait: it arrived, was let go with its source, or is no longer looked for
        // — and then it is not out from here any more either, and is drawn from the store again.
        guard let at = sendings.firstIndex(where: { $0.id == id }), sendings[at].standing == .looking else {
            return await settle(id, in: session)
        }
        let asked = sendings[at].unsent.askedAt
        if found == false, let asked, now().timeIntervalSince(asked) < Self.keyLife,
           hold(sendings[at], in: session) == nil {
            sendings[at].standing = .waiting
            pump(sendings[at].unsent.host, in: session)
        } else {
            sendings[at].standing = .unconfirmed
            session.resendingUnsent = UnsentAsk(id: id)
            await settle(id, in: session)
        }
    }

    // MARK: - Sending

    /// Holds `unsent` in the store and writes it down, behind the write before it. Nobody waits
    /// for this but the text's own send.
    private func keep(_ unsent: Unsent, replacing old: UUID? = nil, in session: ShellSession) {
        let before = old.flatMap { keeps.removeValue(forKey: $0) } ?? keeps[unsent.id]
        let id = unsent.id
        keeps[id] = Task {
            await before?.value
            if let old { await session.store.letGo(unsent: old) }
            await self.holding?()
            // Its sender before it is held, so no other window draws it as one to send again.
            _ = await session.store.claim(unsent: id, for: self.sender)
            // Not taken where the text was let go of meanwhile (`ItemStore.hold`): its send
            // asks again, and does not leave on a no.
            await session.store.hold(unsent)
            _ = await session.persistUnsent?()
        }
    }

    private func work(_ body: @escaping @MainActor () async -> Void) {
        let id = UUID()
        works[id] = Task {
            await body()
            self.works[id] = nil
        }
    }

    /// Starts the one send a source has at a time, where none is running: each text that
    /// waits for it, in the order pressed.
    private func pump(_ host: String, in session: ShellSession) {
        guard pumps[host] == nil else { return }
        pumps[host] = Task {
            while let next = self.sendings.first(where: { $0.unsent.host == host && $0.standing == .waiting }) {
                await self.send(next.id, in: session)
            }
            self.pumps[host] = nil
        }
    }

    /// Why a failed request is known not to have been sent, or nothing where that is not
    /// known — and then the text may have been posted.
    ///
    /// **Known only two ways.** The source answered that it would not: a 4xx, which is its own
    /// word that it did nothing (a 401 it stood by, a 403: refused; any other: declined) — but
    /// for the ones something in front of the source can answer after the source made the post
    /// (`answeredInFront`). Or the request never reached anything that could act on it:
    ///
    /// - this app refused it before the wire (`OutwardRefusal`), or `MastodonWrite` threw
    ///   before asking (`noSource`, `unfindable`);
    /// - `badURL`, `unsupportedURL`: no request was made;
    /// - `notConnectedToInternet`, `dataNotAllowed`, `internationalRoamingOff`, `callIsActive`:
    ///   the system had no network to try;
    /// - `cannotFindHost`, `dnsLookupFailed`: no address, so no connection;
    /// - `cannotConnectToHost`: no connection was made, so nothing was written to one;
    /// - `appTransportSecurityRequiresSecureConnection`: refused by the system before connecting;
    /// - `serverCertificateUntrusted`, `serverCertificateHasBadDate`,
    ///   `serverCertificateHasUnknownRoot`, `serverCertificateNotYetValid`,
    ///   `clientCertificateRejected`, `clientCertificateRequired`: the certificates were turned
    ///   down in the handshake, and a request is written only after it.
    ///
    /// **Everything else may have landed**: `timedOut` and `networkConnectionLost` can come
    /// after the request was read; `cancelled` likewise; `secureConnectionFailed` is also what
    /// a fault in the secure channel is called once the connection is carrying the request; a 5xx is a fault somewhere past the
    /// door — a proxy's 502 or 504, or the 500 a real Mastodon gives for a post it holds; a
    /// redirect, a response nobody could parse, and any error this does not name.
    /// The 4xx answers that are not the source's own word that it did nothing: a request or a
    /// gateway timing out (408, and a proxy's 499 for a client it gave up on), a conflict or a
    /// replay refused in front (409, 425), and a limit applied in front (429) can each be
    /// answered by what stands before the source after the source has made the post.
    static let answeredInFront: Set<Int> = [408, 409, 425, 429, 499]

    static func notSent(_ error: any Error) -> WriteWhy? {
        switch error {
        case MastodonAuthError.signedOut, MastodonAuthError.http(401), MastodonAuthError.http(403):
            return .refused
        case MastodonAuthError.http(let status):
            return (400..<500).contains(status) && !Self.answeredInFront.contains(status) ? .declined : nil
        case MastodonWriteError.noSource, MastodonWriteError.unfindable:
            return .unreachable
        case is OutwardRefusal:
            return .unreachable
        case let error as URLError:
            switch error.code {
            case .badURL, .unsupportedURL,
                 .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
                 .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                 .appTransportSecurityRequiresSecureConnection,
                 .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return .unreachable
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// One text, sent. Its states, and every way between them:
    ///
    /// | From | What happens | To |
    /// | ---- | ------------ | -- |
    /// | waiting | its turn: written down as asked, and only then the request goes | on its way |
    /// | waiting | its turn, and its source, who is signed in there or the post it answers is not as it must be | failed, nothing sent |
    /// | waiting | its turn, and it could not be written to this device | unkept, nothing sent |
    /// | on its way | the source's yes: the post is taken in and adopted, and then the entry and its row on disk go | — |
    /// | on its way | a failure known not to have sent it (`notSent`) | failed(why), every character kept |
    /// | on its way | any other failure | unconfirmed: it may have been posted |
    /// | on its way, having been unconfirmed before | any failure at all | unconfirmed still: a try that failed says nothing of the one before it |
    /// | failed | Send again (`again`) | waiting, under the same name |
    /// | unconfirmed | Send again | looking; then gone (found), waiting (not found, key kept), or unconfirmed and asked about |
    /// | unconfirmed | a read lands its post (`reconcile`) | — |
    /// | unkept | Send anyway (`sendUnkept`) | waiting |
    /// | failed, unconfirmed, unkept | what was typed over it is sent (`sendChanged`) | waiting, a new text under a new name |
    /// | failed, unconfirmed, unkept | the person's yes to discarding it | — |
    /// | any | its source is removed (`forget`) | —; a request still out comes back to no entry |
    /// | waiting | its turn, and another window is sending it (`ItemStore.claim`) | on its way, as the store has it; nothing sent from here |
    /// | waiting | its turn, and another window asked its source since this one looked | unconfirmed, nothing sent |
    /// | waiting | its turn, and the store will not hold it: it was let go of | —, nothing sent |
    /// | any, not out from here | the store says it changed (`follow`) | as the store has it |
    /// | failed, unconfirmed, unkept — discarded, or its source removed | the write that takes it off the disk did not land | unremoved |
    /// | unremoved | Discard: the write is tried again, and lands | — |
    ///
    /// **Everything is read again after each wait.** The entry is found by its name each time,
    /// never held across an `await`; the door, who is signed in and the post answered are
    /// asked once more after the last wait before the request (`ready`), with nothing awaited
    /// between that and the request; and an entry that went meanwhile takes with it whatever
    /// was written of it since (`gone`). What is carried across a wait on purpose is the text
    /// itself, which nothing changes while it is out.
    ///
    /// **The entry goes only after the post is adopted**, so nothing says it is being sent
    /// beside the post it became, and no moment shows neither.
    ///
    /// **One sender a text.** The sending is taken in the store before anything is asked
    /// (`ItemStore.claim`) and given back when this ends, however it ends (`settle`); where
    /// another outbox has it, nothing is done here but to draw it as the store has it.
    private func send(_ id: UUID, in session: ShellSession) async {
        guard let at = sendings.firstIndex(where: { $0.id == id }) else { return }
        sendings[at].standing = .onItsWay
        await keeps.removeValue(forKey: id)?.value
        if await session.store.claim(unsent: id, for: sender) { await sendAsSender(id, in: session) }
        await settle(id, in: session)
    }

    /// `send`, once the store has said this outbox is the one sending `id`.
    private func sendAsSender(_ id: UUID, in session: ShellSession) async {
        // The text as the store holds it now: another window may have sent it, and had no
        // yes or no that settles it, since this one last looked. It may have been posted then,
        // and is not sent on the strength of a press made before that was known.
        let held = await session.store.unsentView().texts.first { $0.id == id }
        guard let at = sendings.firstIndex(where: { $0.id == id }) else { return }
        if let held, held != sendings[at].unsent {
            sendings[at].unsent = held
            if held.standing == .asked, !mayHaveLanded.contains(id) { return stand(id, .unconfirmed, in: session) }
        }
        let host = sendings[at].unsent.host
        // Who is signed in there, where its source has not said this run and the text names
        // its writer: asked before anything is decided on it.
        if sending(id)?.unsent.writerID != nil, session.mastodon.reader(host: host) == nil {
            await session.mastodon.learnWho(host: host, within: Self.lookDeadline)
        }
        // Read after the waits, and nothing awaited from here to the write below. Let go of
        // meanwhile, whatever its own write held of it since goes with it.
        guard var unsent = sending(id)?.unsent, sending(id)?.standing != .unremoved else {
            _ = await gone(id, in: session)
            return
        }
        guard ready(unsent, in: session) != nil else { return await missed(id, .unreachable, in: session) }
        // Named now, where it could not be at the press: the sign-in is the one it was pressed
        // under (`writes`), and its source has since said who that is.
        if unsent.writerID == nil, let reader = session.mastodon.reader(host: host) {
            unsent.writerID = reader.id
            unsent.writer = reader.handle
        }
        // Written down as asked before the request leaves: from here it may have landed.
        let before = unsent
        unsent.standing = .asked
        let asking = now()
        unsent.askedAt = unsent.askedAt ?? asking
        if let at = sendings.firstIndex(where: { $0.id == id }) { sendings[at].unsent = unsent }
        // **Not held, not sent**: the store holds no text let go of (`ItemStore.hold`) —
        // discarded or landed through another window, its source removed — and its line goes.
        guard await session.store.hold(unsent) else { return letGoHere(id, in: session) }
        // A session nobody gave a disk holds a text in memory, as it holds everything.
        var written = true
        if let persist = session.persistUnsent { written = await persist() }
        if await gone(id, in: session) { return }
        guard written || sentUnkept.contains(id) else {
            // Not on disk, so it does not leave — and is not held as asked, which it never was.
            if let at = sendings.firstIndex(where: { $0.id == id }) { sendings[at].unsent = before }
            stand(id, .unkept, in: session)
            guard await session.store.hold(before) else { return letGoHere(id, in: session) }
            _ = await gone(id, in: session)
            return
        }
        // **Asked again after the waits, and nothing awaited from here to the request**: the
        // sign-in, who it is, and the post answered are as they are now, not as they were
        // before the write. Where any is not, nothing leaves, and it was never asked.
        guard let (door, answering) = ready(unsent, in: session) else {
            if let at = sendings.firstIndex(where: { $0.id == id }) { sendings[at].unsent = before }
            return await missed(id, .unreachable, in: session)
        }
        lastAsked[id] = asking
        do {
            let note = try await session.reach.write(door, landingIn: session.store)
                .post(unsent.text, visibility: unsent.audience, answering: answering, key: id)
            if let root = unsent.root {
                let rootID = targets[id]?.root.statusID ?? session.note(ofRow: root.rowID)?.statusID
                session.conversations.landed(note, under: root.rowID, rootID: rootID)
            }
            await session.reloadFromStore()
            drop(id)
            await session.store.letGo(unsent: id)
            // The post is the source's, and is written behind its landing — by a save that
            // writes the texts again too, where the write of them here did not land.
            if await wroteGone(in: session) { session.saveSoon() }
        } catch {
            session.writeFailed(error, host: host)
            if let why = Self.notSent(error) {
                await missed(id, why, in: session)
            } else {
                stand(id, .unconfirmed, in: session)
            }
        }
    }

    /// What a text needs to leave, as things stand at this moment: a sign-in at its source that
    /// may write and is shown to be who wrote it, and — for an answer — the post it answers,
    /// held and still answerable. Nothing where any is missing. No wait inside.
    private func ready(_ unsent: Unsent, in session: ShellSession) -> (door: MastodonAuthorized, answering: Note?)? {
        let host = unsent.host
        guard let door = session.mastodon.authorized(host: host, for: .write),
              session.writableSources.contains(where: { $0.host == host }),
              writes(unsent, in: session)
        else { return nil }
        guard unsent.answers != nil else { return (door, nil) }
        guard let note = answered(unsent, in: session) else { return nil }
        return (door, note)
    }

    /// A send known not to have gone: the entry says why, and what is written down says
    /// whether the source answered — never, for this try, that it may have landed.
    private func missed(_ id: UUID, _ why: WriteWhy, in session: ShellSession) async {
        guard var unsent = sending(id)?.unsent else { return }
        // It may have landed before this try: what is drawn and written goes on saying so.
        guard !mayHaveLanded.contains(id) else { return stand(id, .unconfirmed, in: session) }
        stand(id, .failed(why), in: session)
        switch why {
        case .refused: unsent.standing = .refused
        case .declined: unsent.standing = .declined
        case .unreachable, .locked, .unconfirmed: unsent.standing = .unreachable
        }
        if let at = sendings.firstIndex(where: { $0.id == id }) { sendings[at].unsent.standing = unsent.standing }
        guard await session.store.hold(unsent) else { return letGoHere(id, in: session) }
        if await gone(id, in: session) { return }
        _ = await session.persistUnsent?()
    }

    /// A text the store will not hold: it was let go of, and whoever did so writes that down.
    /// Its line goes from here too, with any sheet or question about it.
    private func letGoHere(_ id: UUID, in session: ShellSession) {
        drop(id)
        unask([id], in: session)
    }

    /// Where a send ended, drawn and said aloud once.
    ///
    /// One the person said goes stays as that (`unremoved`), whatever a request of its own
    /// still out comes back with.
    private func stand(_ id: UUID, _ standing: Standing, in session: ShellSession) {
        guard let at = sendings.firstIndex(where: { $0.id == id }),
              sendings[at].standing != .unremoved || standing == .unremoved
        else { return }
        if standing == .unconfirmed { mayHaveLanded.insert(id) }
        sendings[at].standing = standing
        let ended = sendings[at]
        session.said.announce(OutboxWords.line(ended, hold: hold(ended, in: session), whom: whom(ended, in: session)))
    }

    /// Every send, look, write and discard begun before this call has ended, and whatever
    /// those began. What a test awaits before it looks.
    func settled() async {
        while let task = pumps.values.first ?? works.values.first ?? keeps.values.first {
            await task.value
            for (id, kept) in keeps where kept == task { keeps[id] = nil }
        }
    }
}

/// A text of the outbox's that a sheet or a question is about, by its name.
struct UnsentAsk: Identifiable, Equatable {
    let id: UUID
}

/// What a line of the outbox's says, and the words of its presses.
@MainActor
enum OutboxWords {
    /// What may be done to a text that waits.
    enum Press: String, CaseIterable, Sendable {
        case again, anyway, edit, copy, discard
    }

    /// The presses a line offers: none while it is out; its words to take elsewhere, or to let
    /// go, where it cannot be sent as things stand (`ShellOutbox.Hold`); to send it all the
    /// same, where it could not be kept on this device; and otherwise to send it again, change
    /// it or discard it.
    static func presses(_ sending: ShellOutbox.Sending, hold: ShellOutbox.Hold?) -> [Press] {
        if sending.isOut { return [] }
        // Asked to go already: the one thing left is to try taking it off the disk again.
        if sending.standing == .unremoved { return [.discard] }
        if hold != nil { return [.copy, .discard] }
        return sending.standing == .unkept ? [.anyway, .copy, .discard] : [.again, .edit, .discard]
    }

    static func word(_ press: Press, language: DummyLanguage? = nil) -> String {
        L10n.t("outbox.\(press.rawValue)", language: language)
    }

    /// A press as VoiceOver names it: with the source its text waits for, since a page may
    /// hold several.
    static func spoken(_ press: Press, host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("outbox.\(press.rawValue).spoken", language: language), host)
    }

    /// The glyph before a line: on its way, may have landed, or did not go — the last the
    /// strip's own.
    static func symbol(_ sending: ShellOutbox.Sending) -> String {
        switch sending.standing {
        case .waiting, .onItsWay: "paperplane"
        case .looking: "magnifyingglass"
        case .unconfirmed: "questionmark.circle"
        case .failed, .unkept, .unremoved: SaidStrip.symbol
        }
    }

    /// The line, in one sentence: a post's or an answer's, by where it stands.
    static func line(
        _ sending: ShellOutbox.Sending, hold: ShellOutbox.Hold?, whom: String?, language: DummyLanguage? = nil
    ) -> String {
        let host = sending.unsent.host
        let kind = sending.unsent.answers == nil ? "post" : "answer"
        func said(_ key: String) -> String {
            String(format: L10n.t("outbox.\(key).\(kind)", language: language), host)
        }
        switch sending.standing {
        case .waiting, .onItsWay:
            guard kind == "answer", let whom else { return said("sending") }
            return String(format: L10n.t("outbox.sending.answer.to", language: language), host, LineText.oneLine(whom))
        case .looking:
            return said("looking")
        // Said before anything of its source: it is here whatever became of that.
        case .unremoved:
            return said("unremoved")
        case .failed, .unconfirmed, .unkept:
            break
        }
        switch hold {
        case .noSource?: return said("hold.noSource")
        case .answeredGone?: return said("hold.answered")
        case .otherAccount(let here)?:
            // A handle is its source's word: set in a sentence of ours only made fit for one.
            guard let writer = sending.unsent.writer.map({ LineText.oneLine($0) }) else { return said("hold.unnamed") }
            guard let here else {
                return String(format: L10n.t("outbox.hold.other.unknown.\(kind)", language: language), host, writer)
            }
            return String(format: L10n.t("outbox.hold.other.\(kind)", language: language), host, writer, here)
        // A refusal says more than that nobody may write there now.
        case .signedOut? where sending.standing != .failed(.refused): return said("hold.signedOut")
        case .signedOut?, nil: break
        }
        switch sending.standing {
        case .waiting, .onItsWay: return said("sending")
        case .looking: return said("looking")
        case .unconfirmed, .failed(.unconfirmed): return said("unconfirmed")
        case .unkept: return said("unkept")
        case .unremoved: return said("unremoved")
        case .failed(.refused): return said("refused")
        case .failed(.declined): return said("declined")
        case .failed(.locked), .failed(.unreachable): return said("failed")
        }
    }

    /// The opening of a text, as a question names it: fit to stand in one line of ours.
    static func opening(_ text: String) -> String {
        LineText.oneLine(text, limit: 80)
    }
}

extension ShellSession {
    /// Sends the composer's draft: **the press takes the text** — it is the outbox's from here,
    /// the draft is empty, and the sheet closes — and its source is asked behind it. False
    /// where there is nothing sendable or no source to send through: the sheet stays, and the
    /// draft is untouched.
    ///
    /// A failure throws nothing: the text waits in the outbox, every character, and is said on
    /// every page.
    @discardableResult
    func send() -> Bool {
        let text = ComposerSheet.trimmed(composeDraft)
        guard !text.isEmpty, let host = composeHost,
              writableSources.contains(where: { $0.host == host }),
              text.count <= postLimit(of: host),
              mastodon.authorized(host: host, for: .write) != nil
        else { return false }
        let writer = mastodon.reader(host: host)
        outbox.take(
            Unsent(host: host, text: text, audience: composeAudience, writerID: writer?.id, writer: writer?.handle),
            in: self
        )
        composeDraft = ""
        return true
    }

    /// Sends the answer to the source the post was read through — **the post decides it; it is
    /// not a choice** — as `send()` sends a post: the press takes the text, the draft and the
    /// reach chosen for it go, and the sheet closes. What lands is laid into the conversation
    /// under what it answers.
    ///
    /// False where it cannot go — nothing sendable, or the post no longer offers an answer,
    /// asked of the row as it is now (#179): the sheet stays, and the draft is untouched.
    @discardableResult
    func send(answer target: AnswerTarget) -> Bool {
        let item = target.item
        let host = item.source.host
        let text = ComposerSheet.trimmed(answerDraft(target))
        guard !text.isEmpty, text.count <= postLimit(of: host),
              acts(on: held(item.id) ?? item).offers(.answer),
              let answered = note(ofRow: item.id),
              mastodon.authorized(host: host, for: .write) != nil
        else { return false }
        let writer = mastodon.reader(host: host)
        let unsent = Unsent(
            host: host, text: text, audience: answerReach[item.id] ?? target.start,
            answers: answered.key, root: NoteKey(rowID: target.root.id),
            writerID: writer?.id, writer: writer?.handle
        )
        outbox.take(unsent, answering: target, in: self)
        answerDrafts[item.id] = nil
        answerReach[item.id] = nil
        answering = nil
        return true
    }

    /// Sends a text that waits from the sheet opened on it (`ShellOutbox.edit`), and closes the
    /// sheet. Unchanged, it is Send again (`ShellOutbox.again`). Changed, it is a different post
    /// under a new name — sent at once where the first is known not to have gone, and **asked
    /// about first where the first may have been posted** (`resendingUnsent`), since both would
    /// then stand. False where it cannot go as things stand, or is empty or too long: the sheet
    /// stays.
    @discardableResult
    func send(unsent id: UUID) -> Bool {
        guard let held = outbox.sending(id), !held.isOut, outbox.hold(held, in: self) == nil else { return false }
        let text = ComposerSheet.trimmed(outbox.draft(id))
        guard !text.isEmpty, text.count <= postLimit(of: held.unsent.host) else { return false }
        editingUnsent = nil
        guard outbox.changed(id) != nil else {
            return held.standing == .unkept ? outbox.sendUnkept(id, in: self) : outbox.again(id, in: self)
        }
        guard outbox.mayHaveBeenPosted(id) else { return outbox.sendChanged(id, in: self) != nil }
        resendingUnsent = UnsentAsk(id: id)
        return true
    }
}
