import Foundation

/// The handle somebody is part-way through typing (#98).
///
/// A handle is `@name@host`, and one typed wrong is a reply that reaches nobody — the server
/// takes it as words. So the composer offers who it could be while it is being typed.
///
/// **It follows the end of the draft rather than the caret.** SwiftUI does not hand a text editor's
/// caret over, and guessing at one would be worse than not having it: an offer attached to the
/// wrong place in a draft would replace words somebody had already written. The end of the text is
/// where typing happens, it is a place this can be certain of, and editing in the middle simply
/// offers nothing — which is the honest answer rather than a wrong one.
public struct MentionQuery: Equatable, Sendable {
    /// What to ask the server, without the `@`.
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
        guard token.first == "@" else { return nil }

        let typed = String(token.dropFirst())
        // `@name@` and `@name@ho` are both somebody being typed; what is not is a token with
        // nothing after the `@` yet, or one so short that asking is asking about everybody.
        guard typed.count >= shortest else { return nil }
        return MentionQuery(text: typed, range: start..<draft.endIndex)
    }

    /// The draft with this query replaced by `handle`, and a space after it so the reader can
    /// carry on writing.
    public func accepting(_ handle: String, in draft: String) -> String {
        draft.replacingCharacters(in: range, with: handle + " ")
    }
}
