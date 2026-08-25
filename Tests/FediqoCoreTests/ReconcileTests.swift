import Foundation
import GRDB
import Testing
@testable import FediqoCore

/// Noticing that a server no longer hands a post over.
///
/// The whole suite turns on one distinction. A page that does not contain a post raises a
/// question; only the answer to that question, from the server whose word on the post is
/// final, writes `deleted_at`. Everything below is a way of being wrong about that — silence
/// read as an answer, a refusal read as silence, a relay read as an authority, an empty page
/// read as a mass deletion — and a test that would catch it.
///
/// Nothing here sleeps: the clock is a parameter, as it is everywhere else in this app.
@Suite("Noticing that a server no longer hands a post over")
struct ReconcileTests {
    private let timeline = "/api/v1/timelines/public"
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Arranging

    /// Where one post is asked about on the server that wrote it.
    private func statusPath(_ id: String) -> String { "/api/v1/statuses/\(id)" }

    /// Every post the store has marked, by merge key. The one thing this whole unit is
    /// allowed to write, so it is the one thing every test looks at.
    private func marked(_ store: LocalStore) async throws -> Set<String> {
        try await store.read { db in
            Set(try String.fetchAll(db, sql: "SELECT merge_key FROM posts WHERE deleted_at IS NOT NULL"))
        }
    }

    /// A store already holding `stored` from `server`, and one reach for the bottom whose page
    /// comes back as `page`. What is stored, absent from that page, and inside the stretch the
    /// page covers is exactly what ends up suspected.
    private func reaching(_ stored: [Post], page: String, from server: Server)
        async throws -> (store: LocalStore, loader: TimelineLoader) {
        let store = try LocalStore.inMemory()
        try await store.save(stored, from: server)
        stubRoutes.on(server.host, timeline, status: 200, body: page)
        let loader = stubbedLoader(store: store)
        _ = await loader.loadOlder(servers: [server], now: t0)
        return (store, loader)
    }

    /// The arrangement most of these tests want: two posts stored at one instant, a page that
    /// hands back only the first, and so exactly one suspect — with its authority primed to
    /// answer `answering` when it is asked about it.
    ///
    /// One instant for both is what puts the second inside the stretch the page covers; that
    /// coupling is stated here once rather than restated in every test that relies on it.
    private struct OneSuspect {
        let store: LocalStore
        let loader: TimelineLoader
        let authority: String
        /// The post the page left out — the only question this arrangement raises.
        let suspect: Post
    }

    private func oneSuspect(_ name: String, answering status: Int) async throws -> OneSuspect {
        let relay = makeServer("\(name).reconcile.test")
        let authority = "\(name)-authority.reconcile.test"
        let handed = handedOver("1", from: relay.host, authority: authority)
        let absent = handedOver("2", from: relay.host, authority: authority)
        let (store, loader) = try await reaching(
            [handed, absent],
            page: statusesJSON(["1"], from: relay.host, authority: authority, at: [100]),
            from: relay
        )
        stubRoutes.on(authority, statusPath("2"), status: status, body: "{}")
        return OneSuspect(store: store, loader: loader, authority: authority, suspect: absent)
    }

    // MARK: - Absence is a question, not an answer

    @Test("A post a page left out is a suspect: it is asked about, and nothing is written yet")
    func absenceIsASuspicionAndNotAVerdict() async throws {
        let it = try await oneSuspect("absent", answering: 200)

        // Absence on its own writes nothing and asks nothing: a page arriving is not a verdict.
        #expect(try await marked(it.store).isEmpty)
        #expect(stubRoutes.requests(for: it.authority, statusPath("2")).isEmpty)

        _ = await it.loader.reconcile(now: t0)

        // Suspected is exactly this: the authority was asked about it, by name — and having
        // said the post is still there, still nothing is written.
        #expect(stubRoutes.requests(for: it.authority, statusPath("2")).count == 1)
        #expect(try await marked(it.store).isEmpty)
    }

    @Test("A 404 is the answer that writes deleted_at")
    func notFoundMarksIt() async throws {
        let it = try await oneSuspect("notfound", answering: 404)

        let gone = await it.loader.reconcile(now: t0)

        // 404 rather than 410, because 404 is what mastodon.social was measured to answer for
        // a status it will not give. It does not say the author deleted it, and the mark does
        // not claim it did: it says this server will not hand it over any more.
        #expect(gone == [it.suspect.mergeKey])
        #expect(try await marked(it.store) == [it.suspect.mergeKey])
        // The post that came back in the page was never in question.
        #expect(try await it.store.timeline().count == 1)
    }

