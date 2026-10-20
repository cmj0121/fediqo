import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// A post's poll in the shell (#331): shown on the row it stands in, voted in once from there or
/// from the opened post, read again, and not undone by a read already on its way — asked of the
/// session, as a running app asks it.
///
/// What a test can reach: what the session draws from, and what was sent and in what order. What
/// it cannot: the poll as it looks on a Mac and a phone, in light and dark, and what VoiceOver
/// reads aloud of it — those are a running app's.
@Suite("A poll is voted in from the shell", .watched)
@MainActor
struct PollVoteTests {
    private static let host = "social.example"
    private typealias Captures = MastodonPollCaptures

    /// One source as its signed-in reader sees it: Home holding post 9 with a poll, the poll's
    /// votes, and post 9 read again.
    private actor Server: HTTPSender {
        private var poll: String
        private var voteStatus = 200
        private var holdingVote: Gate?
        private var holdingHome: Gate?
        private(set) var votes: [String] = []
        private(set) var homeAsks = 0

        init(_ poll: String) { self.poll = poll }

        func refuseVotes(_ status: Int) { voteStatus = status }
        func holdVote(_ gate: Gate?) { holdingVote = gate }
        func holdHome(_ gate: Gate?) { holdingHome = gate }
        func pollIs(_ json: String) { poll = json }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url else { throw FixtureHTTPError.unmapped }
            var status = 200
            let body: String
            switch url.path {
            case "/api/v1/timelines/home":
                homeAsks += 1
                body = "[\(Captures.status(poll: poll))]"
                if let gate = holdingHome {
                    holdingHome = nil
                    await gate.wait()
                }
            case "/api/v1/statuses/9":
                body = Captures.status(poll: poll)
            case "/api/v1/polls/34830/votes":
                let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                votes.append(form.removingPercentEncoding ?? form)
                if let gate = holdingVote {
                    holdingVote = nil
                    await gate.wait()
                }
                status = voteStatus
                if status == 200 {
                    poll = Captures.votedCoffee
                    body = poll
                } else {
                    body = #"{"error":"Validation failed: You have already voted on this poll"}"#
                }
            default: throw FixtureHTTPError.unmapped
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    private static func token(writing: Bool) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: MastodonOAuth.scopes(writing: writing)
        )
    }

