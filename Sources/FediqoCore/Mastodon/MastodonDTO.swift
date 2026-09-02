import Foundation

/// The slice of Mastodon's API this build reads. Anything not needed to draw a row or to
/// keep one is left out, and the decoder converts snake_case, so nothing here spells a key
/// twice.
enum MastodonDTO {
    struct Status: Decodable, Sendable {
        let id: String
        let uri: String
        let url: String?
        let createdAt: Date
        let content: String
        let account: Account
        let mediaAttachments: [MediaAttachment]
        let reblog: Box<Status>?
        let inReplyToId: String?
        /// Absent on the odd server; one strange status must never fail the whole page.
        let tags: [Tag]?
        /// Who the status names. Absent on the odd server, for the same reason as `tags`.
        let mentions: [Mention]?
        /// Whether the attachments arrive covered, and the line standing in front of the
        /// words. Optional because a server that does not send them has told us nothing,
        /// which is a different thing from telling us there is nothing.
        let sensitive: Bool?
        let spoilerText: String?
        /// Who it was written for, as the wire spells it. A word this build does not know is
        /// left as `nil` by `Visibility(rawValue:)` rather than failing the status: one strange
        /// value must never cost the reader a post.
        let visibility: String?
        let repliesCount: Int?
        let reblogsCount: Int?
        let favouritesCount: Int?
        /// What it was written with. Sent for statuses this server hosts and left out for
        /// everything it received from somewhere else, which is most of a timeline.
        let application: Application?
        /// The custom emoji the words are partly written in. Absent on the odd server, for the
        /// same reason as `tags`.
        let emojis: [Emoji]?
        /// What the server made of the one link in the post, having fetched the Open Graph
        /// tags itself. Absent on a post with no link, and on a server that has not got round
        /// to reading one yet — both of which are simply no card.
        let card: Card?
    }

    /// One custom emoji: the name between the colons, and the picture it stands for. A row
    /// with no address behind it is dropped rather than kept as a shortcode pointing nowhere.
    struct Emoji: Decodable, Sendable {
        let shortcode: String
        let url: String?
        let staticUrl: String?

        var asEmoji: CustomEmoji? {
            guard !shortcode.isEmpty, let address = url.flatMap(URL.init(string:)) else { return nil }
            return CustomEmoji(shortcode: shortcode, url: address,
                               staticURL: staticUrl.flatMap(URL.init(string:)))
        }
    }

    struct Application: Decodable, Sendable {
        let name: String
        let website: String?

        var asApplication: FediqoCore.Application? {
            name.isEmpty ? nil : FediqoCore.Application(name: name, website: website.flatMap(URL.init(string:)))
        }
    }

    /// One account a status names. `url` is the actor URI — the same name the account itself
    /// is keyed by — and `acct` is how this server spells the handle.
    struct Mention: Decodable, Sendable {
        let url: String?
        let username: String
        let acct: String

        func asMention(on host: String) -> FediqoCore.Mention? {
            let uri = url ?? Account(id: "", url: nil, username: username, acct: acct,
                                     displayName: "", avatar: nil, emojis: nil, note: nil,
                                     statusesCount: nil, followersCount: nil, followingCount: nil,
                                     createdAt: nil, locked: nil).authorId(on: host)
            let handle = acct.contains("@") ? "@\(acct)" : "@\(acct)@\(host)"
            return uri.isEmpty ? nil : FediqoCore.Mention(uri: uri, handle: handle)
        }
    }

    struct Account: Decodable, Sendable {
        let id: String
        /// The actor URI — the one name for an account that survives a rename.
        let url: String?
        let username: String
        let acct: String
        let displayName: String
        let avatar: String?
        /// The custom emoji the display name is partly written in.
        let emojis: [Emoji]?
        /// What a profile carries and a status's copy of an account does not. All optional,
        /// because a status carries the same shape with these left out and the one decoder
        /// reads both — a missing count is a server that did not say, which `Profile` keeps
        /// apart from a zero.
        let note: String?
        let statusesCount: Int?
        let followersCount: Int?
        let followingCount: Int?
        let createdAt: Date?
        let locked: Bool?

        var name: String { displayName.isEmpty ? username : displayName }

        /// Local accounts come back as `alice`; remote ones already carry their server.
        func handle(on host: String) -> String {
            acct.contains("@") ? "@\(acct)" : "@\(acct)@\(host)"
        }

        /// The id the store keys on. A server that sends no actor URI still told us where
        /// the account lives, so the profile address on that server stands in — stable
        /// enough to key on, and never the bare handle.
        func authorId(on host: String) -> String {
            if let url { return url }
            let parts = acct.split(separator: "@", maxSplits: 1)
            let domain = parts.count == 2 ? String(parts[1]) : host
            return "https://\(domain)/@\(parts[0])"
        }
    }

    struct Tag: Decodable, Sendable {
        let name: String
    }

