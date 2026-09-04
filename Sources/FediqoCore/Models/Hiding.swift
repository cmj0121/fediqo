import Foundation

/// The three ways a server hides something on the reader's behalf (#114).
///
/// **Three and not one**, because they are three different acts with three different reaches:
/// muting somebody hides them from you and they never know; blocking them severs what you can
/// see of each other and they are told by the shape of it; blocking a domain severs your
/// server's relationship with a whole place.
///
/// This app can enter only the third and the first — and until #114 it could leave neither,
/// because it kept its own record of what it had asked for and never asked the server what was
/// actually standing. A mute made on a phone was a mute this app had never heard of.
public enum Hiding: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Accounts you muted — `/api/v1/mutes`.
    case muted
    /// Accounts you blocked — `/api/v1/blocks`.
    case blocked
    /// Servers you blocked — `/api/v1/domain_blocks`.
    case blockedServers

    public var id: String { rawValue }

    /// What Mastodon calls the list. Said here so a screen naming it and a request asking for it
    /// cannot come to disagree.
    public var path: String {
        switch self {
        case .muted: "mutes"
        case .blocked: "blocks"
        case .blockedServers: "domain_blocks"
        }
    }

    /// Whether the list is of people or of places. The row differs; the screen does not.
    public var isAboutPeople: Bool { self != .blockedServers }
}

extension Hidden {
    /// One thing on one of those lists: somebody, or somewhere.
    ///
    /// A profile where the server sent one and a bare name where the list is of domains — the
    /// two are drawn differently and undone by the same press, so they are one type with the
    /// difference in it rather than two lists to keep in step.
    public enum Subject: Sendable, Hashable, Identifiable {
        case person(Profile)
        case server(String)

        public var id: String {
            switch self {
            case .person(let profile): profile.authorId
            case .server(let host): host
            }
        }

        /// What a reader would call it.
        public var name: String {
            switch self {
            case .person(let profile): profile.name.isEmpty ? profile.handle : profile.name
            case .server(let host): host
            }
        }

        /// The custom emoji their name is partly written in, where it is somebody. A name is
        /// not prose and is drawn with `EmojiText`'s plain init (#119), but it is still a name
        /// that can contain pictures.
        public var emojis: [CustomEmoji] {
            switch self {
            case .person(let profile): profile.emojis
            case .server: []
            }
        }

        /// The line under it, where there is one to draw.
        public var detail: String? {
            switch self {
            case .person(let profile): profile.handle
            case .server: nil
            }
        }
    }
}
