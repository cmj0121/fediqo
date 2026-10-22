import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #376: whose notices a source holds back is the person's to choose, from the notices page — read
/// with what it holds, changed with one press that shows at once, and the source's own answer
/// once it lands, whatever a read on its way says after.
@Suite("Whose notices a source holds back is chosen here")
@MainActor
struct NoticePolicyTests {
    private typealias F = NoticeActFixture

    init() {
        L10n.language = .english
    }

    private static let path = "/api/v2/notifications/policy"

    private static func policy(_ notFollowing: String, requests: Int = 0) -> String {
        """
        {"for_not_following":"\(notFollowing)","for_not_followers":"accept","for_new_accounts":"accept",\
        "for_private_mentions":"filter","for_limited_accounts":"filter",\
        "summary":{"pending_requests_count":\(requests),"pending_notifications_count":\(requests)}}
        """
    }

    private static func patch(_ host: String) -> String { "PATCH \(host)\(path)" }

    private func shell(
        _ routes: [String: NoticeActServer.Outcome], scopes: String = F.acts
    ) async throws -> (ShellSession, NoticeActServer) {
        var all = routes
        all[F.get(F.a)] = all[F.get(F.a)] ?? F.page(F.one(1, minutes: 1))
        let (session, server, _) = try await F.shell(all, signedIn: [F.a: scopes, F.b: scopes])
        return (session, server)
    }

    @Test("Read with what is held: the five choices as the source says them; a source with no such thing offers none and says why")
    func readWithTheHeld() async throws {
        let (session, _) = try await shell([F.get(F.a, Self.path): .body(Self.policy("accept"))])
        let acts = session.noticeList.acts
        await acts.readPage(in: session)
        let policy = try #require(acts.shownPolicy(host: F.a))
        #expect(policy.offered == NoticePolicy.Whose.allCases && policy.ways[.notFollowing] == .accept)
        #expect(NoticePolicyWords.stands(F.a, in: session) == .offered(policy))
        // b answers 404: it cannot hold notices back, and the place says so.
        #expect(acts.holdings[F.b] == .absent && NoticePolicyWords.stands(F.b, in: session) == .absent)
        #expect(NoticePolicyWords.absent(F.b, language: .english) == "b.example cannot hold notices back, so there is nothing to choose here.")
    }

    @Test("A choice shows at once, is sent as that one field, and once the source answers it is the source's own word")
    func aChoiceShowsAtOnce() async throws {
        let gate = Gate()
        let (session, server) = try await shell([
            F.get(F.a, Self.path): .body(Self.policy("accept")),
            Self.patch(F.a): .held(gate, Self.policy("filter", requests: 1)),
        ])
        let acts = session.noticeList.acts
        await acts.readPage(in: session)
        let task = Task { await acts.choose(.filter, for: .notFollowing, at: F.a, in: session) }
        await met("the choice is on the wire", by: task) { await server.count(Self.patch(F.a)) == 1 }
        #expect(acts.shownPolicy(host: F.a)?.ways[.notFollowing] == .filter, "drawn at once")
        await gate.open()
        await task.value
        #expect(acts.choosing[F.a]?.isEmpty != false)
        #expect(acts.policies[F.a]?.ways[.notFollowing] == .filter, "the source's answer")
        #expect(acts.held(host: F.a) == NoticesHeld(requests: 1, notices: 1), "and what it holds now, from the same answer")
    }

    private static func policy(_ ways: [NoticePolicy.Whose: String]) -> String {
        let fields = NoticePolicy.Whose.allCases.map { "\"\($0.rawValue)\":\"\(ways[$0] ?? "accept")\"" }.joined(separator: ",")
        return "{" + fields + ",\"summary\":{\"pending_requests_count\":0,\"pending_notifications_count\":0}}"
    }

    @Test("Choices sent close together go one at a time a source: the second waits, drawn as chosen, and is sent once the first is answered — so a late answer never puts back what was since chosen")
    func oneAtATime() async throws {
        let gate = Gate()
        let (session, server) = try await shell([
            F.get(F.a, Self.path): .body(Self.policy("accept")),
            Self.patch(F.a): .held(gate, Self.policy([.notFollowing: "filter"])),
        ])
        let acts = session.noticeList.acts
        await acts.readPage(in: session)
        let first = Task { await acts.choose(.filter, for: .notFollowing, at: F.a, in: session) }
        await met("the first choice is on the wire", by: first) { await server.count(Self.patch(F.a)) == 1 }
        // Two more while it is out: another kind, and the same kind chosen again.
        await acts.choose(.drop, for: .newAccounts, at: F.a, in: session)
        await acts.choose(.drop, for: .notFollowing, at: F.a, in: session)
        #expect(await server.count(Self.patch(F.a)) == 1, "nothing more is sent while one is out")
        #expect(acts.shownPolicy(host: F.a)?.ways[.notFollowing] == .drop && acts.shownPolicy(host: F.a)?.ways[.newAccounts] == .drop)
        // The source answers each in turn, each answer the whole policy as it then stands.
        let second = Gate()
        await server.set(Self.patch(F.a), .held(second, Self.policy([.notFollowing: "drop"])))
        await gate.open()
        await met("the next waiting choice is sent", by: first) { await server.count(Self.patch(F.a)) == 2 }
        await server.set(Self.patch(F.a), .body(Self.policy([.notFollowing: "drop", .newAccounts: "drop"])))
        await second.open()
        await first.value
        #expect(await server.count(Self.patch(F.a)) == 3, "the first, then each waiting, one at a time")
        #expect(acts.policies[F.a]?.ways[.notFollowing] == .drop, "the later choice of the same kind stands")
        #expect(acts.policies[F.a]?.ways[.newAccounts] == .drop, "and the other kind's, never put back")
        #expect(acts.choosing[F.a]?.isEmpty != false)
    }

