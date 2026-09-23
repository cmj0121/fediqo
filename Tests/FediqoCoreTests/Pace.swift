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
/// ten cores, it made one index sixteen plain reads by the wall. What is left, a slower core or
/// a colder cache, slows both sides alike.
///
/// **Taken in turns.** Each of three rounds reads the notes plainly and then does the work, and
/// each side keeps its fastest. Time the machine spent elsewhere only ever adds to a measurement,
/// so the fastest is the one closest to the cost — and a runner that turns busy halfway, as when
/// another suite starts beside this one, slows both sides rather than the one measured second.
struct Pace: CustomStringConvertible {
    let work: Duration
    let plain: Duration

    /// How many plain reads the work took.
    var reads: Double { work / plain }

    var description: String {
        "\(reads.formatted(.number.precision(.fractionLength(2)))) plain reads (\(work) against \(plain))"
    }

    init(_ notes: [Note], runs: Int = 3, _ work: () -> Void) {
        self = withoutActuallyEscaping(work) { Self.each(notes, runs: runs, [$0])[0] }
    }

    /// Several pieces of work, each round reading once and then doing each of them once — so
    /// six searches cost three plain reads rather than eighteen, and the checks hold a thread
    /// that other suites are waiting on for no longer than they must.
    static func each(_ notes: [Note], runs: Int = 3, _ works: [() -> Void]) -> [Pace] {
        precondition(runs >= 1, "a pace needs at least one round")
        var plain = Duration.zero
        var took = [Duration](repeating: .zero, count: works.count)
        for run in 0 ..< runs {
            let read = running { Self.read(notes) }
            plain = run == 0 ? read : min(plain, read)
            for (i, work) in works.enumerated() {
                let measured = running(work)
                took[i] = run == 0 ? measured : min(took[i], measured)
            }
        }
        return took.map { Pace(work: $0, plain: plain) }
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