    /// A link, as the server read it. `image` is on that server's own storage rather than on
    /// the site being linked to, which is the whole reason a card costs no new host.
    ///
    /// `type` is `link`, `photo`, `video` or `rich`, and it is not read: this app draws a card
    /// and never an embed, so a video card is a link with a picture on it like any other. An
    /// embed is somebody else's HTML running in the reader's app, which is not a thing this
    /// app does.
    struct Card: Decodable, Sendable {
        let url: String
        let title: String?
        let description: String?
        let providerName: String?
        let image: String?
        let imageDescription: String?

        /// The card this is, or nothing where there is no address to point at — which is not a
        /// card, whatever else the payload carried.
        var asCard: FediqoCore.Card? {
            guard let address = URL(string: url) else { return nil }
            return FediqoCore.Card(
                url: address,
                title: title ?? "",
                summary: description ?? "",
                provider: providerName ?? "",
                imageURL: image.flatMap(URL.init(string:)),
                imageAlt: imageDescription ?? ""
            )
        }
    }

    /// What came attached. `type` is Mastodon's word for what it is — `image`, `gifv`,
    /// `video`, `audio`, or `unknown` for anything it could not classify — and it is kept
    /// rather than guessed at, because the file's address rarely says.
    struct MediaAttachment: Decodable, Sendable {
        let type: String?
        let url: String?
        let previewUrl: String?
        /// What the author wrote for somebody who cannot see it.
        let description: String?

        var asAttachment: Attachment? {
            let attachment = Attachment(kind: Self.kind(of: type),
                                        url: url.flatMap(URL.init(string:)),
                                        previewURL: previewUrl.flatMap(URL.init(string:)),
                                        alt: description ?? "")
            return attachment.isEmpty ? nil : attachment
        }

        /// A looping soundless video is a video, whatever it is called; anything this build
        /// has no name for is `unknown`, which is a truthful answer and not a failure.
        private static func kind(of type: String?) -> Attachment.Kind {
            switch type {
            case "image": .image
            case "video", "gifv": .video
            case "audio": .audio
            default: .unknown
            }
        }
    }

    /// What `/api/v1/statuses/:id/context` answers: the chain above a post and everything
    /// under it, each already in the order that server reads them in.
    struct Context: Decodable, Sendable {
        let ancestors: [Status]
        let descendants: [Status]
    }

    /// `/api/v2/instance` and `/api/v1/instance` disagree on names; both are read into this.
    struct Instance: Decodable, Sendable {
        let title: String?
        let description: String?
        let shortDescription: String?
        let languages: [String]?
        let thumbnail: Thumbnail?
        let version: String?
        /// The server's own house rules, in the order it lists them. v1 servers old enough to
        /// keep these behind a second request simply answer nothing here, and nothing is what
        /// the card then shows: this screen makes one request and is not about to make two.
        let rules: [Rule]?
        let registrations: Registrations?
        /// v2's figures.
        let usage: Usage?
        /// v1's, under a different name and counting different things.
        let stats: Stats?
        /// What the server will take. v2 keeps it here; v1 keeps it at the top level under
        /// `max_toot_chars`, which some forks send and Mastodon itself does not.
        let configuration: Configuration?
        let maxTootChars: Int?

        struct Configuration: Decodable, Sendable {
            struct Statuses: Decodable, Sendable { let maxCharacters: Int? }
            let statuses: Statuses?
        }

        /// v2 hands back an object with the picture inside it and v1 the address on its own.
        /// Either way it is one URL, so the difference stops here.
        struct Thumbnail: Decodable, Sendable {
            let url: String?

            private struct Object: Decodable { let url: String? }

            init(from decoder: any Decoder) throws {
                if let address = try? decoder.singleValueContainer().decode(String.self) {
                    url = address
                } else {
                    url = try? Object(from: decoder).url
                }
            }
        }

        struct Rule: Decodable, Sendable {
            let text: String?
            let hint: String?
        }

        /// v2 answers with a dictionary that distinguishes closed from closed-pending-approval;
        /// v1 answers with a bare yes or no. Only the yes or no is common to both.
        struct Registrations: Decodable, Sendable {
            let enabled: Bool?
            let approvalRequired: Bool?

            private struct Object: Decodable {
                let enabled: Bool?
                let approvalRequired: Bool?
            }

            init(from decoder: any Decoder) throws {
                if let flag = try? decoder.singleValueContainer().decode(Bool.self) {
                    enabled = flag
                    approvalRequired = nil
                } else {
                    let object = try? Object(from: decoder)
                    enabled = object?.enabled
                    approvalRequired = object?.approvalRequired
                }
            }
        }

        /// A month is the shortest window Mastodon publishes. There is no daily figure to ask
        /// for, here or anywhere else in the API.
        struct Usage: Decodable, Sendable {
            struct Users: Decodable, Sendable { let activeMonth: Int? }
            let users: Users?
        }

