import Foundation
@testable import FediqoUI

extension ShellSession {
    /// Puts every deadline this session waits its asks on — what it reaches its sources through,
    /// what it asks through a sign-in to a Mastodon, its forums' reads and their sign-ins — on one
    /// clock nobody turns (#346).
    ///
    /// **For a check that holds an ask and then reads its answer.** A deadline on the real clock
    /// passes while the ask is held wherever the run is slow enough before the check lets it go,
    /// and the ask then ends as timed out, not with what its source answered: a right build fails
    /// for it. On this clock an ask ends with its source's answer, and with nothing else.
    ///
    /// **Said once, where the session is made**, before anything is asked. A check that wants a
    /// deadline to pass hands that seam a clock of its own after this, turns it, and says how long
    /// was asked.
    func deadlinesUnturned() {
        let clock = TurnedClock()
        deadlineSleep = clock.sleep
        mastodon.deadlineSleep = clock.sleep
        posts.deadlineSleep = clock.sleep
        forums.limitSleep = clock.sleep
    }
}
