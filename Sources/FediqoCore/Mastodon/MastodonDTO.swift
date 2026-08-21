import Foundation

/// The slice of Mastodon's API this build reads. Anything not needed to draw a row is left
/// out, and the decoder converts snake_case, so nothing here spells a key twice.
enum MastodonDTO {
    struct Status: Decodable, Sendable {
        let uri: String
        let url: String?
        let createdAt: Date
        let content: String
        let account: Account
        let mediaAttachments: [MediaAttachment]
        let reblog: Box<Status>?
    }

    struct Account: Decodable, Sendable {
        let username: String
        let acct: String
        let displayName: String
        let avatar: String?

        var name: String { displayName.isEmpty ? username : displayName }

        /// Local accounts come back as `alice`; remote ones already carry their server.
        func handle(on host: String) -> String {
            acct.contains("@") ? "@\(acct)" : "@\(acct)@\(host)"
        }
    }

    struct MediaAttachment: Decodable, Sendable {
        let url: String?
        let previewUrl: String?
    }

    /// `/api/v2/instance` and `/api/v1/instance` disagree on names; both are read into this.
    struct Instance: Decodable, Sendable {
        let title: String?
        let description: String?
        let shortDescription: String?
    }

    /// `reblog` nests a `Status` inside itself; a class box keeps the type finite.
    final class Box<Wrapped: Decodable & Sendable>: Decodable, Sendable {
        let value: Wrapped
        init(from decoder: any Decoder) throws {
            value = try Wrapped(from: decoder)
        }
    }
}

extension MastodonDTO.Status {
    /// Flattens a status — boost or not — into the one shape the timeline knows.
    ///
    /// A boost keeps the original's identity and words, but takes its own timestamp: the row
    /// says "X boosted Y", and when that happened is when X boosted, not when Y wrote.
    func asPost(from host: String) -> Post {
        let subject = reblog?.value ?? self
        return Post(
            uri: subject.uri,
            createdAt: createdAt,
            authorName: subject.account.name,
            authorHandle: subject.account.handle(on: host),
            authorAvatarURL: subject.account.avatar.flatMap(URL.init(string:)),
            text: HTMLText.plain(subject.content),
            mediaURLs: subject.mediaAttachments.compactMap { attachment in
                (attachment.previewUrl ?? attachment.url).flatMap(URL.init(string:))
            },
            webURL: subject.url.flatMap(URL.init(string:)),
            boostedBy: reblog == nil ? nil : account.name,
            sources: [host]
        )
    }
}
