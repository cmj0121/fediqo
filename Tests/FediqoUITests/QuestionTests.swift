import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Every question before an undoable act says what will happen in one line (#238).
///
/// What a test can reach: that each question is one short line with the rest of what it used to
/// say behind its (?), that a loss always has a way out and is never answered by the usual key,
/// and that every word it says is in all three languages. What it cannot: the sheet drawn on a Mac
/// and a phone, which `ShellPiecesTests` draws for the card itself.
@Suite("A question before an undoable act says one line")
@MainActor
struct QuestionTests {
    /// Every question and notice, as each screen asks it, in `language`.
    private static func all(_ language: DummyLanguage) -> [ShellConfirmation] {
        [
            ShellQuestion.remove(host: "a.example", boards: 0, language: language),
            ShellQuestion.remove(host: "a.example", boards: 3, language: language),
            ShellQuestion.remove(host: "a.example", boards: 0, postsStay: true, language: language),
            ShellQuestion.remove(host: "a.example", boards: 3, postsStay: true, language: language),
            ShellQuestion.signIn(host: "a.example", language: language),
            ShellQuestion.dropCopies(language: language),
            ShellQuestion.shorten(months: 6, language: language),
            ShellQuestion.shorten(months: 1, language: language),
            ShellQuestion.letGo(posts: 4, places: 0, language: language),
            ShellQuestion.letGo(posts: 4, places: 2, language: language),
            ShellQuestion.letGo(posts: 0, places: 2, language: language),
            ShellQuestion.letGo(SpanAsk(posts: 3, from: Date(), to: Date(), host: nil), language: language),
            ShellQuestion.letGo(SpanAsk(posts: 1, from: Date(), to: Date(), host: "a.example"), language: language),
            ShellQuestion.removeTimeline(named: "Art", language: language),
            ShellQuestion.tighten(room: 250_000_000, language: language),
            ShellQuestion.clearAccount(language: language),
            ShellQuestion.storeNewer(language: language),
            ShellQuestion.signedOut(hosts: ["a.example", "b.example"], language: language),
            ShellQuestion.takeAway(
                PackageWeight(withoutPictures: 40_000_000, withPictures: 1_300_000_000, free: 0, holdsStore: true),
                language: language
            ),
            ShellQuestion.readBack(carried, held: false, language: language),
            ShellQuestion.readBack(carried, held: true, language: language),
            ShellQuestion.carryRefused(.package(.altered), language: language),
            ShellQuestion.carryRefused(.noRoom(needed: 2_000_000, free: 1_000), language: language),
            ShellQuestion.carryDone(.readBack(carried), language: language),
            ShellQuestion.nearbyAsk(.init(offer: nearby, peer: "a tablet", held: false, receiving: true), language: language),
            ShellQuestion.nearbyAsk(.init(offer: nearby, peer: "a tablet", held: true, receiving: true), language: language),
            ShellQuestion.nearbyAsk(.init(offer: nearby, peer: "a tablet", held: false, receiving: false), language: language),
            ShellQuestion.nearbyRefused(.notAllowed, language: language),
            ShellQuestion.nearbyMark("AB12", peer: "a tablet", language: language),
            ShellQuestion.nearbyRefused(.wrongCode, language: language),
            ShellQuestion.nearbyDone(carried, peer: "a tablet", language: language),
        ] + clearKeys.map { ShellQuestion.clear(host: "a.example", detailKey: $0, language: language) }
    }

    /// What a take-away says it holds, as #252's question is asked from it.
    private static let carried = PackageSummary(
        sources: [.init(host: "a.example", kind: .mastodon), .init(host: "b.example", kind: .discuz)],
        posts: 12, timelines: 2, takenAt: Date(timeIntervalSince1970: 1_800_000_000), withPictures: true,
        bytes: 3_000, hasSecrets: true, device: "a laptop", appVersion: "0.7.0", entryCount: 5
    )

    /// What a device nearby offers, as both screens' question is asked from it.
    private static let nearby = NearbyOffer(id: "o", summary: carried, fileBytes: 3_100)

    private static let clearKeys = [
        SourceRow.clearDetailKey(hasPassword: false, reachedSignIn: false),
        SourceRow.clearDetailKey(hasPassword: false, reachedSignIn: true),
        SourceRow.clearDetailKey(hasPassword: true, reachedSignIn: true),
    ]

    @Test("Each says one short line, and never repeats it behind its (?)",
          arguments: [DummyLanguage.english, .taiwanese])
    func oneLine(_ language: DummyLanguage) {
        for question in Self.all(language) {
            #expect(!question.line.isEmpty && !question.line.contains("\n"))
            #expect(!question.line.contains("%"), "\(question.line) was left unformatted")
            #expect(question.line.count <= 70, "\(question.line) is more than a line")
            if question.warns { #expect(question.choices.contains { $0.role == .destructive }) }
            #expect(question.help != question.line)
            if let help = question.help { #expect(help.count > question.line.count) }
        }
    }

    @Test("What each question said at length is behind its (?), word for word")
    func theRestIsKept() {
        let english = DummyLanguage.english
        #expect(ShellQuestion.remove(host: "a", boards: 0, language: english).help == nil)
        #expect(ShellQuestion.remove(host: "a", boards: 3, language: english).help
            == String(format: L10n.t("account.remove.detail.boards", language: english), 3))
        #expect(ShellQuestion.signIn(host: "a", language: english).help
            == L10n.t("account.signin.ask.detail", language: english))
        #expect(ShellQuestion.dropCopies(language: english).help == L10n.t("prefs.drop.copies.detail", language: english))
        #expect(ShellQuestion.shorten(months: 6, language: english).help
            == L10n.t("prefs.keep.shorten.detail", language: english))
        #expect(ShellQuestion.shorten(months: 6, language: english).title
            == L10n.count("prefs.keep.shorten.title", 6, language: english))
        #expect(ShellQuestion.letGo(posts: 4, places: 2, language: english).help
            == GoneSection.askDetail(posts: 4, places: 2, language: english))
        #expect(ShellQuestion.letGo(posts: 4, places: 2, language: english).title
            == GoneSection.askLine(4, places: 2, language: english))
        #expect(ShellQuestion.storeNewer(language: english).help == L10n.t("store.newer.detail", language: english))
        let ended = ShellQuestion.signedOut(hosts: ["a.example"], language: english)
        #expect(ended.line.contains("a.example") && ended.help?.contains("a.example") == true)
        for key in Self.clearKeys {
            let clear = ShellQuestion.clear(host: "a", detailKey: key, language: english)
            #expect(clear.help == L10n.t(key, language: english))
        }
    }

    @Test("Clear's line names a saved password's going, and says what comes back where nothing else goes")
    func clearSaysWhatDoesNotComeBack() {
        let lines = Self.clearKeys.map { ShellQuestion.clear(host: "a", detailKey: $0, language: .english).line }
        #expect(Set(lines).count == 3)
        #expect(lines[2].contains("password"))
        #expect(lines[0].contains("come back"))
        #expect(lines[1].contains("signed out"))
    }

    @Test("A loss always has a way out, is chorded only by ⌘D, and a notice has only its one press")
    func answeredOnlyOnPurpose() {
        for question in Self.all(.english) {
            #expect(question.cancel != nil, "\(question.title) has no way out")
            #expect(question.firstFocus == ShellConfirmCard.cancelFocus)
            if question.warns { #expect(question.chorded?.role == .destructive) }
        }
        let notice = ShellQuestion.storeNewer(language: .english)
        #expect(notice.choices.isEmpty && notice.cancel == L10n.t("store.newer.ok", language: .english))
        #expect(ShellQuestion.signedOut(hosts: ["a"], language: .english).choices.isEmpty)
    }

    @Test("Clear is a plain press answered by ⌘Return, except where a saved password goes")
    func clearWeighsItsAct() {
        for key in Self.clearKeys.prefix(2) {
            let clear = ShellQuestion.clear(host: "a", detailKey: key, language: .english)
            #expect(!clear.warns)
            #expect(clear.chorded?.role == .keyed)
            #expect(ShellConfirmChord.chord(for: .keyed).key == .return)
        }
        let password = ShellQuestion.clear(host: "a", detailKey: Self.clearKeys[2], language: .english)
        #expect(password.warns)
        #expect(password.chorded?.role == .destructive)
    }

    @Test("Remove with boards names, on its line, the boards that do not come back")
    func removeNamesTheBoards() {
        #expect(ShellQuestion.remove(host: "a", boards: 3, language: .english).line.contains("3 boards"))
        #expect(ShellQuestion.remove(host: "a", boards: 3, language: .taiwanese).line.contains("3"))
        #expect(!ShellQuestion.remove(host: "a", boards: 0, language: .english).line.contains("boards"))
    }

    @Test("Signing in offers reading first, neither lit, and a key answers only with reading")
    func signInChoices() {
        let question = ShellQuestion.signIn(host: "a", language: .english)
        #expect(question.choices.map(\.id) == [ShellQuestion.signInRead, ShellQuestion.signInWrite])
        #expect(question.choices.map(\.role) == [.keyed, .plain])
        #expect(question.chorded?.id == ShellQuestion.signInRead)
        #expect(!question.warns)
    }

    @Test("Every new line is in all three languages")
    func stringsInEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let keys = [
            "withdraw.line", "store.newer.line", "account.signin.ask.line", "account.mastodon.ended.line",
            "prefs.drop.copies.line", "prefs.keep.shorten.line", "prefs.gone.ask.line", "prefs.span.ask.line",
            "prefs.gone.ask.line.places", "prefs.gone.ask.line.placesonly", "account.remove.line.boards",
            "account.remove.line.stay", "account.remove.line.stay.boards", "confirm.destructive.hint",
        ] + Self.clearKeys.map(ShellQuestion.clearLineKey)
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in keys { #expect(strings.contains("\"\(key)\" = "), "\(lproj) is missing \(key)") }
        }
    }
}
