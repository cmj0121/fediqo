import FediqoCore
import Foundation
import Observation
import os
import SwiftUI

/// In-memory session: unsigned sources, All and Trends, and the Account add flow.
@MainActor
@Observable
final class ShellSession {
    enum Catalog: Equatable {
        case loading
        case failed
        case empty
        /// The directory's entry is switched off in Preferences (#226): nothing is asked, and a
        /// source is added by its name.
        case off
        case ready([CatalogServer])
    }

    let http: any HTTPClient
    let store: ItemStore
    /// Each joined server's emoji catalogue, held for this run. On the session and not on the
    /// join, so that a server joined once is a server asked once.
    let emoji = EmojiCatalogueStore()

    /// The two picture caches this session's Clear button empties.
    ///
    /// Held here rather than reached for as `.shared` at each call site, so that **the figures
    /// Usage draws and the caches its button presses are the same objects by
    /// construction**. They used to agree by convention — the pane read `.shared` while `clear`
    /// took parameters — which is an agreement a preview or a test wired to fixture caches
    /// breaks silently: it would press the fixtures and draw the live figures, and the reading
    /// would simply not move.
    let pictures: ShellPictures
    let emojis: EmojiCache

    /// Every forum this run signs in to, one browser each — unit F2's transport.
    ///
    /// On the session for the same reason the two picture caches are: **what Clear presses and
    /// what Usage draws have to be the same object**, and a second one reached for as
    /// `.shared` at a call site is an agreement that a test or a preview breaks in silence.
    let forums: ForumSessions

    /// Every Mastodon this device is signed in to. Shared across windows like `forums`, so a
    /// sign-out in one is a sign-out in all.
    let mastodon: MastodonSessions

    /// One thread's opening post, fetched when its row is scrolled to — D30 — and the rest of
    /// the topic as its thread opens — D31, asked at once since #198.
    ///
    /// On the session for the reason the two picture caches and `forums` are: **what Clear
    /// presses and what Usage draws have to be the same object**. It is built here rather
    /// than passed in because it needs two things only the session has — this session's transport
    /// and this session's forum browsers, without which a thread on a forum the reader signed in
    /// to comes back withheld.
    let posts: ForumPosts

    /// A forum's ranked blogs, read as the reader opens them (#209). Beside `posts` and for its
    /// reason: what the blog's pane draws and what a Clear presses are the same object.
    let blogs: ForumBlogs

    /// Every act on a post this run has in the air, and every one that did not land — #106.
    ///
    /// On the session for `conversations`' reason: what a row draws and what a key presses have to
    /// be the same object. It holds no landed act at all — see its own doc, which is where the
    /// "not because this device remembered pressing it" half of #106 is actually enforced.
    let acts = ShellActs()

    /// The conversation around each post the reader has opened — #90.
    ///
    /// Beside `posts` and for its reason: the forum half of "what is around this post" is that
    /// object and the microblog half is this one, and both have to be the object a Clear presses.
    /// Nothing it holds is in the store's list of rows; see its own doc.
    let conversations = ShellConversations()

    /// What each server says it is, asked of that server rather than read off what was written
    /// down when it was joined — #86. On the session for `conversations`' reason.
    let flavours = ShellFlavours()

    /// `r` (#29): one reload at a time, and what the last one could not read.
    let reload = ShellReload()

    /// What this device is asking of a source right now (#164), for Preferences to list. The
    /// reads, joins and writes this session starts are put on it while they run; the caches and
    /// sign-ins it holds carry their own, the same one in the app. A test hands in another.
    @ObservationIgnored var work: SourceWork = .shared
    /// What the system's shared stores keep of a source, dropped as it is signed out of or
    /// removed (#221). The system's own; a test hands in its own jar.
    @ObservationIgnored var jar = SystemJar()
    /// Hosts a Remove is taking away right now, so an adopt landing in its awaits does not count
    /// them as added again (#221).
    @ObservationIgnored private var removals: Set<String> = []
    /// How many times each host has been removed, so a join still reading it when it is removed
    /// asks nothing more of it (#221). A join begun after the Remove reads it afresh.
    @ObservationIgnored private var removes: [String: Int] = [:]

    /// The sheet the reader is being shown the forum's own page in, or nothing.
    var signingIn: ForumSignInRequest?

    /// A host that turned this app away and that a sign-in might open — set only where the
    /// server answered with a refusal of its own, which is the one failure that is never the
    /// reader's spelling. It closes a hole this branch recorded and left open: the refusal
    /// message "tells the reader what happened and offers them nothing to do about it".
    var offerSignIn: String?

    /// The server the reader has pressed Remove on and not yet answered for, or nothing.
    ///
    /// **Nothing is destroyed while this is set.** Remove takes the boards the reader picked, and
    /// `clear`'s own comment is the argument for why that is worth a question first: pictures come
    /// back by themselves and a pick of eight boards out of forty does not. So the press sets this,
    /// the dialog says what goes, and only the confirm reaches `remove(host:)`.
    ///
    /// A host and not a `Source`, because the dialog needs the host to name it and the count of
    /// boards to pick its sentence, and both are readable off `sources` — a second copy of a source
    /// held here would be a copy that goes stale the moment the reader changes their boards.
    var removing: String?

    /// The server the reader has pressed Clear on and not yet answered for, or nothing.
    ///
    /// **Nothing is emptied while this is set** — `removing`'s shape, for a reason decision 29
    /// only half states. The colour is the user's overstatement; the confirmation is closing a
    /// real hole. `clear(host:)` reaches `ForumSessions.forget(host:)`, which drops the forum's
    /// cookies **and deletes the saved password from the Keychain** — and `forget`'s own doc makes
    /// the fairness of that conditional on one thing: *"the row says a password is held before the
    /// button is pressed"*. `UsagePane` draws `passwordLine` and meets it. An Account row
    /// draws no inventory line at all, by `DESIGN.md` §3.6's own rule, so until now this device
    /// deleted a password with nothing on screen having said one was held — and signed the reader
    /// out of a forum, changing the state of the icon beside the one they pressed.
    ///
    /// **One presenter, both entrances.** `prefs.cache.clear` is one word for one call, so a Clear
    /// that confirms on Account and fires straight on Usage would be the same word doing two
    /// different things two panes apart. `UsagePane` sets this too.
    var clearing: String?

    /// The Mastodon whose sign-in has been pressed and whose scope question has not been answered
    /// yet, or nothing (#69).
    ///
    /// **Nothing is asked of the server while this is set.** The question is put before the
    /// browser opens, not after it comes back, because what it decides is what the server's own
    /// page will ask the reader to agree to — a choice made afterwards would be this app deciding
    /// and the server reporting. Cancelling it opens nothing and changes nothing.
    ///
    /// `removing`'s shape, and a host for its reason: the dialog names it, and a copy of the
    /// source held here would be one that goes stale. **Not `signingIn`**, which is the forum
    /// sign-in already running in a web view — this is a question, and nothing is running.
    var signInChoice: String?

    /// Which stage of adding a source the reader is being shown, or nothing.
    ///
    /// **Nothing has been added at any of the three.** Browsing is a list, previewing is what a
    /// server says about itself, and choosing boards is D28's pause — the source, its boards and
    /// its threads all wait on the reader through every one of them. Clearing this is therefore a
    /// complete undo at any stage: there is nothing to take back.
    ///
    /// **One piece of state for all three**, which is what buys the Back button on the boards
    /// stage: the reader returns to the preview they already have instead of the app asking the
    /// forum for its index again. See `JoinStage`.
    ///
    /// **Two presenters read it and they cannot both fire.** A typed hostname's preview is drawn
    /// in `AccountPane`; everything else is the sheet on `FediqoRootView`. Which one is a function
    /// of the stage — `JoinStage.surface` — and not a second flag beside it, so there is no
    /// arrangement of this object in which both are true or neither is.
    /// A window closed with its add sheet still on the browse step lets the directory go with it
    /// (#220): `SourceWork.adding` is nonisolated and `work` a main-actor class, so both are
    /// reachable from here.
    deinit {
        work.adding(false, by: ObjectIdentifier(self))
        if let allowanceWatch { NotificationCenter.default.removeObserver(allowanceWatch) }
    }

    var stage: JoinStage? {
        didSet {
            // The browse step is the one moment the directory of servers may be asked (#220).
            let browsing = switch stage {
            case .browsing, .browsingServers: true
            default: false
            }
            work.adding(browsing, by: ObjectIdentifier(self))
        }
    }

    /// D28's pause, read off the stage.
    ///
    /// **Get-only, and that is the point of it rather than a caution.** It used to be the stored
    /// state a sheet was presented from, and a second `.sheet` modifier that can be active at the
    /// same time as another is silently ignored on iOS. Now the stage is the one presenter and
    /// this is a reading of it, so nothing can bind it and the two cannot disagree.
    var choosing: BoardChoice? {
        guard case .choosingBoards(let offer, _) = stage else { return nil }
        return BoardChoice(offer: offer)
    }

    /// What each host said about itself when it was looked at.
    ///
    /// **Filled by the look the reader already waited for, so the source row costs no request.**
    /// Written under the parsed host, which is what `SourceProfiles.answer` normalises to — a map
    /// keyed by what somebody typed would hold two rows for one server.
    private(set) var profiles: [String: ProfileAnswer] = [:]

    /// The source page's list, in join order, and **costing no request**.
    ///
    /// Every row is built from what this session already holds: the sources the store handed back,
    /// and the answer each host gave when it was looked at. A source the reader joined through some
    /// route that never previewed it has no entry in `profiles` and reads `.unasked`, which is a
    /// real answer and not a hole — the row then draws its host and its shape, honestly, rather
    /// than going and asking the server to fill a gap nobody is waiting on.
    ///
    /// Derived rather than stored, for the reason `choosing` is: a second copy of `sources` kept
    /// beside `sources` is a copy that goes stale the moment a board is picked.
    var rows: [SourceRow] {
        sources.map { source in
            SourceRow(
                source: source,
                profile: profiles[source.host] ?? .unasked(host: source.host, kind: source.kind),
                signedIn: isSignedIn(host: source.host),
                // From the session and never from the row, because two of the three facts that
                // decide it — what the sign-in bought and what the source has refused since —
                // are held here.
                writing: mastodon.writing(host: source.host, kind: source.kind)
            )
        }
    }

    /// Which errand the sheet is showing, counted up.
    ///
    /// **`checking` stopped covering the flow when adding split in two.** The preview sheet is up
    /// while nothing is on the wire, so a returning `.chooseBoards` from a press the reader
    /// swiped away would spring the sheet back over a reader who had left. Every entry point
    /// takes a number at the top and compares it before writing `stage`; every dismissal bumps
    /// it. This is `ForumPosts.forget(host:)`'s guard in the shape this object needs — the answer
    /// is refused after the suspension rather than the work cancelled before it.
    @ObservationIgnored private var errand = 0

    /// Boards the reader picked that could not be read, from the last pick that read some.
    ///
    /// **Not an edge case, and not a silence.** A reader can pick a board off the list this app
    /// showed them and have it fail — `install-a.example` board 37 is a live one, 114,662 threads
    /// served as picture cards with no date on any of them, and it fails `.noThreads`. They
    /// picked it; they are owed a sentence. Dropping it from the rail and saying nothing would
    /// leave them counting tabs to find out.
    var unread: [UnreadBoard] = []

    /// Where every board picked failed at once: how many were picked, so the sentence about the
    /// forum can at least say what it was about. Core throws the first board's error and keeps
    /// no list in that case, which is the right contract — nothing was added — but it leaves the
    /// reader with a sentence naming none of what they chose.
    var unreadAll = 0

    var queries: [TimelineQuery] = []
    /// The query in front. Nothing only while nothing is joined; not persisted.
    var timelineID: TimelineQuery?

    /// The post the reader was standing on in each timeline they have left this run (#100).
    ///
    /// **Here, because `timelineID` is here.** The lamp itself is the root view's — one list, one
    /// selection, which the thread and the reload both read — and what each query remembers
    /// belongs beside the query it is remembered against. Nothing redraws when it changes, so it
    /// is out of observation: it is read exactly once, on the pass that answers a tab press.
    @ObservationIgnored var timelinePlaces = TimelinePlaces()

    /// The timelines the reader wrote, in their tab order (#27). Changed only through
    /// `commit(_:)` and `removeTimeline(_:)`, which keep them on this device.
    var written: [TimelineDefinition] = []
    /// The kept timelines could not be read by this build. They stay as they are on the device
    /// and nothing is written over them (Decision 15); the timeline says so.
    var timelinesUnreadable = false
    /// Where the reader's timelines are kept, or nothing for a session that keeps none.
    @ObservationIgnored let timelineStore: WrittenTimelineStore?
    /// The timeline editor, where it is open. Edits apply on Done (Decision 21).
    var editing: TimelineDraft?
    /// A sentence the timeline shows for a moment.
    var toast: ShellToast?
    /// Every held note's folded text, built the first time something reads text after `notes`
    /// changes — a written timeline with a keyword or author rule — and reusing what did not
    /// change, so a redraw folds nothing and a session that reads no text folds nothing at all.
    var textIndex: TextIndex {
        if !textIndexIsCurrent {
            builtTextIndex = TextIndex(notes, reusing: builtTextIndex)
            textIndexIsCurrent = true
        }
        return builtTextIndex ?? TextIndex([])
    }
    @ObservationIgnored private var builtTextIndex: TextIndex?
    @ObservationIgnored private(set) var textIndexIsCurrent = false
    /// Bumped each time `notes` is assigned. Observed, so a view that read a cached timeline
    /// still redraws when the notes under it change.
    private(set) var notesRevision = 0
    /// The last timeline drawn and what it was drawn from, so a redraw that reads it several
    /// times evaluates the rules once.
    @ObservationIgnored var drawnTimeline: DrawnTimeline?
    /// The person's page last drawn and what it was drawn from. See `heldPosts(of:)`.
    @ObservationIgnored var drawnPerson: HeldByPerson?
    /// The tag's page last drawn and what it was drawn from. See `heldPosts(under:)`.
    @ObservationIgnored var drawnTag: HeldTag?
    /// How many times the rules ran for the stream: the test's window on `drawnTimeline`.
    @ObservationIgnored var timelineEvaluations = 0
    /// Each tab's missing-rule mark as last worked out, so a redraw compiles no tab again.
    @ObservationIgnored var missingRules: [TimelineQuery: MissingRules] = [:]
    /// How many times a tab's mark was worked out: the test's window on `missingRules`.
    @ObservationIgnored var missingRuleEvaluations = 0

    /// The query the timeline draws: the one selected, or All.
    var currentTimeline: TimelineQuery { timelineID ?? .all }
    /// Every change is handed on to `forums`, which is the one place that knows which of them
    /// are forums a sign-in can be held for.
    var sources: [Source] = [] {
        didSet {
            let discuz = sources.filter { $0.kind == .discuz }
            forums.watch(forums: discuz.map(\.host))
            // The boards each forum is read for, which is what decides whether reaching a ranked
            // thread may read it (`ForumPosts.readsWhenReached`). Written only when it changed,
            // so a reload that leaves the picks alone does not wake every forum row.
            let read = Dictionary(
                discuz.map { ($0.host, Set($0.boards.map(\.fid))) }, uniquingKeysWith: { a, _ in a }
            )
            if posts.boardsRead != read { posts.boardsRead = read }
        }
    }
    var notes: [Note] = [] {
        didSet {
            holdings = Holdings(notes: notes, per: heldPeriod)
            textIndexIsCurrent = false
            notesRevision += 1
            heldRevision += 1
            searchTextIsCurrent = false
        }
    }

    /// Every post this device holds aside (#175) — what a search brought back, a thread's answers
    /// — which no timeline draws. **Read by the search alone** (#176): a search finds what this
    /// device holds, and holding a search's finds aside is what keeps All from growing by them.
    private(set) var aside: [Note] = [] {
        didSet {
            heldRevision += 1
            searchTextIsCurrent = false
        }
    }
    /// Bumped as `notes` or `aside` is assigned: what a search's answer is kept against.
    private(set) var heldRevision = 0

    /// Everything a search reads: what the timelines draw, and what is held aside.
    var searchable: [Note] { aside.isEmpty ? notes : notes + aside }

    /// `textIndex` over `searchable`, for a search through a timeline whose rules read text. The
    /// same as it where nothing is held aside, which is most of the time.
    var searchTextIndex: TextIndex {
        guard !aside.isEmpty else { return textIndex }
        if !searchTextIsCurrent {
            builtSearchText = TextIndex(searchable, reusing: builtSearchText ?? builtTextIndex)
            searchTextIsCurrent = true
        }
        return builtSearchText ?? TextIndex([])
    }
    @ObservationIgnored private var builtSearchText: TextIndex?
    @ObservationIgnored private var searchTextIsCurrent = false

