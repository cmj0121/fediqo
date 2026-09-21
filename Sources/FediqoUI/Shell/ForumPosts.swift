import FediqoCore
import Foundation
import Observation
import SwiftUI

/// A thread this device can go and read, as a row knows it.
///
/// **`noteID` is the carrier, and this is the one place it is read back.** A Discuz! thread
/// becomes a `Note` with `id = "discuz:<host>:<tid>"` — host-qualified and prefixed because a
/// forum's thread numbers, another forum's thread numbers and a microblog's status ids all share
/// one store. The row's own `id` also names the source (#10); the spelling lives on `noteID`.
///
/// Reading it back here rather than at each call site is this branch's second convention: a rule
/// enforced at each consumer is a rule consumer N+1 misses. There is exactly one reader of that
/// spelling in this module, and `theIdSpellingStillAgrees` pins it against a `Note` built by
/// `DiscuzClient` itself, so the two halves cannot drift apart in silence.
///
/// **A Discourse thread is deliberately not one of these.** Both forums draw as `.forum` and the
/// shape is where the protocol stops mattering — but a `tid` is Discuz!'s number and
/// `DiscuzClient` is what answers for it, so the prefix is checked rather than the shape.
struct ForumThreadRef: Hashable, Sendable {
    /// Folded once, here, where it enters this module's caches — decision 21.
    let host: String
    let tid: Int

    /// The thread a row is standing on, or nothing where this row is not a Discuz! thread at all.
    ///
    /// **`tid > 0`**, for the reason `DiscuzClient.posts(tid:)` requires it one layer down: a
    /// thread number is a positive integer and everything else is somebody's markup or somebody's
    /// fixture, neither of which there is a page to fetch for.
    init?(_ item: DummyItem) {
        let parts = item.noteID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "discuz" else { return nil }
        guard let tid = Int(parts[2]), tid > 0, !parts[1].isEmpty else { return nil }
        self.host = String(parts[1]).lowercased()
        self.tid = tid
    }

    init(host: String, tid: Int) {
        self.host = host.lowercased()
        self.tid = tid
    }
}

/// What a row knows about its opening post right now — D30, as a value a band can be drawn from.
///
/// **Five states and no sixth, enumerated rather than folded into an optional.** The whole point
/// of the unit is that "not here yet", "the author wrote nothing", "the forum would not let you
/// read it" and "we could not fetch it" are four different sentences, and a `String?` says one
/// thing for all four. `DiscuzPost.isWithheld` exists in Core for exactly this reason and it
/// would be thrown away here by any shape that could not carry it.
enum ForumReading: Equatable, Sendable {
    /// Asked for, or about to be. The band is held open and nothing is claimed.
    case coming
    /// The author's words, as the forum served them.
    case words(String)
    /// `游客请登录后查看回复内容` — the forum answered with its own notice where the words go.
    /// Measured on `install-a.example`, 19 replies of 20 to a signed-out reader.
    case withheld
    /// It arrived, it was not withheld, and there were no words in it: an opening post that is a
    /// picture, or an attachment, or a poll. **Not the same as `withheld` and not the same as
    /// `coming`** — the author really did write nothing this device can draw.
    case silent
    /// It cannot be had. Which kind, because the row says different things about them.
    case absent(ForumPosts.Absence)

    /// What one fetched post is worth to a row: the words, or the reason there are none.
    ///
    /// The order is the whole of it and it is not arbitrary. **Withheld is asked before empty**,
    /// because a withheld post has an empty `body` by construction — Core takes the forum's
    /// notice out rather than attributing it to the author — so asking `body.isEmpty` first would
    /// file every withheld post under "they wrote nothing", which is precisely the confusion
    /// `isWithheld` was added to end.
    static func of(_ post: DiscuzPost) -> ForumReading {
        if post.isWithheld { return .withheld }
        return post.body.isEmpty ? .silent : .words(post.body)
    }
}

/// One thread's opening post, fetched when its row is scrolled to, and cached — **D30** — and
/// the rest of the same topic on request — **D31**.
///
/// ## Why this is a cache and not a fetch
///
/// A Discuz! thread table carries no part of the opening post: `DiscuzThread.asNote` writes
/// `body: ""` and says why. So the reader gets a list of titles, which is what they wrote in to
/// complain about. Filling them in means one request per thread, and a board listing is about
/// forty threads — 3.7MB on the mobile template, 9.7MB on the desktop one, into a stranger's
/// forum, for one press. This package refuses that traffic everywhere else it comes up, so the
/// post is fetched for the rows the reader actually stopped on and kept for as long as it is
/// affordable to keep it.
///
/// **`ShellPictures` is the model and the resemblance is deliberate**, down to the names. It is
/// the same problem with a different payload: work commissioned from a view body, deduplicated,
/// bounded in bytes and in count, evicted least-wanted-first, declined rather than admitted when
/// admitting would drop something on screen, and negative answers remembered so a row that
/// cannot be read is not re-asked on every rebuild. Where this file differs from that one it
/// says so at the line; a reader who finds two of this project's caches shaped differently should
/// be able to find out why without guessing.
///
/// ## The three differences from `ShellPictures`, stated
///
/// 1. **A post belongs to exactly one forum, so there is no set of sources per entry.** A picture
///    address points at a CDN two servers can both hand out, which is why `ShellPictures` carries
///    a `Set<String>` per entry and strikes hosts off one at a time. A `tid` is issued by one
///    forum and means nothing on another — it is *in the key* — so `forget(host:)` here is a
///    single sweep with no reference counting, and `holding(host:)` is a filter on the key.
/// 2. **A row waits before it asks.** `ShellPictures` commissions on the first pass because a
///    picture is small and the slot is already reserved. A thread page is 8KB to 240KB measured,
///    and a fast scroll past forty rows would put forty of them on the wire for rows the reader
///    never read. `settle` is the pause that makes "scrolled to" mean scrolled to and not
///    scrolled past — see `ForumPostBand.settle`, which is where the waiting happens, because
///    only a view's own `.task` can be cancelled by the row going away.
/// 3. **The gate is two and not four.** The same reasoning: these are pages, not thumbnails, and
///    this gate adds to the picture cache's and the emoji cache's against the same host — the
///    "one per-host gate across both caches" the plan already records as owed.
///
/// ## What is kept, and what it costs
///
/// `Part` splits the two reads because they are two requests and two answers with two lifetimes:
/// a row's opening post is wanted by every row the reader scrolls past, and a topic's replies are
/// wanted by the one thread they opened. One map and one budget for both, so there is one LRU and
/// one number to reason about — and because nothing re-stamps interest on replies for a thread
/// that is closed, they age out ahead of the opening posts by themselves rather than by a rule.
///
/// Cost is counted in UTF-8 bytes of the text actually held, which is what the strings weigh. It
/// is not the page: the page is thrown away the moment Core has read it, and what survives here
/// is a post's words with the forum's furniture already taken out.
@MainActor
@Observable
final class ForumPosts {
    /// Which read an entry is the answer to.
    ///
    /// **Two cases, enumerated, no `default:` anywhere that switches on it.** They are two
    /// requests on purpose: `DiscuzClient.post(tid:)` and `.replies(tid:)` each fetch the thread
    /// page for themselves, so a reader who opens a thread pays for that page twice. That is
    /// Core's shape and not this file's to change — it is recorded for the plan rather than
    /// worked around here, because working around it would mean a second parser in the UI.
    enum Part: Hashable, Sendable, CaseIterable {
        /// The first post of the topic — D30, fetched when the row is scrolled to.
        case opening
        /// Everything else the first page of the topic carried — D31, fetched on request.
        case replies
    }

