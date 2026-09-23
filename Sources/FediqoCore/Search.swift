import Foundation

// Local search (#32): one wildcard pattern over every field a held post is known by.
//
// **Never a fetch.** It reads the notes this device already holds, as a timeline does, and asks
// no source anything.

/// One pattern as the reader typed it: `*` any run of characters, including none, `?` exactly
/// one character, every other character itself.
///
/// **Folded as a keyword is** (`Fold.key`), so case and width change nothing — and a full-width
/// `＊` or `？` folds to `*` or `?` and is a wildcard too, as a reader typing with a CJK input
/// method would expect. There is no escape: no quoting, by the issue.
///
/// **Found anywhere in a field, with or without a wildcard**, and with no word breaking, the way
/// a keyword rule is: `foot*ball` is a field holding `football` or `foot and ball` anywhere, and
/// `?` alone is any field with a character in it. So the pattern is read as if a `*` stood at
/// each end, and a leading or trailing `*` the reader types changes nothing.
///
/// **A character is a whole character**, as `Fold.contains` has it: `?` is one grapheme — one
/// emoji with its skin tone, one letter with its marks — and a literal run matches only where it
/// starts and ends on a character boundary of the field.
public struct WildcardPattern: Sendable {
    enum Token: Equatable, Sendable {
        case literal(String)
        case one
        case any
    }

    let tokens: [Token]

    /// Nothing for an empty pattern, or one of spaces alone: neither searches anything.
    public init?(_ text: String) {
        let folded = Fold.key(text)
        guard !folded.allSatisfy(\.isWhitespace) else { return nil }
        var tokens: [Token] = [.any]
        var run = ""
        for character in folded {
            guard character == "*" || character == "?" else {
                run.append(character)
                continue
            }
            if !run.isEmpty { tokens.append(.literal(run)) }
            run = ""
            // Two stars in a row are one: the backtracking below keeps only the last.
            if character == "*", tokens.last == .any { continue }
            tokens.append(character == "*" ? .any : .one)
        }
        if !run.isEmpty { tokens.append(.literal(run)) }
        if tokens.last != .any { tokens.append(.any) }
        self.tokens = tokens
    }

    /// Whether a field, already folded by `Fold.key`, matches.
    public func matches(_ field: String) -> Bool {
        // A plain keyword, the commonest search, skips the walk and its copy of the field.
        if tokens.count == 3, case .literal(let word) = tokens[1] { return Fold.contains(field, word) }
        var field = field
        // A folded field is a native string already, so this copies nothing and the walk reads
        // its bytes where they are.
        field.makeContiguousUTF8()
        return field.utf8.withContiguousStorageIfAvailable { Glob(field, $0).matches(tokens) } ?? false
    }
}

/// The match of the whole field, over its UTF-8 bytes in place, with character boundaries
/// checked. The pattern's own `*` at each end is what makes that "anywhere".
///
/// The classic single-backtrack wildcard walk: on a mismatch, go back to the last `*` and let it
/// take one more character. Where the token after a `*` is a literal, the next place it can
/// start is found with `memmem` rather than one character at a time, so `*word*` over a long
/// body costs one byte search, not a walk.
private struct Glob {
    let text: String
    /// `text`'s own UTF-8 storage, valid only for the one match it is lent to.
    let bytes: UnsafeBufferPointer<UInt8>

    init(_ text: String, _ bytes: UnsafeBufferPointer<UInt8>) {
        self.text = text
        self.bytes = bytes
    }

    func matches(_ tokens: [WildcardPattern.Token]) -> Bool {
        var token = 0
        var at = 0
        // The last `*` seen, and where in the field what follows it is being tried.
        var star: (token: Int, at: Int)?
        while true {
            if token < tokens.count {
                switch tokens[token] {
                case .any:
                    // A star at the end takes whatever is left.
                    if token + 1 == tokens.count { return true }
                    guard let start = start(after: token, from: at, in: tokens) else { return false }
                    star = (token, start)
                    token += 1
                    at = start
                    continue
                case .one:
                    if at < bytes.count {
                        at = after(at)
                        token += 1
                        continue
                    }
                case .literal(let word):
                    if hasWord(word, at: at) {
                        at += word.utf8.count
                        token += 1
                        continue
                    }
                }
            } else if at == bytes.count {
                return true
            }
            // A mismatch: let the last star take one more character, or there is no match.
            guard let last = star, last.at < bytes.count,
                  let next = start(after: last.token, from: after(last.at), in: tokens) else { return false }
            star = (last.token, next)
            token = last.token + 1
            at = next
        }
    }

    /// Where what follows the star at `token` can next start, at or after `from`: the next place
    /// its literal is, or `from` itself when it is not a literal. Nothing where the literal is
    /// nowhere further on — and then no longer star can help either.
    private func start(after token: Int, from: Int, in tokens: [WildcardPattern.Token]) -> Int? {
        guard case .literal(let word) = tokens[token + 1] else { return from }
        return find(word, from: from)
    }

    /// The first offset at or after `from` where `word` starts and ends on character boundaries.
    private func find(_ word: String, from: Int) -> Int? {
        let needle = Array(word.utf8)
        var from = from
        while from + needle.count <= bytes.count {
            let hit = needle.withUnsafeBufferPointer { key in
                memmem(bytes.baseAddress! + from, bytes.count - from, key.baseAddress!, key.count)
                    .map { UnsafeRawPointer(bytes.baseAddress!).distance(to: UnsafeRawPointer($0)) }
            }
            guard let start = hit else { return nil }
            if onBoundary(start) && onBoundary(start + needle.count) { return start }
            from = start + 1
        }
        return nil
    }

