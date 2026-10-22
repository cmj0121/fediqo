import Foundation
import Testing
@testable import FediqoCore

/// #380 and #381, in the half of them Core holds: the standing a server's role gives, read off
/// the account check; tending's part and its words; and what was reported, read on and acted on
/// — from what a real 4.6.6 answered (`MastodonAdminCaptures`).
@Suite("Tending a server: the standing, the part, and what was reported")
struct MastodonAdminTests {
    private typealias Captures = MastodonAdminCaptures

    private static let source = Source(host: Captures.host, kind: .mastodon)
    private static let token = MastodonToken(host: Captures.host, accessToken: "tok-381", clientID: "cid", clientSecret: "secret")
    private static let path = MastodonAdminReports.path

    private func reader(_ routes: [String: PeopleServer.Answer]) throws -> (MastodonAdminReports, PeopleServer) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonAdminReports(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    // MARK: - The standing

    @Test("The standing is the role the account check names: the Admin's lets reports and servers be tended, the Moderator's reports and not servers, and the writer's — everybody's role — nothing of tending; a check with no role, or one that cannot be read, is no standing")
    func theStanding() throws {
        let admin = try #require(MastodonWho.said(Data(Captures.adminCheck.utf8), at: Captures.host).staff)
        let mod = try #require(MastodonWho.said(Data(Captures.modCheck.utf8), at: Captures.host).staff)
        let writer = try #require(MastodonWho.said(Data(Captures.writerCheck.utf8), at: Captures.host).staff)
        #expect(admin.allows(.manageReports) && admin.allows(.manageFederation) && admin.allows(.manageUsers))
        #expect(mod.allows(.manageReports) && !mod.allows(.manageFederation) && !mod.allows(.manageBlocks))
        let tasks: [MastodonStaff] = [
            .viewDashboard, .manageReports, .manageFederation, .manageBlocks, .manageTaxonomies, .manageUsers, .manageRules,
        ]
        #expect(tasks.allSatisfy { !writer.allows($0) }, "65536 is a flag no task of tending reads")
        #expect(MastodonStaff.administrator.allows(.manageRules), "the administrator is granted every flag")
        for role in [#"{"id":"1","acct":"a"}"#, #"{"id":"1","acct":"a","role":{"permissions":"lots"}}"#,
                     #"{"id":"1","acct":"a","role":{"permissions":"123456789012345678901234"}}"#, #"{"acct":"a","role":{"permissions":"16"}}"#] {
            #expect(MastodonWho.said(Data(role.utf8), at: Captures.host).staff == nil, "\(role)")
        }
        #expect(MastodonWho.said(Data(#"{"id":"1","acct":"a","role":{"permissions":16}}"#.utf8), at: Captures.host).staff == .manageReports)
    }

    @Test("Tending is a part of its own, its two words the server's broad ones, apart from every other; it rides on no question and adds to no other; read only drops the word that changes; every registration from now on holds it")
    func thePart() {
        #expect(MastodonPart.tending.words == ["admin:read", "admin:write"])
        #expect(!MastodonPart.tending.rider && !MastodonPart.tending.needsActing && MastodonPart.tending.wordsBesideActing.isEmpty)
        #expect(MastodonPart.allCases.last == .tending, "no scope string sent before changes")
        #expect(MastodonParts.everything.hasSuffix("write:reports admin:read admin:write"))
        #expect(MastodonParts.page(held: nil, ticked: [.reading, .tending], readOnly: true)
            == "read:statuses read:lists read:accounts admin:read")
        #expect(MastodonParts.half(of: .tending, in: "admin:read") == .seeing)
        #expect(MastodonParts.half(of: .tending, in: "admin:write") == .changing)
        // A registration made before cannot carry a page asking for it: it is made again.
        let before = MastodonParts.everything.replacingOccurrences(of: " admin:read admin:write", with: "")
        #expect(MastodonRegistration.page(MastodonParts.page(held: nil, ticked: [.reading, .tending]), on: before) == nil)
    }

    // MARK: - What was reported

    @Test("The open reports a real server listed are read newest first: who reported, whom, what was said, the posts it names as posts of this source and the rules it names — and an open stretch named no next is the end")
    func theReports() async throws {
        let ask = "\(Self.path)?resolved=false"
        let (reader, server) = try reader([ask: .json(Captures.reports, link: Captures.reportsLink)])
        let stretch = try await reader.stretch(resolved: false)
        #expect(stretch.reports.map(\.id) == ["2", "1"] && stretch.next == nil)
        let two = stretch.reports[0], one = stretch.reports[1]
        #expect(!one.closed && one.category == "violation" && one.words == "fediqo381seed one" && one.rules == ["fediqo381seed rule"])
        #expect(one.reporter?.handle == "@fediqo_other@mastodon.localhost" && one.target?.handle == "@fediqo_person@mastodon.localhost")
        #expect(one.posts.map(\.statusID) == ["117481809566645299"] && one.posts.allSatisfy { $0.source == Self.source && $0.categories.isEmpty })
        #expect(two.category == "spam" && two.target?.handle == "@far@elsewhere.example" && two.rules.isEmpty && two.takenBy == nil)
        #expect(two.at != nil)
        let (asked, bearers) = (await server.asked, await server.bearers)
        #expect(asked == [ask] && bearers == ["Bearer tok-381"])
    }

