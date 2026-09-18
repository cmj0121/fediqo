import Foundation
import Testing
@testable import FediqoCore

@Suite("The server's emoji catalogue")
struct EmojiCatalogueTests {
    private let source = Source(host: "first.example", kind: .mastodon)
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("The catalogue is decoded, folded, and answers by shortcode")
    func decodedAndLookedUp() async throws {
        // Seven registrations, of which three are ones this device will draw: `blobcat` twice,
        // a hyphenated name, a nameless one, and two addresses this device will not go to.
        let catalogueJSON = """
        [
          { "shortcode": "blobcat", "url": "https://first.example/emoji/blobcat.png",
            "static_url": "https://first.example/emoji/blobcat-still.png" },
          { "shortcode": "wave", "url": "https://first.example/emoji/wave.png",
            "static_url": "http://first.example/emoji/wave-still.png" },
          { "shortcode": "blob-cat", "url": "https://first.example/emoji/blob-cat.png" },
          { "shortcode": "blobcat", "url": "https://first.example/emoji/blobcat-second.png" },
          { "shortcode": "", "url": "https://first.example/emoji/nameless.png" },
          { "shortcode": "nowhere", "url": "file:///etc/passwd" },
          { "shortcode": "plain", "url": "http://first.example/emoji/plain.png" }
        ]
        """
        let http = FixtureHTTP([
            "/api/v1/custom_emojis": .body(Data(catalogueJSON.utf8)),
        ])
        let emojis = try await MastodonClient(http: http, host: "first.example").customEmojis()

        #expect(emojis.map(\.shortcode) == ["blobcat", "wave", "blob-cat"])
        // Named twice by the same server, drawn once, and the first spelling is the one kept.
        #expect(emojis[0].url == URL(string: "https://first.example/emoji/blobcat.png"))
        #expect(emojis[0].staticURL == URL(string: "https://first.example/emoji/blobcat-still.png"))

        let catalogue = EmojiCatalogue(emojis, host: "First.Example", fetchedAt: noon)
        #expect(catalogue.count == 3)
        #expect(catalogue.lookup("blobcat")?.url == emojis[0].url)
        // A hyphen is whatever the server registered, exactly as `runs` already allows.
        #expect(catalogue.lookup("blob-cat") != nil)
        // It knows whose it is, lowercased the way `Source` lowercases a host — a picture taken
        // out of one has to be filed under the server it came from, and an emoji address is
        // usually a CDN that cannot be read back as a host.
        #expect(catalogue.host == "first.example")
        #expect(await http.paths == ["/api/v1/custom_emojis"])

        // And it folds a list nobody folded, for the same reason and the same way round: a
        // catalogue is built from whatever it is handed, not only from `customEmojis()`.
        let unfolded = EmojiCatalogue(
            [Self.emoji("blobcat", on: "first.example"), Self.emoji("blobcat", on: "second.example")],
            host: "first.example",
            fetchedAt: noon
        )
        #expect(unfolded.count == 1)
        #expect(unfolded.lookup("blobcat")?.url == URL(string: "https://first.example/emoji/blobcat.png"))
    }

    @Test("A shortcode the catalogue does not carry is not invented")
    func unknownShortcodeIsNothing() {
        let catalogue = EmojiCatalogue(
            [Self.emoji("blobcat", on: "first.example")],
            host: "first.example",
            fetchedAt: noon
        )
        #expect(catalogue.lookup("nobody") == nil)
        #expect(catalogue.lookup("") == nil)
        // And the words keep the colons the author typed rather than losing them to a blank.
        let alphabet = EmojiAlphabet(catalogue: catalogue)
        #expect(alphabet.runs(in: "hi :nobody:") == [.text("hi :nobody:")])
    }

