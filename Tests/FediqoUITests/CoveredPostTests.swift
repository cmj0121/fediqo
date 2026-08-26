import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// What an author covered, and who gets to uncover it.
///
/// The band itself is drawn rather than decided, so what these hold is the rule behind it: one
/// answer for the words and the media both, a standing preference, and a per-post decision that
/// beats it in either direction and is never written down.
@Suite("A post behind its warning")
@MainActor
struct CoveredPostTests {
    private func post(spoiler: String? = nil, sensitive: Bool? = nil) -> Post {
        Post(uri: "https://one.example/api/v1/statuses/a", socialProtocol: .mastodon,
             sourceURL: "https://one.example", createdAt: Date(timeIntervalSince1970: 100),
             authorId: "https://one.example/@a", authorName: "A", authorHandle: "@a@one.example",
             text: "the words", attachments: [Attachment(kind: .image, url: URL(string: "https://one.example/1.jpg"))],
             sensitive: sensitive, spoiler: spoiler)
    }

    @Test("Told, told-nothing and never-told are three different states")
    func threeStates() {
        // Told: there is a line to draw and media to cover.
        #expect(post(spoiler: "spoilers").spoiler == "spoilers")
        #expect(post(sensitive: true).sensitive == true)
        // Told, and there was nothing to tell.
        #expect(post(spoiler: "", sensitive: false).spoiler == "")
        #expect(post(spoiler: "", sensitive: false).sensitive == false)
        // Never told — which a screen may not read as either of the other two, and which is
        // every post stored before there was anywhere to keep the answer.
        #expect(post().spoiler == nil)
        #expect(post().sensitive == nil)
    }

    @Test("The preference is the standing answer, and it is off to begin with")
    func theStandingAnswer() {
        let app = freshApp("covered-preference")
        #expect(app.preferences.showSensitive == false)
        app.preferences.showSensitive = true
        #expect(app.preferences.showSensitive)
        // And it is one switch: nothing anywhere holds a second one for the words alone.
        #expect(Preferences(defaults: scratch("covered-fresh")).showSensitive == false)
    }

    @Test("Starting again puts the warnings back up")
    func resettingRestoresTheWarnings() async throws {
        let preferences = Preferences(defaults: scratch("covered-reset"))
        preferences.showSensitive = true
        let app = AppState(preferences: preferences, serverStore: EmptyServerStore(),
                           store: try LocalStore.inMemory())
        await app.startAgain()
        #expect(app.preferences.showSensitive == false)
    }
}
