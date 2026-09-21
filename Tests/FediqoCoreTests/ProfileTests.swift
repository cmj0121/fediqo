import Foundation
import Testing

@testable import FediqoCore

/// What a server says about itself, and the four sentences that can come of asking.
///
/// **Where this JSON comes from, stated plainly.** None of it is a capture. It is written out
/// here, with invented servers and invented numbers, and it is **not evidence that Mastodon or
/// Discourse emit these fields in this shape** — it is a record of the shape this app was built
/// to read, and the reason `f421fea` gives for keeping no captures applies to it word for word.
/// The structural relations that matter are kept: `usage.users.active_month` with no total beside
/// it, `registrations` as two booleans rather than one word, a rules array that is sometimes
/// empty, and a Discourse whose counts live in a second document that is allowed not to answer.
@Suite("Profile")
struct ProfileTests {
    private static let mastodonHost = "install-g.example"
    private static let discourseHost = "install-f.example"

    private static func instance(
        registrations: String = #"{"enabled": true, "approval_required": false, "message": null}"#,
        rules: String = #"[{"id": "1", "text": "Be kind", "hint": "and patient"}]"#,
        thumbnail: String = #""https://install-g.example/system/site_uploads/thumb.png""#
    ) -> String {
        #"""
        {
          "domain": "install-g.example",
          "title": "Install G",
          "version": "4.3.1",
          "source_url": "https://example.invalid/mastodon",
          "description": "A small server for people who repair bicycles.",
          "usage": {"users": {"active_month": 1482}},
          "thumbnail": {"url": \#(thumbnail), "blurhash": "UeKUpFxu"},
          "languages": ["en"],
          "configuration": {"statuses": {"max_characters": 500}},
          "registrations": \#(registrations),
          "contact": {"email": "admin@install-g.example"},
          "rules": \#(rules)
        }
        """#
    }

    private static func answer(
        _ routes: [String: FixtureHTTP.Outcome],
        host: String,
        kind: ProtocolKind
    ) async throws -> (ProfileAnswer, [String]) {
        let http = FixtureHTTP(routes)
        let answer = try await SourceProfiles(http: http).answer(host: host, kind: kind)
        return (answer, await http.paths)
    }

    private static func stated(_ answer: ProfileAnswer) throws -> SourceProfile {
        guard case .stated(let profile) = answer else {
            Issue.record("expected a stated profile, got \(answer)")
            throw ProfileError.unreadable
        }
        return profile
    }

    // MARK: - Mastodon

    @Test("A Mastodon says its name, how many people used it this month, and its rules")
    func aMastodonStatesItself() async throws {
        let (answer, asked) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance())],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        let profile = try Self.stated(answer)

        #expect(asked == ["/api/v2/instance"])
        #expect(profile.id == Self.mastodonHost)
        #expect(profile.kind == .mastodon)
        #expect(profile.title == "Install G")
        #expect(profile.summary == "A small server for people who repair bicycles.")
        #expect(profile.thumbnail?.absoluteString
            == "https://install-g.example/system/site_uploads/thumb.png")
        #expect(profile.activeMonth == 1482)
        #expect(profile.statusLimit == 500)
        #expect(profile.registration == .open)
        #expect(profile.rules == ["Be kind"])
    }

    @Test("A Mastodon that advertises another ceiling is taken at its word")
    func aMastodonAdvertisesItsCeiling() async throws {
        let long = Self.instance().replacingOccurrences(
            of: #""max_characters": 500"#, with: #""max_characters": 2000"#
        )
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(long)],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(try Self.stated(answer).statusLimit == 2000)
    }

    @Test("A Mastodon that said nothing about a ceiling leaves it unguessed")
    func aMastodonWithoutACeilingSaysNothing() async throws {
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(#"{"title":"Install G"}"#)],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(try Self.stated(answer).statusLimit == nil)
    }

    @Test("A Mastodon has no idea how many accounts it holds, and says nothing rather than zero")
    func aMastodonHasNoTotal() async throws {
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance())],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        let profile = try Self.stated(answer)

        // `/api/v2/instance` carries `usage.users.active_month` and no total: the registered
        // account count left with v1's `stats` block. Nothing here means the protocol has no such
        // idea — never that the read failed.
        #expect(profile.people == nil)
        #expect(profile.posts == nil)
        // Nor whether a signed-out reader may read it: a Mastodon's public timeline either
        // answers or does not, and there is no setting published here that predicts it.
        #expect(profile.readsWithoutAccount == nil)
    }

    @Test(
        "Two booleans become the three answers a reader can act on",
        arguments: [
            (#"{"enabled": true, "approval_required": false}"#, SourceProfile.Registration.open),
            // Open, and said with one boolean. A server that turned registrations on and never
            // mentioned approval is not asking anybody to wait.
            (#"{"enabled": true}"#, .open),
            (#"{"enabled": true, "approval_required": true}"#, .byApproval),
            (#"{"enabled": false, "approval_required": false}"#, .closed),
            // Closed is read off `enabled` alone: a server that has said no has said no, and
            // whether it would also have wanted approval is a setting nobody can act on.
            (#"{"enabled": false, "approval_required": true}"#, .closed),
        ]
    )
    func registrationsBecomeThreeAnswers(
        wire: String,
        expected: SourceProfile.Registration
    ) async throws {
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance(registrations: wire))],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(try Self.stated(answer).registration == expected)
    }

    @Test("A server that never mentioned registrations is not assumed to be open")
    func silenceAboutRegistrationsIsNotAnInvitation() async throws {
        let wire = #"{"message": "we are full"}"#
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance(registrations: wire))],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(try Self.stated(answer).registration == nil)
    }

    @Test("No rules and an empty list of rules are the same nothing to draw")
    func rulesAreFlat() async throws {
        let (empty, _) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance(rules: "[]"))],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(try Self.stated(empty).rules.isEmpty)

        // A rule object with no words in it is one line fewer, not one blank line.
        let (partial, _) = try await Self.answer(
            ["/api/v2/instance": .text(
                Self.instance(rules: #"[{"id": "1", "text": "Be kind"}, {"id": "2"}]"#)
            )],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(try Self.stated(partial).rules == ["Be kind"])

        // The same document with the key gone altogether. A list has one spelling of empty, so
        // these two must be indistinguishable — see `SourceProfile.rules`.
        let (absent, _) = try await Self.answer(
            ["/api/v2/instance": .text(#"{"title": "Install G"}"#)],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(try Self.stated(absent).rules.isEmpty)
    }

    @Test("A thumbnail this device will not fetch is dropped, not kept for something else to open")
    func aThumbnailIsAStrangersAddress() async throws {
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance(thumbnail: #""javascript:alert(1)""#))],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(try Self.stated(answer).thumbnail == nil)
    }

    @Test("A Mastodon too old for the endpoint is a profile nobody could read, not a refusal")
    func anOldMastodonIsUnreadable() async throws {
        // What a pre-4.0 Mastodon actually answers: 404, with a page of HTML.
        let page = "<!DOCTYPE html><html><head><title>The page you were looking for doesn't exist"
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(page, status: 404)],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(answer == .unread(host: Self.mastodonHost, kind: .mastodon, .unreadable))
    }

    @Test("A body that did not come with a 200 is never decoded")
    func theStatusIsReadBeforeTheBody() async throws {
        // A perfectly good instance document, served with a 404. If the status were checked after
        // the decode — or not at all — this would come back `.stated` and the preview would draw
        // a profile out of a page the server said was not there.
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance(), status: 404)],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(answer == .unread(host: Self.mastodonHost, kind: .mastodon, .unreadable))
    }

    @Test(
        "Which numbers are a door somebody closed, and which are an answer nobody could read",
        arguments: [
            // Mastodon 4.0 to 4.3 in limited-federation mode answered 401 here while serving
            // everything else perfectly. 403, 429 and 503 are what a filter in front of a server
            // says, and they are the same four numbers `DiscourseClient.check` calls a refusal.
            (401, ProfileError.refused(401)),
            (403, .refused(403)),
            (429, .refused(429)),
            (503, .refused(503)),
            // Not a refusal: a Mastodon too old to have the endpoint, and a server having a bad
            // day. Neither is a door, and telling a reader they were turned away would be a lie
            // about a server they can have.
            (404, .unreadable),
            (500, .unreadable),
        ]
    )
    func statusesBecomeTheRightSentence(status: Int, expected: ProfileError) async throws {
        // **The body is a perfectly good instance document every time.** So each of these also
        // pins the ordering: a decode that ran before the status was read would answer `.stated`.
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance(), status: status)],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(answer == .unread(host: Self.mastodonHost, kind: .mastodon, expected))
    }

    @Test("A host that did not answer at all is unreachable, and the reader still gets a sentence")
    func nothingAnsweredIsNotAThrow() async throws {
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .fail],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(answer == .unread(host: Self.mastodonHost, kind: .mastodon, .unreachable))
    }

    @Test("An answer that is not a profile is unreadable, not unreachable")
    func rubbishIsNotSilence() async throws {
        let (answer, _) = try await Self.answer(
            ["/api/v2/instance": .text("[1, 2, 3]")],
            host: Self.mastodonHost,
            kind: .mastodon
        )
        #expect(answer == .unread(host: Self.mastodonHost, kind: .mastodon, .unreadable))
    }

    // MARK: - Discourse

    private static let basicInfo = #"""
    {
      "logo_url": "https://install-f.example/uploads/default/logo.png",
      "apple_touch_icon_url": "https://install-f.example/uploads/default/apple.png",
      "favicon_url": "https://install-f.example/uploads/default/favicon.ico",
      "title": "Install F",
      "description": "Where the bicycle repairers argue about grease.",
      "header_primary_color": "333333",
      "header_background_color": "ffffff",
      "login_required": false,
      "locale": "en",
      "mobile_logo_url": null
    }
    """#

    private static let about = #"""
    {
      "about": {
        "title": "Install F",
        "locale": "en",
        "version": "3.4.1",
        "https": true,
        "stats": {
          "topic_count": 9184,
          "topics_last_day": 12,
          "post_count": 121904,
          "posts_last_day": 143,
          "user_count": 4402,
          "users_last_day": 3,
          "active_users_30_days": 611
        },
        "admins": [],
        "moderators": []
      }
    }
    """#

    @Test("A forum says its name, how big it is, and whether it can be read at all")
    func aForumStatesItself() async throws {
        let (answer, asked) = try await Self.answer(
            [
                "/site/basic-info.json": .text(Self.basicInfo),
                "/about.json": .text(Self.about),
            ],
            host: Self.discourseHost,
            kind: .discourse
        )
        let profile = try Self.stated(answer)

        // Sorted rather than a `Set`: a set cannot see a path that was asked for twice, and
        // twice is the failure a second caller introduces.
        #expect(asked.sorted() == ["/about.json", "/site/basic-info.json"])
        // Not `/site.json`: 285 KB of Ember bootstrap with neither a title nor a description in
        // it. See `DiscourseClient.profile`.
        #expect(!asked.contains("/site.json"))
        #expect(profile.kind == .discourse)
        #expect(profile.title == "Install F")
        #expect(profile.summary == "Where the bicycle repairers argue about grease.")
        #expect(profile.thumbnail?.absoluteString
            == "https://install-f.example/uploads/default/logo.png")
        #expect(profile.people == 4402)
        #expect(profile.posts == 121_904)
        #expect(profile.readsWithoutAccount == true)
    }

    @Test("A forum has no idea how many people used it this month, and no rules to publish")
    func aForumHasNoMonthlyNumber() async throws {
        let (answer, _) = try await Self.answer(
            ["/site/basic-info.json": .text(Self.basicInfo), "/about.json": .text(Self.about)],
            host: Self.discourseHost,
            kind: .discourse
        )
        let profile = try Self.stated(answer)

        // `/about.json` carries the total and nothing monthly, which is the mirror of Mastodon's
        // gap. Nothing means the protocol has no such idea.
        #expect(profile.activeMonth == nil)
        #expect(profile.registration == nil)
        #expect(profile.rules.isEmpty)
    }

    @Test("A forum that shows nothing to a signed-out reader says so before the press, not after")
    func loginRequiredIsTheOneFieldThatPredictsAFailure() async throws {
        // This is the whole reason the field is carried: this forum's `/latest.json` will answer
        // 403, so a reader who subscribes gets `JoinError.refused` and a sentence about being
        // turned away. It arrives in a document the preview fetches anyway.
        let gated = Self.basicInfo.replacingOccurrences(
            of: #""login_required": false"#,
            with: #""login_required": true"#
        )
        let (answer, _) = try await Self.answer(
            ["/site/basic-info.json": .text(gated), "/about.json": .text(Self.about)],
            host: Self.discourseHost,
            kind: .discourse
        )
        #expect(try Self.stated(answer).readsWithoutAccount == false)
    }

    @Test("A forum that never mentioned it is not assumed to be readable")
    func silenceAboutLoginIsNotAYes() async throws {
        let (answer, _) = try await Self.answer(
            ["/site/basic-info.json": .text(#"{"title": "Install F"}"#)],
            host: Self.discourseHost,
            kind: .discourse
        )
        #expect(try Self.stated(answer).readsWithoutAccount == nil)
    }

    @Test("The counts are allowed to fail, and the forum still has a name")
    func theCountsAreAllowedToFail() async throws {
        // Nothing answered at all. The forum still has a name and a description.
        let (answer, _) = try await Self.answer(
            ["/site/basic-info.json": .text(Self.basicInfo), "/about.json": .fail],
            host: Self.discourseHost,
            kind: .discourse
        )
        let profile = try Self.stated(answer)

        #expect(profile.title == "Install F")
        #expect(profile.people == nil)
        #expect(profile.posts == nil)
    }

    @Test(
        "A counts document that came with a status saying no is not read",
        arguments: [403, 404, 500]
    )
    func aRefusedCountsDocumentIsNotRead(status: Int) async throws {
        // **The body is the real `/about.json` every time, and that is the whole pin.** Served
        // with an undecodable body this test passes with the status guard deleted, because the
        // decode fails either way and the swallow hides which one refused it. With a valid
        // document behind the refusal, a missing guard draws 4402 people out of a document the
        // server said this reader could not have.
        let (answer, _) = try await Self.answer(
            [
                "/site/basic-info.json": .text(Self.basicInfo),
                "/about.json": .text(Self.about, status: status),
            ],
            host: Self.discourseHost,
            kind: .discourse
        )
        let profile = try Self.stated(answer)

        #expect(profile.title == "Install F")
        #expect(profile.people == nil)
        #expect(profile.posts == nil)
    }

    @Test("A counts document that answered 200 with something else in it is swallowed too")
    func anUndecodableCountsDocumentIsSwallowed() async throws {
        // The other failure mode, and a different pin: a 200 carrying a filter's page rather than
        // the forum's numbers. Here it is the decode that has to fail softly.
        let (answer, _) = try await Self.answer(
            [
                "/site/basic-info.json": .text(Self.basicInfo),
                "/about.json": .text("<html>checking your browser", status: 200),
            ],
            host: Self.discourseHost,
            kind: .discourse
        )
        let profile = try Self.stated(answer)

        #expect(profile.title == "Install F")
        #expect(profile.people == nil)
        #expect(profile.posts == nil)
    }

    @Test("Both spellings of the forum's own numbers are read")
    func bothSpellingsOfTheCounts() async throws {
        // Discourse has carried both the singular and the plural form. Neither this repository
        // nor this test is evidence of which one a given install sends — see `AboutDTO.Stats`.
        let plural = #"""
        {"about": {"stats": {"users_count": 4402, "posts_count": 121904}}}
        """#
        let (answer, _) = try await Self.answer(
            ["/site/basic-info.json": .text(Self.basicInfo), "/about.json": .text(plural)],
            host: Self.discourseHost,
            kind: .discourse
        )
        let profile = try Self.stated(answer)

        #expect(profile.people == 4402)
        #expect(profile.posts == 121_904)
    }

    @Test("A forum that answered with no numbers in it is still a forum")
    func aboutWithoutStats() async throws {
        let (answer, _) = try await Self.answer(
            [
                "/site/basic-info.json": .text(Self.basicInfo),
                "/about.json": .text(#"{"about": {"title": "Install F"}}"#),
            ],
            host: Self.discourseHost,
            kind: .discourse
        )
        let profile = try Self.stated(answer)

        #expect(profile.title == "Install F")
        #expect(profile.people == nil)
        #expect(profile.posts == nil)
    }

    @Test("The favicon stands in where the forum set no logo")
    func theFaviconStandsIn() async throws {
        // Two ways a forum has no logo to draw: it set none, and it set one this device will
        // not go and fetch. The second is the one the `??` exists for — a chain written as
        // `fetchableURL(logo ?? favicon)` would pass the first of these and drop the picture
        // altogether on the second.
        for logo in ["null", #""javascript:alert(1)""#] {
            let bare = #"""
            {
              "title": "Install F",
              "logo_url": \#(logo),
              "favicon_url": "https://install-f.example/uploads/default/favicon.ico"
            }
            """#
            let (answer, _) = try await Self.answer(
                ["/site/basic-info.json": .text(bare), "/about.json": .fail],
                host: Self.discourseHost,
                kind: .discourse
            )
            #expect(try Self.stated(answer).thumbnail?.absoluteString
                == "https://install-f.example/uploads/default/favicon.ico")
        }
    }

    @Test("Basic info is the one that is required: without it there is no profile")
    func basicInfoIsRequired() async throws {
        // **A valid document, served with a 404.** An empty body fails to decode on its own, so
        // a test written with one would pass with the status guard deleted — which is the whole
        // thing this test is for.
        let (answer, _) = try await Self.answer(
            [
                "/site/basic-info.json": .text(Self.basicInfo, status: 404),
                "/about.json": .text(Self.about),
            ],
            host: Self.discourseHost,
            kind: .discourse
        )
        #expect(answer == .unread(host: Self.discourseHost, kind: .discourse, .unreadable))
    }

    @Test("A forum behind a filter is refused, and keeps the number it was refused with")
    func aFilteredForumIsARefusal() async throws {
        let (answer, _) = try await Self.answer(
            ["/site/basic-info.json": .text(Self.basicInfo, status: 403)],
            host: Self.discourseHost,
            kind: .discourse
        )
        #expect(answer == .unread(host: Self.discourseHost, kind: .discourse, .refused(403)))
    }

    @Test(
        "A host spelled three other ways is the same host, asked and stamped the same way",
        arguments: [
            "https://install-g.example",
            " install-g.example ",
            "INSTALL-G.example",
        ]
    )
    func theHostIsNormalisedAtTheBoundary(spelling: String) async throws {
        // Each of these was, before the boundary parse, `.unread(.unreachable)` with no request
        // made — a caller's spelling recorded as a fact about somebody's server. The third is the
        // worse one: it used to succeed, under an `id` that is a different string from the
        // normalised spelling of the same host, which is two rows in unit 5's `profiles` map.
        let (answer, asked) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance())],
            host: spelling,
            kind: .mastodon
        )
        let profile = try Self.stated(answer)

        #expect(asked == ["/api/v2/instance"])
        #expect(profile.host == Self.mastodonHost)
        #expect(profile.id == Self.mastodonHost)
    }

    @Test("A protocol with nothing to say is still named by its normalised host")
    func silenceCarriesTheNormalisedHost() async throws {
        let (answer, asked) = try await Self.answer(
            [:],
            host: "https://INSTALL-A.example",
            kind: .discuz
        )
        #expect(answer == .silent(host: "install-a.example", kind: .discuz))
        #expect(asked.isEmpty)
    }

    @Test("A string that is not a host never answered, rather than answering badly")
    func aStringThatIsNotAHost() async throws {
        let (answer, asked) = try await Self.answer(
            ["/api/v2/instance": .text(Self.instance())],
            host: "install-g.example/forum",
            kind: .mastodon
        )
        // `.unreachable` and not `.unreadable`: nothing was asked, so nothing answered with
        // something that could not be read. Of the four sentences this is the only true one.
        #expect(answer == .unread(host: "install-g.example/forum", kind: .mastodon, .unreachable))
        #expect(asked.isEmpty)
    }

    // MARK: - The reader who walked away

    @Test("A reader who walked away is not a server that would not answer")
    func cancellationIsNotAFactAboutTheHost() async throws {
        // The one thing `answer` is allowed to throw, and the reason its signature says so: a
        // leaving recorded as `.unread(.unreachable)` is a lie about somebody's server, and it is
        // the sentence the preview would show the next time the reader came back.
        let http = FixtureHTTP(["/api/v2/instance": .cancelled])
        await #expect(throws: CancellationError.self) {
            try await SourceProfiles(http: http).answer(host: Self.mastodonHost, kind: .mastodon)
        }
    }

    @Test("Walking away during the second document is still walking away")
    func cancellationSurvivesTheDocumentThatMayFail() async throws {
        // **The one that needed catching.** `/about.json` is allowed to fail, so every way it can
        // fail is swallowed — and a cancelled transfer arrives as `URLError(.cancelled)` rather
        // than as `CancellationError`, so a `catch is CancellationError` beside the swallow never
        // fires. Without `Cancellation.happened` this returns `.stated` with two missing numbers,
        // for a reader who is no longer there.
        let http = FixtureHTTP([
            "/site/basic-info.json": .text(Self.basicInfo),
            "/about.json": .cancelled,
        ])
        await #expect(throws: CancellationError.self) {
            try await SourceProfiles(http: http).answer(host: Self.discourseHost, kind: .discourse)
        }
    }

    @Test("Walking away during the document that is required is walking away too")
    func cancellationOnTheRequiredDocument() async throws {
        let http = FixtureHTTP([
            "/site/basic-info.json": .cancelled,
            "/about.json": .text(Self.about),
        ])
        await #expect(throws: CancellationError.self) {
            try await SourceProfiles(http: http).answer(host: Self.discourseHost, kind: .discourse)
        }
    }

    // MARK: - The protocols with nothing to say

    @Test("Discuz! is silent, and nothing at all is asked of it")
    func discuzIsSilentAndUntouched() async throws {
        let (answer, asked) = try await Self.answer([:], host: "install-a.example", kind: .discuz)

        #expect(answer == .silent(host: "install-a.example", kind: .discuz))
        // **Zero requests.** Discuz! publishes no machine-readable self-description, and the
        // statistics a theme draws on `/forum.php` are not one. A read that never happened must
        // not spend a stranger's bandwidth finding that out.
        #expect(asked.isEmpty)
    }

    @Test("Every protocol has an answer, and none of them is unasked")
    func everyProtocolIsAnswered() async throws {
        // **The `allCases` half of this package's mitigation.** The exhaustive switch in
        // `SourceProfiles.answer` stops a new protocol from falling through silently; this stops
        // one from being added to the switch as `.silent` by reflex and never noticed. Between
        // them they are the only thing that keeps M2's unlocked forks from previewing blank.
        for kind in ProtocolKind.allCases {
            let http = FixtureHTTP([:])
            let answer = try await SourceProfiles(http: http).answer(host: "any.example", kind: kind)
            let asked = await http.paths

            switch kind {
            // Asked, and — with nothing routed — answered with the failure that says so. What is
            // pinned here is that the request was made at all.
            case .mastodon, .discourse:
                #expect(answer == .unread(host: "any.example", kind: kind, .unreachable))
                #expect(!asked.isEmpty)
            // Nothing to ask, so nothing asked. Each of these becomes a real answer in the unit
            // that gives it a client; until then a request would be traffic for a document that
            // does not exist.
            case .discuz, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
                .gotosocial, .unknown:
                #expect(answer == .silent(host: "any.example", kind: kind))
                #expect(asked.isEmpty)
            }

            // `.unasked` belongs to a caller holding a source nothing has asked about yet. This
            // function is the asking, so it can never be the answer.
            #expect(answer != .unasked(host: "any.example", kind: kind))
        }
    }
}