    @Test("A 410 is read as exactly the same answer")
    func goneMarksIt() async throws {
        let it = try await oneSuspect("gone", answering: 410)

        #expect(await it.loader.reconcile(now: t0) == [it.suspect.mergeKey])
        #expect(try await marked(it.store) == [it.suspect.mergeKey])
    }

    @Test("A 200 clears the suspicion rather than merely postponing it")
    func stillThereClearsIt() async throws {
        let it = try await oneSuspect("present", answering: 200)

        #expect(await it.loader.reconcile(now: t0).isEmpty)
        // Answered for is answered for. A second pass has no question left to ask, so the
        // authority is not asked about the same post over and over.
        #expect(await it.loader.reconcile(now: t0.addingTimeInterval(1)).isEmpty)
        #expect(stubRoutes.requests(for: it.authority, statusPath("2")).count == 1)
        #expect(try await marked(it.store).isEmpty)
    }

    // MARK: - Whoever asked for the page

    @Test("A refresh raises suspects too: a page is the same evidence whoever asked for it")
    func aRefreshRaisesSuspectsAsWell() async throws {
        let relay = makeServer("refreshed.reconcile.test")
        let authority = "refreshed-authority.reconcile.test"
        let absent = handedOver("2", from: relay.host, authority: authority)
        let store = try LocalStore.inMemory()
        try await store.save([handedOver("1", from: relay.host, authority: authority), absent],
                             from: relay)
        stubRoutes.on(relay.host, timeline, status: 200,
                      body: statusesJSON(["1"], from: relay.host, authority: authority, at: [100]))
        stubRoutes.on(authority, statusPath("2"), status: 404, body: "{}")
        let loader = stubbedLoader(store: store)

        // Never a reach-down — the plain refresh every screen already does. The top of the
        // timeline is where a post pulled down moments after it went up sits, and it is the
        // one stretch paging never revisits, because paging only ever walks away from it.
        _ = await loader.load(servers: [relay], mode: .timeline, now: t0)

        #expect(await loader.reconcile(now: t0) == [absent.mergeKey])
        #expect(try await marked(store) == [absent.mergeKey])
    }

    @Test("A trending list is not a stretch of time, so it leaves nothing out of one")
    func trendingRaisesNoQuestions() async throws {
        let relay = makeServer("trending.reconcile.test")
        let authority = "trending-authority.reconcile.test"
        let stored = ["1", "2"].map { handedOver($0, from: relay.host, authority: authority) }
        let store = try LocalStore.inMemory()
        try await store.save(stored, from: relay)
        stubRoutes.on(relay.host, "/api/v1/trends/statuses", status: 200,
                      body: statusesJSON(["1"], from: relay.host, authority: authority, at: [100]))
        // Primed to say gone, so a trending list that did raise questions could not pass this.
        stubRoutes.on(authority, statusPath("2"), status: 404, body: "{}")
        let loader = stubbedLoader(store: store)

        _ = await loader.load(servers: [relay], mode: .trending, now: t0)

        // A trending list is a snapshot a server curated, not a range it was asked for. A post
        // being absent from it means the server does not think it is rising — which is not a
        // fact about whether the post is there at all.
        #expect(await loader.reconcile(now: t0).isEmpty)
        #expect(try await marked(store).isEmpty)
        #expect(stubRoutes.paths(for: authority).isEmpty)
    }

    // MARK: - Silence is not an answer, and a refusal is not silence

    @Test("A server that cannot answer decides nothing, and the post is asked about again")
    func silenceDecidesNothing() async throws {
        let it = try await oneSuspect("silent", answering: 503)

        #expect(await it.loader.reconcile(every: .seconds(30), now: t0).isEmpty)
        #expect(try await marked(it.store).isEmpty)

        // Still suspected rather than checked: once the wait is over and the authority can
        // speak, the same post is asked about again and this time an answer arrives.
        stubRoutes.on(it.authority, statusPath("2"), status: 404, body: "{}")
        let gone = await it.loader.reconcile(every: .seconds(30), now: t0.addingTimeInterval(31))

        #expect(gone == [it.suspect.mergeKey])
        #expect(try await marked(it.store) == [it.suspect.mergeKey])
        #expect(stubRoutes.requests(for: it.authority, statusPath("2")).count == 2)
    }

