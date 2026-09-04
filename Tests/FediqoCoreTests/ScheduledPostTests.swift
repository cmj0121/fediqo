import Foundation
import Testing
@testable import FediqoCore

/// The posts an account has written and not sent yet (#110).
///
/// Not statuses: what comes back is the parameters a post will be made from and when. It has no
/// address, no counts, nobody has replied to it, and it can still be called off.
@Suite("What you have not sent yet")
struct ScheduledPostTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    private func account(_ host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/users/me", token: "t")
    }

    /// **In the order they will go out**, which is the order that means anything here. Newest
    /// first — the order every other list in this app uses — would put the post going out last
    /// at the top of a list of what is about to happen.
    @Test("They are in the order they will go out")
    func inTheOrderTheyGo() async throws {
        let host = "waiting.scheduled.test"
        stubRoutes.on(host, "/api/v1/scheduled_statuses", status: 200, body: """
        [{"id": "2", "scheduled_at": "2026-09-06T09:00:00.000Z",
          "params": {"text": "later", "visibility": "public"}, "media_attachments": []},
         {"id": "1", "scheduled_at": "2026-09-05T09:00:00.000Z",
          "params": {"text": "sooner", "visibility": "private"}, "media_attachments": []}]
        """)

        let waiting = try await client.scheduled(as: account(host))
        #expect(waiting.map(\.text) == ["sooner", "later"])
        #expect(waiting.map(\.audience) == [.followers, .everyone])
    }

    /// The count and not the pictures: nothing here has been fetched, and a thumbnail would be a
    /// request made on behalf of a post that has not happened.
    @Test("What is attached is a number")
    func whatIsAttached() async throws {
        let host = "clips.scheduled.test"
        stubRoutes.on(host, "/api/v1/scheduled_statuses", status: 200, body: """
        [{"id": "1", "scheduled_at": "2026-09-05T09:00:00.000Z", "params": {"text": "with"},
          "media_attachments": [{"id": "a", "type": "image", "url": "https://clips.scheduled.test/a.png"},
                                {"id": "b", "type": "image", "url": "https://clips.scheduled.test/b.png"}]}]
        """)
        #expect(try await client.scheduled(as: account(host)).first?.attachments == 2)
    }

    /// A server that did not say who it goes to is not a server that said everyone. Guessing
    /// would be inventing the one fact about a post that cannot be taken back once it is out.
    @Test("An audience nobody stated is not everyone")
    func anaudienceNobodyStated() async throws {
        let host = "unstated.scheduled.test"
        stubRoutes.on(host, "/api/v1/scheduled_statuses", status: 200, body: """
        [{"id": "1", "scheduled_at": "2026-09-05T09:00:00.000Z", "params": {"text": "hm"},
          "media_attachments": []}]
        """)
        #expect(try await client.scheduled(as: account(host)).first?.audience == nil)
    }

    /// A time nobody can read is not a time to draw against a post. The whole entry is dropped
    /// rather than shown at a moment this app made up.
    @Test("A time that cannot be read is not invented")
    func atimeThatCannotBeRead() async throws {
        let host = "unreadable.scheduled.test"
        stubRoutes.on(host, "/api/v1/scheduled_statuses", status: 200, body: """
        [{"id": "1", "scheduled_at": "whenever", "params": {"text": "hm"}, "media_attachments": []}]
        """)
        #expect(try await client.scheduled(as: account(host)).isEmpty)
    }

    @Test("Calling one off names it to its own server")
    func callingOneOff() async throws {
        let host = "cancel.scheduled.test"
        stubRoutes.on(host, "/api/v1/scheduled_statuses/9", status: 200, body: "{}")
        try await client.cancelScheduled("9", as: account(host))
        let sent = try #require(stubRoutes.requests(for: host, "/api/v1/scheduled_statuses/9").first)
        #expect(sent.method == "DELETE")
    }

    /// **A protocol that cannot be asked is not an account with nothing waiting.** It throws, so
    /// the page leaves the band absent rather than telling the reader they have nothing queued
    /// when nobody looked.
    @Test("A protocol that cannot be asked says so")
    func aprotocolThatCannotBeAsked() async throws {
        await #expect(throws: (any Error).self) {
            try await Unscheduled().scheduled(as: account("nowhere.example"))
        }
    }

    private struct Unscheduled: StubClient {
        func timeline(host: String, limit: Int, before: Post?, after: Post?,
                      token: String?) async throws -> [Post] { [] }
    }
}
