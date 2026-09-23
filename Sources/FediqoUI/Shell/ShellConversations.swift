import FediqoCore
import Foundation
import Observation

// The conversation around one microblog post, fetched when the post is opened — #90.
//
// A forum thread's answers are `ForumPosts`': they come off the page the opening post came off.
// A microblog thread is one request to one endpoint about one post the reader has just pressed
// Return on, so it is asked for the moment the pane opens and nothing is asked of the reader
// twice — and since #198 a forum topic's first page is too, and both are asked again on the wait.
//
// **Nothing here reaches the store's list of rows.** What comes back is drawn, and what comes
// back for a row this device already holds is handed to `ItemStore.refresh`, which replaces held
// rows and admits none — so an answer this device never held is read in the thread and does not
// turn up in All afterwards. That property is `ShellReload`'s and is stated in its doc; this unit
// took over the request and keeps it.
//
// **Since #177 what comes back lands in the store first, held aside** — written down and saved,
// and still never a row All grew by (#175). So a thread read once is there with the network off:
// a read that finds nobody answering draws what this device holds around the post, and says at
// the foot that the rest did not arrive. And a thread the source handed back only part of is read
// further as the reader nears its foot, one ask at a time, until the source has nothing more.

/// Why a thread ended where it did, as far as asking again goes: one question both kinds of
/// absence answer, so the foot of a thread reads either the same way.
protocol ShellThreadAbsence: Equatable, Sendable {
    /// Whether asking again could ever change the answer by itself.
    var asksAgain: Bool { get }
}

/// How far an open thread has been read toward its end (#177) — **what its foot says**.
///
/// Five states and no sixth, for `ShellConversationStanding`'s reason: "there is more and it will
/// be asked for", "it is on the wire", "the source said this is all", "the source says there is
/// more and gives no way to ask for it here" and "the next part did not arrive" are five
/// sentences, and the third is the one #177 exists to say — a thread that ended is not a thread
/// still waiting, and **neither is a thread the source cut**, which is why that one is not `end`.
enum ShellThreadFurther<Absence: ShellThreadAbsence>: Equatable, Sendable {
    /// The source has more. Asked for as the foot comes into view, or on a press.
    case more
    /// The next part is on the wire.
    case coming
    /// The source has nothing after what is drawn.
    case end
    /// The source counts answers that are not drawn, and nothing this device may ask brings them:
    /// a server that hands back only so many answers to one post, with no way to page past them.
    /// Not the end — saying so would be the lie #177 was filed about — and not worth asking again.
    case cut
    /// The next part did not arrive, and why. What already arrived stays drawn above it.
    case failed(Absence)

    /// Whether asking for the next part could do anything from here — **the one answer the foot,
    /// its button and the key all read**. No `default:`: a sixth state has to say.
    var wantsAsking: Bool {
        switch self {
        case .more: true
        case .failed(let absence): absence.asksAgain
        case .coming, .end, .cut: false
        }
    }
}

/// What is known about the conversation around one post right now.
///
/// **Five states and no sixth**, `ForumRepliesStanding`'s shape and for its reason: "not asked
/// yet", "on the wire", "the source answered and this post is alone" and "it could not be had"
/// are four different sentences, and a `[Note]?` says one thing for all four.
enum ShellConversationStanding: Equatable, Sendable {
    /// Nothing has asked yet. The pane asks as it opens, so a reader sees this for one pass.
    case unasked
    /// On the wire.
    case coming
    /// The source answered and there is nobody else in this thread.
    case none
    /// The two halves, **as the source ordered them**, kept rather than the conversation built
    /// from them.
    ///
    /// The built conversation carries the root row, and the root row is a value that changes
    /// under the reader — a mark pressed, a cover lifted, a card turned. Holding one here would
    /// hold the row as it was when the thread landed, and the pane would draw a post whose marks
    /// stopped answering. So the halves are held and `conversation(around:)` builds against
    /// whichever root the pane has this pass, which is the same thing `dummyConversation()` does
    /// and costs the same walk.
    case loaded(ancestors: [Note], descendants: [Note], rootID: String?)
    /// It could not be had, and why.
    case absent(ShellConversations.Absence)

    /// The conversation to draw around `root`, or nothing where there is none to draw.
    func conversation(around root: DummyItem) -> DummyConversation? {
        guard case .loaded(let ancestors, let descendants, let rootID) = self else { return nil }
        return .around(root, rootID: rootID, ancestors: ancestors, descendants: descendants)
    }

