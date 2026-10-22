import Foundation
import Testing
@testable import FediqoCore

/// #339, in the half of it Core holds: a report sent, and the server's rules a report names —
/// read from what a real 4.6.6 answered (`MastodonReportCaptures`).
@Suite("A report sent to a Mastodon, and the rules it names")
struct MastodonReportsTests {
    private typealias Captures = MastodonReportCaptures

    private static let origin = "https://\(Captures.host)"
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )

    private func reports(_ routes: [String: FormServer.Answer]) throws -> (MastodonReports, FormServer) {
        let server = FormServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonReports(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    @Test("The server's rules are read as it words them, each its words and its hint, in its own order; a hint of nothing is none; a body that is no list is not read, and an entry that cannot be is that one rule not listed")
    func theRules() async throws {
        let (reports, server) = try reports([
            "GET /api/v1/instance/rules": .init(body: Captures.rules),
        ])
        let rules = try await reports.rules()
        #expect(rules == [
            ServerRule(id: "1", text: "No spam, please.", hint: "Posts made only to sell or to be seen."),
            ServerRule(id: "2", text: "Be kind to one another"),
        ])
        #expect(await server.asked.map(\.address) == ["\(Self.origin)/api/v1/instance/rules"])

        let (odd, _) = try self.reports([
            "GET /api/v1/instance/rules": .init(body: #"[7,{"id":"3","text":"Be\nwell","hint":5},{"id":"","text":"x"},{"id":"4","text":""}]"#),
        ])
        #expect(try await odd.rules() == [ServerRule(id: "3", text: "Be well")])
        let (none, _) = try self.reports(["GET /api/v1/instance/rules": .init(body: "{}")])
        await #expect(throws: MastodonReportError.unreadable) { _ = try await none.rules() }
    }

    @Test("A report is one post to the source, as the person, naming the account, each post, the words, whether the server they live on is told, the category — and the rules only where it is a violation; it hands back what the source took")
    func aReport() async throws {
        let (reports, server) = try reports([
            "POST /api/v1/reports": .init(body: Captures.violation),
        ])
        let taken = try await reports.send(ReportToSend(
            accountID: Captures.person, postIDs: Captures.posts, category: .violation, ruleIDs: ["1"], words: "Selling things"
        ))
        #expect(taken.category == "violation" && !taken.forwarded && taken.ruleIDs == ["1"] && Set(taken.postIDs) == Set(Captures.posts))
        let sent = try #require(await server.asked.first)
        #expect(sent.method == "POST" && sent.address == "\(Self.origin)/api/v1/reports" && sent.bearer == "Bearer tok-123")
        #expect(sent.form == "account_id=\(Captures.person)&status_ids%5B%5D=\(Captures.posts[0])&status_ids%5B%5D=\(Captures.posts[1])"
            + "&comment=Selling%20things&forward=false&category=violation&rule_ids%5B%5D=1")

        // A category but violation sends no rule, whatever was chosen before it changed.
        let spam = ReportToSend(accountID: Captures.person, category: .spam, ruleIDs: ["1"])
        #expect(!spam.form.contains { $0.0 == "rule_ids[]" })
        #expect(ReportToSend(accountID: Captures.person, category: .other, forward: true).form.contains { $0 == ("forward", "true") })
    }

    @Test("Told of somebody of another server, with the person's yes, the source says it passed it on")
    func forwarded() async throws {
        let (reports, _) = try reports(["POST /api/v1/reports": .init(body: Captures.forwarded)])
        let taken = try await reports.send(ReportToSend(
            accountID: Captures.far, postIDs: [Captures.farPost], category: .other, words: "x", forward: true
        ))
        #expect(taken.forwarded && taken.category == "other")
    }

    @Test("What the source will not take is said in its own words and changes nothing; a post of somebody else is a refusal like any other; a sign-in without the word is refused as the door refuses it")
    func refused() async throws {
        let (noRule, _) = try reports(["POST /api/v1/reports": .init(body: Captures.noRule, status: 422)])
        await #expect(throws: MastodonReportError.refused(sentence: "Validation failed: Rule ids does not reference valid rules")) {
            _ = try await noRule.send(ReportToSend(accountID: Captures.person, category: .violation, ruleIDs: ["99"]))
        }
        let (notTheirs, _) = try reports(["POST /api/v1/reports": .init(body: Captures.notTheirs, status: 404)])
        await #expect(throws: MastodonAuthError.http(404)) {
            _ = try await notTheirs.send(ReportToSend(accountID: Captures.person, postIDs: [Captures.farPost], category: .other))
        }
        let (scope, _) = try reports([
            "POST /api/v1/reports": .init(body: Captures.reportRefused, status: 403, authenticate: Captures.reportRefusedAuthenticate),
        ])
        await #expect(throws: MastodonAuthError.http(403)) {
            _ = try await scope.send(ReportToSend(accountID: Captures.person, category: .spam))
        }
        let (long, _) = try reports(["POST /api/v1/reports": .init(body: Captures.tooLong, status: 422)])
        await #expect(throws: MastodonReportError.refused(sentence: "Validation failed: Comment is too long (maximum is 1000 characters)")) {
            _ = try await long.send(ReportToSend(accountID: Captures.person, category: .other, words: "short"))
        }
    }

    @Test("Refused before anything is asked: a report naming nobody or an id that is no one segment, a violation naming no rule, and more words than a server takes; an answer about somebody else is not the report asked for")
    func refusedBeforeAsking() async throws {
        let (reports, server) = try reports(["POST /api/v1/reports": .init(body: Captures.forwarded)])
        let refused = [
            ReportToSend(accountID: "", category: .spam),
            ReportToSend(accountID: "1/2", category: .spam),
            ReportToSend(accountID: Captures.person, postIDs: ["../1"], category: .spam),
            ReportToSend(accountID: Captures.person, category: .violation),
            ReportToSend(accountID: Captures.person, category: .violation, ruleIDs: ["a b"]),
            ReportToSend(accountID: Captures.person, category: .other, words: String(repeating: "a", count: MastodonReports.wordsLength + 1)),
        ]
        for report in refused {
            await #expect(throws: MastodonReportError.invalid) { _ = try await reports.send(report) }
        }
        #expect(await server.asked.isEmpty)
        await #expect(throws: MastodonReportError.unreadable, "the source answered about somebody else") {
            _ = try await reports.send(ReportToSend(accountID: Captures.person, category: .other))
        }
        _ = try await reports.send(ReportToSend(
            accountID: Captures.far, category: .other, words: String(repeating: "a", count: MastodonReports.wordsLength)
        ))
    }

    @Test("Reporting is a part of its own: its one word, standing without acting, asked of no question by itself, and no reason to call a sign-in one that writes")
    func thePart() {
        #expect(MastodonPart.reports.words == ["write:reports"])
        #expect(!MastodonPart.reports.rider && !MastodonPart.reports.needsActing && MastodonPart.reports.wordsBesideActing.isEmpty)
        #expect(MastodonGrant.of(scopes: "read:statuses read:lists read:accounts write:reports") == .reading)
        #expect(MastodonParts.everything.hasSuffix("write:reports admin:read admin:write"))
        #expect(ReportCategory.allCases.map(\.rawValue) == ["spam", "legal", "violation", "other"])
    }
}