    private func hasWord(_ word: String, at offset: Int) -> Bool {
        let count = word.utf8.count
        guard offset + count <= bytes.count, onBoundary(offset + count) else { return false }
        return bytes[offset..<(offset + count)].elementsEqual(word.utf8)
    }

    /// The offset one whole character on. Only ever asked at a boundary.
    private func after(_ offset: Int) -> Int {
        let index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        return text.utf8.distance(from: text.utf8.startIndex, to: text.index(after: index))
    }

    private func onBoundary(_ offset: Int) -> Bool {
        String.Index(text.utf8.index(text.utf8.startIndex, offsetBy: offset), within: text) != nil
    }
}

/// Every held note's searchable fields, folded once, so each keystroke only matches.
///
/// Built the way `TextIndex` is: handing in the last one reuses every entry whose note did not
/// change. Kept apart from `TextIndex` because a timeline's rules read three of these fields and
/// search reads them all; folding names and hashtags for every rule evaluation would cost the
/// timelines for something they never ask.
public struct SearchIndex: Sendable {
    struct Entry: Sendable {
        let body: String
        let author: String
        let handle: String
        let boostedBy: String?
        let boosterHandle: String?
        /// Folded: the text, the author's handle and name, the booster's handle and name, each
        /// hashtag with its `#`, and the host. A handle is kept with its leading `@`, so `@ada`
        /// finds `@ada@one.example` as `ada` does. Categories are looked up per search, because
        /// their names live on the source and not on the note.
        let fields: [String]

        init(_ note: Note) {
            body = note.body
            author = note.author
            handle = note.handle
            boostedBy = note.boostedBy
            boosterHandle = note.boosterHandle
            let text = Fold.key(note.body)
            var fields = [text, "@" + Fold.handle(note.handle), Fold.key(note.author)]
            if let booster = note.boosterHandle { fields.append("@" + Fold.handle(booster)) }
            if let name = note.boostedBy { fields.append(Fold.key(name)) }
            fields += Self.hashtags(in: text)
            fields.append(note.source.host)
            self.fields = fields
        }

        func describes(_ note: Note) -> Bool {
            body == note.body && author == note.author && handle == note.handle
                && boostedBy == note.boostedBy && boosterHandle == note.boosterHandle
        }

        /// The tags in the words, each with its `#` — `PostTag`'s rule, and not a second spelling
        /// of it, so a post is found by exactly the tags its row draws as pills. The row reads
        /// the words as written and this reads them folded, and folding changes case and width
        /// and never whether a character is a letter. The one place it reaches the rule is a
        /// full-width `＃`, which folds to `#`: search finds `＃台灣` as `#台灣` and the row
        /// draws it as the letters typed, which is the generous side for a search to err on.
        static func hashtags(in text: String) -> [String] {
            PostTag.found(in: text).map(\.text)
        }
    }

    private let entries: [NoteKey: Entry]

    public init(_ notes: [Note], reusing old: SearchIndex? = nil) {
        var entries: [NoteKey: Entry] = [:]
        entries.reserveCapacity(notes.count)
        for note in notes {
            if let kept = old?.entries[note.key], kept.describes(note) {
                entries[note.key] = kept
            } else {
                entries[note.key] = Entry(note)
            }
        }
        self.entries = entries
    }

    func entry(for note: Note) -> Entry {
        if let entry = entries[note.key], entry.describes(note) { return entry }
        return Entry(note)
    }
}

/// One search, made ready against the sources held now.
public struct NoteSearch: Sendable {
    public let pattern: WildcardPattern
    /// Folded board and list names per host, from the sources as they are now: a board renamed
    /// on the server is found by its new name.
    private let categoryNames: [String: [Category: [String]]]
    /// Folded names of public, trends and home, which are the same on every source.
    private let sharedNames: [Category: [String]]

    /// Nothing for an empty pattern.
    ///
    /// `labels` are the names public, trends and home are drawn with — every language the app
    /// speaks, so a reader finds `趨勢` or `Trends` whichever the app is set to. The English words
    /// `public`, `trends` and `home` are always among them.
    public init?(_ text: String, sources: [Source], labels: [Category: [String]] = [:]) {
        guard let pattern = WildcardPattern(text) else { return nil }
        self.pattern = pattern
        var names: [String: [Category: [String]]] = [:]
        for source in sources {
            var byCategory: [Category: [String]] = [:]
            for board in source.boards {
                byCategory[.board(id: String(board.fid))] = [Fold.key(board.name)]
            }
            for list in source.lists {
                byCategory[.list(id: list.id)] = [Fold.key(list.name)]
            }
            names[source.host] = byCategory
        }
        categoryNames = names
        let words: [Category: String] = [.public: "public", .trends: "trends", .home: "home"]
        sharedNames = words.reduce(into: [:]) { shared, pair in
            shared[pair.key] = [pair.value] + (labels[pair.key] ?? []).map(Fold.key)
        }
    }

    private func names(of category: Category, on host: String) -> [String] {
        switch category {
        case .public, .trends, .home: sharedNames[category] ?? []
        case .list, .board: categoryNames[host]?[category] ?? []
        }
    }

    public func matches(_ note: Note, _ index: SearchIndex) -> Bool {
        if index.entry(for: note).fields.contains(where: pattern.matches) { return true }
        return note.categories.contains { category in
            names(of: category, on: note.source.host).contains(where: pattern.matches)
        }
    }

    /// The notes found, in the order given — store order, newest first, like a timeline.
    public func found(_ notes: [Note], _ index: SearchIndex) -> [Note] {
        // PROBE for #203 — never merged: five times the work, to prove the check bites on CI.
        for _ in 0..<4 { _ = notes.filter { matches($0, index) } }
        return notes.filter { matches($0, index) }
    }
}
