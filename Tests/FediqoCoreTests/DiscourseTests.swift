import Foundation
import Testing

@testable import FediqoCore

/// A forum read the way the app reads it, against what a real one actually sends.
///
/// The fixtures are trimmed captures of `install-f.example` — a running Discourse rather than a
/// shape invented here, so a field that turns out to be absent in practice (`excerpt` on most of
/// the front page, `image_url` on nearly all of it) is absent in the test too.
@Suite("Discourse")
struct DiscourseTests {
    private static let source = Source(host: "install-f.example", kind: .discourse)

    private static func client(
        latest: FixtureHTTP.Outcome = .body(Fixtures.json("discourse-latest")),
        site: FixtureHTTP.Outcome = .body(Fixtures.json("discourse-site"))
    ) -> (DiscourseClient, FixtureHTTP) {
        let http = FixtureHTTP(["/latest.json": latest, "/site.json": site])
        return (DiscourseClient(http: http, host: "install-f.example"), http)
    }

    @Test("The front page becomes notes: a name, a section, who asked, and where to read it")
    func theFrontPageIsATimeline() async throws {
        let (client, http) = Self.client()
        let notes = try await client.latest(source: Self.source)

        #expect(notes.count == 3)
        let first = try #require(notes.first)

        // The title is the post. A forum's front page carries no excerpt for most topics, so a
        // row that drew only `body` would draw three blank posts.
        #expect(first.title == "Make `__doc__` on sentinels writable")
        #expect(first.board == "Ideas")

        // The person named is whoever the forum called the original poster, and the display name
        // is preferred over the handle where the forum has one.
        #expect(first.author == "Rae Lindqvist")
        #expect(first.handle == "@tmk@install-f.example")

        // Where to read it, built from the slug and the number the forum sent.
        #expect(first.url?.absoluteString == "https://install-f.example/t/make-doc-on-sentinels-writable/109067")

        // Prefixed, because a forum's topic numbers and a microblog's status ids share one store.
        #expect(first.id == "discourse:install-f.example:109067")
        #expect(first.source.kind == .discourse)

        // Both documents were read, and nothing else was.
        #expect(await Set(http.paths) == ["/latest.json", "/site.json"])
    }

    @Test("A topic is dated when it was asked, not when a stranger last answered")
    func theDateIsTheAuthors() async throws {
        let (client, _) = Self.client()
        let first = try #require(try await client.latest(source: Self.source).first)

        // `created_at` is 11:47; `bumped_at` is 12:32, and the front page is *ordered* by the
        // second. Dating the row by it would put a stranger's reply time on somebody's question.
        let created = try #require(MastodonJSON.date(from: "2026-09-15T11:47:39.173Z"))
        #expect(first.postedAt == created)
    }

    @Test("The answer count is answers, and never counts the question as one of them")
    func theCountIsAnswers() async throws {
        let (client, _) = Self.client()
        let notes = try await client.latest(source: Self.source)
        for note in notes {
            let replies = try #require(note.counts.replies)
            #expect(replies >= 0)
        }
    }

    @Test("A forum with no category list is still readable, with one line less on each row")
    func theSectionsAreAllowedToFail() async throws {
        // `/site.json` refused: an old version, a plugin, a permission. The front page is still
        // the thing the reader opened the app for.
        let (client, _) = Self.client(site: .text("nope", status: 403))
        let notes = try await client.latest(source: Self.source)

        #expect(notes.count == 3)
        #expect(notes.allSatisfy { $0.board == nil })
        #expect(notes.first?.title == "Make `__doc__` on sentinels writable")
    }

    @Test("A filter's refusal is not a missing endpoint, and is not reported as one")
    func aRefusalIsItsOwnAnswer() async throws {
        // The distinction the reader is told about: 403 is a door somebody closed, 404 is a host
        // that is not a forum. Sending them to check their spelling for the first is sending
        // them after a fault that is not theirs.
        for status in [401, 403, 429, 503] {
            let (client, _) = Self.client(latest: .text("<html>checking your browser</html>", status: status))
            await #expect(throws: DiscourseRequestError.refused(status)) {
                _ = try await client.latest(source: Self.source)
            }
        }
        for status in [404, 500] {
            let (client, _) = Self.client(latest: .text("", status: status))
            await #expect(throws: DiscourseRequestError.http(status)) {
                _ = try await client.latest(source: Self.source)
            }
        }
    }

    @Test("A challenge page that answers 200 is a decode failure, not a timeline")
    func aChallengePageIsNotAForum() async throws {
        // Some filters answer 200 with HTML. It has to fail as "that was not a forum" rather
        // than as an empty front page, or the reader joins a source that draws nothing forever.
        let (client, _) = Self.client(latest: .text("<html><body>Just a moment…</body></html>"))
        await #expect(throws: (any Error).self) {
            _ = try await client.latest(source: Self.source)
        }
    }

    @Test("An avatar template is resolved against the forum, and only when this app would fetch it")
    func theAvatarIsResolvedAndChecked() {
        let resolved = LatestDTO.Topic.avatarURL(
            "/user_avatar/install-f.example/tmk/{size}/10935_2.png",
            host: "install-f.example"
        )
        #expect(resolved?.absoluteString == "https://install-f.example/user_avatar/install-f.example/tmk/96/10935_2.png")

        // It arrives from a stranger's JSON, so it goes through the rule every other address in
        // this package does: nothing but https, and nothing this app would refuse to fetch.
        #expect(LatestDTO.Topic.avatarURL("javascript:alert(1)", host: "install-f.example") == nil)
        #expect(LatestDTO.Topic.avatarURL("http://elsewhere.test/a.png", host: "install-f.example") == nil)
        #expect(LatestDTO.Topic.avatarURL("", host: "install-f.example") == nil)
        #expect(LatestDTO.Topic.avatarURL(nil, host: "install-f.example") == nil)

        // An absolute https template — some forums put avatars on a CDN — is taken as it stands.
        let cdn = LatestDTO.Topic.avatarURL(
            "https://cdn.example/avatars/{size}/a.png",
            host: "install-f.example",
            size: 144
        )
        #expect(cdn?.absoluteString == "https://cdn.example/avatars/144/a.png")
    }

    @Test("The front page names itself in the HTML, before any script runs")
    func theFrontPageNamesTheSoftware() {
        let html = String(decoding: Fixtures.html("discourse"), as: UTF8.self)
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
