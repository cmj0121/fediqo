import Foundation
import Observation
import FediqoCore

/// Who the reader is talking to (#109).
///
/// **Not a feed, and it does not borrow one.** A conversation is not a post, so there is no ring
/// keyed on merge keys, no paging by the foot, and no merging across servers: a conversation
/// belongs to one account on one server, and two servers' conversations are two conversations
/// even where the same people are in both.
///
/// Nothing here is written to the store. A private conversation has the sharpest edges in this
/// app, and the surest way for one not to appear in a reading it is not for is for it never to
/// be written where a reading could find it.
@MainActor
@Observable
final class TalksModel {
    /// What each account is talking about, one list per account, in the order the servers gave.
    private(set) var talks: [Talk] = []
    private(set) var loading = false
    /// Which servers would not answer, so a page that is short can say why rather than looking
    /// like a reader with nothing to say to anybody.
    private(set) var failures: [String: SourceFailure] = [:]
    private var hasRead = false

    private let accounts: () async -> [ActingAccount]
    private let client: (String) -> (any SourceClient)?

    init(accounts: @escaping () async -> [ActingAccount],
         client: @escaping (String) -> (any SourceClient)?) {
        self.accounts = accounts
        self.client = client
    }

    /// Once per opening, and again when the reader asks.
    func readIfNeeded() async {
        guard !hasRead else { return }
        await read()
    }

    func read() async {
        loading = true
        defer { loading = false }

        var found: [Talk] = []
        var refused: [String: SourceFailure] = [:]
        let asking = await accounts()
        // **Nobody asked is not nothing to show.** The accounts arrive over the keychain, so the
        // first visit can land before there is anybody to ask — and latching on that answer would
        // leave the page empty until the app was next launched.
        hasRead = !asking.isEmpty
        for account in asking {
            guard let client = client(account.host) else { continue }
            do {
                found += try await client.conversations(as: account)
            } catch {
                // One server refusing is one server refusing. The others' conversations are
                // still true and still on the screen.
                refused[account.host] = SourceFailure.of(error)
            }
        }
        talks = found
        failures = refused
    }
}
