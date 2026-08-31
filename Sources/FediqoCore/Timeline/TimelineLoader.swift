import Foundation
import GRDB

/// Who asked for a load, which is the whole of what a backoff is for.
///
/// A reader who asked is answered at once, because they asked. A clock that asked is a guest
/// on other people's machines: it leaves alone whatever could not answer last time, and
/// lengthens that wait every time nothing arrives.
public enum Refresh: Sendable {
    /// The reader asked. Every server is asked, whatever it did last time, and a server that
    /// still cannot answer is not punished for it — only the clock's own failures lengthen
    /// the clock's own wait. An answer here still forgives, so pulling to refresh is how a
    /// backed-off server comes back at once.
    case manual
    /// The clock asked, every `every`. A server still inside its wait is not asked at all,
    /// and one that gives nothing waits twice as long next time, starting at `every`.
    case automatic(every: Duration)
}

public struct TimelineResult: Sendable {
    /// One row per post. The timeline is in timestamp order; trending is in the servers' own
    /// rank order. Nothing here is ranked by us, and nothing is re-ordered after the fact.
    public let posts: [Post]
    /// Why a server gave what it gave, at most one reason per server — keyed by
    /// `Server.endpoint`, not by hostname: one host can be a source twice under two
    /// protocols, and their fates are not the same fact. The reason inside still names the
    /// bare host, because that is what a screen says to the reader.
    ///
    /// Every case but `.tokenRejected` and `.store` means that server gave nothing; those
    /// two ride alongside posts that did arrive, so a caller reading a server's fate reads
    /// `posts` for whether anything came and `failures` for whether anything needs attention.
    public let failures: [String: SourceFailure]
    /// The servers this load did not ask at all, by `Server.endpoint`. A refresh leaves out
    /// whoever is still inside a wait; a reach for the bottom leaves out those and whoever
    /// has run out of history or has a page still in flight. They are not failing now and
    /// they are not answering either, so they are in neither `posts` nor `failures` — and a
    /// caller that draws a server's fate needs to be told the difference between a server
    /// that had nothing to say and one that was never asked.
    public let skipped: Set<String>
    /// What arrived and is not in `posts`, and what kept each of them off the screen.
    ///
    /// #6's last promise. Only ever this app's own doing: a post a server never handed over is
    /// not here to say anything about, and that half of the question is answered by `failures`
    /// and `skipped` above. Empty on a timeline with no rules, which is most of them.
    public let hidden: [Hidden]

    public init(posts: [Post], failures: [String: SourceFailure], skipped: Set<String> = [],
                hidden: [Hidden] = []) {
        self.posts = posts
        self.failures = failures
        self.skipped = skipped
        self.hidden = hidden
    }

    public var isEmpty: Bool { posts.isEmpty }

    /// Every server's standing reason: what `known` already said, carried through this load.
    ///
    /// A server inside its wait is absent from `failures` because it was not asked, so
    /// taking a load's failures alone would strike its reason off the screen and put it
    /// back a tick later, though nothing about the server changed. Here a skipped server
    /// keeps whatever was already known about it; a server that was asked is judged by this
    /// load alone, so answering clears its line; and a server no longer among `servers` is
    /// forgotten, since it is nobody's source now.
    public func failures(carrying known: [String: SourceFailure],
                         of servers: [Server]) -> [String: SourceFailure] {
        let ours = Set(servers.map(\.endpoint))
        var standing = known.filter { ours.contains($0.key) && skipped.contains($0.key) }
        for (endpoint, failure) in self.failures where ours.contains(endpoint) {
            standing[endpoint] = failure
        }
        return standing
    }

    /// What the screen should show, given what it was already showing.
    ///
    /// A refresh that came back with nothing has not emptied anything: the store still holds
    /// what it held, and the promise this app makes is that a server being down leaves every
    /// existing row where it was and simply adds nothing. Replacing the screen with a refresh
    /// that failed would make an unreachable server look like an empty one, which is the one
    /// thing an empty screen is supposed to mean.
    ///
    /// Asking nobody is different from asking and being told nothing: with no sources left
    /// there is nothing whose rows these would be, so they go.
    ///
    /// And a refresh speaks for the top of the timeline and for nothing under it — it asked
    /// every server for its newest page, which is what a refresh is. So whatever the reader
    /// had already read down to below that page stays where it is: replacing the whole list
    /// would snap it back to one page under them every time the clock ticked, undoing the
    /// reading rather than adding to it.
    public func posts(carrying shown: [Post], asked servers: [Server]) -> [Post] {
        guard let cut = posts.last else { return servers.isEmpty ? posts : shown }
        let covered = Set(posts.map(\.mergeKey))
        return posts + shown.filter {
            Post.isOlder($0, than: cut) && !covered.contains($0.mergeKey)
        }
    }
}

