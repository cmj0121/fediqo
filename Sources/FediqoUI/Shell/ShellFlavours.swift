import FediqoCore
import Foundation

// What each server says it is, asked of that server — #86.
//
// A source's `kind` is what the detector named when the reader joined it, and it is written down
// beside the host because that is what this device stored. It is not a standing fact about the
// server: a host is joined once and read for months, and in between it can be migrated to
// another program, replaced, or upgraded into one this app does not read. Speaking Mastodon to
// it because Mastodon is what was written down is this device believing its own note over the
// server's own answer.
//
// **What is stored stays stored.** Nothing here writes to the index: the source, its boards and
// its notes are what this device kept and a relaunch finds them exactly as they were. What this
// holds is one run's answers, and a Clear or a Remove drops them with everything else that came
// from that host.
//
// **The answer is applied once, where the session adopts its sources**, and not at each place
// that asks what a host speaks. `ShellSession.adopt` projects every `Source` through
// `spoken(_:)`, so the row, the Trends tab, a rule, the sign-in affordance and the read all see
// one kind — the one the server gave. A gate written into any single one of them would be a
// rule the other five had never heard of.

/// What a server has said about itself this run. **Absent means nobody has asked yet.**
///
/// Two cases, because there are two answers a server can give and "not asked" is not one of
/// them: it is the dictionary having no entry, which is one spelling of nothing rather than two.
enum ShellFlavour: Equatable, Sendable {
    /// It answered, and this is the name it gave.
    case said(ProtocolKind)
    /// It was asked and it would not say — an answer this device could not read, or a refusal;
    /// never a dark network, which leaves the host unasked (#222). What
    /// was written down at join stands, which is the conservative reading: an outage is not a
    /// migration.
    case unsaid
}

/// Every host's flavour as its own server gives it, for this run.
///
/// On the session beside `posts` and `conversations`, for their reason: what Clear presses and
/// what a read consults have to be the same object.
///
/// **Not `@Observable`**, unlike its neighbours, and that is the honest marking rather than an
/// omission: nothing draws from this. What a view sees is `ShellSession.sources`, which is
/// already observed and is where the answer lands.
@MainActor
final class ShellFlavours {
    private var flavours: [String: ShellFlavour] = [:]
    /// What is on the wire, so two reads of one host starting together ask it once.
    private var inFlight: [String: Task<Void, Never>] = [:]

    func flavour(of raw: String) -> ShellFlavour? {
        flavours[raw.lowercased()]
    }

    /// **What to speak to this host** — the server's own answer this run; until it has given
    /// one, what it last said and this device kept (#188), where `kept` names it; and what was
    /// written down at join behind both.
    ///
    /// A kept word stands only until this run asks: `.unsaid` — asked, and it would not say —
    /// leaves the kept word standing rather than the join's note, because it is the later of the
    /// two things the server itself said. A dark network leaves everything as it was.
    func speaking(_ raw: String, storedAs stored: ProtocolKind, keptAs kept: ProtocolKind? = nil) -> ProtocolKind {
        guard case .said(let kind) = flavour(of: raw) else { return kept ?? stored }
        return kind
    }

    /// One source as this run should speak to it: the same source, under the name its own server
    /// gives. Unchanged — the same value, not a copy — where the server has said nothing or has
    /// said what was already written down.
    ///
    /// **Everything else about it is untouched.** The boards and lists the reader picked are
    /// theirs and not the server's to revise, and the host is the key both halves are filed
    /// under. Only the name of what it speaks comes from the wire, or from what the wire last
    /// said and this device kept (`kept`).
    func spoken(_ source: Source, keptAs kept: ProtocolKind? = nil) -> Source {
        let kind = speaking(source.host, storedAs: source.kind, keptAs: kept)
        guard kind != source.kind else { return source }
        return Source(host: source.host, kind: kind, boards: source.boards, lists: source.lists)
    }

    /// Asks the host what it is, once. A second ask while the first is out waits on it, and one
    /// after it has answered asks nothing: the answer stands until a Clear or a Remove drops it.
    ///
    /// The transport is the caller's, so the deadline a reader is waiting under is the reload's
    /// one deadline rather than a second knob that can be set to disagree with it.
    ///
    /// **The same document says what the server is like, and that goes into `store`** (#188) —
    /// the one ask a run already makes, read twice rather than made twice, so a relaunch draws
    /// what the server said last time before this run's ask comes back, and this run's answer
    /// replaces it whole once it does. Nowhere, where no store is named.
    ///
    /// Cancelled — the reader stopped the reload — it leaves the host exactly as it found it, so
    /// walking away is never mistaken for a server that would not say.
    func ask(_ raw: String, through http: any HTTPClient, into store: ItemStore? = nil) async {
        let host = raw.lowercased()
        if let running = inFlight[host] {
            await running.value
            return
        }
        guard flavours[host] == nil else { return }
        let task = Task { @MainActor in await self.read(host, through: http, into: store) }
        inFlight[host] = task
        await task.value
        inFlight[host] = nil
    }

    /// Lets go of one server's answer: Remove, and Clear. The next read asks it again.
    func forget(host raw: String) {
        let host = raw.lowercased()
        flavours[host] = nil
        inFlight[host]?.cancel()
        inFlight[host] = nil
    }

    private func read(_ host: String, through http: any HTTPClient, into store: ItemStore?) async {
        do {
            let (kind, profile) = try await MastodonClient(http: http, host: host).introduction()
            try Task.checkCancellation()
            flavours[host] = .said(kind)
            // After the flavour is written, so the store's change is adopted under the name the
            // server just gave; and only a word this app could read — a kind and nothing more
            // leaves what was kept standing rather than replacing it with nothing.
            if let store, let profile { await store.said(profile) }
        } catch let error where Cancellation.happened(error) {
            flavours[host] = nil
        } catch let error where DarkNetwork.caused(error) {
            // A dark network is not the server declining to say (#222): nothing is written down,
            // so the first reload after the network returns asks again, with no relaunch.
            flavours[host] = nil
        } catch {
            flavours[host] = .unsaid
        }
    }
}
