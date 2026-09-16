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

    /// The sheet the reader is being shown the forum's own page in, or nothing.
    var signingIn: ForumSignInRequest?

    /// A host that turned this app away and that a sign-in might open — set only where the
    /// server answered with a refusal of its own, which is the one failure that is never the
    /// reader's spelling. It closes a hole this branch recorded and left open: the refusal
    /// message "tells the reader what happened and offers them nothing to do about it".
    var offerSignIn: String?

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
        forums: ForumSessions = ForumSessions()
    ) {
        self.http = http
        self.store = store
        self.pictures = pictures
        self.emojis = emojis
        self.forums = forums
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
        } catch is CancellationError {
            return
        } catch {
            catalog = .failed
        }
    }

    func pick(_ server: CatalogServer) async {
        hostname = server.domain
        await add()
    }

    func add() async {
        guard !checking else { return }
        let raw = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        refuse = nil
        offerSignIn = nil
        let parsed: String
        do {
            parsed = try Host.parse(raw)
        } catch {
            refuse = String(format: L10n.t("account.refuse.unknown"), raw)
            return
        }
        progressHost = parsed
        if isAdded(parsed) {
            refuse = L10n.t("account.refuse.duplicate")
            return
        }
        checking = true
        defer { checking = false }
        do {
            try await SourceJoin(http: joiner(for: parsed), store: store, catalogues: emoji)
                .join(host: raw)
            sources = await store.sources()
            notes = await store.all()
            if queries.isEmpty {
                queries = [DummyTimeline(id: "all"), DummyTimeline(id: "trends")]
                timelineID = "all"
            }
        } catch is CancellationError {
            return
        } catch let error as JoinError {
            refuse = Self.refuseMessage(error, raw: raw, host: parsed)
            // A refusal is the one failure where the host is fine, the spelling is fine, and
            // this app was turned away on purpose — which is exactly the case a reader with an
            // account can do something about. Offered only for that one, so that a typo or a
            // dead server never invites somebody to go and sign in to nothing.
            if case .refused = error { offerSignIn = parsed }
        } catch {
            refuse = L10n.t("account.refuse.network")
        }
    }

    /// Which client a join reads through: the browser engine where this reader has already
    /// signed in to that host, and the ordinary one everywhere else.
    ///
    /// **It has to be the engine, and nothing else can stand in for it.** A host behind an
    /// interactive challenge cannot be read by `URLSessionClient` at all — not with a different
    /// agent, not with a copied cookie. The challenge is cleared by a person in a browser, and
    /// the only thing holding what that produced is the engine they cleared it in. Reading a
    /// second time through anything else gets the challenge back.
    ///
    /// **`hasEngine` rather than `transport`**, because `transport(host:)` would *build* one: a
    /// reader adding an ordinary microblog would silently start a web process for a host that
    /// never needed it, and this app does not spend a reader's battery on a maybe.
    private func joiner(for host: String) -> any HTTPClient {
        forums.hasEngine(host: host) ? forums.transport(host: host) : http
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
    func clear(host: String) async {
        let host = host.lowercased()
        await emoji.forget(host: host)
        emojis.forget(host: host)
        pictures.forget(host: host)
        await forums.forget(host: host)
        cleared += 1
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
    func signInFinished(reached: Bool) {
        signingIn = nil
        if reached { offerSignIn = nil }
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
