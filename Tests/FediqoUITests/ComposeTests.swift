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
    private let held: String?
    private let gate: Gate?
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: Outcome], holding held: String? = nil, gate: Gate? = nil) {
        self.routes = routes
        self.held = held
        self.gate = gate
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let held, request.url?.path == held {
            await gate?.wait()
        }
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
        http: FixtureHTTP = FixtureHTTP(),
        holding: String? = nil,
        gate: Gate? = nil
    ) async throws -> (ShellSession, WriteServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token(host, scopes: scopes))
        let server = WriteServer(routes, gate: gate)
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

    private func surface(
        _ session: ShellSession, failed: String? = nil
    ) -> ComposerSheet.Surface {
        ComposerSheet.surface(
            offered: session.writableSources,
            draft: session.composeDraft,
            failed: failed
        )
    }

    @Test("A source they may not write on is not offered")
    func onlyWritableSourcesAreOffered() async throws {
        let (session, _, _) = try await shell(scopes: writing)
        session.mastodon.refusedWrite(host: host)
        #expect(session.writableSources.isEmpty)

        let (reads, _, _) = try await shell(scopes: MastodonOAuth.reading)
        #expect(reads.writableSources.isEmpty)
        #expect(reads.rows.first { $0.source.host == forum }?.writing == .never)

        let (writes, _, _) = try await shell(scopes: writing)
        #expect(writes.writableSources.map(\.host) == [host])
        writes.prepareCompose()
        #expect(writes.composeHost == host)
        #expect(writes.availability.canCompose)
        #expect(writes.availability.allows(.notices))
    }

    @Test("Closing without sending keeps the draft; the press takes it, and the post lands behind it")
    func theDraftSurvivesDismissAndClearsOnALanding() async throws {
        let (session, server, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json(Self.status())]
        )
        session.prepareCompose()
        session.composeDraft = "hello"
        session.composeAudience = .everyone
        #expect(session.composeDraft == "hello", "closing the sheet does not touch the session")

        #expect(session.send())
        #expect(session.composeDraft.isEmpty, "the press took the text")
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        #expect(session.notes.contains { $0.body == "hello" && $0.categories.contains(.home) })
        #expect(await server.form("/api/v1/statuses") == [
            "status": "hello", "visibility": "public",
        ])
        #expect(await server.paths == ["/api/v1/statuses"])
    }

    @Test("A send the source answers with a fault keeps the text, names the source, and is not called unsent: it may have been posted, and sending it again asks first")
    func aFailedSendKeepsTheText() async throws {
        let (session, server, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json("{}", status: 500)]
        )
        session.prepareCompose()
        session.composeDraft = "kept"
        #expect(session.send())
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.unsent.text == "kept")
        #expect(entry.standing == .unconfirmed, "a 500 is a fault past the door: the post may exist")
        #expect(session.notes.isEmpty)
        #expect(OutboxWords.line(entry, hold: nil, whom: nil).contains(host))
        #expect(OutboxWords.presses(entry, hold: session.outbox.hold(entry, in: session)).contains(.again))

        // Send again looks first; nobody can look here, so the person is asked, and the yes sends.
        #expect(await server.paths == ["/api/v1/statuses"])
        #expect(session.outbox.again(entry.id, in: session))
        await session.outbox.settled()
        #expect(session.resendingUnsent == UnsentAsk(id: entry.id))
        #expect(await server.paths == ["/api/v1/statuses"])
        #expect(session.outbox.sendAnyway(entry.id, in: session))
        await session.outbox.settled()
        #expect(await server.paths == ["/api/v1/statuses", "/api/v1/statuses"])
        #expect(session.outbox.sendings.map(\.unsent.text) == ["kept"])
    }

    @Test("A 403 marks the source refused and keeps the text")
    func aRefusedWriteIsMarked() async throws {
        let (session, _, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json("{}", status: 403)]
        )
        session.prepareCompose()
        session.composeDraft = "kept"
        #expect(session.send())
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.unsent.text == "kept")
        #expect(entry.standing == .failed(.refused))
        #expect(session.rows.first { $0.source.host == host }?.writing == .refused)
        #expect(session.writableSources.isEmpty)
        #expect(session.isSignedIn(host: host))
        #expect(surface(session, failed: host) == .composing, "the failure is not the empty notice")
    }

    @Test("A 401 that signs out keeps the text, and a refusal in hand is not the empty notice")
    func aSignOutOnWriteKeepsTheComposer() async throws {
        let (session, _, _) = try await shell(
            scopes: writing,
            routes: [
                "/api/v1/statuses": .json("{}", status: 401),
                "/api/v1/accounts/verify_credentials": .json("{}", status: 401),
            ]
        )
        session.prepareCompose()
        session.composeDraft = "kept"
        #expect(session.send())
        await session.outbox.settled()
        #expect(session.outbox.sendings.map(\.unsent.text) == ["kept"])
        #expect(session.outbox.sendings.first?.standing == .failed(.refused))
        #expect(!session.isSignedIn(host: host))
        #expect(session.writableSources.isEmpty)
        #expect(surface(session, failed: host) == .composing)
        #expect(
            ComposerSheet.surface(offered: [], draft: "", failed: nil) == .empty,
            "empty is only when there is nothing unsent and no failure"
        )
    }

    @Test("A draft typed after the press is untouched by the landing")
    func lateSuccessClearsOnlyTheSnapshot() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let (session, server, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json(Self.status())],
            holding: "/api/v1/statuses",
            gate: gate
        )
        session.prepareCompose()
        session.composeDraft = "hello"
        #expect(session.send())
        #expect(await spun { await server.paths.contains("/api/v1/statuses") })
        session.composeDraft = "newer"
        await gate.open()
        await session.outbox.settled()
        #expect(session.composeDraft == "newer")
        #expect(session.notes.contains { $0.body == "hello" })
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
        #expect(!session.send())
        await session.outbox.settled()
        #expect(await server.paths.isEmpty)
        #expect(session.outbox.sendings.isEmpty)
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