    /// Whether asking again could do anything from here — **the one answer the button and the
    /// key both read**, `ForumRepliesStanding.wantsPressing`'s rule and for its reason: a mark
    /// the key will not press, or a key that acts where no mark is drawn, is two ways of saying
    /// one thing differently.
    ///
    /// **No `default:`.** A sixth standing has to say whether it can be pressed.
    var wantsPressing: Bool {
        switch self {
        case .absent(let absence): absence.asksAgain
        case .unasked, .coming, .none, .loaded: false
        }
    }
}

/// Every open thread's conversation, for as long as this run wants it.
///
/// On the session for the reason the picture caches and `ForumPosts` are: what Clear presses and
/// what a pane draws have to be the same object, and a second one reached for at a call site is
/// an agreement a test or a preview breaks in silence.
@MainActor
@Observable
final class ShellConversations {
    /// Why there is no conversation, and — the part that matters — whether asking again could
    /// change it.
    ///
    /// Narrower than Core's errors, `ForumPosts.Absence`'s rule: the source has many ways to
    /// fail and a pane has three things to say about them. Every one is mapped in
    /// `absence(for:)` over a `switch` with no `default:`.
    enum Absence: ShellThreadAbsence {
        /// The source answered and said no: a filter, a block, a token that may not ask.
        /// Signing in — or signing in again — is what would change this, not waiting.
        case refused
        /// This device cannot name the post on its own server, so there is nothing to ask about.
        /// A row stored before its server id was kept, read by somebody signed out.
        case unfindable
        /// Nothing answered. The address may be good and the network simply dark, so this is the
        /// one kind of nothing that is worth pressing again.
        case unreachable

        /// Whether asking again could ever change the answer by itself.
        var asksAgain: Bool { self == .unreachable }

        /// What the pane says about it. The host, because which server refused is the fact a
        /// reader acts on.
        func sentence(host: String, language: DummyLanguage? = nil) -> String {
            switch self {
            case .refused: String(format: L10n.t("thread.around.refused", language: language), host)
            case .unfindable: String(format: L10n.t("thread.around.unfindable", language: language), host)
            case .unreachable: L10n.t("thread.around.unreachable", language: language)
            }
        }
    }

    /// Keyed by the row's own id — `NoteKey.rowID`, so one post held from two servers is two
    /// threads, which is what #10 says it is everywhere else.
    private(set) var standings: [String: ShellConversationStanding] = [:]
    /// Which host each key was read from, so `forget(host:)` is a sweep and not a search.
    @ObservationIgnored private var hosts: [String: String] = [:]
    /// What is on the wire, so a redraw that asks again while the first ask is out waits for it
    /// rather than starting a second.
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

    /// How long one request may take before the thread counts as unreachable. A reader is
    /// waiting on a key they pressed; `ShellReload` says the same in the same words.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    /// How far each loaded thread has been read toward its end (#177). Nothing for one that is not
    /// loaded, whose foot is its standing's to draw.
    private(set) var furthers: [String: ShellThreadFurther<Absence>] = [:]
    /// The posts whose own thread has been asked for, per open thread — the post itself first. A
    /// post asked once is not asked again this run, so a count of answers the source will not
    /// show (a private one, a deleted one) cannot keep a thread asking for ever.
    @ObservationIgnored private var asked: [String: Set<String>] = [:]
    /// A further ask on the wire, per thread, so a foot drawn twice waits on one.
    @ObservationIgnored private var furtherWork: [String: Task<Void, Never>] = [:]
    /// Threads whose foot failed on **the thread itself** — its first read, or `r` — rather than
    /// on a part further down: trying again there asks the whole thread again.
    @ObservationIgnored private var failedAtRoot: Set<String> = []
    /// Threads whose foot waits for the reader rather than reading on by itself: one the reader
    /// stopped (Esc, or closing it), and one that has asked `autoAsks` times running with nobody
    /// pressing — so a thread of hundreds does not chain request after request as it scrolls.
    /// `ForumPosts.heldBack`'s rule, and for its reason: a stop that the foot undid at once would
    /// spend every Esc on stopping, and the reader could not leave by key.
    private(set) var heldBack: Set<String> = []
    /// How many further asks the foot made by itself since the reader last pressed.
    @ObservationIgnored private var asksRunning: [String: Int] = [:]
    /// How many a foot may make by itself before it waits for a press.
    nonisolated static let autoAsks = 5

