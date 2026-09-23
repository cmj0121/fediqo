@testable import FediqoCore

/// How fast the machine running a speed check is, at the moment it runs it (#203).
///
/// **A check is a ratio, not a number of milliseconds.** A shared runner, a busy one, or one
/// counting what the tests cover is slower at everything, so a fixed budget failed there at one
/// and a half times the line on code that never changed — and a check that is asked again until
/// it passes no longer catches anything. The same machine, in the same test and on the same
/// notes, reads them plainly once; a search or a timeline's rules that have become several
/// times dearer are several times that, on any runner.
enum Pace {
    /// The fastest of `runs` measurements of `work`. Time the machine spent elsewhere only ever
    /// adds to a measurement, so the fastest is the one closest to what the work costs.
    static func fastest(of runs: Int = 3, _ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        var fastest = clock.measure(work)
        for _ in 1 ..< runs { fastest = min(fastest, clock.measure(work)) }
        return fastest
    }

    /// The fastest of three plain reads of every note: its body, name and handle lowercased and
    /// looked through for a word none of them holds. Only the standard library — no fold, no
    /// index, no pattern — so it costs what the machine costs, not what the code under test does.
    static func plainRead(_ notes: [Note]) -> Duration {
        fastest {
            var found = 0
            for note in notes {
                for field in [note.body, note.author, note.handle] where field.lowercased().contains("zzz") {
                    found += 1
                }
            }
            precondition(found == 0, "the plain read is meant to find nothing")
        }
    }
}