    @Test("`visible_in_picker` and `category` are on the wire and change nothing")
    func pickerFieldsAreIgnored() async throws {
        // Both keys on every entry, `wave`'s picker flag `false`. This app has no picker, so an
        // emoji nobody would offer in one is still an emoji somebody wrote in a post.
        let catalogueJSON = """
        [
          { "shortcode": "blobcat", "url": "https://first.example/emoji/blobcat.png",
            "visible_in_picker": true, "category": "Blobs" },
          { "shortcode": "wave", "url": "https://first.example/emoji/wave.png",
            "visible_in_picker": false },
          { "shortcode": "blob-cat", "url": "https://first.example/emoji/blob-cat.png",
            "visible_in_picker": true, "category": "Blobs" }
        ]
        """
        let http = FixtureHTTP([
            "/api/v1/custom_emojis": .body(Data(catalogueJSON.utf8)),
        ])
        let emojis = try await MastodonClient(http: http, host: "first.example").customEmojis()
        #expect(emojis.contains { $0.shortcode == "wave" })
    }

    @Test("An emoji with an address this device will not go to is dropped")
    func refusedAddressIsDropped() async throws {
        let catalogueJSON = """
        [
          { "shortcode": "blobcat", "url": "https://first.example/emoji/blobcat.png",
            "static_url": "https://first.example/emoji/blobcat-still.png" },
          { "shortcode": "wave", "url": "https://first.example/emoji/wave.png",
            "static_url": "http://first.example/emoji/wave-still.png" },
          { "shortcode": "", "url": "https://first.example/emoji/nameless.png" },
          { "shortcode": "nowhere", "url": "file:///etc/passwd" },
          { "shortcode": "plain", "url": "http://first.example/emoji/plain.png" }
        ]
        """
        let http = FixtureHTTP([
            "/api/v1/custom_emojis": .body(Data(catalogueJSON.utf8)),
        ])
        let emojis = try await MastodonClient(http: http, host: "first.example").customEmojis()
        let names = emojis.map(\.shortcode)
        // `file:` and `http:` are refused at the wire here exactly as they are on a status.
        #expect(!names.contains("nowhere"))
        #expect(!names.contains("plain"))
        // A picture with no name is one nothing in the words can ever spell.
        #expect(emojis.allSatisfy { !$0.shortcode.isEmpty })
        // A refused *still* is only a still we have not got; the emoji keeps its own file.
        let wave = try #require(emojis.first { $0.shortcode == "wave" })
        #expect(wave.url == URL(string: "https://first.example/emoji/wave.png"))
        #expect(wave.staticURL == nil)
    }

