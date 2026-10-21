import Foundation
import Testing
@testable import FediqoCore

/// One answer of a local server, whole: its status and its body as JSON where it is JSON.
private struct ChangeAnswer {
    let status: Int
    let body: Data

    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    var list: [[String: Any]] { (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] ?? [] }
    var text: String { String(decoding: body, as: UTF8.self) }
    var poll: [String: Any]? { object["poll"] as? [String: Any] }
}

/// #332: what Fediqo believes a Mastodon says of one's own post read back, changed and read
/// for what it said before, held against the real one this checkout brings up (`make servers`,
/// Mastodon 4.6.6) — the table in `MastodonChangeCaptures`. Each check goes through this app's
/// own `MastodonWrite` and beside it asks the server plainly for what the belief rests on.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **This writes, and takes back what it wrote.** Every post is the writer's, unlisted, written
/// here and taken back however the check ends (`writing`); the second person only votes.
@Suite("What a Mastodon says of a post changed", .enabled(if: LocalServers.requested), .serialized)
struct MastodonChangeSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)
    private static let pixel = Data(base64Encoded: MastodonPartsCaptures.pixel)!

    private static func door(_ token: String) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        let held = MastodonToken(host: host, accessToken: token, clientID: "x", clientSecret: "x")
        try tokens.save(held)
        return MastodonAuthorized(token: held, sender: try LocalHTTP.client(), store: tokens)
    }

    private static func ask(_ path: String, as token: String, _ method: String = "GET", form: [(String, String)]? = nil) async throws -> ChangeAnswer {
        guard let url = URL(string: "https://\(host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form { request.setForm(form) }
        let (body, response) = try await LocalHTTP.client().send(request)
        return ChangeAnswer(status: response.statusCode, body: body)
    }

    /// A writer through this app, into a store of its own, and the two sign-ins of the seed.
    private static func writer() throws -> (write: MastodonWrite, store: ItemStore, writer: String, other: String) {
        let seeded = try LocalServers.seeded()
        let store = ItemStore(sources: [source], notes: [])
        return (MastodonWrite(door: try door(seeded.writer), store: store), store, seeded.writer, seeded.other)
    }

    /// Runs `body` with a list it adds the ids of what it writes to, and takes each back after,
    /// whatever became of it.
    private static func writing(as token: String, _ body: (inout [String]) async throws -> Void) async throws {
        var written: [String] = []
        let thrown: (any Error)?
        do {
            try await body(&written)
            thrown = nil
        } catch {
            thrown = error
        }
        for id in written { _ = try? await ask("/api/v1/statuses/\(id)", as: token, "DELETE") }
        if let thrown { throw thrown }
    }

    @Test("What a post was written from is the words as typed and the cover line, and no more; its language, whether it is covered, its files with their descriptions and its poll are the post's own — read through this app, the two answers together; another person may read it as well; reading it changes nothing held")
    func whatItWasWrittenFrom() async throws {
        try await LocalServers.requireHealthy()
        let (write, store, writer, other) = try Self.writer()
        try await Self.writing(as: writer) { written in
            let first = try await write.upload(bytes: Self.pixel, name: "a.png", type: "image/png", description: "first alt")
            let second = try await write.upload(bytes: Self.pixel, name: "b.png", type: "image/png", description: "")
            let post = try await write.post(
                "written @nobody\ntwo lines", visibility: .unlisted, spoiler: "cw", language: "de", mediaIDs: [first, second]
            )
            written.append(try #require(post.statusID))
            let id = post.statusID!

            let plain = try await Self.ask("/api/v1/statuses/\(id)/source", as: writer)
            #expect(plain.status == 200 && Set(plain.object.keys) == ["id", "text", "spoiler_text"])
            #expect(plain.object["text"] as? String == "written @nobody\ntwo lines" && plain.object["spoiler_text"] as? String == "cw")
            #expect(try await Self.ask("/api/v1/statuses/\(id)/source", as: other).body == plain.body)

            let held = await store.all()
            let said = try await write.source(of: post)
            #expect(said == PostSource(
                statusID: id, text: "written @nobody\ntwo lines", spoiler: "cw", sensitive: true, language: "de",
                media: said.media.map { PostSource.Media(id: $0.id, kind: .image, description: $0.description, previewURL: $0.previewURL) }
            ))
            #expect(said.media.map(\.id) == [first, second] && said.media.map(\.description) == ["first alt", ""])
            #expect(await store.all() == held)
        }
    }

    @Test("A change lands as the status changed, under the same id, with a moment of its own; the row takes it as a later wording, and a read on its way before it changes no word; the history is every wording, the original first; the same change again is no change; who may read it is passed over; a description alone is a change and no new wording")
    func aChange() async throws {
        try await LocalServers.requireHealthy()
        let (write, store, writer, _) = try Self.writer()
        try await Self.writing(as: writer) { written in
            let first = try await write.upload(bytes: Self.pixel, name: "a.png", type: "image/png", description: "first alt")
            let second = try await write.upload(bytes: Self.pixel, name: "b.png", type: "image/png", description: "")
            let post = try await write.post("before the change", visibility: .unlisted, language: "en", mediaIDs: [first, second])
            let id = try #require(post.statusID)
            written.append(id)
            #expect(try await write.earlier(of: post).isEmpty, "a post never changed has nothing before")

            // A read sent before the change, landing after it.
            let sentBefore = ReadMoment.now()
            let early = try await Self.ask("/api/v1/statuses/\(id)", as: writer)

            var change = PostChange(source: try await write.source(of: post))
            change.text = "after the change"
            change.language = "fr"
            change.sensitive = true
            change.media = [.init(id: second, description: "second alt")]
            let after = try await write.change(post, to: change)
            #expect(after.key == post.key && after.statusID == id && after.body == "after the change")
            #expect(after.language == "fr" && after.sensitive == true && after.attachments.map(\.alt) == ["second alt"])
            let changedAt = try #require(after.editedAt)
            #expect(after.earlier == [Wording(body: "before the change", spoiler: "", sensitive: false, until: changedAt)])

            let stale = try MastodonJSON.decoder.decode(StatusDTO.self, from: early.body)
                .asNote(source: Self.source, categories: [.home], sent: sentBefore)
            await store.refresh([stale], ifSourceHere: Self.host)
            #expect(await store.note(post.key) == after, "a read on its way undid the change")

            // What it said before, as the source keeps it.
            let plain = try await Self.ask("/api/v1/statuses/\(id)/history", as: writer)
            #expect(plain.list.count == 2 && (plain.list.first?["content"] as? String) == "<p>before the change</p>")
            #expect(plain.list.allSatisfy { $0["language"] == nil && $0["created_at"] is String })
            #expect(try await write.earlier(of: after) == after.earlier)

            // The same change again changes nothing at the source.
            let again = try await write.change(after, to: change)
            #expect(again.editedAt == after.editedAt && again.earlier == after.earlier)
            #expect(try await Self.ask("/api/v1/statuses/\(id)/history", as: writer).list.count == 2)

            // Who may read it is not a change can move.
            let visibility = try await Self.ask("/api/v1/statuses/\(id)", as: writer, "PUT", form: change.form + [("visibility", "direct")])
            #expect(visibility.status == 200 && visibility.object["visibility"] as? String == "unlisted")

            // A description alone: a change at the source, no new wording here.
            var described = change
            described.media = [.init(id: second, description: "third alt")]
            let relabelled = try await write.change(after, to: described)
            #expect(relabelled.editedAt != after.editedAt && relabelled.attachments.map(\.alt) == ["third alt"])
            #expect(try await Self.ask("/api/v1/statuses/\(id)/history", as: writer).list.count == 3)
            #expect(try await write.earlier(of: relabelled) == after.earlier && relabelled.earlier == after.earlier)

            // A file left out is taken off.
            var bare = change
            bare.media = []
            #expect(try await write.change(relabelled, to: bare).attachments.isEmpty)
        }
    }

    /// Which changes of a poll the server starts again — every vote lost — and which it keeps.
    @Test("A poll sent again as it was keeps its votes and starts its run again from the change; a new run or figures hidden keep the votes; choices reordered, reworded or added, one become several, and the word for several left out, lose them; the poll left out is taken off — each as `Poll.restarted` says")
    func whatAPollChangeKeeps() async throws {
        try await LocalServers.requireHealthy()
        let (write, store, writer, other) = try Self.writer()
        let three = NewPoll(choices: ["A", "B", "C"], multiple: false, runs: 3600, hidesTotals: false)
        let cases: [(String, NewPoll?, keeps: Bool)] = [
            ("sent again", three, true),
            ("a longer run", NewPoll(choices: ["A", "B", "C"], runs: 7200), true),
            ("figures hidden", NewPoll(choices: ["A", "B", "C"], runs: 3600, hidesTotals: true), true),
            ("reordered", NewPoll(choices: ["B", "A", "C"], runs: 3600), false),
            ("reworded", NewPoll(choices: ["A", "B", "D"], runs: 3600), false),
            ("one added", NewPoll(choices: ["A", "B", "C", "D"], runs: 3600), false),
            ("one become several", NewPoll(choices: ["A", "B", "C"], multiple: true, runs: 3600), false),
            ("left out", nil, false),
        ]
        // **One post for every case**, brought back to the same poll with one vote in it between
        // them: a source lets an account take back only thirty posts in half an hour, and every
        // check on this machine shares that.
        try await Self.writing(as: writer) { written in
            var post = try await write.post("poll cases", visibility: .unlisted, poll: three)
            let id = try #require(post.statusID)
            written.append(id)
            for (label, poll, keeps) in cases {
                post = try await write.change(post, to: PostChange(text: "poll before \(label)", poll: three))
                // A read sent before the change, landing after it — with the one vote in it.
                var sentBefore = ReadMoment.now()
                var early = try await Self.ask("/api/v1/statuses/\(id)", as: writer)
                if early.poll?["votes_count"] as? Int == 0, let pollID = early.poll?["id"] as? String {
                    let vote = try await Self.ask("/api/v1/polls/\(pollID)/votes", as: other, "POST", form: [("choices[]", "0")])
                    #expect(vote.status == 200, "\(label)")
                    sentBefore = ReadMoment.now()
                    early = try await Self.ask("/api/v1/statuses/\(id)", as: writer)
                }
                let stale = try MastodonJSON.decoder.decode(StatusDTO.self, from: early.body)
                    .asNote(source: Self.source, categories: [.home], sent: sentBefore)
                let held = try #require(stale.poll)
                #expect(held.votes == 1 && held.choices.map(\.title) == ["A", "B", "C"] && !held.multiple, "\(label): set up")
                let endedAt = try #require(held.endsAt)

                let after = try await write.change(post, to: PostChange(text: "poll \(label)", poll: poll))
                await store.refresh([stale], ifSourceHere: Self.host)
                await store.ingest([stale])
                #expect(await store.note(post.key)?.poll == after.poll, "\(label): a read on its way put the poll back")
                #expect(held.restarted(by: poll) == !keeps, "\(label): the rule")
                if let answered = after.poll {
                    #expect(answered.id == held.id, "\(label): the same poll")
                    #expect((answered.votes == 1) == keeps, "\(label): \(answered.votes.map(String.init) ?? "hidden") votes")
                    if poll?.runs == 3600 {
                        #expect(answered.endsAt.map { endedAt < $0 } == true, "\(label): the run starts again")
                    }
                } else {
                    #expect(poll == nil && !keeps, "\(label): the poll was taken off")
                }
                post = after
            }

            // The word for several left out is taken for a change of it.
            post = try await write.change(post, to: PostChange(text: "poll without the word", poll: three))
            if let pollID = post.poll?.id, post.poll?.votes == 0 {
                _ = try await Self.ask("/api/v1/polls/\(pollID)/votes", as: other, "POST", form: [("choices[]", "0")])
            }
            #expect(try await Self.ask("/api/v1/statuses/\(id)", as: writer).poll?["votes_count"] as? Int == 1)
            let plain = try await Self.ask("/api/v1/statuses/\(id)", as: writer, "PUT", form: [
                ("status", "poll without the word"), ("poll[options][]", "A"), ("poll[options][]", "B"),
                ("poll[options][]", "C"), ("poll[expires_in]", "3600"),
            ])
            #expect(plain.status == 200 && plain.poll?["votes_count"] as? Int == 0)
        }
    }

    @Test("A post changed three times elsewhere and read once here owes one ask of its history, which fills in all four wordings in the background through the source's line, and then owes nothing")
    func historyFilledIn() async throws {
        try await LocalServers.requireHealthy()
        let (write, store, writer, _) = try Self.writer()
        try await Self.writing(as: writer) { written in
            let post = try await write.post("wording 0", visibility: .unlisted)
            let id = try #require(post.statusID)
            written.append(id)
            for n in 1...3 {
                let changed = try await Self.ask("/api/v1/statuses/\(id)", as: writer, "PUT", form: [("status", "wording \(n)")])
                #expect(changed.status == 200)
            }
            let reader = MastodonPost(door: try Self.door(writer))
            await store.refresh([try await reader.post(id: id, source: Self.source)], ifSourceHere: Self.host)
            let seen = try #require(await store.note(post.key))
            #expect(seen.body == "wording 3" && seen.earlier.map(\.body) == ["wording 0"], "what this device saw")

            let owed = await store.historyOwed(host: Self.host)
            #expect(owed.map(\.item) == [post.key])
            var limits = LoadLimits()
            limits.interval = 0
            let fill = MastodonHistoryFill(store: store, loads: LoadPacer(limits: limits))
            #expect(await fill.fill(try #require(owed.first)) { reader } == .done)
            let held = try #require(await store.note(post.key))
            #expect(held.earlier.map(\.body) == ["wording 0", "wording 1", "wording 2"])
            #expect(held.earlier.last?.until == held.editedAt && held.historyAt == held.editedAt)
            #expect(zip(held.earlier, held.earlier.dropFirst()).allSatisfy { $0.until < $1.until })
            #expect(await store.historyOwed(host: Self.host).isEmpty)
        }
    }

    @Test("A refusal changes nothing held: empty words and words over the limit are the source's 422 in its own words; another person's post is a 404; a sign-in that only reads is outside its scopes and may still read the source and the history; a post taken back has neither")
    func refusals() async throws {
        try await LocalServers.requireHealthy()
        let (write, store, writer, other) = try Self.writer()
        let seeded = try LocalServers.seeded()
        let reading = try #require(seeded.notices?.reading.token)
        try await Self.writing(as: writer) { written in
            let post = try await write.post("to be refused a change", visibility: .unlisted)
            let id = try #require(post.statusID)
            written.append(id)
            let held = await store.all()

            // The source's own words, in the language it answers this machine in; asked in English,
            // the ones captured.
            for (words, said) in [("", MastodonChangeCaptures.blank), (String(repeating: "x", count: 501), MastodonChangeCaptures.tooLong)] {
                await #expect(throws: MastodonUnprocessable.self) {
                    _ = try await write.change(post, to: PostChange(text: words))
                }
                let plain = try await Self.ask("/api/v1/statuses/\(id)", as: writer, "PUT", form: [("status", words)])
                #expect(plain.status == 422 && plain.text == said)
            }
            let theirs = MastodonWrite(door: try Self.door(other), store: store)
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await theirs.change(post, to: PostChange(text: "not theirs")) }
            #expect(try await Self.ask("/api/v1/statuses/\(id)", as: other, "PUT", form: [("status", "x")]).text == MastodonChangeCaptures.notTheirs)

            let reader = MastodonWrite(door: try Self.door(reading), store: store)
            await #expect(throws: MastodonScopeError.outside) { _ = try await reader.change(post, to: PostChange(text: "read only")) }
            #expect(try await Self.ask("/api/v1/statuses/\(id)", as: reading, "PUT", form: [("status", "x")]).text == MastodonChangeCaptures.outside)
            #expect(try await reader.source(of: post).text == "to be refused a change")
            #expect(try await reader.earlier(of: post).isEmpty)
            #expect(await store.all() == held, "a refusal changed what is held")

            let taken = try await Self.ask("/api/v1/statuses/\(id)", as: writer, "DELETE")
            #expect(taken.status == 200)
            // Taken back here: not asked again, which would spend one more of the thirty.
            if taken.status == 200 { written.removeAll() }
            for path in ["source", "history"] {
                let gone = try await Self.ask("/api/v1/statuses/\(id)/\(path)", as: writer)
                #expect(gone.status == 404 && gone.text == MastodonChangeCaptures.gone, "\(path)")
            }
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await write.earlier(of: post) }
        }
    }
}