    @Test("A choice that already stands is not sent")
    func aStandingChoiceIsNotSent() async throws {
        let (session, server) = try await shell([F.get(F.a, Self.path): .body(Self.policy("accept"))])
        let acts = session.noticeList.acts
        await acts.readPage(in: session)
        await acts.choose(.accept, for: .notFollowing, at: F.a, in: session)
        #expect(await server.count(Self.patch(F.a)) == 0)
    }

    @Test("Letting a kind's notices go asks first, in one line, with a way out; its yes is the one press that sends")
    func lettingGoAsksFirst() {
        let question = NoticePolicyWords.letGoQuestion(.newAccounts, at: F.a, language: .english)
        #expect(question.title == "Let go of notices from New accounts on a.example?")
        #expect(question.chorded?.role == .destructive && question.cancel != nil)
        var sent = 0
        let ask = ShellMoreAsk(question: question) { sent += 1 }
        ask.answered("anything else")
        #expect(sent == 0)
        ask.answered(ShellQuestion.yes)
        #expect(sent == 1)
    }

    @Test("A read of what is held back already on its way when the choice's answer lands does not put the old choice back")
    func aReadOnItsWayDoesNotUndoIt() async throws {
        let read = Gate()
        let (session, server) = try await shell([F.get(F.a, Self.path): .body(Self.policy("accept"))])
        let acts = session.noticeList.acts
        await acts.readPage(in: session)
        // The next look is held with the old word in it.
        await server.set(F.get(F.a, Self.path), .held(read, Self.policy("accept")))
        let looking = Task { await acts.look(in: session) }
        await met("the look is on the wire", by: looking) { await server.count(F.get(F.a, Self.path)) == 2 }
        await server.set(Self.patch(F.a), .body(Self.policy("drop")))
        await acts.choose(.drop, for: .notFollowing, at: F.a, in: session)
        #expect(acts.policies[F.a]?.ways[.notFollowing] == .drop)
        await read.open()
        await looking.value
        #expect(acts.shownPolicy(host: F.a)?.ways[.notFollowing] == .drop, "the look sent before the answer changed nothing")
    }

    @Test("Refused, what is drawn goes back to what the source said, and the page says it would not")
    func aRefusalGoesBack() async throws {
        let (session, _) = try await shell([
            F.get(F.a, Self.path): .body(Self.policy("accept")),
            Self.patch(F.a): .status(403),
        ])
        let acts = session.noticeList.acts
        await acts.readPage(in: session)
        await acts.choose(.drop, for: .notFollowing, at: F.a, in: session)
        #expect(acts.shownPolicy(host: F.a)?.ways[.notFollowing] == .accept)
        let said = try #require(acts.said[F.a])
        #expect(said.act == .policy)
        #expect(NoticeActs.words(said, host: F.a, language: .english).contains("a.example"))
    }

    @Test("Signed in to read notices and not change them, nothing is offered and nothing sent: the place says what more will be asked")
    func signedInForLess() async throws {
        let (session, server) = try await shell([F.get(F.a, Self.path): .body(Self.policy("accept"))], scopes: F.reads)
        let acts = session.noticeList.acts
        await acts.readPage(in: session)
        #expect(NoticePolicyWords.stands(F.a, in: session) == .locked)
        await acts.choose(.drop, for: .notFollowing, at: F.a, in: session)
        #expect(await server.count(Self.patch(F.a)) == 0)
        #expect(NoticePolicyWords.locked(F.a, language: .english).contains("asks for"))
    }

    @Test("Each choice is named in every language, and a listener hears who and what becomes of them", arguments: [DummyLanguage.english, .taiwanese])
    func eachChoiceIsNamed(_ language: DummyLanguage) {
        for whose in NoticePolicy.Whose.allCases {
            let name = NoticePolicyWords.whose(whose, language: language)
            #expect(!name.hasPrefix("notices.policy"), "\(whose)")
            for way in NoticePolicy.Way.allCases {
                #expect(!NoticePolicyWords.way(way, language: language).hasPrefix("notices.policy"))
                #expect(NoticePolicyWords.spoken(whose, way, language: language).contains(name))
            }
        }
        #expect(NoticePolicyWords.spoken(.newAccounts, .filter, language: .english) == "New accounts. Hold back")
    }
}
