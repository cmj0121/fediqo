import Foundation

/// The handle or hashtag somebody is part-way through typing (#98, #108).
///
/// A handle is `@name@host`, and one typed wrong is a reply that reaches nobody — the server
/// takes it as words. A hashtag typed wrong is a post nobody finds, which is quieter and just
/// as final. So the composer offers what it could be while it is being typed.
///
/// **One finder and not two.** The two tokens differ in their first character and in what is
/// asked about them, and in nothing else — where the token starts and ends, how much has to be
/// typed first, what a chosen answer replaces. A second copy of this for hashtags would agree
/// with it on the day it was written and drift from then on.
///
/// **It follows the end of the draft rather than the caret.** SwiftUI does not hand a text editor's
/// caret over, and guessing at one would be worse than not having it: an offer attached to the
/// wrong place in a draft would replace words somebody had already written. The end of the text is
/// where typing happens, it is a place this can be certain of, and editing in the middle simply
/// offers nothing — which is the honest answer rather than a wrong one.
public struct MentionQuery: Equatable, Sendable {
    /// Which of the two is being typed.
    public enum Kind: Equatable, Sendable {
        /// `@name@host` — somebody to name.
        case handle
        /// `#tag` — something to file the post under.
        case tag

        /// The character that starts one. `＃` is a hash too, and it is what a Japanese or
        /// Chinese keyboard types without leaving the input mode the rest of the draft is in.
        static func of(_ character: Character) -> Kind? {
            switch character {
            case "@": .handle
            case "#", "＃": .tag
            default: nil
            }
        }
    }

    public let kind: Kind
    /// What to ask the server, without the `@` or the `#`.
    public let text: String
    /// The part of the draft an answer replaces — the whole token, `@` and all.
    public let range: Range<String.Index>

    /// How much has to be typed before anybody is asked.
    ///
    /// Two, not one. A bare `@` is the start of every handle there is and a server asked about it
    /// would answer with whoever it happened to list first; one letter is barely narrower. This is
    /// the "nothing is asked before there is something to ask about" line, and it is drawn here.
    public static let shortest = 2

    /// The handle being typed at the end of `draft`, or nothing.
    ///
    /// Nothing where the draft ends in a space — the token is finished and the reader has moved
    /// on — and nothing where the last token is not a handle at all.
    public static func trailing(in draft: String) -> MentionQuery? {
        guard let last = draft.last, !last.isWhitespace else { return nil }

        let start = draft.lastIndex(where: \.isWhitespace).map(draft.index(after:))
            ?? draft.startIndex
        let token = draft[start...]
        guard let first = token.first, let kind = Kind.of(first) else { return nil }

        let typed = String(token.dropFirst())
        // `@name@` and `@name@ho` are both somebody being typed; what is not is a token with
        // nothing after the mark yet, or one so short that asking is asking about everybody.
        guard typed.count >= shortest else { return nil }
        return MentionQuery(kind: kind, text: typed, range: start..<draft.endIndex)
    }

    /// The draft with this query replaced by `answer`, and a space after it so the reader can
    /// carry on writing.
    ///
    /// The answer arrives written the way it goes into a post — `@name@host` or `#tag` — so this
    /// puts back what it is given rather than deciding what a handle or a hashtag looks like in
    /// two places.
    public func accepting(_ answer: String, in draft: String) -> String {
        draft.replacingCharacters(in: range, with: answer + " ")
    }
}
