import Foundation
import Testing

@testable import FediqoCore
@testable import FediqoUI

/// The signed-in transport, as far as a package test can reach it.
///
/// **What is not here, and why it is not here.** A `WKWebView` is a second process with a render
/// surface, and nothing in a Swift package can run a view body or put a window on screen — so the
/// fetch itself, the cookie store, the Keychain and a browser check clearing are all verified by
/// running the app, not here. What is here is every decision that is a decision rather than a
/// framework call: which addresses this transport will go to, what a Clear reaches, when a reader
/// is offered a sign-in, and that every way a sign-in can stop has a sentence in every language.
@MainActor
@Suite("The signed-in transport")
struct ForumTransportTests {
    // MARK: - Where a signed-in session may be spent

    /// The rule that stops a forum's session leaving the forum.
    @Test("A host-scoped transport goes to its own host and nowhere else")
    func hostScoping() {
        let host = "bbs.example.org"
        #expect(ForumWebEngine.belongs(URL(string: "https://bbs.example.org/forum.php")!, to: host))
        #expect(ForumWebEngine.belongs(URL(string: "https://BBS.EXAMPLE.ORG/forum.php")!, to: host))
        // A forum routinely redirects between the two spellings of itself, so these are one host.
        #expect(ForumWebEngine.belongs(URL(string: "https://www.bbs.example.org/x")!, to: host))
        #expect(ForumWebEngine.belongs(URL(string: "https://bbs.example.org/x")!, to: "www.bbs.example.org"))
        // And these are not. A signed-in jar sent here is the reader's forum credentials
        // leaving the forum.
        #expect(!ForumWebEngine.belongs(URL(string: "https://evil.example/x")!, to: host))
        #expect(!ForumWebEngine.belongs(URL(string: "https://bbs.example.org.evil.example/x")!, to: host))
        #expect(!ForumWebEngine.belongs(URL(string: "https://other.bbs.example.org/x")!, to: host))
        #expect(!ForumWebEngine.belongs(URL(string: "about:blank")!, to: host))
    }

    @Test("Decision 9's rule reaches this wire boundary too")
    func schemeRuleIsTheSameRule() {
        // The transport refuses before it ever loads, under the same definition
        // `URLSessionClient` refuses under — forwarded, not copied. See `Host.allowsFetch`.
        #expect(!Host.allowsFetch(URL(string: "http://bbs.example.org/forum.php")!))
        #expect(!Host.allowsFetch(URL(string: "file:///etc/passwd")!))
        #expect(!Host.allowsFetch(URL(string: "javascript:alert(1)")!))
        #expect(Host.allowsFetch(URL(string: "https://bbs.example.org/forum.php")!))
    }

    // MARK: - What the reader is told

    /// The first convention this branch earned: a harness enumerates rather than hand-listing.
    @Test("Every way a sign-in can stop has a sentence, in every language the app ships")
    func everyStopHasASentence() {
        for stop in ForumSignInStop.allKinds {
            for language in [DummyLanguage.english, .taiwanese] {
                let key = stop.explanationKey
                let text = L10n.t(key, language: language)
                #expect(text != key, "\(key) has no \(language.labelKey) sentence")
                #expect(!text.isEmpty)
            }
        }
    }

    @Test("Every stop gets its own sentence, so none of them says another's")
    func stopsAreNotShared() {
        let keys = ForumSignInStop.allKinds.map(\.explanationKey)
        #expect(Set(keys).count == keys.count, "two stops share one sentence")
    }

