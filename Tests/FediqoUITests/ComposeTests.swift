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
@Suite("Writing a post from the shell", .watched)
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

    private static func status(body: String = "hello", visibility: String = "public", extra: String = "") -> String {
        """
        {"id":"9","uri":"https://social.example/users/me/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>\(body)</p>",
         "visibility":"\(visibility)"\(extra),
         "account":{"username":"me","acct":"me","display_name":"Me"}}
        """
    }

    /// The form as it was sent, keys decoded, repeated keys kept.
    private static func pairs(_ request: URLRequest) -> [(String, String)] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [] }
        return text.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].removingPercentEncoding ?? parts[0]
            let value = (parts.count > 1 ? parts[1].removingPercentEncoding : "") ?? ""
            return (key, value)
        }
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
        let server = WriteServer(routes, holding: holding, gate: gate)
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
            draft: session.composeDraft.text,
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
        session.composeDraft.text = "hello"
        session.composeDraft.audience = .everyone
        #expect(session.composeDraft.text == "hello", "closing the sheet does not touch the session")

        #expect(session.send())
        #expect(session.composeDraft.text.isEmpty, "the press took the text")
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
        session.composeDraft.text = "kept"
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
        session.composeDraft.text = "kept"
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
        session.composeDraft.text = "kept"
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
        let watchdog = watching(gate, "the post, held on the wire")
        defer { watchdog.cancel() }
        let (session, server, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json(Self.status())],
            holding: "/api/v1/statuses",
            gate: gate
        )
        session.prepareCompose()
        session.composeDraft.text = "hello"
        #expect(session.send())
        let sending = Task { await session.outbox.settled() }
        await met("the post is on the wire", by: sending) { await server.paths.contains("/api/v1/statuses") }
        session.composeDraft.text = "newer"
        await gate.open()
        await session.outbox.settled()
        #expect(session.composeDraft.text == "newer")
        #expect(session.notes.contains { $0.body == "hello" })
    }

    @Test("Text longer than the source will take cannot be sent; the limit is visible")
    func overTheLimitCannotBeSent() async throws {
        let (session, server, _) = try await shell(scopes: writing)
        session.prepareCompose()
        #expect(session.postLimit(of: host) == 500)
        session.composeDraft.text = String(repeating: "a", count: 501)
        #expect(!session.canPost)
        #expect(ComposerSheet.remaining(session.composeDraft.text, limit: 500) == -1)
        #expect(ComposerSheet.limitLine(remaining: 499, limit: 500) == "499 / 500")
        #expect(!session.send())
        await session.outbox.settled()
        #expect(await server.paths.isEmpty)
        #expect(session.outbox.sendings.isEmpty)
        #expect(session.composeDraft.text.count == 501)

        session.composeDraft.text = "ok"
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
        session.composeDraft.text = String(repeating: "a", count: 501)
        #expect(session.canPost)
    }

    @Test("Every compose word is translated, and the two Chinese files agree")
    func everyWordIsTranslated() throws {
        let keys = [
            "compose.title", "compose.summary", "compose.disabled.summary",
            "compose.cancel", "compose.post", "compose.body", "compose.source",
            "compose.visibility", "compose.visibility.public", "compose.visibility.unlisted",
            "compose.visibility.private", "compose.visibility.direct",
            "compose.limit", "compose.cover", "compose.language", "compose.sensitive",
            "compose.media.add", "compose.media.remove", "compose.media.description",
            "compose.media.count", "compose.media.tooLarge", "compose.media.tooMany",
            "compose.media.kind", "compose.media.description.over", "compose.media.unreadable",
            "compose.none.title", "compose.none.detail", "item.via",
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

    @Test("A cover within the limit can be sent, a cover past it cannot, and files alone can while a cover alone cannot")
    func aCoverAndFilesAreHeldToTheSameLimit() {
        #expect(ComposerSheet.canSend(text: "ok", limit: 500, hasSource: true, cover: "mind"))
        #expect(!ComposerSheet.canSend(text: "ok", limit: 10, hasSource: true, cover: String(repeating: "c", count: 11)))
        #expect(ComposerSheet.canSend(text: "", limit: 500, hasSource: true, attachments: 2))
        #expect(!ComposerSheet.canSend(text: "", limit: 500, hasSource: true, cover: "only a cover"))
        #expect(!ComposerSheet.canSend(text: "ok", limit: 500, hasSource: true, attachments: 1, attachmentsOK: false))
    }

    @Test("A file over the ceiling the source stated is refused with that ceiling named, and the words stay")
    func tooLargeKeepsTheWords() async throws {
        let (session, server, _) = try await shell(scopes: writing + " write:media")
        session.prepareCompose()
        session.composeDraft.text = "kept"
        session.composeRooms[host] = ComposeRoom(
            limit: 500,
            media: MastodonMediaLimits(count: 4, descriptionLimit: 1500, imageBytes: 1024, videoBytes: nil, mimeTypes: [])
        )
        let note = session.composeAttach(bytes: Data(count: 1025), name: "big.png", type: "image/png")
        #expect(note?.contains("1 KiB") == true)
        #expect(note?.contains(host) == true)
        #expect(session.composeDraft.text == "kept")
        #expect(session.composeDraft.media.isEmpty)
        #expect(session.canPost)
        #expect(await server.paths.isEmpty)

        let fifth = (0..<4).allSatisfy { _ in
            session.composeAttach(bytes: Data([1]), name: "ok.png", type: "image/png") == nil
        }
        #expect(fifth)
        let tooMany = session.composeAttach(bytes: Data([1]), name: "fifth.png", type: "image/png")
        #expect(tooMany?.contains(host) == true)
        #expect(session.composeDraft.media.count == 4)
        #expect(session.composeDraft.text == "kept")
    }

    @Test("Adding media the sign-in was not asked for says what the page will ask, and does not open it or the picker")
    func addingMediaAsksBeforeThePage() async throws {
        let (session, server, _) = try await shell(scopes: writing)
        session.prepareCompose()
        session.composeDraft.text = "kept"
        session.composeAddMedia()
        let ask = try #require(session.partAsks.open)
        #expect(ask.ticked == [.media])
        let question = ShellQuestion.part(ask)
        #expect(question.line.contains("media"))
        #expect(question.help?.contains("picture") == true)
        #expect(question.help?.contains("description") == true)
        #expect(session.composeDraft.text == "kept")
        #expect(!session.composeImporting)
        #expect(await server.paths.isEmpty)
    }

    @Test("A new post starts from what the source said, and a late answer does not overwrite a choice already made")
    func aNewPostStartsFromTheSource() async throws {
        let prefs = #"""
        {"posting:default:visibility":"private","posting:default:language":"zh-TW","posting:default:sensitive":true}
        """#
        let (session, _, _) = try await shell(
            scopes: writing, routes: ["/api/v1/preferences": .json(prefs)]
        )
        session.prepareCompose()
        await session.loadComposeDefaults()
        #expect(session.composeDraft.audience == .followers)
        #expect(session.composeDraft.language == "zh-tw")
        #expect(session.composeDraft.coversMedia == true)
        #expect(!session.composeTouchedLanguage)

        let gate = Gate()
        let watchdog = watching(gate, "the defaults, held on the wire")
        defer { watchdog.cancel() }
        let (late, server, _) = try await shell(
            scopes: writing, routes: ["/api/v1/preferences": .json(prefs)],
            holding: "/api/v1/preferences", gate: gate
        )
        late.prepareCompose()
        let loading = Task { await late.loadComposeDefaults() }
        await met("the defaults are on the wire", by: loading) { await server.paths.contains("/api/v1/preferences") }
        late.composeTouchedLanguage = true
        late.composeDraft.language = "fr"
        await gate.open()
        await loading.value
        #expect(late.composeDraft.language == "fr")
        #expect(late.composeDraft.audience == .followers)
        #expect(late.composeDraft.coversMedia == true)
        #expect(!late.composeTouchedAudience)
    }

    @Test("What a source said a new post starts from, let go by a change of it, is asked again; an answer out before that lands nowhere")
    func aChangeLetsTheDefaultsGo() async throws {
        let prefs = #"{"posting:default:sensitive":true}"#
        let gate = Gate()
        let watchdog = watching(gate, "the defaults, held on the wire")
        defer { watchdog.cancel() }
        let (session, server, _) = try await shell(
            scopes: writing, routes: ["/api/v1/preferences": .json(prefs)],
            holding: "/api/v1/preferences", gate: gate
        )
        session.prepareCompose()
        let host = try #require(session.composeHost)
        let loading = Task { await session.loadComposeDefaults() }
        await met("the defaults are on the wire", by: loading) { await server.paths.contains("/api/v1/preferences") }
        session.postingDefaultsChanged(at: host)
        await gate.open()
        await loading.value
        #expect(session.composeDraft.coversMedia != true, "said before the change: lands nowhere")

        await session.loadComposeDefaults()
        #expect(session.composeDraft.coversMedia == true, "asked again")
        #expect(await server.paths.filter { $0 == "/api/v1/preferences" }.count == 2)
    }

    @Test("Two described pictures are sent to that source alone, and the post names both")
    func twoDescribedPicturesGoWithThePost() async throws {
        let posted = Self.status(body: "with pictures", extra: #"""
        ,"spoiler_text":"mind","language":"zh-tw","sensitive":true,"application":{"name":"Fediqo"},
         "media_attachments":[
           {"type":"image","url":"https://social.example/m1.jpg","description":"a hill"},
           {"type":"image","url":"https://social.example/m2.jpg","description":"a bird"}]
        """#)
        let server = MediaServer(media: [
            .init(status: 200, body: #"{"id":"m1"}"#),
            .init(status: 200, body: #"{"id":"m2"}"#),
        ], status: posted)
        let session = try await mediaShell(server)
        session.prepareCompose()
        session.composeDraft.text = "with pictures"
        session.composeDraft.cover = "mind"
        session.chooseLanguage("zh-TW")
        session.chooseCoversMedia(true)
        #expect(session.composeAttach(bytes: Data("hill".utf8), name: "hill.png", type: "image/png", description: "a hill") == nil)
        #expect(session.composeAttach(bytes: Data("bird".utf8), name: "bird.png", type: "image/png", description: "a bird") == nil)
        #expect(session.send())
        await session.outbox.settled()

        let requests = await server.requests
        #expect(requests.map { $0.url?.path } == ["/api/v2/media", "/api/v2/media", "/api/v1/statuses"])
        #expect(requests.allSatisfy { $0.url?.host() == host })
        let uploads = requests.filter { $0.url?.path == "/api/v2/media" }
        #expect(uploads.allSatisfy { $0.value(forHTTPHeaderField: MastodonWrite.idempotencyKey) == nil })
        #expect(uploads[0].httpBody?.range(of: Data("a hill".utf8)) != nil)
        #expect(uploads[1].httpBody?.range(of: Data("a bird".utf8)) != nil)
        let form = Self.pairs(requests[2])
        #expect(form.filter { $0.0 == "media_ids[]" }.map(\.1) == ["m1", "m2"])
        #expect(form.contains { $0 == ("spoiler_text", "mind") })
        #expect(form.contains { $0 == ("language", "zh-tw") })
        #expect(form.contains { $0 == ("sensitive", "true") })
        #expect(requests[2].value(forHTTPHeaderField: MastodonWrite.idempotencyKey) != nil)
        let note = try #require(session.notes.first { $0.body == "with pictures" })
        #expect(note.attachments.map(\.alt) == ["a hill", "a bird"])
        #expect(note.covered == true)
        #expect(note.via == "Fediqo")
        #expect(note.language == "zh-tw")
        let item = DummyItem(note)
        #expect(item.covered && item.via == "Fediqo")
        #expect(DummyItemRow.viaLine(item.via) == "via Fediqo")
        #expect(DummyItemRow.viaLine(nil) == nil && DummyItemRow.viaLine("") == nil)
        #expect(DummyItemRow.viaLine("Fediqo", language: .taiwanese) == "來自 Fediqo")
    }

    @Test("A file refused part-way leaves the post unsent and whole, and trying again does not upload the one already taken")
    func aFailurePartWayLeavesThePostWhole() async throws {
        let server = MediaServer(media: [
            .init(status: 200, body: #"{"id":"m1"}"#),
            .init(status: 422, body: "{}"),
            .init(status: 200, body: #"{"id":"m2"}"#),
        ], status: Self.status(body: "kept"))
        let session = try await mediaShell(server)
        session.prepareCompose()
        session.composeDraft.text = "kept"
        #expect(session.composeAttach(bytes: Data("hill".utf8), name: "hill.png", type: "image/png", description: "a hill") == nil)
        #expect(session.composeAttach(bytes: Data("bird".utf8), name: "bird.png", type: "image/png", description: "a bird") == nil)
        #expect(session.send())
        await session.outbox.settled()

        let failed = try #require(session.outbox.sendings.first)
        #expect(failed.unsent.text == "kept")
        #expect(failed.unsent.media.map(\.remoteID) == ["m1", nil])
        #expect(failed.standing == .failed(.declined))
        #expect(await server.paths == ["/api/v2/media", "/api/v2/media"])
        #expect(session.outbox.again(failed.id, in: session))
        await session.outbox.settled()

        let requests = await server.requests
        #expect(requests.map { $0.url?.path } == ["/api/v2/media", "/api/v2/media", "/api/v2/media", "/api/v1/statuses"])
        #expect(requests[2].httpBody?.range(of: Data("a bird".utf8)) != nil)
        #expect(requests[2].httpBody?.range(of: Data("a hill".utf8)) == nil)
        #expect(Self.pairs(requests[3]).filter { $0.0 == "media_ids[]" }.map(\.1) == ["m1", "m2"])
        #expect(requests.filter { $0.url?.path == "/api/v1/statuses" }.count == 1)
        #expect(requests.allSatisfy { $0.url?.host() == host })
        #expect(session.notes.contains { $0.body == "kept" })
    }

    /// A writing sign-in that may also attach media, talking to `server`.
    // MARK: - A poll (#331)

    @Test("A post with a poll goes with its words, its choices as typed, how long it runs and both answers; the poll goes with the post and the next starts without one")
    func aPostWithAPoll() async throws {
        let (session, server, _) = try await shell(
            scopes: writing,
            routes: ["/api/v1/statuses": .json(Self.status(body: "Which?"))]
        )
        session.prepareCompose()
        session.composeDraft.text = "Which?"
        session.composeAddPoll()
        #expect(session.composeDraft.poll == NewPoll.fresh)
        #expect(!session.canPost, "two empty choices are no poll")
        session.composeDraft.poll?.choices = ["Tea", "Coffee"]
        session.composeDraft.poll?.multiple = true
        session.composeDraft.poll?.hidesTotals = true
        session.composeDraft.poll?.runs = 3600
        #expect(session.canPost)
        #expect(session.send())
        #expect(session.composeDraft.poll == nil)
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        let sent = try #require(await server.requests.first)
        let pairs = Self.pairs(sent)
        #expect(pairs.filter { $0.0 == "poll[options][]" }.map(\.1) == ["Tea", "Coffee"])
        #expect(pairs.contains { $0 == ("poll[expires_in]", "3600") })
        #expect(pairs.contains { $0 == ("poll[multiple]", "true") })
        #expect(pairs.contains { $0 == ("poll[hide_totals]", "true") })
        #expect(pairs.contains { $0 == ("status", "Which?") })
    }

    @Test("A post carries a poll or media, not both: a poll is not started beside a file, and a file is not added beside a poll, and each press says why")
    func aPollOrMedia() async throws {
        let (session, server, _) = try await shell(scopes: writing + " write:media")
        session.prepareCompose()
        session.composeDraft.media = [UnsentMedia(bytes: Data([1]), mime: "image/png", name: "a.png")]
        session.composeAddPoll()
        #expect(session.composeDraft.poll == nil)
        #expect(session.composePollSays == "social.example takes a poll or media on a post, not both.")
        // The file taken off, the reason it gave goes with it.
        session.composeDraft.media = []
        #expect(session.composePollSays == nil)
        session.composeAddPoll()
        #expect(session.composeDraft.poll != nil)
        session.composeAddMedia()
        #expect(session.composeMediaNote == "social.example takes a poll or media on a post, not both.")
        #expect(!session.composeImporting)
        #expect(await server.paths.isEmpty)
    }

    @Test("A poll is held to what the source said it takes: as many choices, each as long, runs it offers; past them it cannot be sent, and says why")
    func heldToTheSourcesLimits() async throws {
        let (session, _, _) = try await shell(scopes: writing)
        session.prepareCompose()
        session.composeDraft.text = "Which?"
        session.composeRooms[host] = ComposeRoom(
            limit: 500, media: .unstated,
            polls: MastodonPollLimits(choices: 3, choiceLength: 5, shortest: 300, longest: 3600)
        )
        session.composeAddPoll()
        #expect(session.composeDraft.poll?.runs == 300, "a day is not among the runs it takes: the shortest is")
        #expect(MastodonPollLimits(choices: 3, choiceLength: 5, shortest: 300, longest: 3600).offeredRuns == [300, 1800, 3600])
        session.composeAddChoice()
        session.composeAddChoice()
        #expect(session.composeDraft.poll?.choices.count == 3, "no more than it takes")
        session.composeDraft.poll?.choices = ["Tea", "Milk", "Water"]
        #expect(session.canPost)
        session.composeDraft.poll?.choices[1] = "Coffee"
        #expect(!session.canPost)
        #expect(session.composePollNote() == "A choice is at most 5.")
        session.composeRemoveChoice(at: 1)
        #expect(session.composeDraft.poll?.choices == ["Tea", "Water"])
        session.composeRemoveChoice(at: 1)
        #expect(session.composeDraft.poll?.choices.count == 2, "a poll keeps the two it needs")
        session.composeDraft.poll?.choices = ["Tea", "Tea"]
        #expect(session.composePollNote() == "Two choices say the same.")
        session.composeRemovePoll()
        #expect(session.composeDraft.poll == nil && session.canPost)
    }

    @Test("Every word of a poll in the composer is translated")
    func pollWordsAreTranslated() {
        for key in [
            "compose.poll.add", "compose.poll.remove", "compose.poll.count", "compose.poll.choice",
            "compose.poll.addChoice", "compose.poll.removeChoice", "compose.poll.removeChoice.named",
            "compose.poll.multiple", "compose.poll.hide", "compose.poll.runs", "compose.poll.runs.refused",
            "compose.poll.choices", "compose.poll.choiceLength", "compose.poll.same", "compose.poll.withMedia",
        ] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
        #expect(ComposeWords.runsLine(86_400, language: .english) == "1 day")
        #expect(ComposeWords.runsLine(1800, language: .english) == "30 minutes")
    }

    // MARK: - A file its source is preparing (#438)

    private static let preparing = MediaServer.Answer(status: 206, body: #"{"id":"m1","url":null}"#)
    private static let readyFile = MediaServer.Answer(body: #"{"id":"m1","url":"https://m/x"}"#)

    private func slowPost(_ server: MediaServer, pace: FilePace = FilePace(rounds: 5) { _ in }) async throws -> ShellSession {
        let session = try await mediaShell(server)
        session.outbox.filePace = pace
        session.prepareCompose()
        session.composeDraft.text = "kept"
        #expect(session.composeAttach(bytes: Data("v".utf8), name: "v.mp4", type: "video/mp4", description: "a hill") == nil)
        #expect(session.send())
        return session
    }

    @Test("A post with a slow file is sent once the file is ready, with no other act, carrying it")
    func aSlowFileWaits() async throws {
        let server = MediaServer(media: [.init(status: 202, body: #"{"id":"m1"}"#)], status: Self.status(body: "kept"))
        await server.files([Self.preparing, Self.preparing, Self.readyFile])
        let session = try await slowPost(server)
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        let requests = await server.requests
        #expect(requests.map { $0.url?.path } == ["/api/v2/media", "/api/v1/media/m1", "/api/v1/media/m1", "/api/v1/media/m1", "/api/v1/statuses"])
        #expect(Self.pairs(requests[4]).filter { $0.0 == "media_ids[]" }.map(\.1) == ["m1"])
    }

    @Test("A file its source could not prepare says so and nothing is posted, every word kept; Send again sends it anew, what was left let go")
    func aFileNotPrepared() async throws {
        let server = MediaServer(media: [.init(status: 202, body: #"{"id":"m1"}"#), .init(body: #"{"id":"m2"}"#)], status: Self.status(body: "kept"))
        await server.files([.init(status: 422, body: #"{"error":"Error processing thumbnail for uploaded media"}"#)])
        let session = try await slowPost(server)
        await session.outbox.settled()
        let held = try #require(session.outbox.sendings.first)
        #expect(held.standing == .unprepared && held.unsent.text == "kept" && held.unsent.media.first?.unprepared == true)
        #expect(held.unsent.standing == .unprepared)
        #expect(OutboxWords.line(held, hold: nil, whom: nil).contains("v.mp4"))
        #expect(OutboxWords.presses(held, hold: nil).contains(.files))
        #expect(await !server.paths.contains("/api/v1/statuses"))

        #expect(session.outbox.again(held.id, in: session))
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        let requests = await server.requests
        #expect(requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/v1/media/m1" })
        #expect(Self.pairs(try #require(requests.last)).filter { $0.0 == "media_ids[]" }.map(\.1) == ["m2"])
    }

    /// A pace that says it stands at a wait, and stands there until a check lets it on.
    private struct Held {
        let reached = Gate()
        let gate = Gate()
        var pace: FilePace {
            FilePace(rounds: 5) { [reached, gate] _ in
                await reached.open()
                await gate.wait()
            }
        }
    }

    @Test("While it is prepared the line says so, the description goes to the source and is what stands, and a file taken back is gone there and not on the post")
    func whilePrepared() async throws {
        let server = MediaServer(media: [.init(status: 202, body: #"{"id":"m1"}"#)], status: Self.status(body: "kept"))
        await server.files([Self.preparing, Self.readyFile])
        let held = Held()
        let session = try await slowPost(server, pace: held.pace)
        await held.reached.wait()
        let line = try #require(session.outbox.sendings.first)
        #expect(OutboxWords.presses(line, hold: nil) == [.files, .stop])
        #expect(OutboxWords.line(line, hold: nil, whom: nil) == String(format: L10n.t("outbox.preparing.post"), host))
        let piece = try #require(line.unsent.media.first)
        session.outbox.correct(piece.id, of: line.id, to: "a valley", in: session)
        session.outbox.takeBack(piece.id, of: line.id, in: session)
        #expect(session.outbox.sending(line.id)?.unsent.media.first?.description == "a hill", "the source first, and one act at a time")
        await session.outbox.fileActEnded(line.id)
        #expect(session.outbox.sending(line.id)?.unsent.media.first?.description == "a valley")
        session.outbox.takeBack(piece.id, of: line.id, in: session)
        await session.outbox.fileActEnded(line.id)
        #expect(session.outbox.sending(line.id)?.unsent.media.isEmpty == true)
        await held.gate.open()
        await session.outbox.settled()
        let requests = await server.requests
        #expect(requests.contains { $0.httpMethod == "PUT" && $0.url?.path == "/api/v1/media/m1" })
        #expect(requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/v1/media/m1" })
        let post = try #require(requests.last { $0.url?.path == "/api/v1/statuses" })
        #expect(Self.pairs(post).filter { $0.0 == "media_ids[]" }.isEmpty)
        #expect(session.outbox.sendings.isEmpty)
    }

    @Test("What the source refuses of a correction or a taking back is said, and nothing here moves; the wait can be ended and taken up")
    func refusalsAndStopping() async throws {
        let server = MediaServer(media: [.init(status: 202, body: #"{"id":"m1"}"#)], status: Self.status(body: "kept"))
        await server.files([Self.preparing, Self.preparing, Self.readyFile])
        await server.refusesFileActs()
        let held = Held()
        let session = try await slowPost(server, pace: held.pace)
        await held.reached.wait()
        let line = try #require(session.outbox.sendings.first)
        let piece = try #require(line.unsent.media.first)
        session.outbox.takeBack(piece.id, of: line.id, in: session)
        await session.outbox.fileActEnded(line.id)
        #expect(session.outbox.fileRefusals[line.id] == String(format: L10n.t("outbox.files.refused"), host))
        #expect(session.outbox.sending(line.id)?.unsent.media.count == 1)

        session.outbox.stopPreparing(line.id)
        await held.gate.open()
        await session.outbox.settled()
        let stopped = try #require(session.outbox.sendings.first)
        #expect(stopped.standing == .failed(.unreachable) && stopped.unsent.media.first?.remoteID == "m1")
        #expect(await !server.paths.contains("/api/v1/statuses"))

        session.outbox.filePace = FilePace(rounds: 5) { _ in }
        #expect(session.outbox.again(stopped.id, in: session))
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty, "the id kept, and no file sent twice")
        #expect(await server.paths.filter { $0 == "/api/v2/media" }.count == 1)
    }

    /// Two files of one post, the first ready after one round, the second's upload standing still.
    private func secondGoingUp(_ server: MediaServer) async throws -> (ShellSession, ShellOutbox.Sending) {
        await server.files([Self.preparing, Self.readyFile])
        await server.holdingSecondUpload()
        let session = try await mediaShell(server)
        session.outbox.filePace = FilePace(rounds: 5) { _ in }
        session.prepareCompose()
        session.composeDraft.text = "kept"
        #expect(session.composeAttach(bytes: Data("v".utf8), name: "v.mp4", type: "video/mp4", description: "a hill") == nil)
        #expect(session.composeAttach(bytes: Data("w".utf8), name: "w.mp4", type: "video/mp4", description: "a bird") == nil)
        #expect(session.send())
        await server.uploadReached.wait()
        return (session, try #require(session.outbox.sendings.first))
    }

    private static var twoSlowFiles: [MediaServer.Answer] {
        [.init(status: 202, body: #"{"id":"m1"}"#), .init(body: #"{"id":"m2"}"#)]
    }

    @Test("A file taken back while another goes up stays gone, and the post does not carry it")
    func takenBackDuringAnotherUpload() async throws {
        let server = MediaServer(media: Self.twoSlowFiles, status: Self.status(body: "kept"))
        let (session, line) = try await secondGoingUp(server)
        #expect(line.standing == .preparing)
        session.outbox.takeBack(line.unsent.media[0].id, of: line.id, in: session)
        await session.outbox.fileActEnded(line.id)
        await server.uploadGate.open()
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        let post = try #require(await server.requests.last)
        #expect(Self.pairs(post).filter { $0.0 == "media_ids[]" }.map(\.1) == ["m2"])
    }

    @Test("A description corrected while its own file goes up reaches the source; a file taken back while it goes up is gone there")
    func actsOnAFileGoingUp() async throws {
        let server = MediaServer(media: Self.twoSlowFiles, status: Self.status(body: "kept"))
        let (session, line) = try await secondGoingUp(server)
        session.outbox.correct(line.unsent.media[1].id, of: line.id, to: "a valley", in: session)
        await session.outbox.fileActEnded(line.id)
        await server.uploadGate.open()
        await session.outbox.settled()
        let requests = await server.requests
        let put = try #require(requests.first { $0.httpMethod == "PUT" })
        #expect(put.url?.path == "/api/v1/media/m2" && String(decoding: put.httpBody ?? Data(), as: UTF8.self).contains("valley"))

        let other = MediaServer(media: Self.twoSlowFiles, status: Self.status(body: "kept"))
        let (second, going) = try await secondGoingUp(other)
        second.outbox.takeBack(going.unsent.media[1].id, of: going.id, in: second)
        await second.outbox.fileActEnded(going.id)
        await other.uploadGate.open()
        await second.outbox.settled()
        let asked = await other.requests
        #expect(asked.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/v1/media/m2" })
        let post = try #require(asked.last { $0.url?.path == "/api/v1/statuses" })
        #expect(Self.pairs(post).filter { $0.0 == "media_ids[]" }.map(\.1) == ["m1"])
    }

    @Test("Stop during another file's upload stops: nothing is posted, every id kept")
    func stopDuringAnUpload() async throws {
        let server = MediaServer(media: Self.twoSlowFiles, status: Self.status(body: "kept"))
        let (session, line) = try await secondGoingUp(server)
        session.outbox.stopPreparing(line.id)
        await server.uploadGate.open()
        await session.outbox.settled()
        #expect(await !server.paths.contains("/api/v1/statuses"))
        let held = try #require(session.outbox.sendings.first)
        #expect(held.standing == .failed(.unreachable) && held.unsent.media.map(\.remoteID) == ["m1", "m2"])
    }

    @Test("Stop followed by a ready answer stops")
    func stopThenReady() async throws {
        let server = MediaServer(media: [.init(status: 202, body: #"{"id":"m1"}"#)], status: Self.status(body: "kept"))
        await server.files([Self.preparing, Self.readyFile])
        await server.holdingGet(2)
        let session = try await slowPost(server)
        await server.getReached.wait()
        let line = try #require(session.outbox.sendings.first)
        session.outbox.stopPreparing(line.id)
        await server.getGate.open()
        await session.outbox.settled()
        #expect(await !server.paths.contains("/api/v1/statuses"))
        #expect(session.outbox.sendings.first?.standing == .failed(.unreachable))
    }

    @Test("A not-found racing a file taken back does not send it up again")
    func goneRacingATakingBack() async throws {
        let server = MediaServer(media: [.init(status: 202, body: #"{"id":"m1"}"#), .init(body: #"{"id":"m2"}"#)], status: Self.status(body: "kept"))
        await server.files([Self.preparing, .init(status: 404, body: #"{"error":"Record not found"}"#)])
        await server.holdingGet(2)
        let session = try await slowPost(server)
        await server.getReached.wait()
        let line = try #require(session.outbox.sendings.first)
        await server.holdingDelete()
        session.outbox.takeBack(line.unsent.media[0].id, of: line.id, in: session)
        await server.deleteReached.wait()
        // The not-found lands with the taking back still out. Given the turns to go wrong in.
        await server.getGate.open()
        await server.getAnswered.wait()
        for _ in 0..<200 { await Task.yield() }
        await server.deleteGate.open()
        await session.outbox.settled()
        #expect(await server.paths.filter { $0 == "/api/v2/media" }.count == 1)
        #expect(session.outbox.sendings.isEmpty)
    }

    @Test("A blip while asking after a file does not end the wait: the post still goes with no other act")
    func aBlipIsAskedAgain() async throws {
        let server = MediaServer(media: [.init(status: 202, body: #"{"id":"m1"}"#)], status: Self.status(body: "kept"))
        await server.files([.init(status: 502, body: "bad"), Self.preparing, .init(status: 500, body: "down"), Self.readyFile])
        let session = try await slowPost(server)
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        #expect(await server.paths.contains("/api/v1/statuses"))
    }

    @Test("A post waiting on a file holds nobody: the one behind it goes first, and it goes once ready")
    func aWaitHoldsNobody() async throws {
        let server = MediaServer(media: [.init(status: 202, body: #"{"id":"m1"}"#)], status: Self.status(body: "kept"))
        await server.files([Self.preparing, Self.readyFile])
        let held = Held()
        let session = try await slowPost(server, pace: held.pace)
        await held.reached.wait()
        session.composeDraft.text = "behind it"
        #expect(session.send())
        // The one behind it reaches its source while the first still waits: held behind it, this
        // would stand here until the run went still, and fail.
        let watched = watching(server.postReached, "the post behind the one waiting on a file")
        defer { watched.cancel() }
        await server.postReached.wait()
        #expect(session.outbox.sendings.first?.standing == .preparing)
        #expect(await server.paths.filter { $0 == "/api/v1/statuses" }.count == 1)
        await held.gate.open()
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        #expect(await server.paths.filter { $0 == "/api/v1/statuses" }.count == 2)
    }

    @Test("A file left with an id by a run before is asked after; one its source let go goes up again from what is kept")
    func leftFromBefore() async throws {
        let server = MediaServer(media: [.init(body: #"{"id":"m2"}"#)], status: Self.status(body: "kept"))
        await server.files([.init(status: 404, body: #"{"error":"Record not found"}"#)])
        let session = try await mediaShell(server)
        let unsent = Unsent(
            host: host, text: "kept", audience: .everyone,
            media: [UnsentMedia(bytes: Data("v".utf8), mime: "video/mp4", name: "v.mp4", remoteID: "m1")]
        )
        session.outbox.take(unsent, in: session)
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        let requests = await server.requests
        #expect(requests.map { $0.url?.path } == ["/api/v1/media/m1", "/api/v2/media", "/api/v1/statuses"])
        #expect(Self.pairs(requests[2]).filter { $0.0 == "media_ids[]" }.map(\.1) == ["m2"])
    }

    @Test("Every language says each word of it")
    func filesWords() {
        for key in ["outbox.files", "outbox.files.spoken", "outbox.stop", "outbox.stop.spoken", "outbox.preparing.post", "outbox.preparing.answer", "outbox.preparing.change", "outbox.unprepared.post", "outbox.unprepared.answer", "outbox.unprepared.change", "outbox.files.refused", "outbox.files.failed", "outbox.files.takeBack", "outbox.files.takeBack.title", "outbox.files.takeBack.line", "outbox.files.takeBack.spoken", "outbox.files.description", "outbox.files.description.spoken", "outbox.files.save", "outbox.files.save.spoken", "outbox.files.unprepared", "outbox.files.preparing", "waiting.preparing", "waiting.unprepared", "waiting.stillPreparing"] {
            for language in [DummyLanguage.english, .taiwanese] { #expect(L10n.t(key, language: language) != key) }
        }
    }

    private func mediaShell(_ server: MediaServer) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        try tokens.save(token(host, scopes: writing + " write:media"))
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.sources = await store.sources()
        session.mastodon.refresh()
        return session
    }
}

/// Two uploads of one path are two answers, then the post.
private actor MediaServer: HTTPSender {
    struct Answer: Sendable {
        var status: Int = 200
        var body: String
    }

    private var media: [Answer]
    private let statusBody: String
    private(set) var requests: [URLRequest] = []
    /// What each `GET` of a file answers, in turn (#438).
    private var fileAnswers: [Answer] = []
    private var fileActsRefused = false

    /// An upload past the first stands here until a check opens it; so does the `GET` numbered.
    let postReached = Gate(), uploadReached = Gate(), uploadGate = Gate(), getReached = Gate(), getGate = Gate()
    private var holdsUpload = false, uploads = 0, gets = 0, heldGet: Int?
    func holdingSecondUpload() { holdsUpload = true }
    func holdingGet(_ number: Int) { heldGet = number }
    /// A `DELETE` of a file stands here until a check opens it, once it is held.
    let deleteReached = Gate(), deleteGate = Gate(), getAnswered = Gate()
    private var holdsDelete = false
    func holdingDelete() { holdsDelete = true }

    func files(_ answers: [Answer]) { fileAnswers = answers }
    func refusesFileActs() { fileActsRefused = true }

    init(media: [Answer], status: String) {
        self.media = media
        self.statusBody = status
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let answer: Answer
        if path == "/api/v2/media" {
            guard !media.isEmpty else { throw FixtureHTTPError.unmapped }
            answer = media.removeFirst()
            uploads += 1
            if holdsUpload, uploads == 2 {
                await uploadReached.open()
                await uploadGate.wait()
            }
        } else if path == "/api/v1/statuses" {
            answer = Answer(body: statusBody)
            await postReached.open()
        } else if path.hasPrefix("/api/v1/media/") {
            if request.httpMethod == "GET" {
                guard !fileAnswers.isEmpty else { throw FixtureHTTPError.unmapped }
                answer = fileAnswers.removeFirst()
                gets += 1
                if gets == heldGet {
                    await getReached.open()
                    await getGate.wait()
                    await getAnswered.open()
                }
            } else {
                if holdsDelete, request.httpMethod == "DELETE" {
                    await deleteReached.open()
                    await deleteGate.wait()
                }
                answer = fileActsRefused ? Answer(status: 422, body: #"{"error":"Media attachment is currently used by a status"}"#) : Answer(body: "{}")
            }
        } else {
            throw FixtureHTTPError.unmapped
        }
        return (
            Data(answer.body.utf8),
            HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}
