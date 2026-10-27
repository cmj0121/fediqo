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
        if had == nil { reading[host] = .reading }
        do {
            reading[host] = .read(try await filters.list())
        } catch {
            if Cancellation.happened(error) {
                reading[host] = had
                return
            }
            reading[host] = .failed(Self.said(error, host: host))
        }
    }

    /// One act on a source's filters, then the list read again. What it could not do is said, and
    /// nothing changes here for it.
    private func act(_ host: String, in session: ShellSession, _ body: (MastodonFilters) async throws -> Void) async -> Bool {
        let host = host.lowercased()
        guard let filters = filters(host, in: session), !busy.contains(host) else { return false }
        busy.insert(host)
        defer { busy.remove(host) }
        refused[host] = nil
        do {
            try await body(filters)
        } catch {
            if !Cancellation.happened(error) { refused[host] = Self.said(error, host: host) }
            return false
        }
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

    func forget(host: String) {
        reading[host.lowercased()] = nil
        refused[host.lowercased()] = nil
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
    /// The filter of the person's at `item`'s source that stands over it where a timeline shows
    /// it (#338), as its source said: a hiding one always, a warning not opened this run.
    func serverFilter(over item: DummyItem, at now: Date = Date()) -> ServerFilterHit? {
        guard let hit = item.serverFiltered.standing(in: ServerFilterHit.timelines, at: now) else { return nil }
        if hit.action != .hide, shownAnyway.contains(item.id) { return nil }
        return hit
    }
}
