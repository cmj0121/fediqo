import Foundation
import Testing
@testable import FediqoCore

/// A post's poll (#331): read off what a Mastodon sends, kept on the item by the rules its
/// counts and its marks are kept by, voted in once, and written with a new post within what the
/// source says it takes.
@Suite("A poll on a post")
struct PollTests {
    private let host = MastodonFixture.host
    private let source = Source(host: MastodonFixture.host, kind: .mastodon)
    private typealias Captures = MastodonPollCaptures

    private func note(_ json: String, sent: ReadMoment = .now()) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .home, sent: sent)
    }

    private func poll(_ json: String) throws -> Poll {
        try #require(try note(Captures.status(poll: json)).poll)
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

    // MARK: - What the source says

    @Test("An open poll is read whole: its choices and each one's figure, when it ends, one to choose, and that the reader has not voted")
    func anOpenPoll() throws {
        let poll = try poll(Captures.open)
        #expect(poll.id == "34830")
        #expect(poll.choices == [.init(title: "Tea", votes: 6), .init(title: "Coffee", votes: 3), .init(title: "Water", votes: 1)])
        #expect(!poll.multiple && !poll.expired)
        #expect(poll.endsAt == MastodonJSON.date(from: "2036-10-20T08:00:00.000Z"))
        #expect(poll.votes == 10 && poll.voters == 10)
        #expect(poll.voted == false && poll.ownVotes.isEmpty)
        #expect(!poll.countsHidden)
        #expect(poll.share(of: 0) == 0.6 && poll.share(of: 2) == 0.1)
        #expect(!poll.ended(at: MastodonJSON.date(from: "2036-10-20T07:59:59.000Z")!))
        #expect(poll.ended(at: MastodonJSON.date(from: "2036-10-20T08:00:00.000Z")!), "it ends at its moment, whatever the source has said since")
    }

    @Test("Read signed out, a poll says nothing of the reader: not a no")
    func signedOutSaysNothing() throws {
        let poll = try poll(Captures.signedOut)
        #expect(poll.voted == nil && poll.ownVotes.isEmpty)
        #expect(poll.choices.map(\.votes) == [6, 3, 1])
    }

    @Test("A poll of several choices that keeps its figures back says no figure for any choice, the reader's own choices, and shares of the people who voted where it says")
    func hiddenAndMany() throws {
        let poll = try poll(Captures.hiddenMany)
        #expect(poll.multiple && poll.countsHidden)
        #expect(poll.choices.allSatisfy { $0.votes == nil })
        #expect(poll.ownVotes == [0, 2] && poll.chose(2) && !poll.chose(1))
        #expect(poll.share(of: 0) == nil, "a figure kept back is no share")
        let open = Poll(id: "p", choices: [.init(title: "a", votes: 3), .init(title: "b", votes: 2)], multiple: true, votes: 5, voters: 4)
        #expect(open.share(of: 0) == 0.75, "of the four who voted, not of the five votes")
    }

    @Test("An ended poll says so, and takes no vote")
    func anEndedPoll() throws {
        let poll = try poll(Captures.ended)
        #expect(poll.expired && poll.ended())
        #expect(poll.refusal(of: [0]) == .ended)
    }

    @Test("A status with no poll has none, a poll of a shape no Mastodon sends is none, and either way the status reads")
    func noPoll() throws {
        #expect(try note(Captures.status(poll: "null")).poll == nil)
        let garbled = try note(Captures.status(poll: Captures.garbled))
        #expect(garbled.poll == nil)
        #expect(garbled.body == "Which one?" && garbled.statusID == "9")
    }

    @Test("A reblog carries no poll of its own: the post it brings carries it")
    func aReblogsPollIsThePosts() throws {
        let inner = Captures.status(poll: Captures.open)
        let wrapper = """
        {"id":"500","uri":"https://social.example/users/bob/statuses/500/activity",
         "created_at":"2026-10-19T09:00:00.000Z","content":"","visibility":"public",
         "account":{"username":"bob","acct":"bob","display_name":"Bob"},"reblog":\(inner)}
        """
        let arrival = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(wrapper.utf8))
            .arrival(source: source, categories: [.home], sent: .now())
        #expect(arrival.item.isReblog && arrival.item.poll == nil)
        #expect(arrival.reblogged?.poll?.id == "34830")
        // And a note that says it reblogs keeps none it was handed.
        let made = Note(
            id: "r", source: source, author: "Bob", handle: "@bob", body: "", postedAt: .now, categories: [],
            poll: Poll(id: "x", choices: [.init(title: "a", votes: 0)]), refs: [Reference(kind: .reblogs, id: "p")]
        )
        #expect(made.poll == nil)
    }

    @Test("A stranger's poll is held to bounds: choices, their length, no negative figure, and only the reader's choices that name one")
    func bounded() {
        let poll = Poll(
            id: "p", choices: (0..<100).map { .init(title: String(repeating: "x", count: 1000) + "\n\($0)", votes: -3) },
            votes: -1, voters: -1, ownVotes: [5, 5, 200, -1, 2]
        )
        #expect(poll.choices.count == Poll.mostChoices)
        // Cut where it runs past the line, and said to be cut (`LineText.oneLine`).
        #expect(poll.choices.allSatisfy { $0.title.count <= Poll.choiceLength + 1 && $0.title.hasSuffix("…") && !$0.title.contains("\n") && $0.votes == nil })
        #expect(poll.votes == nil && poll.voters == nil)
        #expect(poll.ownVotes == [2, 5])
    }

    @Test("A vote is refused here where the poll ended, the reader voted, nothing is chosen, several are chosen where one is taken, or a choice it does not have")
    func refusals() {
        let one = Poll(id: "p", choices: [.init(title: "a", votes: 1), .init(title: "b", votes: 0)], voted: false)
        #expect(one.refusal(of: [1]) == nil)
        #expect(one.refusal(of: []) == .choices)
        #expect(one.refusal(of: [0, 1]) == .choices)
        #expect(one.refusal(of: [2]) == .choices)
        #expect(one.refusal(of: [1, 1]) == .choices)
        let many = Poll(id: "p", choices: one.choices, multiple: true)
        #expect(many.refusal(of: [0, 1]) == nil)
        #expect(Poll(id: "p", choices: one.choices, voted: true).refusal(of: [0]) == .voted)
        #expect(Poll(id: "p", choices: one.choices, endsAt: Date(timeIntervalSince1970: 0)).refusal(of: [0]) == .ended)
    }

    // MARK: - Kept on the item

    @Test("A read made signed out leaves the reader's vote as it was held, and takes how the poll stands now")
    func silenceKeepsTheVote() throws {
        let voted = try note(Captures.status(poll: Captures.votedCoffee))
        let later = try note(Captures.status(poll: Captures.signedOut))
        let laid = try #require(later.refreshed(over: voted).poll)
        #expect(laid.voted == true && laid.ownVotes == [1])
        #expect(laid.choices.map(\.votes) == [6, 3, 1], "the figures are the later copy's")
    }

    @Test("A read sent before the reader's vote landed takes neither their vote nor the figures without it")
    func aReadOnItsWayDoesNotUndoTheVote() throws {
        let voted = try note(Captures.status(poll: Captures.votedCoffee))
        let stale = try note(Captures.status(poll: Captures.open))
        let laid = try #require(stale.refreshed(over: voted, taking: [.boosted, .favourited, .bookmarked]).poll)
        #expect(laid.voted == true && laid.ownVotes == [1])
        #expect(laid.votes == 11 && laid.choices[1].votes == 4)
        // And taken whole where it is not older: the source's word on the reader wins.
        let taken = try #require(stale.refreshed(over: voted).poll)
        #expect(taken.voted == false && taken.votes == 10)
    }

    @Test("A poll whose author changed its choices is the later copy's whole; an edit that takes the poll off leaves none")
    func aChangedPoll() throws {
        let held = try note(Captures.status(poll: Captures.votedCoffee))
        let reworded = try note(Captures.status(poll: Captures.reworded, edited: "2026-10-19T08:30:00.000Z"))
        let changed = held.revised(by: reworded, was: held)
        #expect(changed.poll?.choices.map(\.title) == ["Green tea", "Black coffee"])
        #expect(changed.poll?.voted == false)
        #expect(changed.editedAt == reworded.editedAt, "the post says it changed")
        #expect(changed.earlier.isEmpty, "the words are the same: a poll changed alone offers no earlier wording")
        let none = try note(Captures.status(poll: "null", edited: "2026-10-19T09:00:00.000Z"))
        #expect(held.revised(by: none, was: held).poll == nil)
    }

    @Test("A row filled from a later copy takes how its poll stands, and its reader's word only where it is not the stale one")
    func filling() throws {
        let held = try note(Captures.status(poll: Captures.open))
        let voted = try note(Captures.status(poll: Captures.votedCoffee))
        #expect(held.filled(from: voted).poll?.voted == true)
        #expect(held.filled(from: voted, marksStand: true).poll?.voted == false)
        #expect(held.filled(from: voted, marksStand: true).poll?.votes == 11, "how it stands is any copy's")
        let plain = try note(Captures.status(poll: "null"))
        #expect(plain.filled(from: voted).poll?.id == "34830", "a row that held none takes it")
    }

    @Test("A sign-in that ended takes the reader's vote off the poll and nothing else of it")
    func withoutTheReader() throws {
        let voted = try note(Captures.status(poll: Captures.votedCoffee))
        #expect(voted.saysReader)
        let plain = voted.withoutReaderMarks()
        #expect(plain.poll?.voted == nil && plain.poll?.ownVotes == [])
        #expect(plain.poll?.choices == voted.poll?.choices)
        #expect(!plain.saysReader)
        // What is said of the reader is held to the choices there are, and the choices are kept.
        let said = try #require(plain.poll).with(voted: true, ownVotes: [9, 1, 1, 0])
        #expect(said.voted == true && said.ownVotes == [0, 1] && said.choices == plain.poll?.choices)
    }

    // MARK: - In the store

    @Test("A copy that differs from the row in its poll alone is a change to it: the store moves and holds the poll as it now stands")
    func aPollAloneIsAChange() async throws {
        let store = ItemStore()
        await store.add(source)
        let first = try note(Captures.status(poll: Captures.open))
        await store.ingest([first])
        let before = await store.revision
        // The same copy again moves nothing.
        await store.ingest([try note(Captures.status(poll: Captures.open))])
        #expect(await store.revision == before)
        await store.refresh([try note(Captures.status(poll: Captures.votedCoffee))], ifSourceHere: host)
        #expect(await store.revision > before)
        #expect(await store.note(first.key)?.poll?.voted == true)
    }

    @Test("A sign-in that ended takes the vote off every held poll of its host")
    func theStoreForgetsTheVote() async throws {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([try note(Captures.status(poll: Captures.votedCoffee))])
        #expect(await store.forgetReaderMarks(host: host))
        let held = await store.all()
        #expect(held.count == 1 && held[0].poll?.voted == nil && held[0].poll?.votes == 11)
    }

    // MARK: - A vote

    @Test("A vote goes to the poll's own id as the reader, once, with the choices by their place; the row takes the answer")
    func aVoteLands() async throws {
        let before = try note(Captures.status(poll: Captures.open))
        let (write, store, server) = try await writer(holding: [before], [
            "/api/v1/polls/34830/votes": .json(Captures.votedCoffee),
        ])
        let after = try await write.vote(before, choices: [1])
        #expect(after.poll?.voted == true && after.poll?.ownVotes == [1])
        #expect(after.key == before.key && after.categories == before.categories)
        #expect(await store.note(before.key)?.poll?.votes == 11)
        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(Self.pairs(request).map(\.0) == ["choices[]"] && Self.pairs(request).map(\.1) == ["1"])
        #expect(await server.paths == ["/api/v1/polls/34830/votes"])
    }

    @Test("Several choices go as several fields, in their order")
    func severalChoices() async throws {
        let open = Poll(id: "40001", choices: [.init(title: "Mon", votes: nil), .init(title: "Wed", votes: nil), .init(title: "Fri", votes: nil)], multiple: true, voted: false)
        var before = try note(Captures.status(poll: Captures.signedOut))
        before.poll = open
        // A copy made anew has lost when it was read (`Note.asked`), and says the reader's word.
        before.asked = .now()
        let (write, _, server) = try await writer(holding: [before], ["/api/v1/polls/40001/votes": .json(Captures.hiddenMany)])
        _ = try await write.vote(before, choices: [2, 0])
        #expect(Self.pairs(await server.requests.first).map(\.1) == ["0", "2"])
    }

    @Test("A vote the poll will not take is refused here, and nothing is asked: ended, voted already, or chosen wrong")
    func refusedHere() async throws {
        for (json, choices, refusal) in [(Captures.ended, [0], PollRefusal.ended), (Captures.votedCoffee, [0], .voted), (Captures.open, [0, 1], .choices)] {
            let before = try note(Captures.status(poll: json))
            let (write, store, server) = try await writer(holding: [before], [:])
            await #expect(throws: MastodonWriteError.refusedHere(.vote(refusal))) {
                _ = try await write.vote(before, choices: choices)
            }
            #expect(await server.requests.isEmpty)
            #expect(await store.all() == [before])
        }
    }

    @Test("A source that refuses the vote, or cannot be reached, changes nothing on this device")
    func aFailureChangesNothing() async throws {
        let before = try note(Captures.status(poll: Captures.open))
        for outcome in [FixtureSender.Outcome.json(#"{"error":"You have already voted on this poll"}"#, status: 422), .fail] {
            let (write, store, _) = try await writer(holding: [before], ["/api/v1/polls/34830/votes": outcome])
            await #expect(throws: (any Error).self) { _ = try await write.vote(before, choices: [0]) }
            #expect(await store.all() == [before])
        }
    }

    @Test("A read sent before the vote landed and arriving after it does not draw the poll unvoted again")
    func theVoteOutrunsTheRead() async throws {
        let before = try note(Captures.status(poll: Captures.open))
        let (write, store, _) = try await writer(holding: [before], ["/api/v1/polls/34830/votes": .json(Captures.votedCoffee)])
        let sentBefore = ReadMoment.now()
        _ = try await write.vote(before, choices: [1])
        await store.refresh([try note(Captures.status(poll: Captures.open), sent: sentBefore)], ifSourceHere: host)
        let held = try #require(await store.note(before.key)?.poll)
        #expect(held.voted == true && held.ownVotes == [1] && held.votes == 11)
        // A read sent after it is the source's later word, and is taken.
        await store.refresh([try note(Captures.status(poll: Captures.open), sent: .now())], ifSourceHere: host)
        #expect(await store.note(before.key)?.poll?.voted == false)
    }

    // MARK: - A post written with one

    @Test("A post with a poll sends its choices, how long it runs, and both answers outright")
    func aPostWithAPoll() async throws {
        let (write, _, server) = try await writer(["/api/v1/statuses": .json(Captures.status(poll: Captures.open))])
        let poll = NewPoll(choices: [" Tea ", "", "Coffee"], multiple: true, runs: 3600, hidesTotals: true)
        let note = try await write.post("Which one?", visibility: .everyone, poll: poll, pollLimits: .unstated)
        #expect(note.poll?.id == "34830")
        let pairs = Self.pairs(await server.requests.first)
        #expect(pairs.filter { $0.0 == "poll[options][]" }.map(\.1) == ["Tea", "Coffee"], "trimmed, and the empty one left out")
        #expect(pairs.first { $0.0 == "poll[expires_in]" }?.1 == "3600")
        #expect(pairs.first { $0.0 == "poll[multiple]" }?.1 == "true")
        #expect(pairs.first { $0.0 == "poll[hide_totals]" }?.1 == "true")
        // A post without one sends none of it.
        let (plain, _, bare) = try await writer(["/api/v1/statuses": .json(Captures.status(poll: "null"))])
        _ = try await plain.post("hello", visibility: .everyone)
        #expect(!Self.pairs(await bare.requests.first).contains { $0.0.hasPrefix("poll") })
    }

    @Test("A poll beside media, or past what the source said it takes, is refused here and nothing is sent")
    func pollRefusedHere() async throws {
        let (write, _, server) = try await writer(["/api/v1/statuses": .json(Captures.status(poll: Captures.open))])
        let poll = NewPoll(choices: ["a", "b"])
        await #expect(throws: MastodonWriteError.refusedHere(.pollWithMedia)) {
            _ = try await write.post("x", visibility: .everyone, mediaIDs: ["m1"], poll: poll)
        }
        let limits = MastodonPollLimits(choices: 2, choiceLength: 3, shortest: 300, longest: 3600)
        for (bad, refusal) in [
            (NewPoll(choices: ["a"]), MastodonWriteRefusal.pollChoices(most: 2)),
            (NewPoll(choices: ["a", "b", "c"]), .pollChoices(most: 2)),
            (NewPoll(choices: ["long", "b"]), .pollChoiceLength(limit: 3)),
            (NewPoll(choices: ["a", "a"]), .pollSameChoice),
            (NewPoll(choices: ["a", "b"], runs: 86_400), .pollRuns(shortest: 300, longest: 3600)),
        ] {
            #expect(bad.refusal(within: limits) == refusal)
            await #expect(throws: MastodonWriteError.refusedHere(refusal)) {
                _ = try await write.post("x", visibility: .everyone, poll: bad, pollLimits: limits)
            }
        }
        #expect(await server.requests.isEmpty)
        // Where this run heard no limits, the source is the judge of its own.
        _ = try await write.post("x", visibility: .everyone, poll: NewPoll(choices: ["a", "b"], runs: 86_400 * 60))
        #expect(await server.requests.count == 1)
    }

    @Test("What a source says a poll may be is read off its instance document, and Mastodon's own where it says nothing")
    func pollLimits() {
        let said = MastodonPollLimits(document: Data(Captures.instance.utf8))
        #expect(said == MastodonPollLimits(choices: 6, choiceLength: 80, shortest: 300, longest: 604_800))
        #expect(said.offeredRuns == MastodonPollLimits.runs)
        #expect(MastodonPollLimits(document: Data("{}".utf8)) == .unstated)
        #expect(MastodonPollLimits(document: Data(#"{"configuration":{"polls":{"max_options":true,"max_expiration":0}}}"#.utf8)) == .unstated)
        let short = MastodonPollLimits(choices: 4, choiceLength: 50, shortest: 600, longest: 3600)
        #expect(short.offeredRuns == [1800, 3600])
        let odd = MastodonPollLimits(choices: 4, choiceLength: 50, shortest: 400, longest: 500)
        #expect(odd.offeredRuns == [400], "where none of the usual runs fits, the shortest it takes")
    }
}