    struct Key: Hashable, Sendable {
        let host: String
        let tid: Int
        let part: Part

        init(_ ref: ForumThreadRef, _ part: Part) {
            self.host = ref.host
            self.tid = ref.tid
            self.part = part
        }
    }

    /// Why there is nothing, and — the part that matters — whether asking again could help.
    ///
    /// Narrower than `DiscuzRequestError`, deliberately. Core distinguishes eight failures
    /// because eight of them are different facts about a forum; a row has three things to say and
    /// a fourth that is about this device rather than about the forum. Every Core case is mapped
    /// in `absence(for:)` **over a `switch` with no `default:`**, so a ninth breaks the build
    /// there rather than arriving on screen as the wrong sentence.
    enum Absence: Error, Equatable, Sendable {
        /// The forum answered and said no: a filter, a notice page, a challenge, a status that
        /// means refused. Signing in is what would change this answer, not waiting.
        case refused
        /// It answered, it decoded, and there was no post in it this device could read. A
        /// members-only board served as a login page at status 200 lands here — see
        /// `DiscuzClient.posts(tid:)`.
        case unreadable
        /// Nothing answered. The address may be perfectly good and the network simply dark, so
        /// this is the one kind of nothing that is forgotten the moment anything gets through.
        case unreachable
        /// More post than this cache may hold without dropping one a row is drawing right now.
        ///
        /// A floor, not a mechanism, and the reasoning is `ShellPictures.Absence.crowded`'s
        /// entire: admitting it starts a refetch that never ends, because what is dropped is
        /// re-asked for and re-asking drops another. Permanent for the life of the process except
        /// for the one relief that sits outside the loop — the reader's Clear button, which a
        /// crowded cohort cannot reach and therefore cannot cause.
        ///
        /// It is further out of reach here than it is there. The budget holds several thousand
        /// posts and a screen wants at most a dozen, so if a reader ever sees it, something has
        /// asked for far more at once than a screen can show.
        case crowded

        /// Whether asking again could ever change the answer by itself.
        var asksAgain: Bool { self == .unreachable }
    }

    /// How much post text is held, in bytes.
    ///
    /// **At least twice `maxBytes`**, which is the invariant that makes admission terminate: the
    /// largest single entry that can ever arrive has to fit beside another one, or a full cache
    /// declines a legal newcomer forever. Above that it is slack, and the slack is what makes
    /// `.crowded` unreachable in practice — 8MB is several thousand posts where a screen wants a
    /// dozen.
    nonisolated static let budget = 8 * 1024 * 1024

    /// How many entries are kept, however short they are.
    ///
    /// The byte budget is the memory bound and it is the important one, but it is not a bound on
    /// *count*, and these are walked on the main actor. A reader with eight boards subscribed is
    /// 320 rows; this is that with room, and the same number `ShellPictures` uses for the same
    /// reason.
    nonisolated static let held = 512

    /// How many records of nothing are worth keeping. Bounded because a collection that only
    /// grows is the leak this class exists in order not to have.
    nonisolated static let refusals = 256

    /// How many keys' worth of interest is remembered.
    ///
    /// At least twice `held`, and the ratio is load-bearing for the reason it is in
    /// `ShellPictures`: `trimInterest` may never drop a key that has an entry, so it can only
    /// reach its low-water mark out of the keys that do not. With half the map guaranteed
    /// disposable, trimming always succeeds in one pass.
    nonisolated static let remembered = 2 * held

    /// How many thread pages may be on the wire at once. See the header — two, not four.
    nonisolated static let maxInFlight = 2

    /// The most of one thread page this device will take.
    ///
    /// **A working size, not a last line.** `URLSessionClient`'s 128 MiB default is the ceiling
    /// against a hostile instance; the plan records that no caller yet carries anything tighter,
    /// and this is a caller that can say exactly what it expects. Measured on the four installs:
    /// the largest thread page of any of them is `install-a.example` at 274,457 bytes full and
    /// 238,791 on its third-party mobile template. 2 MiB is seven times the worst measured page
    /// and a sixty-fourth of the default, so a forum that starts streaming is refused on its
    /// declared size rather than after it has been buffered.
    nonisolated static let maxBytes = 2 * 1024 * 1024

    private struct Held: Sendable {
        let posts: [DiscuzPost]
        let cost: Int
    }

    private var entries: [Key: Held] = [:]

    /// What came back with nothing, and why. Held so a thread that cannot be read is asked for
    /// once rather than on every rebuild of the row that shows it.
    private(set) var missing: [Key: Absence] = [:]

    /// Bumped only by a **cohort** changing its mind — the network coming back, or a reader
    /// clearing one forum. Ordinary eviction deliberately stays silent, for the reason
    /// `ShellPictures.generation` states: eviction is a fact about one key and the band that lost
    /// its post already sees it through `entries`, which is observed. Telling every other band as
    /// well is what turns one eviction into a storm.
    private(set) var generation = 0