/// Reads every server at once and hands back one stream in one order.
///
/// It knows about `SourceClient`, never about a protocol. A source this build cannot yet read
/// is a reported failure, not a quiet omission — the same rule the rest of the file follows.
///
/// The timeline is merged by time. A trending list is the server's own order, kept: a post's
/// rank is its place in the list the server handed over, and across servers the best rank
/// wins — the same order the store reads trends back in, so the page that opened from the
/// store and the page that just refreshed do not trade places.
public struct TimelineLoader: Sendable {
    private let registry: SourceRegistry
    private let limit: Int
    private let store: LocalStore?
    /// Who each server is read as. Nil without a store: nobody is signed in anywhere, so
    /// there is nothing to resolve and the Keychain is never opened.
    private let tokenSource: TokenSource?
    /// How long each server is to be left alone. One per loader, so a timeline that could
    /// not be had says nothing about the same server's trending list.
    private let backoff = ServerBackoff()
    /// Where each server has got to reading backwards. One per loader, beside the backoff and
    /// for the same reason: the two feeds page independently, and trending does not page at all.
    private let paging = ServerPaging()
    /// The posts a page should have contained and did not, waiting to be asked about. Beside
    /// the other two and for their reasons; only a timeline can leave a post out, so trending
    /// never puts anything here.
    private let reconciler = Reconciler()

    /// How many suspects one pass is allowed to ask about, and why there is a number at all:
    /// a filter turned on can make a whole page absent at once, and forty single-post requests
    /// fired at other people's servers because a reader changed a setting is not a reasonable
    /// thing to do to them.
    ///
    /// Eight, because that keeps a pass the same order of magnitude as the page fetch it rides
    /// beside — a chosen list is a handful of servers, so reaching the bottom already costs a
    /// handful of requests — while still working a suspected page of forty off in five passes,
    /// which is a few seconds of reading. Smaller would leave a real backlog crawling behind
    /// the reader; larger would turn one changed setting into a burst.
    static let confirmationsPerPass = 8

    /// With a `store`, what each server hands over is kept before it is merged; without one,
    /// nothing is remembered between loads — and nobody is signed in either, so a loader
    /// without a store reads every server as a stranger and never opens `secrets`.
    ///
    /// Pass `tokens` to share one resolver with everything else that needs to know who is
    /// signed in — the launch check, in practice, and the other feed. Without one the loader
    /// keeps its own, which is right for a preview and for a test and for nothing else.
    public init(registry: SourceRegistry = .standard(), limit: Int = 40, store: LocalStore? = nil,
                secrets: any SecretStore = KeychainSecretStore(),
                tokens: TokenSource? = nil) {
        self.registry = registry
        self.limit = limit
        self.store = store
        self.tokenSource = tokens ?? store.map { TokenSource(store: $0, secrets: secrets) }
    }

    /// What the store already holds for this reading, in its own order — the screen before any
    /// server answers. Nothing without a store.
    ///
    /// The rules are applied here, by the store, and not to a list afterwards: a timeline that
    /// keeps one post in fifty would otherwise read a page of two hundred to show four.
    public func stored(_ query: TimelineQuery, now: Date = Date()) async throws -> [Post] {
        guard let store else { return [] }
        return try await store.timeline(matching: query, now: now)
    }

    /// The store's page before `post` — what the reader's next page down is already here,
    /// before anybody's server is asked for it — and, separately, what went wrong. The shape
    /// a read from a server comes back in, because it is the same kind of answer.
    ///
    /// Three answers and not two. A page. Nothing older, which is the store spent and the
    /// reader's cue to go to the network in earnest. And a store that would not say, which is
    /// neither of those: it is our own database having a bad moment, and reading it as the
    /// second buys a burst of somebody else's bandwidth with it. A `try?` at the call site is
    /// exactly what collapses those two, so the difference is kept here instead.
    ///
    /// A page the size a server is asked for, so the list grows by the same step whichever
    /// answered it and a reader cannot tell from the length of the page where it came from.
    /// The cursor is a post, the way it is for a server, so the two cannot disagree about
    /// where the last page ended. Nothing without a store, which is what a preview has.
    public func storedOlder(than post: Post, matching query: TimelineQuery)
        async -> (posts: [Post], failure: SourceFailure?) {
        guard let store else { return ([], nil) }
        do {
            return (try await store.timeline(matching: query, limit: limit, before: post), nil)
        } catch {
            // What SQLite said, in full, is for the log; the caller gets the reason to show.
            LocalStore.log.error("""
                reading the page before \(post.mergeKey, privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """)
            let reason = (error as? DatabaseError)?.message ?? error.localizedDescription
            return ([], .store(reason))
        }
    }