    /// The row at the top of the stream, as the reader last left it scrolled (#110).
    ///
    /// **Here and not on the pane**, because the pane is what a window dragged across the width
    /// where the arrangement changes throws away and builds again; the session is not. **And
    /// past observation**, because the scroll view writes it on every row that passes the top,
    /// and a redraw of everything that reads this session on every one of those would be the
    /// scroll paying for a note nobody reads until the list is drawn again.
    @ObservationIgnored var scrolledTop: String?

    /// The row one id stands for, anywhere in what this device holds — or nothing, where this
    /// device does not hold it any more.
    ///
    /// **Over the store and not over the stream** (#122). A conversation opened from somebody's
    /// page is opened from a post of theirs, and what is theirs is everything held rather than
    /// what the query in front lets through — so a root looked for among the timeline's rows is
    /// a root a rule can hide, and the pane would draw the timeline under the press instead of
    /// the conversation the reader pressed for. The row id is split once and each note's key
    /// compared to it, so walking past a note builds nothing; the row is built once, for the one
    /// note that matched.
    ///
    /// **A row held aside too** (#176, #124, #178): a search's find, a post under a tag or an
    /// answer read in a thread is a row a reader presses like any other, and the conversation it
    /// opens is looked up here — `heldNote(_:)`'s one rule, so the row a press opens and the note
    /// its marks act on are found the same way.
    func held(_ rowID: String) -> DummyItem? {
        heldNote(rowID).map(DummyItem.init)
    }

    /// The store row one row id stands for: in `notes`, and **in what is held aside too** (#178).
    /// See `held(_:)`.
    ///
    /// A search hit the sources sent (#176) and an answer read in a thread (#177) are held aside
    /// and drawn where they were found, and a press on one opens the conversation around it and
    /// acts on it — which is this lookup. Found in `notes` only, the press opened nothing: the
    /// pane drew the page under it, and the marks under the post acted on nothing. **Nothing here
    /// puts a row in All**: `notes` stays what `ItemStore.all()` draws, and a row found here keeps
    /// where it is held through every read and act, `Note.refreshed(over:)`'s rule. What `aside`
    /// leaves out — a forum topic's kept replies, which are not threads — is not found here either.
    func heldNote(_ rowID: String) -> Note? {
        guard let key = NoteKey(rowID: rowID) else { return nil }
        let matches = { (note: Note) in note.source.host == key.host && note.id == key.id }
        return notes.first(where: matches) ?? aside.first(where: matches)
    }

    /// The note behind a row, wherever this run holds it: a store row, or an answer read in an
    /// open conversation this run has not adopted from the store yet.
    func note(ofRow rowID: String) -> Note? {
        heldNote(rowID) ?? conversations.note(rowID)
    }

    /// What `notes` holds, counted (#7) — rebuilt where `notes` is assigned or the breakdown
    /// switches between week and month, never on a redraw.
    private(set) var holdings = Holdings(notes: [], per: .month)

    /// Whether the breakdown is by week or by month.
    var heldPeriod: HeldPeriod = .month {
        didSet { holdings = Holdings(notes: notes, per: heldPeriod) }
    }

    /// Which purpose Usage is showing. Tab rotates it the way it rotates timeline queries.
    var usagePurpose: UsagePane.Purpose = .source

    /// The source whose detail Usage's Sources tab is showing (#234), by host; nothing is the list.
    var usageOpened: String?

    /// Escape on Usage: back from a source's detail to the list. Nothing to leave is not a press.
    @discardableResult
    func closeUsageSource() -> Bool {
        guard usageOpened != nil else { return false }
        usageOpened = nil
        return true
    }

    /// Tab and ⇧Tab on Usage: Sources, Time, Keep, Copies, and round again.
    @discardableResult
    func rotateUsageTab(by step: Int) -> Bool {
        usagePurpose = DummyCommand.advanced(Array(UsagePane.Purpose.allCases), from: usagePurpose, by: step)
        return true
    }

    /// Which tab Preferences is showing (#143): what a person chooses, or which Fediqo this is.
    var preferencesPurpose: PreferencesPane.Purpose = .choices

    /// Whether the record of everything this run has asked of the sources is open (#218).
    var activityShown = false

    /// Tab and ⇧Tab on Preferences, the way they rotate Usage: Settings, This Fediqo, In flight,
    /// and round again.
    @discardableResult
    func rotatePreferencesTab(by step: Int) -> Bool {
        preferencesPurpose = DummyCommand.advanced(
            Array(PreferencesPane.Purpose.allCases), from: preferencesPurpose, by: step
        )
        return true
    }

    /// How many times the reader has cleared a server — decision 14's press, counted.
    ///
    /// **A signal, not a statistic.** Three caches hold this device's copy of a server, and only
    /// one of them announces a Clear to the views drawing from it: `ShellPictures` is
    /// `@Observable` and bumps its generation, so every `RemoteImage` on screen asks again by
    /// itself. `EmojiCache` deliberately announces nothing at all — a hundred lines each carrying
    /// a handful of shortcodes is exactly the audience a cache must not wake — so a line that has
    /// already resolved its pictures keeps drawing them, and its `.task(id: request)` does not
    /// re-run, because the request is unchanged. The reader presses Clear and the emoji stay.
    ///
    /// This is what a line can key on instead: one counter, on the object that performs the
    /// Clear, observed by the views that already hold this session. It costs the emoji cache
    /// nothing, because nothing here is inside it.
    private(set) var cleared = 0

    var hostname = ""
    var catalog: Catalog = .loading
    /// Whether anything this session started is on the wire.
    ///
    /// **Derived, because it is `progress != nil` and never anything else.** It was stored, and
    /// all four errand sites wrote `checking = true` on the line before they wrote `progress` and
    /// cleared both in one `defer` — so the two were one fact in two properties, which is the
    /// arrangement `ProgressReport`'s own doc argues against twenty lines below: *"One value and
    /// not two properties … two properties is two things to forget at each of them."* That
    /// argument was about the surface and the sentence; it applies verbatim here.
    ///
    /// **The drift had already reached the suite.** Three tests set `checking = true` with no
    /// `progress` — busy, with no sentence anywhere — which is a state no press can produce and
    /// which `AccountPane.pageWaiting` and `SourceRow.waitingLine` both read as *nobody is
    /// waiting*. Derived, it is unspellable.
    var checking: Bool { progress != nil }

    var progressHost = ""
    var refuse: String?
    /// The Account search field is first responder; dummy keys must not steal its typing.
    var searchFocused = false

    /// Writes the store to disk. Set by the app so a drop by time survives a relaunch.
    @ObservationIgnored var persist: (@MainActor () async -> Void)?

