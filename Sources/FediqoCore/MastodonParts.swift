import Foundation

/// One thing a Mastodon sign-in may be asked for (#347): a part, and the scope words it is made
/// of. **Adding a part is one case here** and its entry in each `switch` below, none of which
/// has a `default:`, so that a case without an entry does not build.
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
    /// How the reader stands to someone, and following: people and hashtags followed and
    /// unfollowed, requests to follow answered, a follower removed. **Stands without
    /// `acting`**: a sign-in that only reads may be asked for it (#347).
    case follows

    /// The words a page asks for this part.
    public var words: [String] {
        switch self {
        case .reading: ["read:statuses", "read:lists", "read:accounts"]
        case .search: ["read:search"]
        case .acting: ["write:statuses", "write:favourites"]
        case .bookmarks: ["write:bookmarks"]
        case .notices: ["read:notifications"]
        case .follows: ["read:follows", "write:follows"]
        }
    }

    /// The words asked beside the part's own only where the acting part is held with it: an
    /// act of this part's, which a sign-in that only reads is not asked for.
    public var wordsBesideActing: [String] {
        switch self {
        case .notices: ["write:notifications"]
        case .reading, .search, .acting, .bookmarks, .follows: []
        }
    }

    /// Whether the part only rides on the question of reading, or reading and acting, and a
    /// sign-in is whole without it: a source that has none of it is signed in to all the same,
    /// and the part stays a lock at its own place.
    public var rider: Bool {
        switch self {
        case .search, .bookmarks: true
        case .reading, .acting, .notices, .follows: false
        }
    }

    /// Whether the part only adds to acting, and is asked of no sign-in that does not act:
    /// such a sign-in has nothing to add it to, and its row already says to sign in to act.
    public var needsActing: Bool {
        switch self {
        case .bookmarks: true
        case .reading, .search, .acting, .notices, .follows: false
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
    /// **The source's one word for every read, or for every write, is such a word** — `read`,
    /// `write`, as a sign-in made by something else may hold them. It is left out and never
    /// spelt out into the words it covers: those would be words on the page that no question
    /// named. A page widening such a sign-in asks for what was ticked and nothing held.
    ///
    /// `readOnly` is the answer "read only" to whether a sign-in reads or reads and acts: no
    /// word that acts is asked, held or ticked, and every word held to read is.
    ///
    /// The words stand in the table's order whichever of the two brought them, so one choice is
    /// one string however it was reached.
    public static func page(held: String?, ticked: Set<MastodonPart>, readOnly: Bool = false) -> String {
        var had = words(held)
        var own = Set(ticked.flatMap(\.words))
        if readOnly {
            had = had.filter { !acts($0) }
            own = own.filter { !acts($0) }
        }
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
        return spelt(words)
    }

    /// Every word of every part, in the table's order: what this app is registered for at a
    /// source, so that a page for any part is one its registration holds.
    public static let everything = page(held: nil, ticked: Set(MastodonPart.allCases))

    /// The words of the parts a sign-in is whole without (`MastodonPart.rider`).
    static let riderWords = Set(MastodonPart.allCases.filter(\.rider).flatMap(\.words))

    /// What is still refused of `refused`, each list in turn, once a sign-in holds `given`:
    /// every word but those given, once each and in the order met. Nothing, where none is left.
    static func refused(_ refused: [String?], given: String?) -> String? {
        var seen = words(given)
        let left = refused.flatMap { ($0 ?? "").split(separator: " ").map(String.init) }
            .filter { seen.insert($0).inserted }
        return left.isEmpty ? nil : spelt(left)
    }

    /// The held words this table does not know, in the order held: what no page of this build
    /// can ask for again, so a sign-in asked for more gives them up — and is told so first.
    public static func unknown(in scopes: String?) -> [String] {
        let known = Set(MastodonPart.allCases.flatMap { $0.words + $0.wordsBesideActing })
        var seen = Set<String>()
        return (scopes ?? "").split(separator: " ").map(String.init)
            .filter { !known.contains($0) && seen.insert($0).inserted }
    }

    /// Every word of `lists`, each once and in the order met: what a sign-in has been asked
    /// for across every page that asked it. Nothing, where there is no word.
    public static func union(_ lists: String?...) -> String? {
        var seen = Set<String>()
        let all = lists.flatMap { ($0 ?? "").split(separator: " ").map(String.init) }
            .filter { seen.insert($0).inserted }
        return all.isEmpty ? nil : spelt(all)
    }

    /// The words of `parts`, in the table's order — those `kept` keeps, where only some are
    /// meant: what a page refused was refused for, and what a source said it has none of.
    public static func words(of parts: Set<MastodonPart>, where kept: (String) -> Bool = { _ in true }) -> String {
        spelt(MastodonPart.allCases.filter(parts.contains).flatMap(\.words).filter(kept))
    }

    /// What a sign-in is believed to hold where its source says it holds `listed`: those
    /// words — and, where what this device asked of it is known, only the ones it asked for.
    /// A source naming a word nobody was shown cannot make this device think it holds it.
    public static func believed(_ listed: [String], asked: String?) -> String {
        guard let asked else { return spelt(listed) }
        return spelt(listed.filter(words(asked).contains))
    }

    /// Whether two scope strings hold the same words, in whatever order.
    public static func same(_ one: String?, _ other: String?) -> Bool {
        words(one) == words(other)
    }

    /// The words of `page` that `held` has none of, in the page's order: what a page asks
    /// for beyond what a sign-in holds.
    public static func more(on page: String, than held: String?) -> [String] {
        let has = words(held)
        return page.split(separator: " ").map(String.init).filter { !has.contains($0) }
    }

    /// The parts whose act beside acting `page` asks for and `held` has not: what a page
    /// brings in by bringing a part and acting together, which its question names with the
    /// part ticked. In the table's order.
    public static func beside(on page: String, than held: String?) -> [MastodonPart] {
        let brought = Set(more(on: page, than: held))
        return MastodonPart.allCases.filter { !brought.isDisjoint(with: $0.wordsBesideActing) }
    }

    /// How a sign-in stands to `part`, by what is written beside it — the one reading every
    /// place that offers the part's acts goes by.
    public static func standing(_ part: MastodonPart, of held: MastodonHeld) -> MastodonPartStanding {
        let has = words(held.scopes)
        let missing = part.words.filter { !has.contains($0) }
        if missing.isEmpty { return .held }
        if !words(held.refused).isDisjoint(with: missing) { return .refused }
        if missing.count < part.words.count { return .partly }
        return words(held.asked).isDisjoint(with: missing) ? .unasked : .notGiven
    }

    /// What a sign-in holds, part by part, by its scope string — **every word of it said
    /// once**: a part whole, a part held in part, the act a part gains beside acting, and a
    /// word this table does not know. Read off the table alone, so a part added to it is
    /// listed with no edit here. In the table's order; the words it does not know, as held.
    ///
    /// **Nothing here is how a sign-in is called** — one that reads, one that acts: a sign-in
    /// holds parts, and a part stands by itself (#347).
    public static func holdings(in scopes: String?) -> MastodonHoldings {
        let has = words(scopes)
        var entries: [MastodonHoldings.Entry] = []
        for part in MastodonPart.allCases {
            let held = part.words.filter(has.contains)
            if held.count == part.words.count {
                entries.append(.whole(part))
            } else if !held.isEmpty {
                entries.append(.partly(part))
            }
            if part.wordsBesideActing.contains(where: has.contains) { entries.append(.beside(part)) }
        }
        return MastodonHoldings(entries: entries, other: unknown(in: scopes))
    }

    /// Words as the one string a source reads them in.
    private static func spelt(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    /// Whether a scope string holds `part`: every word of it, **word by word and never as a
    /// substring**, so words handed back in another order still hold it and a word that merely
    /// contains one does not. Nothing written down holds nothing.
    public static func holds(_ part: MastodonPart, in scopes: String?) -> Bool {
        part.words.allSatisfy(words(scopes).contains)
    }

    /// Whether a scope string holds the act `part` is asked for beside acting, read as
    /// `holds(_:in:)` is. A part with no such act holds none.
    public static func holdsBesideActing(_ part: MastodonPart, in scopes: String?) -> Bool {
        let beside = part.wordsBesideActing
        return !beside.isEmpty && beside.allSatisfy(words(scopes).contains)
    }

    /// Whether a scope string holds the source's one word for every read there is — which no
    /// page of this app asks for, and a sign-in made by something else may hold.
    public static func holdsEveryRead(in scopes: String?) -> Bool {
        words(scopes).contains("read")
    }

    /// Whether a scope string is one a sign-in reads by: every word of reading, word for
    /// word. **A source's account of a sign-in that does not read is no account of one** —
    /// every sign-in this app holds was asked to — and is believed of none.
    ///
    /// **The source's one word for every read is not reading here**, because `page` leaves it
    /// out: a page built over such a sign-in would carry what was ticked and no reading at
    /// all, and the sign-in that came back could not read Home. So such a sign-in is not
    /// asked where it stands; it is signed in again, choosing what to allow.
    public static func reads(_ scopes: String?) -> Bool {
        holds(.reading, in: scopes)
    }

    /// Whether a word lets something be changed at the source, by the source's own spelling.
    /// "Read only" drops by this prefix alone: a later part with an acting word outside it
    /// must be marked in the table.
    private static func acts(_ word: String) -> Bool {
        word.hasPrefix("write:")
    }

    private static func words(_ scopes: String?) -> Set<String> {
        Set((scopes ?? "").split(separator: " ").map(String.init))
    }
}

/// How a sign-in stands to one part (#347).
public enum MastodonPartStanding: Sendable, Equatable, CaseIterable {
    /// Every word of it is held.
    case held
    /// Some of its words are held: what those allow is offered, and the rest is not asked.
    case partly
    /// No page has asked this sign-in for it. Asking is what changes it.
    case unasked
    /// The person refused it on the source's own page. It may be asked again.
    case refused
    /// Asked, and the source gave none of it — or has none to give. Asking again would get
    /// the same answer.
    case notGiven
}

/// What a sign-in holds, part by part (`MastodonParts.holdings`).
public struct MastodonHoldings: Sendable, Equatable {
    public enum Entry: Sendable, Equatable {
        /// Every word of the part.
        case whole(MastodonPart)
        /// Some of its words, and not all.
        case partly(MastodonPart)
        /// The act the part gains beside acting (`MastodonPart.wordsBesideActing`).
        case beside(MastodonPart)
    }

    /// What is held of the table's parts, in the table's order.
    public let entries: [Entry]
    /// The held words the table does not know, in the order held — the source's one word
    /// for every read, or for every write, among them.
    public let other: [String]
}