    /// The work drawing each part while it is being fetched, so every view wanting the same
    /// thread waits on the same request and a view going away does not take that work with it.
    ///
    /// **Observed, where `ShellPictures.inFlight` is not**, and the difference is not an
    /// oversight. Nothing reads that one from a body: a picture on its way and a picture that was
    /// never asked for are drawn the same bare well, so there is nothing for a view to learn from
    /// the record. Here the thread pane *does* read it — `standing(of:)` — because the reader has
    /// pressed a button and is owed the difference between "on its way" and "press it again".
    /// Ignoring it would leave that press with no feedback at all until the replies landed.
    ///
    /// The audience is one pane at a time, so waking it costs nothing the row cache's silence was
    /// protecting.
    private(set) var inFlight: [Key: Task<Void, Never>] = [:]

    @ObservationIgnored private(set) var heldBytes = 0

    /// Counts every expression of interest, so "wanted since this fetch began" is answerable.
    @ObservationIgnored private(set) var clock = 0

    /// When each key was last asked about — **whether or not there was anything to give back.**
    /// Recording the misses is what makes admission work; see `ShellPictures.interest`.
    @ObservationIgnored private(set) var interest: [Key: Int] = [:]

    @ObservationIgnored private var active = 0
    @ObservationIgnored private var queued: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored private let http: any HTTPClient
    /// The forums this run has a browser for. A host the reader signed in to has to be read
    /// through the engine holding the cookies, or every post on it comes back withheld — see
    /// `ForumJoinTransport`, which is where the rule is stated and where a wall becomes a 403.
    ///
    /// Held strongly. There is no cycle to break — `ForumSessions` knows nothing about this class
    /// — and `weak` here would be a quiet foot-gun: a caller that built one inline would find its
    /// browsers gone by the first fetch, and every post would come back signed-out with nothing
    /// to say why.
    @ObservationIgnored private let forums: ForumSessions?

    init(http: any HTTPClient = ForumPosts.live, through forums: ForumSessions? = nil) {
        self.http = http
        self.forums = forums
    }

    /// Built with this caller's own ceiling rather than the transport's default. See `maxBytes`.
    nonisolated static let live: any HTTPClient = URLSessionClient(byteLimit: maxBytes)

