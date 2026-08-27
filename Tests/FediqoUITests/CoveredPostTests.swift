import Foundation
import SwiftUI
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

    /// `s`, and only the bare `s`. `⌘s` belongs to the menu bar wherever a Mac user reads it,
    /// and while a draft has the keyboard the letter is the draft's — the same gate every
    /// other single key goes through, asked here so this one cannot quietly skip it.
    @Test("`s` is what asks, and it asks nothing through a draft or the menu bar")
    func theKey() {
        #expect(KeyCommand.from("s", modifiers: [], typing: false) == .toggleCover)
        #expect(KeyCommand.from("s", modifiers: [], typing: true) == nil)
        #expect(KeyCommand.from("s", modifiers: [.command], typing: false) == nil)
        #expect(KeyCommand.from("s", modifiers: [.shift], typing: false) == nil)
        #expect(KeyCommand.listened.contains("s"))
    }

    /// A letter is ours whatever it did, so a press on a post with nothing covered is
    /// swallowed rather than handed back to beep — the same rule `m` on a deck of one follows.
    @Test("A press is kept whether or not there was anything to lift")
    func theKeyIsAlwaysOurs() {
        #expect(KeyCommand.consumes(spelledWith: "s", did: false))
        #expect(KeyCommand.consumes(spelledWith: "s", did: true))
    }

    /// Three states again, from the key's side: told there is something, told there is
    /// nothing, and never told. Only the first is a post the key has anything to do on.
    @Test("The key has something to do only where the author covered something")
    func whatTheKeyActsOn() {
        #expect(post(spoiler: "spoilers").hidesSomething)
        #expect(post(sensitive: true).hidesSomething)
        #expect(post(spoiler: "spoilers", sensitive: true).hidesSomething)
        #expect(post(spoiler: "", sensitive: false).hidesSomething == false)
        #expect(post().hidesSomething == false)
    }

    /// The app counts the presses and says nothing about which way the row will go: the row
    /// holds this reader's answer about this post, and a second holder would be a second
    /// answer. Nothing is written down, which is the whole point — a reading record is what
    /// this app does not keep.
    @Test("The app counts the asking, and only where there is something to ask about")
    func theAppCountsPresses() {
        let app = freshApp("covered-key")
        #expect(app.mediaCovers == 0)
        #expect(app.perform(.toggleCover) == false)
        #expect(app.mediaCovers == 0)
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