    /// Every server asked at once, merged into one stream in one order.
    ///
    /// `refresh` says who asked, and the default is the reader — so a caller that has no
    /// clock asks everyone, which is what every caller did before there was one.
    public func load(servers: [Server], query: TimelineQuery,
                     refresh: Refresh = .manual, now: Date = Date()) async -> TimelineResult {
        // A server still inside its wait is not asked, and is not reported either: it is not
        // failing now, it is being left alone. What it said last time is not lost with it —
        // it comes back named in `skipped`, so a screen can keep showing the reason rather
        // than blinking it off and on as the server enters and leaves its wait.
        let (asked, skipped) = await askable(servers, refresh: refresh, now: now)
        // No cursors: a refresh asks everyone for their newest page, which is what it is.
        let round = await fanOut(asked.map { ($0, nil) }, query: query)
        await record(round.failures, from: round.reached, refresh: refresh, now: now)

        // Everything that arrived is kept; only what this timeline is about is handed back.
        // The two are different jobs and the store's is the wider one — a post filtered out
        // here is still a post the next timeline may be entirely about, and asking somebody's
        // server for it twice because we threw it away is the one thing worth avoiding.
        let posts = query.source.ranked ? Self.mergedByRank(round.collected)
                                        : round.collected.flatMap { $0 }.merged()
        // Sifted rather than filtered: what the rules turned away is carried alongside what
        // they let through, so a reader can ask why a post they expected is not here.
        // Sifted rather than filtered: what the rules turned away is carried alongside what
        // they let through, so a reader can ask why a post they expected is not here.
        let sifted = query.sifted(posts)
        return TimelineResult(posts: sifted.admitted, failures: round.failures, skipped: skipped,
                              hidden: sifted.hidden)
    }

    /// Every server asked at once for the page before what it last handed over, merged into
    /// one stream the way `load` merges it.
    ///
    /// The counterpart to `load` and a different question: `load` asks everyone for the newest
    /// page, this asks each server for what came before its own last post. Only a timeline has
    /// one, so there is no `mode` here — a trending list is a snapshot a server curated, and
    /// what came before it means nothing (see `SourceClient.trending`).
    ///
    /// Three kinds of server go unasked, and they are three different facts. One that has said
    /// it has nothing older has reached its end; one whose page is still out is being waited
    /// for, however hard the reader scrolls; one inside its wait is being left alone. The rest
    /// carry on without them — and all three come back in `skipped`, because whichever of the
    /// three it was, this round asked them nothing and so has nothing to say about them.
    ///
    /// Whether that was the last page anyone had is `reachedTheEnd(of:)`'s to say, because it
    /// is a standing fact about the servers rather than something this page brought back.
    ///
    /// `every` is how long a server that gives nothing here is left alone before it is asked
    /// for another page — the wait doubles and is forgiven exactly as it is on a refresh.
    public func loadOlder(servers: [Server], query: TimelineQuery, every: Duration = .seconds(30),
                          now: Date = Date()) async -> TimelineResult {
        // Unlike a refresh, nobody here is saying "ask anyway". Reaching the bottom is the
        // scroll's doing, and a scroll is as tireless as a clock, so a server inside its wait
        // is left alone whoever's finger started this — which is what `.automatic` means.
        let (notWaiting, _) = await askable(servers, refresh: .automatic(every: every), now: now)
        // Cold start — the store holds posts but nobody has asked a server for a page yet, so
        // every cursor here is nil and the first page each server gives is its newest. That
        // page sits above the foot the reader has read down to, not below it, and two things
        // follow from that.
        //
        // The overlap is nothing: `mergeKey` collapses a post the store already had, the same
        // fold two servers carrying one post go through.
        //
        // The hole is real: between the oldest post in that first page and the foot of the
        // store there is a stretch this page does not reach. It is left open knowingly.
        // Closing it would mean seeding a cursor from the store, which means naming the oldest
        // post *this server* handed over — and the store does not know that. `posts.source_url`
        // is only the first server to hand a post over, so the foot of a store page is nobody's
        // cursor but the merged timeline's. Guessing it would skip whatever that server holds
        // in the stretch, which is a hole that never closes. This one closes by itself: each
        // cursor walks down its own server's thread of time, so the next reach for the bottom
        // asks from where this page ended, and the one after that from where that one ended.
        // The cost is round trips that append nothing the reader had not already read.
        // The whole chosen list, before anyone is claimed: what is remembered about a server
        // nobody reads any more goes, so one dropped and added back inside a run is asked
        // again rather than passed over as spent (decision 9).
        await paging.forget(everyoneBut: servers)
        let claimed = await paging.claim(notWaiting)
        // Everyone this round did not ask, whichever of the three reasons kept them out of it —
        // which is why it is taken from the chosen list against what was claimed rather than
        // from the wait alone. A spent server and one whose page is still out went unasked as
        // surely as one inside its wait, and a round that leaves them out of `skipped` as well
        // as out of `failures` is a round claiming it judged them and found nothing wrong.
        // `failures(carrying:of:)` would then strike their standing reason off the screen —
        // and `.tokenRejected` reaches exactly here, since it counts as having arrived, starts
        // no wait, and so is the one reason a server carries all the way to running out.
        let unasked = Set(servers.map(\.endpoint)).subtracting(claimed.map(\.server.endpoint))
        // Every claim is given back here and nowhere else. Silence says nothing about where a
        // server had got to, so its cursor stands and it is not counted as having run out;
        // anything that arrived — posts, or posts the store would not keep — moves the cursor
        // to that page's last post, and ends the server where the page came back empty.
        let round = await fanOut(claimed, query: query) { endpoint, answer in
            if let failure = answer.failure, !failure.arrivedAnyway {
                await paging.gaveNothing(endpoint)
            } else {
                await paging.gave(answer.posts, endpoint)
            }
        }
        await record(round.failures, from: round.reached,
                     refresh: .automatic(every: every), now: now)

        let sifted = query.sifted(round.collected.flatMap { $0 }.merged())
        return TimelineResult(posts: sifted.admitted, failures: round.failures, skipped: unasked,
                              hidden: sifted.hidden)
    }