    /// Held keys, least recently wanted first.
    ///
    /// Worked out when it is needed rather than maintained as it changes, and each clock looked
    /// up once and then sorted on — both for the reasons `ShellPictures.order` gives. The `?? 0`
    /// is a belt: `trimInterest` never drops a key that has an entry.
    var order: [Key] {
        entries.keys
            .map { ($0, interest[$0] ?? 0) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    // MARK: - What a row and a thread read

    /// What this row should draw for its opening post, **and a stamp saying it still wants one**.
    ///
    /// **Read from `body` and nowhere else.** This is I8: admission terminates because every band
    /// on screen re-stamps its interest between one arrival and the next, so a band that stops
    /// reading looks infinitely stale and becomes evictable however recently it was drawn. Moving
    /// this read into an `.onAppear`, or behind an `EquatableView`, restores an unbounded refetch
    /// chain against a stranger's forum — the same warning `RemoteImage` carries, for the same
    /// mechanism.
    func reading(_ ref: ForumThreadRef) -> ForumReading {
        let key = Key(ref, .opening)
        wanted(key)
        if let held = entries[key], let opening = held.posts.first {
            return ForumReading.of(opening)
        }
        if let absence = missing[key] { return .absent(absence) }
        return .coming
    }

    /// The author's picture, where the opening post brought one — **and a stamp, like `reading`**.
    ///
    /// **Free, and that is why it is here rather than in a fetch of its own.** A Discuz! thread
    /// table carries no avatar and the guess at `uc_server/avatar.php?uid=…` is wrong on any
    /// install that moved UCenter — `install-d.example` is that install, twice over. The thread *page*
    /// does carry it, and D30 already fetches that page when the row is scrolled to. So the
    /// picture arrives with the words, in the answer to a request the row was making anyway, and
    /// a forum row's avatar costs exactly nothing beyond what D30 already spends.
    ///
    /// **Which is also the whole argument for doing it this way rather than eagerly.** An avatar
    /// fetched per row on load is forty thread pages for one board listing — the traffic D30
    /// exists to refuse — and the reader would be paying it for a 36pt square rather than for the
    /// words. Lazily, a row the reader never reached never asks, and one they did read shows a
    /// face at the same moment it shows the post. The cost, stated: the plate is drawn for a beat
    /// first, exactly as the words band draws its plates, so the two arrive together and the row
    /// does not fill in twice.
    ///
    /// Separate from `reading` rather than folded into it, because they are facts about different
    /// things: a **withheld** post has no words and still has an author with a face, and a state
    /// that carried both would have to say so in every case. Stamps interest for the same reason
    /// `reading` does — this is read from a body. See I8.
    func avatar(of ref: ForumThreadRef) -> URL? {
        let key = Key(ref, .opening)
        wanted(key)
        return entries[key]?.posts.first?.avatarURL
    }

    /// The rest of the topic, and how it got there — D31.
    ///
    /// One reader rather than a `replies()` beside a `hasReplies`, so the pane cannot draw a
    /// button and a list that disagree. **Stamps interest for the same reason `reading` does**:
    /// this is read from a body, and a band that stops re-stamping looks infinitely stale to the
    /// eviction predicate. See I8.
    func standing(of ref: ForumThreadRef) -> ForumRepliesStanding {
        let key = Key(ref, .replies)
        wanted(key)
        if let posts = entries[key] { return posts.posts.isEmpty ? .none : .loaded(posts.posts) }
        if let absence = missing[key] { return .absent(absence) }
        if inFlight[key] != nil { return .coming }
        return .unasked
    }

    /// Fetches one thread's opening post, unless somebody already is, or already has, or already
    /// found out that asking again cannot help.
    func fetch(_ ref: ForumThreadRef) async {
        await fetch(ref, part: .opening)
    }

    /// Fetches the rest of the topic — the reader pressed for it.
    func fetchReplies(_ ref: ForumThreadRef) async {
        await fetch(ref, part: .replies)
    }

    /// `r` on an open thread (#29): its opening post asked again, and the rest of the topic too
    /// where the reader had asked for it. What is held stays drawn until the answer replaces it.
    ///
    /// Every page it asks for itself ends within `limit`. Cancelled — the reader stopped it — its
    /// own pages are cancelled and nothing they bring lands: what was held, and why a part was
    /// missing, stay as they were. A page some row was already fetching is waited on, not
    /// cancelled, for it was not the reload's to stop.
    ///
    /// Returns whether every part asked came back.
    func reload(_ ref: ForumThreadRef, within limit: Duration) async -> Bool {
        let keys = Part.allCases.map { Key(ref, $0) }.filter { key in
            key.part == .opening || entries[key] != nil || missing[key] != nil || inFlight[key] != nil
        }
        var waits: [Task<Void, Never>] = []
        var own: [Task<Void, Never>] = []
        for key in keys {
            if let running = inFlight[key] {
                waits.append(running)
            } else {
                let started = work(for: key, within: limit)
                waits.append(started)
                own.append(started)
            }
        }
        // A copy for the handler: Swift 6.0 will not let a cancellation handler, which runs
        // concurrently, read a `var` it captured.
        let owned = own
        let landedWhole = await withTaskCancellationHandler {
            for wait in waits { await wait.value }
            return keys.allSatisfy { missing[$0] == nil }
        } onCancel: {
            for task in owned { task.cancel() }
        }
        return landedWhole && !Task.isCancelled
    }

    private func fetch(_ ref: ForumThreadRef, part: Part) async {
        let key = Key(ref, part)
        guard entries[key] == nil, missing[key]?.asksAgain ?? true else { return }
        await work(for: key).value
    }

    // MARK: - The wire

    /// The fetch of one part, started unless one is running. `limit` bounds each request of it.
    private func work(for key: Key, within limit: Duration? = nil) -> Task<Void, Never> {
        if let running = inFlight[key] { return running }
        let client = self.client(for: key.host, within: limit)
        let tid = key.tid
        let part = key.part
        // Unstructured on purpose, and the reason is `ShellPictures.work`'s: the caller is a
        // view's `.task`, which is cancelled by any rebuild, and what that must cancel is this
        // view's waiting rather than the work itself. Two rows wanting one thread wait on one
        // request, and a row that scrolls away and back does not start a second.
        //
        // **What keeps that from costing forty pages on a fast scroll is not here.** It is the
        // pause in `ForumPostBand`, before this is ever reached: only a view's own task knows
        // that its row went away.
        let started = Task { @MainActor in
            await self.enter()
            let answer: Result<[DiscuzPost], Absence>
            do {
                // **No `default:`.** A part falling through would fetch the wrong half of a
                // thread and draw it in the right place, which is a wrong answer the compiler
                // would not mention.
                switch part {
                case .opening: answer = .success([try await client.post(tid: tid)])
                case .replies: answer = .success(try await client.replies(tid: tid))
                }
            } catch {
                answer = .failure(Self.absence(for: error))
            }
            self.leave()
            defer {
                self.inFlight[key] = nil
                self.cleared.remove(key)
            }
            // Stopped: neither the page nor a mark for it lands. Only a reload's own fetch is
            // ever cancelled.
            guard !Task.isCancelled else { return }

            // **The guard that stops a `forget` being undone by work already running.** This
            // exact bug has been through this project twice already — `EmojiCatalogueStore` had
            // it and `ShellPictures` had it — and the mechanism is the same both times: clearing
            // the stored state alone leaves a fetch in the air which lands a moment later and
            // files the entry back under the host the reader just cleared. The record is re-read
            // **after** the suspension rather than trusted from before it.
            //
            // Above the switch, so it covers the failure too: a mark noted here would be filed
            // under the forum the reader has just emptied, and they would have to press Clear a
            // second time to undo the first one's own wake.
            guard !self.cleared.contains(key) else { return }

            switch answer {
            case .success(let posts):
                self.keep(
                    posts,
                    for: key,
                    // Sampled on arrival rather than at creation, for the reason
                    // `ShellPictures.work` gives: the question is "how badly is this newcomer
                    // wanted *now*", and a band still on screen has re-stamped every pass since
                    // the fetch was commissioned. Zero is a fetch no band has asked about, which
                    // can displace nothing.
                    startedAt: self.interest[key] ?? 0
                )
            case .failure(let absence):
                self.note(absence, for: key)
            }
        }
        inFlight[key] = started
        return started
    }

    /// The reader through which one forum is read.
    ///
    /// **Through the sign-in engine where there is one, or where the reader is signed in**, and
    /// this is not an optimisation: a cookie jar is not something a `URLSession` may borrow, so a
    /// thread on a forum the reader signed in to comes back withheld — or as a login page, or a
    /// challenge's 403 — if it is fetched any other way, a relaunch included.
    /// `readsThroughEngine` rather than `transport`, because `transport(host:)` would *build* one
    /// for every host and this app does not start a web process for a host that never needed it.
    private func client(for host: String, within limit: Duration?) -> DiscuzClient {
        var transport = http
        if let forums, forums.readsThroughEngine(host: host) {
            transport = ForumJoinTransport(forums.transport(host: host))
        }
        if let limit { transport = Deadline(transport, within: limit) }
        return DiscuzClient(http: transport, host: host)
    }

    /// Core's eight answers, folded to the four a reader is told apart.
    ///
    /// **No `default:` over `DiscuzRequestError`.** A ninth case added in Core has to be given a
    /// sentence here, and the build is where that should be noticed — the plan records a
    /// `default:` over a protocol kind shipping a silent wrong answer once already, and F5 records
    /// a new error case correctly breaking the build at exactly this kind of line.
    ///
    /// `invalidURL` is folded to `refused` rather than given a fifth sentence: it is this
    /// device's own failure to build an address, the reader can do nothing about it, and a
    /// sentence explaining URL construction to somebody reading a forum is noise. It cannot in
    /// fact arise — the address is built from a parsed host and a positive integer — and folding
    /// it is what keeps that from needing a screen.
    static func absence(for error: any Error) -> Absence {
        if error is CancellationError { return .unreachable }
        guard let discuz = error as? DiscuzRequestError else { return .unreachable }
        switch discuz {
        case .challenged, .restricted, .refused, .http, .invalidURL:
            return .refused
        case .undecodable, .noThreads, .noBoards, .noPosts:
            return .unreadable
        }
    }

    private func enter() async {
        if active < Self.maxInFlight {
            active += 1
            return
        }
        // Resumed holding the slot the leaver handed over, so `active` does not move.
        await withCheckedContinuation { queued.append($0) }
    }

    private func leave() {
        if queued.isEmpty {
            active -= 1
        } else {
            queued.removeFirst().resume()
        }
    }

    // MARK: - Admission and eviction

    /// Admits what came back, or declines it.
    ///
    /// Room is made oldest-first and never past something a band has wanted since this fetch
    /// began; where room cannot be made without dropping a post that is on screen right now, the
    /// newcomer is declined instead. That branch is the only thing that ends the loop where what
    /// is dropped is re-asked for and re-asking drops another — `ShellPictures.keep`, with the
    /// reference counting taken out because a thread belongs to one forum.
    func keep(_ posts: [DiscuzPost], for key: Key, startedAt: Int) {
        let cost = Self.cost(of: posts)
        let already = entries[key]?.cost ?? 0
        var bytes = heldBytes - already + cost
        var count = entries.count + (already > 0 ? 0 : 1)
        var evictable: [Key] = []

        // A `startedAt` of zero can outrank nothing, so there is no order worth working out.
        if bytes > Self.budget || count > Self.held, startedAt > 0 {
            for old in order {
                guard bytes > Self.budget || count > Self.held else { break }
                guard old != key, let held = entries[old],
                      interest[old] ?? 0 < startedAt else { break }
                evictable.append(old)
                bytes -= held.cost
                count -= 1
            }
        }

        guard (bytes <= Self.budget && count <= Self.held) || entries.isEmpty else {
            note(.crowded, for: key)
            return
        }
        for old in evictable {
            if let gone = entries.removeValue(forKey: old) { heldBytes -= gone.cost }
        }

        heldBytes -= already
        entries[key] = Held(posts: posts, cost: cost)
        heldBytes += cost
        missing.removeValue(forKey: key)
        wanted(key)

        // Something got through, so the network is back, so everything written off while it was
        // down deserves another go. Nothing similar happens for `.crowded` — see `Absence`.
        forgetUnreachable()
    }

    /// What a held answer weighs: the text of it, in the bytes the strings are stored as.
    ///
    /// The author's words, what they quoted, and their name — the three strings that came off a
    /// page and are therefore the three whose length a stranger chooses. Everything else in a
    /// `DiscuzPost` is a number or a date.
    static func cost(of posts: [DiscuzPost]) -> Int {
        posts.reduce(0) { running, post in
            running
                + post.body.utf8.count
                // Every level of it: `DiscuzQuotation.byteCount` walks its own tree, so this
                // stays the one sum it was before a quotation had levels.
                + post.quoted.reduce(0) { $0 + $1.byteCount }
                + post.author.utf8.count
                + post.handle.utf8.count
        }
    }

    /// Writes down why there is nothing, bounded.
    ///
    /// The entry dropped to stay under the bound is an arbitrary one rather than the oldest, for
    /// the reason `ShellPictures.note` gives: giving a negative cache its own ordering is a
    /// second LRU for a map nobody can see, losing the wrong one costs one extra request, and it
    /// cannot loop because the entry just written is never the one removed.
    func note(_ absence: Absence, for key: Key) {
        missing[key] = absence
        while missing.count > Self.refusals,
              let spare = missing.keys.first(where: { $0 != key }) {
            missing.removeValue(forKey: spare)
        }
    }

    private func forgetUnreachable() {
        guard missing.contains(where: { $0.value == .unreachable }) else { return }
        // Over a copy, because the body writes back into the map it is walking — the same shape
        // as the sweeps in `forget(host:)`, written the same way on purpose: three loops that do
        // the same thing should not be written three ways, or a reader who finds one of them
        // different will assume the difference is meant.
        let noted = missing
        for (key, absence) in noted where absence == .unreachable {
            missing.removeValue(forKey: key)
        }
        generation += 1
    }

    /// Records that somebody asked about this key. Runs inside a view body, so it does no work
    /// that grows with what the cache is holding.
    private func wanted(_ key: Key) {
        clock += 1
        interest[key] = clock
        trimInterest()
    }

    /// Keeps `interest` bounded, oldest first, and **never drops a key there is an entry for** —
    /// the eviction predicate reads `interest`, so a held key missing from it would look
    /// infinitely stale and be evictable however recently it was drawn. Trims to three quarters
    /// so the sort happens once every few hundred reads rather than on every read once full.
    private func trimInterest() {
        guard interest.count > Self.remembered else { return }
        let target = Self.remembered * 3 / 4
        let spare = interest
            .filter { entries[$0.key] == nil }
            .sorted { $0.value < $1.value }
            .map(\.key)
        for key in spare {
            interest.removeValue(forKey: key)
            if interest.count <= target { return }
        }
    }

    // MARK: - What a reader clears

    /// Drops every post this device holds from one forum — decision 14, this cache's share.
    ///
    /// **One sweep and no reference counting**, which is where this parts company with
    /// `ShellPictures.forget(host:)`. A picture address can be handed out by two servers, so
    /// there an entry survives until the last source that was reading it is cleared. A `tid` is
    /// issued by one forum and is in the key, so an entry here has exactly one owner and goes.
    ///
    /// **Bumps the generation**, unlike ordinary eviction, and bumps it whether or not anything
    /// was held: a reader who presses Clear has made a decision, not asked a question. What a
    /// band still on screen is owed afterwards is a fresh ask.
    ///
    /// Work already in flight is **not** cancelled and its answer is dropped instead, which is
    /// the guard this project has now had to write three times — `EmojiCatalogueStore` and
    /// `ShellPictures` both shipped without it. A fetch that lands a moment after a Clear would
    /// otherwise file the reader's cleared forum straight back into the map they just emptied.
    func forget(host raw: String) {
        let host = raw.lowercased()
        for key in Array(inFlight.keys) where key.host == host {
            // The task still has to tidy its own record away, so the record stays and the
            // *answer* is what is refused: `cleared` is re-read after the suspension rather than
            // captured before it.
            cleared.insert(key)
        }
        for key in Array(entries.keys) where key.host == host {
            if let gone = entries.removeValue(forKey: key) { heldBytes -= gone.cost }
        }
        for key in Array(missing.keys) where key.host == host {
            missing.removeValue(forKey: key)
        }
        generation += 1
    }

    /// Keys whose fetch was in the air when the reader cleared their forum. Read after the
    /// suspension in `work`, never before it.
    @ObservationIgnored private var cleared: Set<Key> = []

    /// What this device is holding from one forum: how many posts, and what they cost. The
    /// reading beside the reader's Clear button.
    ///
    /// Reads `entries` directly, so a body calling this observes it even when nothing is held —
    /// a count that stops updating once it reaches zero is a readout that lies the moment
    /// anything arrives.
    func holding(host raw: String) -> (count: Int, bytes: Int) {
        let host = raw.lowercased()
        var count = 0
        var bytes = 0
        for (key, held) in entries where key.host == host {
            count += held.posts.count
            bytes += held.cost
        }
        return (count, bytes)
    }
}

/// Where the replies of one topic have got to — D31, as a value the thread pane draws from.
///
/// **`unasked` and `none` are separate cases and that is the point.** "Nobody has pressed for
/// them" and "the forum answered and this topic has no replies" look the same in any shape that
/// folds them — an empty array, a `nil` — and they are opposite facts about the thread. A pane
/// that drew a button for the second would invite the reader to press for something that is not
/// there, every time, forever.
enum ForumRepliesStanding: Equatable, Sendable {
    /// Nothing has asked yet. The way in is drawn.
    case unasked
    /// On the wire.
    case coming
    /// The forum answered and the topic has nobody else in it.
    case none
    /// The rest of the topic, in the order the page wrote it.
    case loaded([DiscuzPost])
    /// It could not be had, and why.
    case absent(ForumPosts.Absence)

    /// Whether pressing for the replies could do anything from here — **the one answer the
    /// button and the key both read**.
    ///
    /// This branch's own rule, stated in `FediqoRootView.playRow`: "the rule lives here and not
    /// in the pane, so that a mark and the key cannot come to mean two different things." The
    /// pane draws its way in exactly where this is true and `l` acts exactly where this is true,
    /// so a reader cannot find a button that the key will not press or press a key on a state the
    /// button does not offer. `DummyThreadPaneTests` pins the two against this one function.
    ///
    /// **`absent` is included only where asking again could help.** `unreachable` is the network
    /// having been dark, and `ForumPosts.Absence.asksAgain` is where that judgement already
    /// lives; the other three are settled facts about the forum, and offering to retry them would
    /// be a control that is guaranteed to change nothing.
    ///
    /// **No `default:`.** A sixth standing has to say whether it can be pressed.
    var wantsPressing: Bool {
        switch self {
        case .unasked: true
        case .absent(let absence): absence.asksAgain
        case .coming, .none, .loaded: false
        }
    }
}

/// The words band of a forum row, filled when the row is scrolled to — **D30, on screen**.
///
/// ## What a row shows before its post arrives, and why
///
/// **Two quiet plates, the shape this shell already uses for "asked for, not here yet".** The
/// three candidates were a blank band, the title alone, and a placeholder, and the first two are
/// both wrong for the same reason: they are indistinguishable from an answer. A blank band is
/// exactly what a post the author wrote no words in looks like, and exactly what a **withheld**
/// post would look like if this unit had not been careful — so a blank band before the fetch
/// means the row tells a lie for as long as the fetch takes and then tells the truth, with
/// nothing to mark the difference. The title alone is the screen the reader wrote in to complain
/// about; keeping it as the waiting state means the complaint is still on screen every time.
///
/// A plate is the right third answer because it is **not a sentence**. `RemoteImage` draws
/// `ShellWaiting` while a picture is on its way and this is the same vocabulary one band
/// over, so a reader who has learned what a waiting slot looks like already knows what this is.
/// And nothing is attributed to anybody: `DiscuzPost`'s own doc refuses to put the forum's notice
/// in `body` because a row drawing it would attribute the forum's sentence to the author, and a
/// row drawing *our* "Loading…" in the words band would do the same thing with our sentence.
///
/// ## The row's one height, which is what all of this is really about
///
/// A fetched post fills a band that is already there and already line-limited, and the row must
/// be exactly as tall with it as without — or the timeline reflows under the reader's thumb on
/// the one gesture that makes the fetch happen. On the wide layout that is already true and is
/// not this view's doing: `DummyItemRow.mainBox` holds the band at `Box.thumb` and clips it, so
/// nothing drawn here can move the row. On a phone in portrait the words band is sized by its
/// words — deliberately, and since before any of this — so `mainBox` pins **this** kind of row
/// there too. The rule that separates the two is written down in `mainBox`: a post that arrives
/// with the list may size its row, and a post that arrives after the row is on screen may not.
struct ForumPostBand: View {
    let thread: ForumThreadRef
    let posts: ForumPosts
    /// How many lines the words may have — the row's own `bodyLines`, so the two cannot drift.
    ///
    /// **`nil` means all of them**, which is the thread pane and nowhere else. A timeline row is
    /// one of forty in a list somebody is scrolling and its one height is a defence; the pane is
    /// the one post the reader opened *in order to read*, and truncating it there was the
    /// complaint this unit exists to answer. See `DummyItemRow.inFull`.
    let lines: Int?

    /// Whether an address in these words is drawn as a link. **False means a cover is in front of
    /// them**, and a cover must never draw a control — `EmojiText.words` states the whole of that
    /// argument. Only a microblog post carries a warning today, so a covered band is a shape the
    /// wire does not make; the row decides it all the same, because the row is where the cover is
    /// and a rule kept only where it currently cannot be broken is not a rule.
    let linked: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellPlaceIsActive) private var placeIsActive

    /// How long a row must stay before it costs somebody a request.
    ///
    /// **This is what makes "scrolled to" mean scrolled *to* and not scrolled *past*.** The work
    /// itself is unstructured, for the reason `ShellPictures` states — a `.task` is cancelled by
    /// any rebuild and what that must cancel is this view's waiting, not a fetch two other rows
    /// are also waiting on. The consequence is that once a fetch starts it runs to completion, so
    /// a fast scroll past forty rows would commission forty thread pages, each of them up to
    /// 240KB, for rows nobody read. The pause is before the commissioning, in the one place that
    /// *can* be cancelled by the row going away: this view's own task.
    ///
    /// A quarter of a second, against about a tenth of a second per row at a brisk scroll. The
    /// plan already accepts the cost in words — "text arrives a beat late on a fast scroll, and
    /// that is the right thing to spend" — and this is that beat, named.
    static let settle: Duration = .milliseconds(250)

    /// What this band is waiting on.
    ///
    /// `settled` rather than the reading itself: what re-fires the task is the difference between
    /// "there is nothing yet" and "there is an answer", and re-keying on the words would restart
    /// a task every time a post's text changed for any reason. The generation is for what no
    /// single band can see for itself — a cohort worth trying again because the network came back
    /// or the reader cleared this forum. `active` is decision 20's gate, **in the identity and
    /// not only in the guard**: a tab that was inactive when the task last ran would otherwise
    /// never re-run it, and the reader would come back to a page of plates that never fill.
    struct Wanting: Equatable {
        let thread: ForumThreadRef
        let settled: Bool
        let generation: Int
        let active: Bool
    }

    var body: some View {
        // Read here, in `body`, and not in the task — I8. Admission terminates because every
        // band on screen re-stamps its interest between one arrival and the next; a band that
        // stops reading looks infinitely stale to the eviction predicate however recently it was
        // drawn. Do not move this, and do not wrap this view in an `EquatableView`.
        let reading = posts.reading(thread)
        return Group {
            // **No `default:`.** A sixth state added to `ForumReading` has to be given a shape
            // here, and the build is where that should be noticed.
            switch reading {
            case .coming:
                plates
            case .words(let text):
                // **Prose, with no picture list.** A forum sends no custom emoji, so the scan
                // finds none and there is nothing to fetch; what it does find is the addresses
                // the author wrote, which is what #34 asks for in an open thread as much as in
                // the stream. The font is the same token: `EmojiTextRole.body` is `ShellType.body`.
                EmojiText.words(text, emojis: [], host: thread.host, covered: !linked)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
            case .withheld:
                said("lock", L10n.t("item.forum.withheld"))
            case .silent:
                // Nothing, and that is the answer. The forum was asked, it replied, and the
                // opening post had no words in it — a picture, an attachment, a poll. A sentence
                // here would be this app talking over an author who simply posted a photograph,
                // and it is told apart from the waiting state by the plates above.
                Color.clear.frame(height: 0)
            case .absent(let absence):
                said("exclamationmark.triangle", Self.sentence(for: absence))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(reading)))
        // **Here rather than inside the words**, because `.ignore` above throws away everything
        // the children offered, the actions `EmojiText` hangs on its own element included. See
        // `SpokenLinks`. Nothing to offer in the four states that have no words — and nothing
        // under a cover either, for `linked`'s reason: an action is a control, and a reader using
        // VoiceOver is not an exception to "the cover draws none".
        .spokenLinks(in: linked ? Self.words(of: reading) : "")
        .task(
            id: Wanting(
                thread: thread,
                settled: reading != .coming,
                generation: posts.generation,
                active: placeIsActive
            )
        ) {
            // Decision 20: a post is fetched only for the place the reader is in. **Only the
            // fetch is gated** — `posts.reading(…)` above still runs and still stamps interest on
            // every pass, on every page, or I8 breaks.
            guard placeIsActive, reading == .coming else { return }
            // Cancelled by the row going away, which is the whole point of it. A thrown
            // cancellation here means this row did not stay, so nothing is asked for.
            do { try await Task.sleep(for: Self.settle) } catch { return }
            await posts.fetch(thread)
        }
    }

    /// The waiting state: two plates, the longer one over the shorter, the way a paragraph sits.
    ///
    /// Two and not `lines`, deliberately. The plates are a mark saying "on its way", not a
    /// preview of how much is coming — this device does not know how much is coming — and a
    /// four-plate block reads as a claim about the post rather than as a wait.
    private var plates: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            plate(1.0)
            plate(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func plate(_ fraction: CGFloat) -> some View {
        Self.plate(ShellChrome.well(colorScheme), fraction: fraction)
    }

    /// One of this app's own sentences about the post, drawn so it cannot be mistaken for the
    /// post. `meta` and `inkFaint` are the row's quiet register — the same two the unstated
    /// figures in `BoardPickerSheet` use — and the glyph is what says at a glance that this line
    /// is a condition rather than content.
    private func said(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            Image(systemName: symbol)
            Text(text)
                // One line fewer than the words get, so a long sentence of this app's own cannot
                // fill a band meant for somebody's post — and no limit at all where the words
                // have none, because there is no band to overflow.
                .lineLimit(lines.map { max(1, $0 - 1) })
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .shellFont(.meta)
        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
    }

    /// Which sentence one kind of nothing gets. **No `default:`** — a fifth `Absence` has to be
    /// given words rather than quietly inheriting somebody else's.
    ///
    /// Shared with the thread pane rather than restated there: the four facts are facts about the
    /// forum and the device, not about which screen asked.
    static func sentence(for absence: ForumPosts.Absence) -> String {
        switch absence {
        case .refused: L10n.t("item.forum.refused")
        case .unreadable: L10n.t("item.forum.unreadable")
        case .unreachable: L10n.t("item.forum.unreachable")
        case .crowded: L10n.t("item.forum.crowded")
        }
    }

    /// What this app's own waiting states are made of, so the pane and the band cannot draw two
    /// different vocabularies for one idea. See `ForumWaiting`.
    static func plate(_ colour: Color, fraction: CGFloat = 1) -> some View {
        GeometryReader { space in
            RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous)
                .fill(colour)
                .frame(width: space.size.width * fraction, alignment: .leading)
        }
        .frame(height: ShellSpace.snug)
    }

    /// The author's own words, where this band has any. **Not `spoken`**, which also answers with
    /// one of this app's own sentences — and an address this app wrote is not one a post carries.
    static func words(of reading: ForumReading) -> String {
        if case .words(let text) = reading { return text }
        return ""
    }

    /// What the band says out loud. A screen reader is given every character of the post, never
    /// the line-limited string: a visual limit is a fact about this band's height and about
    /// nothing else.
    static func spoken(_ reading: ForumReading) -> String {
        switch reading {
        case .coming: L10n.t("item.forum.coming")
        case .words(let text): text
        case .withheld: L10n.t("item.forum.withheld")
        case .silent: L10n.t("item.forum.silent")
        case .absent(let absence): sentence(for: absence)
        }
    }
}

/// **Work in progress, drawn as motion** — what the reader asked for first: "the load more thread
/// should give the animation for loading".
///
/// ## Why this is plates and not a spinner
///
/// **This argument is the app's general rule now, and not this pane's exception.** It was written
/// for one reader's request about one list; the measurement behind it held for every other place
/// this app waits, and there were six of them in three vocabularies — a platform spinner at five,
/// these plates at one, and `RemoteImage`'s bare plate at the sixth — with three type roles and two
/// inks between them. They are one vocabulary now: this view, at every site that has a sentence,
/// in `ShellType.meta` and `ShellChrome.inkDim`, with the words first and the motion trailing them.
/// `RemoteImage` waits as `ShellWaiting` and is not a fourth: a picture-shaped hole where a picture
/// will be is a different statement from a sentence about an errand, and it has no words. That
/// wordless half is `ShellWaiting` now, and this view is its sentence-carrying sibling — the
/// clock, the wave and the still frame are read from there so the two cannot drift apart.
///
/// **The plates are the ellipsis, moving.** Every one of those sentences already ends in `…`, so
/// words-then-motion is the reading order the sentence has; a `ProgressView` in front of the words
/// puts a platform control where the reader's eye starts.
///
/// This shell already has a word for "asked for, not here yet", and it is a plate: `RemoteImage`
/// waits as `ShellWaiting` while a picture is on its way, and `ForumPostBand` draws two of
/// them where a post is. A reader who has scrolled one timeline has already learned what a waiting
/// slot looks like here, and a `ProgressView` would be a second, unrelated vocabulary for the same
/// fact — borrowed from the platform rather than from the app the reader is in. So this is the
/// same plate, three of them, with the one thing the static version could not say: that something
/// is happening *now*.
///
/// It stands beside a sentence rather than replacing one. The pane's `.coming` case said
/// "Loading the replies…" and said it perfectly well to a screen reader; what it did not do was
/// look any different from a sentence that had been there for a minute. The words are what the
/// state *is* and the motion is what says it is still going, so this draws both and hands the
/// screen reader only the words — a moving plate is not a fact anybody needs read out.
///
/// ## The reader who asked for less movement
///
/// `accessibilityReduceMotion` stops the clock outright, exactly as `EmojiText.clock` does, and
/// for the same reason: a reader who has turned motion off has said so about every moving thing in
/// the app, not about emoji in particular. What they get is `glow(_:at: 0)` — the first plate lit
/// and the others banked, a still frame that still reads as three plates and a sentence, and
/// **no second frame is ever drawn**. There is no `TimelineView` in that branch at all, so the
/// stillness is structural rather than a zero-speed animation that SwiftUI might still tick.
///
/// ## Why a clock and not `.repeatForever`
///
/// `withAnimation(.repeatForever)` would be fewer lines and would put the whole behaviour out of
/// reach of a test: whether it is running, and what it draws at a given instant, are both inside
/// SwiftUI. Split this way — a pure `clock(reduceMotion:)` and a pure `glow(_:at:)` — the two
/// claims this view actually makes are assertable without a screen, which is the shape unit 5
/// established for `EmojiText` and the shape the suite's existing reduce-motion test is written
/// against.
struct ForumWaiting: View {
    /// What this app says is happening. The accessible fact; the plates are decoration over it.
    let line: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How many plates. Three reads as a run rather than as a pair, and is few enough that the lit
    /// one is always obvious — it is a mark, not a progress bar, and this device does not know how
    /// much is coming.
    static let plates = 3