    /// Whether the foot of the thread around `id` is waiting for the reader.
    func isHeldBack(_ id: String) -> Bool { heldBack.contains(id) }

    /// The foot in view — **the automatic ask**. `appeared` is the foot coming into view again,
    /// which lets go of a stop, and never of the count: only a press does that.
    func reached(_ item: DummyItem, appeared: Bool, in session: ShellSession) async {
        if appeared { heldBack.remove(item.id) }
        guard !heldBack.contains(item.id), furthers[item.id] == .more else { return }
        guard asksRunning[item.id, default: 0] < Self.autoAsks else {
            heldBack.insert(item.id)
            return
        }
        asksRunning[item.id, default: 0] += 1
        await more(item, in: session)
    }

    /// The reader pressing the foot, or its button: asked at once, and the count starts again.
    func press(_ item: DummyItem, in session: ShellSession) async {
        heldBack.remove(item.id)
        asksRunning[item.id] = 0
        await more(item, in: session)
    }

    func standing(of id: String) -> ShellConversationStanding {
        standings[id] ?? .unasked
    }

    /// How far the thread around `id` has been read, where it is loaded.
    func further(of id: String) -> ShellThreadFurther<Absence>? {
        furthers[id]
    }

    /// The conversation to draw around `item` — **the one answer the pane and the keys both
    /// read.**
    ///
    /// The pane draws these rows and the root walks them with `j`, `k` and `Return`; a list the
    /// keys walked that was not the list on screen would put the lamp on a post the reader
    /// cannot see. One function, so the two cannot come apart.
    func conversation(around item: DummyItem) -> DummyConversation {
        standing(of: item.id).conversation(around: item) ?? item.dummyConversation()
    }

    /// The thread around `item`, where nothing has asked for it yet — **the pane opening**.
    ///
    /// Asked once per post per run. A pane that opens, closes and opens again draws what it
    /// already has rather than asking the server the same question twice; `again(_:in:)` is the
    /// reader saying they want it asked.
    func open(_ item: DummyItem, in session: ShellSession) async {
        guard standings[item.id] == nil else {
            await inFlight[item.id]?.value
            return
        }
        await ask(item, in: session)
    }

    /// `r` on an open thread (#29): asked again, whatever it said last time. What is held stays
    /// drawn until the answer replaces it — a thread that blanks and refills under a reader who
    /// pressed reload is the reload showing them less than they had.
    func again(_ item: DummyItem, in session: ShellSession) async {
        await ask(item, in: session)
    }

