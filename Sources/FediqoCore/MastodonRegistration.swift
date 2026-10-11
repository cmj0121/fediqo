import Foundation

/// What this app is registered for at a Mastodon, and what a page may ask on a registration
/// (#347). **One registration for every word the table of parts knows**, so that asking a
/// sign-in for a further part is a page and never a second registration — a server takes few
/// of those (five in ten minutes, on a 4.6).
///
/// A server refuses a registration whole for one word it does not know, and says nothing of
/// which. So a word a host lacks is found before any page: by the host's own list where it
/// publishes one, and otherwise by the registration being refused and made once more for less.
public enum MastodonRegistration {
    /// Where a host publishes what it knows: RFC 8414's address, which a Mastodon answers to
    /// anybody.
    static let listPath = "/.well-known/oauth-authorization-server"
    /// The one thing read of what is there. **Nothing else in that document is ever read**:
    /// every address this app signs in at is a fixed path on the host it was given.
    static let listName = "scopes_supported"
    /// How much of a list is looked at: a 4.6 names forty-seven words in 1,620 bytes.
    static let listBytes = 64 << 10
    static let listWords = 512
    static let wordLength = 64

    /// The words a host's own document lists, or nothing where it lists none that can be
    /// believed — which is no list, and never a failure.
    ///
    /// **Written by a stranger's server, so read as that**: no more than `listBytes`, any shape
    /// but an object naming a list is no list, an entry that is not a word — not a string, too
    /// long, outside RFC 6749's letters for a scope — is passed over, and a list longer than
    /// `listWords` is no list at all rather than one cut short, since a word cut off would be
    /// read as a word the host lacks.
    ///
    /// **A list without the words every sign-in is asked for is no list either.** It is some
    /// other document, or a host naming only its coarse words; believed, it would take from the
    /// registration everything a sign-in needs. Left unbelieved, the host's own answer to the
    /// registration is what says.
    static func listed(in body: Data) -> Set<String>? {
        guard body.count <= listBytes,
              let said = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let entries = said[listName] as? [Any], entries.count <= listWords
        else { return nil }
        let words = Set(entries.compactMap { $0 as? String }.filter(isWord))
        guard MastodonPart.reading.words.allSatisfy(words.contains) else { return nil }
        return words
    }

    /// RFC 6749 §3.3: one or more printable characters, no space, quote or backslash.
    private static func isWord(_ entry: String) -> Bool {
        guard !entry.isEmpty, entry.utf8.count <= wordLength else { return false }
        return entry.utf8.allSatisfy { $0 == 0x21 || (0x23...0x5B).contains($0) || (0x5D...0x7E).contains($0) }
    }

    /// What this app registers for at a host: every word of every part, in the table's order,
    /// less what the host's own list does not have. **The list only ever takes away**: a word
    /// it names that the table does not know is never asked for.
    public static func superset(listed: Set<String>? = nil) -> String {
        guard let listed else { return MastodonParts.everything }
        return words(MastodonParts.everything).filter(listed.contains).joined(separator: " ")
    }

    /// What a page asks on a registration made for `registered`, where `chosen` is what the
    /// person's answer asks: `chosen`, less the words of a part a sign-in is whole without that
    /// the registration does not hold — such a part was not asked, and stays a lock at its own
    /// place. Nothing, where the registration lacks any other word of it: no page is opened
    /// that its registration cannot carry, since a server answers one with a page of its own
    /// and sends nothing back.
    public static func page(_ chosen: String, on registered: String?) -> String? {
        let held = Set(words(registered))
        let lacking = words(chosen).filter { !held.contains($0) }
        guard lacking.allSatisfy(MastodonParts.riderWords.contains) else { return nil }
        return only(chosen, where: held.contains)
    }

    /// What a sign-in that chose `chosen` and whose page asked `page` is written down as having
    /// asked: the page's words, and those of `chosen` the host itself has none of — the row
    /// stops offering such a part. **A word merely left off the page is not among them**: it
    /// was not asked, and stays a lock at its own place.
    public static func asked(_ chosen: String, on page: String, hasNone: (String) -> Bool) -> String {
        let paged = Set(words(page))
        return only(chosen) { paged.contains($0) || hasNone($0) }
    }

    /// Whether a sign-in holding `held` is left every word of it that `chosen` asks, by one
    /// that holds `words`. A word `chosen` does not ask is one the person gave up by choosing.
    public static func keeps(_ held: String?, asking chosen: String, in words: String?) -> Bool {
        let kept = Set(Self.words(words))
        return Self.words(chosen).filter(Set(Self.words(held)).contains).allSatisfy(kept.contains)
    }

    private static func only(_ scopes: String, where kept: (String) -> Bool) -> String {
        words(scopes).filter(kept).joined(separator: " ")
    }

