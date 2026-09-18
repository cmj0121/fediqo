import Foundation

/// Strings from this module's bundle. English is the development language; 繁體中文 is `zh-TW`.
enum L10n {
    nonisolated(unsafe) static var language: DummyLanguage = .system

    static func t(_ key: String, language: DummyLanguage? = nil) -> String {
        let lang = language ?? Self.language
        return NSLocalizedString(key, bundle: bundle(for: lang), value: key, comment: "")
    }

    /// A count in a sentence, **singular where the count is one**: `key.one` for one, `key`
    /// otherwise, each formatted with the count. Every language carries both keys; one without a
    /// grammatical number (繁體中文) says the same thing in both.
    static func count(_ key: String, _ value: Int, language: DummyLanguage? = nil) -> String {
        String(format: t(value == 1 ? key + ".one" : key, language: language), value)
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

    /// A count, shortened, **in the shell's language rather than the device's**.
    ///
    /// `.formatted` with no locale follows the system, and this app lets the reader pick a language
    /// the device is not set to — so on a `zh-TW` machine with the shell in English this returned
    /// "9.1萬" and the line read "9.1萬 posts". One sentence in two languages, on all three surfaces
    /// that draw a figure: the directory's rows, the preview, and the source row. They share this
    /// one function, which is why there is one fix and not three.
    ///
    /// `language` is threaded rather than read off a global at the point of use, and resolves the
    /// same way `t(_:language:)` does — nothing means the shell's current language. A `static func`
    /// has no environment to ask, and the answer must not be allowed to differ from the one the
    /// surrounding string came back in.
    ///
    /// **Here rather than on `JoinSheet`, where it was written, or on `SourcePreviewView`, where
    /// it was nearly moved.** It is a pure locale-bound formatter with no relationship to a
    /// preview, a sheet or a row — hanging it off *any* view is what made the first placement
    /// wrong, and moving it to a second view would have repeated the mistake with a shorter reach.
    /// It is the number half of what `locale(_:)` above is the rule for, and it belongs beside it.
    /// Its three callers are three different surfaces — the directory's rows inside the sheet,
    /// `SourcePreviewView.figurePieces`, and through that the source row — which is why no one of
    /// them is its home.
    static func compact(_ value: Int, language: DummyLanguage? = nil) -> String {
        value.formatted(.number.notation(.compactName).locale(locale(language)))
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
