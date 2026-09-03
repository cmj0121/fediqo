import Foundation

/// Who a reply opens with (#97).
///
/// Replying to somebody should start with them in it. Mastodon's convention carries everyone the
/// post itself named as well, which is right in a thread of three and wrong in a thread of thirty
/// — a reader who says one sentence to one person and pulls eleven others into it has said
/// something to eleven people they did not mean to speak to. So it is the reader's to choose,
/// once, for the app.
public enum CarriedMentions: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The draft opens empty, and handles are typed by hand.
    case nobody
    /// The person being answered, and nobody else. The default: it is the one mention a reply
    /// cannot be without, and it is the one nobody is surprised by.
    case replied
    /// Everyone the post named, with the person being answered first and the rest at the tail.
    case everyone

    public var id: String { rawValue }
}

public extension CarriedMentions {
    /// What a reply to `parent` opens with, for a reader acting as `me`.
    ///
    /// `me` is the acting account's `authorId` rather than its handle, because that is the thing
    /// both ends of the comparison actually have: a mention carries the account's URI, and a
    /// handle is spelled by whichever server is doing the spelling. **The reader is never carried
    /// into their own reply** — a draft that opens by addressing yourself is a draft you have to
    /// edit before you can write in it.
    ///
    /// Nobody appears twice, however many times the post named them. `Mention.folded` already
    /// does that for the post's own list; this has to do it again because the person being
    /// answered is usually in that list too.
    func opening(answering parent: Post, as me: String?) -> String {
        let handles = carried(answering: parent, as: me)
        return handles.isEmpty ? "" : handles.joined(separator: " ") + " "
    }

    /// The handles themselves, in the order they will be written.
    func carried(answering parent: Post, as me: String?) -> [String] {
        guard self != .nobody else { return [] }

        var seen: Set<String> = []
        if let me { seen.insert(me) }

        var handles: [String] = []
        // The person being answered, first. Where the reader is answering themselves there is
        // nobody to name, and the rest — where there is a rest — still follows.
        if seen.insert(parent.authorId).inserted, !parent.authorHandle.isEmpty {
            handles.append(parent.authorHandle)
        }
        guard self == .everyone else { return handles }

        for mention in parent.mentions where seen.insert(mention.uri).inserted {
            guard !mention.handle.isEmpty else { continue }
            handles.append(mention.handle)
        }
        return handles
    }
}
