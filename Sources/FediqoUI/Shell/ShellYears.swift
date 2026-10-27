import FediqoCore
import Foundation
import Observation

/// The years a signed-in source looked back on for the person (#340), read as its page opens and
/// opened from there whole.
///
/// **Absent with no error** where the host has no such address: remembered for the run, and
/// nothing drawn — never a version string. A host that has the address and no year for the
/// person draws nothing either: nothing is said to be missing.
///
/// **Read with the reading part's `read:accounts`.** A sign-in without it is not offered the
/// year, and the place says the reading part's own sentence; signed out, it asks to sign in.
/// Held for the run alone; a read that fails says so and changes nothing.
@MainActor
@Observable
final class ShellYears {
    enum Reading: Equatable {
        case reading
        case read([YearLookedBack])
        case failed(String)
    }

    enum Offer: Equatable {
        case years(Reading?)
        case locked(String)
        case signIn(String)
    }

    private(set) var reading: [String: Reading] = [:]
    /// The hosts that said this run they have no such address.
    private(set) var absent: Set<String> = []

    func offer(host raw: String, in session: ShellSession) -> Offer? {
        let host = raw.lowercased()
        guard !absent.contains(host),
              let source = session.sources.first(where: { $0.host.lowercased() == host }), source.kind == .mastodon
        else { return nil }
        guard session.mastodon.isSignedIn(host: host) else {
            return .signIn(String(format: L10n.t("year.signIn"), source.host))
        }
        // A year is read with `read:accounts`, a word of reading's: a sign-in filed as holding less
        // of reading is not offered it, and says the reading part's own sentence.
        let scopes = session.mastodon.token(host: host)?.scopes
        let reads = scopes == nil || MastodonParts.holds(.reading, in: scopes) || MastodonParts.holdsEveryRead(in: scopes)
        if let place = session.mastodon.place(.reading, host: host) ?? (reads ? nil : PartWords.Place(kind: .unasked, key: "part.reading.unasked")) {
            let words = L10n.t(place.key)
            return .locked(words.contains("%@") ? String(format: words, source.host) : words)
        }
        return .years(reading[host])
    }

    func press(host: String, in session: ShellSession) {
        if session.mastodon.isSignedIn(host: host) {
            session.askFor([.reading], host: host)
        } else {
            session.askSignIn(host: host)
        }
    }

    /// The years read, as the source's page opens. Kept as they were where the read fails.
    func read(host raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        guard case .years = offer(host: host, in: session),
              let source = session.sources.first(where: { $0.host.lowercased() == host }),
              let door = session.mastodon.authorized(host: host, for: .yearsLookedBack)
        else { return }
        if reading[host] == nil { reading[host] = .reading }
        do {
            reading[host] = .read(try await MastodonYears(door: door).years(source: Source(host: host, kind: source.kind)))
        } catch MastodonHostMoreError.noSuchAddress {
            absent.insert(host)
            reading[host] = nil
        } catch {
            if Cancellation.happened(error) {
                if reading[host] == .reading { reading[host] = nil }
                return
            }
            reading[host] = .failed(String(format: L10n.t("year.failed"), source.host))
        }
    }

    // MARK: - Words

    static func title(_ year: YearLookedBack, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("year.title", language: language), String(year.year))
    }

    /// The kind of poster the source said the person was, in words where this build has them,
    /// and as the source said it otherwise.
    static func archetype(_ year: YearLookedBack, language: DummyLanguage? = nil) -> String? {
        guard let word = year.archetype, !word.isEmpty else { return nil }
        let key = "year.archetype." + word
        let said = L10n.t(key, language: language)
        return said == key ? String(format: L10n.t("year.archetype", language: language), word) : said
    }

    static func month(_ month: YearLookedBack.Month, language: DummyLanguage? = nil) -> String {
        var style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide)
        style.locale = L10n.locale(language)
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2001, month: month.month, day: 15))
        return String(
            format: L10n.t("year.month", language: language), date?.formatted(style) ?? String(month.month),
            L10n.grouped(month.posts, language: language), L10n.grouped(month.followers, language: language)
        )
    }

    static func tag(_ tag: YearLookedBack.Tag, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("year.tag", language: language), "#" + tag.name, L10n.grouped(tag.posts, language: language))
    }

    /// The posts it names, each under what it was most of.
    static func posts(_ year: YearLookedBack, language: DummyLanguage? = nil) -> [(title: String, words: String)] {
        [
            (L10n.t("year.post.boosted", language: language), year.mostBoosted),
            (L10n.t("year.post.answered", language: language), year.mostAnswered),
            (L10n.t("year.post.favourited", language: language), year.mostFavourited),
        ].compactMap { title, note in note.map { (title, LineText.oneLine($0.body, limit: 280)) } }
    }
}
