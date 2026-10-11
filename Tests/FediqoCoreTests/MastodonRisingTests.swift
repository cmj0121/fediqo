import Foundation
import Testing
@testable import FediqoCore

/// #320, the reading: the hashtags and the links rising on a Mastodon, read out of what a real
/// server sent (`MastodonRisingCaptures`) — each bounded and cleaned where it enters, read
/// entry by entry, and an empty answer never taken for the host having no such thing.
@Suite("The hashtags and links rising on a Mastodon")
struct MastodonRisingTests {
    private static let host = "m.example"

    private static func reader(_ routes: [String: FixtureHTTP.Outcome]) -> (MastodonRising, FixtureHTTP) {
        let http = FixtureHTTP(routes)
        return (MastodonRising(http: http, host: host), http)
    }

    private static func tags(_ body: String, status: Int = 200) async throws -> [RisingTag] {
        try await reader([MastodonRising.tagsPath: .text(body, status: status)]).0.tags()
    }

    private static func links(_ body: String, status: Int = 200) async throws -> [RisingLink] {
        try await reader([MastodonRising.linksPath: .text(body, status: status)]).0.links()
    }

    @Test("What a real server sent is read: a hashtag as it was written, with the posts and the people of its two newest days added; a link by its address, the host it leads to and what the server says of it as plain words — signed in or not — each asked once, for twenty, at its own address of that host and no other")
    func whatARealServerSent() async throws {
        let (reader, http) = Self.reader([
            MastodonRising.tagsPath: .text(MastodonRisingCaptures.tags), MastodonRising.linksPath: .text(MastodonRisingCaptures.links),
        ])
        let tag = try #require(PostTag("#FediqoRising"))
        #expect(try await reader.tags() == [RisingTag(tag: tag, use: RisingUse(posts: 15, people: 15, days: 2))])
        let link = try #require(PostLink("https://elsewhere.example/stories/rising"))
        let links = try await reader.links()
        #expect(links == [RisingLink(
            link: link, title: "A story <b>rising</b> & more", words: "What the page says of itself.",
            use: RisingUse(posts: 20, people: 20, days: 2)
        )])
        #expect(links.first?.link.host == "elsewhere.example")
        let asked = await http.requested
        #expect(asked.map(\.path) == ["/api/v1/trends/tags", "/api/v1/trends/links"] && MastodonRising.stretch == 20)
        #expect(asked.allSatisfy { $0.host() == Self.host && $0.scheme == "https" && $0.query == "limit=20" })

        // Signed in the server says more of each, and what is read is the same.
        #expect(try await Self.tags(MastodonRisingCaptures.tagsSignedIn) == (try await Self.tags(MastodonRisingCaptures.tags)))
        #expect(try await Self.links(MastodonRisingCaptures.linksSignedIn) == links)
    }

    @Test("An empty answer is the source giving none, and never an absence: a new server and one with what is rising switched off answer alike. A thing is absent only where the host says its address is not there; any other refusal, and an answer that is no list, is a failure")
    func emptyIsNotAbsent() async throws {
        #expect(try await Self.tags(MastodonRisingCaptures.none).isEmpty)
        #expect(try await Self.links(MastodonRisingCaptures.none).isEmpty)
        for body in ["", MastodonHostCaptures.noMeansForIt, MastodonHostCaptures.noSuchAddress] {
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await Self.tags(body, status: 404) }
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await Self.links(body, status: 404) }
        }
        await #expect(throws: MastodonRequestError.http(404)) { try await Self.tags(MastodonHostCaptures.noSuchRecord, status: 404) }
        for status in [401, 403, 422, 429, 500] {
            await #expect(throws: MastodonRequestError.http(status)) { try await Self.links("[]", status: status) }
        }
        for unreadable in ["", "{}", "null", #"{"error":"no"}"#, "<html>"] {
            await #expect(throws: MastodonHostMoreError.unreadable) { try await Self.tags(unreadable) }
            await #expect(throws: MastodonHostMoreError.unreadable) { try await Self.links(unreadable) }
        }
        await #expect(throws: FixtureHTTPError.unreachable) { try await Self.reader([MastodonRising.tagsPath: .fail]).0.tags() }
    }

    @Test("A hashtag is listed where its name is one a post's words could carry, once however it is written, and no more than a stretch of them: a name with a space, a mark or nothing in it, one too long, and an entry of another shape each cost that entry and no other")
    func hashtagsEntryByEntry() async throws {
        let said = try await Self.tags(#"""
        [{"name":"Swift"},{"name":"swift","history":[]},{"name":"two words"},{"name":""},{"name":"#hash"},{"name":"a/b"},
         {"name":7},{"history":[]},"swift",null,{"name":"書","history":"none"},{"name":"\#(String(repeating: "a", count: 101))"},
         {"name":"ok_1","url":"javascript:alert(1)","history":[{"day":"1700000000","accounts":"2","uses":"5"}]}]
        """#)
        #expect(said.map(\.tag.text) == ["#Swift", "#書", "#ok_1"])
        #expect(said[0].use == .unsaid && said[1].use == .unsaid && said[2].use == RisingUse(posts: 5, people: 2, days: 1))
        // Once, by the folding a row is told apart by: another width is the same hashtag.
        let widths = try await Self.tags(#"[{"name":"ＡＢＣ"},{"name":"abc"},{"name":"Abc"}]"#)
        #expect(widths.map(\.tag.text) == ["#ＡＢＣ"] && MastodonRising.folded(widths[0].tag) == "abc")
        let many = "[" + (0..<200).map { #"{"name":"t\#($0)"}"# }.joined(separator: ",") + "]"
        #expect(try await Self.tags(many).count == MastodonRising.stretch)
    }

    @Test("A link is listed where its address is one this device would follow from a post's words — https, a host, nobody's credentials — once, and no more than a stretch of them; what the source says of it is words made fit for a line and bounded, never markup taken apart, and nothing it says of a picture or of the site's name is kept")
    func linksEntryByEntry() async throws {
        let long = String(repeating: "word ", count: 400)
        let said = try await Self.links(#"""
        [{"url":"https://a.example/one","title":"One‮\ntwo","description":"\#(long)","image":"https://tracker.example/p.png","provider_name":"apple.com"},
         {"url":"https://a.example/one","title":"again"},
         {"url":"http://plain.example/x","title":"plain"},{"url":"javascript:alert(1)"},{"url":"https://user:pw@b.example/"},
         {"url":"https://"},{"url":"file:///etc/passwd"},{"url":7},{"title":"no address"},"https://c.example/",null,
         {"url":"https://\#(String(repeating: "a", count: 2100)).example/"},
         {"url":"https://bücher.example/buch","title":7,"description":null,"history":[{"day":"1700086400","accounts":"3","uses":"4"},{"day":"1700000000","accounts":"x","uses":"6"},{"day":"1699913600","accounts":"100","uses":"100"}]}]
        """#)
        #expect(said.map(\.link.url.absoluteString) == ["https://a.example/one", "https://xn--bcher-kva.example/buch"])
        #expect(said[0].title == "One two" && said[0].words.count == RisingLink.wordsLength + 1 && said[0].words.hasSuffix("…"))
        #expect(said[1].title.isEmpty && said[1].words.isEmpty && said[1].link.host == "xn--bcher-kva.example", "the host told in ASCII")
        #expect(said[1].use == RisingUse(posts: 10, people: 3, days: 2), "the two newest days, and a figure that is no count left out")
        #expect(said[1].link.text == "https://xn--bcher-kva.example/buch", "and the address is spelled as the wire spells it")
        #expect(MastodonRising.link("https://аpple.com/x")?.host == "xn--pple-43d.com", "a letter that only looks like one is not shown as it")
        #expect(MastodonRising.link("https://a.example/ü")?.text.utf8.allSatisfy { $0 < 128 } ?? true)
        #expect(RisingLink(link: said[0].link, title: String(repeating: "t", count: 500)).title.count == RisingLink.titleLength + 1)
        let many = "[" + (0..<200).map { #"{"url":"https://a.example/\#($0)"}"# }.joined(separator: ",") + "]"
        #expect(try await Self.links(many).count == MastodonRising.stretch)
        // Nothing of a link names a picture: there is no place to keep one.
        #expect(Mirror(reflecting: said[0]).children.compactMap(\.label).sorted() == ["link", "title", "use", "words"])
    }

    @Test("How much something was used is the source's counts over its two newest days: read leniently, added, never less than none or past belief; a day named by no moment is not a day; no day is no figure; and a sum of nothing is not said")
    func theFiguresAreCounts() throws {
        func use(_ history: String) throws -> RisingUse {
            let days = try MastodonJSON.decoder.decode([StatusDTO.Lenient<MastodonRising.Day>].self, from: Data(history.utf8))
            return MastodonRising.Day.use(days)
        }
        #expect(try use("[]") == .unsaid && !RisingUse.unsaid.isSaid && MastodonRising.Day.use(nil) == .unsaid)
        #expect(try use(#"[{"day":"3","accounts":"1","uses":"2"},{"day":"5","accounts":3,"uses":"4"},{"day":"4","accounts":"10","uses":"20"}]"#)
            == RisingUse(posts: 24, people: 13, days: 2), "the newest two, in whatever order they came")
        #expect(try use(#"[{"day":"5","accounts":"-1","uses":"1e9"},{"accounts":"7","uses":"7"},"day",null]"#) == RisingUse(posts: nil, people: nil, days: 1))
        #expect(try !use(#"[{"day":"5","accounts":"-1","uses":"x"}]"#).isSaid)
        #expect(try use(#"[{"day":"5","uses":"1000000000000"},{"day":"4","uses":"1000000000000"}]"#).posts == MastodonFigure.most)
        #expect(try use(#"[{"day":"5","accounts":"0","uses":"0"}]"#) == RisingUse(posts: 0, people: 0, days: 1))
        #expect(RisingUse(posts: 1, people: 1, days: 9).days == RisingUse.span && RisingUse(posts: 1, people: 1, days: -2).days == 0)
        #expect(RisingUse(posts: 1, people: nil, days: 1).isSaid && !RisingUse(posts: 1, people: 1, days: 0).isSaid)
    }
}
