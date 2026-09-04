import Foundation
import Observation
import FediqoCore

/// What the token being typed could be — who, or which hashtag (#98, #108).
///
/// An offer and never an edit. It holds what a server answered and what the reader picked; the
/// composer owns the draft and is the only thing that writes into it. Nothing here rewrites what
/// somebody typed on its own — a completion that fired by itself would be this app finishing
/// sentences for people.
@MainActor
@Observable
final class MentionSuggestions {
    /// One thing a server offered for what is being typed.
    ///
    /// **One list and not two.** A person and a hashtag are drawn differently and written into
    /// the draft differently, and everything else about them here is identical — when to ask,
    /// how many to hold, which one `Tab` takes, what a stale answer is. Two lists would agree on
    /// the day they were written and drift from then on (#108).
    enum Offer: Identifiable, Hashable {
        case person(Profile)
        case tag(String)

        var id: String {
            switch self {
            case .person(let profile): "@\(profile.handle)"
            case .tag(let name): "#\(name)"
            }
        }

        /// What goes into the draft when this one is taken — written the way it goes into a post.
        var written: String {
            switch self {
            case .person(let profile): profile.handle
            case .tag(let name): "#\(name)"
            }
        }
    }

    /// What the server offered, newest question first. Empty is the ordinary state.
    private(set) var offers: [Offer] = []
    /// The one the reader took, which the composer watches for. Cleared as soon as it is read.
    var chosen: Offer?
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
    func look(for query: MentionQuery, as account: ActingAccount?) async {
        guard let account, let client = registry.client(for: .mastodon) else {
            return clear()
        }
        let text = query.text
        asking = text
        do {
            let found: [Offer]
            switch query.kind {
            case .handle:
                found = try await client.searchPeople(matching: text, limit: Self.most,
                                                      as: account).map(Offer.person)
            case .tag:
                found = try await client.searchTags(matching: text, limit: Self.most,
                                                    as: account).map(Offer.tag)
            }
            // The answer to a question the reader has moved on from is not an answer to draw.
            guard !Task.isCancelled, asking == text else { return }
            offers = found
        } catch {
            // Nothing is said about it. This is a convenience while somebody is typing, and a
            // server that would not answer is not a thing to interrupt a draft over — the reader
            // types it themselves, which is what they were doing anyway. **A tag nobody has used
            // is still typeable**: the offer is an offer, not a list of what is allowed.
            guard asking == text else { return }
            offers = []
        }
    }

    /// The offer goes away: the token stopped being a handle, the panel closed, or the reader
    /// took one.
    func clear() {
        offers = []
        asking = nil
    }

    /// The first of them, which is what a press of `Tab` takes.
    var first: Offer? { offers.first }
}