    init(
        http: any HTTPClient,
        store: ItemStore = ItemStore(),
        pictures: ShellPictures = .shared,
        emojis: EmojiCache = .shared,
        forums: ForumSessions = ForumSessions(),
        mastodon: MastodonSessions = MastodonSessions(),
        posts: ForumPosts? = nil,
        blogs: ForumBlogs? = nil,
        timelines: WrittenTimelineStore? = nil
    ) {
        self.http = http
        timelineStore = timelines
        self.store = store
        self.pictures = pictures
        self.emojis = emojis
        self.forums = forums
        self.mastodon = mastodon
        // Built with this session's forum browsers, so a thread on a forum the reader signed in
        // to is read through the engine that holds the cookies rather than around it.
        //
        // **Not built from `http`.** The session's transport is whatever a test or a preview
        // handed in and, in the product, a `URLSessionClient` at the 128 MiB last line. A thread
        // page is a caller that knows what it expects — the largest measured on four installs is
        // 274KB — so it carries its own far tighter ceiling. See `ForumPosts.maxBytes`, and the
        // plan's standing item about per-caller response ceilings, of which this is the first.
        self.posts = posts ?? ForumPosts(through: forums)
        // Built with the same forum browsers, for `posts`' reason (#209).
        self.blogs = blogs ?? ForumBlogs(through: forums)
        // An opening post read is kept with its row (#154). Weak: the cache is this session's.
        self.posts.keeping = { [weak self] key, opening in self?.keep(opening, for: key) }
        // A topic's replies land in the store and are read back from it (#177). Weak, likewise.
        self.posts.landing = { [weak self] host, tid, replies in
            await self?.land(replies, host: host, tid: tid) ?? []
        }
        self.posts.reading = { [weak self] host, tid in
            await self?.keptReplies(host: host, tid: tid) ?? []
        }
        // A blog read is kept with its row (#209). Weak, likewise.
        self.blogs.landing = { [weak self] key, blog in await self?.keep(blog, for: key) }
        switch timelines?.load() {
        case .timelines(let kept)?: written = kept
        case .unreadable?: timelinesUnreadable = true
        case nil: break
        }
        // The person's list changing while the servers are listed is answered on the spot (#226).
        allowanceWatch = NotificationCenter.default.addObserver(
            forName: SourceWork.allowancesChanged, object: nil, queue: .main
        ) { [weak self] note in
            let from = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.allowancesChanged(by: from) }
        }
    }

    /// The watch on the person's list, taken off as this goes.
    @ObservationIgnored private nonisolated(unsafe) var allowanceWatch: (any NSObjectProtocol)?

    /// The unsent text, kept when the composer closes without sending (#56). In-session only.
    var composeDraft = ""
    /// The source the composer will write to, among those that may be written on.
    var composeHost: String?
    /// How far the post goes. Default public, which is what a Mastodon calls everyone.
    var composeAudience: Audience = .everyone
    /// Ceilings already asked for this run, so opening compose twice does not ask twice.
    @ObservationIgnored private var postLimits: [String: Int] = [:]

    var availability: ShellAvailability {
        ShellAvailability(
            queryIDs: Set(queries.map(\.id)),
            signedIn: sources.contains { isSignedIn(host: $0.host) }
        )
    }

    /// Sources `SourceWriting.writes` names — forums, a read-only sign-in and a refused write
    /// are not offered.
    var writableSources: [Source] {
        rows.filter { $0.writing == .writes }.map(\.source)
    }

    /// Chooses a source they may write on, if the one held is no longer offered.
    func prepareCompose() {
        let offered = writableSources
        if let host = composeHost, offered.contains(where: { $0.host == host }) { return }
        composeHost = offered.first?.host
    }

    func postLimit(of host: String) -> Int {
        if let held = postLimits[host] { return held }
        if case .stated(let profile) = profiles[host] {
            return MastodonWrite.limit(advertised: profile.statusLimit)
        }
        return MastodonWrite.defaultLimit
    }

    /// Asks the instance where this run has not already been told, and remembers the answer.
    /// The composer's chosen source where no host is named; an answer names its own (#108).
    func refreshPostLimit(of named: String? = nil) async {
        guard let host = named ?? composeHost else { return }
        if postLimits[host] != nil { return }
        if case .stated(let profile) = profiles[host] {
            postLimits[host] = MastodonWrite.limit(advertised: profile.statusLimit)
            return
        }
        do {
            postLimits[host] = try await MastodonClient(
                http: WatchedHTTP(http, for: .serverCheck, in: work), host: host
            ).statusLimit()
        } catch where DarkNetwork.caused(error) {
            // Not remembered: the next open asks again once the network is back (#222), and
            // `postLimit(of:)` says Mastodon's own 500 meanwhile.
        } catch {
            postLimits[host] = MastodonWrite.defaultLimit
        }
    }

    var canPost: Bool {
        ComposerSheet.canSend(
            text: composeDraft,
            limit: composeHost.map(postLimit(of:)) ?? MastodonWrite.defaultLimit,
            hasSource: composeHost.map { host in writableSources.contains { $0.host == host } }
                ?? false
        )
    }

    /// Writes the draft to the chosen source and takes the returned post into the store.
    /// Empty or over-long text is not sent. A failure keeps the draft.
    func post() async throws {
        let text = ComposerSheet.trimmed(composeDraft)
        guard !text.isEmpty, let host = composeHost else { return }
        guard writableSources.contains(where: { $0.host == host }) else {
            throw MastodonWriteError.noSource
        }
        guard text.count <= postLimit(of: host) else { return }
        guard let door = mastodon.authorized(host: host, for: .write) else {
            throw MastodonWriteError.noSource
        }
        do {
            _ = try await MastodonWrite(door: door, store: store)
                .post(text, visibility: composeAudience)
            composeDraft = ComposerSheet.draftAfterLanding(current: composeDraft, sent: text)
            await adopt()
            await persist?()
        } catch {
            writeFailed(error, host: host)
            throw error
        }
    }

    /// What a write's failure says about the sign-in it went through, written against `host`:
    /// a 401 the account check confirmed signs the source out, and a 403 marks the source as
    /// having turned a write away. **One reading for every write** — a post, an answer and each
    /// act — because they are the same two answers from the same door, and a second reading of
    /// them is how two writes come to tell a reader different things about one sign-in. Any
    /// other failure says nothing about the sign-in.
    private func writeFailed(_ error: any Error, host: String) {
        switch error as? MastodonAuthError {
        case .signedOut?: mastodon.endedByServer(host: host)
        case .http(403)?: mastodon.refusedWrite(host: host)
        default: break
        }
    }

    /// What may be done to one post, from the source it was read through and whether this device
    /// can name it there (#106).
    ///
    /// **Asked of the session and never worked out on the row**, for `rows`' reason: two of the
    /// three facts that decide it — what the sign-in bought, and what the source has turned away
    /// since — are held here, and a row deriving its own answer would be a second derivation free
    /// to disagree with the one the source page draws.
    ///
    /// **A row two sources carried (#114) offers every act any copy behind it offers** (#136).
    /// Merging changes how a post is drawn, never what a reader can do with it, so a reader signed
    /// in to the second source and not the first keeps what the second source's row gave them
    /// before the rows were one. Which copy each act then goes through is `actingCopy`. Where no
    /// copy offers anything, the row says why as a row of one does — the reason of the first copy
    /// that has one, which is the drawn copy wherever its source is still here.
    ///
    /// A post whose host is not a source here offers nothing and says nothing: a fixture, a
    /// preview, a row left over from a Remove. That is `PostActs.none` rather than a refusal,
    /// because there is no source for a sentence to be about.
    func acts(on item: DummyItem) -> PostActs {
        Self.acts(from: item.copies.map(ownActs(on:)))
    }

    /// The row's acts out of each copy's own, in the row's order — `acts(on:)` over copies
    /// whose acts are already worked out.
    private static func acts(from each: [PostActs]) -> PostActs {
        let offered = each.reduce(into: Set<PostAct>()) { $0.formUnion($1.offered) }
        guard offered.isEmpty else { return PostActs(offered: offered) }
        return each.first { $0.refused != nil } ?? .none
    }

    /// The copy behind `item` that `act` goes through, or nothing where no copy offers it (#136).
    ///
    /// **The first copy that offers the act, in the row's own order**, so the drawn copy wherever
    /// the reader can write on its source — the same row answering the same way every time — and
    /// otherwise the first of the others that can. The act then uses that copy's host, that
    /// host's sign-in and the id that host gave the post, all three together: a status id names
    /// a post only on the server that issued it, and the drawn copy's id sent to another host
    /// would name nothing, or somebody else's post.
    ///
    /// For a row of one this is the row itself or nothing, exactly as before there were copies.
    func actingCopy(of item: DummyItem, for act: PostAct) -> DummyItem? {
        item.copies.first { ownActs(on: $0).offers(act) }
    }

    /// A row's share of the acts, everything but the presses: what it offers, the copy each act
    /// goes through and where each has got to there. The panes add the presses.
    ///
    /// **Each standing is read off the copy its act goes through** (#136), which is where
    /// `perform` keeps it, so a press through a merged row's second source is drawn on its way
    /// and a failure there is drawn as one. `through` names only a copy that is not the row.
    ///
    /// Each copy's own acts are worked out once, and both the offer and each act's copy are read
    /// off them — `acts(on:)` and `actingCopy(of:for:)` asked separately would ask every copy
    /// again for every act.
    func acting(on item: DummyItem) -> ItemActing {
        let each = item.copies.map { (copy: $0, acts: ownActs(on: $0)) }
        var acting = ItemActing(acts: Self.acts(from: each.map(\.acts)))
        for act in PostAct.allCases {
            let copy = each.first { $0.acts.offers(act) }?.copy ?? item
            acting.standings[act] = acts.standing(of: copy.id, act)
            if copy.id != item.id { acting.through[act] = copy }
        }
        return acting
    }

    /// What one copy offers on its own source — the rule a row of one has always read.
    private func ownActs(on copy: DummyItem) -> PostActs {
        guard let kind = sources.first(where: { $0.host == copy.source.host })?.kind else {
            return .none
        }
        return PostActs.on(
            mastodon.writing(host: copy.source.host, kind: kind),
            nameable: copy.statusID != nil,
            mine: isMine(copy),
            gone: copy.goneSince != nil
        )
    }

    /// Whether the reader wrote this post, **as its source said this run** (#109): the post's
    /// handle against who the source says the reader is. Not known is not theirs.
    ///
    /// A boost the reader made of somebody else's post names that somebody as its author, so it is
    /// never offered for taking back — the boost is taken back with the boost's own mark.
    func isMine(_ item: DummyItem) -> Bool {
        guard let me = mastodon.handles[item.source.host], let handle = item.handle else { return false }
        return me.caseInsensitiveCompare(handle) == .orderedSame
    }

    /// The post whose taking back is being asked about, where one is (#109). Observed, and the
    /// question is presented from it; nothing goes while it is only asked.
    ///
    /// The row as it was pressed, every copy behind it, because a confirmed take-back lets go of
    /// all of them. What the question names is `withdrawingCopy`.
    var withdrawing: DummyItem?

    /// The copy the take-back being asked about goes through: the reader's own post, on the
    /// source they wrote it on (#136). **What the question names**, its words and its host, since
    /// that is the post that goes and the source it goes from.
    var withdrawingCopy: DummyItem? {
        withdrawing.flatMap { actingCopy(of: $0, for: .withdraw) }
    }

    /// Asks whether to take `item` back. **Asked, never pressed** — the only act in #54 that asks
    /// first, because a post taken back does not come back. Refused where the post does not offer
    /// it, which is the same one rule the mark reads.
    @discardableResult
    func askToWithdraw(_ item: DummyItem) -> Bool {
        guard let copy = actingCopy(of: item, for: .withdraw),
              !acts.isOnItsWay(copy.id, .withdraw)
        else { return false }
        withdrawing = item
        return true
    }

    /// The question answered no: everything stays as it was.
    func cancelWithdraw() {
        withdrawing = nil
    }

    /// The question answered yes: the post is taken back from its source, and once the source
    /// says so it leaves the timeline, any open thread and the store, so it stays gone after a
    /// relaunch. A failure leaves it where it is and the same act asks again.
    ///
    /// **A row that stands for two copies (#114) lets go of all of them.** The act goes through
    /// the copy that is the reader's own post on a source they signed in to (#136) — its source,
    /// under its id — and the other copies are that same post as other servers carried it. Their
    /// author has just taken it back at the source it was written through, which is what tells
    /// every other server to drop it; leaving them here would redraw the row as the next copy and
    /// put back the post the reader just watched go. They are dropped only after the source has
    /// said the post went.
    func withdraw(_ item: DummyItem) async {
        withdrawing = nil
        guard let copy = actingCopy(of: item, for: .withdraw) else { return }
        let others = item.copies.filter { $0.id != copy.id }
            .map { NoteKey(host: $0.source.host, id: $0.noteID) }
        await perform(.withdraw, on: item) { door, note in
            try await MastodonWrite(door: door, store: self.store).withdraw(note)
            for key in [note.key] + others {
                await self.store.forget(key)
                self.conversations.drop(key)
            }
            return note
        }
    }

    /// Boosts the post or takes the boost back (#106), or favourites it or takes the favourite
    /// back (#107) — the same press either way, and one press with two meanings. The other two
    /// acts are not toggles, and do nothing here.
    ///
    /// **Which way it goes is read off the post and not off the press.** The acting copy's
    /// `boosted` or `favourited` is what the source it goes through last said, so a row the reader
    /// boosted in another app and this device has since fetched takes the boost back on its first
    /// press here, which is what the mark under it says it will do.
    ///
    /// Nothing is written down about the press landing: the store takes the server's answer, and
    /// what the row draws afterwards is that. A refusal leaves the post exactly as it was and
    /// leaves a failure the same press clears by trying again.
    func toggle(_ act: PostAct, on item: DummyItem) async {
        guard act == .boost || act == .favourite else { return }
        await perform(act, on: item) { door, note in
            let write = MastodonWrite(door: door, store: self.store)
            return act == .boost
                ? try await write.boost(note, on: note.boosted != true)
                : try await write.favourite(note, on: note.favourited != true)
        }
    }

    /// One act on one post, with everything every act shares: the guard against a second press
    /// while the first is out, the sign-in, the store, and the three sentences #53 sets.
    ///
    /// **Everything below is the acting copy's, never the row's** (#136): the held note, the door
    /// and the host a 401 or a 403 is written against are all read off the one copy `actingCopy`
    /// chose, and the standing is keyed by that copy, so what the mark draws while the act is out
    /// is the act on the post it went to. For a row of one the copy is the row.
    ///
    /// **The held note is read here and handed down, rather than each act finding its own.** The
    /// row is a drawing of a note and the act is performed against the note, and an act that
    /// looked the row up a second time inside itself would be two lookups that a Remove landing
    /// between them can answer differently.
    ///
    /// A 401 the account check confirms signs the source out, and a 403 marks the source as
    /// having turned a write away — `writeFailed`, exactly as `post()` reads them.
    ///
    /// **Every failure leaves the act failed**, a cancelled one included: a cancelled act is one
    /// that did not arrive, said in the one sentence a reader can act on — press again. There is
    /// no third thing to tell them, and leaving no standing at all would draw the post as though
    /// the press had landed.
    private func perform(
        _ act: PostAct,
        on item: DummyItem,
        _ body: @escaping (MastodonAuthorized, Note) async throws -> Note
    ) async {
        guard let copy = actingCopy(of: item, for: act) else { return }
        let host = copy.source.host
        // A store row, or an answer read in an open conversation, which #90 keeps out of the store.
        guard let note = note(ofRow: copy.id),
              let door = mastodon.authorized(host: host, for: .write)
        else { return }
        guard acts.begin(copy.id, act) else { return }
        do {
            let answered = try await body(door, note)
            conversations.replace(answered)
            acts.landed(copy.id, act)
            await adopt()
            await persist?()
        } catch {
            writeFailed(error, host: host)
            acts.failed(copy.id, act)
        }
    }

    /// The answer being written, where one is (#108). Nothing while no answer is open.
    ///
    /// **Observed, and the sheet is presented from it**, so a key and a press on the mark open
    /// the one surface by writing the one value.
    var answering: AnswerTarget?
    /// What has been written to each post and not yet sent, by row. Kept when the sheet closes
    /// unsent and when a send fails, so every character survives both; cleared only by a landing.
    var answerDrafts: [String: String] = [:]
    /// Who each unsent answer reaches, by row — chosen before it is sent, from where it started.
    var answerReach: [String: Audience] = [:]

    /// Opens the answer to `row`, inside the conversation around `root`.
    ///
    /// **Refused where the post does not offer it**, the same one rule the mark under it reads.
    /// On a row two sources carried the answer is to the copy `actingCopy` chooses (#136), and
    /// the sheet is opened on that copy, so the source it names, the id it answers and the draft
    /// kept for it are that copy's own.
    /// The first time a post is answered, the draft starts with its author's handle, since a
    /// Mastodon answer reaches the person answered only where it names them — the words are the
    /// reader's to change — and the reach starts where the post is and no wider.
    @discardableResult
    func openAnswer(to row: DummyItem, in root: DummyItem) -> Bool {
        guard let item = actingCopy(of: row, for: .answer) else { return false }
        if answerDrafts[item.id] == nil, let handle = item.handle, handle.hasPrefix("@") {
            answerDrafts[item.id] = handle + " "
        }
        let start = Audience.answering(
            // Each half asked for an audience in turn: a store row that carries none leaves the
            // conversation's copy to say, as `note(ofRow:)` would not.
            heldNote(item.id)?.audience ?? conversations.note(item.id)?.audience
        )
        if answerReach[item.id] == nil { answerReach[item.id] = start }
        answering = AnswerTarget(item: item, root: root, start: start)
        return true
    }

    /// The answer's text, bound for the sheet. Empty where nothing is kept for this post.
    func answerDraft(_ target: AnswerTarget) -> String { answerDrafts[target.id] ?? "" }

    func canSendAnswer(_ target: AnswerTarget) -> Bool {
        ComposerSheet.canSend(
            text: answerDraft(target),
            limit: postLimit(of: target.item.source.host),
            hasSource: acts(on: held(target.item.id) ?? target.item).offers(.answer)
        )
    }

    /// Sends the answer to the source the post was read through — **the post decides it; it is
    /// not a choice** — and lays what landed into the conversation under what it answers.
    ///
    /// A failure throws and keeps every character: the draft is only cleared by a landing, and
    /// only where it is still the text that was sent, `ComposerSheet.draftAfterLanding`'s rule.
    /// 401 and 403 are read as `post()` reads them.
    func answer(_ target: AnswerTarget) async throws {
        let item = target.item
        let host = item.source.host
        let text = ComposerSheet.trimmed(answerDraft(target))
        guard !text.isEmpty, text.count <= postLimit(of: host) else { return }
        // Asked of the row as it is now, not as the sheet opened on it: a post its source said
        // was gone while the answer was being written offers nothing to answer (#179).
        guard acts(on: held(item.id) ?? item).offers(.answer),
              let answered = note(ofRow: item.id),
              let door = mastodon.authorized(host: host, for: .write)
        else { throw MastodonWriteError.noSource }
        let reach = answerReach[item.id] ?? target.start
        do {
            let note = try await MastodonWrite(door: door, store: store)
                .post(text, visibility: reach, answering: answered)
            answerDrafts[item.id] = ComposerSheet.draftAfterLanding(
                current: answerDraft(target), sent: text
            )
            if answerDrafts[item.id]?.isEmpty == true {
                answerDrafts[item.id] = nil
                answerReach[item.id] = nil
            }
            conversations.landed(note, under: target.root.id, rootID: target.root.statusID)
            await adopt()
            await persist?()
        } catch {
            writeFailed(error, host: host)
            throw error
        }
    }

    func isAdded(_ domain: String) -> Bool {
        let host = domain.lowercased()
        return sources.contains { $0.host == host }
    }

    /// **Whether a directory fetch is on the wire.** `catalog == .loading` cannot answer this: the
    /// property *starts* at `.loading`, before anybody has asked for anything, which is exactly why
    /// the guards below test `.ready` and `.empty` and not it.
    ///
    /// It became load-bearing when the browser grew a second step. `browse()` could only be pressed
    /// once — it is refused while a sheet is up — but `chooseProtocol` can be reached again by
    /// Mastodon → Back → Mastodon, which is a gesture `backToProtocols` documents as costing
    /// nothing. Without this, a second press while the first fetch is still on the wire starts a
    /// *second* request to the same third party and decodes the whole directory twice, with
    /// whichever finishes last winning — and decision 5 counts requests to third parties.
    @ObservationIgnored private var fetchingCatalog = false

    func loadCatalog() async {
        guard work.allows(.directory) else {
            catalog = .off
            return
        }
        if case .ready = catalog { return }
        if case .empty = catalog { return }
        guard !fetchingCatalog else { return }
        fetchingCatalog = true
        defer { fetchingCatalog = false }
        catalog = .loading
        do {
            let servers = try await ServerDirectory(http: WatchedHTTP(http, for: .directory, in: work)).servers()
            // Switched off while it was asked: what came back is not shown (#226).
            guard work.allows(.directory) else {
                catalog = .off
                return
            }
            catalog = servers.isEmpty ? .empty : .ready(servers)
        }
        // **The one site in this file a raw `URLError(.cancelled)` still reaches.** Everything
        // else here calls Core, which now reports a cancelled transfer as `CancellationError`;
        // `ServerDirectory` has no error vocabulary of its own and hands the transport's failures
        // up exactly as they arrive. Written `catch is CancellationError` this never fired, and
        // the sheet told the reader the directory could not be reached — about a third party that
        // was answering perfectly well, and on the strength of them closing it.
        catch let error where Cancellation.happened(error) {
            return
        } catch {
            catalog = .failed
        }
    }

    /// A server was chosen in the browser — **decision 38, and it is the whole of what the
    /// browser does.**
    ///
    /// It closes the sheet, puts the hostname in the field, and runs the errand a typed host runs.
    /// **It looks immediately rather than waiting for a second press**, because choosing a server
    /// already is the intent a press would express — the reader has just read its description and
    /// its figures and pressed the row.
    ///
    /// **The dismissal is first, and that order is load-bearing — do not reorder these lines.**
    /// `.browsingServers` answers `admitsASecondLook` with no, and correctly: a look started
    /// *behind* this sheet would put a request on the wire under a stage the reader cannot see
    /// past, which is the seam decision 38 exists to delete. So the sheet has to come down before
    /// anything is looked up. Reversed, `look` refuses this press and the whole server list goes
    /// dead to the touch in silence — the shape risk 12 counts four times on this branch, which is
    /// why `choosingAServerBehavesLikeTyping` drives the press rather than the guard.
    ///
    /// Through `dismissStage` rather than by assignment, for the reason `browse` uses it: it bumps
    /// the errand token, which a press about to start a look wants bumped anyway.
    ///
    /// **`.field` is not a fiction about where the press was.** The reader's hostname is in the
    /// field, the preview opens beside it, its Cancel and Subscribe are the page's, and its
    /// sentence is drawn in the block. Every one of those is the typed-host answer because this
    /// *is* the typed-host path from here on; that identity is the ruling.
    func pick(_ server: CatalogServer) async {
        dismissStage()
        hostname = server.domain
        await add()
    }

    /// Add pressed. **Looks, and adds nothing** — the reader sees what the server says about
    /// itself and then decides, which is what `confirm` is for.
    ///
    /// **Guarded on the stage as well as on `checking`.** `checking` is false the whole time a
    /// preview is up, so the field and the Add button would otherwise be live again and a second
    /// look would overwrite a stage the reader is in the middle of reading.
    ///
    /// **`admitsASecondLook` and not `stage == nil`, because browsing is where a look is started
    /// from** — and so, now, is a preview the reader can still see the field beside. The stage
    /// answers for itself; see `JoinStage.admitsASecondLook`.
    ///
    /// **It takes no origin at all now, and that is decision 38 making a narrowing structural.**
    /// It used to take a `JoinEntrance` so that `.joined` could not be handed to the only other
    /// producer of `.previewing` — which would build a stage whose origin and whose preview name
    /// two different servers, with a stale `Source` inside it. With the browser no longer
    /// previewing anything, every join preview is the field's and the case is written here rather
    /// than passed in: `openSource(host:)` is the one function that can build a detail, and there
    /// is no parameter left to hand the wrong value to.
    func add() async {
        // The preview this look is about to replace, asked before the await. A reader who types a
        // second hostname over an inline preview has left the first server, and the picture it
        // pulled is otherwise held for the run under a host that appears in no inventory — the
        // same leak `dismissStage` exists to close, reached by a route that only opens once the
        // field is live behind a preview.
        let replaced = stage?.inlinePreview?.host
        guard let preview = await look() else { return }
        if let replaced, replaced != preview.host, !isAdded(replaced) {
            pictures.forget(host: replaced)
        }
        stage = .previewing(preview, from: .field, ticked: [])
    }

    /// The reader was turned away, went and signed in, and came back — **and does not see the
    /// preview again.**
    ///
    /// They have already read what this server says about itself, already pressed Subscribe, and
    /// already gone and done the one thing that could change the answer. Showing them the same
    /// screen a second time asks a question they have answered. So this looks and *takes*,
    /// landing them where the first press was heading.
    ///
    /// **The look is not skipped, only the stopping.** A signed-in reader's forum index is
    /// genuinely a different document from the signed-out one — it is the index that says which
    /// boards they may see — so the answer this carries forward has to be the one read through
    /// the engine they just signed in to, not the one they were refused with.
    ///
    /// **`from: .field`, because the refusal this resumes was reported under the field.** The
    /// sheet came down when the join was refused (`closeIfStillMine`), so the button the reader
    /// pressed to go and sign in was on the page, and the boards this lands them at have the page
    /// behind them.
    func resumeAfterSignIn() async {
        guard let preview = await look() else { return }
        // **`.page`, stated rather than derived.** The refusal this resumes was reported under the
        // field, and that is where the reader pressed. A block may well be open behind all this —
        // a preview of *another* server, typed before this one — and attributing the sentence to
        // it would draw "Checking B…" under A's Subscribe with nothing under the field at all.
        await take(preview, ticked: [], reportedBy: .page)
    }

    /// One look: the duplicate guard, the parse, the request, and every way it can go wrong said
    /// as a sentence. **Sets no stage** — what to do with the answer is the caller's, which is
    /// the whole of the difference between `add` and `resumeAfterSignIn`.
    ///
    /// **The stage guard is `admitsASecondLook` and it had to move with `AccountPane.busy`.**
    /// `stage?.host == nil` was the right question while every stage covered the field; an inline
    /// preview sits *beside* the field, so the field is live again and this guard left alone would
    /// make Return and the magnifier controls that do nothing — unit 5b's defect exactly, and
    /// risk 12's class.
    private func look() async -> SourcePreview? {
        guard Self.pageActsLive(at: stage, checking: checking) else { return nil }
        let raw = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        refuse = nil
        offerSignIn = nil
        unread = []
        unreadAll = 0
        let parsed: String
        do {
            parsed = try Host.parse(raw)
        } catch {
            refuse = String(format: L10n.t("account.refuse.unknown"), raw)
            return nil
        }
        progressHost = parsed
        if isAdded(parsed) {
            refuse = L10n.t("account.refuse.duplicate")
            return nil
        }
        // The person named it: what is asked of it before it is a source is theirs (#220).
        work.named(parsed)
        errand += 1
        let mine = errand
        // **The page owns a look, even beside an open block.** The reader typed into the field, so
        // that is where the sentence belongs — which is the one place `owner(drawing:)` would give
        // the wrong answer, and the reason this is stated rather than derived.
        progress = ProgressReport(owner: .page, key: "account.detect.progress")
        defer { progress = nil }
        do {
            let preview = try await joiner(for: parsed, for: .joining).look(host: raw)
            guard mine == errand else { return nil }
            profiles[preview.host] = preview.profile
            return preview
        }
        // `Cancellation.happened` and not `is CancellationError`, though after unit 1b Core does
        // report a leaving as `CancellationError` and the tidy spelling would work today. It
        // works only because of a guarantee three files away that `SourceJoin`'s signature does
        // not state — and a site that is correct for a reason nobody can read at it is how this
        // whole class of bug got to fourteen places. The predicate accepts both spellings.
        catch let error where Cancellation.happened(error) {
            // The errand went with the reader, so the host it was about goes too — left behind it
            // is the name of a server in a progress line nobody is waiting on.
            progressHost = ""
            return nil
        } catch let error as JoinError {
            report(error, raw: raw, host: parsed)
            return nil
        } catch {
            refuse = L10n.t("account.refuse.network")
            return nil
        }
    }

    /// Subscribe pressed in the preview. The reader looked and said yes.
    ///
    /// **A fresh `joiner`, never one carried in the preview.** An engine can come into existence
    /// between the look and the press — the reader was offered a sign-in on a refusal and took it
    /// — so the transport is chosen again here, against what this run holds now. `SourcePreview`
    /// states the same rule from the other side.
    ///
    /// **A detail is refused here, and it is refused structurally.** `PreviewOrigin` has a second
    /// case, and a press that matched any `.previewing` would try to join a source the reader
    /// already has — `look`'s duplicate guard reporting an errand nobody started, which is the
    /// incident `signInFinished` already records once. `reporter` is a total function with no
    /// `default:`, and `.joined` has no owner to hand over, so there is no guard to forget:
    /// `take` cannot be called. `JoinSheet.primary` reads the same `nil` and draws no button.
    ///
    /// **It is the reporter that carries the refusal, and that is not a coincidence.** What the
    /// entrance enum ever held was the answer to *which surface says this press is running*, and
    /// an origin with no Subscribe has no such surface — so asking for the one is asking for the
    /// other, and there is one value rather than two to keep in step.
    func confirm() async {
        guard !checking, case .previewing(let preview, let origin, let ticked) = stage,
              let owner = origin.reporter
        else { return }
        await take(preview, ticked: ticked, reportedBy: owner)
    }

    /// A source row was pressed: the reader wants that server's own account of itself —
    /// **decision 31**.
    ///
    /// **It costs no request, and that is the whole shape of it.** The answer is already in
    /// `profiles`, put there by the look they waited for when they added it, so this is `rows`'
    /// own derivation read once more rather than a second one. **Never through `look()`**, which
    /// refuses an added host by design and would answer a press with "You are already reading this
    /// server".
    ///
    /// **`rowActsLive` and not a predicate of its own**, which is `DESIGN-R2` §10.1: one rule now
    /// gates the boards control, all four controls and this press, and a fourth entrance with a
    /// second predicate is how risk 12's class is reached again. Opening a detail replaces
    /// `stage`, so a row pressed under an inline preview would delete a screen the reader is
    /// part-way through.
    ///
    /// **`boards: []` on the preview**, because `SourcePreview.boards` means *the forum's index*
    /// and nothing read one here. The boards the reader subscribed to travel in the origin
    /// instead, where they are what they say they are.
    func openSource(host raw: String) {
        let host = raw.lowercased()
        guard Self.rowActsLive(at: stage, checking: checking),
              let row = rows.first(where: { $0.id == host })
        else { return }
        errand += 1
        stage = .previewing(
            SourcePreview(host: row.source.host, kind: row.source.kind, profile: row.profile),
            from: .joined(row.source),
            ticked: []
        )
    }

    /// The press itself.
    ///
    /// **The preview is carried into the boards stage**, because a Discuz! answers a press with
    /// its board list and that list opens in the sheet while the preview stays drawn in the page
    /// (decision 21). Carrying it is what lets Back land on the preview the reader already has
    /// rather than asking the forum for its index again.
    ///
    /// **`reportedBy` is the caller's answer and never this function reading the screen** — risk
    /// 14's generalising fix. Two callers and two answers: a Subscribe pressed in the block says
    /// `.block`, and a join resumed after a sign-in says `.page`, because the refusal it resumes
    /// was reported under the field and a block open behind it belongs to another server.
    private func take(
        _ preview: SourcePreview,
        ticked: Set<Int>,
        reportedBy owner: ProgressOwner
    ) async {
        refuse = nil
        offerSignIn = nil
        unread = []
        unreadAll = 0
        progressHost = preview.host
        errand += 1
        let mine = errand
        // Where the press was — **the caller's answer, not this function reading the screen**.
        progress = ProgressReport(owner: owner, key: "account.detect.progress")
        defer { progress = nil }
        do {
            // **No `default:`.** A join step falling through a switch is a silent wrong answer:
            // a forum reported as joined, with no source and no boards behind it, and the
            // compiler saying nothing. Both cases are named, so a third breaks the build here.
            switch try await joiner(for: preview.host, for: .joining).begin(preview) {
            case .joined:
                // **`adopt` is not behind the token and the stage write is.** The store has
                // already been written by the time this line runs, so a reader who dismissed the
                // sheet mid-press has still joined this server — skipping `adopt` would leave it
                // added and invisible, with the list disagreeing with the store until something
                // else happened to refresh it. What the token protects is only the sheet.
                closeIfStillMine(mine)
                await adopt()
            case .chooseBoards(let offer):
                // D28's pause, and the third stage. **Nothing has been added**, so a reader who
                // left takes the whole errand with them — which is why this one *is* entirely
                // behind the token: writing it would spring the sheet back open behind them.
                guard mine == errand else { return }
                stage = .choosingBoards(offer, from: .preview(preview, ticked: ticked))
            }
        }
        // **The one branch that does not touch the sheet, and the asymmetry is deliberate.** The
        // other two end the errand with something to say, so the sheet has to come down for the
        // sentence under the field to be reachable. A cancellation has nothing to say — the
        // reader either dismissed the sheet themselves, in which case it is already down and
        // `errand` has moved, or the app is going away. Closing it here would be this function
        // taking a decision on behalf of a reader who has already taken it.
        catch let error where Cancellation.happened(error) {
            progressHost = ""
            return
        } catch let error as JoinError {
            // Said whatever they did with the sheet: they pressed Subscribe and it was refused,
            // and the sentence — with the sign-in it may offer — belongs under the field.
            closeIfStillMine(mine)
            report(error, raw: preview.host, host: preview.host)
        } catch {
            closeIfStillMine(mine)
            refuse = L10n.t("account.refuse.network")
        }
    }

    /// Takes the sheet down, but only if it is still showing the errand that just finished.
    ///
    /// A reader who dismissed and moved on has a stage of their own by now, and closing *that* is
    /// the same fault as reopening one they left — a sheet changing under somebody either way.
    private func closeIfStillMine(_ mine: Int) {
        guard mine == errand else { return }
        stage = nil
    }

    /// Browse pressed. **It opens the protocols this app can read, and contacts nobody** —
    /// decisions 19 and 38.
    ///
    /// **The catalog moved one press later than decision 10 put it.** That decision took the fetch
    /// off the page appearing so that "a reader who never browses contacts nobody"; the browser's
    /// first step names no directory, so a reader who browses and picks a forum still contacts
    /// nobody. `chooseProtocol` is where the third party is reached, and only for a protocol that
    /// has one.
    ///
    /// **Relaxed the same way `look` was, and for the same reason.** `stage == nil` was right
    /// while every stage covered the page; Browse sits beside the field, and an inline preview
    /// covers neither. A Browse refused under a button the reader can see and press is the dead
    /// control this branch has now shipped four times.
    ///
    /// **Through `dismissStage` and not by assignment**, so a preview being replaced still forgets
    /// the picture it pulled for a host nobody joined. Harmless where there is no stage: it bumps
    /// the errand token, which a press about to open the browser wants bumped anyway.
    func browse() {
        guard Self.pageActsLive(at: stage, checking: checking) else { return }
        dismissStage()
        refuse = nil
        stage = .browsing
    }

    /// A protocol was chosen in the browser — step two, and the only place a directory is asked
    /// for.
    ///
    /// **The fetch is here rather than at `browse`**, which is decision 10's argument carried one
    /// step further: the reader who opens the browser to see what this app reads, and closes it
    /// again, has had no third party told about them.
    ///
    /// **A protocol with no directory still opens, and that is deliberate.** It is a real state and
    /// until M3 it is the majority one, so pressing Discourse says so in a sentence rather than
    /// refusing the press — a row that does nothing is the dead control this branch has shipped
    /// four times, and "no list yet" is a fact the reader is owed. `ServerDirectory.covers(_:)` is
    /// the one rule both the fetch and the sentence read — **in Core, beside the only directory
    /// there is**, so the rule lives in the module that would change if its coverage ever did.
    ///
    /// **Answered by a `switch` and not by a bare `guard case`**, which is the rule
    /// `backToProtocols` and `backToPreview` both state twenty lines below and which this press was
    /// written in breach of. A `guard case .browsing = stage else { return }` compiles clean
    /// against a fifth stage and silently inherits step one's answer — a `default:` wearing a
    /// different hat, and this repo bans those with three incidents behind it.
    ///
    /// **There is no `!checking` term, and its absence is the same ruling `catalogRow` and
    /// `interactiveDismissDisabled` got.** Nothing is ever on the wire while this sheet is up, so
    /// such a term could not fire; a guard that cannot fire is a reader of this file inferring a
    /// state the app does not have, and the file would then both assert the invariant and hedge
    /// against it in one press. See `reporting(_:drawnAs:)` for where the invariant lives.
    func chooseProtocol(_ kind: ProtocolKind) {
        switch stage {
        case .browsing:
            errand += 1
            stage = .browsingServers(kind)
            // **`ServerDirectory.covers(_:)` owns this and not a predicate in a view** — the one
            // directory there is, is that type, so the fetch and the sentence read one rule from
            // the module that would change if its coverage ever did. A protocol it does not cover
            // reaches nobody, and the second step says so in a whole sentence.
            guard ServerDirectory.covers(kind) else { return }
            askDirectory()
        // None of these offers a protocol to press: the server list is a step further in, a
        // preview and a board list are about one server, and a detail is about one the reader has.
        case .browsingServers, .previewing, .choosingBoards, .choosingLists, nil:
            return
        }
    }

    /// The one place the directory is asked for: the browse step, a protocol it covers chosen.
    private func askDirectory() {
        Task { await loadCatalog() }
    }

    /// The person's list changed (#226). While the servers are listed, the directory's entry is
    /// read again at once: switched off, the list says so and nothing more is asked; switched on,
    /// it is asked.
    private func allowancesChanged(by from: ObjectIdentifier?) {
        guard from == ObjectIdentifier(work) else { return }
        switch stage {
        case .browsingServers(let kind):
            guard ServerDirectory.covers(kind) else { return }
            askDirectory()
        case .browsing, .previewing, .choosingBoards, .choosingLists, nil:
            return
        }
    }

    /// The sheet went away by a route that is not a button — a swipe, Escape, the scene going.
    ///
    /// **On a boards stage that stands on a preview, that is Back and not Cancel**, because the
    /// preview it stands on is still on screen behind it: in the page where the reader typed the
    /// host, and in this sheet's own history where they picked it off the directory. A dismissal
    /// that cancelled the errand would delete a screen the reader can see, and take the inline
    /// block down with it.
    ///
    /// **No `default:`.** A restate has no preview behind it, so a swipe there *is* a cancel and
    /// has to say so at the place that decides rather than inherit a join's answer.
    func sheetDismissed() {
        // **The sheet also goes away when the stage stops being a sheet, and that is not this.**
        // On the inline route Back flips the surface to `.pane` while the sheet is up, so SwiftUI
        // takes the sheet down and may re-enter the presentation binding's setter — arriving here
        // with the stage already at `.previewing(_, .field)`, which would be read as a dismissal
        // and answered with `dismissStage()`, deleting the preview the reader just stepped back
        // onto and the ticks with it. This method exists to answer *the reader dismissed the
        // sheet*; when the stage is already pane-surfaced the sheet went because the stage moved,
        // and there is nothing to answer. **Not a redundant check — do not remove it.**
        guard stage?.surface != .pane else { return }
        switch stage {
        case .choosingBoards(_, .preview): backToPreview()
        case .choosingBoards(_, .joined), .choosingLists, .browsing, .browsingServers, .previewing,
            nil:
            // **A swipe on the server list is a cancel and not a step back to the protocols.** The
            // reader dismissed the browser, not a step of it; landing them on the protocol list
            // would keep a sheet up that they asked to be rid of. Back is the button for that, and
            // it is the button the footer offers.
            dismissStage()
        }
    }

    /// The sheet closed, by whatever route — a button, a swipe, Escape.
    ///
    /// **Nothing was added at any stage, so there is nothing to undo**, and what the reader typed
    /// stays in the field so pressing Add again gets them back to where they were. What the bump
    /// buys is the other half: a press whose answer is still on the wire has just been abandoned,
    /// and its `.chooseBoards` must not spring this sheet back open behind them.
    ///
    /// **A preview backed out of forgets the picture it pulled.** `ShellPictures` tags an entry
    /// by host, and `UsagePane` lists the hosts in `sources` — so a thumbnail fetched for a
    /// server the reader looked at and did not take would be held for the run and appear in no
    /// inventory. Only where it is not a source: a host they did join keeps its pictures.
    func dismissStage() {
        let looked = stage?.host
        errand += 1
        stage = nil
        guard let looked, !isAdded(looked) else { return }
        pictures.forget(host: looked)
    }

    /// The reader picked, and pressed Subscribe. The second half of D28's conversation.
    ///
    /// **An empty pick is not a failure.** A reader who opened the picker and closed it has not
    /// failed at anything, so nothing is said and nothing is added — which is also exactly what
    /// `DiscuzBoardJoin.subscribe` does with an empty list. It is answered here rather than sent
    /// to the wire because a spinner over a request that cannot do anything is a worse account of
    /// the same nothing.
    func subscribe(_ picks: [DiscuzBoard]) async {
        guard case .choosingBoards(let offer, let origin) = stage, !checking else { return }
        // Taken down once this call is certain to handle it, so the sheet is gone while the
        // boards are read one at a time and a second press cannot start a second pick against
        // the same offer — and so a call that declines to act does not close the sheet on a
        // reader whose pick then went nowhere.
        errand += 1
        let mine = errand
        stage = nil
        // **Only an untick removes a subscription** (#161, D26 revised). A board the reader
        // reads and left ticked is kept even where the list the press walked did not carry it:
        // absence from a list is not the reader's decision, and it is not evidence either. A
        // board the list does carry is the reader's to untick, and `picks` says what they did.
        let listed = Set(offer.boards.map(\.fid)).union(picks.map(\.fid))
        let picks = picks + origin.keeping
            .filter { origin.ticked.contains($0.fid) && !listed.contains($0.fid) }
            .map { DiscuzBoard(fid: $0.fid, name: $0.name, category: "", gid: JoinOffer.keptSection) }
        guard !picks.isEmpty else { return }
        refuse = nil
        offerSignIn = nil
        rowRefusal = nil
        unread = []
        unreadAll = 0
        progressHost = offer.host
        // A restate was pressed inside a row, so the row reports it — this is the second half of
        // the same errand `changeBoards` began, and it must not change surfaces half way through.
        //
        // **And both entrances say the same thing, which is the correction.** This phase reads one
        // page per picked board, sequentially; it is the longest wait in the app and it detects
        // nothing. The restate's half was routed into the row by unit C and the join's half was
        // still drawing "Checking %@…" under the field, which is the detection vocabulary over a
        // phase that does not detect. One key, both owners.
        // **Computed once and handed on.** `failed(_:offer:picked:)` used to re-derive this by
        // reading `progress?.owner` back — the screen, four lines after its caller had already
        // decided the answer, and out of a property the `defer` below is about to nil. `take`
        // carries the ruling this now follows: the reporter is the caller's answer and never a
        // function reading the screen.
        //
        // **Folded here.** `changeBoards` folds what it is handed and this did not, staying
        // correct only because `DiscuzBoardJoin` builds its offer from `source.host` — a
        // guarantee three files away that nothing at this site stated. An unfolded host here
        // matches no row, and the app's longest phase draws no line at all.
        let reporter: ProgressOwner = origin.isRestate
            ? .row(host: offer.host.lowercased())
            : .page
        progress = ProgressReport(owner: reporter, key: "account.join.boards.progress")
        defer { progress = nil }
        do {
            // **`keeping` is what this host is subscribed to now, and it is correctness before it
            // is traffic.** A restate re-reading the eight boards the reader already had would
            // spend eight sequential page fetches to confirm what it already knows — and any one
            // of them timing out would drop that board out of `subscribed`, unsubscribing the
            // reader from something they never touched. A join has nothing to keep and says `[]`
            // rather than defaulting to it; see `BoardsOrigin.keeping`.
            let outcome = try await joiner(for: offer.host, for: .boards)
                .subscribe(offer, to: picks, keeping: origin.keeping)
            // **The reader removed this server while its boards were being read, so it must not
            // come back.** One request per board means this runs for seconds, which is ample time
            // to press Remove on a row — and Core writes `add`, `subscribe` and `ingest` at the
            // end of that call, after the removal, putting the source and every board pick back.
            //
            // **"Which side of the token is this write on" has a third answer here, and that is
            // the whole of why this branch exists.** In `take`, the two writes divide cleanly: the
            // stage write is refused on a stale token, and `adopt()` is not, because the store is
            // already written by then and skipping it would leave a source added and invisible.
            // Here the resurrecting write is not one of *this* function's writes at all — Core
            // performs it inside the call above — so by the time the token can be read the store
            // has **already** been put back. Guarding `adopt()` would therefore only hide the
            // resurrection rather than prevent it: the list would agree with the reader and the
            // store would not, until the next join refreshed it and the server reappeared.
            //
            // So the stale branch takes the write back instead of declining to read it.
            // `store.remove` undoes exactly what `subscribe` wrote — the source, its boards and its
            // threads — and `adopt()` then runs unconditionally, so the list and the store agree
            // whichever way the token went.
            if mine == errand {
                unread = outcome.unread
            } else {
                await store.remove(host: offer.host)
            }
            await adopt()
            // Where a board that failed was the only thing the reader was after, the rail is
            // still worth landing them on the one that worked — `adopt` does that — but the
            // sentence about the rest is `unread`, and it is read on Account.
        } catch let error where Cancellation.happened(error) {
            progressHost = ""
            return
        } catch let error as JoinError {
            // Every board failed, so nothing was added. Core threw the first board's reason and
            // kept no list; the count is what lets the sentence say how much it is about.
            failed(error, offer: offer, picked: picks.count, reportedBy: reporter)
        } catch {
            failed(nil, offer: offer, picked: picks.count, reportedBy: reporter)
        }
    }

    /// Every board the reader picked failed. Which surface is told, and in what colour.
    ///
    /// **The same rule `rowRefusal` was built for, applied to the other half of the errand.** A
    /// join that fails has not added a host, so its sentence belongs under the field, in `alarm`,
    /// beside the offer of a sign-in that might fix it. A **restate** that fails is about a host
    /// the reader added weeks ago and is still reading: nothing was undone, nothing is missing
    /// from their list, and drawing an alarm-coloured line under a field they never touched —
    /// possibly a screen away from the row they pressed — says something untrue in a colour this
    /// app spends on one thing.
    ///
    /// So a restate answers where it was pressed, in `inkDim`, exactly as its index failure does.
    /// No `offerSignIn` either: that offer exists to give a refused *join* somewhere to go, and a
    /// joined forum's row already carries its own Sign in control (decision 13).
    ///
    /// **`reportedBy` is the caller's answer and never this function reading the screen.** It read
    /// `progress?.owner` — re-deriving, four lines after `subscribe` had computed the identical
    /// answer from `origin.isRestate` and stored it, and out of a property `subscribe`'s own
    /// `defer` is about to nil. `take(_:ticked:reportedBy:)` states the rule; this is the site
    /// that was still breaking it, and a second caller is exactly where re-derivation goes wrong.
    private func failed(
        _ error: JoinError?, offer: JoinOffer, picked: Int, reportedBy owner: ProgressOwner
    ) {
        // **A `switch` and not `if case .row`, which is the rule `backToBrowsing` was sent back
        // for, applied to the one site left holding the old shape — and it is in the type this
        // unit introduced.** `if case` compiles clean against a fourth owner and silently gives
        // it the page's alarm-coloured sentence under a field the reader never touched. It is
        // unreachable today only because `subscribe` sets two of the four; "unreachable today"
        // is exactly the argument that did not save the other site.
        switch owner {
        case .row:
            rowRefusal = (host: offer.host, key: "account.source.boards.unread")
            return
        // A join, pressed at the field or in the block, and reported under the field either way.
        case .page, .block:
            break
        }
        unreadAll = picked
        guard let error else {
            refuse = L10n.t("account.refuse.network")
            return
        }
        report(error, raw: offer.host, host: offer.host)
    }

    /// What is on the wire: **who reports it, and what it says while it runs** — or nothing.
    ///
    /// **One value and not two properties.** The surface and the sentence are written together at
    /// four call sites and read together at three, and two properties is two things to forget at
    /// each of them. It replaces `rowErrand: String?`, which could express two owners and now has
    /// to express three (`DESIGN-R2` §10.2): without a third, the inline block's own Subscribe
    /// draws a bare spinner while the page draws a sentence about the same errand 300pt away.
    ///
    /// Written at the top of every errand and cleared with `checking`, so no sentence outlives the
    /// press it is about.
    private(set) var progress: ProgressReport?

    /// Which surface **draws** a report — which is not always the one that claimed it.
    ///
    /// **Ownership and visibility are two questions, and answering only the first is risk 14's
    /// fourth shape.** `ProgressOwner` says whose press it was, and that is a function of the
    /// entrance, correctly. It says nothing about whether that surface is *on screen*, and a
    /// sentence drawn on a surface nobody can see is the same silence as no sentence at all.
    ///
    /// **One way the claimed surface goes away, and it is the block.** Its Cancel stays live while
    /// its Subscribe is on the wire — deliberately, a reader may leave — and leaving runs
    /// `dismissStage()`. The page takes it back.
    ///
    /// **The other way is gone, and it is worth saying what went with it.** A sheet covers the
    /// page, so an errand claimed by the page while a sheet stood over it drew its sentence behind
    /// that sheet: the reader waiting on a request, every visible control refused, and nothing
    /// anywhere saying why. That was reachable by exactly one route — browse, open a server, press
    /// Subscribe — because a browsed preview's press reported `.page` while its own stage was
    /// surfaced `.sheet`. Decision 38 deletes the route rather than rescuing it: the browser
    /// presses nothing, so **no errand can be on the wire while a sheet-surfaced stage is up.**
    ///
    /// **Where that invariant is enforced, because it is not enforced here.** Every entrance that
    /// can put a sheet-surfaced stage up, and what holds it. A sixth has to join them or this
    /// rescue is owed again — `JoinStageTests.noErrandRunsBehindTheSheet` walks all four stages
    /// they produce:
    ///
    /// - `pick(_:)` takes the browser down *before* it looks, so no look runs under it.
    /// - `subscribe(_:)` nils the stage before the boards go on the wire.
    /// - `changeBoards(host:)` runs with no stage at all (`rowActsLive`), and writes one only
    ///   after its read has returned.
    /// - `openSource(host:)` opens the detail, and is held by the same `rowActsLive` — whose
    ///   `!checking` is the term doing the work here.
    /// - `chooseProtocol(_:)` opens `.browsingServers`, and **has no `!checking` of its own.** It
    ///   rests on `browse()`'s, one press earlier: nothing can be on the wire when the browser
    ///   goes up, and nothing this sheet draws starts anything. **That is the one place a
    ///   reachable change breaks this** — relax `browse()`'s `!checking` and a sheet can rise over
    ///   a page-owned errand, restoring the seam decision 38 deleted. Somebody about to relax it
    ///   is reading this line.
    ///
    /// `.previewing(_, .field, _)` is the one stage held across an await, and it is drawn in the
    /// page, so the block below is what answers for it.
    ///
    /// **No `default:`.**
    static func reporting(
        _ progress: ProgressReport?, drawnAs stage: JoinStage?
    ) -> ProgressOwner? {
        guard let progress else { return nil }
        switch progress.owner {
        case .page, .row: return progress.owner
        case .block: return stage?.inlinePreview == nil ? .page : .block
        }
    }

    /// Whether a row's controls are live, as one rule both the drawing and every press read.
    ///
    /// **One function, because the alternative is the defect risk 12 counts.** A control that is
    /// drawn live and refused by a guard somewhere else is a button that does nothing, and this
    /// branch has now shipped four of those. `SourceRowView` dims all four on this and
    /// `changeBoards(host:)` refuses on this, so they cannot come to disagree.
    ///
    /// **`rowActsLive` and not `boardsLive`, which is a rename and not a widening of the rule.**
    /// Decision 30 makes the boards a fourth trailing control beside Sign in, Clear and Remove,
    /// and the answer to *may this row be acted on right now* was never particular to the boards.
    /// A name for one control standing over four is how a later reader concludes the other three
    /// were decided somewhere else.
    ///
    /// **Stricter than `AccountPane.busy`, on purpose.** `busy` lets a control stay live beside an
    /// inline preview, which is right for the field — the block sits *beside* it. It is not right
    /// here: a boards press replaces the stage outright, so pressing it under a preview the reader
    /// is part-way through would delete a screen they are reading.
    /// **Two invariants elsewhere are enforced *here* and nowhere else, so they are named here.**
    /// This is the shape just corrected in `subscribe` — a site relying on a guarantee three files
    /// away that nothing at the enforcement point stated. Somebody relaxing this reads this doc,
    /// and both of these break in silence:
    ///
    /// - **`PreviewOrigin.joined` carries a `Source` and is safe from going stale because of this
    ///   term.** `removing` refuses to hold a copy for exactly that reason; the detail may hold
    ///   one because no row control can change a source's boards while a stage is up, and
    ///   `stage == nil` is the whole of why.
    /// - **A row is always visible while its own errand runs**, which is what lets
    ///   `reporting(_:drawnAs:)` hand `.row` straight back. `changeBoards` and `subscribe` both
    ///   run with no stage, so no sheet can be covering the row that is speaking.
    static func rowActsLive(at stage: JoinStage?, checking: Bool) -> Bool {
        stage == nil && !checking
    }

    /// Whether the **page's** three add controls may be acted on: the hostname field, the
    /// magnifier and Browse.
    ///
    /// **`rowActsLive`'s twin, and it exists for the same reason.** The row's four controls were
    /// drawn on one question and pressed on another until `RowActionState` made the pair
    /// unspellable. The page's three had the same split and kept it: `AccountPane.busy` asked
    /// `stage?.surface == .sheet` while `look()` and `browse()` asked
    /// `stage?.admitsASecondLook`. Two exhaustive switches over the same five shapes, agreeing
    /// **by coincidence** — `surface == .pane` and `admitsASecondLook` happen to answer alike for
    /// every case that exists today, and nothing anywhere says they must.
    ///
    /// **What that coincidence costs when it breaks.** A stage whose two answers part company
    /// ships either a live-looking field whose Return does nothing, or a grey field that would
    /// have worked. That is risk 12's class — a control correct where it is tested and wrong
    /// where it is pressed — and M2 adds `JoinStage` cases, so the coincidence is due to break
    /// rather than merely able to.
    ///
    /// **`admitsASecondLook` and not `surface`**, because the question is whether a second look
    /// may start, not where the reader is looking. Those are the same thing only while the
    /// browser is the only stage that admits one.
    static func pageActsLive(at stage: JoinStage?, checking: Bool) -> Bool {
        !checking && (stage?.admitsASecondLook ?? true)
    }

    /// Whether a scene phase means **the reader has left this window**.
    ///
    /// **The two platforms do not mean the same thing by `.inactive`, and reading it as one rule
    /// is the defect.** On a Mac it fires whenever the window stops being the key one, which is
    /// exactly the "unfocus" a selector should close on — this file already records that fact
    /// elsewhere, about the cache wake. On iOS the same value fires for things the reader has not
    /// left for at all: Notification Centre pulled down, a call banner, the app switcher
    /// previewed and dismissed. A board picker that threw the reader's ticks away because a
    /// banner appeared would be a defect wearing this feature's clothes, so there it is
    /// `.background` and nothing less.
    ///
    /// **Here rather than in the view**, on the same grounds as `pageActsLive`: it decides
    /// whether a reader's work is discarded, and a rule inside a `View` body is reachable from
    /// nothing.
    static func windowLeft(_ phase: ScenePhase) -> Bool {
        #if os(macOS)
        phase != .active
        #else
        phase == .background
        #endif
    }

    /// A row's own press did not finish — the forum's index could not be read for its boards
    /// control, or a Mastodon's sign-in failed — and the sentence that says so.
    ///
    /// **Drawn by the row whose host matches, and by nothing else.** The refusal sentence every
    /// other errand on this page writes is `refuse`, which `AccountPane` draws under the field —
    /// and a reader who pressed a control in row four of six is 900pt away from it. A refusal
    /// nobody can see is not a refusal.
    ///
    /// **Not `alarm`, and the row says why**: that colour is spent on the line that says a host
    /// was *not added* and why, and this host was added weeks ago. Nothing changed here.
    var rowRefusal: (host: String, key: String)?

    /// The reader wants a different set of boards on a forum they already read.
    ///
    /// **A restate and not a join.** The source stays, its notes stay — decision 22, and
    /// unsubscribing changes only what this device fetches *next* — and what the picker hands back
    /// replaces the set outright, which is why it opens **pre-ticked**.
    ///
    /// **Nothing is detected.** `SourceJoin.boards(of:)` takes the `Source` this session already
    /// holds, so the kind travels in the value and a forum the reader already reads is not asked
    /// what it is a second time. It is also the only route in that is not wrong: `look` refuses a
    /// host that is added, `begin(host:)` detects, and `begin(_:)` would need a `SourcePreview`
    /// that does not exist for a source nobody previewed.
    ///
    /// **The picker opens ticked from everything that is subscribed, and lists all of it.**
    /// Decision 25: an empty picker plus one new tick is a silent unsubscribe from the other
    /// eight. Decision 26 used to add that a board the front page no longer lists could not be
    /// ticked, so a press dropped it — and #161 showed absence from one page is not evidence a
    /// board is gone: a sub-board the front page never names was dropped the same way, from a
    /// reader who never touched it. So D26 is revised: **only an untick removes a subscription.**
    /// A subscribed board the list does not place is listed anyway, under the name it was
    /// subscribed by (`JoinOffer.keeping`); one the forum really deleted is there to untick, and
    /// its reads say it cannot be read, which is the positive evidence the old rule never had.
    ///
    /// **And each board the reader already reads has its own page read, now** (#161) — the
    /// boards they chose, not the forum's forty — so a sub-board they picked is filed under its
    /// parent and a parent they picked shows its sub-boards before any refresh has read them.
    /// While a read is on the wire, or where it fails, the board stays listed where it was.
    ///
    /// Behind the same errand token every other press here is, so a reader who removes this source
    /// while its index is on the wire does not get a sheet back over a row that has gone.
    func changeBoards(host raw: String) async {
        let host = raw.lowercased()
        guard Self.rowActsLive(at: stage, checking: checking),
              let source = sources.first(where: { $0.host == host }),
              // **The same predicate the control is drawn on**, asked again where the press lands.
              // `rowActsLive` answers *when* and this answers *which protocol*, and a press that
              // asked only the first would reach `SourceJoin.boards(of:)`, be refused
              // `unsupportedKind`, and tell the reader "boards could not be read just now" — a
              // sentence about a wire, for a protocol that has no picker. Unreachable from a row
              // that draws no control; stated here because "one rule, both ends" is the claim
              // this whole entrance is built on.
              SourceRow.canChangeBoards(source.kind)
        else { return }
        rowRefusal = nil
        refuse = nil
        unread = []
        unreadAll = 0
        progressHost = host
        errand += 1
        let mine = errand
        // This row's press, so this row reports it — the page's line stays down. Cleared with
        // `checking`, because the two are the same errand seen from two surfaces.
        //
        // `account.source.boards.progress` and not the key above: what this phase reads is the
        // forum's **index**, which is what that sentence has always meant.
        progress = ProgressReport(
            owner: .row(host: host), key: "account.source.boards.progress"
        )
        defer { progress = nil }
        do {
            // The front page, and the sub-boards this run has already read off pages it was
            // reading anyway (#161) — so a sub-board the front page never names, and the reader
            // already has, is on the list to stay ticked rather than dropped by the next press.
            let index = try await joiner(for: host, for: .boards).boards(of: source)
            guard mine == errand else { return }
            restating = (host: host, index: index, subscribed: source.boards)
            stage = .choosingBoards(restateOffer(host: host) ?? index, from: .joined(
                subscribed: source.boards,
                ticked: Set(source.boards.map(\.fid))
            ))
            let chosen = source.boards.filter {
                lookedUnder[host, default: []].insert($0.fid).inserted
            }
            if !chosen.isEmpty {
                looking = Task { await self.readAround(chosen, host: host, offer: index) }
            }
        } catch let error where Cancellation.happened(error) {
            progressHost = ""
        } catch {
            // One sentence, in the row the reader pressed. Which failure it was does not change
            // what they can do about it — press again — so it does not change what they are told.
            guard mine == errand else { return }
            rowRefusal = (host: host, key: "account.source.boards.unread")
        }
    }

    /// What this run has read about each forum's sub-boards, by host — #161, D29's page half.
    ///
    /// Filled by the pages this device reads anyway — each subscribed board's, on a reload — and
    /// by the one page a tick in the picker reads. Held for the run and dropped by Clear, like
    /// every other copy of a server's word here; the next reload says it again.
    @ObservationIgnored var subBoards: [String: DiscuzSubBoards] = [:]

    /// The boards whose own page has been read for sub-boards this run, by host, so a board
    /// ticked, unticked and ticked again is one request and not three. A read that failed is
    /// taken off, so ticking it again asks again.
    @ObservationIgnored private var lookedUnder: [String: Set<Int>] = [:]

    /// The last read `tick(_:)` started, for a test to wait on. Nothing else reads it.
    @ObservationIgnored private(set) var looking: Task<Void, Never>?

    /// The restate in hand: its front page and what the reader reads, so the list can be drawn
    /// again as each board's own page arrives. Set by `changeBoards`; read only while the
    /// picker is a restate of this host.
    @ObservationIgnored private var restating:
        (host: String, index: JoinOffer, subscribed: [BoardSubscription])?

    /// A restate's list: the front page, what this run has read about sub-boards, and every
    /// subscribed board the two still do not place — see `changeBoards`.
    private func restateOffer(host: String) -> JoinOffer? {
        guard let restating, restating.host == host else { return nil }
        let placed = subBoards[host]?.applied(to: restating.index) ?? restating.index
        return placed.keeping(restating.subscribed, section: L10n.t("board.choose.kept"))
    }

    /// The pages of the boards a reader already reads, one after another, each redrawing the
    /// list it grows — as `DiscuzBoardJoin.subscribe` reads a pick: never in parallel.
    ///
    /// Stops when the reader has left this picker. A page that fails leaves its board where it
    /// is listed and is taken off `lookedUnder`, so a tick asks again.
    private func readAround(_ boards: [BoardSubscription], host: String, offer: JoinOffer) async {
        for board in boards {
            guard case .choosingBoards(let current, .joined) = stage,
                  current.host.lowercased() == host
            else { return }
            do {
                let page = try await joiner(for: host, for: .boards, name: .called(board.name))
                    .around(board.fid, in: offer)
                subBoards[host, default: DiscuzSubBoards()].learn(page, of: board)
            } catch {
                lookedUnder[host]?.remove(board.fid)
                continue
            }
            guard case .choosingBoards(let now, let origin) = stage,
                  now.host.lowercased() == host, origin.isRestate,
                  let redrawn = restateOffer(host: host)
            else { return }
            stage = .choosingBoards(redrawn, from: origin)
        }
    }

    /// The reader's hand on the picker — **the one door a tick comes through**.
    ///
    /// Writes the ticks into the stage, exactly as before (decision 27). And where a board has
    /// just been ticked — not unticked, and not a board under a board — its own page is read
    /// for the boards it writes under it (#161): some forums name a sub-board nowhere else. That
    /// is **the one moment a board's page is read in the picker**: the reader has just said they
    /// want this board, and it is one page for one board. Reading every board's page when the
    /// picker opens would be forty requests nobody asked for, which is what the issue forbids.
    ///
    /// The tick itself picks nothing more than the board ticked. What the read finds is drawn
    /// under it, unticked: a parent's page does not carry its children's threads, so a parent
    /// that quietly picked them would be a lie about what the reader subscribed to.
    func tick(_ picked: Set<Int>) {
        let before = stage?.ticked ?? []
        stage = stage?.ticking(picked)
        guard case .choosingBoards(let offer, _) = stage else { return }
        let host = offer.host.lowercased()
        for fid in picked.subtracting(before).sorted() {
            guard let board = offer.boards.first(where: { $0.fid == fid }),
                  board.parent == nil,
                  lookedUnder[host, default: []].insert(fid).inserted
            else { continue }
            looking = Task { await self.look(under: board, in: offer) }
        }
    }

    /// One board's own page, read for what it writes under it, and drawn there if the reader
    /// is still choosing on this forum.
    ///
    /// **Quiet when it fails.** The board the reader ticked is still ticked and still readable;
    /// what did not arrive is a list of boards they had not seen, and a refusal sentence over a
    /// picker they are still using would be about something they never asked for. Ticking it
    /// again asks again.
    func look(under board: DiscuzBoard, in offer: JoinOffer) async {
        let host = offer.host.lowercased()
        let found: [DiscuzBoard]
        do {
            found = try await joiner(for: offer.host, for: .boards, name: .called(board.name))
                .subBoards(of: board, in: offer)
        } catch {
            lookedUnder[host]?.remove(board.fid)
            return
        }
        guard !found.isEmpty else { return }
        subBoards[host, default: DiscuzSubBoards()].learn(
            DiscuzBoardPage(notes: [], subBoards: found, parent: nil),
            of: BoardSubscription(board)
        )
        // Drawn into whatever the picker holds **now**, which another tick's read may already
        // have grown — never into the offer this read started from.
        guard case .choosingBoards(let current, let origin) = stage,
              current.host.lowercased() == host
        else { return }
        // A restate's list is drawn from what it was built from, so a board the reader reads
        // and the boards found under it stay in one arrangement; a join's grows in place.
        let grown = (origin.isRestate ? restateOffer(host: host) : nil)
            ?? current.adding(found, under: board.fid)
        stage = .choosingBoards(grown, from: origin)
    }

    /// One subscribed board's page, read on a reload, and what it said about the boards
    /// around it kept for the picker — see `subBoards`.
    func learn(_ page: DiscuzBoardPage, of board: BoardSubscription, host: String) {
        guard !page.subBoards.isEmpty || page.parent != nil else { return }
        subBoards[host.lowercased(), default: DiscuzSubBoards()].learn(page, of: board)
    }

    /// The reader stepped back from one protocol's servers to the list of protocols.
    ///
    /// **This replaces `backToBrowsing`, and it is a different press rather than a rename.** That
    /// one stepped back from a *preview* into the server list, because a preview could be reached
    /// by pressing a row there. Decision 38 ends that: choosing a server closes the sheet, so no
    /// preview has a browser behind it and there is nothing for such a press to return to. This
    /// one lives entirely inside the browser, between its two steps — a stage the old press could
    /// never have been offered at.
    ///
    /// **Not `browse()`, and the difference is which press it is.** `browse` is the page's button
    /// and is refused while a sheet is up, because a reader inside the browser did not ask for it
    /// to be replaced. This is the sheet's own Back, where being at step two is the *premise*.
    ///
    /// **The stage is answered by a `switch` and not by a bare `guard case`** — the rule
    /// `backToPreview` states in as many words. A `guard case .browsingServers = stage else
    /// { return }` compiles clean against a fifth stage and quietly answers on its behalf, which
    /// is a `default:` wearing a different hat, and this repo bans those with three incidents
    /// behind it. The arms that do nothing are the ones carrying the decision.
    ///
    /// **The catalog is not refetched.** `loadCatalog` returns at once for a directory already
    /// `.ready`, so a reader stepping back and forward between the two steps asks joinmastodon
    /// once.
    func backToProtocols() {
        switch stage {
        case .browsingServers:
            errand += 1
            stage = .browsing
        // None of these is a step of the browser: a preview has the page behind it, a detail has
        // nothing, a board list has its preview, and step one has nothing before it.
        // `JoinSheet.leading(for:)` offers this button to none of them, so this is unreachable
        // from the sheet — and it declines by deciding rather than by falling through somebody
        // else's answer.
        case .browsing, .previewing, .choosingBoards, .choosingLists, nil:
            return
        }
    }

    /// The reader stepped back from the boards to the preview they arrived through.
    ///
    /// **No second request, which is the whole gain of one sheet over three.** The preview
    /// travelled in the stage precisely so that this is a value being read and not a forum being
    /// asked for its index again — decision 12.
    ///
    /// **Only where a preview is what is behind them.** A reader restating a joined forum's boards
    /// has no preview to step back to, so this declines rather than inventing one.
    ///
    /// **The origin is answered by a `switch` and not by a second `guard case`, and it has to
    /// stay one — do not "simplify" it back.** Three places in this app ask whether there is a
    /// preview behind a board list: `JoinSheet.leading(for:)`, `sheetDismissed()` and this. Three
    /// sites is fine; three sites of which one can drift in silence is not. The other two are
    /// exhaustive switches, so a fourth `BoardsOrigin` breaks the build there and somebody has to
    /// decide what is behind it. A `guard case .preview … else { return }` here would compile
    /// clean against that fourth case and quietly answer "decline" on its behalf — which is a
    /// `default:` wearing a different hat, and this repo bans those with two incidents behind it.
    func backToPreview() {
        guard case .choosingBoards(_, let origin) = stage else { return }
        switch origin {
        case .preview(let preview, let ticked):
            errand += 1
            // **The ticks come back with them** — decision 27. This sheet is about to unmount, and
            // before the ticks lived in the stage that is where they went.
            //
            // **`.field` is written here rather than carried, and decision 38 is what made that
            // safe.** The origin travelled in `BoardsOrigin.preview` precisely because a guess
            // between two entrances would throw the reader onto the wrong surface. There is one
            // entrance now, so this is the answer and not a guess.
            stage = .previewing(preview, from: .field, ticked: ticked)
        // A restate has nothing behind it, so there is nothing to step back to. The reader is
        // offered Cancel rather than Back (`JoinSheet.leading(for:)`), so this is unreachable from
        // the sheet — and it refuses rather than inventing a preview if it is reached anyway.
        case .joined:
            return
        }
    }

    /// Reload the session from the store after a snapshot is loaded.
    func reloadFromStore() async {
        await adopt()
    }

    /// The store, followed: each time it says it changed, what it holds is adopted again — so a
    /// landing renews the screen reading it with no key pressed (#175), whoever asked for it.
    ///
    /// **Until the task running it is cancelled**, which is the one way it ends: the root view's
    /// own `.task`, so a window closed stops following. A store that changed nothing says nothing
    /// (`ItemStore.changes()`), so an ask that brought nothing new redraws nothing. The rows keep
    /// their ids across an adopt, which is what keeps the selected post selected.
    func followStore() async {
        // Listening before the first adopt, so a landing between the two is not missed.
        let changes = await store.changes()
        await adopt()
        for await _ in changes {
            await adopt()
        }
    }

    /// Only the sources, projected again through what each server has just said it is — for a
    /// reload that has asked every server and has not read anything yet, so has no notes to adopt.
    func reprojectSources() async {
        await adoptSources()
        rebuildQueries()
    }

    /// What the store now holds, and the queries that draw it.
    ///
    /// **Each half assigned only where it moved.** Both have observers behind them — the forums
    /// watched, the boards each forum is read for, the holdings counted and the text index
    /// dropped — and every view reading the session redraws on an assignment, so a reload that
    /// changed nothing used to pay for all of it. The notes are compared by the store's count of
    /// what `all()` draws rather than row by row: unchanged since the last adopt, and nothing here
    /// has assigned `notes` since either, they are what the store holds. **That count and not the
    /// revision** (#175), so a post held aside — written down, drawn nowhere — replaces nothing.
    private func adopt() async {
        await adoptSources()
        let asideRevision = await store.asideRevision
        let drawn = await store.drawn
        if adopted?.store != drawn || adopted?.notes != notesRevision {
            notes = await store.all()
            adopted = (store: drawn, notes: notesRevision)
        }
        // What is held aside has a count of its own, as what is drawn has, so a landing only
        // the timelines see neither reads it again nor redraws a search (#176).
        //
        // **A forum topic's kept replies are not among them** (#177): each is a post of a thread,
        // not a thread, and a search drawing one would draw it as a row that opens nowhere. A
        // microblog answer is a post in its own right, and stays.
        if adoptedAside != asideRevision {
            aside = await store.aside().filter { DiscuzPost(held: $0) == nil }
            adoptedAside = asideRevision
        }
        if heldRevision != renewedConversations {
            renewConversation()
            renewedConversations = heldRevision
        }
        rebuildQueries()
    }

    /// `heldRevision` as the open conversations last drew from what is held.
    @ObservationIgnored private var renewedConversations: Int?

    /// The conversation in front drawn again from what this device holds of its posts (#193): the
    /// store's copy of each, in the thread's own order. Only the thread in front, and only the
    /// posts it draws are looked for, so an adopt with no thread open walks nothing; a thread left
    /// is drawn again as it opens (`ShellReload.opened`).
    func renewConversation() {
        guard let front = reload.inFront else { return }
        let wanted = conversations.drawnKeys(around: front.id)
        guard !wanted.isEmpty else { return }
        var held: [NoteKey: Note] = [:]
        for note in notes where wanted.contains(note.key) { held[note.key] = note }
        for note in aside where wanted.contains(note.key) { held[note.key] = note }
        conversations.renew(front.id, from: held)
    }

    /// The store's `asideRevision` as the last adopt read what is held aside.
    @ObservationIgnored private var adoptedAside: Int?

    /// The store's `drawn` and `notesRevision` as the last adopt left them. Read in a hop before
    /// the notes, so a write landing between the two is adopted again next time, never missed.
    @ObservationIgnored private var adopted: (store: Int, notes: Int)?

    private func adoptSources() async {
        // **Projected through what each server says it is** — #86. One place, so the row, the
        // tabs, a rule and a read all speak to a host under the name its own server gave rather
        // than the one written down when it was joined. Identity where nothing has been said,
        // which is every host until a read asks one.
        let spoken = await store.sources().map(flavours.spoken)
        if spoken != sources { sources = spoken }
        // A source the store holds again, and not one on its way out, is asked as before (#221).
        reload.readmit(spoken.map(\.host).filter { !removals.contains($0) })
    }

    /// The tabs, rebuilt from what is actually joined.
    ///
    /// **All and Trends, then the reader's own timelines in their order.** Boards stay a property of
    /// the source — what this device fetches next — not a third timeline. A Discourse is not
    /// offered Trends: it has no trending read, and an empty tab is a promise the app cannot keep.
    /// A Discuz! is, for its ranking lists.
    ///
    /// Rebuilt rather than appended to, because a second join changes what the first one's tabs
    /// should be: joining a forum after a microblog must not take Trends away, and the only way
    /// to be sure of that is to ask every source each time.
    func rebuildQueries() {
        guard !sources.isEmpty else {
            queries = []
            timelineID = nil
            return
        }
        var rebuilt: [TimelineQuery] = sources.contains(where: { Self.hasTrends($0.kind) }) ? [.all, .trends] : [.all]
        rebuilt += written.map { .written($0.id) }
        if rebuilt != queries { queries = rebuilt }
        if !queries.contains(where: { $0 == timelineID }) {
            timelineID = .all
        }
    }

    /// Whether a source of this kind has a trending timeline to offer.
    ///
    /// **`ProtocolKind.hasTrends`, not a second list**, so the Trends tab and the Trends
    /// timeline's own rule cannot disagree about which servers have trends. A Discuz! has them —
    /// its ranking lists — and a Discourse has none; a forum's boards choose what is fetched and
    /// are not tabs.
    static func hasTrends(_ kind: ProtocolKind) -> Bool {
        kind.hasTrends
    }

    /// The client a join of this host should go through.
    ///
    /// **The forum's own browser where this run has one, or where this device holds a sign-in
    /// for it** — `ForumSessions.readTransport`, the same door a reload and a post fetch read
    /// through. An engine exists for a host the moment the reader has been offered a sign-in for
    /// it, which is when the session it holds starts to matter: a second `begin` after a sign-in
    /// has to go through the thing that was signed in, or the reader watches a sheet clear a
    /// challenge and then gets the same refusal from a client that was never there. And a
    /// sign-in kept across a relaunch leaves cookies and no engine, so asking about this run
    /// alone sent the board picker, a restate and `around(_:)` through `URLSession` and back to
    /// the challenge's 403.
    /// **It has to be the engine, and nothing can stand in for it.** A host behind an
    /// interactive challenge cannot be read by `URLSessionClient` at all — not with a different
    /// agent, and not with a cookie copied out of the browser. The check is cleared by a person
    /// in a browser, and the only thing holding what that produced is the engine they cleared it
    /// in; reading a second time through anything else gets the challenge back.
    ///
    /// **`readTransport` rather than `transport`**, because `transport(host:)` would *build* one —
    /// a reader adding an ordinary microblog would silently start a web process for a host that
    /// never needed it, and this app does not spend a reader's battery on a maybe. A signed-in
    /// host is a forum, so this still starts none for a microblog.
    ///
    /// `purpose` is what its requests are shown as while they run (#164), and `name` the one
    /// board they read, by the name the reader knows it by — nil for a read of no one board,
    /// such as the forum's front page.
    private func joiner(
        for host: String, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil
    ) -> SourceJoin {
        let client = forums.readTransport(host: host, else: http)
        let folded = host.lowercased()
        let asked = removes[folded, default: 0]
        let unremoved = RemovedStops(WatchedHTTP(client, for: purpose, name: name, in: work)) { [weak self] in
            self?.removes[folded, default: 0] != asked
        }
        return SourceJoin(http: unremoved, store: store, catalogues: emoji)
    }

    private func report(_ error: JoinError, raw: String, host: String) {
        refuse = Self.refuseMessage(error, raw: raw, host: host)
        // A refusal is the one failure where the host is fine, the spelling is fine, and
        // this app was turned away on purpose — which is exactly the case a reader with an
        // account can do something about. Offered only for that one, so that a typo or a
        // dead server never invites somebody to go and sign in to nothing.
        if case .refused = error { offerSignIn = host }
    }

    /// Drops everything this device holds from one server — decision 14, in one place.
    ///
    /// Four kinds and three caches: the emoji catalogue and any fetch of it still on the wire,
    /// the emoji pictures, and the attachment previews and avatars, which share one cache because
    /// they are the same kind of thing arriving through the same door. Each of the three already
    /// knows how to forget a host safely, including how to stop work in flight from landing
    /// behind the reader; what was missing was somebody to press all three.
    ///
    /// **The server stays added.** Clear empties what is held, it does not undo a join: the
    /// reader is still reading this server and its timeline is still theirs. That reading is what
    /// makes it safe for a row still on screen to ask again immediately — see `ShellPictures`,
    /// "What Clear means".
    ///
    /// Presses this session's own caches — the ones `UsagePane` reads its figures off — so
    /// that what the button empties and what the screen reports cannot come apart.
    ///
    /// Four kinds became six. Cookies and a saved password are things a signed-in forum left
    /// here too, and D25 says a Clear that does not reach them leaves the two worst ones behind:
    /// a session somebody can still read the forum with, and a password for a server the reader
    /// has stopped looking at. See `ForumSessions.forget(host:)` for why the password goes even
    /// though decision 14 is otherwise "empties, does not remove", and what the screen says about
    /// it before the button is pressed.
    ///
    /// **The subscribed boards stay, and that is a decision rather than an omission.**
    ///
    /// Decision 14 is "Clear empties what this device holds of a server; it does not undo a
    /// join" — and the boards are not something the server left here. They are the *reader's*
    /// choice, made on a screen built for making it, and they are the same kind of thing as the
    /// source being in the list at all: what the server contributed is the threads, and a thread
    /// is a note. Dropping the boards would silently undo the only decision this whole unit
    /// exists to let them take, and it would do it under a button whose promise is that what goes
    /// comes back — pictures do come back, by themselves; a pick of eight boards out of forty
    /// does not.
    ///
    /// **D25's password is the case that proves it rather than the case to copy.** A password
    /// goes because a secret left behind for a server nobody is reading is a hazard in itself. A
    /// list of board names is neither a secret nor a hazard, so the argument that carried D25
    /// past decision 14 has nothing to carry here.
    ///
    /// **Removing a source is a different act, and that is where the boards go.** There is no
    /// such button yet; when there is, it takes the source, its boards and its notes together,
    /// because that is one decision and this is another.
    ///
    /// The honest cost, said out loud: this Clear does take the forum's cookies, so a board the
    /// reader subscribed to *because* they were signed in is a board they will have to sign in
    /// for again the next time it is read. The subscription outliving the session that reached it
    /// is the right way round — the alternative is a reader losing their picks to a cookie.
    func clear(host: String) async {
        let host = host.lowercased()
        // The question has been answered, so nothing is pending any more — set before the awaits,
        // so no dialog state outlives the decision it was asking about. `remove`'s own line, for
        // its reason. Unconditional, because `remove` reaches this too and a Remove answered while
        // a Clear was pending would otherwise leave that Clear's question standing over a row that
        // has gone.
        clearing = nil
        // Before the first await: Home posts read before the Clear must not land after it.
        stopReadingAsYou(host: host)
        await emoji.forget(host: host)
        emojis.forget(host: host)
        pictures.forget(host: host)
        // Six kinds became seven. A forum's opening posts were this device's copy of that
        // server's words, held for exactly the reason the pictures are — until #154 kept them
        // with their rows, which a Clear keeps (#7). So the ones this run read are handed to
        // the rows first, and what the cache lets go of below is its own copy, the replies,
        // and what was withheld or refused: the rows still draw their words, and nothing is
        // asked of the forum for them. A Remove reaches here too, after its rows are gone, and
        // then there is nothing to hand them to.
        keep(posts.openings(host: host))
        posts.forget(host: host)
        // A blog read is already its row's (#209); what goes is a read on the wire, and why one
        // came to nothing.
        blogs.forget(host: host)
        // Seven became eight, for the same reason: an open thread's answers are this device's
        // copy of that server's words too.
        conversations.forget(host: host)
        // And nine: what the server last said it was is that server's word, not this device's
        // note. Dropped with the rest, so the next read asks it again.
        flavours.forget(host: host)
        // Eleven: what this run read about the forum's sub-boards is its word too (#161).
        subBoards[host] = nil
        lookedUnder[host] = nil
        if restating?.host == host { restating = nil }
        // Ten. A Clear signs this source out below, so an act still on its way to it is an act
        // that cannot now arrive, and a failure left standing about a source the reader has just
        // emptied is a sentence about nothing (#106).
        acts.forget(host: host)
        await forums.forget(host: host)
        // Decision 10: a Mastodon's sign-in goes with a Clear as a forum's does. Signing out
        // drops nothing that Home or a list brought in.
        // The app registration goes with it, so nothing of the sign-in is left.
        await mastodon.signOut(host: host, forgettingApp: true)
        jar.forget(host: host, keeping: sources.map(\.host))
        // **The rows stay (#7).** Clear drops this source's copies — pictures in memory and on
        // disk, emoji, first posts, the sign-in — and not its place in the index: every row still
        // draws, reading its pictures from their hyperlinks again. Nothing in this app reads a
        // joined source's timeline a second time, so dropping its notes here would leave a source
        // still joined and permanently empty; the drop by time is what lets posts go.
        cleared += 1
    }

    /// The drop by cache (#7), and exactly one set: the pictures held in memory and on disk
    /// (`ShellPictures`) and the emoji pictures held in memory (`EmojiCache`, which keeps none on
    /// disk). Emoji names, first posts, sign-ins and the rows themselves are not in it: every row
    /// still draws and reads its pictures from their hyperlinks again. The disk half is gone once
    /// the queue reaches it, so it stays dropped after a relaunch without a save. Bumps `cleared`
    /// for the emoji lines, as a Clear does.
    func dropCopies() {
        pictures.forgetAll()
        emojis.clear()
        cleared += 1
    }

    /// Keeps only the latest `months` months, or everything where nil — the drop by time (#7).
    ///
    /// The window is the store's, so every note read after this obeys it too. Where it dropped
    /// something, the rows are read again and the store is written, so the drop holds after a
    /// relaunch; where it dropped nothing — forever, a wider window, a launch with nothing old —
    /// neither happens. Returns how many notes went.
    @discardableResult
    func keep(months: Int?, from now: Date = Date()) async -> Int {
        let dropped = await store.setRetention(months: months, from: now)
        guard dropped > 0 else { return 0 }
        notes = await store.all()
        await persist?()
        return dropped
    }

    /// An opening post just read, kept with its row in the store and saved (#154).
    ///
    /// **Not written into `notes`**, which the timeline is drawn from and which would redraw every
    /// row for every post that lands as the reader scrolls. This run draws the words from
    /// `posts`, which holds them; the rows carry them from the next read of the store on — a
    /// relaunch, a reload, a join — and a Clear hands them over itself (`keep(_:)` below).
    func keep(_ opening: ForumOpening, for key: NoteKey) {
        Task {
            guard await store.keep([key: opening]) else { return }
            await persist?()
        }
    }

    /// A ranked blog just read, kept with its row and saved — **and drawn at once** (#209).
    ///
    /// Written into `notes` where `keep(_:for:)` above is not, and for the opposite of its reason:
    /// that one lands as the reader scrolls, and a row redrawn for each would be the timeline
    /// redrawn for each; this one lands because the reader opened this very blog, whose pane is
    /// drawn from the row and has nothing else to draw the words from. One row, once.
    ///
    /// **And kept as a change to what is drawn**, so a read of the store that was already on its
    /// way — begun before the keep, and handing back the row without it — is followed by another
    /// that has it, rather than drawing the row as it was until something else moves.
    func keep(_ blog: DiscuzBlog, for key: NoteKey) async {
        let opening = blog.opening
        notes = notes.map { $0.key == key && $0.opening != opening ? $0.with(opening: opening) : $0 }
        guard await store.keep([key: opening], shown: true) else { return }
        await persist?()
    }

    /// One page of a topic's replies, landed in the store **held aside** and saved, and the topic
    /// as the store now holds it (#177).
    ///
    /// Aside, because a reply read in a thread is not a row All grew by (#175). A reply already
    /// held takes the words just read — **never the forum's notice over them**, #154's rule for an
    /// opening post, so a guest's read of a page does not undo what a member's read kept.
    ///
    /// **A reply the page gave no date keeps the one it was first kept with.** Stamped with each
    /// read's moment, every re-read would move the row, write the whole store down again, and keep
    /// it inside the reader's keep-for window for ever.
    func land(_ replies: [DiscuzPost], host: String, tid: Int) async -> [DiscuzPost] {
        let read = Date()
        let first = Dictionary(
            await store.held(host: host, idPrefix: DiscuzPost.heldPrefix(host: host, tid: tid))
                .map { ($0.id, $0.postedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let notes = replies.map { reply in
            let id = DiscuzPost.heldPrefix(host: host, tid: tid) + String(reply.pid)
            return reply.asNote(host: host, read: first[id] ?? read)
        }
        await store.hold(notes, ifSourceHere: host)
        await store.refresh(notes.filter { $0.opening != nil }, ifSourceHere: host)
        await persist?()
        return await keptReplies(host: host, tid: tid)
    }

    /// Every reply of one topic this device holds, in reading order: by page, and on a page in the
    /// order the store took them — which is the order the page wrote them, so a forum that lists a
    /// topic newest first reads back newest first too.
    func keptReplies(host: String, tid: Int) async -> [DiscuzPost] {
        await store.held(host: host, idPrefix: DiscuzPost.heldPrefix(host: host, tid: tid))
            .compactMap(DiscuzPost.init(held:))
            .enumerated()
            .sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }
            .map(\.element)
    }

    /// Every further read of an open thread stopped — a forum's next page, a conversation's next
    /// part (#177). The thread closing, and Esc, which stops these as it stops a reload.
    @discardableResult
    func stopReadingFurther() -> Bool {
        let paging = posts.stopPaging()
        let further = conversations.stopReadingFurther()
        return paging || further
    }

    /// The further reads of one thread stopped — **its pane closing**. Only its own: a reader who
    /// opens a reply's thread from inside this one closes this pane as the next one opens, and the
    /// next one's first ask is not this pane's to stop.
    func stopReadingFurther(of item: DummyItem) {
        if let thread = ForumThreadRef(item) { posts.stopPaging(of: thread) }
        conversations.stopReadingFurther(of: item.id)
    }

    /// This run's opening posts for rows still held, handed to the store **and** to the rows drawn
    /// now, for a Clear about to let the cache that was drawing them go (#154).
    private func keep(_ openings: [NoteKey: ForumOpening]) {
        guard !openings.isEmpty,
              notes.contains(where: { openings[$0.key] != nil && $0.opening != openings[$0.key] })
        else { return }
        notes = notes.map { note in openings[note.key].map(note.with(opening:)) ?? note }
        Task {
            guard await store.keep(openings) else { return }
            await persist?()
        }
    }

    /// The reader is done being signed in to one forum, and nothing else about it changes.
    ///
    /// **Narrower than Clear on purpose.** Clear empties every cache this device holds of a server;
    /// this takes only what being signed in produced — the browser holding the session, its cookies
    /// and the saved password — and leaves the pictures, the emoji and the first posts where they
    /// are. A reader signing out of a forum has not asked to stop reading it, and emptying their
    /// caches for them would answer a question they did not ask.
    ///
    /// Through `forums.forget` and not through anything of its own, which is what makes `Clear` and
    /// `Remove` clear the sign-in too: there is one door and all three go through it (decision 13).
    /// A Mastodon's door is `mastodon.signOut`, which `clear` reaches the same way (decision 10).
    func signOut(host: String) async {
        if kind(of: host) == .mastodon {
            stopReadingAsYou(host: host)
            await mastodon.signOut(host: host)
        } else {
            await forums.forget(host: host.lowercased())
        }
        // Whatever kind it is, no session of any sort is left for it in the system's stores (#221).
        jar.forget(host: host, keeping: sources.map(\.host))
    }

    /// Whether this device holds a sign-in for that source, whichever protocol it is.
    func isSignedIn(host: String) -> Bool {
        forums.reachedSignIn(host: host) || mastodon.isSignedIn(host: host)
    }

    /// A row's Sign in. A Mastodon signs in on its own page through `browser`; anything else is a
    /// forum, and takes `signIn(host:)`'s path.
    ///
    /// Closing the page, or saying no on it, says nothing. Any other failure is one sentence under
    /// the row, through `rowRefusal`, the row's one slot for a sentence about its own press.
    /// A source removed while its page is up is not signed in to.
    ///
    /// **`writing` is the reader's answer to the question the row asked before this was called**
    /// (#69) — `askSignIn(_:)` raises it and only a button in it reaches here. It is never assumed
    /// and never remembered from a previous sign-in: a reader who did not say yes this time signs
    /// in to read, on exactly the scopes this app asked for before it could write at all.
    func signIn(host raw: String, through browser: any OAuthBrowser, writing: Bool = false) async {
        guard let host = try? Host.parse(raw) else { return }
        guard kind(of: host) == .mastodon else {
            await signIn(host: host)
            return
        }
        if rowRefusal?.host == host { rowRefusal = nil }
        guard let failure = await mastodon.signIn(
            host: host, through: browser, writing: writing
        ) else {
            if mastodon.isSignedIn(host: host) { await readAsYou(host: host) }
            return
        }
        NetLog.auth.notice("\(NetLog.line("sign-in", host: host, error: failure), privacy: .public)")
        guard isAdded(host) else { return }
        rowRefusal = (host: host, key: Self.signInFailureKey(failure))
    }

    /// Home and the lists this source reads, read as the reader (#25) — right after a sign-in.
    ///
    /// Only through the signed-in door, so a source never signed in to asks nothing here. A read
    /// that did not all come back is one sentence under the row; a server that ended the sign-in
    /// is told to `mastodon`, which signs the row out and says so.
    func readAsYou(host: String) async {
        guard let door = mastodon.authorized(host: host, for: .timeline) else { return }
        await readingAsYou(host: host, key: "account.mastodon.home.progress") {
            try await MastodonAccount(door: door, store: self.store).read()
        }
    }

    /// The reader wants a different set of lists on a Mastodon they are signed in to — the boards
    /// restate's shape (`changeBoards`): the server's lists are read, and the picker opens ticked
    /// from what is chosen, intersected with what the server still has.
    func changeLists(host raw: String) async {
        let host = raw.lowercased()
        guard Self.rowActsLive(at: stage, checking: checking),
              let source = sources.first(where: { $0.host == host }),
              SourceRow.canChooseLists(source.kind),
              let door = mastodon.authorized(host: host, for: .lists)
        else { return }
        rowRefusal = nil
        progressHost = host
        errand += 1
        let mine = errand
        progress = ProgressReport(owner: .row(host: host), key: "account.source.lists.progress")
        defer { progress = nil }
        do {
            let offered = try await MastodonAccount(door: door, store: store).lists()
            guard mine == errand else { return }
            let chosen = Set(source.lists.map(\.id)).intersection(offered.map(\.id))
            stage = .choosingLists(ListChoice(host: host, offered: offered, ticked: chosen))
        } catch MastodonAuthError.signedOut {
            mastodon.endedByServer(host: host)
        } catch let error where Cancellation.happened(error) {
            progressHost = ""
        } catch {
            guard mine == errand else { return }
            rowRefusal = (host: host, key: "account.source.lists.unread")
        }
    }

    /// The reader pressed Done on the lists: `picks` becomes what this source reads, and the lists
    /// not chosen before are read now. An empty pick is a choice too — Home alone.
    func chooseLists(_ picks: [ListSubscription]) async {
        guard case .choosingLists(let choice) = stage, !checking else { return }
        errand += 1
        stage = nil
        guard let door = mastodon.authorized(host: choice.host, for: .timeline) else { return }
        progressHost = choice.host
        await readingAsYou(host: choice.host, key: "account.source.lists.reading") {
            try await MastodonAccount(door: door, store: self.store).choose(picks)
        }
    }

    /// The reads as the reader in flight, per host — so a sign-out, Clear or Remove can stop them
    /// before their posts land (`stopReadingAsYou`).
    @ObservationIgnored private var readsAsYou: [String: Task<Void, Never>] = [:]

    /// One errand of reads as the reader, reported in its row.
    ///
    /// **It reports only where nothing else is.** A sign-in can finish while another row's errand
    /// is on the wire; this read then runs without a line rather than taking that row's line and
    /// clearing it when it ends.
    private func readingAsYou(
        host: String, key: String, _ read: @escaping @MainActor () async throws -> Bool
    ) async {
        let report = ProgressReport(owner: .row(host: host), key: key)
        let reports = progress == nil
        if reports { progress = report }
        let task = Task { @MainActor in
            do {
                let complete = try await read()
                await adopt()
                if !complete { rowRefusal = (host: host, key: "account.mastodon.read.partial") }
            } catch MastodonAuthError.signedOut {
                mastodon.endedByServer(host: host)
            } catch {
                // Stopped, or a reader walking away: nothing came in and there is nothing to say.
            }
        }
        readsAsYou[host] = task
        await task.value
        if readsAsYou[host] == task { readsAsYou[host] = nil }
        if reports, progress == report { progress = nil }
    }

    /// Stops the reads as the reader in flight for `host`: signed out, cleared or removed, nothing
    /// they bring may land afterwards.
    private func stopReadingAsYou(host: String) {
        readsAsYou.removeValue(forKey: host.lowercased())?.cancel()
        reload.stop(host: host)
    }

    /// The sentence under a Mastodon row whose sign-in did not finish.
    static func signInFailureKey(_ failure: MastodonSignInError) -> String {
        switch failure {
        case .unreachable, .http: "account.mastodon.failed.unreachable"
        case .keychain: "account.mastodon.failed.keychain"
        case .cancelled, .denied, .stateMismatch, .unreadable, .clientRejected, .invalidScope:
            "account.mastodon.failed"
        }
    }

    private func kind(of host: String) -> ProtocolKind? {
        let host = host.lowercased()
        return sources.first { $0.host == host }?.kind
    }

    /// The reader has stopped reading a server: it goes, and everything it left here goes with it.
    ///
    /// **Remove subsumes Clear rather than sitting beside it.** Clear's promise is that what goes
    /// comes back, because the reader is still reading the server — see `clear`, "The server stays
    /// added". Remove withdraws exactly that premise, so a Remove that emptied the store and left
    /// the pictures, the emoji, the first posts and the forum's cookies behind would be promising
    /// less than it said: this device would still be holding a cache, and a session, for a server
    /// the reader said to let go of.
    ///
    /// **The store first and the caches second, and the order is load-bearing.** `clear` bumps
    /// `ShellPictures`' generation, and that bump's documented contract is that a row still on
    /// screen asks again immediately — which is right for Clear and would be a burst of avatar and
    /// emoji requests aimed at the host the reader has just deleted. `adopt()` in between is what
    /// takes those rows out of the list before the bump lands, so the re-fetch has nothing to
    /// re-fetch. Nothing in the code says this; it is why the two awaits are in this order and not
    /// the other.
    ///
    /// **Before either, what is left over of the reader's last errand**, where that errand was
    /// about this host — ended ahead of the first await, so no errand can land in the gaps between
    /// them. `progressHost` is the one field that records which host `add` and `subscribe` were
    /// about, so it is what the token, the refusal sentence, the unread boards and their count are
    /// gated on — clearing them unconditionally would take away a sentence owed about a different
    /// server.
    func remove(host raw: String) async {
        let host = raw.lowercased()
        // The question has been answered, so nothing is pending any more — set before the awaits,
        // so no dialog state outlives the decision it was asking about.
        removing = nil
        stopReadingAsYou(host: host)
        // Every read of it a reload has on its way ends here, signed in or not, and an open thread
        // from it is not renewed again: nothing this app does on its own reaches it after (#221).
        reload.letGo(host: host)
        removes[host, default: 0] += 1
        removals.insert(host)
        defer { removals.remove(host) }
        if progressHost.lowercased() == host {
            // **The errand in flight is about the server that just went, so it ends here.** This
            // is the same token `add`, `take` and `subscribe` compare before they write, bumped by
            // the one act that can invalidate an errand from outside it. Without it, a `subscribe`
            // whose boards are still being read one at a time returns after this and writes the
            // source, its board picks and its threads straight back into the store — the reader
            // presses Remove, watches the row go, and watches it come back seconds later.
            //
            // **Only where the errand is about *this* host**, which is the question this branch
            // already exists to ask. Removing one server while another is being added is two
            // unrelated acts, and bumping unconditionally would abandon a join the reader is still
            // waiting on, for a press that had nothing to do with it.
            //
            // **Before the first await, not after the last.** The awaits below give way to the
            // main actor, and a `subscribe` whose Core call returns in that window reads the token
            // there: bumped after them, it read a token that still matched and adopted the source
            // this call had just taken out of the store, so the row came back. Bumped here, every
            // continuation that runs after this line sees a stale token and takes its write back.
            errand += 1
            refuse = nil
            unread = []
            unreadAll = 0
            progressHost = ""
        }
        await store.remove(host: host)
        await adopt()
        await clear(host: host)

        // Folded on both sides rather than on one. `Host.parse` lowercases everything it returns,
        // so all three of these are already folded today — and that is a guarantee three files
        // away that nothing at this site states, which is the shape `add`'s own comment names as
        // how a class of bug reached fourteen places.
        if offerSignIn?.lowercased() == host { offerSignIn = nil }
        // A sentence drawn by a row that has gone. Its own host and not `progressHost`, because a
        // refusal outlives the errand that produced it — that is the whole of what it is for.
        if rowRefusal?.host == host { rowRefusal = nil }
        // The sheet holding somebody else's login page, where it is that server's. A race rather
        // than a click today, because `signIn` sets this *after* `await forums.signIn(host:)` and
        // that await is exactly the window a Remove is pressable in — and properly reachable once
        // unit 5 draws the Sign in / Sign out toggle on the row. A sheet left up over a server
        // that is gone would be asking the reader to sign in to nothing.
        if signingIn?.host.lowercased() == host { signingIn = nil }
        // The sheet standing open over a server that is gone. It covers all three stages now
        // rather than the pause alone: a preview of a removed host is as stale as a board list of
        // one, and `.browsing` names no host so it is left where it is — a reader looking for
        // something else has not asked for their list to be taken away.
        if stage?.host?.lowercased() == host { dismissStage() }
    }

    /// Shows the reader the forum's own page, after asking the saved credential first.
    ///
    /// **Automatic is the default path and never the only one** — D24. The saved password is
    /// tried, and every way that can stop short of a confirmed sign-in ends here, with the page
    /// in front of the reader and a sentence saying which way it stopped. None of them is
    /// reported as a failure, because none of them is one.
    func signIn(host raw: String) async {
        guard let host = try? Host.parse(raw) else { return }
        let outcome = await work.watching(host: host, for: .signIn) { await forums.signIn(host: host) }
        switch outcome {
        case .signedIn:
            // The automatic path, and one of the two witnesses of a sign-in — decision 13. The
            // other is the reader closing the forum's own page below.
            forums.recordSignIn(host: host)
            signingIn = nil
            offerSignIn = nil
        case .handOver(let stop):
            signingIn = ForumSignInRequest(host: host, stop: stop)
        case .forgotten:
            // Signed out of, cleared or removed while it ran: nothing to show (#221).
            break
        }
    }

    /// The sheet closed. A sign-in that was reached clears the offer; one that was not leaves it
    /// where it is, so the reader can try again without retyping the host.
    ///
    /// **Two different errands end here, and the answer is which one it was.**
    ///
    /// *A host that is not a source yet.* The reader typed it, was turned away, and went and
    /// signed in — what they were doing the whole time was adding that forum, and landing them
    /// back at an empty field having lost what they typed would make them start again. So this
    /// says yes, and the caller takes them back to `begin`, which this time goes through the
    /// browser that now holds the session.
    ///
    /// *A host that is already a source.* This is the row's toggle (decision 13), and there is
    /// nothing to resume: the server is read, its boards are picked, and **the sign-in was the
    /// whole errand**. So this says no. It is quiet and it is not silent — `recordSignIn` below
    /// has already run, `ForumSessions` is observed, and the row's toggle is drawn from
    /// `reachedSignIn`, so it reads Sign out by the time the sheet is gone. That is the reader's
    /// answer, and it is why no sentence is needed under the field for a press that was not made
    /// there.
    ///
    /// **Decided here rather than by the caller or inside `resumeAfterSignIn`**, because this is
    /// the last place the host behind the sheet is known. `resumeAfterSignIn` goes by `hostname`,
    /// so a guard put there would be asking about whatever is in the field — and a reader
    /// pressing a button on a row may have been half-way through typing a different server into
    /// it, which would turn a refusal into an unasked-for join.
    ///
    /// **The incident.** Both call sites in `FediqoRootView` ran the retry on any sign-in that
    /// was reached, so a reader who pressed Sign in on a joined Discuz! row and signed in was
    /// answered with "You are already reading this server" — `look`'s duplicate guard, reporting
    /// an errand nobody had started. It shipped in M1 and the suite stayed green, because
    /// `resumeAfterSignIn` was driven only from the typed-host path.
    ///
    /// Answered rather than acted on, so the decision is a value a test can read and not a task
    /// this object spawned on its own.
    @discardableResult
    func signInFinished(reached: Bool, host: String? = nil) -> Bool {
        // Whose page it was, asked before the sheet state is dropped. The argument where the caller
        // named one, and the sheet's own host otherwise — the two always agree in the app, and a
        // caller that names nothing is still telling the truth about a sheet that was up.
        let was = host ?? signingIn?.host
        signingIn = nil
        guard reached else { return false }
        offerSignIn = nil
        // The other witness: the reader closed the forum's own page having got there. Counted
        // whatever the forum named its cookie; the store is what a relaunch reads.
        if let was { forums.recordSignIn(host: was) }
        // The row's errand, and it is finished: recorded on the line above, and drawn by the
        // toggle that reads it. Asked before the field is written, because writing the field is
        // the other errand's business and not this one's.
        if let was, isAdded(was) { return false }
        // What they typed, restored from the host they signed in to — the field may have been
        // edited while the sheet was up, and the errand belongs to the host behind the sheet.
        // **Only where the field is what the errand was about.** A reader who pressed a button on
        // a row was not typing a hostname at all, so putting the row's host there would take away
        // what they were in the middle of typing to answer a question they did not ask.
        if let host { hostname = host }
        return true
    }

    /// One board that was picked and could not be read, said as a sentence naming it.
    ///
    /// **No `default:`.** Two of these cannot happen to one board — a bad host and an unsupported
    /// protocol are decided before any board is read — and they are still named, because a case
    /// swept into somebody else's sentence is how a reader gets told the wrong thing.
    static func unreadMessage(_ entry: UnreadBoard) -> String {
        switch entry.error {
        case .refused(let status):
            String(format: L10n.t("board.unread.refused"), entry.board.name, status)
        case .publicTimelineFailed:
            String(format: L10n.t("board.unread.unreadable"), entry.board.name)
        case .unreachable:
            String(format: L10n.t("board.unread.network"), entry.board.name)
        case .invalidHost, .unsupportedKind:
            String(format: L10n.t("board.unread.unreadable"), entry.board.name)
        }
    }

    private static func refuseMessage(_ error: JoinError, raw: String, host: String) -> String {
        switch error {
        case .unsupportedKind(let kind) where kind == .unknown:
            String(format: L10n.t("account.refuse.unknown"), host)
        case .unsupportedKind(let kind):
            String(format: L10n.t("account.refuse.kind"), host, kind.displayName)
        case .invalidHost:
            String(format: L10n.t("account.refuse.unknown"), raw)
        case .unreachable:
            L10n.t("account.refuse.network")
        case .publicTimelineFailed:
            String(format: L10n.t("account.refuse.closed"), host)
        // The host is fine and the spelling is fine: something in front of it turned this app
        // away. Said as its own sentence so the reader does not go looking for a fault of
        // theirs — see `JoinError.refused`.
        case .refused(let status):
            String(format: L10n.t("account.refuse.refused"), host, status)
        }
    }
}

/// Which surface reports an errand while it is on the wire.
///
/// **Three, because three presses start one.** A look and a join are pressed at the field and
/// answered under it; a restate is pressed inside one row and answered in that row; and the inline
/// preview's own Subscribe is a third — it sits in a block in the page, and a sentence under the
/// field about it is a sentence the reader is not looking at.
///
/// **There was a fourth and it is gone, which is decision 38 deleting machinery rather than
/// adding it.** `.sheet` was never a claim, only an answer: what `reporting(_:drawnAs:)` returned
/// when a sheet stood over whichever surface *had* claimed the errand. It existed for one route —
/// a preview reached from the browser, whose press reported `.page` while its stage was surfaced
/// `.sheet` — and the browser presses nothing now. No errand runs under a sheet, so nothing can be
/// covered, so there is no answer of that shape to give. **Do not reintroduce it as armour**: see
/// `reporting(_:drawnAs:)` for the five entrances that hold the invariant, which is where a sixth
/// has to answer.
///
/// **No `default:`** at any site that switches on it.
enum ProgressOwner: Equatable {
    /// The field's errand: a look, or a join with no block on screen.
    case page
    /// One row's own errand: a restate, its index read or the boards that follow it.
    case row(host: String)
    /// The inline preview's own Subscribe, answered in the block the reader pressed.
    case block
}

/// What is on the wire, said where the press was.
///
/// **The key is carried and not derived from the owner**, because it is not a function of it: the
/// page reports both a look and the boards a reader picked, and those are different errands in
/// different words. That is the whole of the defect this closes — see `ProgressReport.key`.
struct ProgressReport: Equatable {
    let owner: ProgressOwner
    /// The sentence this phase says, as a key taking the host.
    ///
    /// - `account.detect.progress` — "Checking %@…", and it means **detection**.
    /// - `account.source.boards.progress` — "Reading %@'s boards…", the forum's *index*, which is
    ///   what it has always meant.
    /// - `account.join.boards.progress` — "Reading the boards you picked on %@…", one request per
    ///   picked board, sequentially.
    ///
    /// **The third key exists because the longest wait in this app was labelled with the first.**
    /// `subscribe(_:)` reads one page per picked board, so a reader who picked eight boards watched
    /// "Checking forum.example…" for as long as eight page fetches take — the detection vocabulary
    /// over the one phase in the app that detects nothing. The restate's half of that was routed
    /// into the row; the join's half was still under the field.
    ///
    /// Core reports no per-board progress, so "board 3 of 8" is not buildable today. Recorded, not
    /// designed.
    ///
    /// **Do not derive this from `owner`. It is the tidier shape and it reinstates the defect this
    /// unit exists to fix**: `.page` carries two of the three keys — a look, and the boards the
    /// reader picked — so a function from owner to key has to pick one of them, and picking the
    /// detection one is how the longest wait in the app came to be labelled "Checking %@…" over a
    /// phase that detects nothing.
    let key: String
}

/// A join's way out that closes once its source is removed (#221): its next board, page or look
/// is not asked for, and nothing is recorded against the source that went.
private struct RemovedStops: HTTPClient {
    let inner: any HTTPClient
    let removed: @MainActor @Sendable () -> Bool

    init(_ inner: any HTTPClient, removed: @escaping @MainActor @Sendable () -> Bool) {
        self.inner = inner
        self.removed = removed
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if await removed() { throw CancellationError() }
        return try await inner.data(from: url)
    }
}