    @Test("An authority that is struggling is left alone rather than asked post by post")
    func aStrugglingAuthorityIsNotHammered() async throws {
        let it = try await oneSuspect("hammer", answering: 503)

        _ = await it.loader.reconcile(every: .seconds(30), now: t0)
        _ = await it.loader.reconcile(every: .seconds(30), now: t0.addingTimeInterval(1))

        // The same wait a timeline page respects, kept in the same place: a server that could
        // not answer once is not then asked about every suspect in the queue.
        #expect(stubRoutes.requests(for: it.authority, statusPath("2")).count == 1)
    }

    @Test("A server declining to discuss a post with a stranger has answered, and starts no wait")
    func aRefusalIsNotSilence() async throws {
        // 401 to a request carrying no credential: the server replied at once and said this
        // is not a post it shows to strangers. It is not down, and nothing about it is failing.
        let it = try await oneSuspect("refusing", answering: 401)

        #expect(await it.loader.reconcile(every: .seconds(30), now: t0).isEmpty)
        #expect(try await marked(it.store).isEmpty)

        // So no wait was started, and the very next pass reaches it again. Were a refusal
        // counted as silence, this second pass would find the authority inside a wait — and
        // because that wait is shared with the chosen servers, an authority that is also a
        // source would have had its own signed-in timeline skipped for having refused a
        // stranger one post.
        _ = await it.loader.reconcile(every: .seconds(30), now: t0.addingTimeInterval(1))
        #expect(stubRoutes.requests(for: it.authority, statusPath("2")).count == 2)
    }

    @Test("A post the authority keeps refusing stops taking up a place in the queue")
    func aStandingRefusalStopsBeingAsked() async throws {
        let it = try await oneSuspect("standing", answering: 401)

        // Refused as often as it takes to establish that this is simply the answer.
        for pass in 0..<Reconciler.refusalsBeforeSettingAside {
            _ = await it.loader.reconcile(every: .seconds(30), now: t0.addingTimeInterval(Double(pass)))
        }
        let asked = stubRoutes.requests(for: it.authority, statusPath("2")).count
        #expect(asked == Reconciler.refusalsBeforeSettingAside)

        // And then it is set aside: nothing marked, nothing forgotten, and no longer spending
        // one of the eight places a pass has — later passes ask nothing more about it.
        _ = await it.loader.reconcile(every: .seconds(30), now: t0.addingTimeInterval(10))
        _ = await it.loader.reconcile(every: .seconds(30), now: t0.addingTimeInterval(11))

        #expect(stubRoutes.requests(for: it.authority, statusPath("2")).count == asked)
        #expect(try await marked(it.store).isEmpty)
    }

    // MARK: - Who is asked

    @Test("The authority is asked, never whoever handed the post over")
    func theAuthorityIsAskedAndNotTheRelay() async throws {
        // A post the relay carries and another server wrote, which is the ordinary case for
        // most of a federated timeline.
        let it = try await oneSuspect("relay", answering: 404)

        #expect(await it.loader.reconcile(now: t0) == [it.suspect.mergeKey])

        // The relay was asked for a page and nothing else. It having stopped carrying somebody
        // else's post says nothing about whether that post is still there, so its silence is
        // never what gets written down.
        #expect(stubRoutes.requests(for: it.authority, statusPath("2")).count == 1)
        #expect(stubRoutes.paths(for: "relay.reconcile.test") == [timeline])
        #expect(try await marked(it.store) == [it.suspect.mergeKey])
    }

    @Test("A post with no authority is never asked about, and so is never marked")
    func noAuthorityIsNeverMarked() async throws {
        let relay = makeServer("anonymous.reconcile.test")
        let authority = "anonymous-authority.reconcile.test"
        // No canonical address at all, so `posts.authority_url` is NULL and there is nobody
        // whose word on it could be final. Absent from the page exactly like its neighbour.
        let orphan = handedOver("9", from: relay.host)
        let (store, loader) = try await reaching(
            [handedOver("1", from: relay.host, authority: authority), orphan],
            page: statusesJSON(["1"], from: relay.host, authority: authority, at: [100]),
            from: relay
        )

        #expect(await loader.reconcile(now: t0).isEmpty)
        #expect(try await marked(store).isEmpty)
        // Nothing went anywhere. A post nobody can be asked about is not asked about, rather
        // than guessed at against whoever happened to hand it over.
        #expect(stubRoutes.paths(for: relay.host) == [timeline])
    }

