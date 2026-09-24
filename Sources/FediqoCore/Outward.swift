import Foundation

/// The one door every outward request goes through (#220).
///
/// **Every outward act belongs to a source the person added.** Where it belongs is decided in
/// the UI, at the one waist that knows who asked (`WatchedHTTP`), and the decision is carried to
/// the wire in this task-local — so a transport can tell a request that was let through the gate
/// from one that never came near it. `URLSessionClient` refuses the second: a client used without
/// the gate in front of it does not reach anything, and so cannot reach anything unrecorded.
public enum Outward {
    /// Whether the request on its way out was let through the gate. Set only by the gate, and only
    /// for the length of the one request it let through.
    @TaskLocal public static var admitted = false
}

/// Why a request never left.
public enum OutwardRefusal: Error, Equatable, Sendable {
    /// It belongs to no source the person added: nothing they added asked for it or pointed to it.
    case noSource
    /// It came to the wire without passing the gate, so nobody can say whose it is.
    case unwatched
}
