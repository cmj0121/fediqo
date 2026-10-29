import Foundation
import Testing

/// Every table, held against every other at once — where each page's own check holds only the
/// few words it draws.
///
/// English is the development language and carries every key. 繁體中文 carries every key but
/// a count's singular (`key.one`), which `L10n.count` falls back from; a key missing anywhere
/// else is a line that reads as its key. `zh-Hant` is the same bytes as `zh-TW`, kept for a
/// system that asks for the script rather than the region. What the system itself shows before
/// the app draws anything — the reason it asks for the local network — is in the app's own
/// tables, beside the code that runs it.
struct LanguageTablesTests {
    private static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static func table(_ path: String) throws -> [String: String] {
        let url = root.appending(path: path)
        let plist = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String], "\(path) is not a table of strings")
    }

    private static func ui(_ language: String) throws -> [String: String] {
        try table("Sources/FediqoUI/Resources/\(language).lproj/Localizable.strings")
    }

    /// The format specifiers a line carries, in order of their argument: `%1$@` and `%@` alike.
    private static func specifiers(_ line: String) -> [String] {
        let pattern = /%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?([@dDuUxXoOfeEgGcCsSp])/
        let found = line.replacing("%%", with: "").matches(of: pattern)
        let ordered = found.enumerated().map { index, match in (match.1.flatMap { Int($0) } ?? index + 1, String(match.2)) }
        return ordered.sorted { $0.0 < $1.0 }.map(\.1)
    }

    @Test("Every English key is in 繁體中文 but a count's singular, and 繁體中文 has none of its own")
    func sameKeys() throws {
        let english = try Self.ui("en"), taiwanese = try Self.ui("zh-TW")
        // A `.one` with no `key` beside it is a line of its own ("only on %@"), not a singular,
        // and 繁體中文 needs it like any other.
        let singular = { (key: String) in key.hasSuffix(".one") && english[String(key.dropLast(4))] != nil }
        let missing = Set(english.keys).subtracting(taiwanese.keys).filter { !singular($0) }
        #expect(missing.isEmpty, "missing in zh-TW: \(missing.sorted())")
        let extra = Set(taiwanese.keys).subtracting(english.keys)
        #expect(extra.isEmpty, "only in zh-TW: \(extra.sorted())")
    }

    @Test("A line takes the same arguments in both languages")
    func sameArguments() throws {
        let english = try Self.ui("en"), taiwanese = try Self.ui("zh-TW")
        for (key, line) in taiwanese {
            let source = try #require(english[key])
            #expect(Self.specifiers(line) == Self.specifiers(source), "\(key)")
        }
    }

    @Test("The two Chinese tables are the same bytes")
    func hantIsTaiwanese() throws {
        let resources = Self.root.appending(path: "Sources/FediqoUI/Resources")
        let taiwanese = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwanese == hant)
    }

    @Test("What the system asks for on the app's behalf is said in every language the app claims")
    func theSystemsQuestions() throws {
        let project = try String(contentsOf: Self.root.appending(path: "project.yml"), encoding: .utf8)
        let claimed = project.components(separatedBy: "\n").filter { $0.contains("CFBundleLocalizations: [en, zh-TW]") }
        #expect(claimed.count == 2, "both apps claim en and zh-TW")
        let english = try Self.table("Apps/Shared/en.lproj/InfoPlist.strings")
        let taiwanese = try Self.table("Apps/Shared/zh-TW.lproj/InfoPlist.strings")
        let asked = project.components(separatedBy: "\n").compactMap { line -> (String, String)? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("NS"), trimmed.contains("UsageDescription: ") else { return nil }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return (parts[0], parts[1])
        }
        #expect(!asked.isEmpty)
        for (key, words) in asked {
            #expect(english[key] == words, "\(key): en says what project.yml says")
            let chinese = try #require(taiwanese[key], "\(key) is missing in zh-TW")
            #expect(chinese != words, "\(key) is not yet in 繁體中文")
        }
        #expect(Set(english.keys) == Set(taiwanese.keys))
    }
}
