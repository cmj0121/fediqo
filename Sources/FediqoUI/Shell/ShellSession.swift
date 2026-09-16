import FediqoCore
import Foundation
import Observation

/// In-memory session: unsigned sources, All and Trends, and the Account add flow.
@MainActor
@Observable
final class ShellSession {
    enum Catalog: Equatable {
        case loading
        case failed
        case empty
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
    /// Preferences draws and the caches its button presses are the same objects by
    /// construction**. They used to agree by convention — the pane read `.shared` while `clear`
    /// took parameters — which is an agreement a preview or a test wired to fixture caches
    /// breaks silently: it would press the fixtures and draw the live figures, and the reading
    /// would simply not move.
    let pictures: ShellPictures
    let emojis: EmojiCache

    /// Every forum this run signs in to, one browser each — unit F2's transport.
    ///
    /// On the session for the same reason the two picture caches are: **what Clear presses and
    /// what Preferences draws have to be the same object**, and a second one reached for as
    /// `.shared` at a call site is an agreement that a test or a preview breaks in silence.
    let forums: ForumSessions

    /// One thread's opening post, fetched when its row is scrolled to — D30 — and the rest of
    /// the topic on request — D31.
    ///
    /// On the session for the reason the two picture caches and `forums` are: **what Clear
    /// presses and what Preferences draws have to be the same object**. It is built here rather
    /// than passed in because it needs two things only the session has — this session's transport
    /// and this session's forum browsers, without which a thread on a forum the reader signed in
    /// to comes back withheld.
    let posts: ForumPosts

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

    /// Which stage of adding a source the reader is being shown, or nothing.
    ///
    /// **Nothing has been added at any of the three.** Browsing is a list, previewing is what a
    /// server says about itself, and choosing boards is D28's pause — the source, its boards and
    /// its threads all wait on the reader through every one of them. Clearing this is therefore a
    /// complete undo at any stage: there is nothing to take back.
    ///
    /// **One presenter and one piece of state for all three**, which is what buys the Back button
    /// on the boards stage: the reader returns to the preview they already have instead of the
    /// app asking the forum for its index again. See `JoinStage`.
    var stage: JoinStage?

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

    var queries: [DummyTimeline] = DummyTimeline.shipped
    var timelineID: String?
    var sources: [Source] = []
    var notes: [Note] = []

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
    var checking = false
    var progressHost = ""
    var refuse: String?
    /// The Account search field is first responder; dummy keys must not steal its typing.
    var searchFocused = false

    init(
        http: any HTTPClient,
        store: ItemStore = ItemStore(),
        pictures: ShellPictures = .shared,
        emojis: EmojiCache = .shared,
        forums: ForumSessions = ForumSessions(),
        posts: ForumPosts? = nil
    ) {
        self.http = http
        self.store = store
        self.pictures = pictures
        self.emojis = emojis
        self.forums = forums
        // Built with this session's forum browsers, so a thread on a forum the reader signed in
        // to is read through the engine that holds the cookies rather than around it.
        //
        // **Not built from `http`.** The session's transport is whatever a test or a preview
        // handed in and, in the product, a `URLSessionClient` at the 128 MiB last line. A thread
        // page is a caller that knows what it expects — the largest measured on four installs is
        // 274KB — so it carries its own far tighter ceiling. See `ForumPosts.maxBytes`, and the
        // plan's standing item about per-caller response ceilings, of which this is the first.
        self.posts = posts ?? ForumPosts(through: forums)
    }

    var availability: ShellAvailability {
        ShellAvailability(queryIDs: Set(queries.map(\.id)), signedIn: false)
    }

    func isAdded(_ domain: String) -> Bool {
        let host = domain.lowercased()
        return sources.contains { $0.host == host }
    }

