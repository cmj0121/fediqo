import Foundation
import Testing
@testable import FediqoCore

/// #321, the reading: a host's longer account of itself, the servers it knows and how busy it
/// has been, read out of what a real server sent (`MastodonHostMoreCaptures`) — bounded and
/// cleaned where it enters, read leniently, and absent only where the host's own address says so.
@Suite("What a Mastodon says of itself beyond its document")
struct MastodonHostMoreTests {
    private static let host = "m.example"
    private typealias Paths = MastodonHostMore

    private static func reader(_ routes: [String: FixtureHTTP.Outcome]) -> (MastodonHostMore, FixtureHTTP) {
        let http = FixtureHTTP(routes)
        return (MastodonHostMore(http: http, host: host), http)
    }

    private static func account(_ body: String, status: Int = 200) async throws -> HostAccount {
        try await reader([Paths.accountPath: .text(body, status: status)]).0.longerAccount()
    }

    private static func servers(_ body: String, status: Int = 200) async throws -> HostServers {
        try await reader([Paths.serversPath: .text(body, status: status)]).0.knownServers()
    }

    private static func weeks(_ body: String, status: Int = 200) async throws -> [HostWeek] {
        try await reader([Paths.activityPath: .text(body, status: status)]).0.activity()
    }

    @Test("What a real server sent is read: a longer account never written is one with no paragraphs, one written is its words out of their markup, the servers it knows are their names and how many, and its twelve weeks are read newest first with each figure a count — each asked at its own address, of that host and no other")
    func whatARealServerSent() async throws {
        let (reader, http) = Self.reader([
            Paths.accountPath: .text(MastodonHostMoreCaptures.unwritten), Paths.serversPath: .text(MastodonHostMoreCaptures.servers),
            Paths.activityPath: .text(MastodonHostMoreCaptures.activity),
        ])
        #expect(try await reader.longerAccount() == HostAccount(paragraphs: []))
        #expect(try await reader.knownServers() == HostServers(counted: 1, names: ["elsewhere.example"]))
        let weeks = try await reader.activity()
        #expect(weeks.count == 12 && weeks == weeks.sorted { $0.week > $1.week })
        #expect(weeks.first == HostWeek(week: Date(timeIntervalSince1970: 1_791_661_624), posts: 74, signIns: 24, newPeople: 24))
        #expect(weeks.dropFirst().allSatisfy { $0.posts == 0 && $0.signIns == 0 && $0.newPeople == 0 })
        let asked = await http.requested
        #expect(asked.map(\.path) == [
            "/api/v1/instance/extended_description", "/api/v1/instance/peers", "/api/v1/instance/activity",
        ])
        #expect(asked.allSatisfy { $0.host() == Self.host && $0.scheme == "https" && $0.query == nil })

        let written = try await Self.account(MastodonHostMoreCaptures.written)
        #expect(written.paragraphs == MastodonHostMoreCaptures.writtenWords && !written.cut && written.updated != nil)
        #expect(written.paragraphs.allSatisfy { !$0.contains("<") && !$0.contains("&amp;") })
    }

    @Test("A thing is absent only where the host says its address is not there: switched off, kept from strangers, or a page of its own — and a record that is not there, a refusal and a failure are each a failure of that ask, never an absence")
    func absentByItsOwnAddress() async throws {
        for body in [MastodonHostMoreCaptures.switchedOff, MastodonHostCaptures.noMeansForIt, MastodonHostCaptures.noSuchAddress] {
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await Self.servers(body, status: 404) }
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await Self.weeks(body, status: 404) }
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await Self.account(body, status: 404) }
        }
        await #expect(throws: MastodonRequestError.http(404)) { try await Self.servers(MastodonHostCaptures.noSuchRecord, status: 404) }
        await #expect(throws: MastodonRequestError.http(404)) { try await Self.account(#"{"error":"Can't find it"}"#, status: 404) }
        for status in [401, 403, 422, 429, 500, 503] {
            await #expect(throws: MastodonRequestError.http(status)) { try await Self.weeks("", status: status) }
            await #expect(throws: MastodonRequestError.http(status)) { try await Self.servers(#"{"error":"Not Found"}"#, status: status) }
        }
        // An answer that is 200 and says "Not Found" in its body is an answer, and is read as one.
        await #expect(throws: MastodonHostMoreError.unreadable) { try await Self.servers(#"{"error":"Not Found"}"#) }
        // Nothing answering is a failure too, and the walked-away ask is its own.
        await #expect(throws: FixtureHTTPError.unreachable) { try await Self.reader([Paths.serversPath: .fail]).0.knownServers() }
        await #expect(throws: URLError.self) { try await Self.reader([Paths.activityPath: .cancelled]).0.activity() }
    }

    @Test("A longer account is a stranger's words: read leniently — no words, or words of another shape, is none written — cut to length before its markup is taken out and never through a tag, each line cleaned of what turns a line round, and no longer or of more paragraphs than is kept, said as cut where it is")
    func theAccountIsBounded() async throws {
        for none in [#"{}"#, #"{"content":null}"#, #"{"content":7,"updated_at":"never"}"#, #"{"content":"   "}"#, #"{"content":"<p></p><p> </p>"}"#] {
            #expect(try await Self.account(none) == HostAccount(paragraphs: []), "\(none)")
        }
        for unreadable in ["", "[]", "null", "\"words\"", "<html>"] {
            await #expect(throws: MastodonHostMoreError.unreadable) { try await Self.account(unreadable) }
        }
        let said = try await Self.account(#"""
        {"updated_at":"2026-10-01T08:00:00.000Z","content":"<h1>About</h1><p>Run by <a href=\"https://evil.example/x\">friends</a> &amp; neighbours.<br>Since 2017.</p><p>Left‮right​ and\ttabs</p>"}
        """#)
        #expect(said.paragraphs == ["About", "Run by friends & neighbours.", "Since 2017.", "Leftright and tabs"] && !said.cut)
        #expect(said.updated == MastodonJSON.date(from: "2026-10-01T08:00:00.000Z"))

        // Longer than is kept: the beginning, said as that.
        let long = String(repeating: "<p>" + String(repeating: "word ", count: 400) + "</p>", count: 40)
        let cut = try await Self.account(#"{"content":"\#(long)"}"#)
        #expect(cut.cut && cut.paragraphs.map(\.count).reduce(0, +) <= HostAccount.length + 1 && cut.paragraphs.count < 40)
        // More paragraphs than are kept.
        let many = try await Self.account(#"{"content":"\#(String(repeating: "<p>a</p>", count: 500))"}"#)
        #expect(many.cut && many.paragraphs.count == HostAccount.paragraphCount && HostAccount.paragraphCount == 200)
        // Cut before the markup is taken out, and not through a tag: no half of one stands as words.
        let tags = String(repeating: "<a href=\\\"https://m.example/a\\\">x</a>", count: 4_000)
        let linked = try await Self.account(#"{"content":"<p>\#(tags)</p>"}"#)
        #expect(linked.cut && linked.paragraphs.count == 1 && linked.paragraphs[0].allSatisfy { $0 == "x" })
        #expect(HostAccount(markup: String(repeating: "é", count: 60_000)).paragraphs[0].count == HostAccount.length + 1)
    }

    @Test("The servers a host knows are names and nothing else: each held to the letters a host's name is made of and folded to lower case; an entry that is no name costs that entry and is still counted as one the host named; only so many names are kept, and the count is the host's own")
    func theServersAreNames() async throws {
        let said = try await Self.servers(#"""
        ["Elsewhere.Example","xn--bcher-kva.example","a.example:8443","https://b.example/","c.example/path","d example",
         ".e.example","-f.example","bücher.example","g.example‮","",7,null,{"host":"h.example"},"ok.example","192.0.2.7"]
        """#)
        #expect(said.names == ["elsewhere.example", "xn--bcher-kva.example", "ok.example", "192.0.2.7"])
        #expect(said.counted == 16, "what the host named, the entries that are no name among them")
        #expect(HostServers.name(String(repeating: "a", count: 253)) != nil && HostServers.name(String(repeating: "a", count: 254)) == nil)

        let many = "[" + (0..<5_000).map { #""h\#($0).example""# }.joined(separator: ",") + "]"
        let kept = try await Self.servers(many)
        #expect(kept.counted == 5_000 && kept.names.count == HostServers.kept && HostServers.kept == 2_000)
        #expect(kept.names.first == "h0.example" && kept.names.last == "h1999.example")
        #expect(try await Self.servers("[]") == HostServers(counted: 0, names: []))
        #expect(HostServers(counted: -3, names: []).counted == 0)
        for unreadable in ["", "{}", "null", #"{"error":"no"}"#, "\"a.example\""] {
            await #expect(throws: MastodonHostMoreError.unreadable) { try await Self.servers(unreadable) }
        }
    }

    @Test("A week's figures are the host's counts, read leniently: a number or a number written out; one that is less than none, past belief or not a number is not said and costs nothing else; a week named by no moment, or by one outside this century, is that week not listed; newest first, and no more weeks than are kept")
    func theWeeksAreCounts() async throws {
        let said = try await Self.weeks(#"""
        [{"week":"1700000000","statuses":"12","logins":7,"registrations":"-1"},
         {"week":1700604800,"statuses":"99999999999999999999","logins":"1e3","registrations":" 4"},
         {"week":"soon","statuses":"1","logins":"1","registrations":"1"},
         {"statuses":"1"}, "week", null, 7,
         {"week":"12","statuses":"1"}, {"week":"1701209600","statuses":null,"logins":"0012"}]
        """#)
        #expect(said == [
            HostWeek(week: Date(timeIntervalSince1970: 1_701_209_600), posts: nil, signIns: 12, newPeople: nil),
            HostWeek(week: Date(timeIntervalSince1970: 1_700_604_800), posts: nil, signIns: nil, newPeople: nil),
            HostWeek(week: Date(timeIntervalSince1970: 1_700_000_000), posts: 12, signIns: 7, newPeople: nil),
        ])
        let many = "[" + (0..<400).map { #"{"week":"\#(1_700_000_000 + $0 * 604_800)","statuses":"\#($0)"}"# }.joined(separator: ",") + "]"
        let kept = try await Self.weeks(many)
        #expect(kept.count == HostWeek.kept && HostWeek.kept == 53)
        #expect(try await Self.weeks("[]").isEmpty)
        for unreadable in ["", "{}", "null", #"{"error":"no"}"#] {
            await #expect(throws: MastodonHostMoreError.unreadable) { try await Self.weeks(unreadable) }
        }
        #expect(MastodonFigure.read("0") == 0 && MastodonFigure.read("1000000000000") == MastodonFigure.most)
        for bad in ["", "-1", "+1", "1.5", "1,204", " 1", "1000000000001", "9999999999999999", "١٢", "0x10"] {
            #expect(MastodonFigure.read(bad) == nil, "\(bad)")
        }
    }

    @Test("A client kept to its origin refuses every redirect off it, token or none, and is otherwise the client it was: the same ceiling, the same gate")
    func keptToItsOrigin() {
        let small = URLSessionClient(watchedOnly: false).capped(to: 1 << 20).stayingOnOrigin()
        #expect(small.sameOriginOnly && small.byteLimit == 1 << 20 && !small.watchedOnly)
        #expect(!URLSessionClient().capped(to: 1 << 20).sameOriginOnly)
        let asked = URLRequest(url: URL(string: "https://m.example/api/v1/instance/peers")!)
        #expect(!CappedBody.mayFollow(from: asked, to: URL(string: "https://other.example/peers")!, sameOriginOnly: true))
        #expect(CappedBody.mayFollow(from: asked, to: URL(string: "https://m.example/elsewhere")!, sameOriginOnly: true))
    }
}
