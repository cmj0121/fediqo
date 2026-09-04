import Foundation
import Observation
import FediqoCore

/// What each of the reader's servers says it is hiding for them, and the way to stop (#114).
///
/// **Asked of each account as itself.** A reader signed in to three servers has three of these
/// lists, and they are not one: muting somebody on one server does not mute them on another, and
/// a list that merged them would offer to undo something on a server that was never doing it.
@MainActor
@Observable
final class HidingModel {
    /// What each server answered, keyed by the account it was asked as.
    private(set) var found: [String: [Hiding: [Hidden.Subject]]] = [:]
    private(set) var loading = false
    private(set) var failure: SourceFailure?
    private var hasRead = false

    private let accounts: () async -> [ActingAccount]
    private let client: () -> (any SourceClient)?

    init(accounts: @escaping () async -> [ActingAccount],
         client: @escaping () -> (any SourceClient)?) {
        self.accounts = accounts
        self.client = client
    }

    /// Every account's handle that answered, in a settled order so the lists do not shuffle.
    var hosts: [String] { found.keys.sorted() }

    func readIfNeeded() async {
        guard !hasRead else { return }
        await read()
    }

    func read() async {
        loading = true
        defer { loading = false }
        let asking = await accounts()
        // Nobody asked is not nothing hidden: the accounts arrive over the keychain after the
        // screen is drawn, and latching on that would leave the lists empty until relaunch.
        hasRead = !asking.isEmpty
        guard let client = client() else { return }

        var answers: [String: [Hiding: [Hidden.Subject]]] = [:]
        var refused: SourceFailure?
        for account in asking {
            var mine: [Hiding: [Hidden.Subject]] = [:]
            for which in Hiding.allCases {
                do {
                    let list = try await client.hidden(which, as: account)
                    if !list.isEmpty { mine[which] = list }
                } catch {
                    // One list refusing is one list. A server that will not discuss its blocks
                    // still has mutes worth showing, and a reader with something to undo should
                    // not be shown nothing because of the list beside it.
                    refused = refused ?? SourceFailure.of(error)
                }
            }
            if !mine.isEmpty { answers[account.host] = mine }
        }
        found = answers
        failure = refused
    }

    /// Stop hiding one of them, on the server that is doing it.
    func stop(_ which: Hiding, _ subject: Hidden.Subject, on host: String) async {
        guard let client = client(),
              let account = await accounts().first(where: { $0.host == host })
        else { return }
        do {
            try await client.stopHiding(which, subject, as: account)
            // Read back rather than removed here: what is standing is the server's answer, and
            // a list edited on this side would be this app's opinion of what it had just done.
            await read()
        } catch {
            failure = SourceFailure.of(error)
        }
    }
}