    /// A session signed in — to act, or only to read — holding post 9 as Home last brought it.
    private func shell(
        _ poll: String = Captures.open, writing: Bool = true
    ) async throws -> (ShellSession, Server, TimelineQuery) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token(writing: writing))
        let server = Server(poll)
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        let home = TimelineDefinition(name: "Home", rules: [
            try #require(Rule.category(.home, in: .source(host: Self.host), sources: session.sources)),
        ])
        session.written = [home]
        await session.reload.timeline(.written(home.id), in: session)
        #expect(session.notes.first?.poll != nil, "the premise: Home brought the post and its poll")
        return (session, server, .written(home.id))
    }

    private func row(_ session: ShellSession) throws -> DummyItem {
        DummyItem(try #require(session.notes.first))
    }

    // MARK: - The vote

    @Test("A vote from the row goes once with what was chosen, the row draws it as the source answered, and a second press sends nothing")
    func aVoteLands() async throws {
        let (session, server, _) = try await shell()
        let row = try row(session)
        #expect(session.acting(on: row).acts.offers(.vote))
        #expect(await session.vote(row, choices: [1]))
        #expect(await server.votes == ["choices[]=1"])
        let poll = try #require(session.notes.first?.poll)
        #expect(poll.voted == true && poll.ownVotes == [1] && poll.votes == 11)
        #expect(await session.store.all().first?.poll?.voted == true, "the store holds what the source said")
        #expect(session.acts.standing(of: row.id, .vote) == nil)
        #expect(await session.vote(try self.row(session), choices: [0]) == false, "voted is voted")
        #expect(await server.votes.count == 1)
    }

    @Test("While the vote is out the row draws what was chosen, a second press sends nothing, and a reload on its way that lands meanwhile does not undo the vote")
    func shownFirstAndNotUndone() async throws {
        let (session, server, home) = try await shell()
        let row = try row(session)
        let asked = await server.homeAsks

        let homeGate = Gate()
        let homeWatch = watching(homeGate, "the reload of Home, held on the wire")
        defer { homeWatch.cancel() }
        await server.holdHome(homeGate)
        let reloading = Task { await session.reload.timeline(home, in: session) }
        await met("the reload is on the wire", by: reloading) { await server.homeAsks == asked + 1 }

        let voteGate = Gate()
        let voteWatch = watching(voteGate, "the vote, held on the wire")
        defer { voteWatch.cancel() }
        await server.holdVote(voteGate)
        let voting = Task { await session.vote(row, choices: [1]) }
        await met("the vote is on the wire", by: voting) { await server.votes.count == 1 }

        let acting = session.acting(on: row)
        #expect(session.acts.chosen(on: row.id) == [1])
        let drawn = PollWords.drawn(try #require(row.poll), chosen: session.acts.chosen(on: row.id))
        #expect(drawn.voted == true && drawn.ownVotes == [1], "what was chosen is drawn at once")
        #expect(!PollWords.votable(try #require(row.poll), acting: acting), "and no second vote is offered meanwhile")
        #expect(await session.vote(row, choices: [0]) == false)
        #expect(session.notes.first?.poll?.voted == false, "the store has not moved")

        await voteGate.open()
        #expect(await voting.value)
        await homeGate.open()
        await reloading.value
        let poll = try #require(session.notes.first?.poll)
        #expect(poll.voted == true && poll.ownVotes == [1], "the reload on its way took the vote back")
        #expect(session.acts.chosen(on: row.id) == nil)
        #expect(await server.votes.count == 1)
    }

    @Test("An ended poll says so and takes no vote: nothing is offered, nothing is sent")
    func anEndedPoll() async throws {
        let (session, server, _) = try await shell(Captures.ended)
        let row = try row(session)
        let poll = try #require(row.poll)
        #expect(!PollWords.votable(poll, acting: session.acting(on: row)))
        #expect(PollWords.summary(poll, language: .english).contains("ended"))
        #expect(await session.vote(row, choices: [0]) == false)
        #expect(await server.votes.isEmpty)
    }

    @Test("A source that refuses the vote says so once, the poll is as it was, and the same press may try again")
    func aRefusal() async throws {
        let (session, server, _) = try await shell()
        await server.refuseVotes(422)
        let row = try row(session)
        let before = session.notes.first
        #expect(await session.vote(row, choices: [1]))
        #expect(session.notes.first == before)
        #expect(await session.store.all().first?.poll?.voted == false)
        #expect(session.acts.standing(of: row.id, .vote) == .failed)
        let said = try #require(session.said.lines.first)
        #expect(said.words(language: .english).contains("did not take the vote"))
        await server.refuseVotes(200)
        #expect(await session.vote(row, choices: [1]))
        #expect(session.notes.first?.poll?.voted == true)
        #expect(session.acts.standing(of: row.id, .vote) == nil)
    }

    @Test("The poll is read again where it stands, and its figures are the source's now")
    func readAgain() async throws {
        let (session, server, _) = try await shell()
        await server.pollIs(Captures.votedCoffee)
        await session.readPollAgain(try row(session))
        #expect(session.notes.first?.poll?.votes == 11)
    }

    @Test("A row two sources carried draws the poll its vote is checked against: the copy the vote goes through, which says the reader voted, and not the first copy, read signed out")
    func aMergedRowDrawsTheVotingCopysPoll() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: "b.example", accessToken: "tok-b", clientID: "cid", clientSecret: "csecret",
            scopes: MastodonOAuth.scopes(writing: true)
        ))
        let server = Server(Captures.open)
        let store = ItemStore()
        for host in ["a.example", "b.example"] { await store.add(Source(host: host, kind: .mastodon)) }
        let open = Poll(id: "34830", choices: [.init(title: "Tea", votes: 6), .init(title: "Coffee", votes: 3)], votes: 9)
        func copy(on host: String, _ statusID: String, poll: Poll) -> Note {
            Note(
                id: "https://origin.example/users/ada/statuses/1", source: Source(host: host, kind: .mastodon),
                author: "Ada", handle: "@ada@origin.example", body: "Which?",
                postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home], statusID: statusID, poll: poll
            ).readNow()
        }
        // The first copy, read signed out, says nothing of the reader; the second says they voted.
        await store.ingest([copy(on: "a.example", "111", poll: open)])
        await store.ingest([copy(on: "b.example", "222", poll: Poll(id: "34830", choices: open.choices, votes: 10, voted: true, ownVotes: [1]))])
        let session = ShellSession(http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        session.mastodon.refresh()
        await session.reloadFromStore()
        let rows = DummyItem.merged(session.notes)
        let row = try #require(rows.first)
        try #require(rows.count == 1 && row.source.host == "a.example" && row.otherCopies.count == 1, "the premise: one row, drawn as the first copy")
        #expect(row.poll?.voted == nil)
        let acting = session.acting(on: row)
        #expect(acting.acts.offers(.vote) && session.actingCopy(of: row, for: .vote)?.source.host == "b.example")
        let drawn = try #require(acting.poll)
        #expect(drawn.voted == true && drawn.ownVotes == [1], "the poll drawn is the voting copy's")
        #expect(!PollWords.votable(drawn, acting: acting), "so no vote is offered that the press would refuse")
        #expect(await session.vote(row, choices: [0]) == false)
        #expect(await server.votes.isEmpty)
    }

    // MARK: - Signed in for less

    @Test("Signed in only to read: no vote is offered, the poll says why, and its press puts the question that names voting before the source's page opens")
    func signedInToRead() async throws {
        let (session, server, _) = try await shell(writing: false)
        let row = try row(session)
        var acting = session.acting(on: row)
        #expect(!acting.acts.offers(.vote))
        let lock = try #require(session.voteLock(on: row))
        acting.voteLock = lock
        #expect(lock.place.key == "part.acting.unasked")
        let poll = try #require(row.poll)
        #expect(PollWords.why(poll, acting, language: .english)?.contains("write as you") == true)
        // A poll that ended, or that the reader voted in, says that and no lock: no sign-in
        // would change it.
        let ended = Poll(id: poll.id, choices: poll.choices, expired: true)
        let voted = Poll(id: poll.id, choices: poll.choices, voted: true, ownVotes: [0])
        #expect(PollWords.why(ended, acting, language: .english) == nil)
        #expect(PollWords.why(voted, acting, language: .english) == nil)
        #expect(PollWords.why(poll, acting, now: try #require(MastodonJSON.date(from: "2037-01-01T00:00:00.000Z")), language: .english) == nil)
        #expect(await session.vote(row, choices: [1]) == false)
        #expect(await server.votes.isEmpty)
        #expect(session.askFor([.acting], host: Self.host))
        let ask = try #require(session.partAsks.open)
        #expect(ask.ticked == [.acting])
        let question = ShellQuestion.part(ask, language: .english)
        #expect(question.help?.contains("vote in a poll") == true, "the person is told what more the page will ask")
    }

    @Test("A source that has no polls offers no vote, by what that kind of source offers and never by its name")
    func noPollsNoVote() {
        #expect(ProtocolKind.mastodon.offers.polls)
        for kind in ProtocolKind.allCases where kind != .mastodon { #expect(!kind.offers.polls, "\(kind)") }
        #expect(!PostActs.on(.writes, nameable: true, polls: false).offers(.vote))
        #expect(PostActs.on(.writes, nameable: true, polls: true).offers(.vote))
        #expect(!PostActs.on(.never, nameable: true, polls: true).offers(.vote))
    }

    // MARK: - What it says

    @Test("A poll's line says what it is, how many voted, the reader's vote and when it ends, in each language")
    func words() throws {
        let note = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Captures.status(poll: Captures.hiddenMany).utf8))
            .asNote(source: Source(host: Self.host, kind: .mastodon), category: .home, sent: .now())
        let poll = try #require(note.poll)
        let now = try #require(MastodonJSON.date(from: "2036-10-25T08:00:00.000Z"))
        #expect(PollWords.summary(poll, now: now, language: .english) == "Poll · 4 people · you voted · ends in 1 day · figures shown when it ends")
        #expect(PollWords.summary(poll, now: now, language: .taiwanese).hasPrefix("投票 · 4 人 · 你已投票 · "))
        #expect(PollWords.spokenChoice(poll, 2, language: .english) == "Fri, your vote")
        let open = Poll(id: "p", choices: [.init(title: "Tea", votes: 1), .init(title: "Coffee", votes: 3)], votes: 4, voted: false)
        #expect(PollWords.share(open, 1, language: .english) == "75%")
        #expect(PollWords.spokenChoice(open, 0, language: .english) == "Tea, 25%, 1 vote")
        #expect(PollWords.summary(open, language: .english) == "Poll · 4 votes · open")
        for key in [
            "poll.title", "poll.votes", "poll.voters", "poll.voted", "poll.ends", "poll.ended", "poll.open", "poll.hidden",
            "poll.choice.stands", "poll.choice.yours", "poll.vote", "poll.read", "poll.read.failed", "poll.open.hint",
            "item.act.vote", "item.act.voted",
        ] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("A row in a list says its poll in one line and keeps its one height; the opened post draws the whole poll")
    func oneLineInAList() throws {
        #if os(macOS)
        let source = Source(host: Self.host, kind: .mastodon)
        let poll = Poll(id: "p", choices: (0..<4).map { (i: Int) in Poll.Choice(title: "Choice \(i)", votes: i) }, votes: 6, voted: false)
        func item(_ poll: Poll?) -> DummyItem {
            DummyItem(Note(
                id: "1", source: source, author: "Ada", handle: "@ada@social.example", body: "Which one of these?",
                postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], audience: .everyone,
                statusID: "1", poll: poll
            ))
        }
        func laid(_ item: DummyItem, inFull: Bool) -> (RowBandProbe, CGSize) {
            let probe = RowBandProbe()
            let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), inFull: inFull, probe: probe)
            let hosted = NSHostingView(rootView: row.frame(width: 640))
            hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
            hosted.layoutSubtreeIfNeeded()
            return (probe, hosted.fittingSize)
        }
        let (listed, listedSize) = laid(item(poll), inFull: false)
        let (_, plainSize) = laid(item(nil), inFull: false)
        #expect(abs(listedSize.height - plainSize.height) <= 0.5, "a poll grew the row: \(listedSize.height) against \(plainSize.height)")
        let line = try #require(listed.frames[.poll], "the row says nothing of its poll")
        let content = try #require(listed.frames[.content])
        #expect(line.maxY <= content.maxY + 0.5, "the poll's line is inside the words' band")
        let (opened, _) = laid(item(poll), inFull: true)
        let band = try #require(opened.frames[.poll], "the opened post draws no poll")
        #expect(band.height > line.height * 3, "the opened post draws every choice")
        #endif
    }
}
