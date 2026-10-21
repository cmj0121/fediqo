import FediqoCore
import Foundation

/// What a post sent later, and the list of what waits, say (#333, X0 §2 and §6) — functions of
/// what is known, so a test reads what is drawn and what VoiceOver hears.
@MainActor
enum LaterWords {
    /// A moment as the list and the strip say it: the day and the minute, in the shell's language.
    static func when(_ at: Date, language: DummyLanguage? = nil) -> String {
        at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(L10n.locale(language)))
    }

    /// The first time a picker offers: the first the source would take by this device's clock —
    /// the outbox judges again by the source's own as it sends (`MastodonLater.sendable`).
    static func earliest() -> Date { MastodonLater.earliest() }

    /// Where a new time to send starts: an hour from now, at the next five minutes.
    static func start(now: Date = Date()) -> Date {
        let hour = now.addingTimeInterval(3600).timeIntervalSince1970
        return Date(timeIntervalSince1970: (hour / 300).rounded(.up) * 300)
    }

    /// The line under the time to send.
    static func line(host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("compose.later.line", language: language), host)
    }

    /// What the host said when it would not take what was asked, in its own words, where it
    /// said any.
    static func words(of error: any Error) -> String? {
        guard let refused = error as? MastodonUnprocessable,
              let said = try? JSONSerialization.jsonObject(with: refused.body) as? [String: Any],
              let words = said["error"] as? String, !words.isEmpty
        else { return nil }
        return LineText.oneLine(words, limit: 200)
    }

    /// A time come too near by the source's clock, moved forward, as a press on the list says it.
    static func movedForward(host: String, to at: Date, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("waiting.movedForward", language: language), host, when(at, language: language))
    }

    /// What a press on the list could not do, in a sentence.
    static func missed(_ error: any Error, host: String, language: DummyLanguage? = nil) -> String {
        if case MastodonLaterError.tooSoon(let earliest) = error {
            return String(format: L10n.t("waiting.tooSoon", language: language), host, when(earliest, language: language))
        }
        if let words = words(of: error) {
            return String(format: L10n.t("outbox.later.refused", language: language), host, words)
        }
        if error is MastodonScopeError {
            return String(format: L10n.t("waiting.refused", language: language), host)
        }
        return String(format: L10n.t("waiting.missed", language: language), host)
    }

    /// One waiting post's second line: that it quotes a post, its files and its poll, where it
    /// has them.
    static func carries(_ post: WaitingPost, language: DummyLanguage? = nil) -> String? {
        var parts: [String] = []
        if post.quoting != nil { parts.append(L10n.t("waiting.quote", language: language)) }
        if !post.media.isEmpty { parts.append(String(format: L10n.t("waiting.files", language: language), post.media.count)) }
        if post.poll != nil { parts.append(L10n.t("waiting.poll", language: language)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Who may read it, in the composer's word.
    static func reach(_ post: WaitingPost, language: DummyLanguage? = nil) -> String? {
        post.audience.map { L10n.t(ComposerSheet.visibilityKey($0), language: language) }
    }

    /// One row as VoiceOver reads it: when it goes, who may read it, its first words, what it
    /// carries (X0 §5).
    static func spoken(_ post: WaitingPost, language: DummyLanguage? = nil) -> String {
        [
            String(format: L10n.t("waiting.goes", language: language), when(post.at, language: language)),
            reach(post, language: language), OutboxWords.opening(post.text), carries(post, language: language),
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The pair's band: why both wait, and that the one before lost its files where it did.
    static func pair(_ pair: ShellLater.Pair, language: DummyLanguage? = nil) -> String {
        var line = L10n.t(pair.new == nil ? "waiting.pair.unknown" : "waiting.pair", language: language)
        if pair.lostMedia { line += " " + L10n.t("waiting.pair.lostMedia", language: language) }
        return line
    }
}

extension ShellSession {
    /// The time to send at `host` (#333), where its kind of source sends later: offered where the
    /// sign-in holds the writing part, dim with the lock's words where it does not.
    func laterSlot(host: String) -> DraftControls.LaterSlot? {
        guard sources.first(where: { $0.host == host })?.kind.offers.sendsLater == true else { return nil }
        guard mastodon.standing(.acting, host: host) != .held else { return DraftControls.LaterSlot() }
        let place = mastodon.place(.acting, host: host) ?? PartWords.Place(kind: .none, key: "part.ask.partly")
        return DraftControls.LaterSlot(locked: String(format: L10n.t(place.key), host))
    }

    /// The line on one's own page's About at `host` that opens what waits there (X0 §2), or
    /// nothing where the page is not the reader's own, or the source sends nothing later.
    func waitingEntry(of who: DummyPerson) -> WaitingEntry? {
        guard sources.first(where: { $0.host == who.host })?.kind.offers.sendsLater == true,
              ShellPersonPages.own(at: who.host, in: self)?.id == who.id
        else { return nil }
        return WaitingEntry(host: who.host, locked: laterSlot(host: who.host)?.locked)
    }
}

/// The way to what waits at a source, on the reader's own page there (X0 §2): its words, or the
/// lock's where the sign-in lacks what it needs — then dim, and a press asks.
struct WaitingEntry: Equatable {
    let host: String
    var locked: String?

    static let id = "about.waiting"

    @MainActor
    func words(language: DummyLanguage? = nil) -> String {
        locked ?? L10n.t("waiting.entry", language: language)
    }
}
