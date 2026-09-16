import Foundation
import Testing

@testable import FediqoCore

/// A forum read the way the app reads it.
///
/// **Where this JSON comes from, stated plainly.** It used to be a trimmed capture of a running
/// Discourse, which is what made a missing field — no `excerpt` on most of the front page, no
/// `image_url` on nearly all of it — evidence rather than an assumption. It is now written out
/// here, with invented people and invented topics, and it is **no longer evidence that Discourse
/// emits these fields in this shape**; it is only a record of the shape this app was built to
/// read. Every structural relation the capture had is kept: `users` keyed to topics through
/// `posters[].user_id`, a `created_at` that differs from `bumped_at`, `reply_count` beside
/// `posts_count`, a `category_id` that means nothing until `/site.json` names it, and a topic
/// whose original poster is not in `users` at all.
@Suite("Discourse")
struct DiscourseTests {
    private static let host = "install-f.example"
    private static let source = Source(host: Self.host, kind: .discourse)

    @Test("The front page becomes notes: a name, a section, who asked, and where to read it")
    func theFrontPageIsATimeline() async throws {
        let latest = #"""
        {
          "users": [
            {
              "id": 4021,
              "username": "wrenmakar",
              "name": "Wren Makar",
              "avatar_template": "/user_avatar/install-f.example/wrenmakar/{size}/4021_2.png",
              "trust_level": 2
            },
            {
              "id": 5510,
              "username": "ipollard",
              "name": "Ines Pollard",
              "avatar_template": "/user_avatar/install-f.example/ipollard/{size}/5510_2.png",
              "primary_group_name": "maintainers",
              "trust_level": 3
            },
            {
              "id": 3097,
              "username": "haruspex",
              "name": "Jo Ferrando",
              "avatar_template": "/user_avatar/install-f.example/haruspex/{size}/3097_2.png",
              "trust_level": 2
            }
          ],
          "topic_list": {
            "topics": [
              {
                "fancy_title": "Give `retry_after` a documented default",
                "id": 41207,
                "title": "Give `retry_after` a documented default",
                "slug": "give-retry-after-a-documented-default",
                "posts_count": 3,
                "reply_count": 0,
                "highest_post_number": 3,
                "image_url": null,
                "created_at": "2026-04-02T09:12:41.508Z",
                "last_posted_at": "2026-04-02T14:55:06.219Z",
                "bumped": true,
                "bumped_at": "2026-04-02T14:55:06.219Z",
                "archetype": "regular",
                "visible": true,
                "closed": false,
                "archived": false,
                "tags": [],
                "views": 54,
                "like_count": 2,
                "has_summary": false,
                "last_poster_username": "haruspex",
                "category_id": 6,
                "posters": [
                  {"extras": null, "description": "Original Poster", "user_id": 4021},
                  {"extras": null, "description": "Recent Poster", "user_id": 5510},
                  {"extras": "latest", "description": "Most Recent Poster", "user_id": 3097}
                ]
              },
              {
                "fancy_title": "Threaded build uses twice the memory",
                "id": 41094,
                "title": "Threaded build uses twice the memory",
                "slug": "threaded-build-uses-twice-the-memory",
                "posts_count": 19,
                "reply_count": 9,
                "highest_post_number": 19,
                "image_url": null,
                "created_at": "2026-03-26T07:36:16.903Z",
                "last_posted_at": "2026-04-02T14:31:03.004Z",
                "bumped": true,
                "bumped_at": "2026-04-02T14:31:03.004Z",
                "archetype": "regular",
                "visible": true,
                "closed": false,
                "archived": false,
                "tags": [
                  {"id": 89, "name": "threading", "slug": "threading"},
                  {"id": 12, "name": "GC", "slug": "gc"}
                ],
                "views": 676,
                "like_count": 7,
                "has_summary": true,
                "last_poster_username": "ipollard",
                "category_id": 7,
                "posters": [
                  {"extras": null, "description": "Original Poster", "user_id": 5510},
                  {"extras": null, "description": "Frequent Poster", "user_id": 4021},
                  {"extras": "latest", "description": "Most Recent Poster", "user_id": 3097}
                ]
              },
              {
                "fancy_title": "Telling a string from an expression",
                "id": 41205,
                "title": "Telling a string from an expression",
                "slug": "telling-a-string-from-an-expression",
                "posts_count": 4,
                "reply_count": 2,
                "highest_post_number": 4,
                "image_url": null,
                "created_at": "2026-04-02T08:24:36.347Z",
                "last_posted_at": "2026-04-02T14:26:30.946Z",
                "bumped": true,
                "bumped_at": "2026-04-02T14:26:30.946Z",
                "archetype": "regular",
                "visible": true,
                "closed": false,
                "archived": false,
                "tags": [],
                "views": 59,
                "like_count": 1,
                "has_summary": false,
                "last_poster_username": "nemet",
                "category_id": 7,
                "posters": [
                  {
                    "extras": "latest",
                    "description": "Original Poster, Most Recent Poster",
                    "user_id": 90118
                  },
                  {"extras": null, "description": "Recent Poster", "user_id": 90224}
                ]
              }
            ]
          }
        }
        """#
        // The category numbers a topic names, resolved here and nowhere else. Out of order and
        // wider than the front page needs, because `/site.json` is the whole forum's list.
        let site = #"""
        {
          "categories": [
            {"id": 7, "name": "Help"},
            {"id": 5, "name": "Maintainers"},
            {"id": 6, "name": "Proposals"},
            {"id": 33, "name": "Events"}
          ]
        }
        """#
        let http = FixtureHTTP(["/latest.json": .text(latest), "/site.json": .text(site)])
        let notes = try await DiscourseClient(http: http, host: Self.host).latest(source: Self.source)

        #expect(notes.count == 3)
        let first = try #require(notes.first)

        // The title is the post. A forum's front page carries no excerpt for most topics, so a
        // row that drew only `body` would draw three blank posts.
        #expect(first.title == "Give `retry_after` a documented default")
        #expect(first.body.isEmpty, "a topic with no excerpt drew something anyway")
        #expect(first.board == "Proposals")

        // The person named is whoever the forum called the original poster, and the display name
        // is preferred over the handle where the forum has one.
        #expect(first.author == "Wren Makar")
        #expect(first.handle == "@wrenmakar@install-f.example")

        // Not the most recent poster, though that is who the front page is ordered by.
        #expect(first.author != "Jo Ferrando")

        // `/latest.json` sends only the handful of people it needs, and the third topic's
        // original poster is not among them. A row for a person the forum did not describe must
        // come back blank rather than borrowing the name of whoever it did describe.
        let third = try #require(notes.last)
        #expect(third.author == "")
        #expect(third.handle == "")
        #expect(third.title == "Telling a string from an expression")

        // Where to read it, built from the slug and the number the forum sent.
        #expect(first.url?.absoluteString == "https://install-f.example/t/give-retry-after-a-documented-default/41207")

        // Prefixed, because a forum's topic numbers and a microblog's status ids share one store.
        #expect(first.id == "discourse:install-f.example:41207")
        #expect(first.source.kind == .discourse)

        // Both documents were read, and nothing else was.
        #expect(await Set(http.paths) == ["/latest.json", "/site.json"])
    }

    @Test("A topic is dated when it was asked, not when a stranger last answered")
    func theDateIsTheAuthors() async throws {
        // The two fields differ by five hours, and the front page is *ordered* by the second.
        // Dating the row by it would put a stranger's reply time on somebody's question.
        let latest = #"""
        {
          "users": [{"id": 4021, "username": "wrenmakar", "name": "Wren Makar"}],
          "topic_list": {"topics": [{
            "id": 41207,
            "title": "Give `retry_after` a documented default",
            "slug": "give-retry-after-a-documented-default",
            "created_at": "2026-04-02T09:12:41.508Z",
            "bumped_at": "2026-04-02T14:55:06.219Z",
            "posts_count": 3,
            "reply_count": 0,
            "category_id": 6,
            "posters": [{"description": "Original Poster", "user_id": 4021}]
          }]}
        }
        """#
        let http = FixtureHTTP(["/latest.json": .text(latest), "/site.json": .text(#"{"categories":[]}"#)])
        let first = try #require(
            try await DiscourseClient(http: http, host: Self.host).latest(source: Self.source).first
        )

        let created = try #require(MastodonJSON.date(from: "2026-04-02T09:12:41.508Z"))
        let bumped = try #require(MastodonJSON.date(from: "2026-04-02T14:55:06.219Z"))
        #expect(created != bumped, "the two dates were written the same, so this pins nothing")
        #expect(first.postedAt == created)
    }

    @Test("The answer count is answers, and never counts the question as one of them")
    func theCountIsAnswers() async throws {
        // Two topics with three posts each. The first states its `reply_count`; the second sends
        // only `posts_count`, which counts the question, so the fallback has to subtract it back
        // off rather than quietly showing one more answer than the topic has.
        let latest = #"""
        {
          "users": [{"id": 4021, "username": "wrenmakar", "name": "Wren Makar"}],
          "topic_list": {"topics": [
            {
              "id": 41207, "title": "Stated", "slug": "stated",
              "created_at": "2026-04-02T09:12:41.508Z",
              "posts_count": 3, "reply_count": 0,
              "posters": [{"description": "Original Poster", "user_id": 4021}]
            },
            {
              "id": 41208, "title": "Counted", "slug": "counted",
              "created_at": "2026-04-02T09:14:00.000Z",
              "posts_count": 3,
              "posters": [{"description": "Original Poster", "user_id": 4021}]
            },
            {
              "id": 41209, "title": "Unanswered", "slug": "unanswered",
              "created_at": "2026-04-02T09:15:00.000Z",
              "posts_count": 1,
              "posters": [{"description": "Original Poster", "user_id": 4021}]
            }
          ]}
        }
        """#
        let http = FixtureHTTP(["/latest.json": .text(latest), "/site.json": .text(#"{"categories":[]}"#)])
        let notes = try await DiscourseClient(http: http, host: Self.host).latest(source: Self.source)

        #expect(notes.map(\.counts.replies) == [0, 2, 0])
    }

    @Test("A forum with no category list is still readable, with one line less on each row")
    func theSectionsAreAllowedToFail() async throws {
        // `/site.json` refused: an old version, a plugin, a permission. The front page is still
        // the thing the reader opened the app for.
        let latest = #"""
        {
          "users": [{"id": 4021, "username": "wrenmakar", "name": "Wren Makar"}],
          "topic_list": {"topics": [
            {
              "id": 41207, "title": "Give `retry_after` a documented default",
              "slug": "give-retry-after-a-documented-default",
              "created_at": "2026-04-02T09:12:41.508Z", "category_id": 6, "reply_count": 0,
              "posters": [{"description": "Original Poster", "user_id": 4021}]
            },
            {
              "id": 41094, "title": "Threaded build uses twice the memory",
              "slug": "threaded-build-uses-twice-the-memory",
              "created_at": "2026-03-26T07:36:16.903Z", "category_id": 7, "reply_count": 9,
              "posters": [{"description": "Original Poster", "user_id": 4021}]
            },
            {
              "id": 41205, "title": "Telling a string from an expression",
              "slug": "telling-a-string-from-an-expression",
              "created_at": "2026-04-02T08:24:36.347Z", "category_id": 7, "reply_count": 2,
              "posters": [{"description": "Original Poster", "user_id": 4021}]
            }
          ]}
        }
        """#
        let http = FixtureHTTP([
            "/latest.json": .text(latest),
            "/site.json": .text("nope", status: 403),
        ])
        let notes = try await DiscourseClient(http: http, host: Self.host).latest(source: Self.source)

        #expect(notes.count == 3)
        #expect(notes.allSatisfy { $0.board == nil })
        #expect(notes.first?.title == "Give `retry_after` a documented default")
    }

    @Test("A filter's refusal is not a missing endpoint, and is not reported as one")
    func aRefusalIsItsOwnAnswer() async throws {
        // The distinction the reader is told about: 403 is a door somebody closed, 404 is a host
        // that is not a forum. Sending them to check their spelling for the first is sending
        // them after a fault that is not theirs.
        for status in [401, 403, 429, 503] {
            let http = FixtureHTTP([
                "/latest.json": .text("<html>checking your browser</html>", status: status),
                "/site.json": .text(#"{"categories":[]}"#),
            ])
            let client = DiscourseClient(http: http, host: Self.host)
            await #expect(throws: DiscourseRequestError.refused(status)) {
                _ = try await client.latest(source: Self.source)
            }
        }
        for status in [404, 500] {
            let http = FixtureHTTP([
                "/latest.json": .text("", status: status),
                "/site.json": .text(#"{"categories":[]}"#),
            ])
            let client = DiscourseClient(http: http, host: Self.host)
            await #expect(throws: DiscourseRequestError.http(status)) {
                _ = try await client.latest(source: Self.source)
            }
        }
    }

    @Test("A challenge page that answers 200 is a decode failure, not a timeline")
    func aChallengePageIsNotAForum() async throws {
        // Some filters answer 200 with HTML. It has to fail as "that was not a forum" rather
        // than as an empty front page, or the reader joins a source that draws nothing forever.
        let http = FixtureHTTP([
            "/latest.json": .text("<html><body>Just a moment…</body></html>"),
            "/site.json": .text(#"{"categories":[]}"#),
        ])
        let client = DiscourseClient(http: http, host: Self.host)
        await #expect(throws: (any Error).self) {
            _ = try await client.latest(source: Self.source)
        }
    }

    @Test("An avatar template is resolved against the forum, and only when this app would fetch it")
    func theAvatarIsResolvedAndChecked() {
        let resolved = LatestDTO.Topic.avatarURL(
            "/user_avatar/install-f.example/wrenmakar/{size}/4021_2.png",
            host: Self.host
        )
        #expect(resolved?.absoluteString == "https://install-f.example/user_avatar/install-f.example/wrenmakar/96/4021_2.png")

        // It arrives from a stranger's JSON, so it goes through the rule every other address in
        // this package does: nothing but https, and nothing this app would refuse to fetch.
        #expect(LatestDTO.Topic.avatarURL("javascript:alert(1)", host: Self.host) == nil)
        #expect(LatestDTO.Topic.avatarURL("http://elsewhere.test/a.png", host: Self.host) == nil)
        #expect(LatestDTO.Topic.avatarURL("", host: Self.host) == nil)
        #expect(LatestDTO.Topic.avatarURL(nil, host: Self.host) == nil)

        // An absolute https template — some forums put avatars on a CDN — is taken as it stands.
        let cdn = LatestDTO.Topic.avatarURL(
            "https://cdn.example/avatars/{size}/a.png",
            host: Self.host,
            size: 144
        )
        #expect(cdn?.absoluteString == "https://cdn.example/avatars/144/a.png")
    }

    @Test("The front page names itself in the HTML, before any script runs")
    func theFrontPageNamesTheSoftware() {
        // Discourse writes its name and version into a `generator` meta on every server-rendered
        // page. The decoys matter: the word appears all over a real page's asset names, and what
        // is read is the meta tag rather than the document.
        let html = #"""
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>A forum</title>
            <meta name="generator" content="Discourse 2026.9.0-latest - https://github.com/discourse/discourse version 0000000000000000000000000000000000000000">
            <link rel="canonical" href="https://install-f.example/" />
            <link href="https://cdn.example/stylesheets/common_0000000.css" media="all" rel="stylesheet" data-target="common" />
            <link href="https://cdn.example/stylesheets/discourse-ai_0000000.css" media="all" rel="stylesheet" data-target="discourse-ai" />
          </head>
          <body class="crawler">
            <div id="main-outlet"><h1>Latest topics</h1></div>
          </body>
        </html>
        """#
        #expect(HTMLKind.classify(html) == .named(.discourse))
    }

    @Test("This app says who it is, and does not claim to be a browser")
    func theAgentIsHonest() {
        // A filter in front of a forum is entitled to turn an app away; what it is not entitled
        // to is being lied to. The agent carries a name and a way to reach whoever wrote it.
        #expect(Fediqo.userAgent.contains("Fediqo"))
        #expect(Fediqo.userAgent.contains("https://"))
        for browser in ["Mozilla", "Chrome", "Safari", "AppleWebKit", "Gecko"] {
            #expect(!Fediqo.userAgent.contains(browser))
        }
    }
}
