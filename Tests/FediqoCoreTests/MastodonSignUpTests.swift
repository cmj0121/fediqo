import Foundation
import Testing

@testable import FediqoCore

/// #435: an account made on a host's own form, as far as this package goes. What the answers say
/// is what a real Mastodon (nightly 2026-10-30) was walked through saying.
@Suite("An account made in a Mastodon's own sign-in")
struct MastodonSignUpTests {
    private static let host = "social.example"
    private static let app = MastodonApp(host: host, clientID: "cid", clientSecret: "csecret", scopes: "read write")
    private static let token = MastodonToken(host: host, accessToken: "tok", clientID: "cid", clientSecret: "csecret")

    private static func document(_ registrations: String) -> Data {
        Data(#"{"registrations":\#(registrations)}"#.utf8)
    }

    // MARK: - What a host says

    @Test("A host offers it only where its document says oauth true, and enabled alone tells closed from open")
    func theDocument() {
        let open = #"{"enabled":true,"approval_required":false,"reason_required":false,"message":null,"min_age":16,"url":null,"oauth":true}"#
        #expect(MastodonHostSays(document: Self.document(open)).signUp == MastodonSignUp(open: true, minAge: 16))
        let approved = #"{"enabled":true,"approval_required":true,"min_age":null,"oauth":true}"#
        #expect(MastodonHostSays(document: Self.document(approved)).signUp == MastodonSignUp(open: true, approvalRequired: true))
        let closed = #"{"enabled":false,"approval_required":false,"min_age":null,"oauth":true}"#
        #expect(MastodonHostSays(document: Self.document(closed)).signUp == MastodonSignUp(open: false))
        #expect(MastodonHostSays(document: Self.document(#"{"oauth":true}"#)).signUp == MastodonSignUp(open: false))

        for silent in [#"{"enabled":true}"#, #"{"enabled":true,"oauth":false}"#, #"{"enabled":true,"oauth":"yes"}"#, "[]", "null"] {
            #expect(MastodonHostSays(document: Self.document(silent)).signUp == nil, "\(silent)")
        }
        #expect(MastodonHostSays.nothing.signUp == nil)
    }

    @Test("An age no host could mean is no age, and one of another shape costs only itself")
    func theAge() {
        for odd in ["0", "-3", #""sixteen""#] {
            let said = MastodonHostSays(document: Self.document(#"{"enabled":true,"min_age":\#(odd),"oauth":true}"#))
            #expect(said.signUp == MastodonSignUp(open: true), "\(odd)")
        }
    }

    @Test("A look carries the terms, and what is written down of a source does not")
    func aLookCarriesThem() async throws {
        let body = #"{"title":"A","registrations":{"enabled":true,"oauth":true}}"#
        let client = MastodonClient(http: FixtureHTTP(["/api/v2/instance": .text(body)]), host: Self.host)
        let profile = try await client.profile()
        #expect(profile.signUp == MastodonSignUp(open: true))
        #expect(profile.said(at: Date(timeIntervalSince1970: 1)).signUp == nil)
    }

    @Test("Only a Mastodon's look carries terms: another kind is asked nothing and answers none")
    func otherKinds() async throws {
        let http = FixtureHTTP(["/api/v2/instance": .text(#"{"registrations":{"enabled":true,"oauth":true}}"#)])
        for kind in [ProtocolKind.pleroma, .discuz, .gotosocial] {
            guard case .silent = try await SourceProfiles(http: http).answer(host: Self.host, kind: kind) else {
                Issue.record("\(kind)")
                continue
            }
        }
        #expect(await http.requested.isEmpty)
    }

    // MARK: - An invitation

    @Test("An invitation is a bare code or the last segment of an https invite address at this host")
    func reducesToACode() {
        let reads: [(String, String)] = [
            ("aBc123", "aBc123"),
            ("  aBc-1_2\n", "aBc-1_2"),
            ("https://social.example/invite/aBc123", "aBc123"),
            ("HTTPS://SOCIAL.example/invite/aBc123/", "aBc123"),
            ("https://social.example/invite/aBc123?x=1#y", "aBc123"),
        ]
        for (typed, code) in reads { #expect(MastodonSignUp.invitation(typed, at: Self.host) == code, "\(typed)") }
    }

    @Test("Anything else reduces to nothing: no other scheme, host or path, no character a path could be bent by")
    func refusesTheRest() {
        let refused = [
            "", "   ", "a b", "a/b", "../x", "a%2Fb", "a?b", "a&invite_code=b", "a#b", "碼",
            String(repeating: "a", count: MastodonSignUp.inviteLength + 1),
            "http://social.example/invite/abc",
            "ftp://social.example/invite/abc",
            "javascript:alert(1)",
            "https://other.example/invite/abc",
            "https://social.example@other.example/invite/abc",
            "https://me:pw@social.example/invite/abc",
            "https://social.example/abc",
            "https://social.example/invite/",
            "https://social.example/invite/a/b",
            "https://social.example/x/invite/abc",
            "https://social.example/invite/a%2Fb",
            "https://social.example/invite/..",
            "social.example/invite/abc",
        ]
        for typed in refused { #expect(MastodonSignUp.invitation(typed, at: Self.host) == nil, "\(typed)") }
    }

    // MARK: - The page

    @Test("The page carries prompt=create and invite_code only when asked, on every parameter a sign-in has")
    func thePage() throws {
        let oauth = MastodonOAuth(host: Self.host, sender: FixtureSender([:]))
        let plain = try #require(oauth.authorizeURL(clientID: "cid", challenge: "chal", state: "st"))
        #expect(FixtureBrowser.query(plain, "prompt") == nil)
        #expect(FixtureBrowser.query(plain, "invite_code") == nil)
        let ignored = try #require(oauth.authorizeURL(clientID: "cid", challenge: "chal", state: "st", invite: "abc"))
        #expect(FixtureBrowser.query(ignored, "invite_code") == nil, "an invitation on a page making no account is sent nowhere")

        let making = try #require(oauth.authorizeURL(clientID: "cid", challenge: "chal", state: "st", creating: true))
        #expect(FixtureBrowser.query(making, "prompt") == "create")
        #expect(FixtureBrowser.query(making, "invite_code") == nil)
        #expect(FixtureBrowser.query(making, "state") == "st" && FixtureBrowser.query(making, "code_challenge_method") == "S256")

        let invited = try #require(oauth.authorizeURL(clientID: "cid", challenge: "chal", state: "st", creating: true, invite: "abc"))
        #expect(FixtureBrowser.query(invited, "prompt") == "create" && FixtureBrowser.query(invited, "invite_code") == "abc")
    }

    @Test("Coming back from the form the code is traded, asking nothing else of the host")
    @MainActor
    func theTrade() async throws {
        let sender = FixtureSender(["/oauth/token": .json(#"{"access_token":"new","scope":"read"}"#)])
        let page = FixtureBrowser.approving()
        let made = try await MastodonOAuth(host: Self.host, sender: sender).signUp(
            as: Self.app, asking: "read", invite: "abc", through: page
        )
        #expect(made.token.accessToken == "new" && made.token.scopes == "read" && !made.handedBack)
        #expect(await sender.paths == ["/oauth/token"])
        #expect(FixtureBrowser.query(page.opened[0], "invite_code") == "abc")
    }

    @Test("An answer that does not carry this page's state is not this page's: no code is traded")
    @MainActor
    func theStateIsChecked() async throws {
        let sender = FixtureSender(["/oauth/token": .json(#"{"access_token":"new"}"#)])
        await #expect(throws: MastodonSignInError.stateMismatch) {
            _ = try await MastodonOAuth(host: Self.host, sender: sender).signUp(
                as: Self.app, asking: "read",
                through: FixtureBrowser { _ in URL(string: "fediqo://oauth?code=c&state=another")! }
            )
        }
        #expect(await sender.paths.isEmpty)
    }

    @Test("A page for a word its registration was not made for opens nothing")
    @MainActor
    func aWordNotRegistered() async throws {
        let page = FixtureBrowser.approving()
        await #expect(throws: MastodonSignInError.unreadable) {
            _ = try await MastodonOAuth(host: Self.host, sender: FixtureSender([:])).signUp(
                as: Self.app, asking: "read follow", through: page
            )
        }
        #expect(page.opened.isEmpty)
    }

    // MARK: - How it stands

    private static let path = "/api/v1/accounts/verify_credentials"

    private func standing(_ outcome: FixtureSender.Outcome) async throws -> (MastodonNewAccount, URLRequest?) {
        let sender = FixtureSender([Self.path: outcome])
        let answer = try await MastodonOAuth(host: Self.host, sender: sender).standing(of: Self.token)
        return (answer, await sender.requests.first)
    }

    @Test("Asked with allow_nonfunctional and the token, each state the real server gave is read by its code")
    func theStates() async throws {
        let unconfirmed = #"{"id":"1","acct":"a","state":{"functional":false,"confirmed":false,"approved":false,"error_code":"pending_confirmation","error":"請確認"}}"#
        let (mail, request) = try await standing(.json(unconfirmed))
        #expect(mail == .awaitingMail)
        #expect(request?.url?.query == "allow_nonfunctional=true")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        let unapproved = #"{"id":"1","state":{"functional":false,"confirmed":true,"approved":false,"error_code":"pending_approval","error":"x"}}"#
        #expect(try await standing(.json(unapproved)).0 == .awaitingApproval)

        // As verify_raw.json of the walk has it.
        let works = #"{"id":"117532260903127495","acct":"userf","source":{"privacy":"public"},"state":{"functional":true,"confirmed":true,"approved":true,"error_code":null,"error":null}}"#
        guard case .functional(let who) = try await standing(.json(works)).0 else {
            Issue.record("a working account")
            return
        }
        #expect(who.id == "117532260903127495" && who.handle?.contains("userf") == true)

        let held = #"{"id":"1","state":{"functional":false,"error_code":"disabled","error":"pending_approval"}}"#
        #expect(try await standing(.json(held)).0 == .unsaid, "by the code and never the sentence")
    }

    @Test("Only the host's plain word works: other shapes of an answer are unsaid, never a working account")
    func otherShapes() async throws {
        for body in [
            "not json", "[]", #""x""#, #"{}"#, #"{"id":1}"#, #"{"id":""}"#, #"{"id":"1","state":"x"}"#, #"{"id":"1","state":null}"#,
            #"{"id":"1","state":{}}"#, #"{"id":"1","state":{"functional":"false"}}"#, #"{"id":"1","state":{"functional":"true"}}"#,
            #"{"id":"1","state":{"functional":1}}"#, #"{"id":"1","state":{"functional":false}}"#, #"{"id":"1","state":{"error_code":null}}"#,
            #"{"state":{"functional":true}}"#, #"{"id":"","state":{"functional":true}}"#, #"{"id":1,"state":{"functional":true}}"#,
        ] {
            #expect(try await standing(.json(body)).0 == .unsaid, "\(body)")
        }
    }

    @Test("A bare 401 is something in front of the source, and its own is the token gone")
    func theTwo401s() async throws {
        await #expect(throws: MastodonSignInError.unreachable) { _ = try await standing(.json("", status: 401)) }
        await #expect(throws: MastodonSignInError.unreachable) { _ = try await standing(.json("<html>", status: 401)) }
        await #expect(throws: MastodonSignInError.http(401)) { _ = try await standing(.json(#"{"error":"The access token is invalid"}"#, status: 401)) }
    }

    @Test("A check naming no state is the usual check's yes; a 403 is no failure; the dark and a 500 are thrown")
    func theRest() async throws {
        guard case .functional = try await standing(.json(#"{"id":"1"}"#)).0 else {
            Issue.record("no state")
            return
        }
        #expect(try await standing(.json(#"{"error":"Your login is missing a confirmed e-mail address"}"#, status: 403)).0 == .unsaid)
        await #expect(throws: MastodonSignInError.http(500)) { _ = try await standing(.json("{}", status: 500)) }
        await #expect(throws: MastodonSignInError.unreachable) { _ = try await standing(.fail) }
    }

    @Test("The mail is asked for again with the token, and a refusal is thrown with its status")
    func resending() async throws {
        let path = "/api/v1/emails/confirmations"
        let sender = FixtureSender([path: .json("{}")])
        try await MastodonOAuth(host: Self.host, sender: sender).resendConfirmation(Self.token)
        let sent = await sender.requests.first
        #expect(sent?.httpMethod == "POST" && sent?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        await #expect(throws: MastodonSignInError.http(403)) {
            try await MastodonOAuth(host: Self.host, sender: FixtureSender([path: .json("{}", status: 403)])).resendConfirmation(Self.token)
        }
    }
}
