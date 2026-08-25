import Foundation

/// The posts a server should have handed over and did not, waiting to be asked about.
///
/// Absence is the whole of what puts a post here, and absence proves nothing. A server takes
/// blocked accounts and filtered posts out of a range it has already chosen, so a page can
/// leave out a post that is perfectly well there — which is why nothing here writes anything.
/// A suspicion is a question not yet asked; only an answer from the authority settles one.
///
/// Two things follow from that, and they are the whole of this actor's job.
///
/// It is a queue, not a verdict. Suspicions are kept in the order they were first raised, so
/// a backlog is worked off oldest first rather than in whatever order a dictionary yields,
/// and one asked about but not answered for goes back in rather than being taken as checked.
///
/// It is bounded at the point of asking, not the point of suspecting. A filter turned on can
/// make a whole page absent at once, and that is a real thing readers do; what must not
/// follow is a burst of single-post requests at other people's servers. So everything absent
/// is suspected — losing one would mean never noticing it — and `take` is what says how many
/// of them this pass is allowed to ask about.
///
/// In memory, for as long as the app runs, beside `ServerPaging` and `ServerBackoff` and held
/// by the same loader, for their reasons: a suspicion is about a reading in progress, and the
/// next run of the app will re-suspect whatever is still absent from the next page it reads.
actor Reconciler {
    /// What one pass learned about one post it asked about. Four answers, because "we could
    /// not reach them", "they would not discuss it", "nobody could even ask" and "they told
    /// us" are four different things, and only the last of them settles anything.
    enum Verdict {
        /// The authority answered about this post — it is gone and marked, or it is still
        /// there. Either way the question is closed.
        case settled
        /// The authority answered and declined to discuss the post with a stranger. Not
        /// silence, so it starts no wait; not an answer about the post either, so it decides
        /// nothing. Enough of these and the question is set aside.
        case refused
        /// No client could put the question into words — a canonical address of a shape this
        /// build cannot ask about, or a protocol it does not speak. Never answerable.
        case unanswerable
        /// Silence, or a store that would not keep the answer. Nothing was learned.
        case unknown
    }

    /// How many refusals before a question is set aside.
    ///
    /// Three, because one is not evidence of anything standing — a server restarting, a post
    /// mid-edit, a moment of strictness — while three passes is enough to establish that this
    /// is simply the answer a stranger gets. Costing at most three requests before the slot is
    /// freed is the trade; the alternative is a handful of private posts holding places in a
    /// queue of eight for the rest of the run, which is the bound being spent on questions
    /// whose answer is already known.
    static let refusalsBeforeSettingAside = 3

    /// One post nobody has seen in a page that covered it, and how it has been going.
    private struct Suspicion {
        let subject: PostAuthority
        /// A question is out and has not come back — so a second pass arriving while the
        /// first is still waiting does not ask the same server about the same post again.
        /// The same guard `ServerPaging.claim` keeps over a page, for the same reason.
        var asking = false
        /// How many times the authority has declined to discuss it with a stranger.
        var refusals = 0
    }

    private var suspicions: [Suspicion] = []

    /// The merge keys `suspicions` holds, kept beside it so that suspecting a page costs one
    /// lookup per post rather than a rebuild of the whole queue. The queue is at its longest
    /// exactly when a filter has just made a page's worth of posts absent — which is also when
    /// pages keep arriving — so the rebuild would be slowest in the one case it has to be fast.
    private var queued: Set<String> = []

    /// Questions this run will not raise again, for either of the two reasons a question is
    /// worth stopping: nobody could ever put it into words, or the authority has given the
    /// same non-answer often enough that asking again is only spending the bound.
    ///
    /// Set aside is neither settled nor forgotten. Nothing is marked, nothing is written, and
    /// the post stays exactly where it is on the screen and in the store — it has simply
    /// stopped holding a place in a queue of eight.
    ///
    /// What brings one back is a relaunch: all of this lives in memory beside the backoff and
    /// dies with the app, so the next run raises the question afresh against whatever the
    /// servers say then. A refused one would also come back the moment confirmation had a
    /// credential to send, which today it never does — see `TimelineLoader.reconcile`.
    private var setAside: Set<String> = []

    /// These were absent from a page that covered them, so they are now questions. Writes
    /// nothing and decides nothing; a post already suspected is not suspected twice, and one
    /// already set aside is not suspected at all.
    func suspect(_ subjects: [PostAuthority]) {
        for subject in subjects {
            let key = subject.post.mergeKey
            guard !queued.contains(key), !setAside.contains(key) else { continue }
            queued.insert(key)
            suspicions.append(Suspicion(subject: subject))
        }
    }

    /// At most `most` suspects to ask about now, oldest suspicion first — passing over any
    /// already being asked about, and any whose authority is inside a wait.
    ///
    /// Claiming and marking are one hop, the way `ServerPaging.claim` is: two passes arriving
    /// together would otherwise both find the same post free and both ask about it. Whoever
    /// takes must give back, through `settle`.
    ///
    /// What is left over is left over. It stays exactly where it was, in order, for the next
    /// pass to take — never dropped, and never counted as having been checked.
    func take(_ most: Int, avoiding blocked: Set<String>) -> [PostAuthority] {
        var taken: [PostAuthority] = []
        for index in suspicions.indices {
            // A `where` clause here would read like a limit and behave like a filter, walking
            // the whole backlog after the last one was claimed. This stops.
            if taken.count >= most { break }
            let suspicion = suspicions[index]
            guard !suspicion.asking, !blocked.contains(suspicion.subject.authorityURL) else { continue }
            suspicions[index].asking = true
            taken.append(suspicion.subject)
        }
        return taken
    }

    /// The pass is over: what it learned about each post it asked about, by merge key.
    ///
    /// A question that was answered leaves the queue. One nobody could put into words leaves
    /// it and is set aside, because every later page covering that post would otherwise raise
    /// the same unanswerable question and spend a slot of the bound rediscovering it. One that
    /// was refused leaves only once it has been refused `refusalsBeforeSettingAside` times.
    ///
    /// Everything else is freed to be asked about another time, because silence decides
    /// nothing: a server that could not be reached has said no more about a post than a server
    /// nobody asked. Freeing rather than dropping is the difference between "we do not know
    /// yet" and "we checked", and only one of those is true.
    func settle(_ verdicts: [String: Verdict]) {
        var closing: Set<String> = []
        for index in suspicions.indices {
            let key = suspicions[index].subject.post.mergeKey
            guard let verdict = verdicts[key] else { continue }
            suspicions[index].asking = false
            switch verdict {
            case .settled:
                // Answered for, and answerable again another day: a post that is still there
                // now may be gone next week, so this one is not set aside.
                closing.insert(key)
            case .unanswerable:
                closing.insert(key)
                setAside.insert(key)
            case .refused:
                suspicions[index].refusals += 1
                guard suspicions[index].refusals >= Self.refusalsBeforeSettingAside else { continue }
                closing.insert(key)
                setAside.insert(key)
            case .unknown:
                continue
            }
        }
        suspicions.removeAll { closing.contains($0.subject.post.mergeKey) }
        queued.subtract(closing)
    }

    /// What is suspected and not yet settled, by merge key — the questions still open.
    var suspected: Set<String> { queued }
}
