import Foundation

/// One thing a Mastodon sign-in may be asked for (#347): a part, and the scope words it is made
/// of. **Adding a part is one case here** and its entry in the `switch` below, which has no
/// `default:` so that a case without an entry does not build.
///
/// **In the order a page names them.** The order of the cases, and of each part's words, is the
/// order of every scope string this app sends — which is also what a registration records — so
/// it is today's order, word for word (`MastodonOAuth.scopes`).
///
/// **A part's words are never added to.** A sign-in is read as holding a part by its words, so
/// a part that grew a word would turn every sign-in made before into one that holds it only
/// partly. A new word is a new part.
public enum MastodonPart: String, CaseIterable, Sendable {
    /// Home, lists, and who the reader is.
    case reading
    /// Finding a post again by its address. Apart from `reading`: a server may refuse it alone.
    case search
    /// A post, a reply, a boost, a favourite, and taking any of them back.
    case acting
    /// A bookmark put on a post and taken off it.
    case bookmarks
    /// What the source says happened to the reader — and dismissing it, beside `acting`.
    case notices

    /// The words a page asks for this part.
    public var words: [String] {
        switch self {
        case .reading: ["read:statuses", "read:lists", "read:accounts"]
        case .search: ["read:search"]
        case .acting: ["write:statuses", "write:favourites"]
        case .bookmarks: ["write:bookmarks"]
        case .notices: ["read:notifications"]
        }
    }

    /// The words asked beside the part's own only where the acting part is held with it: an
    /// act of this part's, which a sign-in that only reads is not asked for.
    public var wordsBesideActing: [String] {
        switch self {
        case .notices: ["write:notifications"]
        case .reading, .search, .acting, .bookmarks: []
        }
    }
}

/// What is read off the table of parts.
public enum MastodonParts {
    /// The words one page asks for: what the sign-in holds, and the parts ticked — **and nothing
    /// else**, so that no page names a word its question did not.
    ///
    /// `held` is the scope string of the sign-in the page widens, or nothing where there is
    /// none. **A held word this table does not know is left out**: no registration this build
    /// makes holds it, and a page naming a word outside its registration is answered with a
    /// page of the server's own and nothing sent back.
    ///
    /// The words stand in the table's order whichever of the two brought them, so one choice is
    /// one string however it was reached.
    public static func page(held: String?, ticked: Set<MastodonPart>) -> String {
        let had = Set((held ?? "").split(separator: " ").map(String.init))
        let own = Set(ticked.flatMap(\.words))
        let will = had.union(own)
        let actingHeld = MastodonPart.acting.words.allSatisfy(will.contains)
        var words: [String] = []
        for part in MastodonPart.allCases {
            words += part.words.filter(will.contains)
            // Asked only where this page is what brings the two together: a sign-in holding
            // both and never asked for the act is not asked for it on a page about another part.
            let pressed = ticked.contains(part) || ticked.contains(.acting)
            let whole = part.words.allSatisfy(will.contains)
            let beside = part.wordsBesideActing
            words += beside.filter { had.contains($0) || (pressed && whole && actingHeld) }
        }
        return words.joined(separator: " ")
    }
}