    /// The conversation around one post as the store already has it — instant, offline, and
    /// only as much of it as the timeline happened to carry past us.
    public func storedThread(around post: Post) async -> Conversation {
        guard let store else { return Conversation(post: post) }
        do {
            return try await store.thread(around: post)
        } catch {
            LocalStore.log.error("reading a thread failed: \(String(describing: error), privacy: .public)")
            return Conversation(post: post)
        }
    }

    /// The conversation as the post's own server has it, kept on the way past.
    ///
    /// One request, to one server, because a reader asked for it — which is what separates it
    /// from everything else that talks to other people's machines here. There is no budget and
    /// no backoff on it for the same reason `stillHas` has one and this does not: nothing here
    /// fires on a clock.
    ///
    /// **The authority is asked, never the relay.** A server that carried somebody else's post
    /// knows whatever replies happened to reach it; the server the post lives on is the one
    /// with the conversation. That is the rule `reconcile` follows, for the same reason.
    ///
    /// What comes back is written down like any other arrival, through the `thread` base
    /// source — those posts were handed over by a server, and throwing them away would mean
    /// asking for them again the next time somebody opens the same post.
    public func conversation(around post: Post) async -> (conversation: Conversation, failure: SourceFailure?) {
        guard let authority = await authorityHost(of: post),
              let client = registry.client(for: post.socialProtocol) else {
            return (Conversation(post: post), nil)
        }
        let server = Server(host: authority, socialProtocol: post.socialProtocol, title: authority)
        let token = await tokensByEndpoint(for: [server])[server.endpoint]
        do {
            let context = try await client.context(of: post, host: authority, token: token)
            do {
                try await store?.save(context.ancestors + context.descendants, from: server, into: .thread)
            } catch {
                LocalStore.log.error("keeping a thread failed: \(String(describing: error), privacy: .public)")
            }
            return (context, nil)
        } catch {
            return (Conversation(post: post), SourceFailure.of(error))
        }
    }

    /// The host whose word on this post is final: the store's `authority_url` where it has one,
    /// and the server that handed the post over where it does not — which is a preview, a test,
    /// or a protocol that names no authority at all.
    private func authorityHost(of post: Post) async -> String? {
        if let store, let known = try? await store.posts(named: [post.mergeKey]).first {
            return LocalStore.host(of: known.authorityURL)
        }
        return post.sourceURL.isEmpty ? nil : LocalStore.host(of: post.sourceURL)
    }

    /// Every one of `servers` has said it has nothing older, so there is nothing left to reach
    /// for. The one thing on which a screen may say the reading is over — and a standing fact
    /// about the servers rather than a property of any one page, which is why it is asked for
    /// here rather than carried back by `loadOlder`.
    public func reachedTheEnd(of servers: [Server]) async -> Bool {
        await paging.reachedTheEnd(of: servers)
    }