    @Test("A canonical address of another shape is never asked about either")
    func anotherProjectsAddressIsNeverAsked() async throws {
        let relay = makeServer("othershape.reconcile.test")
        let authority = "othershape-authority.reconcile.test"
        // What a server that is not Mastodon names its posts. It carries no number this
        // endpoint could be asked about, and guessing one would fetch a status that was never
        // there and read the answer as a post withdrawn.
        let elsewhere = makePost(uri: "https://\(relay.host)/api/v1/statuses/9",
                                 originURI: "https://\(authority)/objects/6f1c-not-a-number",
                                 at: 100, from: relay.host)
        let (store, loader) = try await reaching(
            [handedOver("1", from: relay.host, authority: authority), elsewhere],
            page: statusesJSON(["1"], from: relay.host, authority: authority, at: [100]),
            from: relay
        )

        #expect(await loader.reconcile(now: t0).isEmpty)
        #expect(try await marked(store).isEmpty)
        // Nothing was sent, so that server has not been asked anything — and must not be put
        // into a wait for a question we could not phrase.
        #expect(stubRoutes.paths(for: authority).isEmpty)
    }

    @Test("A question we could not phrase starts no wait for the server we never asked")
    func anUnphrasableQuestionBlamesNobody() async throws {
        let relay = makeServer("unphrasable.reconcile.test")
        let authority = "unphrasable-authority.reconcile.test"
        let odd = makePost(uri: "https://\(relay.host)/api/v1/statuses/9",
                           originURI: "https://\(authority)/objects/6f1c-not-a-number",
                           at: 100, from: relay.host)
        let askable = handedOver("2", from: relay.host, authority: authority)
        let store = try LocalStore.inMemory()
        try await store.save([handedOver("1", from: relay.host, authority: authority), odd, askable],
                             from: relay)
        stubRoutes.on(authority, statusPath("2"), status: 404, body: "{}")
        let loader = stubbedLoader(store: store)

        // A first page leaving out only the post nobody here can phrase a question about.
        stubRoutes.on(relay.host, timeline, status: 200,
                      body: statusesJSON(["1", "2"], from: relay.host, authority: authority, at: [100, 100]))
        _ = await loader.loadOlder(servers: [relay], now: t0)
        #expect(await loader.reconcile(every: .seconds(30), now: t0).isEmpty)

        // A second page, this time leaving out one that can be asked about. Nothing was ever
        // sent about the first, so nothing about it can have put that server into a wait —
        // and the real question reaches the authority now rather than half a minute from now.
        stubRoutes.on(relay.host, timeline, status: 200,
                      body: statusesJSON(["1"], from: relay.host, authority: authority, at: [100]))
        _ = await loader.loadOlder(servers: [relay], now: t0.addingTimeInterval(1))
        let gone = await loader.reconcile(every: .seconds(30), now: t0.addingTimeInterval(1))

        #expect(gone == [askable.mergeKey])
        // One request in the whole test: the unphrasable one was never sent, and never
        // raised a second time either.
        #expect(stubRoutes.paths(for: authority) == [statusPath("2")])
    }

    // MARK: - The stretch a page speaks for

    @Test("A page speaks for the stretch it arrived with, not the one it was asked for")
    func theRangeIsWhatArrived() async throws {
        let relay = makeServer("stretch.reconcile.test")
        let authority = "stretch-authority.reconcile.test"
        // A page of forty asked for, three posts back — the ordinary shape of a range with a
        // blocked account in it. Only what falls between the newest and the oldest of those
        // three is a stretch this page can be said to have left anything out of.
        let missing = handedOver("7", from: relay.host, authority: authority, at: 700)
        let (store, loader) = try await reaching(
            [handedOver("9", from: relay.host, authority: authority, at: 900),
             missing,
             handedOver("5", from: relay.host, authority: authority, at: 500),
             handedOver("3", from: relay.host, authority: authority, at: 300)],
            page: statusesJSON(["9", "5"], from: relay.host, authority: authority, at: [900, 500]),
            from: relay
        )
        stubRoutes.on(authority, statusPath("7"), status: 404, body: "{}")
        stubRoutes.on(authority, statusPath("3"), status: 404, body: "{}")

        let gone = await loader.reconcile(now: t0)

        // 7 sits between the page's newest and oldest and was left out, so it is a question.
        // 3 is older than anything that arrived: this page never reached it, and a page that
        // did not reach a post has said nothing at all about it.
        #expect(gone == [missing.mergeKey])
        #expect(try await marked(store) == [missing.mergeKey])
        #expect(stubRoutes.requests(for: authority, statusPath("3")).isEmpty)
    }