    var query: String {
        hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Catalog rows matching the field, live. Domain and description, case-insensitive.
    var visibleServers: [CatalogServer] {
        guard case .ready(let servers) = catalog else { return [] }
        let needle = query
        guard !needle.isEmpty else { return servers }
        return servers.filter { Self.matches($0, query: needle) }
    }

    /// A typed host that is not in the visible catalog. Join is still a tap.
    var extraJoinHost: String? {
        guard let host = try? Host.parse(hostname) else { return nil }
        let isAddress = host.contains(".") || host.contains(":")
        guard isAddress else { return nil }
        if visibleServers.contains(where: { $0.domain.compare(host, options: .caseInsensitive) == .orderedSame }) {
            return nil
        }
        return host
    }

    static func matches(_ server: CatalogServer, query: String) -> Bool {
        server.domain.localizedCaseInsensitiveContains(query)
            || server.summary.localizedCaseInsensitiveContains(query)
    }

    /// Enter and the search icon. The list already filters as the field changes.
    func search() {
        refuse = nil
        hostname = query
    }

    func loadCatalog() async {
        if case .ready = catalog { return }
        if case .empty = catalog { return }
        catalog = .loading
        do {
            let servers = try await ServerDirectory(http: http).servers()
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

    func pick(_ server: CatalogServer) async {
        hostname = server.domain
        await add()
    }

    /// Add pressed. **Looks, and adds nothing** — the reader sees what the server says about
    /// itself and then decides, which is what `confirm` is for.
    ///
    /// **Guarded on the stage as well as on `checking`.** `checking` is false the whole time the
    /// preview sheet is up, so the field and the Add button are live again and a second look
    /// would overwrite the stage under a reader who is reading the first one. The sheet being up
    /// *is* the errand being in progress, and it is the stage that says so.
    ///
    /// **`stage?.host` and not `stage`, because browsing is where a look is started from.** A row
    /// pressed in the directory is this call, so refusing it whenever any stage is up would make
    /// the whole list dead to the touch. What has to stop a second look is a stage that is
    /// already *about a server* — a preview, or its boards — and `host` is the question that
    /// separates those from the list.
    func add() async {
        guard let preview = await look() else { return }
        stage = .previewing(preview)
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
    func resumeAfterSignIn() async {
        guard let preview = await look() else { return }
        await take(preview)
    }

    /// One look: the duplicate guard, the parse, the request, and every way it can go wrong said
    /// as a sentence. **Sets no stage** — what to do with the answer is the caller's, which is
    /// the whole of the difference between `add` and `resumeAfterSignIn`.
    private func look() async -> SourcePreview? {
        guard !checking, stage?.host == nil else { return nil }
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
        errand += 1
        let mine = errand
        checking = true
        defer { checking = false }
        do {
            let preview = try await joiner(for: parsed).look(host: raw)
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
    func confirm() async {
        guard !checking, case .previewing(let preview) = stage else { return }
        await take(preview)
    }

    /// The press itself, wherever it was pressed from.
    private func take(_ preview: SourcePreview) async {
        refuse = nil
        offerSignIn = nil
        unread = []
        unreadAll = 0
        progressHost = preview.host
        errand += 1
        let mine = errand
        checking = true
        defer { checking = false }
        do {
            // **No `default:`.** A join step falling through a switch is a silent wrong answer:
            // a forum reported as joined, with no source and no boards behind it, and the
            // compiler saying nothing. Both cases are named, so a third breaks the build here.
            switch try await joiner(for: preview.host).begin(preview) {
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
                stage = .choosingBoards(offer, from: preview)
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

    /// Browse pressed. **The catalog is fetched here and not on the page appearing** — decision
    /// 10 — so a reader who never browses never has this app contact a third party for them.
    func browse() {
        guard !checking, stage == nil else { return }
        refuse = nil
        stage = .browsing
        Task { await loadCatalog() }
    }

    /// The sheet closed, by whatever route — a button, a swipe, Escape.
    ///
    /// **Nothing was added at any stage, so there is nothing to undo**, and what the reader typed
    /// stays in the field so pressing Add again gets them back to where they were. What the bump
    /// buys is the other half: a press whose answer is still on the wire has just been abandoned,
    /// and its `.chooseBoards` must not spring this sheet back open behind them.
    ///
    /// **A preview backed out of forgets the picture it pulled.** `ShellPictures` tags an entry
    /// by host, and `PreferencesPane` lists the hosts in `sources` — so a thumbnail fetched for a
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
        guard case .choosingBoards(let offer, _) = stage, !checking else { return }
        // Taken down once this call is certain to handle it, so the sheet is gone while the
        // boards are read one at a time and a second press cannot start a second pick against
        // the same offer — and so a call that declines to act does not close the sheet on a
        // reader whose pick then went nowhere.
        errand += 1
        stage = nil
        guard !picks.isEmpty else { return }
        refuse = nil
        offerSignIn = nil
        unread = []
        unreadAll = 0
        progressHost = offer.host
        checking = true
        defer { checking = false }
        do {
            let outcome = try await joiner(for: offer.host).subscribe(offer, to: picks)
            unread = outcome.unread
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
            unreadAll = picks.count
            report(error, raw: offer.host, host: offer.host)
        } catch {
            unreadAll = picks.count
            refuse = L10n.t("account.refuse.network")
        }
    }

    /// The reader stepped back from a preview to the list they picked it off.
    ///
    /// **Not `browse()`, and the difference is which press it is.** `browse` is the page's button
    /// and is refused while a sheet is up, because a reader reading a preview did not ask for it
    /// to be replaced. This is the sheet's own Back, where being at a preview is the *premise*.
    /// The catalog is already loaded by the time this can be pressed, so nothing is refetched.
    func backToBrowsing() {
        guard case .previewing = stage else { return }
        errand += 1
        stage = .browsing
    }

    /// The reader stepped back from the boards to the preview they arrived through.
    ///
    /// **No second request, which is the whole gain of one sheet over three.** The preview
    /// travelled in the stage precisely so that this is a value being read and not a forum being
    /// asked for its index again — decision 12.
    func backToPreview() {
        guard case .choosingBoards(_, let preview) = stage else { return }
        errand += 1
        stage = .previewing(preview)
    }

    /// What the store now holds, and the queries that draw it.
    private func adopt() async {
        sources = await store.sources()
        notes = await store.all()
        rebuildQueries()
    }

    /// The tabs, rebuilt from what is actually joined.
    ///
    /// **A forum is not offered Trends** (D27, and the open item this branch recorded against
    /// itself): a join used to set the list to `all` and `trends` whatever it had joined, and a
    /// forum has no trending endpoint at all, so that tab was permanently empty. An empty tab is
    /// a promise the app cannot keep, and the reader has no way to tell it from a quiet hour.
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
        var made = [DummyTimeline(id: "all")]
        if sources.contains(where: { Self.hasTrends($0.kind) }) {
            made.append(DummyTimeline(id: "trends"))
        }
        for source in sources {
            for board in source.boards {
                made.append(DummyTimeline(
                    board: BoardQuery(host: source.host, fid: board.fid, name: board.name)
                ))
            }
        }
        queries = made
        if timelineID == nil || !made.contains(where: { $0.id == timelineID }) {
            timelineID = made.first?.id
        }
    }

    /// Whether a source of this kind has a trending timeline to offer.
    ///
    /// **No `default:`.** This is a switch over a protocol kind, and this branch has already
    /// shipped one silent wrong answer through exactly that shape. A protocol added and not
    /// listed here would silently inherit somebody else's answer about a tab it may not have.
    static func hasTrends(_ kind: ProtocolKind) -> Bool {
        switch kind {
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
            .gotosocial:
            true
        // Neither forum has one. Discourse publishes no trending read this app takes, and
        // Discuz! publishes a page; what a forum has instead is boards, and those are the tabs.
        case .discourse, .discuz, .unknown:
            false
        }
    }

    /// The query a timeline id names, resolved out of the list that knows the names.
    ///
    /// A board's tab cannot be rebuilt from its id — see `DummyTimeline.board` — so a view that
    /// reconstructed one would draw a tab that matched no note. Falls back to a plain query for
    /// `all`, `trends`, and for nothing selected at all.
    func timeline(for id: String?) -> DummyTimeline {
        guard let id else { return DummyTimeline(id: "") }
        return queries.first { $0.id == id } ?? DummyTimeline(id: id)
    }

    /// The client a join of this host should go through.
    ///
    /// **The forum's own browser, but only where this run already has one.** An engine exists for
    /// a host exactly when the reader has been offered a sign-in for it, which is the moment the
    /// session it holds starts to matter: a second `begin` after a sign-in has to go through the
    /// thing that was signed in, or the reader watches a sheet clear a challenge and then gets
    /// the same refusal from a client that was never there. `hasEngine` is asked rather than
    /// `engine(host:)` so that a plain microblog join never starts a web process.
    /// **It has to be the engine, and nothing can stand in for it.** A host behind an
    /// interactive challenge cannot be read by `URLSessionClient` at all — not with a different
    /// agent, and not with a cookie copied out of the browser. The check is cleared by a person
    /// in a browser, and the only thing holding what that produced is the engine they cleared it
    /// in; reading a second time through anything else gets the challenge back.
    ///
    /// **`hasEngine` rather than `transport`**, because `transport(host:)` would *build* one — a
    /// reader adding an ordinary microblog would silently start a web process for a host that
    /// never needed it, and this app does not spend a reader's battery on a maybe.
    private func joiner(for host: String) -> SourceJoin {
        var client: any HTTPClient = http
        if forums.hasEngine(host: host) {
            client = ForumJoinTransport(forums.transport(host: host))
        }
        return SourceJoin(http: client, store: store, catalogues: emoji)
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
    /// Presses this session's own caches — the ones `PreferencesPane` reads its figures off — so
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
        await emoji.forget(host: host)
        emojis.forget(host: host)
        pictures.forget(host: host)
        // Six kinds became seven. A forum's opening posts are this device's copy of that server's
        // words, held for exactly the reason the pictures are, and a Clear that reached the
        // pictures and left the posts would empty half of what the reader was looking at.
        posts.forget(host: host)
        await forums.forget(host: host)
        cleared += 1
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
    /// Then what is left over of the reader's last errand, where that errand was about this host.
    /// `progressHost` is the one field that records which host `add` and `subscribe` were about, so
    /// it is what the refusal sentence, the unread boards and their count are gated on — clearing
    /// them unconditionally would take away a sentence owed about a different server.
    func remove(host raw: String) async {
        let host = raw.lowercased()
        // The question has been answered, so nothing is pending any more — set before the awaits,
        // so no dialog state outlives the decision it was asking about.
        removing = nil
        await store.remove(host: host)
        await adopt()
        await clear(host: host)

        // Folded on both sides rather than on one. `Host.parse` lowercases everything it returns,
        // so all three of these are already folded today — and that is a guarantee three files
        // away that nothing at this site states, which is the shape `add`'s own comment names as
        // how a class of bug reached fourteen places.
        if offerSignIn?.lowercased() == host { offerSignIn = nil }
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
        if progressHost.lowercased() == host {
            refuse = nil
            unread = []
            unreadAll = 0
            progressHost = ""
        }
    }

    /// Shows the reader the forum's own page, after asking the saved credential first.
    ///
    /// **Automatic is the default path and never the only one** — D24. The saved password is
    /// tried, and every way that can stop short of a confirmed sign-in ends here, with the page
    /// in front of the reader and a sentence saying which way it stopped. None of them is
    /// reported as a failure, because none of them is one.
    func signIn(host raw: String) async {
        guard let host = try? Host.parse(raw) else { return }
        switch await forums.signIn(host: host) {
        case .signedIn:
            signingIn = nil
            offerSignIn = nil
        case .handOver(let stop):
            signingIn = ForumSignInRequest(host: host, stop: stop)
        }
    }

    /// The sheet closed. A sign-in that was reached clears the offer; one that was not leaves it
    /// where it is, so the reader can try again without retyping the host.
    ///
    /// **Reaching a sign-in is not the end of the errand.** The reader typed a host, was turned
    /// away, and went and signed in — what they were doing the whole time was adding that forum,
    /// and landing them back at an empty field having lost what they typed would make them start
    /// again. So a sign-in that was reached says so, and the caller takes them back to `begin`,
    /// which this time goes through the browser that now holds the session.
    ///
    /// Answered rather than acted on, so the decision is a value a test can read and not a task
    /// this object spawned on its own.
    @discardableResult
    func signInFinished(reached: Bool, host: String? = nil) -> Bool {
        signingIn = nil
        guard reached else { return false }
        offerSignIn = nil
        // What they typed, restored from the host they signed in to — the field may have been
        // edited while the sheet was up, and the errand belongs to the host behind the sheet.
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
