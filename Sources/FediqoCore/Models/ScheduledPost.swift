import Foundation

/// A post that has not happened yet (#110).
///
/// **Not a `Post`, and that is the whole of why this type exists.** `/api/v1/scheduled_statuses`
/// answers with what a post *will be* — its parameters and when — rather than with a status. It
/// has no address, no counts, nobody has replied to it, and it can still be cancelled. Drawn as
/// an ordinary row it would be a post that answers none of the questions a row asks, which is
/// the shape lying.
///
/// So it is its own short list, in the order the posts will go out, saying when. What can be
/// done to one is cancel it; everything a row offers is meaningless on a post that has not
/// happened.
public struct ScheduledPost: Sendable, Hashable, Identifiable {
    /// The server's own number for it, which is what a cancellation names.
    public let id: String
    /// The server it will go out from, so a reader with several accounts can tell which of them
    /// is about to say this.
    public let host: String
    /// What it will say.
    public let text: String
    /// When it goes.
    public let when: Date
    /// Who it will go to, where the server said. Nil is not "everyone" — it is the server not
    /// having said, and a row that guessed would be inventing the one fact about a post that
    /// cannot be taken back.
    public let audience: Audience?
    /// How many things are attached. The count and not the pictures: nothing here has been
    /// fetched, and a row saying "2 attachments" is true where a thumbnail would be a request.
    public let attachments: Int

    public init(id: String, host: String, text: String, when: Date,
                audience: Audience? = nil, attachments: Int = 0) {
        self.id = id
        self.host = host
        self.text = text
        self.when = when
        self.audience = audience
        self.attachments = attachments
    }
}
