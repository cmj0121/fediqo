import Foundation
import Testing
@testable import FediqoCore

/// #293 in the store: an item that first arrives referring to a post this device does not hold
/// owes one load — of that post, by its source's own id for it — and what the load brings is an
/// item like any other, which owes nothing in turn.
@Suite("What an item refers to is loaded once")
struct ReferenceLoadTests {
    private static let host = "one.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private static func post(
        _ id: String, at days: Double = 0, answering parent: String? = nil, quoting quoted: Quote? = nil,
        categories: Set<FediqoCore.Category> = [.home], by source: Source = source
    ) -> Note {
        Note(
            id: "https://\(source.host)/p/\(id)", source: source, author: "Ada", handle: "@ada@\(source.host)", body: "post \(id)",
            postedAt: origin.addingTimeInterval(days * 86400), categories: categories,
            reply: parent.map { Reply(handle: "@bob@\(source.host)", inReplyToId: $0) }, statusID: id, quote: quoted
        )
    }

    private func store(_ notes: [Note] = []) async -> ItemStore {
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(notes)
        return store
    }

    private func held(_ store: ItemStore, _ id: String) async -> Note? {
        await store.all().first { $0.statusID == id }
    }

    // MARK: - What is owed

    @Test("A reply that arrives with the post it answers not held owes one load: that post, by its source's own id for it")
    func aReplyOwesItsParent() async {
        let store = await store([Self.post("2", answering: "1")])
        #expect(await held(store, "2")?.refsDue == true)
        #expect(await store.owed(host: Self.host) == [
            ItemStore.Owed(item: Self.post("2").key, kind: .answers, statusID: "1", asReader: true),
        ])
        #expect(await store.owed(host: "elsewhere.example").isEmpty, "nothing is owed of a host that is not a source here")
    }

    @Test("Nothing is owed where the post is held already, arrives in the same landing, or the item refers to nothing")
    func nothingToLoad() async {
        let holding = await store([Self.post("1")])
        await holding.ingest([Self.post("2", answering: "1")])
        #expect(await held(holding, "2")?.refsDue == false)
        let together = await store([Self.post("2", answering: "1"), Self.post("1")])
        #expect(await together.owed(host: Self.host).isEmpty)
        #expect(await together.all().allSatisfy { !$0.refsDue })
        let plain = await store([Self.post("3")])
        #expect(await held(plain, "3")?.refsDue == false)
    }

    @Test("A post that quotes one its source did not send along owes that post; one sent along is taken in at no request, and owes nothing of its own even where it answers another")
    func quotes() async {
        let bare = await store([Self.post("5", quoting: Quote(state: .accepted, statusID: "4"))])
        #expect(await bare.owed(host: Self.host).map(\.kind) == [.quotes])
        #expect(await bare.owed(host: Self.host).map(\.statusID) == ["4"])
        // A quote that may not be shown is nothing to ask for.
        let pending = await store([Self.post("5", quoting: Quote(state: .pending))])
        #expect(await pending.owed(host: Self.host).isEmpty)

        let quoted = QuotedPost(Self.post("4", at: -30, answering: "3"))
        let whole = await store([Self.post("5", quoting: Quote(state: .accepted, post: quoted))])
        #expect(await whole.owed(host: Self.host).isEmpty)
        #expect(await held(whole, "4")?.refsDue == false, "what was brought for an item owes nothing: only the direct target is ever loaded")
        #expect(await held(whole, "4")?.categories.isEmpty == true)
    }

    @Test("A reblog owes nothing, and neither does the post it brought, though that post answers another")
    func reblogs() async {
        let target = Self.post("7", at: -30, answering: "6", categories: [])
        let reblog = Note(
            id: "https://\(Self.host)/r/9", source: Self.source, author: "Bob", handle: "@bob@\(Self.host)", body: "",
            postedAt: Self.origin, categories: [.home], statusID: "9", refs: [Reference(kind: .reblogs, id: target.id, statusID: "7")]
        )
        let store = await store([reblog, target])
        #expect(await store.owed(host: Self.host).isEmpty)
        #expect(await store.all().allSatisfy { !$0.refsDue })
        // A reblog whose post did not come is not a thing to ask for either.
        let alone = await self.store([reblog])
        #expect(await alone.owed(host: Self.host).isEmpty)
        // The same post arriving on its own, through a timeline, is an item that arrived.
        let own = await self.store([reblog, Self.post("7", at: -30, answering: "6")])
        #expect(await own.owed(host: Self.host).map(\.statusID) == ["6"])
    }

    @Test("Only a Mastodon's items owe a load, and a copy that says it owes one does not make it so")
    func whoOwes() async {
        let forum = Source(host: "forum.example", kind: .discourse)
        let store = ItemStore()
        await store.add(forum)
        await store.ingest([Self.post("2", answering: "1", by: forum)])
        #expect(await store.all().allSatisfy { !$0.refsDue })
        var claims = Self.post("3")
        claims.refsDue = true
        let mastodon = await self.store([claims])
        #expect(await held(mastodon, "3")?.refsDue == false)
    }

    // MARK: - What a load brings

    @Test("The post loaded is held as an ordinary item: at its own publish time, through no category, owing nothing though it answers another; the reply owes nothing more and names what it answers")
    func aLoadLands() async throws {
        let store = await store([Self.post("2", answering: "1")])
        let owed = try #require(await store.owed(host: Self.host).first)
        let parent = Self.post("1", at: -400, answering: "0", categories: [.public])
        await store.land(.held(parent), for: owed)

        let loaded = try #require(await held(store, "1"))
        #expect(loaded.postedAt == Self.origin.addingTimeInterval(-400 * 86400))
        #expect(loaded.categories.isEmpty && loaded.listed.isEmpty, "it came through no timeline, whatever the copy says")
        #expect(!loaded.refsDue, "what a loaded item refers to in turn is not followed")
        let reply = try #require(await held(store, "2"))
        #expect(!reply.refsDue)
        #expect(reply.refs == [Reference(kind: .answers, id: parent.id, statusID: "1", handle: "@bob@\(Self.host)")])
        #expect(await store.owed(host: Self.host).isEmpty)
        #expect(await held(store, "0") == nil, "the post before that one is not asked for")
    }

    @Test("Reading the same reply again asks for nothing more; letting the loaded post go and reading again does not bring it back")
    func once() async throws {
        let reply = Self.post("2", answering: "1")
        let store = await store([reply])
        let owed = try #require(await store.owed(host: Self.host).first)
        await store.land(.held(Self.post("1", at: -3)), for: owed)
        await store.ingest([reply])
        _ = await store.refresh([reply], ifSourceHere: Self.host)
        #expect(await store.owed(host: Self.host).isEmpty)

        await store.forget(Self.post("1").key)
        #expect(await held(store, "1") == nil)
        await store.ingest([reply])
        _ = await store.refresh([reply], ifSourceHere: Self.host)
        #expect(await held(store, "2")?.refsDue == false)
        #expect(await store.owed(host: Self.host).isEmpty, "let go later, it stays let go")
        #expect(await held(store, "2")?.refs.first?.id == Self.post("1").id, "and the reply still names what it answered")
    }

    @Test("A post its source says is gone settles what was owed: nothing is held, and it is not asked for again")
    func gone() async throws {
        let store = await store([Self.post("2", answering: "1")])
        let owed = try #require(await store.owed(host: Self.host).first)
        await store.land(.gone, for: owed)
        #expect(await store.all().count == 1)
        #expect(await held(store, "2")?.refsDue == false)
        await store.ingest([Self.post("2", answering: "1")])
        #expect(await store.owed(host: Self.host).isEmpty)
    }

    @Test("A load given up for the run leaves the item as it was and still owing: it says so for this run, is not listed to ask again, and a later run asks")
    func stalled() async throws {
        let store = await store([Self.post("2", answering: "1"), Self.post("4", answering: "3")])
        let owed = try #require(await store.owed(host: Self.host).first { $0.statusID == "1" })
        let before = try #require(await held(store, "2"))
        let drawn = await store.drawn
        await store.land(.stalled, for: owed)
        var after = try #require(await held(store, "2"))
        #expect(after.refsStalled && after.refsDue)
        after.refsStalled = false
        #expect(after == before, "nothing else of it moved")
        #expect(await store.drawn == drawn + 1, "and the row is drawn again, to say so")
        #expect(await store.owed(host: Self.host).map(\.statusID) == ["3"])

        // Written down, it still owes and says nothing of this run.
        let next = ItemStore(sources: [Self.source], notes: await store.snapshot().notes)
        #expect(await next.all().allSatisfy { !$0.refsStalled })
        #expect(Set(await next.owed(host: Self.host).map(\.statusID)) == ["1", "3"])

        await store.unstall(host: Self.host)
        #expect(Set(await store.owed(host: Self.host).map(\.statusID)) == ["1", "3"], "asked for again once the reader says so")
        #expect(await held(store, "2")?.refsStalled == false)
    }

    @Test("Only the post that was asked for is taken: one with another id, one from another source, and a reblog are not, and what was owed is settled all the same")
    func onlyWhatWasAsked() async throws {
        let elsewhere = Source(host: "two.example", kind: .mastodon)
        let reblog = Note(
            id: "https://\(Self.host)/r/1", source: Self.source, author: "Bob", handle: "@bob", body: "",
            postedAt: Self.origin, categories: [], statusID: "1", refs: [Reference(kind: .reblogs, id: "x")]
        )
        for wrong in [Self.post("99"), Self.post("1", by: elsewhere), reblog] {
            let store = await store([Self.post("2", answering: "1")])
            let owed = try #require(await store.owed(host: Self.host).first)
            await store.land(.held(wrong), for: owed)
            #expect(await store.all().map(\.statusID) == ["2"], "\(wrong.id) was taken in")
            #expect(await held(store, "2")?.refsDue == false)
            #expect(await held(store, "2")?.refs.first?.id == nil)
        }
    }

    @Test("A load that comes back for an item let go of meanwhile, or for a source removed, lands nowhere")
    func landsNowhere() async throws {
        let store = await store([Self.post("2", answering: "1")])
        let owed = try #require(await store.owed(host: Self.host).first)
        await store.forget(owed.item)
        await store.land(.held(Self.post("1")), for: owed)
        #expect(await store.all().isEmpty)

        let removed = await self.store([Self.post("2", answering: "1")])
        let stillOwed = try #require(await removed.owed(host: Self.host).first)
        await removed.remove(host: Self.host, keepingPosts: true)
        await removed.land(.held(Self.post("1")), for: stillOwed)
        #expect(await removed.all().map(\.statusID) == ["2"])
        #expect(await removed.owed(host: Self.host).isEmpty)
    }

    // MARK: - Settled on sight

    @Test("A post an item was waiting for that comes another way — a timeline brings it later, or a thread is read — settles what the item owed: it owes nothing, names the post, and is not listed to ask")
    func settledWhenItArrivesAnotherWay() async {
        for categories: Set<FediqoCore.Category> in [[.home], []] {
            let store = await store([Self.post("2", answering: "1")])
            #expect(await held(store, "2")?.refsDue == true, "the premise")
            await store.ingest([Self.post("1", at: -1, categories: categories)])
            let reply = await held(store, "2")
            #expect(reply?.refsDue == false, "nobody would ever have asked: the post is held")
            #expect(reply?.refs.first?.id == Self.post("1").id)
            #expect(await store.owed(host: Self.host).isEmpty)
        }
    }

    @Test("One load settles every item that was waiting on that post, whoever it was asked for")
    func oneLoadSettlesAll() async throws {
        let store = await store([Self.post("2", answering: "1"), Self.post("3", answering: "1"), Self.post("5", answering: "4")])
        let owed = try #require(await store.owed(host: Self.host).first { $0.item == Self.post("2").key })
        await store.land(.held(Self.post("1", at: -1)), for: owed)
        for waiting in ["2", "3"] {
            #expect(await held(store, waiting)?.refsDue == false)
            #expect(await held(store, waiting)?.refs.first?.id == Self.post("1").id)
        }
        #expect(await store.owed(host: Self.host).map(\.statusID) == ["4"], "and nothing else is touched")
    }

    @Test("A launch settles what the file says is owed against what the file holds: a post waited for that is there is named and no longer owed; a row with nothing to ask for owes nothing")
    func settledAtLaunch() async {
        var waiting = Self.post("2", answering: "1")
        waiting.refsDue = true
        var still = Self.post("4", answering: "3")
        still.refsDue = true
        var nothing = Self.post("6")
        nothing.refsDue = true
        let store = ItemStore(sources: [Self.source], notes: [waiting, Self.post("1", at: -1), still, nothing])
        #expect(await held(store, "2")?.refsDue == false)
        #expect(await held(store, "2")?.refs.first?.id == Self.post("1").id)
        #expect(await held(store, "6")?.refsDue == false)
        #expect(await store.owed(host: Self.host).map(\.statusID) == ["3"])
    }

    @Test("A reference whose id at its source is no path segment is nothing to ask for: the item owes nothing, at arrival and at launch")
    func whatCannotBeAsked() async {
        for id in ["../../admin", "1/2", "", "a b", "1?x=2"] {
            let store = await store([Self.post("2", answering: id)])
            #expect(await held(store, "2")?.refsDue == false, "\(id) was owed")
            #expect(await store.owed(host: Self.host).isEmpty)
            var claims = Self.post("2", answering: id)
            claims.refsDue = true
            let launched = ItemStore(sources: [Self.source], notes: [claims])
            #expect(await launched.all().first?.refsDue == false)
        }
    }

    // MARK: - Gone, no longer held, and not said

    @Test("A post its source says is gone is written on the reference, survives the item being read again, and is never asked for; nothing of the post is kept")
    func goneIsRecorded() async throws {
        let reply = Self.post("2", answering: "1")
        let store = await store([reply])
        let owed = try #require(await store.owed(host: Self.host).first)
        await store.land(.gone, for: owed)
        let expected = [Reference(kind: .answers, statusID: "1", handle: "@bob@\(Self.host)", gone: true)]
        #expect(await held(store, "2")?.refs == expected)
        await store.ingest([reply])
        _ = await store.refresh([reply], ifSourceHere: Self.host)
        #expect(await held(store, "2")?.refs == expected)
        #expect(await held(store, "2")?.refsDue == false)
        #expect(await held(store, "2")?.askable.isEmpty == true)
        #expect(await held(store, "2")?.refsUnheld.isEmpty == true, "gone is not the same as no longer held")
        #expect(await store.all().count == 1)
    }

    @Test("A post that was loaded and later let go is said to be no longer held: the item still names it, and the store says it is not here")
    func noLongerHeld() async throws {
        let store = await store([Self.post("2", answering: "1")])
        let owed = try #require(await store.owed(host: Self.host).first)
        await store.land(.held(Self.post("1", at: -1)), for: owed)
        #expect(await held(store, "2")?.refsUnheld.isEmpty == true)
        await store.forget(Self.post("1").key)
        #expect(await held(store, "2")?.refsUnheld == [.answers])
        #expect(await held(store, "2")?.refs.first?.gone == false)
        // And held again — by any way — it says so no longer.
        await store.ingest([Self.post("1", at: -1)])
        #expect(await held(store, "2")?.refsUnheld.isEmpty == true)
    }

    @Test("An answer that is no word on whether the post exists settles what was owed without saying it is gone")
    func notSaid() async throws {
        let store = await store([Self.post("2", answering: "1")])
        let owed = try #require(await store.owed(host: Self.host).first)
        #expect(owed.asReader, "it arrived through Home")
        await store.land(.notSaid, for: owed)
        #expect(await held(store, "2")?.refsDue == false)
        #expect(await held(store, "2")?.refs == [Reference(kind: .answers, statusID: "1", handle: "@bob@\(Self.host)")])
        let open = await self.store([Self.post("3", answering: "1", categories: [.public])])
        #expect(await open.owed(host: Self.host).first?.asReader == false)
    }

    @Test("When a sign-in ends, what its reader's own timelines left owing is dropped with their marks; what a public timeline left owing is not")
    func aSignInEnding() async {
        let store = await store([Self.post("2", answering: "1"), Self.post("4", answering: "3", categories: [.public])])
        #expect(await store.forgetReaderMarks(host: Self.host))
        #expect(await held(store, "2")?.refsDue == false)
        #expect(await store.owed(host: Self.host).map(\.statusID) == ["3"])
        // The sweep at launch, for every host not signed in to, is the same.
        let launched = await self.store([Self.post("2", answering: "1"), Self.post("4", answering: "3", categories: [.public])])
        #expect(await launched.forgetReaderMarks(keeping: []))
        #expect(await launched.owed(host: Self.host).map(\.statusID) == ["3"])
    }

    @Test("Gone is taken back when the post turns up after all: held — by a timeline, a thread, a load for another item — the reference names it and is gone no longer")
    func goneIsTakenBack() async throws {
        let store = await store([Self.post("2", answering: "1")])
        let owed = try #require(await store.owed(host: Self.host).first)
        await store.land(.gone, for: owed)
        #expect(await held(store, "2")?.refs.first?.gone == true, "the premise")
        await store.ingest([Self.post("1", at: -1, categories: [])])
        let reply = try #require(await held(store, "2"))
        #expect(reply.refs == [Reference(kind: .answers, id: Self.post("1").id, statusID: "1", handle: "@bob@\(Self.host)")])
        #expect(!reply.refsDue && reply.refsUnheld.isEmpty)
        // And at a launch, from a file that says gone beside the post itself.
        var saysGone = Self.post("4", answering: "3")
        saysGone = Note(
            id: saysGone.id, source: Self.source, author: "Ada", handle: saysGone.handle, body: "x", postedAt: Self.origin,
            categories: [.home], reply: saysGone.reply, statusID: "4", refs: [Reference(kind: .answers, statusID: "3", gone: true)]
        )
        let launched = ItemStore(sources: [Self.source], notes: [saysGone, Self.post("3", at: -1)])
        #expect(await launched.all().first { $0.statusID == "4" }?.refs == [Reference(kind: .answers, id: Self.post("3").id, statusID: "3")])
    }

    @Test("Where an item owes two loads and one comes back as nothing to keep, that one is not asked for again this run and is not said to be on its way; the other is still owed, and a later run asks for both")
    func triedAndRefused() async throws {
        let both = Self.post("5", answering: "1", quoting: Quote(state: .accepted, statusID: "4"))
        for refusal in [ItemStore.Loaded.notSaid, .held(Self.post("99"))] {
            let store = await store([both])
            let owed = await store.owed(host: Self.host)
            #expect(Set(owed.map(\.statusID)) == ["1", "4"], "the premise")
            await store.land(refusal, for: try #require(owed.first { $0.kind == .answers }))
            let item = try #require(await held(store, "5"))
            #expect(item.refsDue, "it still owes the quoted post")
            #expect(item.refsTried == [.answers])
            #expect(await store.owed(host: Self.host).map(\.statusID) == ["4"], "and what was refused is not asked again")
            #expect(await store.owed(host: Self.host, among: [both.key]).map(\.statusID) == ["4"], "nor when its row is near")

            let next = ItemStore(sources: [Self.source], notes: await store.snapshot().notes)
            #expect(Set(await next.owed(host: Self.host).map(\.statusID)) == ["1", "4"])
            #expect(await next.all().first?.refsTried.isEmpty == true)
            await store.unstall(host: Self.host)
            #expect(Set(await store.owed(host: Self.host).map(\.statusID)) == ["1", "4"], "or when the reader signs in again")

            // Settled, the item keeps nothing of it.
            let rest = try #require(await store.owed(host: Self.host).first { $0.kind == .quotes })
            await store.land(.notSaid, for: try #require(await store.owed(host: Self.host).first { $0.kind == .answers }))
            await store.land(.gone, for: rest)
            #expect(await held(store, "5")?.refsDue == false)
            #expect(await held(store, "5")?.refsTried.isEmpty == true)
        }
    }

    @Test("Arrived as the reader is a fact about a signed read: Home and a list are the reader's; what a public timeline brought is anybody's, whoever read it; and what came through no category — a search, a thread, a hashtag — is the reader's only where the copy says what the reader did, which a source says to a signed read alone. The reader's debts go when the sign-in ends, and nobody else's do")
    func whatIsTheReaders() async {
        // Categories, whether the copy says what the reader did (as a signed read's does, yes or no), and whose it is.
        let cases: [(Set<FediqoCore.Category>, Bool?, Bool)] = [
            ([.public], nil, false), ([.trends], nil, false), ([.home, .public], false, false), ([.public], true, false),
            ([.home], nil, true), ([.list(id: "7")], nil, true), ([.home], false, true),
            ([], nil, false), ([], false, true), ([], true, true),
        ]
        for (categories, said, readers) in cases {
            let plain = Self.post("2", answering: "1", categories: categories)
            var note = Note(
                id: plain.id, source: plain.source, author: plain.author, handle: plain.handle, body: plain.body,
                postedAt: plain.postedAt, categories: categories, reply: plain.reply, favourited: said, statusID: "2"
            )
            note.asked = .now()
            let store = await store([note])
            #expect(await store.owed(host: Self.host).first?.asReader == readers, "\(categories) \(String(describing: said))")
            _ = await store.forgetReaderMarks(host: Self.host)
            #expect(await store.owed(host: Self.host).isEmpty == readers, "\(categories) \(String(describing: said))")
        }
    }

    // MARK: - What it costs

    @Test("What is owed is found among 10,000 notes, one in twenty owing, in about the time one read of them takes; asked of a screenful it looks at the screenful")
    func cost() async {
        let notes = (0..<10_000).map { index in
            Self.post("\(index)", at: -Double(index) / 100, answering: index % 20 == 0 ? "p\(index)" : nil)
        }
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest(notes)
        func timed(_ work: () async -> Int) async -> (Duration, Int) {
            var best = Duration.seconds(60)
            var count = 0
            for _ in 0..<3 {
                let start = ContinuousClock.now
                count = await work()
                best = min(best, ContinuousClock.now - start)
            }
            return (best, count)
        }
        let (reading, held) = await timed { await store.all().count }
        let (owing, owed) = await timed { await store.owed(host: Self.host).count }
        let screen = Set(notes.prefix(30).map(\.key))
        let (near, onScreen) = await timed { await store.owed(host: Self.host, among: screen).count }
        #expect(held == 10_000 && owed == 500 && onScreen == 2)
        print("Owed among 10,000, one in twenty owing: \(owing) against one read of them in \(reading); of a screen of thirty: \(near)")
        #expect(owing < reading * 3, "finding what is owed took \(owing) against \(reading)")
        #expect(near < reading / 10, "a screenful took \(near) against \(reading)")
    }

    // MARK: - Where it stands, and how long

    @Test("What was loaded stands in All at its own time and through no category: a timeline of Home alone does not show it, one whose rule names its author does")
    func whereItStands() async throws {
        let store = await store([Self.post("2", answering: "1")])
        let owed = try #require(await store.owed(host: Self.host).first)
        let parent = Note(
            id: "https://\(Self.host)/p/1", source: Self.source, author: "Cyd", handle: "@cyd@\(Self.host)", body: "the earlier post",
            postedAt: Self.origin.addingTimeInterval(-3 * 86400), categories: [], statusID: "1"
        )
        await store.land(.held(parent), for: owed)
        let all = await store.all()
        #expect(all.map(\.statusID) == ["2", "1"], "at its own publish time, below the reply")
        func shown(_ rule: Rule?) -> [String?] {
            CompiledTimeline(TimelineDefinition(name: "t", rules: [rule].compactMap { $0 }), sources: [Self.source])
                .shown(all, TextIndex(all)).map(\.statusID)
        }
        #expect(shown(.category(.home, in: .every, sources: [Self.source])) == ["2"])
        #expect(shown(.author("cyd@\(Self.host)", in: .every, sources: [Self.source])) == ["1"])
        #expect(shown(.keyword("earlier", in: .every)) == ["1"])
    }

    @Test("A loaded post older than the keep-for window is taken in for the item that refers to it, stays while that item stays, and goes when it goes — by the window and by the room")
    func heldForWhatRefersToIt() async throws {
        let store = await store()
        await store.setRetention(months: 1, from: Self.origin)
        await store.ingest([Self.post("2", answering: "1")])
        let owed = try #require(await store.owed(host: Self.host).first)
        await store.land(.held(Self.post("1", at: -400)), for: owed)
        #expect(await held(store, "1") != nil, "refused at the door, the load would have been for nothing")
        #expect(await store.setRetention(months: 1, from: Self.origin) == 0)
        #expect(await store.letGoOldest(count: 1).posts == 1)
        #expect(await store.all().map(\.statusID) == ["1"], "the room takes the reply first; the post it answers after")

        let later = await self.store()
        await later.setRetention(months: 1, from: Self.origin)
        await later.ingest([Self.post("2", answering: "1")])
        let again = try #require(await later.owed(host: Self.host).first)
        await later.land(.held(Self.post("1", at: -400)), for: again)
        #expect(await later.setRetention(months: 1, from: Self.origin.addingTimeInterval(90 * 86400)) == 2, "the reply went by its age, and the post with it")
    }

    @Test("A store laid in whole from elsewhere owes nothing")
    func aStoreLaidIn() async {
        var owing = Self.post("2", answering: "1")
        owing.refsDue = true
        let store = ItemStore()
        await store.replace(sources: [Self.source], notes: [owing])
        #expect(await store.owed(host: Self.host).isEmpty)
        #expect(await store.all().allSatisfy { !$0.refsDue })
    }

    // MARK: - Other reads' word

    @Test("What another read of the source heard — told to slow down, or little of its allowance left — holds the source's loads back, and counts as no failure")
    func otherReadsAreHeard() async throws {
        let clock = HandClock()
        let pacer = LoadPacer(clock: clock)
        let wire = LoadWire(clock)
        await pacer.heard(host: Self.host, slowDown: true, SourceWord(retryAfter: clock.wall().addingTimeInterval(120)))
        guard case .taken(let ticket) = await pacer.ask(host: Self.host, id: "a", wire.work("a")) else {
            Issue.record("not taken")
            return
        }
        #expect(await pacer.standing(host: Self.host) == LoadStanding(waiting: 1, quietFor: 120))
        await clock.sleeping(for: 120)
        clock.advance(by: 120)
        #expect(await ticket.end() == .done)
        #expect(await wire.times == [120])

        // Plenty of the allowance left is nothing to wait for; little left waits for the reset.
        await pacer.heard(host: "two.example", slowDown: false, SourceWord(remaining: 290, limit: 300, reset: clock.wall().addingTimeInterval(60)))
        #expect(await pacer.standing(host: "two.example").quietFor == nil)
        await pacer.heard(host: "two.example", slowDown: false, SourceWord(remaining: 3, limit: 300, reset: clock.wall().addingTimeInterval(60)))
        #expect(await pacer.standing(host: "two.example") == LoadStanding(quietFor: 60))
        // Told to wait longer than a load waits: not asked this run.
        await pacer.heard(host: "three.example", slowDown: true, SourceWord(retryAfter: clock.wall().addingTimeInterval(7_200)))
        #expect(await pacer.standing(host: "three.example").givenUp)
        // And with no time given, the backoff.
        await pacer.heard(host: "four.example", slowDown: true, nil)
        #expect(await pacer.standing(host: "four.example").quietFor == 30)
    }
}