    /// The open thread asked again on this device's wait (#198) — `again(_:in:)`'s read, with what
    /// is drawn staying drawn and the foot saying it is on its way, and failed where it did not
    /// arrive. Only a thread that has been read: one still on its first ask, or being read further,
    /// is let be, and the next wait asks again. Cancelled — the thread left — nothing it brings
    /// lands, and the thread is as it was.
    func renew(_ item: DummyItem, in session: ShellSession) async {
        guard inFlight[item.id] == nil, furtherWork[item.id] == nil else { return }
        switch standing(of: item.id) {
        case .loaded, .none: break
        case .absent(let absence) where absence.asksAgain: break
        case .unasked, .coming, .absent: return
        }
        let task = Task { @MainActor in await self.read(item, in: session) }
        inFlight[item.id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if inFlight[item.id] == task { inFlight[item.id] = nil }
    }

    /// Every post drawn in a loaded thread, by key — what `renew(from:)` asks the store for.
    var drawnKeys: Set<NoteKey> {
        var keys: Set<NoteKey> = []
        for standing in standings.values {
            guard case .loaded(let ancestors, let descendants, _) = standing else { continue }
            keys.formUnion((ancestors + descendants).map(\.key))
        }
        return keys
    }

    /// **What this device now holds of each drawn post, drawn in its place** (#193, #198). A thread
    /// keeps the order its source gave and the posts it drew; each post is the store's copy of it,
    /// so an answer another read edited, or its source said was gone (#179), reads so here with no
    /// key pressed. A post the store no longer holds keeps the copy drawn. Nothing is assigned
    /// where nothing moved, so an adopt that changed no drawn post redraws no thread.
    func renew(from held: [NoteKey: Note]) {
        guard !held.isEmpty else { return }
        for (id, standing) in standings {
            guard case .loaded(let ancestors, let descendants, let rootID) = standing else { continue }
            let swap = { (drawn: Note) in held[drawn.key] ?? drawn }
            let renewed = ShellConversationStanding.loaded(
                ancestors: ancestors.map(swap), descendants: descendants.map(swap), rootID: rootID
            )
            if renewed != standing { standings[id] = renewed }
        }
    }

    /// The note behind a row drawn in a conversation, where one of the loaded halves holds it.
    ///
    /// **An answer read in a thread is not a row `session.notes` holds** — it is held aside, see
    /// this file's header — so an act
    /// pressed on one has to find its note here, or the mark under it would be a control that is
    /// drawn and does nothing.
    func note(_ rowID: String) -> Note? {
        for standing in standings.values {
            guard case .loaded(let ancestors, let descendants, _) = standing else { continue }
            if let found = (ancestors + descendants).first(where: { $0.key.rowID == rowID }) {
                return found
            }
        }
        return nil
    }

    /// What a source answered to an act on a row held here, laid in where the row was, in every
    /// thread that holds it — so the mark under an answer in an open conversation says what the
    /// source said, as the timeline's does (#106).
    func replace(_ note: Note) {
        for (id, standing) in standings {
            guard case .loaded(let ancestors, let descendants, let rootID) = standing else { continue }
            let swap = { (held: Note) in held.key == note.key ? note : held }
            standings[id] = .loaded(
                ancestors: ancestors.map(swap), descendants: descendants.map(swap), rootID: rootID
            )
        }
    }

    /// A post taken back (#109), let go of in every thread that drew it. The answers under it
    /// stay until the thread is read again: whether they went with it is the source's to say.
    func drop(_ key: NoteKey) {
        for (id, standing) in standings {
            guard case .loaded(let ancestors, let descendants, let rootID) = standing else { continue }
            standings[id] = .loaded(
                ancestors: ancestors.filter { $0.key != key },
                descendants: descendants.filter { $0.key != key },
                rootID: rootID
            )
        }
    }

    /// An answer the reader wrote from inside this thread, placed under what it answers (#108).
    ///
    /// **Laid into the halves the source handed back rather than asked for again.** The reader is
    /// looking at the conversation they answered; a full read to show them their own words would
    /// be a thread that blanks and refills under them, and a thread still on the wire when this
    /// lands will bring the answer with it anyway, because the source now holds it.
    ///
    /// A thread that was alone, or not yet asked, becomes a thread with this one answer in it: the
    /// reader has just made it a conversation. One that could not be had is left as it is, since
    /// drawing a single answer under a sentence saying the thread could not be read would be two
    /// things saying opposite things about one pane.
    func landed(_ note: Note, under root: String, rootID: String?) {
        switch standing(of: root) {
        case .loaded(let ancestors, let descendants, let held):
            standings[root] = .loaded(
                ancestors: ancestors,
                descendants: Self.placed(note, in: descendants, rootID: held ?? rootID),
                rootID: held ?? rootID
            )
        case .unasked, .none, .coming:
            standings[root] = .loaded(ancestors: [], descendants: [note], rootID: rootID)
            hosts[root] = note.source.host
        case .absent:
            break
        }
    }

    /// Where an answer goes among the answers already drawn: **directly after the last post under
    /// the one it answers**, so it reads in its place rather than at the bottom of the thread.
    ///
    /// The depths are `DummyConversation.around`'s walk, done once more over the notes; a parent
    /// this device cannot find among them is the post the thread is about, whose subtree is the
    /// whole list, so the answer goes last. Already present, it is not placed twice.
    static func placed(_ note: Note, in descendants: [Note], rootID: String?) -> [Note] {
        guard !descendants.contains(where: { $0.key == note.key }) else { return descendants }
        var depths: [String: Int] = [:]
        if let rootID { depths[rootID] = 0 }
        var depth: [Int] = []
        for held in descendants {
            let parent = held.reply?.inReplyToId.flatMap { depths[$0] }
            let own = (parent ?? 0) + 1
            if let id = held.statusID { depths[id] = own }
            depth.append(own)
        }
        guard let parentID = note.reply?.inReplyToId,
              let at = descendants.firstIndex(where: { $0.statusID == parentID })
        else { return descendants + [note] }
        var index = at + 1
        while index < descendants.count, depth[index] > depth[at] { index += 1 }
        var placed = descendants
        placed.insert(note, at: index)
        return placed
    }

    /// Lets go of one server's threads: `Remove`, and `Clear`. Keyed by host rather than swept by
    /// reading the notes back, because the notes may be gone by the time this is called.
    func forget(host raw: String) {
        let host = raw.lowercased()
        for (id, from) in hosts where from == host {
            standings[id] = nil
            hosts[id] = nil
            inFlight[id]?.cancel()
            inFlight[id] = nil
            furtherWork[id]?.cancel()
            furtherWork[id] = nil
            furthers[id] = nil
            asked[id] = nil
            failedAtRoot.remove(id)
            heldBack.remove(id)
            asksRunning[id] = nil
        }
    }

    func clear() {
        for task in inFlight.values { task.cancel() }
        for task in furtherWork.values { task.cancel() }
        inFlight = [:]
        furtherWork = [:]
        standings = [:]
        furthers = [:]
        asked = [:]
        failedAtRoot = []
        heldBack = []
        asksRunning = [:]
        hosts = [:]
    }

    /// One ask, deduplicated: a second while the first is out waits on it.
    private func ask(_ item: DummyItem, in session: ShellSession) async {
        if let running = inFlight[item.id] {
            await running.value
            return
        }
        let task = Task { @MainActor in await self.read(item, in: session) }
        inFlight[item.id] = task
        await task.value
        inFlight[item.id] = nil
    }

    /// The read itself. Cancelled — the reader closed the thread, or stopped the reload — it
    /// leaves the standing exactly as it found it: a thread half-read is not a thread that failed.
    private func read(_ item: DummyItem, in session: ShellSession) async {
        // **Settled rather than left unasked, both times.** A forum thread's answers are
        // `ForumPosts`' and a row this device does not hold is a fixture or a row a Remove took
        // — neither has a conversation this unit can ask for, and neither is *waiting* for one.
        // The pane draws an unasked standing as coming, so a post this returns from in silence
        // would wait for an answer nothing is going to bring.
        guard let held = session.heldNote(item.id),
              // The server's own answer where it has given one — #86. A host that has stopped
              // being a Mastodon has no conversation this unit can ask it for, whatever the row
              // was stored as.
              session.flavours.speaking(held.source.host, storedAs: held.source.kind) == .mastodon
        else {
            standings[item.id] = ShellConversationStanding.none
            return
        }
        let host = held.source.host
        hosts[item.id] = host
        let before = standings[item.id]
        let furtherBefore = furthers[item.id]
        // **A thread drawn stays drawn while it is asked again** — the pane's foot says it is on
        // its way, where blanking it would show the reader less than they had for a whole ask.
        // A post the source said was alone stays alone meanwhile too: asked again on the wait
        // (#198), it would otherwise say it is loading once a minute.
        switch before {
        case .loaded?: furthers[item.id] = .coming
        case .some(ShellConversationStanding.none): break
        default: standings[item.id] = .coming
        }
        let stamp = Source(host: host, kind: held.source.kind)
        do {
            let (post, signedIn) = session.conversationPost(host: host, within: deadline)
            guard let id = try await post.id(of: held) else {
                // The rule every other failure keeps: a thread already drawn stays drawn.
                await failed(item, held: held, before: before, why: .unfindable, in: session)
                return
            }
            try Task.checkCancellation()
            let thread: MastodonThread
            do {
                thread = try await post.conversation(id: id, source: stamp)
            } catch {
                // Asked by the post's own id, so this is the source speaking of this one post
                // (#179): it stays, marked, and the thread still says it could not be had.
                if await session.sourceSaysGone(error, of: held, id: id, signedIn: signedIn, within: deadline) {
                    try Task.checkCancellation()
                    await session.markGone(held.key)
                }
                throw error
            }
            try Task.checkCancellation()
            // **Into the store first, held aside** (#177): every post of the thread is written
            // down and saved, and none of them is a row All grew by. Held rows that appear in it
            // are refreshed on the way past — an answer this device already has shows its new
            // words in the timeline too.
            //
            // **And the session is told**, here rather than at the caller. This read happens
            // from two places — the pane opening and `r` — and only one of them used to adopt
            // the store afterwards, so an edit that landed on the way past a thread showed in
            // the thread and not in the stream under it until something else asked.
            // Only where a held row did change: a thread of rows this device never held refreshes
            // nothing, and adopting then would be a round trip to the store for nothing.
            if await Self.land(thread.ancestors + thread.descendants, host: host, in: session) {
                await session.reloadFromStore()
            }
            failedAtRoot.remove(item.id)
            if thread.isAlone {
                standings[item.id] = ShellConversationStanding.none
                furthers[item.id] = nil
                return
            }
            // A thread read again keeps what was read further of it before, below what the
            // source handed back this time: the reader is not sent back to its first answer.
            var descendants = thread.descendants
            if case .loaded(_, let drawn, _)? = before {
                let fresh = Set(descendants.map(\.key))
                descendants += drawn.filter { !fresh.contains($0.key) }
            }
            asked[item.id] = (asked[item.id] ?? []).union([id])
            standings[item.id] = .loaded(ancestors: thread.ancestors, descendants: descendants, rootID: id)
            furthers[item.id] = Self.settled(
                root: held, rootID: id, descendants: descendants, asked: asked[item.id] ?? []
            )
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            await failed(item, held: held, before: before, why: .refused, in: session)
        } catch let error where Cancellation.happened(error) {
            standings[item.id] = before
            furthers[item.id] = furtherBefore
        } catch {
            await failed(item, held: held, before: before, why: Self.absence(for: error), in: session)
        }
    }

    /// A thread read that did not come back. **What already arrived stays** (#177): a thread drawn
    /// before stays drawn, and one this device kept from an earlier read is drawn from the store —
    /// with the network off, the thread read yesterday — and either way the foot says the rest did
    /// not arrive. Only where nothing is held is the whole thread the sentence.
    private func failed(
        _ item: DummyItem, held: Note, before: ShellConversationStanding?, why: Absence,
        in session: ShellSession
    ) async {
        // **Where it failed is kept with it**: the foot's "try again" has to ask what did not
        // arrive, and that was the whole thread, not a part further down it.
        if case .loaded? = before {
            standings[item.id] = before
            furthers[item.id] = .failed(why)
            failedAtRoot.insert(item.id)
            return
        }
        let kept = await session.store.held(host: held.source.host)
        if let around = Self.kept(around: held, among: kept) {
            standings[item.id] = .loaded(
                ancestors: around.ancestors, descendants: around.descendants, rootID: held.statusID
            )
            furthers[item.id] = .failed(why)
            failedAtRoot.insert(item.id)
        } else {
            standings[item.id] = .absent(why)
        }
    }

    /// The thread around `item` read further (#177): the next post whose own answers the source
    /// has not all handed back is asked for its thread, and what comes back that is not drawn yet
    /// lands in the store and then goes under what is. **The reader nearing the foot**, or pressing
    /// for it; nothing where the thread is not loaded or has no more to ask.
    ///
    /// A server hands back only so much of one thread in one answer — sixty answers to a reader
    /// who is not signed in, on Mastodon, and only so deep — and cuts it at the end of the order it
    /// walks the thread in. So what is missing is under the last post drawn, or under the posts it
    /// answers; each of those is asked in turn, the deepest first, and its answers follow every
    /// post already drawn. The post being read does not move.
    ///
    /// **Never left saying it is on its way.** A foot that asked and found nothing to ask is
    /// settled — the end, or cut — and one whose post this device no longer holds says it cannot
    /// be named; a foot that stayed at `more` would draw "reading further" for ever.
    func more(_ item: DummyItem, in session: ShellSession) async {
        if let running = furtherWork[item.id] {
            await running.value
            return
        }
        guard let further = furthers[item.id], further.wantsAsking else { return }
        // The whole thread is what did not arrive, so the whole thread is what is asked again.
        if failedAtRoot.contains(item.id) {
            await again(item, in: session)
            return
        }
        guard case .loaded(_, let descendants, let rootID) = standing(of: item.id) else { return }
        guard let rootID, let held = session.heldNote(item.id) else {
            furthers[item.id] = .failed(.unfindable)
            return
        }
        guard let edge = Self.edge(below: rootID, in: descendants, asked: asked[item.id] ?? []) else {
            furthers[item.id] = Self.settled(
                root: held, rootID: rootID, descendants: descendants, asked: asked[item.id] ?? []
            )
            return
        }
        furthers[item.id] = .coming
        let task = Task { @MainActor in
            await self.readFurther(item, from: edge, held: held, was: further, in: session)
        }
        furtherWork[item.id] = task
        await task.value
        // Only this ask's own record: a Clear and a new ask may have replaced it meanwhile.
        if furtherWork[item.id] == task { furtherWork[item.id] = nil }
    }

    /// Every further ask on the wire let go of — the thread closed, or Esc. What they had not
    /// landed does not land, and each foot is put back where it was, to be asked again.
    @discardableResult
    func stopReadingFurther() -> Bool {
        guard !furtherWork.isEmpty else { return false }
        for task in furtherWork.values { task.cancel() }
        heldBack.formUnion(furtherWork.keys)
        furtherWork = [:]
        return true
    }

    /// `stopReadingFurther()` for one thread only — its pane closing, which must not stop the
    /// pane opened in its place.
    func stopReadingFurther(of id: String) {
        guard let task = furtherWork.removeValue(forKey: id) else { return }
        task.cancel()
        heldBack.insert(id)
    }

    private func readFurther(
        _ item: DummyItem, from edge: String, held: Note, was before: ShellThreadFurther<Absence>,
        in session: ShellSession
    ) async {
        let host = held.source.host
        let stamp = Source(host: host, kind: held.source.kind)
        do {
            let post = session.conversationPost(host: host, within: deadline).post
            let thread = try await post.conversation(id: edge, source: stamp)
            try Task.checkCancellation()
            if await Self.land(thread.descendants, host: host, in: session) {
                await session.reloadFromStore()
            }
            // Closed, or its server let go of, while this was on the wire: nothing to lay it under.
            guard case .loaded(let ancestors, let descendants, let rootID) = standings[item.id] else {
                return
            }
            let drawn = Set((ancestors + descendants).map(\.key)).union([held.key])
            let fresh = thread.descendants.filter { !drawn.contains($0.key) }
            let grown = descendants + fresh
            standings[item.id] = .loaded(ancestors: ancestors, descendants: grown, rootID: rootID)
            asked[item.id, default: []].insert(edge)
            furthers[item.id] = rootID.map {
                Self.settled(root: held, rootID: $0, descendants: grown, asked: asked[item.id] ?? [])
            } ?? .end
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            furthers[item.id] = .failed(.refused)
        } catch let error where Cancellation.happened(error) {
            if standings[item.id] != nil { furthers[item.id] = before }
        } catch {
            furthers[item.id] = .failed(Self.absence(for: error))
        }
    }

    /// Posts read in a thread, into the store **held aside** and saved, and those already held
    /// refreshed on the way past. Whether a held row changed, so a caller adopts only then.
    private static func land(_ notes: [Note], host: String, in session: ShellSession) async -> Bool {
        guard !notes.isEmpty else { return false }
        await session.store.hold(notes, ifSourceHere: host)
        let changed = await session.store.refresh(notes, ifSourceHere: host)
        await session.persist?()
        return changed
    }

    /// The next post to ask for its own thread, or nothing where no drawn post has more to give.
    ///
    /// **Every drawn answer is weighed**, not only the chain above the last one: a server cuts a
    /// thread by depth as well as by count, so a post in the middle can be missing its answers as
    /// surely as the last. Of those that say they have more answers than are drawn under them and
    /// have not been asked, the deepest is the one — the furthest place the source stopped — and
    /// the later of two as deep. Never the post itself: its thread is the first answer, and asking
    /// it again would hand back the same cut.
    static func edge(below rootID: String, in descendants: [Note], asked: Set<String>) -> String? {
        let answers = answerCounts(descendants)
        var depths: [String: Int] = [rootID: 0]
        var best: (id: String, depth: Int)?
        for note in descendants {
            guard let id = note.statusID, id != rootID else { continue }
            let depth = (note.reply?.inReplyToId.flatMap { depths[$0] } ?? 0) + 1
            depths[id] = depth
            guard !asked.contains(id), (note.counts.replies ?? 0) > (answers[id] ?? 0) else { continue }
            if depth >= (best?.depth ?? 0) { best = (id, depth) }
        }
        return best?.id
    }

    /// Where a thread stands once nothing is on the wire: more to ask, the end, or cut.
    ///
    /// **Cut rather than the end wherever a post drawn — the opened one included — counts more
    /// answers than are drawn under it** and there is no one left to ask. Mastodon hands back
    /// only so many of a post's direct answers and gives no way to page past them; the post's own
    /// count is what shows that happened, and saying "the end" over it is the false end.
    static func settled(
        root: Note, rootID: String, descendants: [Note], asked: Set<String>
    ) -> ShellThreadFurther<Absence> {
        if edge(below: rootID, in: descendants, asked: asked) != nil { return .more }
        let answers = answerCounts(descendants)
        let claims = [(rootID, root.counts.replies)]
            + descendants.compactMap { note in note.statusID.map { ($0, note.counts.replies) } }
        let short = claims.contains { id, claimed in (claimed ?? 0) > (answers[id] ?? 0) }
        return short ? .cut : .end
    }

    /// How many drawn answers each post has directly under it.
    private static func answerCounts(_ descendants: [Note]) -> [String: Int] {
        var answers: [String: Int] = [:]
        for note in descendants {
            if let parent = note.reply?.inReplyToId { answers[parent, default: 0] += 1 }
        }
        return answers
    }

    /// The thread around `root` as this device holds it — what an earlier read landed (#177) —
    /// or nothing where it holds nobody else in it.
    ///
    /// Built from the answers' own parents, since the store keeps no order of the source's: what
    /// it answers up to the start, and what answered it walked depth first, the older answer
    /// first under each post. Each post once, so a loop in a stranger's parents ends.
    static func kept(around root: Note, among held: [Note]) -> (ancestors: [Note], descendants: [Note])? {
        guard let rootID = root.statusID else { return nil }
        let byID = Dictionary(
            held.compactMap { note in note.statusID.map { ($0, note) } },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = [rootID]
        var ancestors: [Note] = []
        var up = root.reply?.inReplyToId
        while let id = up, seen.insert(id).inserted, let parent = byID[id] {
            ancestors.insert(parent, at: 0)
            up = parent.reply?.inReplyToId
        }
        var answers: [String: [Note]] = [:]
        for note in held where note.statusID != nil {
            if let parent = note.reply?.inReplyToId { answers[parent, default: []].append(note) }
        }
        var descendants: [Note] = []
        var stack = Self.oldestFirst(answers[rootID] ?? []).reversed().map { $0 }
        while let next = stack.popLast() {
            guard let id = next.statusID, seen.insert(id).inserted else { continue }
            descendants.append(next)
            stack += Self.oldestFirst(answers[id] ?? []).reversed()
        }
        return ancestors.isEmpty && descendants.isEmpty ? nil : (ancestors, descendants)
    }

    private static func oldestFirst(_ notes: [Note]) -> [Note] {
        notes.sorted { ($0.postedAt, $0.statusID ?? "") < ($1.postedAt, $1.statusID ?? "") }
    }

    /// Every failure a thread read can end in, as one of three sentences.
    ///
    /// **A status the server chose is a refusal and everything else is the dark.** A 403 on the
    /// lookup is a token that may not search, a 401 is a token the server has stopped honouring,
    /// a 404 is a post that is no longer there to have a thread — all three are the server
    /// answering, and none of them is helped by pressing again. A transport error, a timeout, or
    /// a status the server did not choose, is the one kind worth a second press.
    private static func absence(for error: any Error) -> Absence {
        if case .http(let status)? = error as? MastodonAuthError { return chosen(status) }
        if case .http(let status)? = error as? MastodonRequestError { return chosen(status) }
        return .unreachable
    }

    private static func chosen(_ status: Int) -> Absence {
        (400..<500).contains(status) ? .refused : .unreachable
    }
}

extension ShellSession {
    /// One microblog post and the conversation around it, read as the reader where this device
    /// is signed in to the host and unsigned otherwise — **the one rule** a thread read and a
    /// reload's read of a single post both go by, so neither can ask through a door the reader
    /// has closed. Each request ends within `limit`, and `signedIn` says which door it was.
    func conversationPost(host: String, within limit: Duration) -> (post: MastodonPost, signedIn: Bool) {
        if let door = mastodon.authorized(host: host, within: limit, for: .conversation) {
            return (MastodonPost(door: door), true)
        }
        let watched = WatchedHTTP(http, for: .conversation, in: work)
        return (MastodonPost(http: Deadline(watched as any HTTPClient, within: limit), host: host), false)
    }
}
