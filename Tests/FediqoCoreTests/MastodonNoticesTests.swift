import Foundation
import Testing
@testable import FediqoCore

/// A server that answers by path and query, and remembers what it was asked and as whom.
private actor NoticeServer: HTTPSender {
    enum Answer: Sendable {
        case json(String, status: Int = 200)
        case fail
    }

    private let routes: [String: Answer]
    private(set) var asked: [String] = []
    private(set) var bearers: Set<String> = []

    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let ask = url.path + (url.query.map { "?\($0)" } ?? "")
        asked.append(ask)
        bearers.insert("\(url.host ?? "") \(request.value(forHTTPHeaderField: "Authorization") ?? "")")
        switch routes[ask] {
        case .json(let body, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        case .fail:
            throw URLError(.notConnectedToInternet)
        case nil:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// #323, in the half of it Core holds: a notice, and reading them from a Mastodon — the gathered
/// read and the single one landing in one shape, every kind, reading on to older ones, and a
/// refusal or a failure that is an error and nothing else. Read from what a real 4.6.6 answered
/// (`MastodonNoticeCaptures`).
@Suite("What a source says happened to the person")
struct MastodonNoticesTests {
    private typealias Captures = MastodonNoticeCaptures

    private static let gathered = MastodonNotices.gatheredPath
    private static let single = MastodonNotices.singlePath
    private static let source = Source(host: Captures.host, kind: .mastodon)
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )

    private static let reader = "@fediqo@mastodon.localhost"
    private static let other = "@fediqo_other@mastodon.localhost"
    private static let third = "@fediqo_third@mastodon.localhost"
    /// The reader's first post, which was boosted, favoured and answered.
    private static let first = "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685"
    private static let boosts = "reblog-117402373970258685-497616"
    private static let favourites = "favourite-117402373970258685-497616"

    private static func moment(_ raw: String) -> Date { MastodonJSON.date(from: raw)! }

    private func reading(
        _ routes: [String: NoticeServer.Answer]
    ) throws -> (MastodonNotices, NoticeServer, MemoryMastodonTokens) {
        let server = NoticeServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        let door = MastodonAuthorized(token: Self.token, sender: server, store: tokens)
        return (MastodonNotices(door: door), server, tokens)
    }

    /// What two reads of one notice must agree on: everything but how it is named at the source.
    private struct Said: Equatable {
        let kind: Notice.Kind
        let people: [NoticePerson]
        let count: Int
        let post: Note?
        let at: Date
        let newestID: String
        let oldestID: String

        init(_ notice: Notice) {
            kind = notice.kind
            people = notice.people
            count = notice.count
            post = notice.post
            at = notice.at
            newestID = notice.newestID
            oldestID = notice.oldestID
        }
    }

    // MARK: - The two reads, one shape

    @Test("The gathered read lands a line for each thing that happened: its kind, who, how many, about which post and when — the people and the post found beside the lines by id")
    func gatheredRead() async throws {
        let (notices, server, _) = try reading([Self.gathered: .json(Captures.gathered)])
        let page = try await notices.page(source: Self.source)
        #expect(page.gathered)
        #expect(await server.asked == [Self.gathered], "one request, and no length asked for")
        #expect(await server.bearers == ["mastodon.localhost Bearer tok-123"])
        let lines = page.notices
        #expect(lines.map(\.kind) == [.update, .mention, .mention, .poll, .reblog, .favourite, .follow, .followRequest])
        #expect(lines.map(\.handle) == [
            .gathered(key: "ungrouped-11"), .gathered(key: "ungrouped-10"), .gathered(key: "ungrouped-9"),
            .gathered(key: "ungrouped-8"), .gathered(key: Self.boosts), .gathered(key: Self.favourites),
            .gathered(key: "follow-497616"), .gathered(key: "ungrouped-1"),
        ])
        #expect(lines.map(\.count) == [1, 1, 1, 1, 2, 2, 1, 1])
        #expect(lines.map { $0.people.map(\.handle) } == [
            [Self.other], [Self.third], [Self.other], [Self.reader],
            [Self.other, Self.third], [Self.other, Self.third], [Self.other], [Self.third],
        ], "newest first; a poll that ended names the reader themself")
        #expect(lines.map(\.newestID) == ["11", "10", "9", "8", "7", "6", "3", "1"], "a number on the wire, read as an id")
        #expect(lines.map(\.oldestID) == ["11", "10", "9", "8", "4", "5", "3", "1"])
        #expect(lines.allSatisfy { $0.source == Self.source })
        #expect(Set(lines.map(\.id)).count == 8)
        #expect(lines[4].id == "mastodon.localhost\u{1e}gathered\u{1e}\(Self.boosts)")
        #expect(lines[4].at == Self.moment("2026-10-08T00:08:15.934Z"), "a line has no moment of its own but its latest notice's")
        #expect(page.before == "1")

        let person = try #require(lines[0].people.first)
        #expect(person.name == "fediqo_other" && person.emojis.isEmpty)
        #expect(person.avatarURL == URL(string: "https://mastodon.localhost/avatars/original/missing.png"))

        #expect(lines.map { $0.post?.body } == [
            "fediqo298seed plain, now changed", "@fediqo a mention from a third person",
            "@fediqo an answer to the first note", "a poll", "A public note on this machine",
            "A public note on this machine", nil, nil,
        ])
        #expect(lines[4].post?.id == Self.first && lines[4].post?.handle == Self.reader, "what was boosted is the reader's own post")
        #expect(lines[0].post?.handle == Self.other && lines[0].post?.categories == [], "carried, through no timeline")
        #expect(lines[0].post?.asked.place != nil, "and says when its read was sent, as every post read does")
    }

    @Test("The single read lands the same things one by one: a line of one person and a count of one, named by its own id")
    func singleRead() async throws {
        let (notices, server, _) = try reading([Self.single: .json(Captures.single)])
        let page = try await notices.page(source: Self.source, gathered: false)
        #expect(!page.gathered)
        #expect(await server.asked == [Self.single], "the gathered read is not tried where it is known not to be there")
        let lines = page.notices
        #expect(lines.map(\.kind) == [
            .update, .mention, .mention, .poll, .reblog, .favourite, .favourite, .reblog, .follow, .followRequest,
        ])
        let ids = ["11", "10", "9", "8", "7", "6", "5", "4", "3", "1"]
        #expect(lines.map(\.handle) == ids.map { .one(id: $0) })
        #expect(lines.map(\.newestID) == ids && lines.map(\.oldestID) == ids)
        #expect(lines.allSatisfy { $0.count == 1 && $0.people.count == 1 })
        #expect(lines.map { $0.people[0].handle } == [
            Self.other, Self.third, Self.other, Self.reader, Self.other, Self.other, Self.third, Self.third,
            Self.other, Self.third,
        ])
        #expect(lines[5].id == "mastodon.localhost\u{1e}one\u{1e}6")
        #expect(lines[5].at == Self.moment("2026-10-08T00:08:15.896Z"))
        #expect(lines[5].post?.id == Self.first)
        #expect(lines[8].post == nil && lines[9].post == nil)
        #expect(page.before == "1")
    }

    @Test("Both reads say the same of a notice the source did not gather — kind, who, post, moment — and differ only in how it is named there")
    func oneShape() async throws {
        let (notices, _, _) = try reading([
            Self.gathered: .json(Captures.gathered), Self.single: .json(Captures.single),
        ])
        let lines = try await notices.page(source: Self.source, gathered: true).notices
        let ones = try await notices.page(source: Self.source, gathered: false).notices
        let alone = lines.filter { $0.count == 1 }
        #expect(alone.count == 6)
        for line in alone {
            let one = try #require(ones.first { $0.newestID == line.newestID })
            #expect(Said(one) == Said(line), "\(line.kind)")
            #expect(one.handle != line.handle && one.id != line.id)
        }
        // A gathered line is its notices folded: the same people, the count of them, the same post.
        for key in [Self.boosts, Self.favourites] {
            let line = try #require(lines.first { $0.handle == .gathered(key: key) })
            let its = ones.filter { $0.kind == line.kind }
            #expect(its.count == line.count)
            #expect(its.flatMap(\.people) == line.people && its.map(\.newestID) == [line.newestID, line.oldestID])
            #expect(its.allSatisfy { $0.post?.id == line.post?.id } && its.map(\.at).max() == line.at)
        }
    }

    @Test("Answered and mentioned are one kind, told apart by the post: an answer's post answers something")
    func answeredOrMentioned() async throws {
        let (notices, _, _) = try reading([
            Self.gathered: .json(Captures.gathered), Self.single: .json(Captures.single),
        ])
        for gathered in [true, false] {
            let lines = try await notices.page(source: Self.source, gathered: gathered).notices
            let mentions = lines.filter { $0.kind == .mention }
            #expect(mentions.map(\.answers) == [false, true], "gathered: \(gathered)")
            #expect(mentions[1].post?.reply?.inReplyToId == "117402373970258685")
            #expect(lines.filter { $0.kind != .mention }.allSatisfy { !$0.answers })
        }
    }

    @Test("A quote lands from both reads as a quote, about the post that quotes")
    func quote() async throws {
        let (notices, _, _) = try reading([
            Self.gathered: .json(Captures.quoteGathered), Self.single: .json(Captures.quoteSingle),
        ])
        let line = try #require(try await notices.page(source: Self.source, gathered: true).notices.first)
        let one = try #require(try await notices.page(source: Self.source, gathered: false).notices.first)
        #expect(Said(line) == Said(one))
        #expect(line.kind == .quote && line.people.map(\.handle) == [Self.other] && line.newestID == "14")
        #expect(line.handle == .gathered(key: "ungrouped-14") && one.handle == .one(id: "14"))
        #expect(line.post?.handle == Self.other && line.post?.quote?.state == .accepted)
        #expect(!line.answers)
    }

    // MARK: - Every kind, and one nobody knows

    @Test("Every word a source can send is a kind and gives its word back: the eight this app names, the server's own four, and anything else kept as unknown")
    func everyKind() {
        let named: [(String, Notice.Kind)] = [
            ("mention", .mention), ("reblog", .reblog), ("favourite", .favourite), ("follow", .follow),
            ("follow_request", .followRequest), ("quote", .quote), ("poll", .poll), ("update", .update),
        ]
        for (word, kind) in named {
            #expect(Notice.Kind(type: word) == kind && kind.type == word)
        }
        for word in ["severed_relationships", "moderation_warning", "admin.sign_up", "admin.report"] {
            #expect(Notice.Kind(type: word) == .server(word) && Notice.Kind(type: word).type == word)
        }
        for word in ["status", "quoted_update", "annual_report", "Mention", "pleroma:emoji_reaction", ""] {
            #expect(Notice.Kind(type: word) == .unknown(word) && Notice.Kind(type: word).type == word)
        }
    }

    /// Made by hand, since no 4.6.6 could be made to send a kind this build does not know: one
    /// such line, one the server speaks for itself, and entries that are not notices at all.
    private static let strangeGathered = """
    {"accounts":[{"id":"7","username":"ada","acct":"ada","display_name":"Ada"},{"id":8}],
     "statuses":[{"id":"30"}],
     "notification_groups":[
      {"group_key":"ungrouped-5","type":"emoji_reaction","most_recent_notification_id":5,"notifications_count":"3",
       "page_min_id":"5","latest_page_notification_at":"2026-10-08T00:00:05.000Z","sample_account_ids":["7","8","9"],"status_id":"30"},
      {"group_key":"ungrouped-4","type":"moderation_warning","most_recent_notification_id":"4",
       "latest_page_notification_at":"2026-10-08T00:00:04.000Z"},
      {"type":"favourite","most_recent_notification_id":3,"latest_page_notification_at":"2026-10-08T00:00:03.000Z"},
      {"group_key":"ungrouped-2","most_recent_notification_id":2,"latest_page_notification_at":"2026-10-08T00:00:02.000Z"},
      "a line that is no line",
      {"group_key":"follow-1","type":"follow","most_recent_notification_id":1,"page_min_id":"1",
       "latest_page_notification_at":"2026-10-08T00:00:01.000Z","sample_account_ids":["7"]}
     ]}
    """
    private static let strangeSingle = """
    [{"id":5,"type":"emoji_reaction","created_at":"2026-10-08T00:00:05.000Z",
      "account":{"id":"7","username":"ada","acct":"ada","display_name":"Ada"},"status":{"id":"30"}},
     {"id":"4","type":"moderation_warning","created_at":"2026-10-08T00:00:04.000Z","account":null},
     {"type":"favourite","created_at":"2026-10-08T00:00:03.000Z"},
     {"id":"2","created_at":"2026-10-08T00:00:02.000Z"},
     7,
     {"id":"1","type":"follow","created_at":"2026-10-08T00:00:01.000Z",
      "account":{"id":"7","username":"ada","acct":"ada@elsewhere.example","display_name":""}}]
    """

    @Test("A kind this build does not know is kept, with its people, under the word the source used; only an entry with no name or no kind is skipped, and never the page with it")
    func unknownKept() async throws {
        let (notices, _, _) = try reading([
            Self.gathered: .json(Self.strangeGathered), Self.single: .json(Self.strangeSingle),
        ])
        let ada = NoticePerson(handle: "@ada@mastodon.localhost", name: "Ada")
        let lines = try await notices.page(source: Self.source, gathered: true)
        #expect(lines.notices.map(\.kind) == [.unknown("emoji_reaction"), .server("moderation_warning"), .follow])
        #expect(lines.notices.map(\.people) == [[ada], [], [ada]], "somebody the side list does not hold is absent, not a failure")
        #expect(lines.notices.map(\.count) == [3, 1, 1], "a count sent as a string is a count")
        #expect(lines.notices.map(\.newestID) == ["5", "4", "1"] && lines.notices.map(\.oldestID) == ["5", "4", "1"])
        #expect(lines.notices.allSatisfy { $0.post == nil }, "a post that cannot be read is no post, and the line stands")
        #expect(lines.before == "1")

        let ones = try await notices.page(source: Self.source, gathered: false)
        #expect(ones.notices.map(\.kind) == [.unknown("emoji_reaction"), .server("moderation_warning"), .follow])
        #expect(ones.notices.map(\.handle) == [.one(id: "5"), .one(id: "4"), .one(id: "1")], "an id sent as a number is an id")
        #expect(ones.notices.map(\.people) == [[ada], [], [NoticePerson(handle: "@ada@elsewhere.example", name: "ada")]])
        #expect(ones.before == "1")
    }

    private static let post = #"{"id":"30","uri":"https://mastodon.localhost/p/30","created_at":"2026-10-01T00:00:00.000Z","content":"<p>old</p>","account":{"username":"ada","acct":"ada","display_name":"Ada"}}"#

    @Test("A notice that names no moment of its own stands at its post's rather than being left out; only one with no moment anywhere is skipped, and where the page reached is still known")
    func noMoment() async throws {
        let gathered = """
        {"accounts":[],"statuses":[\(Self.post)],"notification_groups":[
          {"group_key":"favourite-30-1","type":"favourite","most_recent_notification_id":9,"page_min_id":"8","status_id":"30"},
          {"group_key":"ungrouped-7","type":"update","most_recent_notification_id":7,"latest_page_notification_at":"yesterday","status_id":"30"},
          {"group_key":"follow-1","type":"follow","most_recent_notification_id":6,"latest_page_notification_at":null}]}
        """
        let single = """
        [{"id":"9","type":"favourite","status":\(Self.post)},
         {"id":"7","type":"update","created_at":"yesterday","status":\(Self.post)},
         {"id":"6","type":"follow"}]
        """
        let (notices, _, _) = try reading([Self.gathered: .json(gathered), Self.single: .json(single)])
        for read in [true, false] {
            let page = try await notices.page(source: Self.source, gathered: read)
            #expect(page.notices.map(\.kind) == [.favourite, .update], "gathered: \(read)")
            #expect(page.notices.allSatisfy { $0.at == Self.moment("2026-10-01T00:00:00.000Z") })
            #expect(page.before == "6", "the one skipped still says how far down the page went")
        }
    }

    @Test("A page with entries and none this build can read is not the end: it lands nothing and still says where to read on from; one that names no id anywhere is no page")
    func nothingReadable() async throws {
        let gathered = #"{"notification_groups":[{"most_recent_notification_id":12,"page_min_id":"11"},{"group_key":7,"most_recent_notification_id":"10"}]}"#
        let single = #"[{"id":12,"type":{}},{"id":"10"}]"#
        let (notices, _, _) = try reading([Self.gathered: .json(gathered), Self.single: .json(single)])
        for read in [true, false] {
            let page = try await notices.page(source: Self.source, gathered: read)
            #expect(page.notices.isEmpty && page.gathered == read)
            #expect(page.before == "10", "gathered: \(read)")
        }
        let (nameless, _, _) = try reading([
            Self.gathered: .json(#"{"notification_groups":[{"type":"follow"},7]}"#),
            Self.single: .json(#"[{"type":"follow"},7]"#),
        ])
        for read in [true, false] {
            await #expect(throws: MastodonNoticeError.unreadable) {
                _ = try await nameless.page(source: Self.source, gathered: read)
            }
        }
    }

    @Test("An id or a count that is not one costs the line that one thing and never the line: an empty post id, an empty page id, one bad person among the sample, a count in words")
    func oneBadField() async throws {
        let body = """
        {"accounts":[{"id":"7","username":"ada","acct":"ada","display_name":"Ada"}],"statuses":[\(Self.post)],
         "notification_groups":[
          {"group_key":"favourite-30-1","type":"favourite","most_recent_notification_id":9,"notifications_count":"many",
           "page_min_id":"","latest_page_notification_at":"2026-10-08T00:00:09.000Z",
           "sample_account_ids":["", {"id":"7"}, "7", null],"status_id":""},
          {"group_key":"favourite-30-2","type":"favourite","most_recent_notification_id":8,"notifications_count":2,
           "page_min_id":"6","latest_page_notification_at":"2026-10-08T00:00:08.000Z",
           "sample_account_ids":"7","status_id":30}]}
        """
        let (notices, _, _) = try reading([Self.gathered: .json(body)])
        let page = try await notices.page(source: Self.source)
        let ada = NoticePerson(handle: "@ada@mastodon.localhost", name: "Ada")
        #expect(page.notices.map(\.handle) == [.gathered(key: "favourite-30-1"), .gathered(key: "favourite-30-2")])
        #expect(page.notices.map(\.people) == [[ada], []])
        #expect(page.notices.map(\.count) == [1, 2])
        #expect(page.notices.map(\.oldestID) == ["9", "6"] && page.before == "6")
        #expect(page.notices.map { $0.post?.body } == [nil, "old"])
    }

    // MARK: - Reading on

    /// A stretch nobody asked the server for while it was up — the captures stop a page short
    /// of the end — **cut out of its own answer to the unpaged read**: these notices, as it
    /// wrote them there, and nothing typed by hand.
    private static func stretch(single ids: [String]) throws -> String {
        let all = try JSONSerialization.jsonObject(with: Data(Captures.single.utf8)) as? [[String: Any]] ?? []
        let cut = all.filter { ids.contains($0["id"] as? String ?? "") }
        try #require(cut.count == ids.count)
        return String(decoding: try JSONSerialization.data(withJSONObject: cut), as: UTF8.self)
    }

    /// The same for the gathered read: these lines, and the people and posts they name.
    private static func stretch(gathered keys: [String]) throws -> String {
        let all = try JSONSerialization.jsonObject(with: Data(Captures.gathered.utf8)) as? [String: Any] ?? [:]
        func list(_ name: String) -> [[String: Any]] { all[name] as? [[String: Any]] ?? [] }
        let lines = list("notification_groups").filter { keys.contains($0["group_key"] as? String ?? "") }
        try #require(lines.count == keys.count)
        let people = Set(lines.flatMap { $0["sample_account_ids"] as? [String] ?? [] })
        let posts = Set(lines.compactMap { $0["status_id"] as? String })
        let cut: [String: Any] = [
            "accounts": list("accounts").filter { people.contains($0["id"] as? String ?? "") },
            "statuses": list("statuses").filter { posts.contains($0["id"] as? String ?? "") },
            "notification_groups": lines,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: cut), as: UTF8.self)
    }

    @Test("Reading on asks each older stretch before the lowest id the last one named, and a gathered line the source cut at a page edge is folded into the line already held: the pages read on are the lines one read brings")
    func readingOnGathered() async throws {
        let (notices, server, _) = try reading([
            Self.gathered: .json(Captures.gatheredNewest),
            Self.gathered + "?max_id=9": .json(Captures.gatheredOlder),
            Self.gathered + "?max_id=6": .json(Captures.gatheredOldest),
            Self.gathered + "?max_id=3": .json(try Self.stretch(gathered: ["ungrouped-1"])),
            Self.gathered + "?max_id=1": .json(Captures.gatheredPastTheEnd),
        ])
        let newest = try await notices.page(source: Self.source)
        #expect(newest.notices.map(\.newestID) == ["11", "10", "9"] && newest.before == "9")
        let older = try await notices.page(source: Self.source, before: newest.before, gathered: newest.gathered)
        #expect(older.notices.map(\.newestID) == ["8", "7", "6"] && older.before == "6")
        #expect(older.notices.map(\.count) == [1, 2, 2] && older.notices.map(\.oldestID) == ["8", "7", "6"])
        let oldest = try await notices.page(source: Self.source, before: older.before, gathered: older.gathered)
        #expect(oldest.notices.map(\.handle) == [
            .gathered(key: Self.favourites), .gathered(key: Self.boosts), .gathered(key: "follow-497616"),
        ], "the same two keys again")
        #expect(oldest.notices.map(\.count) == [1, 1, 1] && oldest.before == "3")
        let last = try await notices.page(source: Self.source, before: oldest.before, gathered: oldest.gathered)
        #expect(last.notices.map(\.kind) == [.followRequest] && last.before == "1")
        let end = try await notices.page(source: Self.source, before: last.before, gathered: last.gathered)
        #expect(end.notices.isEmpty && end.before == nil && end.gathered, "nothing more is the end, not a failure")
        #expect(await server.asked == [
            Self.gathered, Self.gathered + "?max_id=9", Self.gathered + "?max_id=6", Self.gathered + "?max_id=3",
            Self.gathered + "?max_id=1",
        ])

        let held = newest.notices.readingOn(older.notices).readingOn(oldest.notices).readingOn(last.notices)
            .readingOn(end.notices)
        #expect(held.map(\.newestID) == ["11", "10", "9", "8", "7", "6", "3", "1"], "eight lines, not ten")
        #expect(Set(held.map(\.id)).count == held.count)
        let boosts = try #require(held.first { $0.handle == .gathered(key: Self.boosts) })
        #expect(boosts.count == 2 && boosts.people.map(\.handle) == [Self.other, Self.third])
        #expect(boosts.newestID == "7" && boosts.oldestID == "4")
        #expect(boosts.at == Self.moment("2026-10-08T00:08:15.934Z"), "it stands where its newest notice does")

        // The whole of it asked at once, by the same server, a little earlier.
        let (whole, _, _) = try reading([Self.gathered: .json(Captures.gathered)])
        #expect(try await whole.page(source: Self.source).notices == held)
    }

    @Test("Reading on one notice at a time repeats none, and a stretch already held adds nothing")
    func readingOnSingle() async throws {
        let (notices, server, _) = try reading([
            Self.gathered: .json(#"{"error":"Not Found"}"#, status: 404),
            Self.single: .json(Captures.singleNewest),
            Self.single + "?max_id=9": .json(Captures.singleOlder),
            Self.single + "?max_id=6": .json(try Self.stretch(single: ["5", "4", "3"])),
            Self.single + "?max_id=3": .json(try Self.stretch(single: ["1"])),
            Self.single + "?max_id=1": .json(Captures.singlePastTheEnd),
        ])
        let newest = try await notices.page(source: Self.source)
        #expect(!newest.gathered && newest.before == "9")
        let older = try await notices.page(source: Self.source, before: newest.before, gathered: newest.gathered)
        #expect(older.before == "6")
        let oldest = try await notices.page(source: Self.source, before: older.before, gathered: older.gathered)
        #expect(oldest.before == "3")
        let last = try await notices.page(source: Self.source, before: oldest.before, gathered: oldest.gathered)
        #expect(last.before == "1")
        let end = try await notices.page(source: Self.source, before: last.before, gathered: last.gathered)
        #expect(end.notices.isEmpty && end.before == nil && !end.gathered)
        #expect(await server.asked == [
            Self.gathered, Self.single, Self.single + "?max_id=9", Self.single + "?max_id=6",
            Self.single + "?max_id=3", Self.single + "?max_id=1",
        ], "the gathered read is asked once, and not again once the source has said it has none")

        let held = newest.notices.readingOn(older.notices).readingOn(oldest.notices).readingOn(last.notices)
            .readingOn(end.notices)
        #expect(held.map(\.handle) == ["11", "10", "9", "8", "7", "6", "5", "4", "3", "1"].map { .one(id: $0) })
        #expect(held.readingOn(older.notices) == held, "the same stretch come back is the lines already held")
        #expect(held.allSatisfy { $0.count == 1 && $0.people.count == 1 })

        // The whole of it asked at once.
        let (whole, _, _) = try reading([Self.single: .json(Captures.single)])
        #expect(try await whole.page(source: Self.source, gathered: false).notices == held)
    }

    @Test("Folding joins the two samples with nobody twice, keeps the larger count, reaches the older id and stands at the newer moment, whichever page said which")
    func folding() {
        let ada = NoticePerson(handle: "@ada@a.example", name: "Ada")
        let bob = NoticePerson(handle: "@bob@a.example", name: "Bob")
        let cyd = NoticePerson(handle: "@cyd@a.example", name: "Cyd")
        let source = Source(host: "a.example", kind: .mastodon)
        func line(_ people: [NoticePerson], count: Int, at: TimeInterval, newest: String, oldest: String) -> Notice {
            Notice(
                source: source, handle: .gathered(key: "favourite-1-2"), kind: .favourite, people: people, count: count,
                at: Date(timeIntervalSince1970: at), newestID: newest, oldestID: oldest
            )
        }
        let upper = line([ada, bob], count: 3, at: 300, newest: "100", oldest: "99")
        let lower = line([bob, cyd], count: 1, at: 100, newest: "9", oldest: "8")
        let folded = upper.folding(lower)
        #expect(folded == line([ada, bob, cyd], count: 3, at: 300, newest: "100", oldest: "8"))
        #expect(folded.id == upper.id)
        #expect(lower.folding(upper) == line([bob, cyd, ada], count: 3, at: 300, newest: "100", oldest: "8"), "ids are compared as ids: 9 is older than 100")
        #expect(upper.folding(upper) == upper)
        // The same key on another source, or the same name from the other read, is another line.
        let elsewhere = Notice(
            source: Source(host: "b.example", kind: .mastodon), handle: upper.handle, kind: .favourite, people: [ada],
            at: upper.at, newestID: "100", oldestID: "100"
        )
        let one = Notice(
            source: source, handle: .one(id: "favourite-1-2"), kind: .favourite, people: [ada], at: upper.at,
            newestID: "100", oldestID: "100"
        )
        #expect([upper].readingOn([elsewhere, one]).count == 3)
    }

    // MARK: - A source without the gathered read

    @Test("A source that has no gathered read is asked one notice at a time, and only a 404 says so")
    func fallsBack() async throws {
        let missing = NoticeServer.Answer.json(#"{"error":"Not Found"}"#, status: 404)
        let (notices, server, _) = try reading([Self.gathered: missing, Self.single: .json(Captures.single)])
        let page = try await notices.page(source: Self.source)
        #expect(!page.gathered && page.notices.count == 10)
        #expect(await server.asked == [Self.gathered, Self.single])

        // Asked for the gathered read alone, the 404 is the answer.
        await #expect(throws: MastodonAuthError.http(404)) {
            _ = try await notices.page(source: Self.source, gathered: true)
        }
        #expect(await server.asked == [Self.gathered, Self.single, Self.gathered])

        // A source with neither is a source that could not be read.
        let (neither, asked, _) = try reading([Self.gathered: missing, Self.single: missing])
        await #expect(throws: MastodonAuthError.http(404)) { _ = try await neither.page(source: Self.source) }
        #expect(await asked.asked == [Self.gathered, Self.single])
    }

    // MARK: - Refused, failed, unreadable

    @Test("A token never asked for notices is refused by both reads: the refusal is thrown as it came, asked once, and the sign-in is still held")
    func refused() async throws {
        let refusal = NoticeServer.Answer.json(Captures.outsideScope, status: 403)
        let (notices, server, tokens) = try reading([Self.gathered: refusal, Self.single: refusal])
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await notices.page(source: Self.source) }
        #expect(await server.asked == [Self.gathered], "a refusal is not a source without the gathered read")
        await #expect(throws: MastodonAuthError.http(403)) {
            _ = try await notices.page(source: Self.source, gathered: false)
        }
        #expect(await server.asked == [Self.gathered, Self.single])
        #expect(try tokens.token(host: Captures.host) == Self.token, "a 403 signs nobody out")
    }

    @Test("A server that fails, cannot be reached or answers something else is an error and no page: nothing is asked a second way")
    func failed() async throws {
        let (broken, brokenAsked, tokens) = try reading([Self.gathered: .json("{}", status: 500)])
        await #expect(throws: MastodonAuthError.http(500)) { _ = try await broken.page(source: Self.source) }
        #expect(await brokenAsked.asked == [Self.gathered])
        #expect(try tokens.token(host: Captures.host) == Self.token)

        let (away, awayAsked, _) = try reading([Self.gathered: .fail])
        await #expect(throws: URLError.self) { _ = try await away.page(source: Self.source) }
        #expect(await awayAsked.asked == [Self.gathered])

        // A body that is not the read's shape: the other read's, an error's, or no JSON at all.
        for body in [Captures.single, Captures.outsideScope, "[]", "<html>"] {
            let (notices, asked, _) = try reading([Self.gathered: .json(body)])
            await #expect(throws: MastodonNoticeError.unreadable, "\(body.prefix(12))") {
                _ = try await notices.page(source: Self.source)
            }
            #expect(await asked.asked == [Self.gathered])
        }
        for body in [Captures.gathered, Captures.outsideScope, "<html>"] {
            let (notices, _, _) = try reading([Self.single: .json(body)])
            await #expect(throws: MastodonNoticeError.unreadable, "\(body.prefix(12))") {
                _ = try await notices.page(source: Self.source, gathered: false)
            }
        }
    }

    @Test("A stretch asked before something that is not an id asks nothing, rather than the newest page nobody asked for")
    func notAnID() async throws {
        let (notices, server, _) = try reading([Self.gathered: .json(Captures.gathered)])
        await #expect(throws: MastodonRequestError.invalidURL) {
            _ = try await notices.page(source: Self.source, before: "9/../clear")
        }
        #expect(await server.asked.isEmpty)
    }
}
