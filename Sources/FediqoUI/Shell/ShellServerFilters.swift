import FediqoCore
import Foundation
import Observation

/// The person's filters at each signed-in source, read and tended from the source's page (#338).
///
/// **The server's, and never a rule.** Listed, made, changed and removed there, through the
/// filters part; a timeline's rules are not sent to it, and none of its filters becomes a rule.
/// **What a post says a filter caught is drawn wherever the post is** (`serverFilter(over:)`):
/// hidden, naming the filter, or covered with its name and opened on asking.
///
/// **Read when the page opens and after each change, and held for the run alone**: nothing of the
/// list is written down. A source that refuses or fails says so where the list is, and nothing on
/// this device changes for it.
@MainActor
@Observable
final class ShellServerFilters {
    enum Reading: Equatable {
        case reading
        case read([ServerFilter])
        case failed(String)
    }

    /// What the source's page offers.
    enum Offer: Equatable {
        case list(Reading?)
        /// Signed in without the filters part, or with half of it: the part's own sentence, and
        /// its press asks for it.
        case locked(String)
        /// Not signed in: the sentence, and the press asks to sign in with filters ticked.
        case signIn(String)
    }

    private(set) var reading: [String: Reading] = [:]
    /// What the last act at a source could not do, said under its list.
    private(set) var refused: [String: String] = [:]
    /// The acts on their way, by host.
    private(set) var busy: Set<String> = []
    /// How many times each host's state was let go (`forget`): a read begun before lands nowhere.
    @ObservationIgnored private var epochs: [String: Int] = [:]
    /// The post whose sheet of filters is up (#439), or nothing.
    private(set) var filtering: PostUnderFilters?
    /// The filter whose sheet of posts is up (#439), or nothing.
    private(set) var readingPosts: FilterPosts?

    /// A post a sheet of the person's filters is open on.
    struct PostUnderFilters: Identifiable, Equatable {
        /// The row the press was on.
        let row: String
        /// The row of the copy at the source that is asked, and that copy's id there.
        let copy: String
        let statusID: String
        let host: String
        /// Its opening words, as a line of ours says them.
        let opening: String

        var id: String { row }
    }

    /// The posts a filter names by themselves, as its sheet shows them.
    struct FilterPosts: Identifiable, Equatable {
        struct Line: Identifiable, Equatable {
            let post: FilteredPost
            /// Who wrote it and how it opens; nothing where its source no longer gives it.
            var who: String?
            var opening: String?

            var id: String { post.id }
        }

        let filterID: String
        let title: String
        let host: String
        var lines: [Line] = []
        var reading = true
        /// The posts could not be read: a line with no words then says nothing of its post.
        var unread = false

        var id: String { host + "\n" + filterID }
    }

    /// Nothing for a source with no filters of the person's — any but a Mastodon.
    func offer(host raw: String, in session: ShellSession) -> Offer? {
        let host = raw.lowercased()
        guard let source = session.sources.first(where: { $0.host.lowercased() == host }), source.kind == .mastodon else {
            return nil
        }
        guard session.mastodon.isSignedIn(host: host) else {
            return .signIn(String(format: L10n.t("filters.signIn"), source.host))
        }
        if let place = session.mastodon.place(.filters, host: host) {
            let words = L10n.t(place.key)
            return .locked(words.contains("%@") ? String(format: words, source.host) : words)
        }
        return .list(reading[host])
    }

    /// The press on the dim line: the filters part asked for where a sign-in is held, and the
    /// read-or-act question with filters ticked where none is — each saying what more is asked
    /// before the source's page opens.
    func press(host: String, in session: ShellSession) {
        if session.mastodon.isSignedIn(host: host) {
            session.askFor([.filters], host: host)
        } else {
            _ = session.askSignIn(host: host, ticking: [.filters])
        }
    }

    private func filters(_ host: String, in session: ShellSession) -> MastodonFilters? {
        session.mastodon.authorized(host: host, for: .filters).map(MastodonFilters.init(door:))
    }

    /// The list read again, as the page opens. Kept as it was where the read fails.
    func read(host raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        guard case .list = offer(host: host, in: session), let filters = filters(host, in: session) else { return }
        let had = reading[host]
        let asked = epochs[host, default: 0]
        if had == nil { reading[host] = .reading }
        do {
            let read = try await filters.list()
            guard epochs[host, default: 0] == asked else { return }
            // The same list again leaves every row as it was drawn.
            guard reading[host] != .read(read) else { return }
            reading[host] = .read(read)
            lookups[host] = Lookup(read)
        } catch {
            guard epochs[host, default: 0] == asked else { return }
            if Cancellation.happened(error) {
                reading[host] = had
                return
            }
            reading[host] = .failed(Self.said(error, host: host))
        }
    }

