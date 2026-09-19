import Foundation

/// One way of making two spellings of the same text compare equal, for everything that looks
/// text up rather than draws it: a rule's keyword and author (#26), and later local search (#32).
///
/// **Case and width, nothing else.** `ＳＷＩＦＴ`, `Swift` and `swift` are one word, and so are
/// `ｶﾀｶﾅ` and `カタカナ`. Diacritics are not folded: `café` and `cafe` are different words to
/// the people who write them. No locale, so a device set to Turkish folds `I` as every other does.
///
/// **Composed as well**, so one spelling has one sequence of bytes and `contains` below can
/// compare bytes: an `é` typed as one character and one sent as `e` plus an accent are the same.
///
/// Two repairs after that. A no-break space — `&nbsp;` after `HTMLText`, the narrow one, the
/// ideographic one — is a space, which width folding leaves alone. And `İ` folds to `i` plus a
/// combining dot above, which would keep `istanbul` from `İSTANBUL`, so that dot after an `i`
/// is dropped.
public enum Fold {
    public static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
        guard folded.unicodeScalars.contains(where: { spaces.contains($0) || $0 == dotAbove }) else {
            return native(folded)
        }
        var repaired = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in folded.unicodeScalars {
            defer { previous = scalar }
            if scalar == dotAbove && previous == "i" { continue }
            repaired.append(spaces.contains(scalar) ? " " : scalar)
        }
        return String(repaired)
    }

    /// **Native UTF-8, always.** `folding` and `precomposedStringWithCanonicalMapping` hand back
    /// an `NSString` on macOS 15, whose bytes are not contiguous — so `contains` below found no
    /// storage to read and fell back to Foundation's substring search, which finds `🇺🇸` inside
    /// `🇦🇺🇸🇪`. A newer OS hands back a native string, which is why only CI saw it.
    private static func native(_ text: String) -> String {
        var text = text
        text.makeContiguousUTF8()
        return text
    }

    private static let spaces: Set<Unicode.Scalar> = ["\u{00A0}", "\u{202F}", "\u{3000}"]
    private static let dotAbove: Unicode.Scalar = "\u{0307}"

    /// Whether folded `text` holds folded `part` anywhere, with no word breaking — so `#swift`
    /// is inside `#swiftui` — but only as whole characters.
    ///
    /// **Bytes, not characters**, because this runs for every keyword against every held note on
    /// every redraw: `String.contains` walks characters and cost four times the budget. Both
    /// sides are folded and composed by `key`, so equal text is equal bytes.
    ///
    /// **A byte hit counts only where it starts and ends on a character boundary** of `text`,
    /// checked on a hit alone. So `🇺🇸` is not inside `🇦🇺🇸🇪`, `e` is not inside `e̱`, and `👍`
    /// is not inside `👍🏽`: a skin tone, a joiner or a mark makes a different character. What
    /// remains is `part` itself: a keyword that begins with a combining mark or a lone modifier
    /// is compared as the bytes it is.
    public static func contains(_ text: String, _ part: String) -> Bool {
        if part.isEmpty { return true }
        let found = text.utf8.withContiguousStorageIfAvailable { haystack in
            part.utf8.withContiguousStorageIfAvailable { needle -> Bool in
                guard let base = haystack.baseAddress, let key = needle.baseAddress else { return false }
                var from = 0
                while from + needle.count <= haystack.count,
                      let hit = memmem(base + from, haystack.count - from, key, needle.count) {
                    let start = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                    if onBoundary(text, start) && onBoundary(text, start + needle.count) { return true }
                    from = start + 1
                }
                return false
            }
        }
        if let found = found.flatMap({ $0 }) { return found }
        // Not contiguous — a string that did not come through `key`. Made so, and read the same
        // way, rather than handed to a substring search that splits characters.
        return contains(native(text), native(part))
    }

    private static func onBoundary(_ text: String, _ offset: Int) -> Bool {
        String.Index(text.utf8.index(text.utf8.startIndex, offsetBy: offset), within: text) != nil
    }

    /// A handle as a rule compares it: `user@instance`, folded, with the one leading `@` a
    /// handle is drawn with dropped. `@Ada@First.example` and `ada@first.example` are one person.
    ///
    /// Width is folded too, so a forum name written `ＡＢＣ` and one written `abc` are one person.
    public static func handle(_ handle: String) -> String {
        let folded = key(handle)
        return folded.hasPrefix("@") ? String(folded.dropFirst()) : folded
    }
}

/// Each held note's text, folded once, so a timeline's keyword and author rules are string
/// lookups rather than a fold per note per rule on every redraw.
///
/// Built wherever the held notes are replaced. Handing in the index built last time reuses every
/// entry whose note did not change, so a fetch that brings forty notes folds forty.
public struct TextIndex: Sendable {
    struct Entry: Sendable {
        // What was folded, kept to know whether a note with this key is still the same note.
        // Strings are shared storage, so this costs no copy of the body.
        let body: String
        let handle: String
        let boosterHandle: String?

        /// What a keyword reads: the body alone (Decision 13).
        let text: String
        let foldedHandle: String
        let foldedBooster: String?

        init(_ note: Note) {
            body = note.body
            handle = note.handle
            boosterHandle = note.boosterHandle
            text = Fold.key(note.body)
            foldedHandle = Fold.handle(note.handle)
            foldedBooster = note.boosterHandle.map(Fold.handle)
        }

        func describes(_ note: Note) -> Bool {
            body == note.body && handle == note.handle && boosterHandle == note.boosterHandle
        }
    }

    private let entries: [NoteKey: Entry]
    /// How many entries this build folded rather than reused.
    let folded: Int

    public init(_ notes: [Note], reusing old: TextIndex? = nil) {
        var entries: [NoteKey: Entry] = [:]
        var folded = 0
        entries.reserveCapacity(notes.count)
        for note in notes {
            let key = note.key
            if let kept = old?.entries[key], kept.describes(note) {
                entries[key] = kept
            } else {
                entries[key] = Entry(note)
                folded += 1
            }
        }
        self.entries = entries
        self.folded = folded
    }

    /// The note's entry, or one folded now for a note this index was not built over — so a
    /// caller holding no index (All and Trends read no text) can pass an empty one.
    func entry(for note: Note) -> Entry {
        if let entry = entries[note.key], entry.describes(note) { return entry }
        return Entry(note)
    }
}
