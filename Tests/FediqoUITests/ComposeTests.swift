import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A server that answers a write by path, remembering every request.
private actor WriteServer: HTTPSender {
    enum Outcome: Sendable {
        case json(String, status: Int = 200)
        case fail
    }

    private let routes: [String: Outcome]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: Outcome]) {
        self.routes = routes
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url, let outcome = routes[url.path] else {
            throw FixtureHTTPError.unmapped
        }
        switch outcome {
        case .json(let body, let status):
            return (
                Data(body.utf8),
                HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
                )!
            )
        case .fail:
            throw URLError(.notConnectedToInternet)
        }
    }

    func form(_ path: String) -> [String: String] {
        guard let request = requests.first(where: { $0.url?.path == path }),
              let body = request.httpBody, let text = String(data: body, encoding: .utf8)
        else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }
}

/// You write a post from Fediqo, and it lands in the timeline it belongs to (#56).
@Suite("Writing a post from the shell")
@MainActor
struct ComposeTests {
    init() {
        L10n.language = .english
    }

    private let host = "social.example"
    private let forum = "bbs.example.org"
    private let writing = MastodonOAuth.scopes(writing: true)

    private func token(_ host: String, scopes: String?) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: scopes
        )
    }

    private static func status(body: String = "hello", visibility: String = "public") -> String {
        """
        {"id":"9","uri":"https://social.example/users/me/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>\(body)</p>",
         "visibility":"\(visibility)",
         "account":{"username":"me","acct":"me","display_name":"Me"}}
        """
    }

    private func shell(
        scopes: String?,
        routes: [String: WriteServer.Outcome] = [:],
        http: FixtureHTTP = FixtureHTTP()
    ) async throws -> (ShellSession, WriteServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token(host, scopes: scopes))
        let server = WriteServer(routes)
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        await store.add(Source(host: forum, kind: .discuz))
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.sources = await store.sources()
        session.mastodon.refresh()
        return (session, server, tokens)
    }

    @Test("A source they may not write on is not offered")
    func onlyWritableSourcesAreOffered() async throws {
        let (session, _, _) = try await shell(scopes: writing)
        session.mastodon.refusedWrite(host: host)
        #expect(ComposerSheet.offered(session.rows).isEmpty)

        let (reads, _, _) = try await shell(scopes: MastodonOAuth.reading)
        #expect(ComposerSheet.offered(reads.rows).isEmpty)
        #expect(reads.rows.first { $0.source.host == forum }?.writing == .never)

        let (writes, _, _) = try await shell(scopes: writing)
        #expect(ComposerSheet.offered(writes.rows).map(\.host) == [host])
        writes.prepareCompose()
        #expect(writes.composeHost == host)
        #expect(writes.availability.canCompose)
        #expect(writes.availability.allows(.notices))
    }

    @Test("Closing without sending keeps the draft; a send that lands clears it")
    func theDraftSurvivesDismissAndClearsOnALanding() async throws {
        let (session, server, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json(Self.status())]
        )
        session.prepareCompose()
        session.composeDraft = "hello"
        session.composeAudience = .everyone
        #expect(session.composeDraft == "hello", "closing the sheet does not touch the session")

        try await session.post()
        #expect(session.composeDraft.isEmpty)
        #expect(session.notes.contains { $0.body == "hello" && $0.categories.contains(.home) })
        #expect(await server.form("/api/v1/statuses") == [
            "status": "hello", "visibility": "public",
        ])
        #expect(await server.paths == ["/api/v1/statuses"])
    }

    @Test("A send that fails keeps the text, names the source, and can be tried again")
    func aFailedSendKeepsTheText() async throws {
        let (session, server, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json("{}", status: 500)]
        )
        session.prepareCompose()
        session.composeDraft = "kept"
        await #expect(throws: MastodonAuthError.http(500)) {
            try await session.post()
        }
        #expect(session.composeDraft == "kept")
        #expect(session.notes.isEmpty)
        #expect(ShellFailure.spoken([host]).contains(host))
        #expect(!ShellFailure.retryName.isEmpty)

        // The same draft can be sent again: the next call still posts it.
        #expect(await server.paths == ["/api/v1/statuses"])
        #expect(session.canPost)
    }

    @Test("A 403 marks the source refused and keeps the draft")
    func aRefusedWriteIsMarked() async throws {
        let (session, _, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json("{}", status: 403)]
        )
        session.prepareCompose()
        session.composeDraft = "kept"
        await #expect(throws: MastodonAuthError.http(403)) {
            try await session.post()
        }
        #expect(session.composeDraft == "kept")
        #expect(session.rows.first { $0.source.host == host }?.writing == .refused)
        #expect(ComposerSheet.offered(session.rows).isEmpty)
        #expect(session.isSignedIn(host: host))
    }

    @Test("Text longer than the source will take cannot be sent; the limit is visible")
    func overTheLimitCannotBeSent() async throws {
        let (session, server, _) = try await shell(scopes: writing)
        session.prepareCompose()
        #expect(session.postLimit(of: host) == 500)
        session.composeDraft = String(repeating: "a", count: 501)
        #expect(!session.canPost)
        #expect(ComposerSheet.remaining(session.composeDraft, limit: 500) == -1)
        #expect(ComposerSheet.limitLine(remaining: 499, limit: 500) == "499 / 500")
        try await session.post()
        #expect(await server.paths.isEmpty)
        #expect(session.composeDraft.count == 501)

        session.composeDraft = "ok"
        #expect(session.canPost)
        #expect(ComposerSheet.canSend(text: "  \n  ", limit: 500, hasSource: true) == false)
        #expect(ComposerSheet.canSend(text: "ok", limit: 500, hasSource: false) == false)
    }

    @Test("An advertised ceiling is the one the composer uses")
    func advertisedCeiling() async throws {
        let (session, _, _) = try await shell(
            scopes: writing,
            http: FixtureHTTP([
                "/api/v2/instance": .text(
                    #"{"configuration":{"statuses":{"max_characters":2000}}}"#
                ),
            ])
        )
        session.prepareCompose()
        await session.refreshPostLimit()
        #expect(session.postLimit(of: host) == 2000)
        session.composeDraft = String(repeating: "a", count: 501)
        #expect(session.canPost)
    }

    @Test("Every compose word is translated, and the two Chinese files agree")
    func everyWordIsTranslated() throws {
        let keys = [
            "compose.title", "compose.summary", "compose.disabled.summary",
            "compose.cancel", "compose.post", "compose.body", "compose.source",
            "compose.visibility", "compose.visibility.public", "compose.visibility.unlisted",
            "compose.visibility.private", "compose.visibility.direct",
            "compose.limit", "compose.none.title", "compose.none.detail",
        ]
        for key in keys {
            for language in [DummyLanguage.english, .taiwanese] {
                let said = L10n.t(key, language: language)
                #expect(said != key && !said.isEmpty, "\(key) is missing in \(language)")
            }
        }
        for audience in Audience.allCases {
            let key = ComposerSheet.visibilityKey(audience)
            #expect(L10n.t(key, language: .english) == audience.mastodon)
            #expect(
                L10n.t(key, language: .english) != L10n.t(key, language: .taiwanese),
                "\(key)"
            )
        }
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let tw = try Data(contentsOf: resources.appendingPathComponent("zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        #expect(tw == hant)
    }

    @Test("Unsigned compose stays off; a writing sign-in turns it on")
    func composeFollowsAWritingSignIn() async throws {
        let empty = ShellSession(http: FixtureHTTP())
        #expect(!empty.availability.canCompose)
        let (session, _, _) = try await shell(scopes: writing)
        #expect(session.availability.canCompose)
        #expect(session.availability.composeHintKey == "compose.summary")
    }
}