    /// The source said its filters changed (#427): the list read again where it was read this run.
    /// A list not read is read as its page opens.
    func heard(host raw: String, in session: ShellSession) async {
        guard reading[raw.lowercased()] != nil else { return }
        await read(host: raw, in: session)
    }

    /// Fediqo came back to the front (#461): each of `hosts` — the sources whose line is held — has
    /// its list read once, whether or not its page was opened. **A source does not say on its line
    /// that a filter changed** (#427), so a filter changed in another client meanwhile applies to
    /// what is held here as soon as the person is back (`current`), not at the next whole read.
    func cameForward(hosts: Set<String>, in session: ShellSession) async {
        await withTaskGroup(of: Void.self) { group in
            for host in hosts.sorted() {
                group.addTask { await self.read(host: host, in: session) }
            }
        }
    }

    /// `hits` as `host`'s list read last says each filter is now (#461): one the source no longer
    /// has stands no more, one changed stands as it is now — its title, its action, where it applies
    /// and until when — and one naming the post `statusID` by itself stands over it. Unchanged where
    /// the list was not read this run.
    ///
    /// **No word is matched here** (`ServerFilter`): a keyword added elsewhere reaches a post when
    /// the source next sends it, saying itself what caught it.
    func current(_ hits: [ServerFilterHit], host raw: String, statusID: String?) -> [ServerFilterHit] {
        let host = raw.lowercased()
        guard case .read? = reading[host], let known = lookups[host] else { return hits }
        var standing = hits.compactMap { known.byID[$0.filterID] }
        if let statusID {
            for hit in known.byPost[statusID] ?? [] where !standing.contains(where: { $0.filterID == hit.filterID }) {
                standing.append(hit)
            }
        }
        return standing
    }

    /// One source's list, by filter and by the posts named: made as the list is read, not as a row
    /// is drawn.
    private struct Lookup {
        var byID: [String: ServerFilterHit] = [:]
        var byPost: [String: [ServerFilterHit]] = [:]

        init(_ filters: [ServerFilter]) {
            for filter in filters {
                let hit = ServerFilterHit(
                    filterID: filter.id, title: filter.title, action: filter.action, context: filter.context, expiresAt: filter.expiresAt
                )
                byID[filter.id] = hit
                for post in filter.posts { byPost[post.statusID, default: []].append(hit) }
            }
        }
    }

    /// The lookup of each list in `reading`, kept beside it.
    @ObservationIgnored private var lookups: [String: Lookup] = [:]

    /// One act on a source's filters, then the list read again. What it could not do is said, and
    /// nothing changes here for it.
    private func act(_ host: String, in session: ShellSession, _ body: (MastodonFilters) async throws -> Void) async -> Bool {
        let host = host.lowercased()
        guard let filters = filters(host, in: session), !busy.contains(host) else { return false }
        busy.insert(host)
        defer { busy.remove(host) }
        refused[host] = nil
        let asked = epochs[host, default: 0]
        do {
            try await body(filters)
        } catch {
            if !Cancellation.happened(error), epochs[host, default: 0] == asked { refused[host] = Self.said(error, host: host) }
            return false
        }
        guard epochs[host, default: 0] == asked else { return false }
        await read(host: host, in: session)
        return true
    }

    @discardableResult
    func make(_ draft: ServerFilterDraft, host: String, in session: ShellSession) async -> Bool {
        await act(host, in: session) { _ = try await $0.make(draft) }
    }

    @discardableResult
    func change(_ filter: ServerFilter, to draft: ServerFilterDraft, host: String, in session: ShellSession) async -> Bool {
        await act(host, in: session) { _ = try await $0.change(filter, to: draft) }
    }

    /// Asked first by the page: this is the yes.
    @discardableResult
    func remove(_ filter: ServerFilter, host: String, in session: ShellSession) async -> Bool {
        await act(host, in: session) { try await $0.remove(filter) }
    }

