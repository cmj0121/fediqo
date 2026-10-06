import Foundation
import Testing
@testable import FediqoCore

/// #290: a reblog is an item of its own when it arrives — who reblogged, when, and a reference to
/// what — and the post it reblogs is an ordinary item at its own publish time.
@Suite("A reblog is an item of its own")
struct ReblogItemTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_704_067_200)

    private static func date(_ minutes: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: origin.addingTimeInterval(Double(minutes) * 60))
    }

    /// Ada's post `id`, as its server sends it.
    private static func status(_ id: String, uri: String? = nil, at minutes: Int = 0, extra: String = "") -> String {
        let uri = uri ?? "https://\(host)/users/ada/statuses/\(id)"
        return """
        {"id":"\(id)","uri":"\(uri)","created_at":"\(date(minutes))","content":"<p>post \(id) about cats</p>",
         "visibility":"public","language":"en","replies_count":2,"reblogs_count":3,"favourites_count":4,
         "favourited":true,"reblogged":false,"bookmarked":false\(extra),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    /// Bob's reblog `id` of `inner`, as its server sends it. `uri` nil leaves the key out.
    private static func reblog(_ id: String, uri: String?? = .none, at minutes: Int = 600, of inner: String) -> String {
        let named: String? = switch uri {
        case .none: "https://\(host)/users/bob/statuses/\(id)/activity"
        case .some(let given): given
        }
        let key = named.map { #""uri":"\#($0)","# } ?? ""
        return """
        {"id":"\(id)",\(key)"created_at":"\(date(minutes))","content":"","visibility":"public",
         "favourited":false,"reblogged":true,
         "account":{"username":"bob","acct":"bob","display_name":"Bob","avatar":"https://\(host)/bob.png"},
         "reblog":\(inner)}
        """
    }

    private static func arrival(_ json: String, categories: Set<FediqoCore.Category> = [.home]) throws -> (item: Note, reblogged: Note?) {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .arrival(source: source, categories: categories, sent: .now())
    }

    private static func listed(_ json: String) throws -> Listed {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .listed(source: source, category: .home, sent: .now())
    }

    private func store(_ notes: [Note] = []) async -> ItemStore {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(notes)
        return store
    }

    // MARK: - What arrives

    @Test("A reblog arrives as two things: the reblog — its own id and time, who reblogged, one reference — and the post, at its own time through no category")
    func twoThings() throws {
        let arrived = try Self.arrival(Self.reblog("900", of: Self.status("7")))
        let item = arrived.item
        #expect(item.id == "https://\(Self.host)/users/bob/statuses/900/activity")
        #expect(item.postedAt == Self.origin.addingTimeInterval(600 * 60), "when it was reblogged")
        #expect(item.author == "Bob" && item.handle == "@bob@\(Self.host)")
        #expect(item.statusID == "900")
        #expect(item.refs == [Reference(kind: .reblogs, id: "https://\(Self.host)/users/ada/statuses/7", statusID: "7")])
        #expect(item.isReblog && item.categories == [.home] && !item.refsDue, "its target came with it: nothing is owed")
        #expect(item.avatarURL?.absoluteString == "https://\(Self.host)/bob.png")
        // Nothing of a post is the reblog's own.
        #expect(item.body.isEmpty && item.attachments.isEmpty && item.spoiler == nil && item.sensitive == nil)
        #expect(item.counts == Counts() && item.boosted == nil && item.favourited == nil && item.bookmarked == nil)
        #expect(item.editedAt == nil && item.earlier.isEmpty && item.quote == nil && item.reply == nil && item.url == nil)
        #expect(item.boostedBy == nil && item.boosterHandle == nil)

        let post = try #require(arrived.reblogged)
        #expect(post.key == item.reblogKey)
        #expect(post.postedAt == Self.origin, "when it was published")
        #expect(post.categories.isEmpty && post.listed.isEmpty, "it came in the payload, not through the timeline")
        #expect(post.author == "Ada" && post.body == "post 7 about cats" && post.statusID == "7")
        #expect(post.counts == Counts(replies: 2, reblogs: 3, favourites: 4))
        #expect(post.favourited == true && post.boosted == false, "the post's own flags, never the reblog's")
        #expect(post.boostedBy == nil && post.boosterHandle == nil && !post.isReblog)
    }

    @Test("As a timeline lists it, the reblog is what is listed, under its own id; the post is carried beside it, unlisted")
    func theReblogIsTheListedThing() throws {
        let listed = try Self.listed(Self.reblog("900", of: Self.status("7")))
        #expect(listed.listed == "900")
        #expect(listed.note.isReblog && listed.note.listed == [.home: "900"])
        #expect(listed.carried.map(\.statusID) == ["7"] && listed.carried[0].listed.isEmpty)
        let plain = try Self.listed(Self.status("7"))
        #expect(plain.listed == "7" && plain.carried.isEmpty && !plain.note.isReblog)
        #expect([listed, plain].landing.map(\.statusID) == ["900", "7", "7"])
    }

    @Test("Read as a post — a search, a tag, a thread, one post read again, an act's answer — a reblog is the post it carries, and says nothing of who reblogged")
    func readAsAPost() throws {
        let dto = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.reblog("900", of: Self.status("7")).utf8))
        let note = dto.asNote(source: Self.source, categories: [], sent: .now())
        #expect(note.statusID == "7" && !note.isReblog && note.boostedBy == nil && note.favourited == true)
    }

    // MARK: - An identity made of a stranger's word

    @Test("A reblog its source gave no address is held under a name this device makes of the host and the reblog's own id, which gathers with nothing")
    func noAddress() throws {
        let item = try Self.arrival(Self.reblog("900", uri: .some(nil), of: Self.status("7"))).item
        #expect(item.id == Note.inventedID(host: Self.host, statusID: "900"))
        #expect(item.isReblog && item.post == nil)
    }

    @Test("A reblog named as the very post it reblogs is given the made-up name instead: the two are never one row")
    func namedAsItsTarget() throws {
        let target = "https://\(Self.host)/users/ada/statuses/7"
        let arrived = try Self.arrival(Self.reblog("900", uri: .some(target), of: Self.status("7")))
        #expect(arrived.item.id == Note.inventedID(host: Self.host, statusID: "900"))
        #expect(arrived.item.key != arrived.reblogged?.key && arrived.item.isReblog)
    }

    @Test("A reblog that would still be the row of what it reblogs is no reblog: the post arrives as itself, through the timeline")
    func stillTheSameRow() throws {
        // No address for either, and one id for both: the made-up names are one name.
        let inner = #"{"id":"900","created_at":"\#(Self.date(0))","content":"<p>x</p>","account":{"username":"ada","acct":"ada","display_name":"Ada"}}"#
        let arrived = try Self.arrival(Self.reblog("900", uri: .some(nil), of: inner))
        #expect(!arrived.item.isReblog && arrived.reblogged == nil)
        #expect(arrived.item.body == "x" && arrived.item.categories == [.home])
    }

    @Test("A name longer than a name may be is no name: a post, a reblog and a reblog's target sent under one are each held under the name this device makes instead")
    func namesPastTheBound() throws {
        let long = "https://\(Self.host)/" + String(repeating: "a", count: Reference.longest)
        #expect(long.utf8.count > Reference.longest)
        #expect(try Self.arrival(Self.status("7", uri: long)).item.id == Note.inventedID(host: Self.host, statusID: "7"))
        let arrived = try Self.arrival(Self.reblog("900", uri: .some(long + "/activity"), of: Self.status("7", uri: long)))
        #expect(arrived.item.isReblog && arrived.item.id == Note.inventedID(host: Self.host, statusID: "900"))
        #expect(arrived.reblogged?.id == Note.inventedID(host: Self.host, statusID: "7"))
        #expect(arrived.item.reblogKey == arrived.reblogged?.key)
        // As long as a name may be is still a name.
        let longest = "https://\(Self.host)/" + String(repeating: "a", count: Reference.longest - "https://\(Self.host)/".utf8.count)
        #expect(try Self.arrival(Self.status("7", uri: longest)).item.id == longest)
    }

    @Test("A reblog whose target's own id at its source is longer than a name may be is no reblog: the post arrives as itself, through the timeline")
    func targetIDPastTheBound() throws {
        let id = String(repeating: "9", count: Reference.longest + 1)
        let arrived = try Self.arrival(Self.reblog("900", of: Self.status(id, uri: "https://\(Self.host)/users/ada/statuses/7")))
        #expect(!arrived.item.isReblog && arrived.reblogged == nil)
        #expect(arrived.item.body.hasSuffix("about cats") && arrived.item.categories == [.home])
    }

    @Test("However deep a payload nests reblogs, one status and the one it reblogs are all that is decoded")
    func nestingIsOneDeep() throws {
        var json = Self.status("1")
        for depth in 2...400 { json = Self.reblog("\(depth)", of: json) }
        let dto = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
        #expect(dto.id == "400" && dto.reblog?.value?.id == "399")
        #expect(dto.reblog?.value?.reblog != nil && dto.reblog?.value?.reblog?.value == nil, "the second reblog is seen and not decoded")
        let arrived = dto.arrival(source: Self.source, categories: [.home], sent: .now())
        #expect(arrived.item.isReblog && arrived.reblogged == nil)
    }

    @Test("A reblog of a reblog refers to the inner one by name and brings nothing with it: what is not a post is not taken in as one")
    func aReblogOfAReblog() throws {
        let arrived = try Self.arrival(Self.reblog("950", of: Self.reblog("900", of: Self.status("7"))))
        #expect(arrived.item.isReblog && arrived.reblogged == nil)
        #expect(arrived.item.refs == [
            Reference(kind: .reblogs, id: "https://\(Self.host)/users/bob/statuses/900/activity", statusID: "900"),
        ])
    }

    @Test("A status carrying no reblog is a post, whatever else it says")
    func noTarget() throws {
        let arrived = try Self.arrival(Self.status("7", extra: #","reblog":null"#))
        #expect(!arrived.item.isReblog && arrived.reblogged == nil && arrived.item.categories == [.home])
    }

    @Test("A target on another host is a name within this source: it is looked up here, under this host, and is no address to ask")
    func aTargetElsewhere() throws {
        let arrived = try Self.arrival(Self.reblog("900", of: Self.status("7", uri: "https://elsewhere.example/users/ada/statuses/1")))
        #expect(arrived.item.reblogKey == NoteKey(host: Self.host, id: "https://elsewhere.example/users/ada/statuses/1"))
        #expect(arrived.reblogged?.source == Self.source)
    }

    // MARK: - Held

    @Test("Both are held: the reblog through the timeline that listed it, the post through none unless it also arrives on its own")
    func bothAreHeld() async throws {
        let store = await store()
        await store.ingest([try Self.listed(Self.reblog("900", of: Self.status("7")))].landing)
        let all = await store.all()
        #expect(all.map(\.statusID) == ["900", "7"], "the reblog at its time, above the post at its own")
        #expect(all[0].categories == [.home] && all[1].categories.isEmpty)
        #expect(await store.newestListedID(host: Self.host, category: .home) == "900")

        await store.ingest([try Self.listed(Self.status("7"))].landing)
        let post = await store.all().first { $0.statusID == "7" }
        #expect(post?.categories == [.home] && post?.listed == [.home: "7"], "arrived on its own too")
        #expect(await store.all().count == 2)
    }

    @Test("Reading again moves neither: the same reblog listed again changes no row and draws nothing")
    func readingAgainMovesNeither() async throws {
        let store = await store()
        let landing = [try Self.listed(Self.reblog("900", of: Self.status("7")))].landing
        await store.ingest(landing)
        let before = await store.all(), drawn = await store.drawn, revision = await store.revision
        await store.ingest(landing)
        #expect(await store.all() == before)
        #expect(await store.drawn == drawn)
        #expect(await store.revision == revision)
    }

    @Test("A post older than the keep-for window is taken in with a reblog inside it, stays while that reblog does, and goes when it goes")
    func theWindowKeepsWhatAReblogShows() async throws {
        let store = await store()
        let now = Self.origin.addingTimeInterval(601 * 60)
        await store.setRetention(months: 1, from: now)
        // Published two years before; reblogged a minute ago.
        let old = Self.status("7", at: -2 * 365 * 24 * 60)
        await store.ingest([try Self.listed(Self.reblog("900", of: old))].landing)
        #expect(await store.all().map(\.statusID) == ["900", "7"])
        await store.setRetention(months: 1, from: now)
        #expect(await store.all().count == 2, "the window leaves the post its reblog shows")

        await store.ingest([try Self.listed(old)].landing)
        #expect(await store.all().first { $0.statusID == "7" }?.categories.isEmpty == true, "on its own it is past the window, and is not taken")

        await store.setRetention(months: 1, from: now.addingTimeInterval(90 * 86400))
        #expect(await store.all().isEmpty, "the reblog went by its own age, and the post with it")
    }

    @Test("Room lets the post go only after the reblog showing it, however much older the post is")
    func roomTakesTheReblogFirst() async throws {
        let store = await store()
        await store.ingest([try Self.listed(Self.reblog("900", of: Self.status("7")))].landing)
        #expect(await store.letGoOldest(count: 1).posts == 1)
        #expect(await store.all().map(\.statusID) == ["7"], "the post is the older, and stayed while the reblog showed it")
        #expect(await store.letGoOldest(count: 1).posts == 1)
        #expect(await store.all().isEmpty)
    }

    @Test("A source naming a reblog as a post it already handed over, or a post as a reblog, is not believed: the row held stays what it was")
    func aRowDoesNotChangeWhatItIs() async throws {
        let post = try Self.arrival(Self.status("7"), categories: []).item
        let store = await store([post])
        // A reblog of some other post, under post 7's own name, as Home lists it.
        let liar = try Self.listed(Self.reblog("900", uri: .some(post.id), of: Self.status("8"))).note
        #expect(liar.key == post.key && liar.isReblog && liar.listed == [.home: "900"], "the premise")
        await store.ingest([liar])
        let held = await store.note(post.key)
        #expect(held?.isReblog == false && held?.body == "post 7 about cats")
        #expect(held?.listed.isEmpty == true && held?.categories.isEmpty == true, "nothing of the copy was taken: not its listing, not what it came through")
        #expect(await store.newestListedID(host: Self.host, category: .home) == nil)

        let reblog = try Self.arrival(Self.reblog("901", of: Self.status("8"))).item
        await store.ingest([reblog])
        // A post under the reblog's name, saying it was changed since: its words are not laid on the reblog.
        let posing = try Self.arrival(Self.status("9", uri: reblog.id, extra: #","edited_at":"\#(Self.date(900))""#), categories: [.public]).item
        #expect(posing.key == reblog.key && posing.editedAt != nil, "the premise")
        await store.ingest([posing])
        #expect(await store.note(reblog.key)?.isReblog == true)
        #expect(await store.note(reblog.key)?.body.isEmpty == true)
        #expect(await store.note(reblog.key)?.categories == [.home])
    }

    @Test("A reblog older than the keep-for window is refused, and the post it carried is refused with it — unless that post is already held, or arrives on its own in the same landing")
    func aRefusedReblogBringsNothing() async throws {
        let now = Self.origin.addingTimeInterval(200 * 86400)
        // Reblogged four months before now; the post it carries was published yesterday.
        let recent = Self.status("7", at: 199 * 24 * 60)
        let old = Self.reblog("900", at: 80 * 24 * 60, of: recent)

        let empty = await store()
        await empty.setRetention(months: 1, from: now)
        await empty.ingest([try Self.listed(old)].landing)
        #expect(await empty.all().isEmpty, "nothing refers to the post, and it came through no timeline")

        let holding = await store()
        await holding.setRetention(months: 1, from: now)
        let own = [try Self.listed(recent)].landing
        await holding.ingest(own)
        let before = await holding.all()
        await holding.ingest([try Self.listed(old)].landing)
        #expect(await holding.all() == before, "already held: it stays as it was")

        let together = await store()
        await together.setRetention(months: 1, from: now)
        await together.ingest([try Self.listed(old), try Self.listed(recent)].landing)
        #expect(await together.all().map(\.statusID) == ["7"])
        #expect(await together.all().first?.categories == [.home], "the copy that arrived on its own is taken")
    }

    // MARK: - The room, and what is held for another

    private static func post(_ id: String, at days: Int, quoting quoted: String? = nil, kept: Bool = false) -> Note {
        Note(
            id: "https://\(host)/p/\(id)", source: source, author: "Ada", handle: "@ada@\(host)", body: id,
            postedAt: origin.addingTimeInterval(Double(days) * 86400), categories: [.home], statusID: id,
            quote: quoted.map { Quote(state: .accepted, post: QuotedPost(post($0, at: 0)), statusID: $0) }, kept: kept
        )
    }

    private static func reblogNote(_ id: String, at days: Int, of target: String, kept: Bool = false) -> Note {
        Note(
            id: "https://\(host)/r/\(id)", source: source, author: "Bob", handle: "@bob@\(host)", body: "",
            postedAt: origin.addingTimeInterval(Double(days) * 86400), categories: [.home], statusID: id, kept: kept,
            refs: [Reference(kind: .reblogs, id: target)]
        )
    }

    /// Lets the room take one row at a time until it takes none, and says the order they went in.
    private func drained(_ store: ItemStore) async -> [String] {
        var went: [String] = []
        while true {
            let before = Set(await store.all().map(\.id))
            guard await store.letGoOldest(count: 1).posts == 1 else { return went }
            went += before.subtracting(await store.all().map(\.id)).map { String($0.split(separator: "/").suffix(2).joined(separator: "/")) }
        }
    }

    @Test("Two reblogs that name each other hold nothing: both go, and the room is not left saying only kept posts fill it")
    func aMutualPairGoes() async {
        let a = Self.reblogNote("a", at: 1, of: "https://\(Self.host)/r/b")
        let b = Self.reblogNote("b", at: 2, of: "https://\(Self.host)/r/a")
        let store = ItemStore(sources: [Self.source], notes: [a, b])
        #expect(await store.holdsWhatRoomMayLetGo())
        #expect(await drained(store) == ["r/a", "r/b"])
        #expect(await !store.holdsWhatRoomMayLetGo())
    }

    @Test("Two posts that quote each other do not hold each other for ever: the later goes, then the earlier")
    func mutualQuotesGo() async {
        let a = Self.post("a", at: 1, quoting: "b")
        let b = Self.post("b", at: 2, quoting: "a")
        let store = ItemStore(sources: [Self.source], notes: [a, b])
        #expect(await store.holdsWhatRoomMayLetGo())
        #expect(await drained(store) == ["p/b", "p/a"], "the earlier is held for the later, and by nothing once it has gone")
    }

    @Test("A chain goes from its newest end: each post is held for the item that shows it, until that item has gone")
    func aChainGoesFromTheEnd() async {
        // c quotes b quotes a; a reblog shows c; and x is nobody's.
        let store = ItemStore(sources: [Self.source], notes: [
            Self.post("a", at: 1), Self.post("b", at: 2, quoting: "a"), Self.post("c", at: 3, quoting: "b"),
            Self.reblogNote("r", at: 9, of: "https://\(Self.host)/p/c"), Self.post("x", at: 5),
        ])
        #expect(await drained(store) == ["p/x", "r/r", "p/c", "p/b", "p/a"])
    }

    @Test("A reference to a reblog holds nothing: a reblog named by another goes as its own age says")
    func aReblogIsHeldForNothing() async {
        let store = ItemStore(sources: [Self.source], notes: [
            Self.post("p", at: 0), Self.reblogNote("old", at: 1, of: "https://\(Self.host)/p/p"),
            Self.reblogNote("new", at: 5, of: "https://\(Self.host)/r/old"),
        ])
        #expect(await drained(store) == ["r/old", "p/p", "r/new"])
        // And the window: a reblog inside it does not hold a reblog outside it.
        let windowed = ItemStore(sources: [Self.source], notes: [
            Self.reblogNote("old", at: -90, of: "https://\(Self.host)/p/p"),
            Self.reblogNote("new", at: 0, of: "https://\(Self.host)/r/old"),
        ])
        await windowed.setRetention(months: 1, from: Self.origin)
        #expect(await windowed.all().map(\.statusID) == ["new"])
    }

    @Test("What a kept item shows is held whatever goes around it; what an item that may go shows is held only until it has gone")
    func heldForWhatStays() async {
        let store = ItemStore(sources: [Self.source], notes: [
            Self.post("shown", at: 0), Self.reblogNote("kept", at: 1, of: "https://\(Self.host)/p/shown", kept: true),
            Self.post("other", at: 2),
        ])
        #expect(await drained(store) == ["p/other"])
        #expect(await store.all().compactMap(\.statusID).sorted() == ["kept", "shown"])
    }

    // MARK: - Keeping a reblog

    @Test("Keeping a reblog keeps the reblog, and the post it shows is held for as long as it is kept — by the window, the room, a span of dates, its source removed, and its source saying it is gone")
    func aKeptReblogKeepsWhatItShows() async {
        func held() -> [Note] {
            [Self.post("shown", at: -400), Self.reblogNote("kept", at: -300, of: "https://\(Self.host)/p/shown", kept: true)]
        }
        let post = held()[0].key, reblog = held()[1].key
        let everything = Self.origin.addingTimeInterval(-1000 * 86400) ..< Self.origin.addingTimeInterval(86400)

        let byWindow = ItemStore(sources: [Self.source], notes: held())
        await byWindow.setRetention(months: 1, from: Self.origin)
        #expect(await byWindow.all().count == 2)

        let byRoom = ItemStore(sources: [Self.source], notes: held())
        #expect(await byRoom.letGoOldest(count: 5).posts == 0)
        #expect(await !byRoom.holdsWhatRoomMayLetGo())

        let bySpan = ItemStore(sources: [Self.source], notes: held())
        #expect(await bySpan.count(span: everything) == 0, "the question before the press counts neither")
        #expect(await bySpan.letGo(span: everything) == 0)
        #expect(await bySpan.all().count == 2)

        let byRemoval = ItemStore(sources: [Self.source], notes: held())
        await byRemoval.remove(host: Self.host)
        #expect(await byRemoval.all().count == 2)

        let byGone = ItemStore(sources: [Self.source], notes: held())
        await byGone.forget(post)
        #expect(await byGone.note(post)?.goneSince != nil, "marked as gone from its source, and still here")
        #expect(await byGone.goneCount() == 0)
        #expect(await byGone.letGoneGo() == 0)

        // The mark is the reblog's, and the post is not marked: un-kept, both are ordinary again.
        let after = ItemStore(sources: [Self.source], notes: held())
        #expect(await after.note(post)?.kept == false)
        #expect(await after.setKept(false, for: reblog))
        #expect(await after.letGo(span: everything) == 2)
    }

    // MARK: - What a note rebuilt from another keeps

    private static let reference = Reference(kind: .reblogs, id: "https://\(host)/users/ada/statuses/7", statusID: "7")

    private static func reblogItem(_ id: String = "r/1") -> Note {
        Note(
            id: "https://\(host)/\(id)", source: source, author: "Bob", handle: "@bob@\(host)", body: "",
            postedAt: origin, categories: [.home], statusID: "900", refs: [reference]
        )
    }

    @Test("A reblog stays a reblog through every way a note is made anew from another: filled, read again, restated, revised, its reader's marks swept, an opening kept, the legacy word taken off")
    func refsAreCarried() {
        let held = Self.reblogItem()
        let copy = Self.reblogItem()
        let made: [(String, Note)] = [
            ("filled", held.filled(from: copy)),
            ("refreshed", copy.refreshed(over: held)),
            ("restated", held.restated(by: copy, taking: [])),
            ("revised", held.revised(by: copy, was: held)),
            ("withoutReaderMarks", held.withoutReaderMarks()),
            ("with(opening:)", held.with(opening: ForumOpening(words: "x"))),
            ("withoutArrivalAsReblog", held.withoutArrivalAsReblog()),
        ]
        for (site, note) in made {
            #expect(note.refs == [Self.reference], "\(site) lost what the item reblogs")
            #expect(note.isReblog && note.key == held.key)
        }
    }

    @Test("What a reblog reblogs never changes once it is held: a later copy naming another post is read over it and leaves it reblogging what it did")
    func aReblogIsNeverRetargeted() async {
        let held = Self.reblogItem()
        let other = Note(
            id: held.id, source: Self.source, author: "Bob", handle: held.handle, body: "", postedAt: Self.origin,
            categories: [.home], statusID: "900", refs: [Reference(kind: .reblogs, id: "https://\(Self.host)/users/eve/statuses/666")]
        )
        #expect(other.refreshed(over: held).refs == [Self.reference])
        #expect(held.filled(from: other).refs == [Self.reference])
        let store = await store([held])
        await store.ingest([other])
        _ = await store.refresh([other], ifSourceHere: Self.host)
        #expect(await store.note(held.key)?.reblogKey == held.reblogKey)
    }

    @Test("A store laid in whole — a read back — takes what the window would refuse where a row that comes in shows it: the post a kept reblog reblogs and the post an in-window post quotes, and never a reblog for another's sake")
    func aStoreLaidInSparesWhatIsShown() async {
        let store = ItemStore()
        await store.setRetention(months: 1, from: Self.origin)
        let notes = [
            Self.post("shown", at: -400), Self.reblogNote("kept", at: -300, of: "https://\(Self.host)/p/shown", kept: true),
            Self.post("quoted", at: -400), Self.post("quoting", at: -1, quoting: "quoted"),
            Self.reblogNote("old", at: -300, of: "https://\(Self.host)/p/none"),
            Self.reblogNote("new", at: -1, of: "https://\(Self.host)/r/old"),
            Self.post("alone", at: -400),
        ]
        await store.replace(sources: [Self.source], notes: notes)
        #expect(Set(await store.all().compactMap(\.statusID)) == ["shown", "kept", "quoted", "quoting", "new"])
        // And it is the rule the window itself keeps: applying the window again lets nothing more go.
        #expect(await store.setRetention(months: 1, from: Self.origin) == 0)
    }

    @Test("A post's references that its reply and quote state are worked out again at each of those sites, and never doubled")
    func derivedOnesAreNotDoubled() {
        let answer = Note(
            id: "https://\(Self.host)/a", source: Self.source, author: "Ada", handle: "@ada", body: "x",
            postedAt: Self.origin, categories: [.home], reply: Reply(inReplyToId: "41"), quote: Quote(state: .pending)
        )
        let expected = [Reference(kind: .answers, statusID: "41"), Reference(kind: .quotes, state: .pending)]
        for note in [
            answer.filled(from: answer), answer.refreshed(over: answer), answer.restated(by: answer, taking: []),
            answer.revised(by: answer, was: answer), answer.withoutReaderMarks(), answer.withoutArrivalAsReblog(),
        ] {
            #expect(note.refs == expected)
        }
    }

    @Test("Through the store: a reblog taken in again, and read again, is the reblog it was")
    func carriedThroughTheStore() async {
        let store = await store([Self.reblogItem()])
        let key = Self.reblogItem().key
        var listedAgain = Self.reblogItem()
        listedAgain.categories = [.public]
        await store.ingest([listedAgain])
        #expect(await store.note(key)?.refs == [Self.reference])
        #expect(await store.note(key)?.categories == [.home, .public])
        _ = await store.refresh([Self.reblogItem()], ifSourceHere: Self.host)
        #expect(await store.note(key)?.isReblog == true)
    }

    // MARK: - A reblog has no words of its own

    @Test("A note that says it reblogs another is a reblog wherever it is made: whatever words, cover, pictures, counts, marks, reply, quote, change or address it is handed, it holds none, and refers by that one reference alone")
    func noWordsOfItsOwn() {
        let claimed = Note(
            id: "https://\(Self.host)/r/1", source: Self.source, author: "Bob", handle: "@bob@\(Self.host)",
            body: "words", title: "a title", postedAt: Self.origin, categories: [.home],
            reply: Reply(inReplyToId: "41"), boostedBy: "Cyd", boosterHandle: "@cyd@\(Self.host)",
            boosted: true, favourited: true, bookmarked: true, audience: .everyone,
            attachments: [Attachment(kind: .image, url: URL(string: "https://\(Self.host)/a.png"))],
            sensitive: true, spoiler: "cover", url: URL(string: "https://\(Self.host)/x"),
            counts: Counts(replies: 1, reblogs: 2, favourites: 3), statusID: "900",
            opening: ForumOpening(words: "opening"), quote: Quote(state: .pending), editedAt: Self.origin,
            earlier: [Wording(body: "before", spoiler: nil, sensitive: nil, until: Self.origin)], language: "en",
            refs: [Reference(kind: .answers, statusID: "41"), Self.reference, Reference(kind: .reblogs, id: "other")]
        )
        #expect(claimed.isReblog && claimed.refs == [Self.reference])
        #expect(claimed.body.isEmpty && claimed.title == nil && claimed.spoiler == nil && claimed.sensitive == nil)
        #expect(claimed.attachments.isEmpty && claimed.counts == Counts() && claimed.url == nil && claimed.audience == nil)
        #expect(claimed.boosted == nil && claimed.favourited == nil && claimed.bookmarked == nil)
        #expect(claimed.reply == nil && claimed.quote == nil && claimed.opening == nil && claimed.language == nil)
        #expect(claimed.editedAt == nil && claimed.earlier.isEmpty && claimed.boostedBy == nil && claimed.boosterHandle == nil)
        // What is the reblog's own stays.
        #expect(claimed.author == "Bob" && claimed.statusID == "900" && claimed.categories == [.home] && claimed.postedAt == Self.origin)
        #expect(claimed.sendableID == nil, "and its id is no id to send")
        #expect(Self.reblogItem() == Self.reblogItem().refreshed(over: claimed).filled(from: claimed))
    }

    @Test("A post read again, a thread, an act's answer: read as a post and named as a reblog this device holds, it is not laid over the reblog; nor a reblog over a post")
    func aReadAgainDoesNotChangeWhatARowIs() async throws {
        let reblog = try Self.arrival(Self.reblog("900", of: Self.status("7"))).item
        let post = try Self.arrival(Self.status("8"), categories: [.home]).item
        let store = await store([reblog, post])
        let posing = try Self.arrival(Self.status("9", uri: reblog.id), categories: []).item
        #expect(posing.key == reblog.key && !posing.isReblog, "the premise")
        #expect(await !store.refresh([posing], ifSourceHere: Self.host))
        #expect(await !store.refresh([posing], ifSourceHere: Self.host, acted: .favourited))
        let held = try #require(await store.note(reblog.key))
        #expect(held == reblog || (held.isReblog && held.body.isEmpty && held.favourited == nil))
        #expect(held.body.isEmpty && held.counts == Counts() && held.favourited == nil && held.refs == reblog.refs)

        let liar = try Self.arrival(Self.reblog("901", uri: .some(post.id), of: Self.status("7"))).item
        #expect(await !store.refresh([liar], ifSourceHere: Self.host))
        #expect(await store.note(post.key)?.body == "post 8 about cats")
        #expect(await store.note(post.key)?.isReblog == false)
    }

    @Test("A read again of a reblog that says nothing of what it reblogs leaves it reblogging what it did; a reply and a quote are still re-derived beside it")
    func carriedBesideWhatIsDerived() {
        let reference = Reference(kind: .reblogs, id: "x")
        #expect(Reference.carried([reference], reply: nil, quote: nil) == [reference])
        #expect(Reference.carried([Reference(kind: .answers, statusID: "1"), reference], reply: Reply(inReplyToId: "2"), quote: nil)
            == [Reference(kind: .answers, statusID: "2"), reference])
        #expect(Reference.carried([Reference(kind: .quotes, state: .pending)], reply: nil, quote: nil).isEmpty)
    }

    // MARK: - Held from before

    private static func legacy(by booster: String? = "@bob@\(host)", name: String = "Bob") throws -> Note {
        let post = try arrival(status("7"), categories: [.home]).item
        var note = Note(
            id: post.id, source: source, author: post.author, handle: post.handle, body: post.body,
            postedAt: post.postedAt, categories: [.home, .public], boostedBy: name, boosterHandle: booster, statusID: "7",
            gaps: [TimelineGap(.mayBeMissing, in: .home), TimelineGap(.newerRemain, in: .public)],
            listed: [.home: "900", .public: "7"]
        )
        note.asked = .unsaid
        return note
    }

    @Test("A post held from before, which arrived as a reblog, stays where it was and says so; once a timeline brings that reblog it says so no longer, and the reblog carries what that timeline listed")
    func theLegacyFactComesOff() async throws {
        let store = await store([try Self.legacy()])
        let key = try Self.legacy().key
        #expect(await store.note(key)?.boostedBy == "Bob")
        #expect(await store.note(key)?.postedAt == Self.origin)

        await store.ingest([try Self.listed(Self.reblog("900", of: Self.status("7")))].landing)

        let post = try #require(await store.note(key))
        #expect(post.boostedBy == nil && post.boosterHandle == nil)
        #expect(post.postedAt == Self.origin, "where it was")
        #expect(post.categories == [.public], "Home listed the reblog, not the post: it came through Public alone, as a post a reblog brings today comes through none")
        #expect(post.listed == [.public: "7"], "the reblog's own listing is the reblog's")
        #expect(post.gaps == [TimelineGap(.newerRemain, in: .public)])
        let reblog = try #require(await store.all().first { $0.isReblog })
        #expect(reblog.listed == [.home: "900"] && reblog.gaps == [TimelineGap(.mayBeMissing, in: .home)])
        #expect(reblog.postedAt == Self.origin.addingTimeInterval(600 * 60), "the source's own time for the reblog; none is guessed")
        #expect(await store.newestListedID(host: Self.host, category: .home) == "900")
    }

    @Test("Somebody else's reblog of that post leaves the word on it: it arrived as the reblog it says, and that one has not come")
    func anotherPersonsReblogLeavesIt() async throws {
        let store = await store([try Self.legacy(by: "@cyd@\(Self.host)", name: "Cyd")])
        await store.ingest([try Self.listed(Self.reblog("900", of: Self.status("7")))].landing)
        let post = try #require(await store.note(try Self.legacy().key))
        #expect(post.boostedBy == "Cyd" && post.listed[.home] == "900" && post.categories == [.home, .public])
    }

    @Test("A row that wrote down a name and no handle is matched by the name")
    func matchedByNameWhereNoHandleWasKept() async throws {
        let store = await store([try Self.legacy(by: nil)])
        await store.ingest([try Self.listed(Self.reblog("900", of: Self.status("7")))].landing)
        #expect(await store.note(try Self.legacy().key)?.boostedBy == nil)
    }

    // MARK: - Rules and search

    private static func held() throws -> (reblog: Note, post: Note, own: Note, all: [Note]) {
        let arrived = try arrival(reblog("900", of: status("7")))
        let own = try arrival(status("8", extra: #","sensitive":true"#), categories: [.home]).item
        let post = try #require(arrived.reblogged)
        return (arrived.item, post, own, [arrived.item, post, own])
    }

    private func shown(_ rules: [Rule?], _ notes: [Note]) -> Set<String> {
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: rules.compactMap { $0 }), sources: [Self.source])
        return Set(timeline.shown(notes, TextIndex(notes)).compactMap(\.statusID))
    }

    @Test("Showing a person shows what they made: an include on an author is asked of who reblogged, and of nobody else — the post's own row is its author's")
    func showingAPersonIsWhoMadeIt() throws {
        // Bob reblogged Ada's post 7 (the reblog is 900); Ada also wrote 8.
        let held = try Self.held()
        #expect(shown([.author("bob@\(Self.host)", in: .every, sources: [Self.source])], held.all) == ["900"], "who reblogged: the reblog")
        #expect(shown([.author("ada@\(Self.host)", in: .every, sources: [Self.source])], held.all) == ["7", "8"], "who wrote it: her own rows, and not Bob's reblog of hers")
        // And with the post it reblogs in hand — as beside a rule on words, which has it looked
        // up — an include on Ada still does not take Bob's reblog of hers.
        let showAda = try #require(Rule.author("ada@\(Self.host)", in: .every, sources: [Self.source]))
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: [showAda]), sources: [Self.source])
        #expect(timeline.verdict(held.reblog, TextIndex(held.all), reblogged: held.post) == .hidden(by: showAda.id))
        #expect(shown([showAda, .keyword("nothing here", in: .every, effect: .exclude)], held.all) == ["7", "8"])
    }

    private static func reblogsOf(_ who: String, effect: RuleEffect = .include) throws -> Rule {
        try #require(Rule.field("reblogOf", is: .text("\(who)@\(host)"), in: .every, effect: effect))
    }

    @Test("A hide on an author is asked of who made the item, as an include is: it takes that person's own rows and leaves somebody else's reblog of their post; a hide on who reblogged takes the reblog and not the post's own row")
    func hidingAPersonIsWhoMadeIt() throws {
        let held = try Self.held()
        let hideAda = try #require(Rule.author("ada@\(Self.host)", in: .every, effect: .exclude, sources: [Self.source]))
        #expect(shown([hideAda], held.all) == ["900"], "her rows go; Bob's reblog of her post is Bob's item")
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: [hideAda]), sources: [Self.source])
        #expect(timeline.verdict(held.reblog, TextIndex(held.all), reblogged: held.post) == .shown, "with the post in hand, too")
        #expect(timeline.verdict(held.reblog, TextIndex([]), reblogged: held.post) == .shown, "and with no index built")

        let hideBob = Rule.author("bob@\(Self.host)", in: .every, effect: .exclude, sources: [Self.source])
        #expect(shown([hideBob], held.all) == ["7", "8"], "the reblog goes; what Ada wrote stays")

        // A hide beside an include: Bob's reblogs are shown, Ada's too.
        let showBob = Rule.author("bob@\(Self.host)", in: .every, sources: [Self.source])
        #expect(shown([showBob, hideAda], held.all) == ["900"])
    }

    @Test("Whose post it reblogs is a rule of the person's own: hiding reblogs of somebody takes other people's reblogs of their posts and leaves their own posts, and names the rule; with a hide on the author beside it both go; an include shows only reblogs of that person")
    func reblogsOfAPerson() throws {
        let held = try Self.held()
        let hideReblogsOfAda = try Self.reblogsOf("ada", effect: .exclude)
        #expect(shown([hideReblogsOfAda], held.all) == ["7", "8"], "Bob's reblog of her post goes; what she wrote stays")
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: [hideReblogsOfAda]), sources: [Self.source])
        #expect(timeline.verdict(held.reblog, TextIndex(held.all), reblogged: held.post) == .hidden(by: hideReblogsOfAda.id), "the hidden reblog names its rule")
        #expect(timeline.verdict(held.reblog, TextIndex([]), reblogged: held.post) == .hidden(by: hideReblogsOfAda.id), "with no index built, too")
        #expect(timeline.verdict(held.post, TextIndex(held.all)) == .shown)

        // What a hide on the author did by itself before, the two rules do together.
        let hideAda = Rule.author("ada@\(Self.host)", in: .every, effect: .exclude, sources: [Self.source])
        #expect(shown([hideAda, hideReblogsOfAda], held.all).isEmpty, "her words are drawn nowhere")
        let showBob = Rule.author("bob@\(Self.host)", in: .every, sources: [Self.source])
        #expect(shown([showBob, hideReblogsOfAda], held.all).isEmpty, "Bob's reblogs are shown, but not those of Ada's posts")

        #expect(shown([try Self.reblogsOf("ada")], held.all) == ["900"], "only reblogs of her posts: no post, hers or anybody's")
        #expect(shown([try Self.reblogsOf("bob")], held.all).isEmpty, "who reblogged is not whose post it is")
        #expect(shown([try Self.reblogsOf("bob", effect: .exclude)], held.all) == ["900", "7", "8"])
        // Two on the one field are any; with another field, all.
        #expect(shown([try Self.reblogsOf("ada"), try Self.reblogsOf("cyd")], held.all) == ["900"])
        #expect(shown([try Self.reblogsOf("ada"), .field("reblog", is: .flag(false), in: .every)], held.all).isEmpty)
        // Asked of the item: its value is nothing on a post, a handle on a reblog whose post is in hand.
        #expect(held.post.value(of: "reblogOf", reblogged: held.post) == nil)
        #expect(held.reblog.value(of: "reblogOf", reblogged: held.post) == .text("ada@\(Self.host)"))
        #expect(held.reblog.value(of: "reblogOf") == nil)
        #expect(held.reblog.value(of: "reblogOf", reblogged: held.reblog) == nil, "a reblog is not what a reblog reblogs")
        let elsewhere = Note(
            id: held.post.id, source: Source(host: "other.example", kind: .mastodon), author: "Ada", handle: "@ada@\(Self.host)",
            body: "x", postedAt: Self.origin, categories: []
        )
        #expect(held.reblog.value(of: "reblogOf", reblogged: elsewhere) == nil, "only a post of the reblog's own source is what it reblogs")
    }

    @Test("A reblog whose post is not held says nothing of whose post it reblogs: no rule on that shows it or hides it; a rule on an author is asked of who reblogged, as ever")
    func anUnheldReblog() throws {
        let held = try Self.held()
        let without = [held.reblog, held.own]
        #expect(shown([try Self.reblogsOf("ada", effect: .exclude)], without) == ["900", "8"], "not hidden: nothing says whose post it is")
        #expect(shown([try Self.reblogsOf("ada")], without).isEmpty, "and not shown")
        let hideAda = Rule.author("ada@\(Self.host)", in: .every, effect: .exclude, sources: [Self.source])
        #expect(shown([hideAda], without) == ["900"], "Ada's own row goes; the reblog is Bob's")
        let hideBob = Rule.author("bob@\(Self.host)", in: .every, effect: .exclude, sources: [Self.source])
        #expect(shown([hideBob], without) == ["8"])
        let showAda = Rule.author("ada@\(Self.host)", in: .every, sources: [Self.source])
        #expect(shown([showAda], without) == ["8"])
    }

    @Test("A post held from before, which arrived as somebody's reblog, and a forum's item say nothing of whose post they reblog: neither is shown by such a rule nor hidden by one")
    func legacyAndForumSayNothing() throws {
        let legacy = try Self.legacy()
        let forum = Source(host: "f.example", kind: .discuz)
        let topic = Note(
            id: "f.example/t/1", source: forum, author: "Ada", handle: "ada@f.example", body: "a topic",
            postedAt: Self.origin, categories: [.board(id: "2")], boostedBy: "Bob"
        )
        #expect(legacy.value(of: "reblogOf", reblogged: legacy) == nil && topic.value(of: "reblogOf", reblogged: topic) == nil)
        for who in ["ada", "bob"] {
            let hide = try #require(Rule.field("reblogOf", is: .text("\(who)@\(Self.host)"), in: .every, effect: .exclude))
            let show = try #require(Rule.field("reblogOf", is: .text("\(who)@\(Self.host)"), in: .every))
            for rule in [hide, show] {
                let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: [rule]), sources: [Self.source, forum])
                let all = [legacy, topic]
                #expect(timeline.shown(all, TextIndex(all)).count == (rule.effect == .exclude ? 2 : 0))
            }
        }
        let forumHandle = try #require(Rule.field("reblogOf", is: .text("ada@f.example"), in: .every))
        #expect(CompiledTimeline(TimelineDefinition(name: "t", rules: [forumHandle]), sources: [forum]).status(of: forumHandle) == .missingField)
    }

    @Test("A rule on words is asked of the post reblogged: an include finds the reblog by them, and a hide takes it with the post")
    func wordsAreThePosts() throws {
        let held = try Self.held()
        #expect(shown([.keyword("post 7", in: .every)], held.all) == ["900", "7"])
        #expect(shown([.keyword("post 7", in: .every, effect: .exclude)], held.all) == ["8"])
        #expect(shown([.keyword("post 8", in: .every)], held.all) == ["8"])
    }

    @Test("A reblog whose post is not held matches no rule on words, shown or hidden; a rule on its source, its category or who reblogged still reaches it")
    func unheldMatchesNoWords() throws {
        let held = try Self.held()
        let without = [held.reblog, held.own]
        #expect(shown([.keyword("cats", in: .every)], without) == ["8"])
        #expect(shown([.keyword("cats", in: .every, effect: .exclude)], without) == ["900"])
        #expect(shown([.source(Self.host)], without) == ["900", "8"])
        #expect(shown([.category(.home, in: .every, sources: [Self.source])], without) == ["900", "8"])
    }

    @Test("A rule on a category is asked of the reblog as of any listed item: Home shows the reblog, and not the post it brought")
    func categoryIsTheReblogs() throws {
        let held = try Self.held()
        #expect(shown([.category(.home, in: .every, sources: [Self.source])], held.all) == ["900", "8"])
    }

    @Test("A rule on a field of a post — its language, its cover — is asked of the post reblogged")
    func fieldsAreThePosts() throws {
        let covered = try Self.arrival(Self.reblog("901", of: Self.status("8", extra: #","sensitive":true"#)))
        let held = try Self.held()
        let all = held.all + [covered.item]
        #expect(shown([.field("language", is: .option("en"), in: .every)], all) == ["900", "901", "7", "8"])
        #expect(shown([.field("covered", is: .flag(true), in: .every, effect: .exclude)], all) == ["900", "7"])
        #expect(shown([.field("language", is: .option("en"), in: .every)], [held.reblog]) == [], "nothing held to ask")
    }

    // MARK: - Whether an item is a reblog

    @Test("Every Mastodon item says whether it is a reblog: a reblog yes; a post no, and so a post held from before that arrived as somebody's reblog; an item whose source declares no such field says nothing")
    func whatEachAnswers() throws {
        let held = try Self.held()
        #expect(held.reblog.value(of: "reblog") == .flag(true))
        #expect(held.post.value(of: "reblog") == .flag(false))
        #expect(try Self.legacy().value(of: "reblog") == .flag(false), "it is the post")
        let forum = Source(host: "forum.example", kind: .discourse)
        let topic = Note(id: "t", source: forum, author: "Eve", handle: "@eve@forum.example", body: "x", postedAt: Self.origin, categories: [])
        #expect(topic.value(of: "reblog") == nil)
        // Even a forum row that claims to reblog: its kind of source declares no such field.
        let odd = Note(id: "o", source: forum, author: "Eve", handle: "", body: "", postedAt: Self.origin, categories: [], refs: [Reference(kind: .reblogs, id: "t")])
        #expect(odd.isReblog && odd.value(of: "reblog") == nil)
    }

    @Test("A hide on reblogs takes the reblog's row and leaves the post's own row: the post is shown once; showing only reblogs shows no post for having been reblogged")
    func hidingAndShowingReblogs() throws {
        let held = try Self.held()
        let hide = try #require(Rule.field("reblog", is: .flag(true), in: .every, effect: .exclude))
        #expect(shown([hide], held.all) == ["7", "8"], "the post reblogged is still there, once, and so is the other")
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: [hide]), sources: [Self.source])
        #expect(timeline.verdict(held.reblog, TextIndex(held.all), reblogged: held.post) == .hidden(by: hide.id))
        #expect(timeline.verdict(held.post, TextIndex(held.all)) == .shown)
        #expect(shown([.field("reblog", is: .flag(true), in: .every)], held.all) == ["900"])
        #expect(shown([.field("reblog", is: .flag(false), in: .every)], held.all) == ["7", "8"])
        #expect(shown([.field("reblog", is: .flag(false), in: .every, effect: .exclude)], held.all) == ["900"])
        // Asked of the row itself, held post or not.
        #expect(shown([hide], [held.reblog, held.own]) == ["8"])
        #expect(shown([.field("reblog", is: .flag(true), in: .every)], [held.reblog]) == ["900"])
        // A post held from before, which arrived as a reblog, is a post: the hide leaves it.
        #expect(shown([hide], [try Self.legacy()]) == ["7"])
    }

    @Test("Whether it is a reblog is asked of the row; every other field is still asked of the post it reblogs — beside each other in one timeline")
    func theOtherFieldsStillAskThePost() throws {
        let japanese = try Self.arrival(Self.reblog("901", of: Self.status("8").replacingOccurrences(of: #""language":"en""#, with: #""language":"ja""#)))
        let english = try Self.held()
        let all = english.all.filter { $0.statusID != "8" } + [japanese.item, try #require(japanese.reblogged)]
        #expect(shown([.field("language", is: .option("ja"), in: .every)], all) == ["901", "8"], "the reblog by the language of its post")
        #expect(shown([.field("language", is: .option("ja"), in: .every), .field("reblog", is: .flag(true), in: .every)], all) == ["901"], "reblogs of posts in Japanese")
        #expect(shown([.field("language", is: .option("ja"), in: .every), .field("reblog", is: .flag(true), in: .every, effect: .exclude)], all) == ["8"], "posts in Japanese, less their reblogs")
        #expect(shown([.field("language", is: .option("ja"), in: .every, effect: .exclude)], all) == ["900", "7"])
    }

    @Test("An item whose source declares no such field neither matches a rule on reblogs nor is hidden by one")
    func aSourceThatDeclaresNoSuchField() throws {
        let forum = Source(host: "forum.example", kind: .discourse)
        let topic = Note(id: "t", source: forum, author: "Eve", handle: "@eve@forum.example", body: "x", postedAt: Self.origin, categories: [], statusID: "t")
        let held = try Self.held()
        let all = held.all + [topic]
        func shownHere(_ rule: Rule?) -> Set<String> {
            let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: [rule].compactMap { $0 }), sources: [Self.source, forum])
            return Set(timeline.shown(all, TextIndex(all)).compactMap(\.statusID))
        }
        #expect(shownHere(.field("reblog", is: .flag(true), in: .every, effect: .exclude)) == ["7", "8", "t"], "not hidden")
        #expect(shownHere(.field("reblog", is: .flag(false), in: .every, effect: .exclude)) == ["900", "t"], "nor by the other answer")
        #expect(shownHere(.field("reblog", is: .flag(false), in: .every)) == ["7", "8"], "and matched by neither")
        #expect(shownHere(.field("reblog", is: .flag(true), in: .every)) == ["900"])
    }

    @Test("A rule on reblogs is made for a yes or a no and nothing else, and is stored in the shape every field rule is")
    func theRule() {
        #expect(Rule.field("reblog", is: .flag(true), in: .every)?.kind == .field(name: "reblog", is: .flag(true), in: .every))
        #expect(Rule.field("reblog", is: .option("yes"), in: .every) == nil)
        #expect(Rule.field("reblog", is: .flag(true), in: .source(host: Self.host)) != nil)
    }

    @Test("The text index is each note's own: a reblog's rules are right when its post lands, changes and goes, with the index reused across each")
    func indexIsRightAsThingsMove() throws {
        let held = try Self.held()
        let rule = [Rule.keyword("dogs", in: .every)]
        func shownReusing(_ notes: [Note], _ old: TextIndex?) -> (Set<String>, TextIndex) {
            let index = TextIndex(notes, reusing: old)
            let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: rule.compactMap { $0 }), sources: [Self.source])
            return (Set(timeline.shown(notes, index).compactMap(\.statusID)), index)
        }
        var (found, index) = shownReusing([held.reblog], nil)
        #expect(found.isEmpty)
        (found, index) = shownReusing([held.reblog, held.post], index)
        #expect(found.isEmpty, "the post landed, and says cats")
        let changed = Note(
            id: held.post.id, source: Self.source, author: "Ada", handle: held.post.handle, body: "now about dogs",
            postedAt: held.post.postedAt, categories: [], statusID: "7"
        )
        (found, index) = shownReusing([held.reblog, changed], index)
        #expect(found == ["900", "7"], "the post changed")
        #expect(index.folded == 1, "and only the post was folded again")
        (found, index) = shownReusing([held.reblog], index)
        #expect(found.isEmpty, "the post went")
    }

    @Test("A search finds a reblog by who reblogged and by the words, tags and author of the post it reblogs — also where a timeline's rules left that post out, and as the post lands, changes and goes")
    func searchReadsBoth() throws {
        let held = try Self.held()
        func found(_ text: String, in notes: [Note], among all: [Note], index: SearchIndex) throws -> Set<String> {
            let search = try #require(NoteSearch(text, sources: [Self.source]))
            return Set(search.found(notes, index, among: all).compactMap(\.statusID))
        }
        let index = SearchIndex(held.all)
        #expect(try found("bob", in: held.all, among: held.all, index: index) == ["900"])
        #expect(try found("post 7", in: held.all, among: held.all, index: index) == ["900", "7"])
        #expect(try found("ada", in: held.all, among: held.all, index: index) == ["900", "7", "8"])
        // The timeline in front let the reblog through and not the post: it is still found by the post's words.
        #expect(try found("post 7", in: [held.reblog], among: held.all, index: index) == ["900"])
        // An index built before the post landed, and after it went.
        #expect(try found("post 7", in: [held.reblog, held.post], among: [held.reblog, held.post], index: SearchIndex([held.reblog])) == ["900", "7"])
        #expect(try found("post 7", in: [held.reblog], among: [held.reblog], index: index).isEmpty)
    }

    // MARK: - The same reblog, and never its post

    @Test("The same reblog through two sources is one; a reblog is never one with the post it reblogs, nor with a post another source named alike")
    func gathered() throws {
        let other = Source(host: "other.example", kind: .mastodon)
        let here = try Self.arrival(Self.reblog("900", of: Self.status("7")))
        let there = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.reblog("55", of: Self.status("31")).replacingOccurrences(of: "statuses/55/activity", with: "statuses/900/activity").utf8))
            .arrival(source: other, categories: [.home], sent: .now())
        #expect(there.item.id == here.item.id, "the premise: both servers state the reblog's one name")
        let post = try #require(here.reblogged)
        // A post from the other source under the reblog's own name.
        let posing = Note(id: here.item.id, source: other, author: "Eve", handle: "@eve@other.example", body: "", postedAt: Self.origin, categories: [])
        let groups = SamePost.gathered([here.item, post, there.item, posing])
        #expect(groups.map { $0.map(\.source.host) } == [[Self.host, "other.example"], [Self.host], ["other.example"]])
        #expect(groups[0].allSatisfy { $0.isReblog })
    }
}
