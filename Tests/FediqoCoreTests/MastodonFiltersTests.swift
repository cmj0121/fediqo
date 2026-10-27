import Foundation
import Testing
@testable import FediqoCore

@Suite("The person's filters at a Mastodon, and what a post says of them")
struct MastodonFiltersTests {
    private let host = MastodonFixture.host

    private static func status(_ id: String, filtered: String?) -> String {
        let said = filtered.map { #","filtered":\#($0)"# } ?? ""
        return #"{"id":"\#(id)","uri":"https://social.example/users/ada/statuses/\#(id)","created_at":"2026-10-27T00:00:00.000Z","content":"<p>pie</p>","account":{"username":"ada","acct":"ada","display_name":"Ada"}\#(said)}"#
    }

    private func note(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: Source(host: host, kind: .mastodon), category: .home, sent: .now())
    }

    @Test("A post says which filters caught it, each as the source named it; none said is nothing, an empty list is none")
    func filtered() throws {
        let warned = try note(Self.status("1", filtered: MastodonFilterCaptures.warned))
        let hit = try #require(warned.serverFiltered?.first)
        #expect(hit.filterID == "1" && hit.title == "Fruit warned" && hit.action == .warn)
        #expect(hit.context == ["home", "public", "thread"])
        #expect(hit.expiresAt != nil)
        #expect(try note(Self.status("2", filtered: MastodonFilterCaptures.hidden)).serverFiltered?.first?.action == .hide)
        #expect(try note(Self.status("3", filtered: MastodonFilterCaptures.blurred)).serverFiltered?.first?.action == .blur)
        #expect(try note(Self.status("4", filtered: "[]")).serverFiltered == [])
        #expect(try note(Self.status("5", filtered: nil)).serverFiltered == nil)
        #expect(try note(Self.status("6", filtered: #"[{"nonsense":1}, "x"]"#)).serverFiltered == [], "an entry that does not read is passed over")
    }

    @Test("What stands over a post is weighed where it is shown and when: hiding before warning before blurring, nothing lapsed or elsewhere")
    func standing() {
        let now = Date()
        func hit(_ action: ServerFilterAction, _ context: Set<String>, lapsed: Bool = false) -> ServerFilterHit {
            ServerFilterHit(filterID: action.word, title: action.word, action: action, context: context,
                            expiresAt: lapsed ? now.addingTimeInterval(-1) : nil)
        }
        let hits = [hit(.blur, ["home"]), hit(.warn, ["public"]), hit(.hide, ["thread"])]
        #expect(hits.standing(in: ServerFilterHit.timelines, at: now)?.action == .warn)
        #expect(hits.standing(in: ["thread"], at: now)?.action == .hide)
        #expect([hit(.hide, ["home"], lapsed: true)].standing(in: ["home"], at: now) == nil)
        #expect([hit(.unknown("explode"), ["home"])].standing(in: ["home"], at: now)?.action == .unknown("explode"))
    }

    @Test("A post's word on its filters is kept by the last read that says, and not taken back by one that says nothing")
    func landing() async throws {
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        await store.ingest([try note(Self.status("1", filtered: MastodonFilterCaptures.warned))])
        let key = NoteKey(host: host, id: "https://social.example/users/ada/statuses/1")
        #expect(await store.note(key)?.serverFiltered?.first?.action == .warn)
        await store.ingest([try note(Self.status("1", filtered: nil))])
        #expect(await store.note(key)?.serverFiltered?.first?.action == .warn, "an unsigned read says nothing of it")
        await store.ingest([try note(Self.status("1", filtered: "[]"))])
        #expect(await store.note(key)?.serverFiltered == [], "the filter removed since, said by the next read")
    }

    @Test("The filters read as the source keeps them: words, places, action, lasting, keywords and how many posts")
    func list() async throws {
        let server = FixtureSender(["/api/v2/filters": .json("[" + MastodonFilterCaptures.made + "," + MastodonFilterCaptures.changed + "]")])
        let filters = try await MastodonFilters(door: door(server)).list()
        #expect(filters.count == 2)
        #expect(filters[0].keywords == [.init(id: "1", keyword: "apple", wholeWord: true), .init(id: "2", keyword: "pear", wholeWord: false)])
        #expect(filters[0].expiresAt != nil && filters[1].expiresAt == nil)
        #expect(filters[1].statuses == 1 && filters[1].context == ["home"])
    }

    @Test("A change names each keyword by its place: kept and changed, new, and removed after them; for good is said as nothing")
    func form() throws {
        let was = MastodonFilters.decoded(MastodonFilterCaptures.made)
        let draft = ServerFilterDraft(
            title: "Fruit", context: ["public", "home"], action: .hide, lasts: nil,
            keywords: [.init(id: "1", keyword: "apples", wholeWord: false), .init(keyword: "plum", wholeWord: true)]
        )
        let form = MastodonFilters.form(draft, was: try #require(was))
        #expect(form.map { "\($0.0)=\($0.1)" } == [
            "title=Fruit", "context[]=home", "context[]=public", "filter_action=hide", "expires_in=",
            "keywords_attributes[0][id]=1", "keywords_attributes[0][keyword]=apples", "keywords_attributes[0][whole_word]=false",
            "keywords_attributes[1][keyword]=plum", "keywords_attributes[1][whole_word]=true",
            "keywords_attributes[2][id]=2", "keywords_attributes[2][_destroy]=true",
        ])
    }

    @Test("A filter the source refuses says so and nothing else; removing one already gone is done")
    func refusals() async throws {
        let refusing = FixtureSender(["/api/v2/filters": .json(#"{"error":"Validation failed: Title can't be blank"}"#, status: 422)])
        let draft = ServerFilterDraft(title: "", context: ["home"], action: .warn, keywords: [])
        await #expect(throws: MastodonFilterRefused.self) { _ = try await MastodonFilters(door: door(refusing)).make(draft) }
        let filter = ServerFilter(id: "9", title: "x", context: ["home"], action: .warn, expiresAt: nil, keywords: [])
        // A change refused as the real server refuses it, which the door names unprocessable.
        let unchanged = FixtureSender(["/api/v2/filters/9": .json(#"{"error":"Validation failed: Title can't be blank"}"#, status: 422)])
        await #expect(throws: MastodonFilterRefused.self) { _ = try await MastodonFilters(door: door(unchanged)).change(filter, to: draft) }
        let gone = FixtureSender(["/api/v2/filters/9": .json(#"{"error":"Record not found"}"#, status: 404)])
        try await MastodonFilters(door: door(gone)).remove(filter)
    }

    private func door(_ server: FixtureSender) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        return MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
    }
}

extension MastodonFilters {
    /// One filter as the source sent it.
    static func decoded(_ json: String) -> ServerFilter? {
        (try? MastodonJSON.decoder.decode(FilterDTO.self, from: Data(json.utf8)))?.filter
    }
}