    /// What was read as whoever was signed in at `host` let go: they left, somebody new came, or
    /// the source went. Its sheets close, and an answer on its way lands nowhere (`epochs`).
    func forget(host: String) {
        epochs[host.lowercased(), default: 0] += 1
        reading[host.lowercased()] = nil
        lookups[host.lowercased()] = nil
        refused[host.lowercased()] = nil
        if filtering?.host == host.lowercased() { filtering = nil }
        if readingPosts?.host == host.lowercased() { readingPosts = nil }
    }

    // MARK: - One post (#439)

    /// The filters as the post's sheet draws them, once read.
    func filters(at host: String) -> [ServerFilter]? {
        if case .read(let filters)? = reading[host.lowercased()] { return filters }
        return nil
    }

    /// The sheet put up on `item`'s post, and the filters read for it: whose they are says which
    /// hold the post already.
    func open(on item: DummyItem, in session: ShellSession) {
        let post = item.isReblog ? item.reblogged.first ?? item : item
        guard let id = post.statusID else { return }
        let host = post.source.host.lowercased()
        refused[host] = nil
        filtering = PostUnderFilters(row: item.id, copy: post.id, statusID: id, host: host, opening: LineText.oneLine(post.body, limit: 80))
        Task { await read(host: host, in: session) }
    }

    func closePost() { filtering = nil }

    /// Puts the post under `filter`, or takes it out where it is under it already: **the source
    /// first**. What it refuses or fails is said, and nothing here moves. After its yes the post is
    /// read again, so what it now says of it is what the post's row is drawn by, here as on its
    /// pages; and a warning opened this run is closed, where it is one of its own making.
    func turn(_ filter: ServerFilter, for asked: PostUnderFilters, in session: ShellSession) async {
        let place = filter.place(of: asked.statusID)
        let done = await act(asked.host, in: session) { filters in
            if let place {
                try await filters.takeOut(place)
            } else {
                _ = try await filters.put(asked.statusID, under: filter)
            }
        }
        guard done else { return }
        if place == nil { session.shownAnyway.remove(asked.row) }
        await readAgain(row: asked.copy, host: asked.host, in: session)
    }

    /// What the source now says of the post held in `row`. It took the act, so a read lost now
    /// says that alone: the post is drawn as it was until it is next read.
    private func readAgain(row: String, host: String, in session: ShellSession) async {
        guard let held = session.note(ofRow: row), let door = session.mastodon.authorized(host: host, for: .filters) else { return }
        do {
            try await session.reach.write(door, landingIn: session.store).readAgain(held)
            await session.reloadFromStore()
        } catch {
            if !Cancellation.happened(error) { refused[host] = String(format: L10n.t("filters.post.unread"), host) }
        }
    }

    /// The sheet of the posts `filter` names by themselves, each read for who wrote it and how it
    /// opens. **A post the source no longer gives stays a line of its own**, which can be taken out.
    func openPosts(of filter: ServerFilter, at raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        var sheet = FilterPosts(filterID: filter.id, title: filter.title, host: host)
        sheet.lines = filter.posts.map { .init(post: $0) }
        readingPosts = sheet
        guard let filters = filters(host, in: session),
              let source = session.sources.first(where: { $0.host.lowercased() == host })
        else {
            readingPosts?.reading = false
            return
        }
        let asked = epochs[host, default: 0]
        var read: [String: Note] = [:]
        var failure: (any Error)?
        do {
            read = try await filters.posts(filter.posts.map(\.statusID), source: source)
        } catch {
            failure = error
        }
        // Written onto the sheet as it stands now: a line taken out meanwhile stays out.
        guard readingPosts?.id == sheet.id, epochs[host, default: 0] == asked else { return }
        readingPosts?.reading = false
        if let failure {
            readingPosts?.unread = true
            if !Cancellation.happened(failure) { refused[host] = Self.said(failure, host: host) }
            return
        }
        for index in readingPosts?.lines.indices ?? 0..<0 {
            guard let id = readingPosts?.lines[index].post.statusID, let note = read[id] else { continue }
            readingPosts?.lines[index].who = note.handle
            readingPosts?.lines[index].opening = LineText.oneLine(note.body, limit: 80)
        }
    }

    func closePosts() { readingPosts = nil }

