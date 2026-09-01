import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// What the inbox screen has to get right before anybody looks at it.
@Suite("The inbox, and what the system was told about it")
@MainActor
struct NoticeScreenTests {
    /// iOS refuses to schedule a refresh task whose identifier is not in the app's
    /// `BGTaskSchedulerPermittedIdentifiers` — quietly, at run time, in a message nobody
    /// reads. The string is therefore in two files, and this is what holds them identical.
    @Test("The task the app schedules is the task the app declared")
    func theIdentifierIsDeclared() throws {
        let yaml = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(yaml.contains("BGTaskSchedulerPermittedIdentifiers: [\(AppState.noticeRefresh)]"))
        // And only on the phone. A Mac app that is open is already listening, and one that is
        // closed is not running for anybody to wake.
        #expect(yaml.components(separatedBy: "BGTaskSchedulerPermittedIdentifiers").count == 2)
    }

    /// The repository root, found by walking up from this file rather than written down — a
    /// checkout is somewhere different on every machine.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
        }
        return URL(fileURLWithPath: ".")
    }()

    @Test("Every kind of notice has a face, and no two share one")
    func everyKindIsDrawable() {
        let faces = NoticeKind.allCases.map(\.symbolName)
        #expect(faces.allSatisfy { !$0.isEmpty })
        #expect(Set(faces).count == NoticeKind.allCases.count)
    }

    /// Every notice is a fraction of a second late. Saying so on every row would be noise
    /// standing where a fact should be.
    @Test("Lateness is shown when it means something and not before")
    func latenessHasAThreshold() {
        #expect(NoticeRow.worthSaying == 60)
        #expect(NoticeRow.spelled(120).contains("2"))
        // Past an hour, minutes are a number a reader has to do arithmetic on.
        #expect(NoticeRow.spelled(2 * 3600).contains("2"))
    }

    /// The screen has to say why a notice can be late, in both languages, or #9's third line
    /// is not met — and a reader whose app has gone quiet is left thinking it is broken.
    ///
    /// Read out of `Localizable.xcstrings` rather than through `t()`, and that is not a
    /// shortcut. SwiftPM copies that file into the resource bundle as it stands; only Xcode
    /// compiles it into the `.lproj` folders `localizedString` reads, so under `swift test`
    /// **every** key resolves to itself and a test written through `t()` would pass whether
    /// the wording existed or not. The file is the thing that has to be right.
    @Test("The screen says why they can be late, in both languages")
    func theScreenSaysWhy() throws {
        let wording = try Self.wording(for: "notices.why")
        #expect(wording["en"]?.count ?? 0 > 40)
        #expect(wording["zh-TW"]?.isEmpty == false)
    }

    @Test("Every kind of notice can be said in both languages")
    func everyKindIsSayable() throws {
        for kind in NoticeKind.allCases {
            let key = "notices.kind.\(kind.rawValue)"
            let wording = try Self.wording(for: key)
            #expect(wording["en"]?.isEmpty == false, "no English wording for \(key)")
            #expect(wording["zh-TW"]?.isEmpty == false, "no 繁體中文 wording for \(key)")
        }
    }

    /// What one key says, per language, straight out of the catalogue in the repository.
    private static func wording(for key: String) throws -> [String: String] {
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Sources/FediqoUI/Resources/Localizable.xcstrings"))
        let catalogue = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = catalogue?["strings"] as? [String: Any]
        guard let entry = strings?[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any] else {
            Issue.record("\(key) is not in Localizable.xcstrings at all")
            return [:]
        }
        return localizations.compactMapValues {
            (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }
}
