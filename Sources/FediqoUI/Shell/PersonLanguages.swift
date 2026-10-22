import FediqoCore
import Foundation

/// What a person's page says of the languages of their posts that reach the reader's Home
/// (#378), as values a test reads without drawing them.
///
/// **Every language has one spelling: nothing chosen.** The source takes an empty choice so, and
/// a source that says nothing of it delivers every language; the row says "every language"
/// for both, and choosing none sends that.
enum PersonLanguagesWords {
    /// The glyph of the row, and of its act.
    static let symbol = "character.bubble"

    /// The languages this device knows by a two-letter code (ISO 639-1): what is chosen among
    /// where the source has not said its own. Named at drawing, in the reader's language.
    static let known: [FollowLanguage] = Locale.LanguageCode.isoLanguageCodes
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLowercase) }
        .map { FollowLanguage(code: $0, name: $0) }

    /// A language's name in the reader's language: as this device names its code, else as the
    /// source named it, else the code itself.
    static func name(_ code: String, offered: [FollowLanguage], language: DummyLanguage? = nil) -> String {
        if let named = L10n.locale(language).localizedString(forLanguageCode: code), named != code { return named }
        if let said = offered.first(where: { $0.code == code })?.name, !said.isEmpty { return said }
        return code
    }

    /// The row as About draws it: what is chosen, named.
    struct Row: Equatable {
        /// The codes chosen, in the order the source keeps them: none, every language.
        let codes: [String]
        let offered: [FollowLanguage]

        /// What is chosen, in words: every language, or the names joined.
        func state(language: DummyLanguage? = nil) -> String {
            guard !codes.isEmpty else { return L10n.t("person.languages.all", language: language) }
            return codes.map { PersonLanguagesWords.name($0, offered: offered, language: language) }
                .joined(separator: L10n.t("people.row.between", language: language))
        }

        /// The row as it is written and read: what it is, and what is chosen.
        func words(language: DummyLanguage? = nil) -> String {
            String(
                format: L10n.t("person.narrow.said", language: language),
                PersonActing.name(.chooseLanguages, language: language), state(language: language)
            )
        }
    }

    /// The languages to choose among, named and in the order of their names, narrowed to those
    /// whose name or code holds `find` — **with what is chosen first**, whatever is typed, so a
    /// choice is never hidden by a search.
    static func choices(
        _ offered: [FollowLanguage], chosen: Set<String>, find: String, language: DummyLanguage? = nil
    ) -> [Choice] {
        let key = find.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = offered.map { Choice(code: $0.code, name: name($0.code, offered: offered, language: language), said: $0.name) }
        let locale = L10n.locale(language)
        let sorted = named.sorted { $0.name.compare($1.name, locale: locale) == .orderedAscending }
        let matches = sorted.filter { choice in
            key.isEmpty || [choice.name, choice.said, choice.code].contains {
                $0.range(of: key, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
            }
        }
        // A code chosen that the source did not offer still shows, so it can be taken off.
        let unoffered = chosen.subtracting(offered.map(\.code)).sorted()
            .map { Choice(code: $0, name: name($0, offered: offered, language: language), said: $0) }
        return unoffered + sorted.filter { chosen.contains($0.code) } + matches.filter { !chosen.contains($0.code) }
    }

    /// One language to choose: its code, its name in the reader's language, and the source's.
    struct Choice: Equatable, Identifiable {
        let code: String
        let name: String
        let said: String

        var id: String { code }
    }

    static func title(language: DummyLanguage? = nil) -> String {
        PersonActing.name(.chooseLanguages, language: language)
    }

    static func all(language: DummyLanguage? = nil) -> String {
        L10n.t("person.languages.all", language: language)
    }

    static func find(language: DummyLanguage? = nil) -> String {
        L10n.t("person.languages.find", language: language)
    }

    static func keep(language: DummyLanguage? = nil) -> String {
        L10n.t("person.languages.keep", language: language)
    }

    /// What a pointer and a listener are told the row's press does, and where.
    static func hint(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("person.languages.hint", language: language), host)
    }

    /// Whether a language is chosen, in words: nothing of it is said by a checkmark alone.
    static func chosen(_ on: Bool, language: DummyLanguage? = nil) -> String {
        L10n.t(on ? "person.languages.chosen" : "person.languages.unchosen", language: language)
    }
}
