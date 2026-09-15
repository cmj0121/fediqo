/// Which pictures are worth asking for again, and why nobody but the app can decide it.
///
/// An extension rather than a change to `ShellPictures`: that file is merged, its invariants are
/// load-bearing, and this needs nothing from inside it — `missing` and `maxInFlight` are both
/// readable from here. Kept out of `FediqoRootView` all the same, because what counts as stranded
/// is a fact about the cache and belongs next to it rather than inside a view.
extension ShellPictures {
    /// The addresses an outage wrote off, bounded.
    ///
    /// Only `.unreachable`. The other two kinds of nothing are answers: `.refused` is a server
    /// that said no and will say no again, and `.crowded` is terminal for the life of the process
    /// by design — asking for either is a request whose result is already known.
    ///
    /// **A handful rather than one, and a handful rather than all of them.** One is fragile: if
    /// the address picked belongs to a host that is still down, the whole cohort waits for the
    /// next activation. All of them is a thundering herd at somebody else's server for a fact
    /// that one answer settles, because the first success clears the cohort by itself. The bound
    /// is the cache's own limit on what may be in the air at once, so this can never ask for more
    /// than it was already willing to hold.
    ///
    /// Arbitrary within that, which is deliberate: `Dictionary` has no order, so a run that finds
    /// nothing leaves a different handful to the next one rather than asking after the same dead
    /// address forever.
    var stranded: [Key] {
        missing
            .filter { $0.value == .unreachable }
            .prefix(Self.maxInFlight)
            .map(\.key)
    }
}