    @Test("A catalogue is one server's: the same name on two servers is two pictures")
    func oneNameTwoServers() async {
        let store = EmojiCatalogueStore()
        await Self.hold([Self.emoji("blobcat", on: "first.example")], host: "first.example", in: store)
        await Self.hold([Self.emoji("blobcat", on: "second.example")], host: "second.example", in: store)

        #expect(await store.alphabet(own: [], host: "first.example").lookup("blobcat")?.url
            == URL(string: "https://first.example/emoji/blobcat.png"))
        #expect(await store.alphabet(own: [], host: "second.example").lookup("blobcat")?.url
            == URL(string: "https://second.example/emoji/blobcat.png"))
        #expect(await store.alphabet(own: [], host: "nowhere.example").isEmpty)
        // The host is a host however the reader spelled it, the way `Source` takes it.
        #expect(await store.alphabet(own: [], host: "First.Example").lookup("blobcat") != nil)
    }

    @Test("A post's own picture wins over the server's registration of the same name")
    func ownListBeatsCatalogue() async {
        let own = Self.emoji("blobcat", on: "author.example")
        let store = EmojiCatalogueStore()
        await Self.hold(
            [Self.emoji("blobcat", on: "first.example"), Self.emoji("wave", on: "first.example")],
            host: "first.example",
            in: store
        )
        // Asked the way a screen asks: the store's one public door to a resolved shortcode.
        let alphabet = await store.alphabet(own: [own], host: "first.example")

        // A federated post brings the pictures of the server that wrote it. The reading
        // server's `:blobcat:` is a different picture and must not be drawn over it.
        #expect(alphabet.lookup("blobcat")?.url == own.url)
        // And the catalogue is still the answer for a name the post did not bring.
        #expect(alphabet.lookup("wave")?.url == URL(string: "https://first.example/emoji/wave.png"))
        #expect(alphabet.runs(in: ":blobcat: and :wave:") == [
            .emoji(own),
            .text(" and "),
            .emoji(Self.emoji("wave", on: "first.example")),
        ])
    }

    @Test("An alphabet with nothing in it leaves the words exactly as they were typed")
    func emptyAlphabetIsAFastPath() {
        #expect(EmojiAlphabet().isEmpty)
        #expect(EmojiAlphabet(catalogue: EmojiCatalogue([], host: "first.example", fetchedAt: noon)).isEmpty)
        #expect(EmojiAlphabet().runs(in: ":blobcat:") == [.text(":blobcat:")])
        #expect(EmojiAlphabet().runs(in: "") == [])
        // A post's own list alone is still an alphabet, catalogue or no catalogue.
        let own = Self.emoji("blobcat", on: "author.example")
        #expect(!EmojiAlphabet(own: [own]).isEmpty)
        #expect(EmojiAlphabet(own: [own]).runs(in: ":blobcat:") == [.emoji(own)])
        // A post's own list is folded here too: a status and its author can both name one
        // shortcode, and first spelling wins the same way it does on the wire.
        let twice = EmojiAlphabet(own: [own, Self.emoji("blobcat", on: "first.example")])
        #expect(twice.lookup("blobcat")?.url == own.url)
    }

    @Test("A day old is stale, a day less a second is not, and the clock is injected")
    func staleAfterItsLife() async {
        let catalogue = EmojiCatalogue(
            [Self.emoji("blobcat", on: "first.example")],
            host: "first.example",
            fetchedAt: noon
        )
        #expect(EmojiCatalogue.life == 24 * 60 * 60)
        #expect(!catalogue.isStale(at: noon))
        #expect(!catalogue.isStale(at: noon.addingTimeInterval(EmojiCatalogue.life - 1)))
        #expect(catalogue.isStale(at: noon.addingTimeInterval(EmojiCatalogue.life)))

        // The store asks the same question of its own clock. Nothing here waits a day.
        let clock = TestClock(noon)
        let store = EmojiCatalogueStore(now: clock.read)
        #expect(await store.needsFetch(host: "first.example"))
        await Self.hold([Self.emoji("blobcat", on: "first.example")], host: "first.example", in: store)
        #expect(await store.needsFetch(host: "first.example") == false)
        #expect(await store.catalogue(host: "first.example")?.fetchedAt == noon)

        clock.set(noon.addingTimeInterval(EmojiCatalogue.life))
        #expect(await store.needsFetch(host: "first.example"))
        // Stale is not gone: the pictures still answer until something replaces them.
        #expect(await store.alphabet(own: [], host: "first.example").lookup("blobcat") != nil)
    }

    @Test("A held catalogue is not fetched again inside its life, and a stale one is")
    func refreshSkipsWhatIsStillYoung() async {
        let clock = TestClock(noon)
        let store = EmojiCatalogueStore(now: clock.read)
        let counter = Counter()

        for _ in 0..<3 {
            await store.refresh(host: "first.example") {
                await counter.tick()
                return [Self.emoji("blobcat", on: "first.example")]
            }
            await store.settle(host: "first.example")
        }
        #expect(await counter.count == 1)

        clock.set(noon.addingTimeInterval(EmojiCatalogue.life))
        await store.refresh(host: "first.example") {
            await counter.tick()
            return [Self.emoji("wave", on: "first.example")]
        }
        await store.settle(host: "first.example")
        #expect(await counter.count == 2)
        #expect(await store.alphabet(own: [], host: "first.example").lookup("wave") != nil)
    }

    @Test("Four callers racing one cold host make one fetch, not four", .timeLimit(.minutes(1)))
    func concurrentCallersShareOneFetch() async {
        let store = EmojiCatalogueStore()
        let gate = Gate()
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await store.refresh(host: "first.example") {
                        await counter.tick()
                        // Held open so that all four arrive while the first is on the wire —
                        // the check-then-act window a caller cannot close for itself.
                        await gate.wait()
                        return [Self.emoji("blobcat", on: "first.example")]
                    }
                }
            }
            await group.waitForAll()
        }
        await gate.open()
        await store.settle(host: "first.example")

        #expect(await counter.count == 1)
        #expect(await store.catalogue(host: "first.example")?.count == 1)
    }

    @Test("A fetch still on the wire when the reader clears does not arrive behind them", .timeLimit(.minutes(1)))
    func forgetDuringAFetchKeepsNothing() async {
        let store = EmojiCatalogueStore()
        let gate = Gate()
        await store.refresh(host: "first.example") {
            await gate.wait()
            return [Self.emoji("blobcat", on: "first.example")]
        }

        await store.forget(host: "first.example")
        await gate.open()
        await store.settle(host: "first.example")

        #expect(await store.catalogue(host: "first.example") == nil)
        #expect(await store.needsFetch(host: "first.example"))
    }

    @Test("Clearing and asking again in the same turn starts a fetch, and it lands", .timeLimit(.minutes(1)))
    func forgetThenAskAgainInTheSameTurn() async {
        let store = EmojiCatalogueStore()
        let held = Gate()
        // Cleared while still on the wire, and asked for again before it has unwound — which is
        // exactly what a Clear button does: drop this server, then let the screen re-ask.
        await store.refresh(host: "first.example") {
            await held.wait()
            return [Self.emoji("cleared", on: "first.example")]
        }
        await store.forget(host: "first.example")
        await store.refresh(host: "first.example") { [Self.emoji("asked", on: "first.example")] }

        // Opened before anything is waited on, so that a re-ask which started nothing shows up
        // as a wrong answer rather than as a test that never returns: the cancelled fetch can
        // always run to its end here, and it is the assertions that say it changed nothing.
        await held.open()
        await store.settle(host: "first.example")

        // The re-ask is a fetch that really started. Waiting behind the cancelled one would
        // leave this host with no catalogue and nothing to retry it.
        #expect(await store.alphabet(own: [], host: "first.example").lookup("asked") != nil)
        #expect(await store.needsFetch(host: "first.example") == false)
        // And the cancelled one answering late — a client that does not honour cancellation —
        // neither puts back what the reader cleared nor disturbs the fetch that replaced it.
        #expect(await store.alphabet(own: [], host: "first.example").lookup("cleared") == nil)
    }

    @Test(
        "A fetch that ignores cancellation still cannot land, and the host stays askable",
        .timeLimit(.minutes(1))
    )
    func aFetchThatIgnoresCancellationLandsNothing() async {
        let store = EmojiCatalogueStore()
        let held = Gate()
        await store.refresh(host: "first.example") {
            await held.wait()
            return [Self.emoji("cleared", on: "first.example")]
        }
        await store.forget(host: "first.example")

        // Opened before it is waited on, so the cancelled fetch runs all the way to its answer
        // and the task unwinds completely under `settle` — the case a cooperative client never
        // reaches, and the one that stays open for the whole request on a slow server.
        await held.open()
        await store.settle(host: "first.example")
        #expect(await store.catalogue(host: "first.example") == nil)
        #expect(await store.needsFetch(host: "first.example"))

        // Tidied after itself, so the next ask is not waiting behind a finished corpse.
        await Self.hold([Self.emoji("asked", on: "first.example")], host: "first.example", in: store)
        #expect(await store.alphabet(own: [], host: "first.example").lookup("asked") != nil)
    }

    @Test("A cleared fetch unwinding late does not strike off the one that replaced it", .timeLimit(.minutes(1)))
    func aCancelledFetchDoesNotClearItsSuccessor() async {
        let store = EmojiCatalogueStore()
        let cleared = Gate()
        let asked = Gate()
        let counter = Counter()

        await store.refresh(host: "first.example") {
            await counter.tick()
            await cleared.wait()
            return [Self.emoji("cleared", on: "first.example")]
        }
        await store.forget(host: "first.example")
        await store.refresh(host: "first.example") {
            await counter.tick()
            await asked.wait()
            return [Self.emoji("asked", on: "first.example")]
        }

        // The cleared one unwinds here, while its replacement is still on the wire. Yielding
        // rather than sleeping: this hands the pool as many turns as it needs and depends on no
        // duration. A task that struck its successor off would do it inside this loop.
        await cleared.open()
        for _ in 0..<1_000 { await Task.yield() }

        // If the entry had been struck off, this would be a third fetch running beside the
        // second — the same host asked twice at once, which is the whole thing the map prevents.
        await store.refresh(host: "first.example") {
            await counter.tick()
            return [Self.emoji("third", on: "first.example")]
        }
        await asked.open()
        await store.settle(host: "first.example")

        #expect(await counter.count == 2)
        #expect(await store.alphabet(own: [], host: "first.example").lookup("asked") != nil)
        #expect(await store.alphabet(own: [], host: "first.example").lookup("cleared") == nil)
        #expect(await store.alphabet(own: [], host: "first.example").lookup("third") == nil)
    }

    @Test("forget() clears every server and none of them is left unaskable", .timeLimit(.minutes(1)))
    func forgetAllThenAskAgain() async {
        let store = EmojiCatalogueStore()
        let held = Gate()
        for host in ["first.example", "second.example"] {
            await store.refresh(host: host) {
                await held.wait()
                return [Self.emoji("cleared", on: host)]
            }
        }
        await store.forget()
        for host in ["first.example", "second.example"] {
            await store.refresh(host: host) { [Self.emoji("asked", on: host)] }
        }
        await held.open()

        for host in ["first.example", "second.example"] {
            await store.settle(host: host)
            #expect(await store.alphabet(own: [], host: host).lookup("asked") != nil)
            #expect(await store.alphabet(own: [], host: host).lookup("cleared") == nil)
        }
    }

    @Test("forget(host:) drops one server and leaves the other; forget() drops all")
    func forgetOneAndAll() async {
        let store = EmojiCatalogueStore()
        await Self.hold([Self.emoji("blobcat", on: "first.example")], host: "first.example", in: store)
        await Self.hold([Self.emoji("blobcat", on: "second.example")], host: "second.example", in: store)

        await store.forget(host: "First.Example")
        #expect(await store.catalogue(host: "first.example") == nil)
        #expect(await store.needsFetch(host: "first.example"))
        #expect(await store.alphabet(own: [], host: "second.example").lookup("blobcat") != nil)

        await store.forget()
        #expect(await store.catalogue(host: "second.example") == nil)
        #expect(await store.needsFetch(host: "second.example"))
    }

    @Test("A catalogue that 404s leaves the source joined and its posts readable")
    func catalogue404DoesNotFailTheJoin() async throws {
        let items = ItemStore()
        let catalogues = EmojiCatalogueStore()
        try await MastodonJoin(
            http: Self.joinHTTP(catalogue: .text("not here", status: 404)),
            store: items,
            catalogues: catalogues
        ).join(host: "first.example")
        await catalogues.settle(host: "first.example")

        #expect(await items.sources().map(\.host) == ["first.example"])
        #expect(await items.all().count == 4)
        // No entry at all, rather than an empty one: a bad minute is not written down.
        #expect(await catalogues.catalogue(host: "first.example") == nil)
        #expect(await catalogues.needsFetch(host: "first.example"))
    }

    @Test("A catalogue that never answers is survivable too")
    func catalogueUnreachableDoesNotFailTheJoin() async throws {
        let catalogues = EmojiCatalogueStore()
        try await MastodonJoin(
            http: Self.joinHTTP(catalogue: .fail),
            store: ItemStore(),
            catalogues: catalogues
        ).join(host: "first.example")
        await catalogues.settle(host: "first.example")
        #expect(await catalogues.catalogue(host: "first.example") == nil)
    }

    /// **Both reads refused, which is what a refused join now takes** (decision 18). With only
    /// the public timeline closed this server joins on its trends, and a joined server is asked
    /// for its catalogue — so a one-endpoint fixture here would be pinning the opposite fact.
    @Test("A refused join leaves no catalogue for a host this device never joined")
    func refusedJoinAsksForNothing() async {
        let http = Self.joinHTTP(
            publicTimeline: .text("no", status: 404),
            trending: .text("no", status: 404)
        )
        let catalogues = EmojiCatalogueStore()
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await MastodonJoin(http: http, store: ItemStore(), catalogues: catalogues)
                .join(host: "first.example")
        }
        await catalogues.settle(host: "first.example")
        #expect(await catalogues.catalogue(host: "first.example") == nil)
        #expect(await http.paths.contains("/api/v1/custom_emojis") == false)
    }

    @Test("Joining fetches the catalogue once, and joining again inside its life does not")
    func joinFetchesOncePerServer() async throws {
        let http = Self.joinHTTP()
        let catalogues = EmojiCatalogueStore()
        let join = MastodonJoin(http: http, store: ItemStore(), catalogues: catalogues)
        try await join.join(host: "first.example")
        await catalogues.settle(host: "first.example")

        let catalogue = try #require(await catalogues.catalogue(host: "first.example"))
        #expect(catalogue.count == 3)
        #expect(await catalogues.alphabet(own: [], host: "first.example").lookup("blobcat")?.url
            == URL(string: "https://first.example/emoji/blobcat.png"))

        try await join.join(host: "First.Example")
        await catalogues.settle(host: "first.example")
        #expect(await http.paths.filter { $0 == "/api/v1/custom_emojis" }.count == 1)
    }

    @Test(
        "The join returns with the timeline in hand while the catalogue is still on the wire",
        .timeLimit(.minutes(1))
    )
    func joinDoesNotWaitForTheCatalogue() async throws {
        let gate = Gate()
        let http = GatedHTTP(Self.joinHTTP(), holding: "/api/v1/custom_emojis", at: gate)
        let items = ItemStore()
        let catalogues = EmojiCatalogueStore()

        // Nothing but this test can release the gate, so a join that went back to waiting for
        // the catalogue would wait for ever. The guard turns that into a recorded issue inside
        // the time limit instead of a suite that never finishes. On the passing path the join
        // returns at once and this is cancelled without ever having waited.
        let watchdog = hangGuard { await gate.open() }
        defer { watchdog.cancel() }

        try await MastodonJoin(http: http, store: items, catalogues: catalogues)
            .join(host: "first.example")

        // Returned, and the timeline is in the store, while the catalogue has not answered a
        // word. A catalogue is the largest of the four responses a big instance sends, and the
        // reader pressed the button for a timeline — holding the join open for pictures that
        // may not even be on the page would spend their whole wait on it.
        #expect(await items.all().count == 4)
        #expect(await catalogues.catalogue(host: "first.example") == nil)

        await gate.open()
        await catalogues.settle(host: "first.example")
        #expect(await catalogues.catalogue(host: "first.example")?.count == 3)
    }

    @Test("Four joins of one host racing each other still ask the server once", .timeLimit(.minutes(1)))
    func concurrentJoinsAskOnce() async {
        let http = Self.joinHTTP()
        let catalogues = EmojiCatalogueStore()
        let join = MastodonJoin(http: http, store: ItemStore(), catalogues: catalogues)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try? await join.join(host: "first.example") }
            }
            await group.waitForAll()
        }
        await catalogues.settle(host: "first.example")

        #expect(await http.paths.filter { $0 == "/api/v1/custom_emojis" }.count == 1)
        #expect(await catalogues.catalogue(host: "first.example")?.count == 3)
    }

    /// Puts a catalogue in the store without a server, for the cases that are about holding and
    /// dropping rather than about fetching.
    private static func hold(_ emojis: [CustomEmoji], host: String, in store: EmojiCatalogueStore) async {
        await store.refresh(host: host) { emojis }
        await store.settle(host: host)
    }

    /// A fetch the test opens by hand, so that "while one is still on the wire" is a state a
    /// test can stand in rather than a race it has to hope for.
    private actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            opened = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    /// The fixture client with one path held shut, so that "everything has landed except the
    /// catalogue" is a moment a test can stand in.
    private actor GatedHTTP: HTTPClient {
        private let inner: FixtureHTTP
        private let path: String
        private let gate: Gate

        init(_ inner: FixtureHTTP, holding path: String, at gate: Gate) {
            self.inner = inner
            self.path = path
            self.gate = gate
        }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            if url.path == path { await gate.wait() }
            return try await inner.data(from: url)
        }
    }

    /// How many times the server was actually asked.
    private actor Counter {
        private(set) var count = 0
        func tick() { count += 1 }
    }

    /// A clock a test moves by hand. Time-dependent behaviour is asserted, never waited for.
    ///
    /// Unchecked because it is written by the test and read from inside the actor, and this
    /// suite does both in order on one task.
    private final class TestClock: @unchecked Sendable {
        private var instant: Date

        init(_ instant: Date) { self.instant = instant }

        func set(_ instant: Date) { self.instant = instant }

        var read: @Sendable () -> Date { { [self] in instant } }
    }

    private static func emoji(_ shortcode: String, on host: String) -> CustomEmoji {
        CustomEmoji(shortcode: shortcode, url: URL(string: "https://\(host)/emoji/\(shortcode).png")!)
    }

    /// A whole Mastodon written out here rather than a page taken off one: the front page, the
    /// probe, the two timelines a join reads, and the catalogue this suite is about. It is one
    /// server, not a sample document, and the only thing more than one test can share is a
    /// server — every test above that turns on a *shape* writes its own literal.
    private static func joinHTTP(
        publicTimeline: FixtureHTTP.Outcome? = nil,
        trending: FixtureHTTP.Outcome? = nil,
        catalogue: FixtureHTTP.Outcome? = nil
    ) -> FixtureHTTP {
        let front = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="application-name" content="Mastodon">
          <link rel="help" href="https://joinmastodon.org/">
          <title>Mastodon</title>
        </head>
        <body>
          <div id="mastodon"></div>
        </body>
        </html>
        """
        let instance = """
        {
          "domain": "first.example",
          "title": "The first server",
          "version": "4.3.0",
          "description": "A server this test wrote"
        }
        """
        let publicBody = """
        [
          {
            "id": "100",
            "uri": "https://first.example/users/ada/statuses/old",
            "created_at": "2024-01-01T00:00:00.000Z",
            "content": "<p>Oldest public</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
          },
          {
            "id": "200",
            "uri": "https://first.example/users/ada/statuses/shared",
            "created_at": "2024-06-01T00:00:00.000Z",
            "content": "<p>Shared with trends</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
          },
          {
            "id": "300",
            "uri": "https://first.example/users/bob/statuses/new",
            "created_at": "2024-12-01T00:00:00.000Z",
            "content": "<p>Newest public</p>",
            "visibility": "unlisted",
            "account": { "username": "bob", "acct": "bob@second.example", "display_name": "Bob" }
          }
        ]
        """
        let trendingBody = """
        [
          {
            "id": "200",
            "uri": "https://first.example/users/ada/statuses/shared",
            "created_at": "2024-06-01T00:00:00.000Z",
            "content": "<p>Shared with trends, later payload</p>",
            "visibility": "public",
            "account": { "username": "other", "acct": "other", "display_name": "Other" }
          },
          {
            "id": "400",
            "uri": "https://first.example/users/ada/statuses/trend-only",
            "created_at": "2024-09-01T00:00:00.000Z",
            "content": "<p>Trend only</p>",
            "visibility": "public",
            "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
          }
        ]
        """
        // Seven registrations, three of them drawable — the same seven the decoding tests above
        // spell out, so that `count == 3` here means what it means there.
        let catalogueBody = """
        [
          { "shortcode": "blobcat", "url": "https://first.example/emoji/blobcat.png",
            "static_url": "https://first.example/emoji/blobcat-still.png" },
          { "shortcode": "wave", "url": "https://first.example/emoji/wave.png",
            "static_url": "http://first.example/emoji/wave-still.png" },
          { "shortcode": "blob-cat", "url": "https://first.example/emoji/blob-cat.png" },
          { "shortcode": "blobcat", "url": "https://first.example/emoji/blobcat-second.png" },
          { "shortcode": "", "url": "https://first.example/emoji/nameless.png" },
          { "shortcode": "nowhere", "url": "file:///etc/passwd" },
          { "shortcode": "plain", "url": "http://first.example/emoji/plain.png" }
        ]
        """
        return FixtureHTTP([
            "/": .body(Data(front.utf8)),
            "/api/v2/instance": .body(Data(instance.utf8)),
            "/api/v1/timelines/public": publicTimeline ?? .body(Data(publicBody.utf8)),
            "/api/v1/trends/statuses": trending ?? .body(Data(trendingBody.utf8)),
            "/api/v1/custom_emojis": catalogue ?? .body(Data(catalogueBody.utf8)),
        ])
    }

    // MARK: - Leaving a wait

    @Test("A waiter that is cancelled leaves, and does not sit on a server that never answers",
          .timeLimit(.minutes(1)))
    func aCancelledWaiterLeaves() async throws {
        // The leak this closes: waiting used to be `await task.value`, which honours nobody's
        // cancellation but the fetch's own. A screen that joins and leaves against a dripping
        // server parked one task per visit, for the life of the process.
        let store = EmojiCatalogueStore()
        let parked = AsyncStream<Void>.makeStream()
        await store.refresh(host: "slow.example") {
            // Never answers, and is never cancelled: `forget` is not called here, because the
            // point is the *waiter* leaving rather than the fetch being called off.
            for await _ in parked.stream {}
            return []
        }

        let waiting = Task { await store.settle(host: "slow.example") }
        // Cancelling is the whole test: without a ticket of its own this never returns.
        waiting.cancel()
        await waiting.value

        // The fetch is still on its way — one reader giving up does not call it off for the
        // others, and a catalogue half-fetched is worth no less because one screen stopped
        // looking.
        #expect(await store.isFetching(host: "slow.example"))
        parked.continuation.finish()
    }

    @Test("A waiter is woken when the fetch ends, including when it was called off",
          .timeLimit(.minutes(1)))
    func everyEndingWakesTheWaiters() async throws {
        // A waiter nobody resumes is not a slow wait, it is a hang, and this project's risks
        // record that `.timeLimit` is not a hang guard. So every path out of the fetch wakes
        // them, and the cancelled path is the one easiest to forget.
        let store = EmojiCatalogueStore()
        let parked = AsyncStream<Void>.makeStream()
        await store.refresh(host: "slow.example") {
            for await _ in parked.stream {}
            return []
        }

        let first = Task { await store.settle(host: "slow.example") }
        let second = Task { await store.settle(host: "slow.example") }
        // `forget` cancels the fetch. Both waiters must still be told it is over.
        await store.forget(host: "slow.example")
        parked.continuation.finish()
        await first.value
        await second.value
    }

    @Test("Waiting on a host with nothing on its way is not a wait", .timeLimit(.minutes(1)))
    func nothingOnItsWayIsNoWait() async {
        let store = EmojiCatalogueStore()
        await store.settle(host: "quiet.example")
    }
}
