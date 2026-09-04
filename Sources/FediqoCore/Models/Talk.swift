import Foundation

/// A conversation you are in (#109).
///
/// **Not a timeline, and this type exists to say so.** `/api/v1/conversations` does not answer
/// with posts. It answers with conversations: an id, the accounts taking part, whether it is
/// unread, and the last status in it. A timeline is a stretch of time made of posts; this is a
/// set of threads made of people, and what a reader wants from it is *who is talking to me and
/// what was said last* — a different question from *what happened, newest first*.
///
/// Forcing it into a timeline would mean drawing the last post of each and calling that a
/// stream. Paging down would not be going back in time, the ring would land on posts whose
/// conversation it could not say, and a reply would appear in two places at once.
public struct Talk: Sendable, Hashable, Identifiable {
    /// The server's own id for the conversation, which is what marking it read names.
    public let id: String
    /// The server it is held on. A conversation belongs to one account on one server: there is
    /// no merging these across servers, because two servers' conversations are two
    /// conversations even where the same people are in both.
    public let host: String
    /// Who is in it besides the reader, as the server listed them.
    public let people: [Profile]
    /// What was said last, or nothing where the server sent no status — a conversation whose
    /// last post has been deleted is still a conversation.
    public let last: Post?
    /// Whether the reader has read it. **The server's answer and not this app's guess**: read
    /// is a fact about an account rather than about a device, and a reader who read it on their
    /// phone has read it.
    public let unread: Bool

    public init(id: String, host: String, people: [Profile], last: Post?, unread: Bool) {
        self.id = id
        self.host = host
        self.people = people
        self.last = last
        self.unread = unread
    }
}
