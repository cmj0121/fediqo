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
        _ = reach.unsignedPerson("cookie.example", for: .timeline, within: .seconds(1))
        #expect(!forums.hasEngine(host: "cookie.example"))
        #expect(reach.wire(for: .timeline, within: nil) is WatchedHTTP)
        #expect(reach.wire(for: .timeline, within: .seconds(1)) is Deadline)
        let named = try #require(reach.wire(for: .lists, name: .called("Dev"), within: nil) as? WatchedHTTP)
        #expect(named.purpose == .lists && named.name == .called("Dev"))
    }

    @Test("Somebody read with no token is read through a wire of this place: the ask is written in the run's record under the source asked and the purpose it was made for, and is bounded")
    func somebodyReadUnsignedIsListed() async throws {
        let work = SourceWork()
        let http = FixtureHTTP(["/api/v1/accounts/42": .text(#"{"id":"42","acct":"a","display_name":"A"}"#)])
        let reach = SourceReach(http: http, work: work)
        let source = Source(host: "mastodon.example", kind: .mastodon)
        let person = try await reach.unsignedPerson(source.host, for: .timeline, within: .seconds(5)).person(id: "42", source: source)
        #expect(person.handle == "@a@mastodon.example" && person.name == "A")
        #expect(await http.paths == ["/api/v1/accounts/42"])
        let acts = work.record.filter { $0.reached == source.host }
        #expect(acts.count == 1 && acts.first?.purpose == .timeline && acts.first?.source == source.host)
    }

    @Test("Somebody read with no token is read under the ceiling a signed-in read has: the live client is held to it as it transfers, with its session and its rules as they were, an answer past it is refused, and no other unsigned read is changed")
    func somebodyReadUnsignedIsSmall() async throws {
        let live = URLSessionClient(sameOriginOnly: true)
        let small = try #require(SourceReach(http: live, work: SourceWork()).small() as? URLSessionClient)
        #expect(small.byteLimit == SourceReach.smallBody && SourceReach.smallBody == 1 << 20)
        #expect(small.session === live.session && small.sameOriginOnly && small.watchedOnly)
        #expect(live.capped(to: .max).byteLimit == URLSessionClient.defaultByteLimit, "a ceiling is never raised")

        let big = #"{"id":"42","acct":"a","note":"\#(String(repeating: "w", count: SourceReach.smallBody))"}"#
        let http = FixtureHTTP(["/api/v1/accounts/42": .text(big), "/api/v1/accounts/42/statuses": .text("[]")])
        let reach = SourceReach(http: http, work: SourceWork())
        let source = Source(host: "mastodon.example", kind: .mastodon)
        let reader = reach.unsignedPerson(source.host, for: .timeline, within: .seconds(5))
        await #expect(throws: URLError.self) { _ = try await reader.person(id: "42", source: source) }
        #expect(try await reader.posts(of: "42", source: source).posts.isEmpty)
        // The plain wire is as it was.
        #expect(try await reach.wire(for: .timeline, within: nil).data(from: try #require(URL(string: "https://mastodon.example/api/v1/accounts/42"))).0.count > SourceReach.smallBody)
    }
}
