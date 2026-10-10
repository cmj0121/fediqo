import FediqoCore
import Foundation
import Observation

/// What this run knows each Mastodon host has (`MastodonHostsKnown`), **held here and nowhere
/// else**: the one owner that value asks for. It is changed in place, by calls that do not
/// wait — never copied out, carried across a wait, and written back.
///
/// Held by `ShellPersonPages`, on its count of asks, and handed the session at each ask: the
/// session's own stored state is not this unit's to add to.
///
/// **A host's document is asked for at most once a run** — when a page that goes by what the
/// host has first wants it — through the plain client held to the small body's ceiling, kept
/// to that host, listed in the run's record as a check of the server and ended within the
/// deadline. One on the wire is waited on and not asked twice; one that did not come is owed
/// still, and is asked for when next wanted. Nothing is asked from here by itself.
///
/// **Nothing is for ever**: `askAfresh` lets a host go whole — at the person's own asking
/// again, and when who is signed in to it changes — and an answer to a document asked for
/// before that lands nowhere.
@MainActor
@Observable
final class ShellHostsKnown {
    private var known = MastodonHostsKnown()
    /// The hosts whose document came this run, whatever it said: what stops a second ask.
    @ObservationIgnored private var came: Set<String> = []
    /// The document asks on the wire, by host, and the number each host's answer is awaited by.
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var awaits: [String: Int] = [:]
    /// How many times each host has been asked afresh this run: what tells an answer asked for
    /// before the last of them from one asked for since.
    @ObservationIgnored private var rounds: [String: Int] = [:]
    @ObservationIgnored private let errands: PageErrands
    /// How long the document may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a host's document, where a test reaches it by one — a wire that goes on
    /// answering an ask that was called off. Nothing in the app.
    @ObservationIgnored var reaching: ((String) -> MastodonClient)?

    init(errands: PageErrands) {
        self.errands = errands
    }

    private static func key(_ host: String) -> String { host.lowercased() }

    /// What is known of `thing` at `host`: absent where the host's document or its own address
    /// said so this run, and otherwise what the document said, or nothing either way.
    func has(_ thing: MastodonHostThing, at host: String) -> MastodonHostHas {
        known.has(thing, at: host)
    }

    /// The address of `thing` answered that `host` has no such address: it is not there for
    /// the rest of the run, or until the host is asked afresh.
    ///
    /// **Only where the ask that heard it was begun since the host was last asked afresh**:
    /// `round` is what `round(at:)` said when that ask started. A not-found that comes late —
    /// asked for before the person asked again, answered after — is written down nowhere.
    func notFound(_ thing: MastodonHostThing, at host: String, round: Int) {
        guard round == self.round(at: host) else { return }
        known.notFound(thing, at: host)
    }

    /// Which asking-afresh of `host` this is: taken as an ask of one of its addresses starts,
    /// and handed back with what that ask heard (`notFound`).
    func round(at host: String) -> Int {
        rounds[Self.key(host), default: 0]
    }

    /// Everything known of `host` let go, and its document owed again. A document already
    /// asked for is called off, and whatever it brings late is not believed.
    func askAfresh(_ host: String) {
        let key = Self.key(host)
        asks[key]?.cancel()
        asks[key] = nil
        awaits[key] = nil
        came.remove(key)
        rounds[key, default: 0] += 1
        known.askAfresh(host)
    }

    /// Whether the document of `host` came this run.
    func heard(_ host: String) -> Bool {
        came.contains(Self.key(host))
    }

    /// The document of `host`, asked for where this run has not had it: once, and a second
    /// caller while it is on the wire waits on that ask. Returns when it has come or failed.
    func hear(_ host: String, in session: ShellSession) async {
        let key = Self.key(host)
        if let running = asks[key] {
            await running.value
            return
        }
        guard !came.contains(key) else { return }
        let errand = errands.next()
        awaits[key] = errand
        // The ceiling goes on the plain client, before it is listed and bounded.
        let through = reaching?(key) ?? SourceReach.mastodon(
            key, over: session.reach.wire(SourceReach.smallAtItsHost(session.http), for: .serverCheck, within: deadline)
        )
        let task = Task { await self.read(key, through: through, errand: errand) }
        asks[key] = task
        await task.value
    }

    private func read(_ host: String, through client: MastodonClient, errand: Int) async {
        defer { if awaits[host] == errand { asks[host] = nil } }
        guard let said = try? await client.said(), awaits[host] == errand else { return }
        came.insert(host)
        // Only a Mastodon's document is its word about these things; another program's, at
        // the same address, came and says nothing of them.
        if ShellPersonPages.saysPeople(Source(host: host, kind: said.kind)) { known.heard(said.has, at: host) }
    }
}