    @Test("An empty page is an end, not a mass deletion")
    func anEmptyPageMarksNothing() async throws {
        let relay = makeServer("empty.reconcile.test")
        let authority = "empty-authority.reconcile.test"
        let stored = ["1", "2", "3"].map { handedOver($0, from: relay.host, authority: authority) }
        // Every one of them would be marked on the spot if it were ever asked about, so if an
        // empty page suspected the timeline this test could not pass by accident.
        for id in ["1", "2", "3"] { stubRoutes.on(authority, statusPath(id), status: 404, body: "{}") }

        let (store, loader) = try await reaching(stored, page: "[]", from: relay)

        // An empty page covers no stretch of time at all, so there is nothing it can be said
        // to have left out. It is the server saying it has nothing older, and that is all.
        #expect(await loader.reachedTheEnd(of: [relay]))
        #expect(await loader.reconcile(now: t0).isEmpty)
        #expect(try await marked(store).isEmpty)
        #expect(stubRoutes.paths(for: authority).isEmpty)
        #expect(try await store.timeline().count == 3)
    }

    // MARK: - The bound

    @Test("A pass confirms at most eight, and what is left over waits rather than being dropped")
    func theBoundHoldsAndTheRestWait() async throws {
        let relay = makeServer("bounded.reconcile.test")
        let authority = "bounded-authority.reconcile.test"
        // Eleven posts at one instant and a page carrying one of them: ten absent at once,
        // which is what turning a filter on looks like from here.
        let ids = (1...11).map(String.init)
        let stored = ids.map { handedOver($0, from: relay.host, authority: authority) }
        for id in ids { stubRoutes.on(authority, statusPath(id), status: 404, body: "{}") }

        let (store, loader) = try await reaching(
            stored, page: statusesJSON(["1"], from: relay.host, authority: authority, at: [100]), from: relay
        )

        let first = await loader.reconcile(now: t0)
        #expect(first.count == TimelineLoader.confirmationsPerPass)
        #expect(try await marked(store).count == TimelineLoader.confirmationsPerPass)

        // The overflow was not counted as checked, and it was not thrown away either: the
        // next pass takes it, and the two passes together account for every absent post.
        let second = await loader.reconcile(now: t0.addingTimeInterval(1))
        #expect(second.count == 2)
        #expect(first.union(second) == Set(stored.dropFirst().map(\.mergeKey)))

        // And with nothing left in the queue, nobody is asked anything more.
        #expect(await loader.reconcile(now: t0.addingTimeInterval(2)).isEmpty)
        #expect(stubRoutes.paths(for: authority).count == 10)
    }
}

/// The queue underneath the pass: what it hands out, what it holds back, and what it forgets.
/// Straight against the actor, because a bound and a hand-back are easier to be sure of when
/// nothing is standing between the assertion and the state.
@Suite("The queue of posts waiting to be asked about")
struct ReconcilerTests {
    private let authority = "https://wrote-it.queue.test"

    private func subject(_ id: String) -> PostAuthority {
        PostAuthority(post: handedOver(id, from: "relay.queue.test", authority: "wrote-it.queue.test"),
                      authorityURL: authority)
    }

    /// The id back out of a suspect, for asserting on which ones a pass took.
    private func ids(_ subjects: [PostAuthority]) -> [String] {
        subjects.map { URL(string: $0.post.uri)!.lastPathComponent }
    }

    /// Every one of `subjects` answered for the same way, as `settle` wants it.
    private func all(_ subjects: [PostAuthority],
                     _ verdict: Reconciler.Verdict) -> [String: Reconciler.Verdict] {
        Dictionary(uniqueKeysWithValues: subjects.map { ($0.post.mergeKey, verdict) })
    }

