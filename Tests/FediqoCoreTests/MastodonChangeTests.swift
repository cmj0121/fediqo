import Foundation
import Testing
@testable import FediqoCore

/// One's own post changed after it was published (#332): read back to what it was written from,
/// the change sent and its answer kept as a later wording of the same row, and what it said
/// before read off its source — each against what Mastodon 4.6.6 answered (`MastodonChangeCaptures`).
@Suite("Changing one's own post")
struct MastodonChangeTests {
    private typealias Captures = MastodonChangeCaptures
    private let host = MastodonFixture.host
    private let source = Source(host: MastodonFixture.host, kind: .mastodon)

    private func note(_ json: String, sent: ReadMoment = .now()) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .home, sent: sent)
    }

    /// The form as it was sent, keys decoded, repeated keys kept.
    private static func pairs(_ request: URLRequest?) -> [(String, String)] {
        guard let body = request?.httpBody, let text = String(data: body, encoding: .utf8) else { return [] }
        return text.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0].removingPercentEncoding ?? parts[0], (parts.count > 1 ? parts[1].removingPercentEncoding : "") ?? "")
        }
    }

    private func writer(
        holding held: [Note] = [], _ routes: [String: FixtureSender.Outcome]
    ) async throws -> (MastodonWrite, ItemStore, FixtureSender) {
        let store = ItemStore()
        await store.add(source)
        await store.ingest(held)
        let server = FixtureSender(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        return (MastodonWrite(door: door, store: store), store, server)
    }

    private static let path = "/api/v1/statuses/\(Captures.statusID)"

    // MARK: - What it was written from

    @Test("The source reads to the words as typed and the cover line, with the language, whether it is covered, each file by its id with its description, and the poll off the post")
    func theSourceReads() async throws {
        let post = try note(Captures.withMedia)
        let (write, store, server) = try await writer(holding: [post], [
            "\(Self.path)/source": .json(Captures.sourceUncovered),
            Self.path: .json(Captures.withMedia),
        ])
        let said = try await write.source(of: post)
        #expect(said.statusID == Captures.statusID && said.text == "media probe" && said.spoiler == "")
        #expect(said.sensitive == false && said.language == "en" && said.poll == nil)
        #expect(said.media.map(\.id) == ["117476049068757210", "117476049076597848"])
        #expect(said.media.map(\.description) == ["first alt", ""] && said.media.allSatisfy { $0.kind == .image })
        #expect(Set(await server.paths) == ["\(Self.path)/source", Self.path])
        #expect(await store.all() == [post], "reading what it was written from changes nothing held")

        // Unchanged, it is the change that sends it back as it was.
        let unchanged = PostChange(source: said)
        #expect(unchanged == PostChange(
            text: "media probe", language: "en",
            media: [.init(id: "117476049068757210", description: "first alt"), .init(id: "117476049076597848", description: "")]
        ))
    }

    @Test("The words keep their line breaks and mentions as typed, where the rendered row has lost them")
    func wordsAsTyped() async throws {
        let post = try note(Captures.status(id: "117476042627241864", content: "<p>probe one @other line<br />two</p>", edited: nil, sensitive: true, language: "de", spoiler: "cw", poll: Captures.pollHidden))
        let (write, _, _) = try await writer(holding: [post], [
            "/api/v1/statuses/117476042627241864/source": .json(Captures.source),
            "/api/v1/statuses/117476042627241864": .json(Captures.status(id: "117476042627241864", content: "<p>probe one @other line<br />two</p>", edited: nil, sensitive: true, language: "de", spoiler: "cw", poll: Captures.pollHidden)),
        ])
        let said = try await write.source(of: post)
        #expect(said.text == "probe one @other line\ntwo" && said.spoiler == "cw" && said.sensitive && said.language == "de")
        let poll = try #require(said.poll)
        #expect(poll.choices.map(\.title) == ["A", "B"] && poll.countsHidden)
    }

    @Test("A poll's draft runs for what is left of it, and keeps its figures hidden where they were: a change starts the run again from its own moment")
    func thePollDraft() throws {
        let poll = try #require(try note(Captures.status(content: "<p>x</p>", edited: nil, sensitive: false, language: nil, poll: Captures.pollHidden)).poll)
        let ends = try #require(poll.endsAt)
        let said = PostSource(statusID: "1", text: "x", poll: poll)
        let draft = try #require(said.pollDraft(now: ends.addingTimeInterval(-1800.4)))
        #expect(draft == NewPoll(choices: ["A", "B"], multiple: false, runs: 1801, hidesTotals: true))
        #expect(said.pollDraft(now: ends.addingTimeInterval(10))?.runs == 0, "an ended poll has nothing left to run")
        #expect(said.pollDraft(now: ends.addingTimeInterval(10))?.hidesTotals == false)
    }

    @Test("A source that is not this post's, or not a source at all, is unreadable; one gone is what the door says; and nothing is asked of a row that cannot be named")
    func sourceRefused() async throws {
        let post = try note(Captures.withMedia)
        let (write, _, _) = try await writer(holding: [post], [
            "\(Self.path)/source": .json(Captures.source), Self.path: .json(Captures.withMedia),
        ])
        await #expect(throws: MastodonWriteError.unreadable) { _ = try await write.source(of: post) }
        let (gone, _, _) = try await writer(holding: [post], [
            "\(Self.path)/source": .json(Captures.gone, status: 404), Self.path: .json(Captures.gone, status: 404),
        ])
        await #expect(throws: MastodonAuthError.http(404)) { _ = try await gone.source(of: post) }
        let unnamed = Note(id: "kept-before-ids", source: source, author: "Me", handle: "@me@\(host)", body: "x", postedAt: post.postedAt, categories: [.home])
        let (none, _, server) = try await writer(holding: [], [:])
        await #expect(throws: MastodonWriteError.unfindable) { _ = try await none.source(of: unnamed) }
        #expect(await server.requests.isEmpty)
    }

    // MARK: - The change

    @Test("A change is sent as a PUT of only what a change moves, each file by its id and again with its description, and no key; the answer is a later wording on the same row")
    func aChangeLands() async throws {
        let before = try note(Captures.withMedia)
        let (write, store, server) = try await writer(holding: [before], [Self.path: .json(Captures.changed)])
        let change = PostChange(
            text: "media probe two", spoiler: "", sensitive: true, language: "fr",
            media: [.init(id: "117476049076597848", description: "second alt")]
        )
        let after = try await write.change(before, to: change)

        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: MastodonWrite.idempotencyKey) == nil)
        #expect(Self.pairs(request).map { "\($0.0)=\($0.1)" } == [
            "status=media probe two", "spoiler_text=", "sensitive=true", "language=fr",
            "media_ids[]=117476049076597848",
            "media_attributes[][id]=117476049076597848", "media_attributes[][description]=second alt",
        ])
        #expect(after.key == before.key && after.body == "media probe two" && after.language == "fr")
        #expect(after.earlier.map(\.body) == ["media probe"] && after.earlier.first?.until == after.editedAt)
        #expect(after.attachments.map(\.alt) == ["second alt"] && after.categories == before.categories)
        #expect(await store.all().count == 1)
        #expect(await store.note(before.key) == after)
    }

    @Test("A read already on its way when the change landed changes no word of it")
    func aStaleReadDoesNotUndoIt() async throws {
        let before = try note(Captures.withMedia)
        let (write, store, _) = try await writer(holding: [before], [Self.path: .json(Captures.changed)])
        let sentBefore = ReadMoment.now()
        let after = try await write.change(before, to: PostChange(text: "media probe two"))
        await store.refresh([try note(Captures.withMedia, sent: sentBefore)], ifSourceHere: host)
        await store.ingest([try note(Captures.withMedia, sent: sentBefore)])
        let held = try #require(await store.note(before.key))
        #expect(held.body == "media probe two" && held.editedAt == after.editedAt && held.earlier == after.earlier)
    }

    @Test("A poll is sent whole, every answer outright — one left out is a change of it that loses the votes; none takes it off")
    func thePollIsSent() async throws {
        let before = try note(Captures.status(content: "<p>x</p>", edited: nil, sensitive: false, language: nil, poll: Captures.pollBefore))
        let (write, _, server) = try await writer(holding: [before], [
            Self.path: .json(Captures.status(content: "<p>y</p>", edited: "2026-10-21T00:30:00.000Z", sensitive: false, language: nil, poll: Captures.pollReordered)),
        ])
        let poll = NewPoll(choices: ["B", "A", " C ", ""], multiple: false, runs: 3600, hidesTotals: false)
        let after = try await write.change(before, to: PostChange(text: "y", poll: poll))
        #expect(Self.pairs(await server.requests.first).filter { $0.0.hasPrefix("poll") }.map { "\($0.0)=\($0.1)" } == [
            "poll[options][]=B", "poll[options][]=A", "poll[options][]=C",
            "poll[expires_in]=3600", "poll[multiple]=false", "poll[hide_totals]=false",
        ])
        #expect(after.poll?.votes == 0 && after.poll?.choices.map(\.title) == ["B", "A", "C"])
        #expect(PostChange(text: "y").form.allSatisfy { !$0.0.hasPrefix("poll") })
    }

    @Test("Which changes of a poll start it again, as the server answered: its choices' words, number or order, one or several, or the poll taken off — not its run, nor its figures hidden")
    func whatRestartsAPoll() throws {
        let poll = try #require(try note(Captures.status(content: "<p>x</p>", edited: nil, sensitive: false, language: nil, poll: Captures.pollBefore)).poll)
        let same = NewPoll(choices: ["A", "B", "C"], multiple: false, runs: 3600, hidesTotals: false)
        #expect(!poll.restarted(by: same))
        #expect(!poll.restarted(by: NewPoll(choices: ["A", "B", "C", ""], runs: 7200)))
        #expect(!poll.restarted(by: NewPoll(choices: [" A", "B ", "C"], hidesTotals: true)))
        for changed in [
            NewPoll(choices: ["B", "A", "C"]), NewPoll(choices: ["A", "B", "D"]),
            NewPoll(choices: ["A", "B", "C", "D"]), NewPoll(choices: ["A", "B"]), NewPoll(choices: ["A", "B", "C"], multiple: true),
        ] {
            #expect(poll.restarted(by: changed), "\(changed.choices) multiple \(changed.multiple)")
        }
        #expect(poll.restarted(by: nil))
    }

    @Test("A refusal changes nothing held: the source's words for a 422, a sign-in without the writing part, a post not the reader's, a miss — and a poll beside media or past the source's limits is refused before anything is sent")
    func aRefusalChangesNothing() async throws {
        let before = try note(Captures.withMedia)
        for (outcome, thrown) in [
            (FixtureSender.Outcome.json(Captures.blank, status: 422), MastodonUnprocessable(body: Data(Captures.blank.utf8)) as any Error),
            (.json(Captures.outside, status: 403), MastodonScopeError.outside),
            (.json(Captures.notTheirs, status: 404), MastodonAuthError.http(404)),
            (.json(#"{"id":"1"}"#), MastodonWriteError.unreadable),
            (.json(Captures.status(id: "2", content: "<p>y</p>", edited: "2026-10-21T00:30:00.000Z", sensitive: false, language: nil)), MastodonWriteError.unreadable),
        ] {
            let (write, store, _) = try await writer(holding: [before], [Self.path: outcome])
            do {
                _ = try await write.change(before, to: PostChange(text: ""))
                Issue.record("no refusal for \(thrown)")
            } catch {
                #expect(String(describing: error) == String(describing: thrown))
            }
            #expect(await store.all() == [before])
        }
        let (write, store, server) = try await writer(holding: [before], [Self.path: .json(Captures.changed)])
        let poll = NewPoll(choices: ["A", "B"])
        await #expect(throws: MastodonWriteError.refusedHere(.pollWithMedia)) {
            _ = try await write.change(before, to: PostChange(text: "x", media: [.init(id: "1", description: "")], poll: poll))
        }
        await #expect(throws: MastodonWriteError.refusedHere(.pollRuns(shortest: 300, longest: 2_629_746))) {
            _ = try await write.change(before, to: PostChange(text: "x", poll: NewPoll(choices: ["A", "B"], runs: 0)), pollLimits: .unstated)
        }
        #expect(await server.requests.isEmpty)
        #expect(await store.all() == [before])
    }

    // MARK: - A poll changed, and a read on its way

    /// A poll of three as the server writes it, one vote in it unless said.
    private static func poll(
        ends: String = "2026-10-21T01:23:24.372Z", expired: Bool = false, multiple: Bool = false, votes: Int = 1
    ) -> String {
        """
        {"id":"7","expires_at":"\(ends)","expired":\(expired),"multiple":\(multiple),"votes_count":\(votes),"voters_count":\(votes),"voted":true,"own_votes":[],
         "options":[{"title":"A","votes_count":\(votes)},{"title":"B","votes_count":0},{"title":"C","votes_count":0}],"emojis":[]}
        """
    }

    private func post(edited: String?, poll: String, words: String = "x") throws -> String {
        Captures.status(content: "<p>\(words)</p>", edited: edited, sensitive: false, language: nil, poll: poll)
    }

    /// The row after `answer` landed as a change's answer, and after each of `reads` landed —
    /// by a refresh and by a timeline's ingest — each sent before the change.
    private func landed(holding before: String, answer: String, reads: [String]) async throws -> (after: Note, held: Note) {
        let row = try note(before)
        let (write, store, _) = try await writer(holding: [row], [Self.path: .json(answer)])
        let sentBefore = ReadMoment.now()
        let after = try await write.change(row, to: PostChange(text: "y"))
        for read in reads {
            await store.refresh([try note(read, sent: sentBefore)], ifSourceHere: host)
            await store.ingest([try note(read, sent: sentBefore)])
        }
        return (after, try #require(await store.note(row.key)))
    }

    @Test("A poll sent again as it was starts its run again at the source: a read on its way before the change puts back neither the old end nor the old words")
    func aRestartedRunStands() async throws {
        let changed = try post(edited: "2026-10-21T00:30:00.000Z", poll: Self.poll(ends: "2026-10-21T01:30:00.000Z"), words: "y")
        let (after, held) = try await landed(
            holding: try post(edited: nil, poll: Self.poll()), answer: changed, reads: [try post(edited: nil, poll: Self.poll())]
        )
        let ends = try #require(MastodonJSON.date(from: "2026-10-21T01:30:00.000Z"))
        #expect(after.poll?.endsAt == ends && after.poll?.votes == 1)
        #expect(held.poll == after.poll && held.body == "y")
    }

    @Test("An ended poll opened again by a change reads open, and a read on its way that says it ended does not end it")
    func aReopenedPollStands() async throws {
        let ended = Self.poll(ends: "2026-10-21T00:33:22.194Z", expired: true)
        let reopened = try post(edited: "2026-10-21T00:34:34.614Z", poll: Self.poll(ends: "2026-10-21T01:34:34.614Z"), words: "y")
        let (after, held) = try await landed(holding: try post(edited: nil, poll: ended), answer: reopened, reads: [try post(edited: nil, poll: ended)])
        #expect(after.poll?.expired == false && held.poll == after.poll)
    }

    @Test("One choice become several loses every vote under the same id: a read on its way before it puts back neither one choice nor the votes")
    func aSwitchedPollStands() async throws {
        let switched = try post(edited: "2026-10-21T00:30:00.000Z", poll: Self.poll(multiple: true, votes: 0), words: "y")
        let (after, held) = try await landed(holding: try post(edited: nil, poll: Self.poll()), answer: switched, reads: [try post(edited: nil, poll: Self.poll())])
        #expect(after.poll?.multiple == true && after.poll?.votes == 0)
        #expect(held.poll == after.poll)
    }

    @Test("A poll, or a language, a change took off is not put back by a read on its way before it")
    func whatAChangeTookOffStaysOff() async throws {
        let bare = Captures.status(content: "<p>y</p>", edited: "2026-10-21T00:30:00.000Z", sensitive: false, language: nil)
        let before = Captures.status(content: "<p>x</p>", edited: nil, sensitive: false, language: "en", poll: Self.poll())
        let (after, held) = try await landed(holding: before, answer: bare, reads: [before])
        #expect(after.poll == nil && after.language == nil)
        #expect(held.poll == nil && held.language == nil && held.body == "y")
    }

    @Test("A stale read still brings its figures where the poll is the same question; a later read brings a new end, and a poll ended since")
    func laterReadsStillLand() async throws {
        let changed = try post(edited: "2026-10-21T00:30:00.000Z", poll: Self.poll(ends: "2026-10-21T01:30:00.000Z"), words: "y")
        let staleFigures = try post(edited: nil, poll: Self.poll(votes: 3))
        let (_, held) = try await landed(holding: try post(edited: nil, poll: Self.poll()), answer: changed, reads: [staleFigures])
        let ends = try #require(MastodonJSON.date(from: "2026-10-21T01:30:00.000Z"))
        #expect(held.poll?.votes == 3 && held.poll?.endsAt == ends)

        // Later reads: the same change, ended now; and a change after it with a new run.
        let (_, endedSince) = try await landed(
            holding: try post(edited: nil, poll: Self.poll()), answer: changed,
            reads: [try post(edited: "2026-10-21T00:30:00.000Z", poll: Self.poll(ends: "2026-10-21T01:30:00.000Z", expired: true), words: "y")]
        )
        #expect(endedSince.poll?.expired == true)
        let (_, runAgain) = try await landed(
            holding: try post(edited: nil, poll: Self.poll()), answer: changed,
            reads: [try post(edited: "2026-10-21T00:40:00.000Z", poll: Self.poll(ends: "2026-10-21T02:40:00.000Z"), words: "z")]
        )
        #expect(runAgain.poll?.endsAt == MastodonJSON.date(from: "2026-10-21T02:40:00.000Z") && runAgain.body == "z")
    }

    // MARK: - What it said before

    @Test("History reads to every wording before the one it says now, the original first, each until the next began; a change of a description alone is no new wording")
    func historyReads() async throws {
        let now = try note(Captures.changed)
        let (write, store, server) = try await writer(holding: [now], ["\(Self.path)/history": .json(Captures.history)])
        let wordings = try await write.history(of: now)
        let changedAt = try #require(MastodonJSON.date(from: "2026-10-21T00:24:13.007Z"))
        #expect(wordings == [Wording(body: "media probe", spoiler: "", sensitive: false, until: changedAt)])
        #expect(await server.paths == ["\(Self.path)/history"])
        #expect(await store.all() == [now])

        let (never, _, _) = try await writer(holding: [], ["\(Self.path)/history": .json(Captures.historyUnchanged)])
        #expect(try await never.history(of: now).isEmpty, "a post never changed has nothing before")
    }

    @Test("Several wordings come oldest first, each until the next one that says something else, the cover line a wording too; an entry with no moment is passed over")
    func historyOrdered() throws {
        let at = { (s: TimeInterval) in Date(timeIntervalSince1970: 1_000_000 + s) }
        let said: [(words: Wording, since: Date)] = [
            (Wording(body: "three", until: at(3)), at(3)),
            (Wording(body: "one", until: at(0)), at(0)),
            (Wording(body: "two", until: at(1)), at(1)),
            (Wording(body: "two", spoiler: "", sensitive: true, until: at(2)), at(2)),
            (Wording(body: "three", spoiler: "cw", until: at(4)), at(4)),
        ]
        #expect(MastodonWrite.wordings(said) == [
            Wording(body: "one", until: at(1)), Wording(body: "two", until: at(3)), Wording(body: "three", until: at(4)),
        ])
        #expect(MastodonWrite.wordings([]).isEmpty)
    }

    @Test("A history that is not a list is unreadable, and one entry this build cannot read costs nothing else")
    func historyLenient() async throws {
        let post = try note(Captures.changed)
        let (bad, _, _) = try await writer(holding: [], ["\(Self.path)/history": .json(#"{"error":"x"}"#)])
        await #expect(throws: MastodonWriteError.unreadable) { _ = try await bad.history(of: post) }
        let odd = #"[{"content":"<p>a</p>","created_at":"2026-10-21T00:00:00.000Z"},{"content":7},{"content":"<p>b</p>","created_at":"later"},{"content":"<p>c</p>","created_at":"2026-10-21T00:01:00.000Z"}]"#
        let (lenient, _, _) = try await writer(holding: [], ["\(Self.path)/history": .json(odd)])
        #expect(try await lenient.history(of: post).map(\.body) == ["a"])
    }
}
