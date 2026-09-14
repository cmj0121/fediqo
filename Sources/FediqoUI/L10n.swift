import Foundation

/// Strings from this module's bundle. English is the development language; 繁體中文 is `zh-TW`.
enum L10n {
    nonisolated(unsafe) static var language: DummyLanguage = .system

    static func t(_ key: String, language: DummyLanguage? = nil) -> String {
        let lang = language ?? Self.language
        return NSLocalizedString(key, bundle: bundle(for: lang), value: key, comment: "")
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
