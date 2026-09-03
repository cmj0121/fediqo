import Foundation
import Observation
import FediqoCore

/// Who the handle being typed could be (#98).
///
/// An offer and never an edit. It holds what a server answered and what the reader picked; the
/// composer owns the draft and is the only thing that writes into it. Nothing here rewrites what
/// somebody typed on its own — a completion that fired by itself would be this app finishing
/// sentences for people.
@MainActor
@Observable
final class MentionSuggestions {
    /// What the server offered, newest question first. Empty is the ordinary state.
    private(set) var people: [Profile] = []
    /// The one the reader took, which the composer watches for. Cleared as soon as it is read.
    var chosen: Profile?
    /// What the last answer was about, so an answer arriving after the reader has typed on is
    /// not drawn under a question nobody is asking any more.
    private(set) var asking: String?

    /// How many are offered. A list longer than this is a menu to read rather than a hand
    /// finishing a word.
    static let most = 5

    private let registry: SourceRegistry

    init(registry: SourceRegistry) {
        self.registry = registry
    }

    /// Asks who `query` could be, on the server the draft will be posted from.
    ///
    /// The caller does the waiting — see the composer, which asks through `.task(id:)` so that a
    /// reader typing quickly asks once rather than once per letter, and so that the question is
    /// cancelled the moment it stops being the question.
    func look(for query: String, as account: ActingAccount?) async {
        guard let account, let client = registry.client(for: .mastodon) else {
            return clear()
        }
        asking = query
        do {
            let found = try await client.searchPeople(matching: query, limit: Self.most,
                                                      as: account)
            // The answer to a question the reader has moved on from is not an answer to draw.
            guard !Task.isCancelled, asking == query else { return }
            people = found
        } catch {
            // Nothing is said about it. This is a convenience while somebody is typing, and a
            // server that would not answer is not a thing to interrupt a draft over — the reader
            // types the handle themselves, which is what they were doing anyway.
            guard asking == query else { return }
            people = []
        }
    }

    /// The offer goes away: the token stopped being a handle, the panel closed, or the reader
    /// took one.
    func clear() {
        people = []
        asking = nil
    }

    /// The first of them, which is what a press of `Tab` takes.
    var first: Profile? { people.first }
}
