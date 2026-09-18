import FediqoCore
import Foundation
import Observation
import SwiftUI

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

    /// The server the reader has pressed Clear on and not yet answered for, or nothing.
    ///
    /// **Nothing is emptied while this is set** — `removing`'s shape, for a reason decision 29
    /// only half states. The colour is the user's overstatement; the confirmation is closing a
    /// real hole. `clear(host:)` reaches `ForumSessions.forget(host:)`, which drops the forum's
    /// cookies **and deletes the saved password from the Keychain** — and `forget`'s own doc makes
    /// the fairness of that conditional on one thing: *"the row says a password is held before the
    /// button is pressed"*. `PreferencesPane` draws `passwordLine` and meets it. An Account row
    /// draws no inventory line at all, by `DESIGN.md` §3.6's own rule, so until now this device
    /// deleted a password with nothing on screen having said one was held — and signed the reader
    /// out of a forum, changing the state of the icon beside the one they pressed.
    ///
    /// **One presenter, both entrances.** `prefs.cache.clear` is one word for one call, so a Clear
    /// that confirms on Account and fires straight on Preferences would be the same word doing two
    /// different things two panes apart. `PreferencesPane` sets this too.
    var clearing: String?

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
                profile: profiles[source.host] ?? .unasked(host: source.host, kind: source.kind)
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

    var queries: [DummyTimeline] = DummyTimeline.shipped
    var timelineID: String?
    /// Every change is handed on to `forums`, which is the one place that knows which of them
    /// are forums a sign-in can be held for.
    var sources: [Source] = [] {
        didSet { forums.watch(forums: sources.filter { $0.kind == .discuz }.map(\.host)) }
    }
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
        if case .ready = catalog { return }
        if case .empty = catalog { return }
        guard !fetchingCatalog else { return }
        fetchingCatalog = true
        defer { fetchingCatalog = false }
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
        errand += 1
        let mine = errand
        // **The page owns a look, even beside an open block.** The reader typed into the field, so
        // that is where the sentence belongs — which is the one place `owner(drawing:)` would give
        // the wrong answer, and the reason this is stated rather than derived.
        progress = ProgressReport(owner: .page, key: "account.detect.progress")
        defer { progress = nil }
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
            Task { await loadCatalog() }
        // None of these offers a protocol to press: the server list is a step further in, a
        // preview and a board list are about one server, and a detail is about one the reader has.
        case .browsingServers, .previewing, .choosingBoards, nil:
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
        case .choosingBoards(_, .joined), .browsing, .browsingServers, .previewing, nil:
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
        guard case .choosingBoards(let offer, let origin) = stage, !checking else { return }
        // Taken down once this call is certain to handle it, so the sheet is gone while the
        // boards are read one at a time and a second press cannot start a second pick against
        // the same offer — and so a call that declines to act does not close the sheet on a
        // reader whose pick then went nowhere.
        errand += 1
        let mine = errand
        stage = nil
        guard !picks.isEmpty else { return }
        refuse = nil
        offerSignIn = nil
        boardsRefusal = nil
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
            let outcome = try await joiner(for: offer.host)
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
    /// **The same rule `boardsRefusal` was built for, applied to the other half of the errand.** A
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
            boardsRefusal = (host: offer.host, key: "account.source.boards.unread")
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

    /// A row's boards control was pressed and the forum's index could not be read.
    ///
    /// **Drawn by the row whose host matches, and by nothing else.** The refusal sentence every
    /// other errand on this page writes is `refuse`, which `AccountPane` draws under the field —
    /// and a reader who pressed a control in row four of six is 900pt away from it. A refusal
    /// nobody can see is not a refusal.
    ///
    /// **Not `alarm`, and the row says why**: that colour is spent on the line that says a host
    /// was *not added* and why, and this host was added weeks ago. Nothing changed here.
    var boardsRefusal: (host: String, key: String)?

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
    /// **The picker opens ticked from what is subscribed, intersected with what the forum still
    /// offers.** Decision 25 is the first half — an empty picker plus one new tick is a silent
    /// unsubscribe from the other eight. Decision 26 is the second: a board the forum no longer
    /// lists cannot be ticked, so a press drops it and nothing says so, because the honest reading
    /// is that the forum stopped offering it and Cancel still loses nothing.
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
        boardsRefusal = nil
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
            let offer = try await joiner(for: host).boards(of: source)
            guard mine == errand else { return }
            let offered = Set(offer.boards.map(\.fid))
            stage = .choosingBoards(offer, from: .joined(
                subscribed: source.boards,
                ticked: Set(source.boards.map(\.fid)).intersection(offered)
            ))
        } catch let error where Cancellation.happened(error) {
            progressHost = ""
        } catch {
            // One sentence, in the row the reader pressed. Which failure it was does not change
            // what they can do about it — press again — so it does not change what they are told.
            guard mine == errand else { return }
            boardsRefusal = (host: host, key: "account.source.boards.unread")
        }
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
        case .browsing, .previewing, .choosingBoards, nil:
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
        // The question has been answered, so nothing is pending any more — set before the awaits,
        // so no dialog state outlives the decision it was asking about. `remove`'s own line, for
        // its reason. Unconditional, because `remove` reaches this too and a Remove answered while
        // a Clear was pending would otherwise leave that Clear's question standing over a row that
        // has gone.
        clearing = nil
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
    func signOut(host: String) async {
        await forums.forget(host: host.lowercased())
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
        if boardsRefusal?.host == host { boardsRefusal = nil }
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
        switch await forums.signIn(host: host) {
        case .signedIn:
            // The automatic path. The row learns of it from the cookie the forum just set,
            // read here rather than left to the store's notification so it is in place now.
            await forums.readReached()
            signingIn = nil
            offerSignIn = nil
        case .handOver(let stop):
            signingIn = ForumSignInRequest(host: host, stop: stop)
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
    /// whole errand**. So this says no. It is quiet and it is not silent — the forum's session
    /// cookie is in the store, `ForumSessions` reads it from there and is observed, and the row's toggle is drawn from
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
        // The forum's own page set its session cookie; the row reads it off the store, which
        // says so itself — this only asks sooner.
        Task { [forums] in await forums.readReached() }
        // The row's errand, and it is finished: drawn by the toggle that reads the store. Asked before the field is written, because writing the field is
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
