import Foundation
@testable import FediqoCore

/// How long some work took, told as a number of plain reads of the same notes by the same
/// machine at the same moment — what a speed check holds to a line (#203).
///
/// **A check is a ratio, not a number of milliseconds.** A shared runner, a busy one, or one
/// counting what the tests cover is slower at everything, so a fixed budget failed there at one
/// and a half times the line on code that never changed — and a check that is asked again until
/// it passes no longer catches anything. Work that has become several times dearer is several
/// times the plain read, on any runner.
///
/// **The thread's own time, not the wall's.** Both sides count only the time this thread spent
/// running. A runner with more work than cores hands a thread its core in slices, and waiting for
/// the next slice lands on whichever measurement is longer — here, with seventy threads wanting
/// ten cores, it made one index sixteen plain reads by the wall.
///
/// **Each round its own ratio, and the middle round kept.** Even the thread's own time swells on
/// a busy machine, and not evenly: when every core is in use the clock drops for all of them and
/// the caches are shared with whatever else runs, so one measurement may take a few per cent
/// longer and the next nearly half again, with nothing about the work changed (#414). Keeping the
/// fastest of each side on its own paired a lucky read from one round with an unlucky piece of
/// work from another, and a check that added two such paces doubled the error. So each of five
/// rounds reads the notes plainly, does the work, and reads them again; the work is set against
/// the mean of the reads on either side of it, taken moments apart, and the check keeps the
/// middle of the five ratios. One or two rounds caught by the machine at a bad moment fall to the
/// ends, whichever side they slowed, while work made dearer is dearer in every round.
struct Pace: CustomStringConvertible {
    let work: Duration
    let plain: Duration

    /// How many plain reads the work took.
    var reads: Double { work / plain }

    var description: String {
        "\(reads.formatted(.number.precision(.fractionLength(2)))) plain reads (\(work) against \(plain))"
    }

    init(_ notes: [Note], runs: Int = 5, _ work: () -> Void) {
        self = withoutActuallyEscaping(work) { Self.each(notes, runs: runs, [$0])[0] }
    }

    /// Several pieces of work, each round reading once before the first, once after each, and
    /// doing each of them once in between — so every piece sits between two reads of its own
    /// round, and six searches cost seven plain reads a round rather than twelve.
    static func each(_ notes: [Note], runs: Int = 5, _ works: [() -> Void]) -> [Pace] {
        precondition(runs >= 1, "a pace needs at least one round")
        var rounds = [[Pace]](repeating: [], count: works.count)
        for _ in 0 ..< runs {
            var before = running { Self.read(notes) }
            for (i, work) in works.enumerated() {
                let took = running(work)
                let after = running { Self.read(notes) }
                rounds[i].append(Pace(work: took, plain: (before + after) / 2))
                before = after
            }
        }
        return rounds.map { $0.sorted { $0.reads < $1.reads }[runs / 2] }
    }

    private init(work: Duration, plain: Duration) {
        self.work = work
        self.plain = plain
    }

    /// How long `work` kept this thread running. The work never suspends, so it runs on the one
    /// thread it started on.
    private static func running(_ work: () -> Void) -> Duration {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        work()
        return .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start)
    }

    /// A plain read of every note: its body, name and handle folded for case with the same
    /// Foundation call `Fold.key` makes, and looked through for a word none of them holds. It
    /// deliberately leaves out everything the checks are about — width, composition, the index,
    /// a pattern — so it costs what the machine and its text library cost, not the code under
    /// test, and a slower library or bridge moves both sides alike.
    private static func read(_ notes: [Note]) {
        var found = 0
        for note in notes {
            for field in [note.body, note.author, note.handle]
            where field.folding(options: .caseInsensitive, locale: nil).contains("zzz") {
                found += 1
            }
        }
        precondition(found == 0, "the plain read is meant to find nothing")
    }
}
