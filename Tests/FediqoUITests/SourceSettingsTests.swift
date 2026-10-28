import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source listing the person's filters, and answering everything else as a sign-in check.
private actor FilterSource: HTTPSender {
    let filters: [String]

    init(_ filters: [String]) { self.filters = filters }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.url?.path == "/api/v2/filters" ? "[" + filters.joined(separator: ",") + "]" : #"{"id":"9","acct":"reader"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    static let fruit = #"{"id":"1","title":"Fruit","context":["home"],"expires_at":null,"filter_action":"warn","keywords":[],"statuses":[]}"#
}

/// #400: what is chosen for a joined source stands behind a gear on its page — only the parts the
/// source has, and the gear lit while something there narrows what is shown.
@MainActor
@Suite("What is chosen for a source is behind its gear")
struct SourceSettingsTests {
    private typealias F = NoticeActFixture
    private static let path = "/api/v2/notifications/policy"

    private static func policy(_ notFollowing: String) -> String {
        """
        {"for_not_following":"\(notFollowing)","for_not_followers":"accept","for_new_accounts":"accept",\
        "for_private_mentions":"accept","for_limited_accounts":"accept",\
        "summary":{"pending_requests_count":0,"pending_notifications_count":0}}
        """
    }

    @Test("A signed-in source lists what it has; whose notices it holds back once it has said; a source that is not one of yours has no gear")
    func theParts() async throws {
        let (session, _, _) = try await F.shell(
            [F.get(F.a, Self.path): .body(Self.policy("accept"))], signedIn: [F.a: F.acts, F.b: F.acts]
        )
        #expect(SourceSettings.parts(host: F.a, in: session) == [.line, .told, .filters])
        await session.noticeList.acts.look(host: F.a, in: session)
        #expect(SourceSettings.parts(host: F.a, in: session) == [.line, .told, .policy, .filters])
        // b has no such thing (404): absent, not dim.
        await session.noticeList.acts.look(host: F.b, in: session)
        #expect(!SourceSettings.parts(host: F.b, in: session).contains(.policy))
        #expect(SourceSettings.parts(host: "elsewhere.example", in: session).isEmpty)
    }

    @Test("The gear is lit while a kind of notice is not told, or someone's notices are held back, and out again when not")
    func theGearIsLit() async throws {
        let (session, _, _) = try await F.shell(
            [F.get(F.a, Self.path): .body(Self.policy("accept"))], signedIn: [F.a: F.acts]
        )
        await session.noticeList.acts.look(host: F.a, in: session)
        #expect(!SourceSettings.narrows(host: F.a, in: session))
        #expect(SourceSettings.spoken(narrows: false, language: .english) == "Nothing here narrows what is shown")

        let told = session.noticesTold
        told.choose(true, host: F.a)
        #expect(!SourceSettings.narrows(host: F.a, in: session), "telling every kind narrows nothing")
        told.tell("favourite", false, host: F.a)
        #expect(SourceSettings.narrows(host: F.a, in: session))
        told.tell("favourite", true, host: F.a)
        #expect(!SourceSettings.narrows(host: F.a, in: session))

        let (held, _, _) = try await F.shell(
            [F.get(F.a, Self.path): .body(Self.policy("filter"))], signedIn: [F.a: F.acts]
        )
        await held.noticeList.acts.look(host: F.a, in: held)
        #expect(SourceSettings.narrows(host: F.a, in: held), "notices held back narrow what is shown")
        for key in ["source.settings", "source.settings.title", "source.settings.back", "source.settings.narrows", "source.settings.plain"] {
            #expect(L10n.t(key, language: .taiwanese) != key && L10n.t(key, language: .english) != key)
        }
    }

    private static let host = "social.example"
    private static let forum = "forum.example"

    /// A Mastodon and a forum joined, signed in to the Mastodon with reading and filters, or not.
    private func joined(signedIn: Bool, filters: [String] = []) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(
                host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s",
                scopes: MastodonParts.page(held: nil, ticked: [.reading, .filters])
            ))
        }
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.add(Source(host: Self.forum, kind: .discourse))
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: FilterSource(filters))
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        return session
    }

    @Test("A joined source signed out of offers its line, its notices and its filters as asks to sign in; a joined forum has none of them, and no gear")
    func signedOutAndForum() async throws {
        let session = try await joined(signedIn: false)
        #expect(SourceSettings.parts(host: Self.host, in: session) == [.line, .told, .filters])
        guard case .signIn? = session.lines.offer(host: Self.host, in: session),
              case .signIn? = session.noticesTold.offer(host: Self.host, in: session),
              case .signIn? = session.serverFilters.offer(host: Self.host, in: session)
        else {
            Issue.record("a signed-out source offered a choice rather than the ask to sign in")
            return
        }
        // The forum tells nothing as it happens and has no notices or filters: absent, not dim.
        #expect(SourceSettings.parts(host: Self.forum, in: session).isEmpty, "a forum was given a gear")
        await SourceSettings.read(host: Self.forum, in: session)
        #expect(SourceSettings.parts(host: Self.forum, in: session).isEmpty)
    }

    @Test("A filter the server keeps lights the gear; with none it is out")
    func aFilterLightsTheGear() async throws {
        let none = try await joined(signedIn: true)
        await SourceSettings.read(host: Self.host, in: none)
        #expect(!SourceSettings.narrows(host: Self.host, in: none))

        let kept = try await joined(signedIn: true, filters: [FilterSource.fruit])
        await SourceSettings.read(host: Self.host, in: kept)
        guard case .read(let filters)? = kept.serverFilters.reading[Self.host] else {
            Issue.record("the filters were not read as the page opened")
            return
        }
        #expect(filters.count == 1)
        #expect(SourceSettings.narrows(host: Self.host, in: kept))
        #expect(SourceSettings.spoken(narrows: true, language: .english) == "Something here narrows what is shown")
    }
}
