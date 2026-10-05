import Foundation
import Testing
@testable import FediqoCore

/// A post changed at its source gains a revision, and stays where it was (#286), at the store's
/// own door: the source's word that it changed, what this device held of it before, and every
/// way a copy arrives or a row goes.
@Suite("A post changed at its source")
struct RevisionTests {
    private let source = Source(host: "social.example", kind: .mastodon)
    private let posted = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutes: Double) -> Date { posted.addingTimeInterval(minutes * 60) }

    /// The post as its source hands it over: `edited` minutes after it was published, or never.
    private func copy(
        _ body: String, edited: Double? = nil, spoiler: String? = "", id: String = "9",
        categories: Set<FediqoCore.Category> = [.home], favourites: Int? = nil
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@social.example", body: body,
            postedAt: posted, categories: categories, spoiler: spoiler,
            counts: Counts(favourites: favourites), statusID: id, editedAt: edited.map(at)
        )
    }

    private func store(_ notes: [Note]) async -> ItemStore {
        let store = ItemStore()
        await store.add(source)
        await store.ingest(notes, ifSourceHere: source.host)
        return store
    }

    private func row(_ store: ItemStore, _ id: String = "9") async throws -> Note {
        try #require(await store.note(NoteKey(host: source.host, id: id)))
    }

    static func status(_ words: String, editedAt: String? = nil) -> String {
        let edited = editedAt.map { #""\#($0)""# } ?? "null"
        return """
        {"id":"9","uri":"https://social.example/users/ada/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","edited_at":\(edited),"content":"<p>\(words)</p>",
         "visibility":"public","spoiler_text":"",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    // MARK: - The source's word

    @Test("When a status was last edited is read off it; one never edited, and a server that says nothing, say nothing")
    func theSourcesWord() throws {
        func note(_ json: String) throws -> Note {
            try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8)).asNote(source: source, category: .home)
        }
        let edited = try note(Self.status("now", editedAt: "2024-06-02T10:00:00.000Z"))
        #expect(edited.editedAt == ISO8601DateFormatter().date(from: "2024-06-02T10:00:00Z"))
        #expect(edited.postedAt == ISO8601DateFormatter().date(from: "2024-06-01T00:00:00Z"), "when it was published is not when it changed")
        #expect(edited.earlier.isEmpty)
        #expect(try note(Self.status("as written")).editedAt == nil)
        let old = Self.status("as written").replacingOccurrences(of: #""edited_at":null,"#, with: "")
        #expect(try note(old).editedAt == nil)
    }

    // MARK: - Read, changed, read again

    @Test("An ordinary reload of a post its source changed: the row is where it was, says it changed, shows the new words and keeps the old")
    func aReloadTakesTheChange() async throws {
        let store = await store([copy("first words", id: "8"), copy("as written"), copy("last words", id: "10")])
        let order = await store.all().map(\.id)
        let drawn = await store.drawn

        await store.ingest([copy("as changed", edited: 30)], ifSourceHere: source.host)

        let row = try await row(store)
        #expect(row.body == "as changed")
        #expect(row.editedAt == at(30))
        #expect(row.earlier == [Wording(body: "as written", spoiler: "", until: at(30))])
        #expect(row.postedAt == posted, "a change moved when it was published")
        #expect(await store.all().map(\.id) == order, "a change moved the row")
        #expect(await store.drawn == drawn + 1, "and the screen is told")
    }

    @Test("Changed twice, both earlier wordings are kept, in order, each with when the source said it changed")
    func changedTwice() async throws {
        let store = await store([copy("one")])
        await store.ingest([copy("two", edited: 10)], ifSourceHere: source.host)
        await store.refresh([copy("three", edited: 20)], ifSourceHere: source.host)

        let row = try await row(store)
        #expect(row.body == "three" && row.editedAt == at(20))
        #expect(row.earlier == [
            Wording(body: "one", spoiler: "", until: at(10)), Wording(body: "two", spoiler: "", until: at(20)),
        ])
    }

    @Test("A post already changed when first read says it was changed, and holds no earlier wording")
    func alreadyChangedWhenFirstRead() async throws {
        let store = await store([copy("as it is now", edited: 30)])
        let row = try await row(store)
        #expect(row.editedAt == at(30))
        #expect(row.earlier.isEmpty, "a wording this device never held was offered")
    }

    @Test("Read again with nothing changed adds nothing and writes nothing, by a reload or by a read of the post")
    func nothingChangedAddsNothing() async throws {
        let store = await store([copy("as written")])
        await store.ingest([copy("as changed", edited: 30)], ifSourceHere: source.host)
        let before = try await row(store)
        let revision = await store.revision

        await store.ingest([copy("as changed", edited: 30)], ifSourceHere: source.host)
        await store.refresh([copy("as changed", edited: 30)], ifSourceHere: source.host)
        await store.ingest([copy("as changed", edited: 30, categories: [.home])], ifSourceHere: source.host)

        #expect(try await row(store) == before)
        #expect(await store.revision == revision)
    }

    @Test("An older copy still on its way when a later one landed changes no word of the row, by a reload or by a read of the post")
    func anOlderCopyInFlight() async throws {
        let store = await store([copy("one")])
        await store.ingest([copy("three", edited: 20)], ifSourceHere: source.host)
        let settled = try await row(store)

        // Read before the last change, landing after it: the unedited copy, and the first edit.
        for stale in [copy("one"), copy("two", edited: 10)] {
            await store.ingest([stale], ifSourceHere: source.host)
            #expect(await store.refresh([stale], ifSourceHere: source.host) == false)
        }

        #expect(try await row(store) == settled, "an older copy overwrote a newer one")
        #expect(settled.earlier == [Wording(body: "one", spoiler: "", until: at(20))])
    }

    @Test("What makes a wording is the words and the author's warning: a count or a mark moving is no revision, and a change that touches neither keeps none")
    func whatAWordingIs() async throws {
        let store = await store([copy("words", spoiler: "mind this")])

        // A warning changed is a wording changed.
        await store.ingest([copy("words", edited: 10, spoiler: "mind that")], ifSourceHere: source.host)
        #expect(try await row(store).earlier == [Wording(body: "words", spoiler: "mind this", until: at(10))])
        #expect(try await row(store).spoiler == "mind that")

        // The source says it changed and neither the words nor the warning did — a picture's
        // description, a poll: marked as changed, and nothing earlier to read.
        await store.ingest([copy("words", edited: 20, spoiler: "mind that")], ifSourceHere: source.host)
        #expect(try await row(store).editedAt == at(20))
        #expect(try await row(store).earlier.count == 1)

        // A count moving says nothing of what the post says.
        await store.ingest([copy("words", edited: 20, spoiler: "mind that", favourites: 7)], ifSourceHere: source.host)
        #expect(try await row(store).counts.favourites == 7)
        #expect(try await row(store).earlier.count == 1)
    }

    @Test("A source that never says a post was changed keeps none: a read of the post still shows its new words, as it did")
    func aSourceThatNeverSays() async throws {
        let store = await store([copy("as written")])
        await store.ingest([copy("reworded")], ifSourceHere: source.host)
        #expect(try await row(store).body == "as written", "a reload still keeps the first copy where nothing says it changed")
        await store.refresh([copy("reworded")], ifSourceHere: source.host)
        let row = try await row(store)
        #expect(row.body == "reworded" && row.editedAt == nil && row.earlier.isEmpty)
    }

    @Test("A post rewritten without end keeps its latest earlier wordings and lets the oldest go")
    func boundedPerPost() async throws {
        let store = await store([copy("0")])
        for n in 1...(Wording.kept + 5) {
            await store.ingest([copy("\(n)", edited: Double(n))], ifSourceHere: source.host)
        }
        let row = try await row(store)
        #expect(row.earlier.count == Wording.kept)
        #expect(row.earlier.first?.body == "5" && row.earlier.last?.body == "\(Wording.kept + 4)")
    }

    @Test("An edit that changes the words and adds a quote keeps what the post said before the quote arrived")
    func aQuoteArrivingWithAnEdit() async throws {
        let store = await store([copy("as written, RE: https://elsewhere.example/1")])
        let quoted = QuotedPost(id: "q", author: "Bob", handle: "@bob", body: "quoted", postedAt: posted)
        let later = Note(
            id: "9", source: source, author: "Ada", handle: "@ada@social.example", body: "as changed",
            postedAt: posted, categories: [.home], spoiler: "", statusID: "9",
            quote: Quote(state: .accepted, post: quoted), editedAt: at(30)
        )

        await store.ingest([later], ifSourceHere: source.host)

        let row = try await row(store)
        #expect(row.body == "as changed" && row.quote != nil)
        #expect(row.earlier.map(\.body) == ["as written, RE: https://elsewhere.example/1"], "the wording it held was lost to the quote's own fill")
    }

    @Test("A copy known to be the older one changes no word and no mark of the reader's on a reload; its counts still land")
    func anOlderCopyLeavesTheReadersMarks() async throws {
        func marked(_ body: String, edited: Double?, said: Bool?, favourites: Int) -> Note {
            Note(
                id: "9", source: source, author: "Ada", handle: "@ada@social.example", body: body,
                postedAt: posted, categories: [.home], boosted: said, favourited: said, bookmarked: said,
                spoiler: "", counts: Counts(favourites: favourites), statusID: "9", editedAt: edited.map(at)
            )
        }
        // The row as the source answered the reader's own press, after its last change.
        let store = await store([marked("two", edited: 20, said: true, favourites: 5)])

        // A reload asked before both, landing now: it says the reader had done none of it.
        await store.ingest([marked("one", edited: nil, said: false, favourites: 9)], ifSourceHere: source.host)

        var row = try await row(store)
        #expect(row.body == "two")
        #expect(row.boosted == true && row.favourited == true && row.bookmarked == true, "a stale reload flipped a mark the source had answered")
        #expect(row.counts.favourites == 9)

        // A stale read of the post itself, or of its thread, is no different.
        await store.refresh([marked("one", edited: 10, said: false, favourites: 11)], ifSourceHere: source.host)
        row = try await self.row(store)
        #expect(row.body == "two" && row.editedAt == at(20))
        #expect(row.bookmarked == true && row.counts.favourites == 11)

        // The source's answer to an act the reader has just made always lands, whatever its age.
        await store.refresh([marked("one", edited: 10, said: false, favourites: 12)], ifSourceHere: source.host, acted: true)
        row = try await self.row(store)
        #expect(row.bookmarked == false && row.favourited == false && row.boosted == false, "the answer to the reader's own press was dropped")
        #expect(row.body == "two" && row.earlier.isEmpty, "and it still changed no word")
        // And a copy that is not older says the reader's word as before.
        await store.ingest([marked("two", edited: 20, said: true, favourites: 12)], ifSourceHere: source.host)
        #expect(try await self.row(store).bookmarked == true)
    }

    @Test("An edit moment far ahead of this device's clock is taken as when the post was published: marked once, the same at every read, and no bar to a true change")
    func aFarFutureMomentIsStable() async throws {
        let now = at(100)
        #expect(StatusDTO.edited(nil, posted: posted, now: now) == nil)
        #expect(StatusDTO.edited(at(30), posted: posted, now: now) == at(30))
        #expect(StatusDTO.edited(now.addingTimeInterval(60), posted: posted, now: now) == now.addingTimeInterval(60), "a clock a minute out is ordinary")
        let impossible = now.addingTimeInterval(86_400 * 3_650)
        #expect(StatusDTO.edited(impossible, posted: posted, now: now) == posted)
        #expect(StatusDTO.edited(impossible, posted: posted, now: now.addingTimeInterval(3_600)) == posted, "it moved with the clock")

        func note(_ words: String, editedAt: String?) throws -> Note {
            try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status(words, editedAt: editedAt).utf8))
                .asNote(source: source, category: .home)
        }
        let plain = try note("as written", editedAt: nil)
        let hostile = try note("hostile", editedAt: "2999-01-01T00:00:00.000Z")
        #expect(hostile.editedAt == hostile.postedAt)

        // Held unedited, then the impossible moment arrives: one revision, and the mark.
        let store = await store([plain])
        await store.ingest([hostile], ifSourceHere: source.host)
        let revised = try #require(await store.note(plain.key))
        #expect(revised.body == "hostile" && revised.editedAt != nil)
        #expect(revised.earlier.map(\.body) == ["as written"])
        let revision = await store.revision

        // The same copy at every read after — parsed afresh, as a reload parses it — and from a
        // store read back: nothing is revised, nothing is written.
        for _ in 0..<3 {
            await store.ingest([try note("hostile", editedAt: "2999-01-01T00:00:00.000Z")], ifSourceHere: source.host)
            #expect(await store.refresh([try note("hostile", editedAt: "2999-06-01T00:00:00.000Z")], ifSourceHere: source.host) == false)
        }
        #expect(try #require(await store.note(plain.key)) == revised, "revised again at every read")
        #expect(await store.revision == revision, "and written down every time")
        let taken = await store.snapshot()
        let relaunched = ItemStore(sources: taken.sources, notes: taken.notes)
        await relaunched.ingest([try note("hostile", editedAt: "2999-01-01T00:00:00.000Z")], ifSourceHere: source.host)
        #expect(await relaunched.revision == 0)

        // A true change afterwards is later than when the post was published, and lands.
        await store.ingest([try note("the true change", editedAt: "2024-06-01T00:10:00.000Z")], ifSourceHere: source.host)
        let landed = try #require(await store.note(plain.key))
        #expect(landed.body == "the true change")
        #expect(landed.earlier.map(\.body) == ["as written", "hostile"])
    }

    @Test("An edit moment this build cannot read is no word about a change, and costs neither the status nor its page")
    func anUnreadableMoment() throws {
        let bad = Self.status("fine otherwise", editedAt: "the day before yesterday")
        let page = "[\(Self.status("first")),\(bad),\(Self.status("third", editedAt: "2024-06-02T10:00:00.000Z"))]"
        let notes = try MastodonJSON.decoder.decode([StatusDTO].self, from: Data(page.utf8))
            .map { $0.asNote(source: source, category: .home) }
        #expect(notes.map(\.body) == ["first", "fine otherwise", "third"], "one status took its page with it")
        #expect(notes.map { $0.editedAt != nil } == [false, false, true])
        let number = Self.status("x").replacingOccurrences(of: #""edited_at":null"#, with: #""edited_at":12345"#)
        #expect(try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(number.utf8)).asNote(source: source, category: .home).editedAt == nil)
    }

    @Test("What a post said before is bounded by weight as by count, the oldest going first, whoever hands the list over")
    func boundedByWeight() async throws {
        let big = String(repeating: "x", count: Wording.budget / 2 - 10)
        let list = (0..<4).map { Wording(body: "\($0)" + big, spoiler: "", until: at(Double($0))) }
        let held = Wording.bounded(list)
        #expect(held.map { $0.body.prefix(1) } == ["2", "3"], "the oldest go, and the latest stay")
        #expect(held.reduce(0) { $0 + $1.body.utf8.count } <= Wording.budget)
        // One oversized rewrite does not cost a post what it had said: the light ones before it stay.
        let small = (0..<3).map { Wording(body: "small \($0)", until: at(Double($0))) }
        let oversized = Wording(body: big + big + big, until: at(9))
        #expect(Wording.bounded(small + [oversized]) == small, "the newest alone was over, and every older one went for it")
        #expect(Wording.bounded([small[0], oversized, small[1]]) == [small[0], small[1]])
        // One wording heavier than the whole budget is not kept at all; a light list is untouched.
        #expect(Wording.bounded([Wording(body: big + big + big, until: at(1))]).isEmpty)
        let light = (0..<3).map { Wording(body: "w\($0)", until: at(Double($0))) }
        #expect(Wording.bounded(light) == light)
        #expect(Wording.bounded((0..<(Wording.kept + 7)).map { Wording(body: "\($0)", until: at(Double($0))) }).count == Wording.kept)

        // Through the store: a source handing over a heavy wording at every read grows no row past it.
        let store = await store([copy("0" + big)])
        for n in 1...5 {
            await store.ingest([copy("\(n)" + big, edited: Double(n))], ifSourceHere: source.host)
        }
        let earlier = try await row(store).earlier
        #expect(earlier.count == 2 && earlier.reduce(0) { $0 + $1.body.utf8.count } <= Wording.budget)
    }

    @Test("A wording remembers whether its author had covered it, with a warning or with none")
    func aWordingRemembersItsCover() async throws {
        let covered = Note(
            id: "9", source: source, author: "Ada", handle: "@ada@social.example", body: "under no warning",
            postedAt: posted, categories: [.home], sensitive: true, spoiler: "", statusID: "9"
        )
        let store = await store([covered])
        let open = Note(
            id: "9", source: source, author: "Ada", handle: "@ada@social.example", body: "in the open",
            postedAt: posted, categories: [.home], sensitive: false, spoiler: "", statusID: "9", editedAt: at(30)
        )
        await store.ingest([open], ifSourceHere: source.host)
        let row = try await row(store)
        #expect(row.sensitive == false)
        #expect(row.earlier == [Wording(body: "under no warning", spoiler: "", sensitive: true, until: at(30))])
        #expect(row.earlier[0].covered)
        #expect(Wording(body: "x", spoiler: "mind", until: at(1)).covered && !Wording(body: "x", spoiler: "", until: at(1)).covered)
    }

    // MARK: - What a rule and a search are asked of

    @Test("A keyword rule and a search are asked of what the post says now, never of what it said before")
    func rulesReadWhatItSaysNow() async throws {
        let store = await store([copy("about apples"), copy("about pears", id: "10")])
        func shown(_ word: String) async throws -> [String] {
            let notes = await store.all()
            let rule = try #require(Rule.keyword(word, in: .every))
            let timeline = TimelineDefinition(name: "T", rules: [rule])
            return CompiledTimeline(timeline, sources: [source]).shown(notes, TextIndex(notes)).map(\.id)
        }
        func found(_ word: String) async throws -> [String] {
            let notes = await store.all()
            return try #require(NoteSearch(word, sources: [source])).found(notes, SearchIndex(notes)).map(\.id)
        }
        #expect(try await shown("apples") == ["9"])

        await store.ingest([copy("about plums", edited: 30)], ifSourceHere: source.host)

        #expect(try await row(store).earlier.map(\.body) == ["about apples"])
        #expect(try await shown("apples").isEmpty, "a rule matched a wording the post no longer says")
        #expect(try await shown("plums") == ["9"])
        #expect(try await found("apples").isEmpty, "a search found a wording the post no longer says")
        #expect(try await found("plums") == ["9"])
    }

    // MARK: - Part of what the device holds

    @Test("Earlier wordings are counted in what the device holds")
    func counted() async throws {
        let store = await store([copy("one"), copy("other", id: "10")])
        await store.ingest([copy("two", edited: 10)], ifSourceHere: source.host)
        await store.ingest([copy("three", edited: 20)], ifSourceHere: source.host)
        let holdings = Holdings(notes: await store.snapshot().notes, per: .month)
        #expect(holdings.posts == 2 && holdings.earlier == 2)
    }

    @Test("Every way the item goes takes its earlier wordings with it; a kept item keeps them, and nothing of them is left anywhere in the store")
    func theyGoWithTheItem() async throws {
        func changed() async -> ItemStore {
            let changed = await self.store([copy("the words its author took back")])
            await changed.ingest([copy("as changed", edited: 30)], ifSourceHere: source.host)
            return changed
        }
        func holdsNothing(_ store: ItemStore, _ how: String) async {
            let snapshot = await store.snapshot()
            #expect(snapshot.notes.isEmpty, "\(how) left the item")
            #expect(!String(describing: snapshot).contains("took back"), "\(how) left an earlier wording behind")
        }
        let key = NoteKey(host: source.host, id: "9")
        let day = posted.addingTimeInterval(-3_600)..<posted.addingTimeInterval(3_600)

        var store = await changed()
        await store.letGo(span: day)
        await holdsNothing(store, "letting go by dates")

        store = await changed()
        _ = await store.letGoOldest(count: 1)
        await holdsNothing(store, "the room limit")

        store = await changed()
        _ = await store.letGoBeyond(months: 1, from: posted.addingTimeInterval(400 * 86_400))
        await holdsNothing(store, "the months limit")

        store = await changed()
        await store.remove(host: source.host)
        await holdsNothing(store, "removing its source")

        store = await changed()
        await store.markGone(key, at: posted)
        await store.letGoneGo()
        await holdsNothing(store, "letting go of what its source deleted")

        store = await changed()
        await store.forget(key)
        await holdsNothing(store, "taking it back")

        // Kept, it stays through each of them, with what it said before.
        store = await changed()
        await store.setKept(true, for: key)
        await store.letGo(span: day)
        _ = await store.letGoOldest(count: 1)
        await store.remove(host: source.host)
        #expect(try await row(store).earlier.map(\.body) == ["the words its author took back"])
    }

    @Test("What this device does to a row leaves what it said before where it was: kept, marked, an opening post, a sign-in ending")
    func otherChangesCarryThem() async throws {
        let store = await store([copy("one")])
        await store.ingest([copy("two", edited: 10)], ifSourceHere: source.host)
        let key = NoteKey(host: source.host, id: "9")
        let before = try await row(store)

        await store.setKept(true, for: key)
        await store.markGone(key, at: posted)
        await store.forgetReaderMarks(host: source.host)
        await store.keep([key: ForumOpening(words: "x")])

        let after = try await row(store)
        #expect(after.earlier == before.earlier && after.editedAt == before.editedAt)
        #expect(before.with(opening: ForumOpening(words: "x")).earlier == before.earlier)
    }

    @Test("A snapshot carries the mark and the earlier wordings into a new store")
    func ridesASnapshot() async throws {
        let store = await store([copy("one")])
        await store.ingest([copy("two", edited: 10)], ifSourceHere: source.host)
        let taken = await store.snapshot()
        let other = ItemStore()
        await other.replace(sources: taken.sources, notes: taken.notes)
        #expect(try await row(other) == (try await row(store)))
        #expect(try await row(other).earlier.count == 1)
    }
}