    @Test("Read on by the server's own next, a stretch at a time, until it names none")
    func readOn() async throws {
        let first = try #require(try MastodonLink.next(in: Captures.firstOneLink))
        let (reader, _) = try reader([
            "\(Self.path)?resolved=false": .json(Captures.firstOne, link: Captures.firstOneLink),
            "\(Self.path)?resolved=false&max_id=\(first)": .json(Captures.secondOne, link: Captures.secondOneLink),
        ])
        let one = try await reader.stretch(resolved: false)
        #expect(one.reports.map(\.id) == ["2"] && one.next == "2")
        let two = try await reader.stretch(resolved: false, after: first)
        #expect(two.reports.map(\.id) == ["1"])
        let (looping, _) = try self.reader(["\(Self.path)?resolved=false&max_id=2": .json("[]", link: Captures.firstOneLink)])
        await #expect(throws: PagingError.notPaging) { try await looping.stretch(resolved: false, after: "2") }
    }

    @Test("Each act is the server's own address for it, sent once, and answered with the report as it now stands: taken on by the reader, handed back, closed, opened again")
    func theActs() async throws {
        let answers: [(MastodonAdminReports.Act, String)] = [
            (.take, Captures.assigntoself), (.handBack, Captures.unassign), (.close, Captures.resolve), (.reopen, Captures.reopen),
        ]
        for (act, body) in answers {
            let ask = "\(Self.path)/1/\(act.rawValue)"
            let (reader, server) = try reader([ask: .json(body)])
            let report = try await reader.act(act, on: "1")
            #expect(await server.asked == [ask], "\(act)")
            switch act {
            case .take: #expect(report.takenBy == "@fediqo_admin@mastodon.localhost" && !report.closed)
            case .handBack: #expect(report.takenBy == nil && !report.closed)
            case .close: #expect(report.closed)
            case .reopen: #expect(!report.closed)
            }
        }
    }

    @Test("Without the standing the server refuses each read and act with 403, which is said as not allowed; an id that cannot stand in a path is asked nothing; an answer about another report, or no report, is unreadable; and the report's own page is on the server")
    func refusals() async throws {
        let (reader, _) = try reader([
            "\(Self.path)?resolved=false": .json(Captures.notAllowed, status: 403),
            "\(Self.path)/1/resolve": .json(Captures.notAllowed, status: 403),
            "\(Self.path)/2": .json(Captures.one),
            "\(Self.path)/3": .json("{}"),
        ])
        await #expect(throws: MastodonAdminError.notAllowed) { try await reader.stretch(resolved: false) }
        await #expect(throws: MastodonAdminError.notAllowed) { try await reader.act(.close, on: "1") }
        await #expect(throws: MastodonAdminError.unreadable) { try await reader.report("2") }
        await #expect(throws: MastodonAdminError.unreadable) { try await reader.report("3") }
        await #expect(throws: MastodonAdminError.invalid) { try await reader.act(.close, on: "../1") }
        #expect(MastodonAdminReports.page(of: "1", host: Captures.host)?.absoluteString == "https://mastodon.localhost/admin/reports/1")
        #expect(MastodonAdminReports.page(of: "a/b", host: Captures.host) == nil)
    }

    @Test("A notice of a new report, gathered or one at a time, is read with the report it is about; one whose report id cannot stand in a path names none")
    func aNoticeReadsItsReport() async throws {
        let account = #"{"id":"5","acct":"fediqo_other","username":"fediqo_other","display_name":"Other"}"#
        let report = #"{"id":"1","action_taken":false,"category":"spam","comment":"","statuses":[],"rules":[]}"#
        let gathered = #"""
        {"accounts":[\#(account)],"statuses":[],"notification_groups":[{"group_key":"ungrouped-11","type":"admin.report","notifications_count":1,
          "most_recent_notification_id":"11","page_min_id":"11","latest_page_notification_at":"2026-10-22T03:00:00.000Z",
          "sample_account_ids":["5"],"report":\#(report)},
         {"group_key":"ungrouped-10","type":"admin.report","notifications_count":1,"most_recent_notification_id":"10",
          "latest_page_notification_at":"2026-10-22T02:00:00.000Z","sample_account_ids":["5"],"report":{"id":"../1"}}]}
        """#
        let single = #"[{"id":"12","type":"admin.report","created_at":"2026-10-22T03:00:00.000Z","account":\#(account),"report":\#(report)}]"#
        let server = PeopleServer(["/api/v2/notifications": .json(gathered), "/api/v1/notifications": .json(single)])
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        let notices = MastodonNotices(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens))
        let read = try await notices.page(source: Self.source, gathered: true)
        #expect(read.notices.map(\.report) == ["1", nil] && read.notices.allSatisfy { $0.kind == .server("admin.report") })
        #expect(try await notices.page(source: Self.source, gathered: false).notices.map(\.report) == ["1"])
    }

    @Test("A notice of a new report names the report it is about, by the id its server gives it, and a line folded keeps it")
    func aNoticeNamesItsReport() {
        let at = Date(timeIntervalSince1970: 1)
        let notice = Notice(
            source: Self.source, handle: .one(id: "9"), kind: Notice.Kind(type: "admin.report"), people: [], at: at,
            newestID: "9", oldestID: "9", report: "1"
        )
        #expect(notice.report == "1" && notice.carrying(nil).report == "1")
        let older = Notice(source: Self.source, handle: .one(id: "9"), kind: .server("admin.report"), people: [], at: at, newestID: "8", oldestID: "8")
        #expect(older.folding(notice).report == "1")
    }
}