    /// D23's whole substance, pinned as text rather than as intent.
    @Test("The two honest sentences differ, and only the opted-in one says the app holds it")
    func theHonestSentenceChanges() {
        for language in [DummyLanguage.english, .taiwanese] {
            let off = L10n.t("forum.signin.save.off", language: language)
            let on = L10n.t("forum.signin.save.on", language: language)
            #expect(off != "forum.signin.save.off", "the before sentence is missing")
            #expect(on != "forum.signin.save.on", "the after sentence is missing")
            #expect(off != on, "the sentence does not change when the promise does")
        }
        // Said in those words, in the development language, rather than implied.
        let off = L10n.t("forum.signin.save.off", language: .english)
        let on = L10n.t("forum.signin.save.on", language: .english)
        #expect(off.localizedCaseInsensitiveContains("never sees your password"))
        #expect(on.localizedCaseInsensitiveContains("will see your password"))
        #expect(on.localizedCaseInsensitiveContains("Keychain"))
        #expect(on.localizedCaseInsensitiveContains("iCloud"), "the sentence does not say where it will not go")
    }

    /// The pane's own doc warns against exactly this: a true-looking sentence that is false.
    @Test("The cache footer stops claiming nothing is written to disk, now that something is")
    func theFooterIsNoLongerALie() {
        // "None of this is written to disk" was true when three memory caches were all this
        // section listed. A saved password is in the Keychain, and a footer that denies it sits
        // directly under a row saying a password is held — the reader is told two opposite
        // things at once and one of them is this app's own promise.
        for language in [DummyLanguage.english, .taiwanese] {
            let footer = L10n.t("prefs.cache.footer", language: language)
            #expect(footer != "prefs.cache.footer")
            let names = language == .english ? ["exception", "Keychain"] : ["例外", "鑰匙圈"]
            for name in names {
                #expect(footer.contains(name),
                        "the \(language.labelKey) footer does not own up to the one thing it keeps")
            }
        }
    }

    @Test("The sheet's own lines and the Preferences lines are translated too")
    func everyNewStringIsTranslated() {
        let keys = [
            "account.refuse.signin", "account.refuse.signin.label",
            "forum.signin.title", "forum.signin.web.label", "forum.signin.save",
            "forum.signin.cancel", "forum.signin.done",
            "prefs.password.held", "prefs.password.forget", "prefs.password.forget.label",
        ]
        for key in keys {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key,
                        "\(key) is missing from \(language.labelKey)")
            }
        }
    }

    // MARK: - What a Clear reaches

    /// D25.
    @Test("One press drops the cookies and the saved password with everything else")
    func clearReachesTheForum() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: "bbs.example.org", username: "u", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)

        #expect(forums.hasPassword(host: "bbs.example.org"), "the premise did not hold")
        await session.clear(host: "BBS.Example.ORG")
        #expect(!forums.hasPassword(host: "bbs.example.org"), "the saved password survived a Clear")
        #expect(try credentials.credential(host: "bbs.example.org") == nil,
                "it is gone from the screen but still in the store")
        #expect(session.cleared == 1)
    }

    @Test("A Clear on a host with nothing held is still a Clear, and stands no browser up")
    func clearingNothingIsSafe() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        await session.clear(host: "never.seen.example")
        #expect(!forums.hasEngine(host: "never.seen.example"),
                "a Clear started a web process for a server it was emptying")
        #expect(session.cleared == 1)
    }

    @Test("Clearing one server leaves another server's password where it is")
    func clearIsPerServer() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: "one.example", username: "a", password: "p1"))
        try credentials.save(ForumCredential(host: "two.example", username: "b", password: "p2"))
        let forums = ForumSessions(credentials: credentials)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)

        await session.clear(host: "one.example")
        #expect(!forums.hasPassword(host: "one.example"))
        #expect(forums.hasPassword(host: "two.example"), "a Clear reached a server it was not for")
    }

    /// The narrower affordance, for the reader who wants their pictures kept.
    @Test("Forget drops the password and nothing else")
    func forgetIsNarrower() throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: "one.example", username: "a", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        #expect(forums.hasPassword(host: "one.example"))
        forums.forgetPassword(host: "ONE.Example")
        #expect(!forums.hasPassword(host: "one.example"), "Forget did not fold the host")
    }

    @Test("What the screen draws and what the store holds cannot come apart")
    func savedHostsFollowTheStore() throws {
        // `savedHosts` is held rather than asked for on every body. Held state that is not
        // refreshed where it changes is a row that says a password is there after it has gone —
        // and the reader presses Forget and watches nothing happen.
        let credentials = MemoryCredentials()
        let forums = ForumSessions(credentials: credentials)
        #expect(forums.savedHosts.isEmpty)
        try credentials.save(ForumCredential(host: "a.example", username: "u", password: "p"))
        forums.refreshSavedHosts()
        #expect(forums.savedHosts == ["a.example"])
        forums.forgetPassword(host: "a.example")
        #expect(forums.savedHosts.isEmpty)
    }

    // MARK: - When the reader is offered a sign-in

    @Test("A refusal offers the reader their own forum's sign-in page")
    func refusalOffersSignIn() async {
        // A refusal is the one failure where the host is fine, the spelling is fine, and this app
        // was turned away on purpose — which is the one a reader with an account can answer.
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(String(data: Fixtures.forumHTML(), encoding: .utf8)!),
            "/latest.json": .text("nope", status: 403),
        ]), forums: ForumSessions(credentials: MemoryCredentials()))
        session.hostname = "forum.example"
        await session.add()
        #expect(session.refuse != nil, "the premise did not hold: nothing was refused")
        #expect(session.offerSignIn == "forum.example", "a refusal offered the reader nothing")
    }

    @Test("A host that is simply unreachable offers nothing, because there is nothing to sign in to")
    func unreachableOffersNothing() async {
        let session = ShellSession(http: FixtureHTTP(), forums: ForumSessions(credentials: MemoryCredentials()))
        session.hostname = "nowhere.example"
        await session.add()
        #expect(session.refuse != nil)
        #expect(session.offerSignIn == nil, "a dead server invited the reader to go and sign in to it")
    }

    @Test("A fresh attempt clears the last one's offer")
    func offerDoesNotLinger() async {
        let session = ShellSession(http: FixtureHTTP(), forums: ForumSessions(credentials: MemoryCredentials()))
        session.offerSignIn = "stale.example"
        session.hostname = "nowhere.example"
        await session.add()
        #expect(session.offerSignIn == nil, "one host's offer was shown for another")
    }

    /// D24, at the level a package test can reach: no saved credential is a hand-over, not a
    /// failure, and it puts the forum's own page in front of the reader.
    @Test("With nothing saved, the first sign-in is handed to the reader")
    func firstSignInIsTheReaders() async {
        let session = ShellSession(http: FixtureHTTP(), forums: ForumSessions(credentials: MemoryCredentials()))
        await session.signIn(host: "bbs.example.org")
        #expect(session.signingIn?.host == "bbs.example.org")
        #expect(session.signingIn?.stop == .noCredential)
    }

    @Test("A host that is not a host is not a sign-in")
    func nonsenseHostIsNotASheet() async {
        let session = ShellSession(http: FixtureHTTP(), forums: ForumSessions(credentials: MemoryCredentials()))
        await session.signIn(host: "not a host/at all")
        #expect(session.signingIn == nil)
    }

    @Test("A sign-in that was reached closes the offer; one that was not leaves it")
    func finishingKeepsTheOfferWhereItIsNeeded() {
        let session = ShellSession(http: FixtureHTTP(), forums: ForumSessions(credentials: MemoryCredentials()))
        session.offerSignIn = "bbs.example.org"
        session.signingIn = ForumSignInRequest(host: "bbs.example.org", stop: .noCredential)

        session.signInFinished(reached: false)
        #expect(session.signingIn == nil, "the sheet stayed open")
        #expect(session.offerSignIn == "bbs.example.org",
                "the reader would have to type the host again to try a second time")

        session.signInFinished(reached: true)
        #expect(session.offerSignIn == nil)
    }
}

extension Fixtures {
    /// A minimal forum front page, enough for the detector to name it.
    static func forumHTML() -> Data {
        Data("""
        <html><head><meta name="generator" content="Discourse 3.2.0" /></head>
        <body>a forum</body></html>
        """.utf8)
    }
}
