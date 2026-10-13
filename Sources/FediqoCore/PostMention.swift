import Foundation

/// Somebody a post's words name, and the letters they were named with (#310).
///
/// **Who it is comes from the source, never from the words.** A source that says a post
/// mentions people lists them beside its words, and only somebody on that list is a mention:
/// `text` is where the words spell them and `handle` is who the source said that is. An `@word`
/// the source did not list is letters, whatever it looks like — reading a person out of a
/// stranger's text is the guess `PostLink.opener` refuses to make about an address.
public struct PostMention: Sendable, Hashable {
    /// Exactly what the author typed, drawn exactly as they typed it: `@ada`, or `@ada@host`.
    public let text: String
    /// Who the source said the post mentions, whole: `@name@host`, as an author's handle is.
    public let handle: String
}

public extension PostMention {
    /// How many people one post may be kept as mentioning, and how many mentions its words may
    /// draw: `PostLink.maxLinks`' bound, for its reason.
    static var maxMentions: Int { 32 }

    /// How long a whole handle may be: as long as one that can be asked for is.
    static var handleLength: Int { MastodonPerson.handleLength }

    /// The handles a post is kept as mentioning: each a whole `@name@host` a mention can be
    /// written as, once, in the order the source listed them, and no more than `maxMentions`.
    /// Whatever else a source listed is nobody a press could open.
    static func bounded(_ handles: [String]) -> [String] {
        var seen: Set<String> = []
        var kept: [String] = []
        for handle in handles {
            if kept.count == maxMentions { break }
            if parts(of: handle) != nil, seen.insert(handle.lowercased()).inserted { kept.append(handle) }
        }
        return kept
    }

    /// The mentions in a post's words, in the order they were written.
    static func found(in text: String, among handles: [String]) -> [PostMention] {
        spans(in: text, among: handles).map(\.mention)
    }

    /// Where each mention sits in the words, and who it is.
    ///
    /// **Written whole, a mention is whoever was listed by exactly that handle.** `@ada@two.example`
    /// is never read as the `@ada` of another server.
    ///
    /// **Written by the name alone, it is the one person listed under that name.** That is how a
    /// source spells a mention in the words it sends. Two people listed under one name on two
    /// servers are both written `@ada`, and nothing in the words says which is which — so neither
    /// is a mention, rather than one of them by a guess.
    ///
    /// Compared without regard to case, as the servers this app reads compare a handle.
    ///
    /// **A `.` is written inside a name, so one that touches a mention hides it**: `Hi.@ada` and
    /// `@ada.Thanks` stay letters. Nothing is cut out of a longer word to find somebody in it.
    internal static func spans(
        in text: String, among handles: [String]
    ) -> [(range: Range<String.Index>, mention: PostMention)] {
        // No list, or no `@` — ASCII, so a byte scan finds it: the common case, and no walk.
        guard !handles.isEmpty, text.utf8.contains(UInt8(ascii: "@")) else { return [] }
        var whole: [String: String] = [:]
        var named: [String: [String]] = [:]
        for handle in handles {
            guard let parts = parts(of: handle) else { continue }
            whole[handle.lowercased()] = handle
            named[parts.name.lowercased(), default: []].append(handle)
        }

        var found: [(range: Range<String.Index>, mention: PostMention)] = []
        var index = text.startIndex
        while index < text.endIndex, found.count < maxMentions {
            guard text[index] == "@", opensAWord(text, at: index) else {
                index = text.index(after: index)
                continue
            }
            let nameStart = text.index(after: index)
            let nameEnd = end(of: text, from: nameStart)
            var end = trimmed(text, from: nameStart, to: nameEnd)
            guard end > nameStart else {
                index = nameStart
                continue
            }
            var listed = named[text[nameStart ..< end].lowercased()]
            // A server's name straight after the name: the mention is written whole.
            if end == nameEnd, end < text.endIndex, text[end] == "@" {
                let hostStart = text.index(after: end)
                let hostEnd = trimmed(text, from: hostStart, to: self.end(of: text, from: hostStart))
                if hostEnd > hostStart {
                    end = hostEnd
                    listed = whole[text[index ..< end].lowercased()].map { [$0] }
                }
            }
            if let listed, listed.count == 1 {
                found.append((index ..< end, PostMention(text: String(text[index ..< end]), handle: listed[0])))
            }
            index = end
        }
        return found
    }

    /// The name and the server of a whole handle, or nothing where it is not one: an `@`, a name
    /// a mention can be written with, an `@`, and a server's name.
    private static func parts(of handle: String) -> (name: Substring, host: Substring)? {
        guard handle.first == "@", handle.unicodeScalars.count <= handleLength else { return nil }
        let parts = handle.dropFirst().split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(isHandleCharacter), isHostName(parts[1])
        else { return nil }
        return (parts[0], parts[1])
    }

    /// Whether `host` is spelled as a server's name is: letters of any script, digits, `.` and
    /// `-`, and a port after one `:` where it has one. **Nothing else**: a `/`, a `?`, a `#` or
    /// a `+` is where an address goes on, and a handle is nobody's address.
    private static func isHostName(_ host: Substring) -> Bool {
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { return false }
        return parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy { $0.isASCII && $0.isNumber })
    }

    /// Whether an `@` at `index` starts a mention rather than sitting inside a word, an address
    /// or another handle. **ASCII only**, for `PostLink.opensAWord`'s reason: `請看@ada` is how a
    /// post in this app's second language names somebody, with no space before them.
    private static func opensAWord(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        return !(isHandleCharacter(before) || before == "@" || before == "/" || before == "=")
    }

    /// Where a name, or a server's name, stops: the first character neither is written with.
    private static func end(of text: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex, isHandleCharacter(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    /// The sentence's punctuation handed back to the sentence: a `.` or a `-` is written inside
    /// a name and a server's name, and never ends one.
    private static func trimmed(_ text: String, from start: String.Index, to end: String.Index) -> String.Index {
        var end = end
        while end > start, ".-".contains(text[text.index(before: end)]) {
            end = text.index(before: end)
        }
        return end
    }

    private static func isHandleCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
    }
}
