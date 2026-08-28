import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// The part of an action that is a screen's: who acts, what the row is told, and what happens
/// when there is nobody to act as. The steps after that are Core's and are tested there.
@Suite("What can be done with a post")
@MainActor
struct InteractionTests {
    private func post(_ uri: String = "a", from host: String = "one.example") -> Post {
        Post(uri: "https://\(host)/users/a/statuses/\(uri)", socialProtocol: .mastodon,
             sourceURL: "https://\(host)", createdAt: Date(timeIntervalSince1970: 100),
             authorId: "https://\(host)/users/a", authorName: "A", authorHandle: "@a@\(host)",
             text: "the words", sources: [host])
    }

    /// Nobody signed in anywhere is not a fault to hide: without an account there is no such
    /// thing as favouriting something, and the app says so rather than appearing to work.
    @Test("With no account there is nobody to act as, and the app says so")
    func nobodyToActAs() async {
        let app = freshApp("acting-none")
        #expect(app.actingChoices.isEmpty)
        #expect(await app.acting(on: post()) == nil)

        await app.act(.favourite, on: post())
        #expect(app.actionFailure != nil)
        // And nothing was written down about a thing that did not happen.
        #expect(app.marks(of: post()).areKnown == false)
    }

    /// Never-told is what an unpressed star means here, and it is not `false`. Nearly every
    /// read this app makes goes out as a stranger, and a stranger is told none of this.
    @Test("A post nobody has told us about is unmarked, not un-favourited")
    func neverTold() {
        let app = freshApp("acting-marks")
        let marks = app.marks(of: post())
        #expect(marks.favourited == nil)
        #expect(marks.reblogged == nil)
        #expect(marks.bookmarked == nil)
        #expect(app.isKept(post()) == false)
    }

    /// Two rules about one author, and the app can say which is which — which is the whole
    /// reason they are two rows in the store rather than one with a flag.
    @Test("A local mute and a server's are asked about separately")
    func mutesAreAskedAboutSeparately() {
        let app = freshApp("acting-mutes")
        let author = "https://one.example/users/a"
        #expect(app.isMuted(.author, author, onServer: false) == false)
        #expect(app.isMuted(.author, author, onServer: true) == false)

        app.mutes = [Mute(kind: .author, value: author, mutedAt: Date())]
        #expect(app.isMuted(.author, author, onServer: false))
        #expect(app.isMuted(.author, author, onServer: true) == false)

        app.mutes.append(Mute(kind: .author, value: author, serverURL: "https://one.example",
                              mutedAt: Date()))
        #expect(app.isMuted(.author, author, onServer: true))
        // A host of the same name is a different rule and is not answered by either.
        #expect(app.isMuted(.host, author, onServer: false) == false)
    }

    /// Off until asked. The request it permits is the one that tells somebody else what is
    /// being read, so it is not a default anybody arrives at by not looking.
    @Test("Letting your own server fetch a post to act on it is off to begin with")
    func fetchingIsOffUntilAsked() {
        let app = freshApp("acting-fetch")
        #expect(app.preferences.mayFetchToAct == false)
        #expect(app.preferences.actingServer == nil)
    }

    @Test("Everything else sits behind two headings, and neither is the other")
    func theTwoPages() {
        #expect(MoreActions.Page.allCases.map(\.rawValue) == ["general", "danger"])
        #expect(MoreActions.Page.general.titleKey == "post.more.general")
        #expect(MoreActions.Page.danger.titleKey == "post.more.danger")
    }

    /// Three marks, three answers. The row draws each from its own, so a boost must never
    /// leave a star looking pressed.
    @Test("Setting one mark leaves the other two alone", arguments: PostAction.allCases)
    func marksAreIndependent(action: PostAction) {
        let marks = PostMarks.unknown.setting(action, to: true)
        #expect(marks.value(of: action) == true)
        for other in PostAction.allCases where other != action {
            #expect(marks.value(of: other) == nil)
        }
    }
}

/// What the app says out loud about the last thing the reader asked for.
///
/// The mark moves before anybody's server has been asked, which is what makes a control that
/// answers immediately possible — and what makes this necessary: when the server disagrees the
/// mark goes back, and without these words a press that failed and a press that did nothing
/// look exactly alike.
@Suite("What is said about a press")
@MainActor
struct ActionNoticeTests {
    @Test("With nothing to report, nothing is said")
    func silence() {
        #expect(ActionNotice.saying(failure: nil, reachedOut: nil) == nil)
    }

    @Test("A failure is said, whichever failure it was")
    func aFailureIsSaid() {
        let failure = SourceFailure.needsSignIn("one.example")
        #expect(ActionNotice.saying(failure: failure, reachedOut: nil) == .wrong(failure))
    }

    /// The one moment this app tells somebody else what is being read. A reader who allowed
    /// it should watch it happen rather than find out from a changelog.
    @Test("A server asked to go and fetch the post is said too")
    func reachingOutIsSaid() {
        #expect(ActionNotice.saying(failure: nil, reachedOut: "one.example")
                == .reachedOut("one.example"))
    }

    /// Both standing means the request went out and then failed. "We told somebody else what
    /// you are reading" on its own would be the least useful half of that.
    @Test("Where both are standing, the failure is what gets said")
    func theFailureWins() {
        let failure = SourceFailure.tokenRejected("one.example")
        #expect(ActionNotice.saying(failure: failure, reachedOut: "one.example") == .wrong(failure))
    }

    /// A sentence with a hostname in it and something to do about it is given time to be read
    /// twice; a note about something that already happened is not worth covering a corner of
    /// the timeline for as long.
    @Test("A failure stands longer than a note")
    func aFailureStandsLonger() {
        let wrong = ActionNotice.Saying.wrong(.needsSignIn("one.example"))
        #expect(wrong.lasts > ActionNotice.Saying.reachedOut("one.example").lasts)
    }

    /// Whatever went wrong, it is said in the reader's own language — which is the whole
    /// reason `SourceFailure` carries a case rather than a sentence.
    @Test("Every failure has words of its own", arguments: [
        SourceFailure.needsSignIn("one.example"), .tokenRejected("one.example"),
        .unsupported(.mastodon), .badHost("nope"), .transport("no route"),
    ])
    func everyFailureHasWords(failure: SourceFailure) {
        #expect(!message(for: failure).isEmpty)
    }
}
