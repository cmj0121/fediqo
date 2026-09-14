import Foundation

/// Strings from this module's bundle. English is the development language; 繁體中文 is `zh-TW`.
enum L10n {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, value: key, comment: "")
    }
}
