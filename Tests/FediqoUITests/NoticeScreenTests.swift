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
    static func wording(for key: String) throws -> [String: String] {
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

    // MARK: - when it last managed to ask (#9)

    /// Something the reader wrote, so there is an account for them to be signed in as: a
    /// signed-in account is a row that points at one, and `owned_accounts` will not hold a
    /// person nobody has seen write anything.
    static let written = Post(uri: "https://one.example/api/v1/statuses/1",
                              originURI: "https://one.example/users/a/statuses/1",
                              socialProtocol: .mastodon, sourceURL: "https://one.example",
                              createdAt: Date(timeIntervalSince1970: 100),
                              authorId: "https://one.example/@a", authorName: "A",
                              authorHandle: "@a@one.example", text: "hello")

    /// The line that makes an empty inbox readable. Without it "nothing has happened" and
    /// "nothing has been asked" are the same screen, and a reader cannot tell which they have.
    @Test("The screen says when it last managed to ask, in both languages")
    func theScreenSaysWhenItAsked() throws {
        for key in ["notices.asked", "notices.never", "notices.ask"] {
            let wording = try Self.wording(for: key)
            #expect(wording["en"]?.isEmpty == false, "no English wording for \(key)")
            #expect(wording["zh-TW"]?.isEmpty == false, "no 繁體中文 wording for \(key)")
        }
        // The time goes in the sentence, in both languages. A translation that dropped the
        // placeholder would draw the sentence without the one fact it is there to carry.
        let asked = try Self.wording(for: "notices.asked")
        #expect(asked["en"]?.contains("%@") == true)
        #expect(asked["zh-TW"]?.contains("%@") == true)
    }

    /// **The reason it is on disk.** A background wake asks, writes what it found, and the
    /// process is gone; a time held only in the model would have the next launch say it had
    /// never asked, on a morning when it had asked four times.
    @Test("A time one launch wrote down is shown by the next")
    func theTimeSurvivesALaunch() async throws {
        let defaults = scratch("notices-last-heard")
        let woken = Preferences(defaults: defaults)
        let asked = Date(timeIntervalSince1970: 1_700_000_000)
        woken.lastHeard = asked

        // A second launch, over the same disk, building the model the way the app does.
        let relaunched = NoticeModel(store: try LocalStore.inMemory(),
                                     tokens: TokenSource(store: try LocalStore.inMemory(),
                                                         secrets: InMemorySecretStore()),
                                     registry: SourceRegistry(clients: [:]),
                                     remembering: Preferences(defaults: defaults))
        #expect(relaunched.lastHeard == asked)
    }

    /// Nil is not a long time ago and it is not zero. A device that has never managed to ask
    /// says so in words, because a blank where a fact belongs gets read as one.
    @Test("A device that has never asked has no time to show")
    func neverAskedIsNotATime() async throws {
        let fresh = NoticeModel(store: try LocalStore.inMemory(),
                                tokens: TokenSource(store: try LocalStore.inMemory(),
                                                    secrets: InMemorySecretStore()),
                                registry: SourceRegistry(clients: [:]),
                                remembering: Preferences(defaults: scratch("notices-never")))
        #expect(fresh.lastHeard == nil)
    }

    /// **A quiet morning and a broken evening are different mornings.** A server that answered
    /// with nothing was still asked, and the time is written down; a server that refused was
    /// not, and it is not.
    @Test("A server that answered with nothing was still asked")
    func answeringNothingIsStillAnswering() async throws {
        let app = try await signedInApp("notices-quiet", posts: [Self.written],
                                        client: InboxDouble())
        #expect(app.notices?.lastHeard == nil)

        await app.askForNotices()

        #expect(app.notices?.lastHeard != nil)
    }

    @Test("A server nobody could reach is not a server this device asked")
    func refusedIsNotAsked() async throws {
        let app = try await signedInApp("notices-refused", posts: [Self.written],
                                        client: InboxDouble(refusing: true))

        await app.askForNotices()

        #expect(app.notices?.lastHeard == nil)
    }

    /// A fresh install has never asked anybody anything, so neither has a device somebody has
    /// just reset. The time is a record of what happened here, and nothing happened here.
    @Test("Starting again forgets when it last asked")
    func startingAgainForgets() {
        let preferences = Preferences(defaults: scratch("notices-reset"))
        preferences.lastHeard = Date()

        preferences.resetToDefaults()

        #expect(preferences.lastHeard == nil)
    }
}

/// A server with an inbox, which either answers or cannot be reached.
///
/// The two answers worth telling apart: one that hands over nothing — the commonest answer
/// there is — and one that never replies at all. They used to reach the screen as the same
/// zero.
final class InboxDouble: SourceClient, @unchecked Sendable {
    private let refusing: Bool

    init(refusing: Bool = false) { self.refusing = refusing }

    func notices(host: String, owner: String, after: String?, limit: Int,
                 token: String) async throws -> [Notice] {
        if refusing { throw SourceFailure.badHost(host) }
        return []
    }

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "", maxCharacters: 500)
    }
    func timeline(host: String, limit: Int, before: Post?, after: Post?, token: String?) async throws -> [Post] { [] }
    func home(host: String, limit: Int, before: Post?, after: Post?, token: String) async throws -> [Post] { [] }
    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }
    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        Conversation(post: post)
    }
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
}

/// The setting behind #97, and the wording that has to exist for it to be choosable.
@Suite("The reply setting, kept and said")
@MainActor
struct CarryMentionsSettingTests {
    /// The one nobody is surprised by. A fresh install that carried everybody would be this app
    /// speaking to eleven people on a reader's behalf before they had chosen anything.
    @Test("A fresh install carries the person being answered and nobody else")
    func theDefaultIsThem() {
        #expect(Preferences(defaults: scratch("carry-default")).carryMentions == .replied)
    }

    @Test("The choice survives a launch")
    func itSurvivesALaunch() {
        let defaults = scratch("carry-kept")
        Preferences(defaults: defaults).carryMentions = .everyone
        #expect(Preferences(defaults: defaults).carryMentions == .everyone)
    }

    @Test("Starting again goes back to the default")
    func startingAgainResets() {
        let preferences = Preferences(defaults: scratch("carry-reset"))
        preferences.carryMentions = .nobody

        preferences.resetToDefaults()

        #expect(preferences.carryMentions == .replied)
    }

    /// Every choice has to be sayable, or the control offers a reader a blank to pick.
    @Test("Every answer is written in both languages")
    func everyAnswerIsSayable() throws {
        var keys = ["settings.writing", "settings.carryMentions", "settings.carryMentions.body"]
        keys += CarriedMentions.allCases.map { "settings.carryMentions.\($0.rawValue)" }
        for key in keys {
            let wording = try NoticeScreenTests.wording(for: key)
            #expect(wording["en"]?.isEmpty == false, "no English wording for \(key)")
            #expect(wording["zh-TW"]?.isEmpty == false, "no 繁體中文 wording for \(key)")
        }
    }
}