    @Test("Suspecting the same post twice leaves one question, not two")
    func oneQuestionPerPost() async {
        let queue = Reconciler()

        await queue.suspect([subject("1"), subject("2")])
        await queue.suspect([subject("1")])

        #expect(await queue.suspected.count == 2)
        #expect(await queue.take(10, avoiding: []).count == 2)
    }

    @Test("A question already out is not asked a second time while it is out")
    func oneAskingAtATime() async {
        let queue = Reconciler()
        await queue.suspect([subject("1")])

        #expect(await queue.take(10, avoiding: []).count == 1)
        #expect(await queue.take(10, avoiding: []).isEmpty)
    }

    @Test("An authority inside its wait keeps its questions, and they are not counted as asked")
    func aBlockedAuthorityIsPassedOver() async {
        let queue = Reconciler()
        await queue.suspect([subject("1")])

        #expect(await queue.take(10, avoiding: [authority]).isEmpty)
        // Passed over is not settled: the question is still there for a pass that can ask it.
        #expect(await queue.suspected.count == 1)
        #expect(await queue.take(10, avoiding: []).count == 1)
    }

    @Test("What was answered for goes; what was only asked comes back")
    func settlingKeepsTheUndecided() async {
        let queue = Reconciler()
        let (answered, unanswered) = (subject("1"), subject("2"))
        await queue.suspect([answered, unanswered])

        _ = await queue.take(10, avoiding: [])
        await queue.settle([answered.post.mergeKey: .settled, unanswered.post.mergeKey: .unknown])

        #expect(await queue.suspected == [unanswered.post.mergeKey])
        // And it is free to be asked again rather than stuck as a question already out.
        #expect(await queue.take(10, avoiding: []).map(\.post.mergeKey) == [unanswered.post.mergeKey])
    }

    @Test("A question nobody could put into words is not raised again by the next page")
    func theUnanswerableIsNotSuspectedTwice() async {
        let queue = Reconciler()
        let odd = subject("1")
        await queue.suspect([odd])

        _ = await queue.take(10, avoiding: [])
        await queue.settle([odd.post.mergeKey: .unanswerable])
        #expect(await queue.suspected.isEmpty)

        // Every later page covering it would raise the same unanswerable question. Dropping it
        // once is not enough: it has to stay dropped, or it takes a slot of the bound on every
        // pass for the rest of the run, and the posts that could be settled queue behind it.
        await queue.suspect([odd])
        #expect(await queue.suspected.isEmpty)
        #expect(await queue.take(10, avoiding: []).isEmpty)
    }

    @Test("A refusal is not an answer, but a standing refusal is set aside")
    func aStandingRefusalIsSetAside() async {
        let queue = Reconciler()
        let private_ = subject("1")
        await queue.suspect([private_])

        // Under the threshold the question is kept: one refusal is a moment, not a policy,
        // and the post is asked about again the next pass.
        for _ in 1..<Reconciler.refusalsBeforeSettingAside {
            let asked = await queue.take(10, avoiding: [])
            #expect(asked.count == 1)
            await queue.settle(all(asked, .refused))
            #expect(await queue.suspected == [private_.post.mergeKey])
        }

        // The last one settles it aside: not marked, not answered for, simply no longer
        // holding one of the eight places a pass has to spend.
        let last = await queue.take(10, avoiding: [])
        await queue.settle(all(last, .refused))

        #expect(await queue.suspected.isEmpty)
        await queue.suspect([private_])
        #expect(await queue.suspected.isEmpty)
        #expect(await queue.take(10, avoiding: []).isEmpty)
    }

    /// Silence decides nothing about a post, and no number of silences ever will — but a
    /// question that can never be answered still has to stop holding a place, or an authority
    /// that is simply gone takes the queue with it.
    @Test("An authority that only ever goes quiet stops holding a place in the queue")
    func aStandingSilenceIsSetAside() async {
        let queue = Reconciler()
        let unreachable = subject("1")
        await queue.suspect([unreachable])

        // Under the threshold nothing is given up: silence is not an answer, and the post is
        // asked about again the next pass, exactly as it always was.
        for _ in 1..<Reconciler.silencesBeforeSettingAside {
            let asked = await queue.take(10, avoiding: [])
            #expect(asked.count == 1)
            await queue.settle(all(asked, .unknown))
            #expect(await queue.suspected == [unreachable.post.mergeKey])
        }

        let last = await queue.take(10, avoiding: [])
        await queue.settle(all(last, .unknown))

        // Set aside, not settled: nothing was marked and nothing was written, and the post is
        // still on the screen and in the store. It has only stopped being a question.
        #expect(await queue.suspected.isEmpty)
        await queue.suspect([unreachable])
        #expect(await queue.suspected.isEmpty)
        #expect(await queue.take(10, avoiding: []).isEmpty)
    }

