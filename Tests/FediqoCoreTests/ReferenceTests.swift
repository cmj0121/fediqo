import Foundation
import Testing
@testable import FediqoCore

/// What an item refers to (#290, #293), as a note carries it beside its `reply` and `quote`:
/// the references those two state, read both ways, bounded, and following the note through
/// every way one is made from another — with nothing the person can see changed.
@Suite("What an item refers to")
struct ReferenceTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private static func note(
        _ id: String = "1", body: String = "hello", reply: Reply? = nil, quote: Quote? = nil,
        boostedBy: String? = nil, refs: [Reference]? = nil, refsDue: Bool = false, editedAt: Date? = nil
    ) -> Note {
        Note(
            id: "https://one.example/\(id)", source: source, author: "Ada", handle: "@ada", body: body,
            postedAt: origin, categories: [.home], reply: reply, boostedBy: boostedBy, spoiler: "",
            statusID: id, quote: quote, editedAt: editedAt, refs: refs, refsDue: refsDue
        )
    }

    private static func quoted(_ id: String) -> QuotedPost {
        QuotedPost(note("q\(id)"))
    }

    private static func status(_ extra: String) -> String {
        """
        {"id":"9","uri":"https://one.example/users/ada/statuses/9","created_at":"2024-06-01T00:00:00.000Z",
         "content":"<p>hello</p>","visibility":"public"\(extra),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func read(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .home, sent: .now())
    }

    // MARK: - What reply and quote state

    @Test("An item's references are what its reply and its quote state: whom and what it answers, what it quotes and where that stands — and nothing where it says neither")
    func derived() {
        #expect(Self.note().refs.isEmpty)
        let answer = Self.note(reply: Reply(handle: "@bob@two.example", inReplyToId: "41"))
        #expect(answer.refs == [Reference(kind: .answers, statusID: "41", handle: "@bob@two.example")])
        // A reply whose parent was never named is still an answer, to something not named.
        #expect(Self.note(reply: Reply()).refs == [Reference(kind: .answers)])

        let quote = Quote(state: .accepted, post: Self.quoted("7"), statusID: "77")
        #expect(Self.note(quote: quote).refs == [
            Reference(kind: .quotes, id: "https://one.example/q7", statusID: "77", state: .accepted),
        ])
        #expect(Self.note(quote: Quote(state: .pending)).refs == [Reference(kind: .quotes, state: .pending)])

        let both = Self.note(reply: Reply(handle: "@bob", inReplyToId: "41"), quote: quote)
        #expect(both.refs.map(\.kind) == [.answers, .quotes])
    }

    @Test("A row held from before, which arrived as a boost, is the post and no reblog; a reblog a timeline lists is an item whose one reference names the post, and the post's own references stay the post's")
    func aReblogRefersToThePost() throws {
        let boosted = Self.note(boostedBy: "Bob")
        #expect(boosted.refs.isEmpty && !boosted.isReblog)
        let wrapper = """
        {"id":"500","uri":"https://one.example/users/bob/statuses/500/activity","created_at":"2024-06-02T00:00:00.000Z",
         "content":"","visibility":"public","account":{"username":"bob","acct":"bob","display_name":"Bob"},
         "reblog":\(Self.status(#","in_reply_to_id":"41""#))}
        """
        let read = try Self.read(wrapper)
        #expect(read.boostedBy == nil && !read.isReblog, "read as the post it carries, saying nothing of who reblogged")
        #expect(read.refs == [Reference(kind: .answers, statusID: "41")], "the post's own reference, not the boost's")
        let arrived = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(wrapper.utf8))
            .arrival(source: Self.source, categories: [.home], sent: .now())
        #expect(arrived.item.refs == [
            Reference(kind: .reblogs, id: "https://one.example/users/ada/statuses/9", statusID: "9"),
        ])
        #expect(arrived.item.reblogKey == arrived.reblogged?.key)
        #expect(arrived.reblogged?.refs == [Reference(kind: .answers, statusID: "41")])
        #expect(Self.note(refs: [Reference(kind: .reblogs, id: "https://one.example/1")]).isReblog)
    }

    @Test("What a status says it answers and quotes is on the note as references, and they are the ones its reply and quote state")
    func offTheWire() throws {
        let read = try Self.read(Self.status(#","in_reply_to_id":"41","mentions":[{"id":"3","acct":"bob@two.example","username":"bob"}]"#))
        #expect(read.refs == Reference.derived(reply: read.reply, quote: read.quote))
        #expect(read.refs.first?.kind == .answers && read.refs.first?.statusID == "41")
        #expect(try Self.read(Self.status("")).refs.isEmpty)
        #expect(try Self.read(Self.status("")).refsDue == false, "nothing is asked for yet")
    }

    // MARK: - Read back the other way

    @Test("A reference says back the reply or the quote it came from; a quote without the quoted post's copy, which is the target's own")
    func bothWays() {
        let reply = Reply(handle: "@bob@two.example", inReplyToId: "41")
        let quote = Quote(state: .accepted, post: Self.quoted("7"), statusID: "77")
        let refs = Reference.derived(reply: reply, quote: quote)
        #expect(Reply(refs[0]) == reply)
        #expect(Quote(refs[1]) == Quote(state: .accepted, statusID: "77"))
        #expect(Quote(refs[1])?.post == nil)
        #expect(Reply(refs[1]) == nil && Quote(refs[0]) == nil, "each kind is its own")
        #expect(Reply(Reference(kind: .reblogs, id: "x")) == nil)
        for state in Quote.State.allCases {
            let shell = Quote(state: state)
            #expect(Quote(Reference.derived(reply: nil, quote: shell)[0]) == shell)
        }
    }

    @Test("What belongs to one kind is not carried on another: a handle only on an answer, a state only on a quote")
    func ownFactsOnly() {
        let wrong = Reference(kind: .reblogs, id: "x", handle: "@bob", state: .accepted)
        #expect(wrong.handle == nil && wrong.state == nil)
        #expect(Reference(kind: .quotes, handle: "@bob", state: .pending).handle == nil)
        #expect(Reference(kind: .answers, handle: "@bob", state: .pending).state == nil)
    }

    // MARK: - Bounded

    @Test("An item holds a bounded number of references, each with names no longer than a name is, and none twice")
    func bounded() {
        let many = (0 ..< 50).map { Reference(kind: .quotes, id: "https://one.example/\($0)") }
        #expect(Self.note(refs: many).refs.count == Reference.most)
        #expect(Self.note(refs: many).refs == Array(many.prefix(Reference.most)), "the first, in order")

        let long = String(repeating: "x", count: Reference.longest + 1)
        let kept = Reference(kind: .answers, statusID: String(repeating: "x", count: Reference.longest))
        #expect(Self.note(refs: [
            Reference(kind: .answers, id: long), Reference(kind: .answers, statusID: long),
            Reference(kind: .answers, handle: long), kept,
        ]).refs == [kept])

        // Bytes, not characters: one letter under a great many combining marks is one character.
        let stacked = "e" + String(repeating: "\u{301}", count: Reference.longest)
        #expect(stacked.count == 1 && stacked.utf8.count > Reference.longest)
        #expect(Self.note(refs: [Reference(kind: .answers, handle: stacked), kept]).refs == [kept])
        let wide = String(repeating: "字", count: Reference.longest / 3)
        #expect(Self.note(refs: [Reference(kind: .answers, statusID: wide)]).refs.count == 1, "as long as a name may be, in bytes")
        #expect(Self.note(refs: [Reference(kind: .answers, statusID: wide + "字")]).refs.isEmpty)

        let same = Reference(kind: .reblogs, id: "a")
        #expect(Reference.bounded([same, same, Reference(kind: .reblogs, id: "b")]).count == 2, "none said twice")
        #expect(Self.note(refs: [same, same, Reference(kind: .reblogs, id: "b")]).refs == [same], "and an item reblogs one thing: the first it names")
        #expect(Reference.bounded([]).isEmpty)
    }

    // MARK: - Following the note

    @Test("A note made from another carries the references its own reply and quote state: read again with a quote it had not, the reference arrives with it")
    func followsTheNote() async {
        let store = ItemStore(sources: [Self.source], notes: [Self.note(reply: Reply(inReplyToId: "41"))])
        let quote = Quote(state: .accepted, post: Self.quoted("7"), statusID: "77")
        await store.refresh([Self.note(reply: Reply(inReplyToId: "41"), quote: quote)], ifSourceHere: Self.source.host)
        var held = await store.all().first
        #expect(held?.refs.map(\.kind) == [.answers, .quotes])
        #expect(held?.refs == Reference.derived(reply: held?.reply, quote: held?.quote))

        // A reload's copy fills in what the held one never said, and the references follow.
        let plain = ItemStore(sources: [Self.source], notes: [Self.note()])
        await plain.ingest([Self.note(quote: quote)], ifSourceHere: Self.source.host)
        held = await plain.all().first
        #expect(held?.refs.map(\.kind) == [.quotes])
        #expect(held?.refs == Reference.derived(reply: held?.reply, quote: held?.quote))
    }

    @Test("Whether an item's references are still to be asked for is this device's own: no reload, no reading again, no later copy and no mark taken off moves it")
    func dueIsThisDevicesOwn() async {
        #expect(Self.note().refsDue == false, "off is the rest state")
        let store = ItemStore(sources: [Self.source], notes: [Self.note(refsDue: true)], keepingWhatIsOwed: true)
        func due() async -> Bool? { await store.all().first?.refsDue }

        await store.ingest([Self.note(body: "hello", refsDue: false)], ifSourceHere: Self.source.host)
        #expect(await due() == true, "a reload's copy took it off")
        await store.refresh([Self.note(body: "edited", refsDue: false)], ifSourceHere: Self.source.host)
        #expect(await due() == true, "reading the post again took it off")
        await store.ingest([Self.note(body: "later", refsDue: false, editedAt: Self.origin.addingTimeInterval(60))], ifSourceHere: Self.source.host)
        #expect(await due() == true, "a later copy took it off")
        await store.refresh([Self.note(body: "stale", refsDue: false)], ifSourceHere: Self.source.host)
        #expect(await due() == true, "an earlier copy took it off")
        #expect(await store.forgetReaderMarks(host: Self.source.host) == false)
        await store.setKept(true, for: NoteKey(host: Self.source.host, id: "https://one.example/1"))
        #expect(await due() == true)

        // And the other way: a copy that says it is due does not make a held one so.
        let settled = ItemStore(sources: [Self.source], notes: [Self.note()])
        await settled.ingest([Self.note(body: "x", refsDue: true)], ifSourceHere: Self.source.host)
        await settled.refresh([Self.note(body: "y", refsDue: true)], ifSourceHere: Self.source.host)
        #expect(await settled.all().first?.refsDue == false)
    }

    @Test("A store read back brings no row still owing a load: what another device had yet to ask for is not this device's to ask")
    func aStoreReadBackOwesNothing() async {
        let store = ItemStore(sources: [Self.source], notes: [Self.note("0", refsDue: true)], keepingWhatIsOwed: true)
        #expect(await store.all().first?.refsDue == true, "the premise: a row that owes")
        let reblog = [Reference(kind: .reblogs, id: "https://one.example/9")]
        await store.replace(sources: [Self.source], notes: [
            Self.note("1", reply: Reply(inReplyToId: "41"), refsDue: true), Self.note("2", refs: reblog, refsDue: true), Self.note("3"),
        ])
        let now = await store.all()
        #expect(now.count == 3 && now.allSatisfy { !$0.refsDue })
        #expect(now.first { $0.statusID == "2" }?.refs == reblog, "and nothing else of the row is touched")
    }

    @Test("A store opened at launch brings no row still owing a load: nothing asks for what an item refers to yet, so nothing would ever take the mark off")
    func aLaunchOwesNothing() async {
        let reblog = Note(
            id: "r", source: Self.source, author: "Bob", handle: "@bob", body: "", postedAt: Self.origin,
            categories: [.home], refs: [Reference(kind: .reblogs, id: "https://one.example/9")], refsDue: true
        )
        let store = ItemStore(sources: [Self.source], notes: [Self.note("0", refsDue: true), reblog])
        #expect(await store.all().allSatisfy { !$0.refsDue })
        #expect(await store.all().first { $0.isReblog }?.refs == reblog.refs, "and nothing else of the row is touched")
    }

    @Test("Two notes that differ only in what they refer to, or in whether that is still to be asked for, are not the same note")
    func partOfWhatANoteIs() {
        #expect(Self.note() != Self.note(refs: [Reference(kind: .reblogs, id: "x")]))
        #expect(Self.note() != Self.note(refsDue: true))
        #expect(Self.note(reply: Reply(inReplyToId: "41")) == Self.note(
            reply: Reply(inReplyToId: "41"), refs: [Reference(kind: .answers, statusID: "41")]
        ))
    }
}
