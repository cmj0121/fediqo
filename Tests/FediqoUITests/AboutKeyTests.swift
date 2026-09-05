import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// Reaching what a post can tell you about itself without a pointer (#126).
@Suite("The key to a post's own page")
@MainActor
struct AboutKeyTests {
    @Test("i is the key, and it is nobody else's")
    func iistheKey() {
        #expect(KeyCommand.from("i", modifiers: [], typing: false) == .aboutPost)
        // Not while somebody is writing: every letter is a letter in a draft.
        #expect(KeyCommand.from("i", modifiers: [], typing: true) == nil)
    }

    /// **One key in and out.** The page is a thing you look at and stop looking at, and a second
    /// key for closing would be a second thing to know.
    @Test("Pressed again it closes")
    func pressedAgain() {
        let app = freshApp("about-key")
        let post = makePost("https://a.example/1")
        app.expand(post)

        #expect(app.perform(.aboutPost))
        #expect(app.about != nil)
        #expect(app.perform(.aboutPost))
        #expect(app.about == nil)
    }

    /// With nothing opened there is no post to be told about, and the press is handed back
    /// rather than kept for nothing.
    @Test("With no post in front of the reader it does nothing")
    func nothingOpened() {
        let app = freshApp("about-key-nothing")
        #expect(!app.perform(.aboutPost))
        #expect(app.about == nil)
    }

    /// `Tab` belongs to the page in front of the reader. Rotating a rail page's tabs underneath
    /// an open one would be moving something they cannot see.
    @Test("Tab moves between the two lists while the page is up")
    func tabMovesTheLists() {
        let app = freshApp("about-key-tabs")
        app.expand(makePost("https://a.example/2"))
        app.perform(.aboutPost)

        #expect(app.about?.tab == .favourited)
        #expect(app.perform(.nextTab))
        #expect(app.about?.tab == .boosted)
        #expect(app.perform(.previousTab))
        #expect(app.about?.tab == .favourited)
    }

    /// And it goes back to being the page's own the moment the page is closed.
    @Test("Closing it gives Tab back to the page underneath")
    func tabGoesBack() {
        let app = freshApp("about-key-tabs-back")
        app.railItem = .inbox
        app.expand(makePost("https://a.example/3"))
        app.perform(.aboutPost)
        app.perform(.nextTab)
        #expect(app.inboxTab == .notices, "the inbox must not have moved under it")

        app.perform(.aboutPost)
        #expect(app.perform(.nextTab))
        #expect(app.inboxTab == .talks)
    }
}
