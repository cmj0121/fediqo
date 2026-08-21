import Foundation
import FediqoCore

/// Native localisation, with one addition: the language can be overridden inside the app.
///
/// Strings live in `Resources/Localizable.xcstrings`, which the build compiles into the
/// usual `.lproj` folders. Following the system language needs nothing but `Bundle.module`;
/// overriding it is a matter of resolving the `.lproj` for the chosen language and reading
/// from that instead.
@MainActor
enum L10n {
    private(set) static var bundle: Bundle = .module

    static func use(_ language: AppLanguage) {
        switch language {
        case .system:
            bundle = .module
        case .english, .traditionalChinese:
            bundle = lproj(named: language.rawValue) ?? .module
        }
    }

    private static func lproj(named code: String) -> Bundle? {
        // zh-TW is written as zh-Hant in some builds; try the obvious spellings in order.
        let candidates: [String]
        switch code {
        case "zh-TW": candidates = ["zh-TW", "zh-Hant", "zh_TW"]
        default: candidates = [code]
        }
        for candidate in candidates {
            if let path = Bundle.module.path(forResource: candidate, ofType: "lproj"), let found = Bundle(path: path) {
                return found
            }
        }
        return nil
    }
}

/// Every user-facing string in the app comes through here.
@MainActor
func t(_ key: String) -> String {
    L10n.bundle.localizedString(forKey: key, value: key, table: nil)
}

@MainActor
func t(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: t(key), arguments: arguments)
}