    /// The rhythm, which is `ShellWaiting`'s and no longer this view's own. Two copies of one
    /// cosine is how a shell ends up with two ways of waiting; these read the one.
    static var period: TimeInterval { ShellWaiting.period }
    static var tick: TimeInterval { ShellWaiting.tick }

    /// How bright one plate is at one instant, between banked and lit. Deeper than
    /// `ShellWaiting`'s ends for the reason written there: these plates trail a sentence that
    /// already says what is happening, so one of them may go nearly out.
    ///
    /// Both ends are this view's own numbers, and the agreement with `ShellWaiting.lit` is a
    /// coincidence of full being full rather than a coupling. Reading the ceiling from there
    /// would mean a change made for the bare plate silently moved these, which is the drift the
    /// shared *rhythm* above is meant to prevent, not to cause.
    static let banked: Double = 0.3
    static let lit: Double = 1.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Text(line)
                .shellFont(.meta)
                // **`inkDim` and not `inkFaint`, which is a small declared change.** Six sites
                // said this fact in two inks; `inkDim` is the token for *present, read second*,
                // which is what a sentence about an errand in progress is — and `inkFaint` is the
                // faintest engraving, for counts nobody is looking for. A reader waiting is
                // looking.
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let tick = Self.clock(reduceMotion: reduceMotion) {
                    TimelineView(.periodic(from: .now, by: tick)) { instant in
                        run(at: instant.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    run(at: 0)
                }
            }
            .frame(width: Self.width)
            Spacer(minLength: 0)
        }
        // One element carrying the sentence. Without `.ignore` a screen reader would be free to
        // walk into the `TimelineView` and read whatever the plates happen to name — the same
        // trap `EmojiText` documents one file over, and for the same reason it is closed here.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Three plates as wide as they are tall, with the gaps between them.
    private static let width =
        CGFloat(plates) * ShellSpace.snug + CGFloat(plates - 1) * ShellSpace.tight

    private func run(at instant: TimeInterval) -> some View {
        HStack(spacing: ShellSpace.tight) {
            ForEach(0..<Self.plates, id: \.self) { index in
                // The same ink as the sentence they trail: one ink for the whole statement, so a
                // reader meets one way of waiting rather than a sentence in one weight and a run
                // of plates in another.
                ForumPostBand.plate(ShellChrome.inkDim(colorScheme))
                    .frame(width: ShellSpace.snug)
                    .opacity(Self.glow(index, at: instant))
            }
        }
    }

    /// A clock only where one is wanted — nothing for a reader who asked for less movement.
    /// `ShellWaiting`'s answer, so one preference cannot stop one waiting state and not the other.
    static func clock(reduceMotion: Bool) -> TimeInterval? {
        ShellWaiting.clock(reduceMotion: reduceMotion)
    }

    /// How lit one plate is at one instant, in `banked...lit`: the shell's one wave, over this
    /// view's own ends.
    static func glow(_ index: Int, at instant: TimeInterval) -> Double {
        banked + (lit - banked) * ShellWaiting.wave(index, of: plates, at: instant)
    }
}
