import FediqoCore
import Foundation
import Observation

// The conversation around one microblog post, fetched when the post is opened — #90.
//
// A forum thread's answers are `ForumPosts`': they come off the page the opening post came off,
// and the reader asks for them with a press because that page is expensive and they may not want
// it. A microblog thread is one request to one endpoint about one post the reader has just
// pressed Return on, so it is asked for the moment the pane opens and nothing is asked of the
// reader twice.
//
// **Nothing here reaches the store's list of rows.** What comes back is drawn, and what comes
// back for a row this device already holds is handed to `ItemStore.refresh`, which replaces held
// rows and admits none — so an answer this device never held is read in the thread and does not
// turn up in All afterwards. That property is `ShellReload`'s and is stated in its doc; this unit
// took over the request and keeps it.

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
    enum Absence: Equatable, Sendable {
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

    func standing(of id: String) -> ShellConversationStanding {
        standings[id] ?? .unasked
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

    /// The note behind a row drawn in a conversation, where one of the loaded halves holds it.
    ///
    /// **An answer read in a thread is not a store row** — see this file's header — so an act
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
        }
    }

    func clear() {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        standings = [:]
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
        guard let held = session.notes.first(where: { $0.key.rowID == item.id }),
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
        standings[item.id] = .coming
        let stamp = Source(host: host, kind: held.source.kind)
        do {
            let post = door(host: host, in: session)
            guard let id = try await post.id(of: held) else {
                standings[item.id] = .absent(.unfindable)
                return
            }
            try Task.checkCancellation()
            let thread = try await post.conversation(id: id, source: stamp)
            try Task.checkCancellation()
            // Held rows that appear in the thread are refreshed on the way past — an answer this
            // device already has shows its new words in the timeline too. Nothing is admitted.
            //
            // **And the session is told**, here rather than at the caller. This read happens
            // from two places — the pane opening and `r` — and only one of them used to adopt
            // the store afterwards, so an edit that landed on the way past a thread showed in
            // the thread and not in the stream under it until something else asked.
            await session.store.refresh(thread.ancestors + thread.descendants, ifSourceHere: host)
            await session.reloadFromStore()
            standings[item.id] = thread.isAlone
                ? ShellConversationStanding.none
                : .loaded(ancestors: thread.ancestors, descendants: thread.descendants, rootID: id)
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            standings[item.id] = .absent(.refused)
        } catch let error where Cancellation.happened(error) {
            standings[item.id] = before
        } catch {
            standings[item.id] = .absent(Self.absence(for: error))
        }
    }

    /// As the reader where this device is signed in to the host, unsigned otherwise — the one
    /// rule `ShellReload` reads a single post by, spelled once more here because this unit asks
    /// its own question and must not ask it through a door the reader has closed.
    private func door(host: String, in session: ShellSession) -> MastodonPost {
        if let door = session.mastodon.authorized(host: host, within: deadline) {
            return MastodonPost(door: door)
        }
        return MastodonPost(http: Deadline(session.http, within: deadline), host: host)
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
