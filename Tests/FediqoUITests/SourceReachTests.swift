import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #299: the one place a source is reached from, asked directly — what `SourceReachPinTests`
/// cannot see from outside a session. Written with the place itself, where those pins were
/// written before it.
@MainActor
@Suite("The one place a source is reached from")
struct SourceReachTests {
    @Test("A forum's client is built through that forum's own sign-in and no other's: building one for the forum signed in to goes to its browser, and building one for any other host starts none — a Discuz! and a Discourse alike")
    func aForumsClientCarriesItsOwnSignIn() async {
        for discourse in [false, true] {
            let forums = ForumSessions(credentials: MemoryCredentials())
            let session = ShellSession(http: FixtureHTTP(), forums: forums)
            session.sources = [Source(host: "cookie.example", kind: .discuz), Source(host: "other.example", kind: .discuz)]
            await forums.plantSession(host: "cookie.example")
            let reach = session.reach
            func build(_ host: String) {
                if discourse {
                    _ = reach.discourse(host, for: .timeline, within: nil)
                } else {
                    _ = reach.discuz(host, for: .timeline, within: nil)
                }
            }
            build("other.example")
            #expect(!forums.hasEngine(host: "other.example") && !forums.hasEngine(host: "cookie.example"), "another host's read reached for a forum's browser")
            build("cookie.example")
            #expect(forums.hasEngine(host: "cookie.example"), "the forum signed in to was read around its browser")
            #expect(!forums.hasEngine(host: "other.example"))
        }
        // With no sign-ins to ask, every forum is read through the plain client.
        let plain = FixtureHTTP()
        #expect((SourceReach(http: plain, work: SourceWork()).base(for: "cookie.example") as? FixtureHTTP) === plain)
    }

    @Test("An unsigned Mastodon client never reaches for a forum's browser, whatever host it names; and a wire with no limit is listed and not bounded, where one with a limit is bounded")
    func aMastodonIsPlain() async throws {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        session.sources = [Source(host: "cookie.example", kind: .discuz)]
        await forums.plantSession(host: "cookie.example")
        let reach = session.reach
        #expect(forums.readsThroughEngine(host: "cookie.example"), "the premise")
        _ = reach.mastodon("cookie.example", for: .timeline, within: nil)
        _ = reach.unsignedPost("cookie.example", for: .conversation, within: .seconds(1))
        _ = reach.unsignedTag("cookie.example", name: nil, within: .seconds(1))
        #expect(!forums.hasEngine(host: "cookie.example"))
        #expect(reach.wire(for: .timeline, within: nil) is WatchedHTTP)
        #expect(reach.wire(for: .timeline, within: .seconds(1)) is Deadline)
        let named = try #require(reach.wire(for: .lists, name: .called("Dev"), within: nil) as? WatchedHTTP)
        #expect(named.purpose == .lists && named.name == .called("Dev"))
    }
}