    /// One bounded pass at the suspects: posts a page should have contained and did not, each
    /// asked about by name — of the server whose word on it is final, never of whoever handed
    /// it over, because a server that has stopped carrying somebody else's post has said
    /// nothing about whether that post is still there. A relay's silence is not evidence.
    ///
    /// What an authority answers is the only thing that writes anything. It will not hand the
    /// post over any more, and `deleted_at` is set; it will, and the suspicion is dropped.
    /// Anything that is not an answer — offline, a 5xx, a timeout — decides nothing at all:
    /// the post stays suspected and is asked about again another time, because "we could not
    /// reach them" and "we checked" are different facts and only one of them is true.
    ///
    /// **What `deleted_at` then means.** Not "the author deleted it" — only that the authority
    /// will not hand the post over any more. The measurement behind reading 404 and 410 as one
    /// answer is written out once, on `SourceClient.stillHas`, and for the reader in
    /// `docs/data-store.md`.
    ///
    /// The asking is anonymous, which is part of why the mark claims so little: the authority
    /// is usually not a server anybody here is signed in to — it is wherever the post was
    /// written — so there is generally no credential to send it.
    ///
    /// At most `confirmationsPerPass` are asked about, and an authority inside its wait is not
    /// asked at all — the same wait a timeline page respects, kept in the same place. Whatever
    /// is left over waits for the next pass; nothing unasked is counted as checked.
    ///
    /// Hands back the merge keys of the posts confirmed gone, so a screen showing one can stop.
    @discardableResult
    public func reconcile(every: Duration = .seconds(30), now: Date = Date()) async -> Set<String> {
        let blocked = await backoff.blocked(at: now)
        let asking = await reconciler.take(Self.confirmationsPerPass, avoiding: blocked)
        guard !asking.isEmpty else { return [] }

        var failures: [String: SourceFailure] = [:]
        // The authorities that said something, whatever it was. Kept apart from `failures`
        // because one authority can be asked about several posts at once and answer for only
        // some of them, and having answered for any it is not silent.
        var answered: Set<String> = []
        // The merge keys the authority will not hand over any more, waiting to be written.
        var gone: [String] = []
        // What this pass learned about each post it asked about — see `Reconciler.Verdict`.
        // Every subject taken gets an entry, so the queue can tell apart the ones it may
        // close from the ones it must hand back.
        var verdicts: [String: Reconciler.Verdict] = [:]

        await withTaskGroup(of: (PostAuthority, Result<Bool, SourceFailure>).self) { group in
            for subject in asking {
                guard let client = registry.client(for: subject.post.socialProtocol) else {
                    // Nothing in this build can ever answer for it — and it will not start
                    // speaking that protocol in a minute, so this is not a question worth
                    // keeping. Nothing was sent, so no server is judged for it either.
                    verdicts[subject.post.mergeKey] = .unanswerable
                    continue
                }
                group.addTask { (subject, await Self.stillThere(client, subject)) }
            }
            for await (subject, verdict) in group {
                switch verdict {
                case .success(let stillThere):
                    answered.insert(subject.authorityURL)
                    // A post found gone is only settled once the mark is actually written, so
                    // it starts here as nothing learned and is upgraded below.
                    verdicts[subject.post.mergeKey] = stillThere ? .settled : .unknown
                    if !stillThere { gone.append(subject.post.mergeKey) }
                case .failure(.notItsPost):
                    // The client could not name this post on that server, so nothing was
                    // sent: the authority has not been asked anything, and so is recorded
                    // nowhere here — no answer, no failure, no wait. That is decision 8's
                    // rule, that our own wiring never reaches anybody wearing a server's
                    // fault. The question is dropped for good rather than left to spend a
                    // slot of the bound on every pass for the rest of the run.
                    verdicts[subject.post.mergeKey] = .unanswerable
                case .failure(.needsSignIn):
                    // The server answered at once and declined to discuss this post with a
                    // stranger. That is an answer, so it starts no wait — and it decides
                    // nothing about the post, which is asked about again another time.
                    //
                    // Counting it as silence would be actively harmful rather than merely
                    // wrong. `arrivedAnyway` calls `.needsSignIn` a non-arrival because for a
                    // timeline read it means no posts came; here it means the opposite. And
                    // the wait is keyed by endpoint and shared with the chosen servers, so an
                    // anonymous probe being refused would put a server's own signed-in
                    // timeline into a wait it never earned.
                    //
                    // It decides nothing about the post, so the post is asked about again —
                    // but not for ever. A standing refusal is a standing answer, and after
                    // `Reconciler.refusalsBeforeSettingAside` of them the question is set
                    // aside so that a handful of private posts cannot hold slots the bound
                    // was meant to spend on suspects that can actually be settled.
                    answered.insert(subject.authorityURL)
                    verdicts[subject.post.mergeKey] = .refused
                case .failure(let failure):
                    failures[subject.authorityURL] = failure
                    verdicts[subject.post.mergeKey] = .unknown
                }
            }
        }
        // An authority that answered for any of its posts is not silent about the rest, so its
        // failures are struck out rather than allowed to start a wait for a server that is
        // plainly talking to us. What is left is silence, and everything asked at all is the
        // two together — there is no third set to keep in step.
        for endpoint in answered { failures[endpoint] = nil }

        var marked: Set<String> = []
        for key in gone {
            do {
                try await store?.markDeleted(mergeKey: key)
                marked.insert(key)
                // The verdict is written here because this is where it becomes true: a post
                // found gone is settled by the mark going down, not by the answer that
                // prompted it, which is why it started as `.unknown` above.
                verdicts[key] = .settled
            } catch {
                // The authority answered and its answer stands; only the writing of it failed.
                // So the suspicion is kept, and the post is asked about again another time.
                LocalStore.log.error("""
                    marking \(key, privacy: .public) deleted failed: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }

        await reconciler.settle(verdicts)
        await record(failures, from: answered.union(failures.keys),
                     refresh: .automatic(every: every), now: now)
        return marked
    }

    /// What a page that came back did not contain, of the posts the store holds from that
    /// server inside the stretch the page covered.
    ///
    /// The stretch is what arrived, not what was asked for. A page of forty that came back
    /// with three covers those three and no more: a server takes blocked accounts and filtered
    /// posts out of a range it has already chosen, so the rest of the range it was asked for
    /// is not this page's to speak for.
    ///
    /// **An empty page covers no stretch at all**, and so leaves nothing out. It is an end —
    /// the server saying it has nothing older — and reading it as a page that omitted
    /// everything would suspect the entire timeline every time a reader reached the bottom.
    ///
    /// Every timeline page runs through here, a refresh's as much as a reach-down's: which of
    /// them asked says nothing about what the page is evidence of. The volume stays small by
    /// construction rather than by policy — only posts inside the returned page's own range
    /// can be suspected, and a refresh's range is a narrow one.
    ///
    /// Nothing is written here, and nothing is asked. Absence raises a question; `reconcile`
    /// is what asks it, and only an answer writes anything.
    ///
    /// The healthy page is the one this is written for, because it is nearly every page: the
    /// server handed over everything the store had in the stretch, and there is nothing to
    /// suspect. So the store is asked for names rather than posts, the diff is done on those,
    /// and a post is built only for what the diff leaves standing — which on that page is
    /// nothing at all, and used to be a page's worth of rows joined, tagged and thrown away.
    private func suspectMissing(_ page: [Post], from endpoint: String, through query: TimelineQuery) async {
        guard let store, let first = page.first else { return }
        // One pass for all three: the stretch the page covers, and the keys it covered it with.
        var oldest = first.createdAt
        var newest = first.createdAt
        var handed: Set<String> = [first.mergeKey]
        handed.reserveCapacity(page.count)
        for post in page.dropFirst() {
            if post.createdAt < oldest { oldest = post.createdAt }
            if post.createdAt > newest { newest = post.createdAt }
            handed.insert(post.mergeKey)
        }
        do {
            let covered = try await store.postKeys(from: endpoint, through: query.source,
                                                   as: query.account, postedIn: oldest...newest)
            let missing = covered.filter { !handed.contains($0) }
            guard !missing.isEmpty else { return }
            await reconciler.suspect(try await store.posts(named: missing))
        } catch {
            // Not being able to read our own store says nothing about anybody's post, so it
            // goes in the log and this page simply raises no questions.
            LocalStore.log.error("""
                reading \(endpoint, privacy: .public) back to reconcile it failed: \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// One post asked about, and what came back. A failure is not `false`: the two are exactly
    /// the difference between a server saying no and a server saying nothing.
    private static func stillThere(_ client: any SourceClient,
                                   _ subject: PostAuthority) async -> Result<Bool, SourceFailure> {
        do {
            return .success(try await client.stillHas(subject.post,
                                                      host: LocalStore.host(of: subject.authorityURL),
                                                      token: nil))
        } catch {
            return .failure(SourceFailure.of(error))
        }
    }

    /// What one server handed over, and separately what went wrong — a store that would not
    /// keep the posts is a failure worth reporting, but the posts still arrived.
    private typealias Answer = (posts: [Post], failure: SourceFailure?)

    /// The fan-out both loads are made of: every target asked at once, as whoever is signed in
    /// to it, and what each one answered collected in one place.
    ///
    /// A target is a server and the cursor to ask it from — nil throughout for a refresh,
    /// which asks everyone for their newest page. `answered` is told what each one gave as it
    /// gives it, which is where a paging load writes down where that server has got to; a
    /// refresh has nothing to write down and passes nothing.
    private func fanOut(
        _ targets: [(server: Server, cursor: Post?)], query: TimelineQuery,
        answered: (String, Answer) async -> Void = { _, _ in }
    ) async -> (collected: [[Post]], failures: [String: SourceFailure], reached: Set<String>) {
        var failures: [String: SourceFailure] = [:]
        var collected: [[Post]] = []
        // Once per load, not once per server: the rows and the Keychain are asked before
        // anything is asked of the network, and only about the servers being read.
        let tokens = await tokensByEndpoint(for: targets.map(\.server))
        // And who each token belongs to, which only a source with an owner needs: it is what
        // a post's origin is written under, so that two people's reading on one machine stays
        // two readings. Nothing is asked for it where the source has no owner.
        let readers = query.source.needsAccount ? await readersByEndpoint(for: targets.map(\.server)) : [:]
        // Which servers a request actually went to, so the bookkeeping above judges only
        // the ones that were given a chance to answer.
        var reached: Set<String> = []

        // Each task answers with what arrived and, separately, what went wrong — a store that
        // would not keep the posts is a failure worth reporting, but the posts still arrived.
        await withTaskGroup(of: (endpoint: String, answer: Answer).self) { group in
            for (server, cursor) in targets {
                guard let client = registry.client(for: server.socialProtocol) else {
                    // Nothing was sent anywhere, so there is nothing to back off from: a
                    // protocol this build cannot read will not start speaking it in a minute.
                    let unsupported = SourceFailure.unsupported(server.socialProtocol)
                    failures[server.endpoint] = unsupported
                    await answered(server.endpoint, ([], unsupported))
                    continue
                }
                let token = tokens[server.endpoint]
                let reader = readers[server.endpoint]
                // A home timeline is not readable as nobody, and nothing else is quietly put
                // in its place: a server with no account on it is reported as needing one,
                // the way #4 has a server with no public timeline reported rather than topped
                // up with whatever else it was willing to hand over.
                if query.source.needsAccount, token == nil || reader == nil {
                    let needed = SourceFailure.needsSignIn(server.host)
                    failures[server.endpoint] = needed
                    await answered(server.endpoint, ([], needed))
                    continue
                }
                reached.insert(server.endpoint)
                group.addTask {
                    (server.endpoint,
                     await ask(client, server, query: query, token: token, as: reader, before: cursor))
                }
            }
            for await (endpoint, answer) in group {
                if !answer.posts.isEmpty { collected.append(answer.posts) }
                if let failure = answer.failure { failures[endpoint] = failure }
                // A page is the same evidence whoever asked for it, so this is here rather
                // than in `loadOlder`. A refresh's newest page covers the top of the timeline,
                // which is exactly where a post pulled down moments after it went up sits —
                // and it is the one stretch paging never revisits, because paging only ever
                // walks away from it. Trending is not a stretch of time at all and cannot
                // leave anything out of one, so it raises no questions.
                if query.source.isThreadOfTime {
                    await suspectMissing(answer.posts, from: endpoint, through: query)
                }
                await answered(endpoint, answer)
            }
        }
        return (collected, failures, reached)
    }

    /// How one server is asked: for the page before `before` — its newest where that is nil —
    /// as `token`'s owner, and where that is turned down once more as nobody. The whole of the
    /// retry policy is here, so the fan-outs above only have to name the servers and collect
    /// what each one answered.
    private func ask(_ client: any SourceClient, _ server: Server, query: TimelineQuery,
                     token: String?, as reader: String?, before: Post?) async -> Answer {
        let answer = await attempt(client, server, query: query, token: token, as: reader, before: before)
        // A cursor a server cannot be asked about is our wiring, not their machine: per-server
        // cursors mean a post from somewhere else can never become one, so this is the belt.
        // It goes in the log, where a mistake of ours belongs; the bad cursor is dropped so it
        // cannot be asked about twice; and the server is asked once more for its newest page,
        // which puts a cursor of its own back in place. The reader is told nothing, and none
        // of it counts towards a backoff — the server never spoke.
        //
        // Around the whole attempt rather than inside it: which of the two reads refused the
        // cursor is a fact about the credential and says nothing about whose mistake this is,
        // and the point of it being ours is that no wiring of ours ever reaches the reader
        // looking like a server's fault. The retry is a fresh attempt for the same reason it
        // is not a recursive `ask` — a cursor already dropped cannot be refused again.
        guard case .notItsPost(let uri)? = answer.failure, before != nil else { return answer }
        LocalStore.log.error("""
            paging cursor \(uri, privacy: .public) is not a post of \
            \(server.host, privacy: .public); asking for its newest page instead
            """)
        await paging.forget(server.endpoint)
        return await attempt(client, server, query: query, token: token, as: reader, before: nil)
    }

    /// The read itself, tried as `token`'s owner and once more as a stranger where the
    /// credential is turned down — everything `ask` does but the belt around the cursor.
    private func attempt(_ client: any SourceClient, _ server: Server, query: TimelineQuery,
                         token: String?, as reader: String?, before: Post?) async -> Answer {
        let signedIn = await read(client, server, query: query, token: token, as: reader, before: before)
        // A token the server turned down is the account's problem, not the server's, so the
        // same read goes out once more as a stranger and the column shows whatever anyone
        // would see. What is reported stays `.tokenRejected`, so the screen marks the account
        // rather than the server — and stays one failure for this server on this load, so a
        // backoff counting failures per server never counts the retry as a second.
        guard case .tokenRejected? = signedIn.failure else { return signedIn }
        // A source with an owner has nowhere to fall back to: read as nobody it is not this
        // timeline at all. So the refusal stands, and it stands as the account's problem.
        guard !query.source.needsAccount else { return signedIn }
        let anonymous = await read(client, server, query: query, token: nil, as: nil, before: before)
        // A retry that read fine but would not store replaces `.tokenRejected` with `.store`,
        // and the account goes unmarked this round. That is the trade taken knowingly: one
        // host can only carry one reason, and the store failing is the newer news. It heals
        // by itself — nothing was reported, so nothing told `TokenSource` to stop sending the
        // credential, and the next load carries it again and is rejected again.
        guard anonymous.failure == nil else { return anonymous }
        return (anonymous.posts, signedIn.failure)
    }

    /// One request to one server as `token`'s owner, and what it handed over kept. `before` is
    /// that server's own cursor; a trending list has none and is never given one.
    private func read(_ client: any SourceClient, _ server: Server, query: TimelineQuery,
                      token: String?, as reader: String?, before: Post?) async -> Answer {
        let posts: [Post]
        do {
            posts = switch query.source {
            case .public: try await client.timeline(host: server.host, limit: limit,
                                                    before: before, token: token)
            case .home: try await client.home(host: server.host, limit: limit,
                                              before: before, token: token ?? "")
            case .trend: try await client.trending(host: server.host, limit: limit, token: token)
            // A conversation is not read by fanning out across the chosen servers: it is one
            // post's own, asked of the one server whose word on that post is final, when a
            // reader opens it. `thread(around:)` is that path; this one never leads there.
            case .thread: []
            }
        } catch {
            return ([], SourceFailure.of(error))
        }
        do {
            // The whole page is kept, whatever this timeline's rules make of it, and it is
            // kept with the source it came through written beside it — that pairing is what
            // lets a timeline be a question asked of one copy of each post rather than a copy
            // of its own.
            try await store?.save(posts, from: server, into: query.source, as: reader)
            if query.source.ranked { try await store?.recordTrending(posts, from: server) }
        } catch {
            // What SQLite said, in full, is for the log; the screen gets the message.
            LocalStore.log.error("save failed for \(server.host, privacy: .public): \(String(describing: error), privacy: .public)")
            let reason = (error as? DatabaseError)?.message ?? error.localizedDescription
            return (posts, .store(reason))
        }
        return (posts, nil)
    }

    /// Which of `servers` this load is allowed to ask, and which of them it is leaving
    /// alone. Everyone is asked where the reader asked; everyone not still inside a wait
    /// where the clock did — which is also everyone, almost always, so the healthy load
    /// does no work, and allocates nothing, to find that out.
    private func askable(_ servers: [Server], refresh: Refresh,
                         now: Date) async -> (asked: [Server], skipped: Set<String>) {
        guard case .automatic = refresh else { return (servers, []) }
        let blocked = await backoff.blocked(at: now)
        guard !blocked.isEmpty else { return (servers, []) }
        return (servers.filter { !blocked.contains($0.endpoint) },
                blocked.intersection(servers.map(\.endpoint)))
    }

    /// What this load's answers do to how long each server is left alone next time.
    ///
    /// Whether an answer arrived at all is `SourceFailure.arrivedAnyway`'s to say, so the
    /// rule lives with the cases rather than here. Silence is what a wait is for; anything
    /// that arrived forgives whatever wait had been building.
    ///
    /// Only the clock lengthens the clock's wait. A reader who asked and got nothing has not
    /// made a schedule for anybody — but their answer still forgives, so pulling to refresh
    /// brings a server back at once.
    private func record(_ failures: [String: SourceFailure], from reached: Set<String>,
                        refresh: Refresh, now: Date) async {
        var answered: Set<String> = []
        var silent: Set<String> = []
        for endpoint in reached {
            guard let failure = failures[endpoint] else { answered.insert(endpoint); continue }
            if case .tokenRejected = failure {
                // The credential is spent; sending it again every refresh is asking a server
                // to say no on a timer. The read still goes out, as a stranger.
                await tokenSource?.markRejected(endpoint)
            }
            if failure.arrivedAnyway { answered.insert(endpoint) } else { silent.insert(endpoint) }
        }
        if !answered.isEmpty { await backoff.answered(answered) }
        guard case .automatic(let every) = refresh, !silent.isEmpty else { return }
        await backoff.failed(silent, base: every, at: now)
    }

    /// Who each of `servers` is read as, by endpoint — the `accounts.author_id` of whoever is
    /// signed in there. The rows alone: no Keychain, no network, and asked for only where the
    /// base source has an owner.
    private func readersByEndpoint(for servers: [Server]) async -> [String: String] {
        guard let store else { return [:] }
        do {
            let asked = Set(servers.map(\.endpoint))
            return try await store.signedInByServer()
                .filter { asked.contains($0.key) }
                .mapValues(\.authorId)
        } catch {
            LocalStore.log.error("reading who is signed in failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    /// The access token to read each of `servers` as. `TokenSource` answers who is signed in
    /// and what proves it; a read with no token here goes out as a stranger, which is what
    /// it did before anyone signed in.
    private func tokensByEndpoint(for servers: [Server]) async -> [String: String] {
        guard let tokenSource else { return [:] }
        return await tokenSource.tokens(for: servers).mapValues(\.accessToken)
    }

    /// Several servers' trending lists as one: a post's rank is its index in its server's
    /// list, a post on several lists takes its best rank and keeps every source, and where
    /// the servers ranked two posts the same the timeline's own order breaks the tie.
    ///
    /// That tail is `Post.isOlder` and not a fourth spelling of it. Rank is this list's own
    /// idea and nothing else has one; the order underneath it is the same order the store
    /// reads a page back in and the same one a merged timeline is in, so it is asked for
    /// rather than written out again.
    static func mergedByRank(_ lists: [[Post]]) -> [Post] {
        var ranks: [String: Int] = [:]
        for list in lists {
            for (rank, post) in list.enumerated() {
                ranks[post.mergeKey] = min(ranks[post.mergeKey] ?? rank, rank)
            }
        }
        return lists.flatMap { $0 }.merged(orderedBy: {
            let (a, b) = (ranks[$0.mergeKey]!, ranks[$1.mergeKey]!)
            return a == b ? Post.isOlder($1, than: $0) : a < b
        })
    }

    /// The only thing between what arrived and what you see. It adds and removes; it never moves.
    public static func apply(showBoosts: Bool, mediaOnly: Bool, to posts: [Post]) -> [Post] {
        sift(showBoosts: showBoosts, mediaOnly: mediaOnly, posts).admitted
    }

    /// The same, and what it turned away, with the reason attached.
    ///
    /// These two switches are rules like the ones written on a timeline — the reader's own, and
    /// they remove rather than move — so they answer #6's question the same way. A post is not
    /// on the screen for one reason, so the first that refuses it is the reason.
    public static func sift(showBoosts: Bool, mediaOnly: Bool,
                            _ posts: [Post]) -> (admitted: [Post], hidden: [Hidden]) {
        var admitted: [Post] = []
        var hidden: [Hidden] = []
        for post in posts {
            if !showBoosts, post.isBoost {
                hidden.append(Hidden(post: post, because: .boostsHidden))
            } else if mediaOnly, post.mediaURLs.isEmpty {
                hidden.append(Hidden(post: post, because: .mediaOnly))
            } else {
                admitted.append(post)
            }
        }
        return (admitted, hidden)
    }
}