    /// Takes a line's post out of the filter its sheet is on, the source first; and, where this
    /// device holds the post, reads it again so it is treated as it was before.
    func takeOut(_ line: FilterPosts.Line, in session: ShellSession) async {
        guard let host = readingPosts?.host else { return }
        guard await act(host, in: session, { try await $0.takeOut(line.post) }) else { return }
        readingPosts?.lines.removeAll { $0.id == line.id }
        guard let held = session.notes.first(where: { $0.source.host == host && $0.statusID == line.post.statusID }) else { return }
        await readAgain(row: held.key.rowID, host: host, in: session)
    }

    private static func said(_ error: any Error, host: String) -> String {
        switch error {
        case let refusal as MastodonFilterRefused:
            refusal.said ?? String(format: L10n.t("filters.refused"), host)
        case MastodonAuthError.http(403), MastodonAuthError.http(401):
            String(format: L10n.t("filters.notAllowed"), host)
        default:
            String(format: L10n.t("filters.failed"), host)
        }
    }

    // MARK: - Words

    static func actionName(_ action: ServerFilterAction, language: DummyLanguage? = nil) -> String {
        switch action {
        case .warn: L10n.t("filters.action.warn", language: language)
        case .hide: L10n.t("filters.action.hide", language: language)
        case .blur: L10n.t("filters.action.blur", language: language)
        case .unknown(let word): word
        }
    }

    static func placeName(_ place: String, language: DummyLanguage? = nil) -> String {
        let key = "filters.place." + place
        let said = L10n.t(key, language: language)
        return said == key ? place : said
    }

    /// What one filter's row says under its name: what it does, where, with which words, until when.
    static func line(_ filter: ServerFilter, language: DummyLanguage? = nil) -> String {
        let places = ServerFilter.places.filter(filter.context.contains).map { placeName($0, language: language) }
        var parts = [actionName(filter.action, language: language), places.joined(separator: ", ")]
        let words = filter.keywords.map(\.keyword)
        if !words.isEmpty { parts.append(words.joined(separator: ", ")) }
        if filter.statuses > 0 { parts.append(L10n.count("filters.posts", filter.statuses, language: language)) }
        if let until = filter.expiresAt {
            parts.append(String(
                format: L10n.t("filters.until", language: language),
                until.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale(language)))
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// How long a filter made or changed may last, in seconds; nothing for for good.
    static let lastings: [Int?] = [nil, 1800, 3600, 21_600, 43_200, 86_400, 604_800]

    static func lastingName(_ seconds: Int?, language: DummyLanguage? = nil) -> String {
        guard let seconds else { return L10n.t("filters.lasts.always", language: language) }
        if seconds == ServerFilterDraft.unchanged { return L10n.t("filters.lasts.unchanged", language: language) }
        return L10n.t("filters.lasts.\(seconds)", language: language)
    }
}

extension ShellSession {
    /// What `item`'s `…` offers of its filters (#439): nothing but on a post at a source that has
    /// them, with somebody signed in there; dim with the part's lock where the sign-in lacks it,
    /// its press asking.
    func postFilterOffer(on item: DummyItem) -> ItemActing.PostFilter? {
        let post = item.isReblog ? item.reblogged.first ?? item : item
        let host = post.source.host
        guard post.statusID != nil, post.goneSince == nil, sources.first(where: { $0.host == host })?.kind == .mastodon,
              mastodon.isSignedIn(host: host)
        else { return nil }
        guard let place = mastodon.place(.filters, host: host) else {
            return ItemActing.PostFilter(lock: nil) { [weak self] in
                guard let self else { return }
                self.serverFilters.open(on: item, in: self)
            }
        }
        return ItemActing.PostFilter(lock: ItemActing.Lock(place: place, host: host)) { [weak self] in
            _ = self?.askFor([.filters], host: host)
        }
    }

    /// The filter of the person's at `item`'s source that stands over it where a timeline shows
    /// it (#338), as its source said: a hiding one always, a warning not opened this run.
    /// Nothing where this device is not applying a source's filters (#406). The hit stays on
    /// the post, and no source is asked.
    ///
    /// **As the list read last says each filter is now** (#461, `ShellServerFilters.current`).
    func serverFilter(over item: DummyItem, at now: Date = Date(), applied: Bool = true) -> ServerFilterHit? {
        guard applied else { return nil }
        let post = postOf(item)
        let hits = serverFilters.current(item.serverFiltered, host: post.source.host, statusID: post.statusID)
        guard let hit = hits.standing(in: ServerFilterHit.timelines, at: now) else { return nil }
        if hit.action != .hide, shownAnyway.contains(item.id) { return nil }
        return hit
    }
}