    /// The failure this is really for. An authority that is permanently unreachable, with a
    /// round's worth of its posts suspected, fills `questionsAtOnce` — and if silence never
    /// frees a place, `suspect` turns every later page away for the rest of the run and
    /// reconcile is deaf. That is the permanently-full queue that dropping the oldest was
    /// rejected for causing, arriving by the other road.
    @Test("A dead authority's suspects do not shut the queue for the rest of the run")
    func aDeadAuthorityDoesNotShutTheQueue() async {
        let queue = Reconciler()
        await queue.suspect((1...Reconciler.questionsAtOnce).map { subject(String($0)) })
        #expect(await queue.suspected.count == Reconciler.questionsAtOnce)

        for _ in 1...Reconciler.silencesBeforeSettingAside {
            let asked = await queue.take(Reconciler.questionsAtOnce, avoiding: [])
            await queue.settle(all(asked, .unknown))
        }

        // The queue is open again, and the next page's question is taken rather than dropped.
        let live = subject("live")
        await queue.suspect([live])
        #expect(await queue.suspected == [live.post.mergeKey])
    }

    @Test("Refusals counted for one post say nothing about another")
    func refusalsAreCountedPerPost() async {
        let queue = Reconciler()
        let (refused, other) = (subject("1"), subject("2"))
        await queue.suspect([refused, other])

        for _ in 1...Reconciler.refusalsBeforeSettingAside {
            let asked = await queue.take(10, avoiding: [])
            await queue.settle([refused.post.mergeKey: .refused, other.post.mergeKey: .unknown])
            #expect(asked.contains { $0.post.mergeKey == other.post.mergeKey })
        }

        // One went quiet; the other is still a live question, having only ever met silence.
        #expect(await queue.suspected == [other.post.mergeKey])
    }

    /// The bound at the point of asking does not bound the remembering: a pass spends eight
    /// and one round of pages can raise a great many more than eight, so without a ceiling
    /// here the queue grows faster than it drains and every entry holds a whole `Post`.
    @Test("A queue at its ceiling stops taking questions on rather than growing without end")
    func theQueueHasACeiling() async {
        let queue = Reconciler()

        await queue.suspect((1...(Reconciler.questionsAtOnce + 50)).map { subject(String($0)) })

        #expect(await queue.suspected.count == Reconciler.questionsAtOnce)
    }

    /// The newest is what is dropped, never the oldest: the oldest are the ones being worked
    /// off, and dropping those would leave a queue permanently full and permanently
    /// unfinished. What is dropped is a question deferred, not a question answered — the next
    /// page covering that post raises it again.
    @Test("Over the ceiling it is the newest question that is left for later, not the oldest")
    func theCeilingKeepsTheFrontOfTheQueue() async {
        let queue = Reconciler()
        await queue.suspect((1...Reconciler.questionsAtOnce).map { subject(String($0)) })

        let late = subject("late")
        await queue.suspect([late])
        #expect(await queue.suspected.contains(late.post.mergeKey) == false)

        // The front is untouched, and room made at it is room the deferred question can have.
        let front = await queue.take(1, avoiding: [])
        #expect(ids(front) == ["1"])
        await queue.settle(all(front, .settled))
        await queue.suspect([late])
        #expect(await queue.suspected.contains(late.post.mergeKey))
    }

    @Test("The oldest question is asked first, so a backlog does not starve its front")
    func oldestFirst() async {
        let queue = Reconciler()
        await queue.suspect((1...5).map { subject(String($0)) })

        let first = await queue.take(2, avoiding: [])
        await queue.settle(all(first, .settled))
        let second = await queue.take(2, avoiding: [])

        #expect(ids(first) == ["1", "2"])
        #expect(ids(second) == ["3", "4"])
    }
}