        struct Stats: Decodable, Sendable {
            let userCount: Int?
            let statusCount: Int?
        }
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
    ///
    /// Mastodon's `uri` is already the canonical id, so it is the origin. The address we
    /// were handed is this host's local number for the row — the boost's own for a boost —
    /// so a reply's `inReplyToURI`, built the same way from `in_reply_to_id`, is the `uri`
    /// of some row on this host and a thread is a join on it.
    func asPost(from host: String) -> Post {
        let subject = reblog?.value ?? self
        return Post(
            uri: "https://\(host)/api/v1/statuses/\(id)",
            originURI: subject.uri,
            socialProtocol: .mastodon,
            sourceURL: "https://\(host)",
            createdAt: createdAt,
            authorId: subject.account.authorId(on: host),
            authorName: subject.account.name,
            authorHandle: subject.account.handle(on: host),
            authorAvatarURL: subject.account.avatar.flatMap(URL.init(string:)),
            text: HTMLText.plain(subject.content),
            attachments: subject.mediaAttachments.compactMap(\.asAttachment),
            sensitive: subject.sensitive,
            spoiler: subject.spoilerText,
            // The subject's and not the wrapper's: the row draws the post that was written,
            // and who it was written for is a fact about that post. A boost cannot widen an
            // audience -- Mastodon will not let one be made of anything but a public or
            // unlisted status -- so the wrapper has nothing to add here.
            audience: subject.visibility.flatMap(Audience.init(rawValue:)),
            counts: Counts(replies: subject.repliesCount, reblogs: subject.reblogsCount,
                           favourites: subject.favouritesCount),
            application: subject.application?.asApplication,
            webURL: subject.url.flatMap(URL.init(string:)),
            inReplyToURI: subject.inReplyToId.map { "https://\(host)/api/v1/statuses/\($0)" },
            tags: (subject.tags ?? []).map(\.name),
            mentions: (subject.mentions ?? []).compactMap { $0.asMention(on: host) },
            // The words' own emoji first, then the author's: where a server spells one
            // shortcode two ways, what the post says wins over what the name does.
            emojis: ((subject.emojis ?? []) + (subject.account.emojis ?? [])).compactMap(\.asEmoji),
            // The boost's own card is the boosted post's, because a boost has no words of its
            // own to have put a link in — `subject` is already whichever of the two carries the
            // post, and the card follows it.
            card: subject.card?.asCard,
            boostedBy: reblog == nil ? nil : account.name,
            boostedById: reblog == nil ? nil : account.authorId(on: host),
            sources: [host]
        )
    }
}

extension MastodonDTO {
    /// One event the server says was aimed at the account asking.
    ///
    /// `status` is absent for a follow and present for everything else, which is the same
    /// shape `Notice` has — a follow is about a person, and there is nothing to quote.
    struct Notification: Decodable, Sendable {
        let id: String
        let type: String
        let createdAt: Date
        let account: Account
        let status: Status?

        /// The notice this is, or nothing where it is a kind this build cannot draw.
        ///
        /// Mastodon sends more than the six `NoticeKind` has. `follow_request` is a decision
        /// to be made rather than an event that happened; `admin.sign_up` and `admin.report`
        /// belong to a moderation console this app is not; `severed_relationships` and
        /// `moderation_warning` are a server talking about itself; `status` is somebody the
        /// reader asked to be told about posting, which is a subscription this build has no
        /// way to make and so can never receive. Each is dropped here rather than stored as a
        /// kind with no row to draw it — a screen that cannot say what happened should show
        /// nothing, never a blank line.
        ///
        /// `arrivedAt` is passed in rather than taken here, because it is a fact about this
        /// device and not about the payload: a catch-up read hands it the moment the page
        /// landed, and every notice in that page shares it.
        func asNotice(from host: String, owner: String, arrivedAt: Date) -> Notice? {
            guard let kind = Self.kind(of: type) else { return nil }
            return Notice(
                remoteId: id,
                serverURL: "https://\(host)",
                kind: kind,
                ownerId: owner,
                actorId: account.authorId(on: host),
                actorName: account.name,
                actorHandle: account.handle(on: host),
                actorAvatarURL: account.avatar.flatMap(URL.init(string:)),
                post: status?.asPost(from: host),
                noticedAt: createdAt,
                arrivedAt: arrivedAt
            )
        }

        /// Mastodon's word for the event, as one of ours. `reblog` is the only one spelled
        /// differently on the two sides: this app says boost everywhere a reader can see, so
        /// it says boost here too, and the translation happens once, at the edge.
        static func kind(of type: String) -> NoticeKind? {
            switch type {
            case "mention": .mention
            case "favourite": .favourite
            case "reblog": .boost
            case "follow": .follow
            case "poll": .poll
            case "update": .update
            default: nil
            }
        }
    }
}