    /// Whether a registration made for `registered` holds every word of `page`.
    public static func holds(_ page: String, on registered: String?) -> Bool {
        Set(words(page)).isSubset(of: words(registered))
    }

    fileprivate static func words(_ scopes: String?) -> [String] {
        (scopes ?? "").split(separator: " ").map(String.init)
    }
}

/// What one run has learnt of registering this app at each host. **Kept nowhere**: it is what
/// stops a press from spending a registration on something a host has already answered, and
/// the next run asks afresh.
public struct MastodonRegistering: Sendable {
    private var lists: [String: Set<String>] = [:]
    private var refused: [String: Set<String>] = [:]
    private var lacked: [String: Set<String>] = [:]
    private var wholeGone: Set<String> = []
    private var unconfirmed: Set<String> = []
    private var strandedOnce: Set<String> = []
    private var strandedForGood: Set<String> = []

    public init() {}

    /// The host's own list, where it has given one this run.
    public func list(_ host: String) -> Set<String>? { lists[host] }

    public mutating func learnt(_ list: Set<String>, of host: String) { lists[host] = list }

    /// Whether the registration for everything may still be tried at `host`: not refused there
    /// this run, and not suspected of stranding a page.
    public func mayTryWhole(_ host: String) -> Bool { !wholeGone.contains(host) }

    /// The host refused the registration for everything.
    public mutating func refusedWhole(_ host: String) { wholeGone.insert(host) }

    /// Whether `host` refused a registration for exactly `words` this run: it is not asked for
    /// them again.
    public func refused(_ words: String, at host: String) -> Bool {
        refused[host]?.contains(words) == true
    }

    public mutating func refuse(_ words: String, at host: String) {
        refused[host, default: []].insert(words)
    }

    /// Whether `host` has itself said, this run, that it has none of `word`: its list lacks
    /// it, its answer to a registration left it out, or it alone parted a registration refused
    /// from one made.
    public func hasNone(of word: String, at host: String) -> Bool {
        lacked[host]?.contains(word) == true || lists[host].map { !$0.contains(word) } == true
    }

    /// `host` registered `made` where it was asked for `asked`, and named what it registered:
    /// what it left out, it has none of.
    public mutating func named(_ made: String?, of asked: String, at host: String) {
        lacked[host, default: []].formUnion(Set(MastodonRegistration.words(asked)).subtracting(MastodonRegistration.words(made)))
    }

    /// `host` made a registration for `made`, having refused one for `refused`. Where one word
    /// parts the two, the host has none of it; where more do, nothing says which, and a word
    /// only left off is not one the host was asked about.
    public mutating func made(_ made: String, after refused: String, at host: String) {
        let parting = Set(MastodonRegistration.words(refused)).subtracting(MastodonRegistration.words(made))
        if parting.count == 1 { lacked[host, default: []].formUnion(parting) }
    }

    /// Whether the registration made at `host` this run is one nothing has confirmed: the host
    /// neither lists its words nor said which of those asked it registered.
    public func isUnconfirmed(_ host: String) -> Bool { unconfirmed.contains(host) }

    public mutating func made(at host: String, confirmed: Bool) {
        if confirmed { unconfirmed.remove(host) } else { unconfirmed.insert(host) }
    }

    /// Whether a page at `host` is suspected of having been one of the server's own, with no
    /// way back: the next press registers for exactly what it asks where a sign-in is held,
    /// and for the least a sign-in can be where none is.
    public func suspected(_ host: String) -> Bool { strandedOnce.contains(host) }

    /// Whether `host` cannot be asked again this run: a second page went the same way.
    public func stranded(_ host: String) -> Bool { strandedForGood.contains(host) }

    /// A sign-in was kept at `host`: its pages do come back, and nothing is suspected of it.
    public mutating func signedIn(_ host: String) {
        strandedOnce.remove(host)
        strandedForGood.remove(host)
    }

    /// Everything this run learnt of `host` is let go: the person removed the source, and one
    /// added again is asked as a host nothing is known of.
    public mutating func forget(_ host: String) {
        lists[host] = nil
        refused[host] = nil
        lacked[host] = nil
        wholeGone.remove(host)
        unconfirmed.remove(host)
        strandedOnce.remove(host)
        strandedForGood.remove(host)
    }

    /// A page at `host` ended with nothing sent back, on a registration nothing confirmed:
    /// suspected the first time, and the second time the host is not asked again this run.
    /// The registration for everything is not tried there again either way.
    public mutating func strand(_ host: String) {
        unconfirmed.remove(host)
        wholeGone.insert(host)
        if strandedOnce.contains(host) { strandedForGood.insert(host) }
        strandedOnce.insert(host)
    }
}
