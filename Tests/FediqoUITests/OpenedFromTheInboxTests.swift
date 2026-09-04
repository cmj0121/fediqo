import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// Opening something from the inbox (#123).
///
/// The overlays are views and are not asserted here. What is asserted is the part that was
/// missing underneath them: a notice names who did it rather than carrying their profile, so
/// opening one has to build a subject out of a handle and the server whose inbox it arrived in.
@Suite("Opening what reached you")
@MainActor
struct OpenedFromTheInboxTests {
    @Test("A notice about somebody opens their page, on the server it arrived from")
    func anoticeOpensAPerson() {
        let app = freshApp("inbox-opens-person")
        app.openPerson("@ines@birch.example", on: "https://cedar.example")
        let subject = app.person?.subject
        #expect(subject?.handle == "@ines@birch.example")
        // The inbox it arrived in, which is a server the reader has an account on — so it is
        // one they already read, and not somewhere new to go.
        #expect(subject?.host == "cedar.example")
    }

    /// The server arrives as the URL `post_origins` keeps, not as a bare host, and a page asked
    /// of `https://cedar.example` is a page asked of nowhere.
    @Test("The server is read out of the address the inbox carries")
    func theserverIsRead() {
        let app = freshApp("inbox-opens-host")
        for spelling in ["https://cedar.example", "https://cedar.example/", "cedar.example"] {
            app.closePerson()
            app.openPerson("@ines@birch.example", on: spelling)
            #expect(app.person?.subject.host == "cedar.example", "\(spelling)")
        }
    }

    /// Opening the same person twice is the same page, not a second one built over the first —
    /// which is what would have happened to a reader pressing a row they were already looking at.
    @Test("The same person twice is the same page")
    func thesameTwice() {
        let app = freshApp("inbox-opens-once")
        app.openPerson("@ines@birch.example", on: "https://cedar.example")
        let first = app.person
        app.openPerson("@ines@birch.example", on: "https://cedar.example")
        #expect(app.person === first)
    }
}
