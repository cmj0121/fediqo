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
    /// The reader's own account as others see it: its name, its words and fields, and what it
    /// lets others do (#312). **The source gives the same word for more than that** — featuring
    /// people and hashtags, pinning a post, dismissing an announcement or a suggestion — so the
    /// question says so. Stands without `acting`.
    case account
    /// A picture, a sound or a film on a post, each with a description. **Adds to acting**:
    /// a sign-in that only reads has nothing to attach it to. Not a rider — a page that
    /// lacks the word is made again, rather than signed in without it.
    case media
    /// What the reader bookmarked and favourited at the source, read back as categories of it
    /// (#317) — from whichever reader marked them. **Reads, and stands without `acting`**: a
    /// sign-in that only reads may be asked for it, and only where the person presses for it.
    case marks
    /// Who the reader mutes and blocks at the source, and the servers they block (#314): the
    /// three lists read, and each muting and blocking made and undone. **Stands without
    /// `acting`**, as following does: a sign-in that only reads may be asked for it, and then
    /// sees the lists and changes none of them.
    case blocks
    /// A post or a person reported to those who answer for the server (#339). **Stands without
    /// `acting`**: telling a server's moderators is not writing as the reader, and a sign-in that
    /// only reads may be asked for it.
    case reports
    /// The person's filters at the source (#338): what it hides or warns of for them, read, made,
    /// changed and removed. **Stands without `acting`**: a sign-in that only reads may be asked for
    /// it, and then sees the filters and changes none. What a post says a filter caught needs no
    /// part: the source tells every reader of the post.
    case filters
    /// A list made, renamed and removed, and who is on it changed (#337). **Stands without
    /// `acting`**: `read:lists` stays on reading, and `write:lists` is asked where a list is
    /// changed. A new word, so it is a part of its own and not a word added to reading.
    case lists
    /// Posts written to named people (#326): marking a conversation read, and removing it from
    /// the list. **Reading them is `reading`** — the same word that reads a timeline — so a
    /// sign-in that reads can see the list, and this part is only what changes it. Stands
    /// without `acting`. The coarse word `write` is not this part.
    case conversations
    /// Tending the server the reader answers for (#380): what was reported to it, who asks to
    /// join, the servers and addresses it refuses, and what it lets rise. **The larger thing,
    /// asked only from its own lock and alone** — never ridden on another question — and of use
    /// only to an account the server gives standing (`MastodonStaff`): the words may be granted
    /// to anyone, and the standing, not the words, is what draws anything (D9, D13). Coarse on
    /// purpose: a server takes only its two broad words for some of it.
    case tending

    /// The words a page asks for this part.
    public var words: [String] {
        switch self {
        case .reading: ["read:statuses", "read:lists", "read:accounts"]
        case .search: ["read:search"]
        case .acting: ["write:statuses", "write:favourites"]
        case .bookmarks: ["write:bookmarks"]
        case .notices: ["read:notifications"]
        case .follows: ["read:follows", "write:follows"]
        case .account: ["write:accounts"]
        case .media: ["write:media"]
        case .marks: ["read:bookmarks", "read:favourites"]
        case .blocks: ["read:mutes", "write:mutes", "read:blocks", "write:blocks"]
        case .reports: ["write:reports"]
        case .filters: ["read:filters", "write:filters"]
        case .lists: ["write:lists"]
        case .conversations: ["write:conversations"]
        case .tending: ["admin:read", "admin:write"]
        }
    }

    /// The words asked beside the part's own only where the acting part is held with it: an
    /// act of this part's, which a sign-in that only reads is not asked for.
    public var wordsBesideActing: [String] {
        switch self {
        case .notices: ["write:notifications"]
        case .reading, .search, .acting, .bookmarks, .follows, .account, .media, .marks, .blocks, .reports, .filters, .tending, .lists, .conversations: []
        }
    }

    /// Whether the part only rides on the question of reading, or reading and acting, and a
    /// sign-in is whole without it: a source that has none of it is signed in to all the same,
    /// and the part stays a lock at its own place.
    public var rider: Bool {
        switch self {
        case .search, .bookmarks: true
        case .reading, .acting, .notices, .follows, .account, .media, .marks, .blocks, .reports, .filters, .tending, .lists, .conversations: false
        }
    }

    /// Whether the part only adds to acting, and is asked of no sign-in that does not act:
    /// such a sign-in has nothing to add it to, and its row already says to sign in to act.
    public var needsActing: Bool {
        switch self {
        case .bookmarks, .media: true
        case .reading, .search, .acting, .notices, .follows, .account, .marks, .blocks, .reports, .filters, .tending, .lists, .conversations: false
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

    /// Whether a sign-in holding `part` in part may be asked for the rest of it where it
    /// stands: no page has asked it for a word of the part it lacks — one asked and not given
    /// would be answered the same again — and it reads by every word of reading, which is
    /// what a page is built over (`reads`). **So reading itself, held in part, is never asked
    /// for in place**: such a sign-in is signed in again.
    public static func asksRest(_ part: MastodonPart, of held: MastodonHeld) -> Bool {
        guard standing(part, of: held) == .partly, reads(held.scopes) else { return false }
        let has = words(held.scopes)
        return words(held.asked).isDisjoint(with: part.words.filter { !has.contains($0) })
    }

    /// What signing in again carries of the sign-in held, whichever answer is given: its
    /// words that are no word of `choice` — those are the answer's to ask for or leave — and
    /// that **this device itself asked that sign-in for**. A word only the record says is
    /// held, as a package may bring it, is carried onto no page: nobody was shown it here.
    /// In the order held; nothing, where nothing is held.
    public static func carried(of held: MastodonHeld?, beside choice: Set<MastodonPart>) -> String? {
        guard let held else { return nil }
        let chosen = Set(choice.flatMap { $0.words + $0.wordsBesideActing })
        let asked = words(held.asked)
        return spelt((held.scopes ?? "").split(separator: " ").map(String.init)
            .filter { !chosen.contains($0) && asked.contains($0) })
    }

    /// The words of `scopes` that `page` has none of, in the order held: what a sign-in
    /// gives up by being replaced by one made on that page.
    public static func lost(of scopes: String?, on page: String) -> [String] {
        more(on: scopes ?? "", than: page)
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

    /// The half of `part` that `scopes` holds, where it holds one and not the other: every
    /// word of it that reads and none that acts, or the other way round. Nothing for a part
    /// held whole, held not at all, or held in part some other way — and nothing for a part
    /// with no such halves, all of whose words read or all of whose words act.
    public static func half(of part: MastodonPart, in scopes: String?) -> MastodonHalf? {
        let held = part.words.filter(words(scopes).contains)
        let acting = part.words.filter(acts)
        guard !acting.isEmpty, acting.count < part.words.count else { return nil }
        if held == acting { return .changing }
        return held == part.words.filter { !acts($0) } ? .seeing : nil
    }

    /// A list of scope words as a package brings it (#347): only what can be a scope word
    /// at all (`MastodonRegistration.isWord`), one space between — and nothing, where none
    /// is one or there are more than a source's own account of a token may bring
    /// (`MastodonOAuth.tokenInfoWords`). Nothing written down is a sign-in never asked,
    /// which is asked again and widens nothing.
    ///
    /// **Not only the words this table knows**: a sign-in an earlier build made reads by
    /// the source's one word for every read, which is no part's word, and must go on
    /// reading as it did.
    static func carriedWords(_ said: String?) -> String? {
        guard let said, said.utf8.count <= MastodonOAuth.tokenInfoWords * (MastodonRegistration.wordLength + 1) else { return nil }
        let words = said.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count <= MastodonOAuth.tokenInfoWords else { return nil }
        let kept = words.filter(MastodonRegistration.isWord)
        return kept.isEmpty ? nil : spelt(kept)
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

    /// Whether a scope string holds the half of `part` that sees (`seeing`) or that changes:
    /// the part whole, or that half of it. What tending's page is drawn and acted by (#380).
    public static func holds(_ half: MastodonHalf, of part: MastodonPart, in scopes: String?) -> Bool {
        holds(part, in: scopes) || Self.half(of: part, in: scopes) == half
    }

    /// Whether a scope string holds the act `part` is asked for beside acting, read as
    /// `holds(_:in:)` is. A part with no such act holds none.
    public static func holdsBesideActing(_ part: MastodonPart, in scopes: String?) -> Bool {
        let beside = part.wordsBesideActing
        return !beside.isEmpty && beside.allSatisfy(words(scopes).contains)
    }

    /// Whether a scope string may read `category` of the reader's marks (#317): the word of
    /// `MastodonPart.marks` that reads it — the one naming it (`Category.markWord`) — or the
    /// source's one word for every read, which holds both. Never for any other category.
    public static func readsMarks(_ category: Category, in scopes: String?) -> Bool {
        guard let mark = category.markWord,
              let word = MastodonPart.marks.words.first(where: { $0.hasSuffix(":" + mark) })
        else { return false }
        return holdsEveryRead(in: scopes) || words(scopes).contains(word)
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
    /// "Read only" drops by this prefix — and by tending's word that changes (#380), the one
    /// acting word outside it.
    private static func acts(_ word: String) -> Bool {
        word.hasPrefix("write:") || word == "admin:write"
    }

    private static func words(_ scopes: String?) -> Set<String> {
        Set((scopes ?? "").split(separator: " ").map(String.init))
    }
}

/// How a sign-in stands to one part (#347).
public enum MastodonPartStanding: Sendable, Equatable, CaseIterable {
    /// Every word of it is held.
    case held
    /// Some of its words are held: what those allow is offered. The rest is asked for where
    /// the sign-in stands only if no page asked for it before (`MastodonParts.asksRest`).
    case partly
    /// No page has asked this sign-in for it. Asking is what changes it.
    case unasked
    /// The person refused it on the source's own page. It may be asked again.
    case refused
    /// Asked, and the source gave none of it — or has none to give. Asking again would get
    /// the same answer.
    case notGiven
}

/// One half of a part whose words both read and act (`MastodonParts.half`): named for what
/// it lets be done, which is what a sentence about it is keyed by.
public enum MastodonHalf: String, Sendable, Equatable {
    /// The words that read.
    case seeing
    /// The words that act.
    case changing

    /// The half a sign-in holding this one lacks.
    public var other: MastodonHalf { self == .seeing ? .changing : .seeing }
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
