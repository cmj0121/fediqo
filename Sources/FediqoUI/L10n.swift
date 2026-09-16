import Foundation

/// Strings from this module's bundle. English is the development language; 繁體中文 is `zh-TW`.
enum L10n {
    nonisolated(unsafe) static var language: DummyLanguage = .system

    static func t(_ key: String, language: DummyLanguage? = nil) -> String {
        let lang = language ?? Self.language
        return NSLocalizedString(key, bundle: bundle(for: lang), value: key, comment: "")
    }

    /// The locale a **number or a date** should be formatted in: the shell's language, resolved by
    /// the same rule `t(_:language:)` resolves a string by.
    ///
    /// **A `FormatStyle` left to itself follows the system, and the system is not the shell.** This
    /// app lets the reader choose a language independently of the device, so on a `zh-TW` machine
    /// with the shell set to English `91000.formatted(.number.notation(.compactName))` returns
    /// "9.1萬" — and the screen then reads "9.1萬 posts", one sentence in two languages, which is
    /// what `DESIGN.md` §0 rule 3 asks for the opposite of. It reached three surfaces before
    /// anybody noticed: the directory's rows, the preview's figures, and the source row.
    ///
    /// Here rather than at a call site, because every one of those three had to get it right
    /// separately and none of them can see the shell's language without asking this type. The
    /// mapping itself is `DummyLanguage.locale`'s, which already exists and which
    /// `FediqoRootView` already hands to SwiftUI as `\.locale` — so what this adds is a way for
    /// code with no environment to ask the same question and get the same answer.
    static func locale(_ language: DummyLanguage? = nil) -> Locale {
        (language ?? Self.language).locale
    }

    static func bundle(for language: DummyLanguage) -> Bundle {
        guard let name = language.lprojName else { return .module }
        let candidates = [name, name.lowercased(), "zh-Hant", "zh-hant"]
        for candidate in candidates {
            if let path = Bundle.module.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path)
            {
                return bundle
            }
        }
        return .module
    }
}
