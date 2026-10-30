import Foundation

/// The tabs of somebody's page, in the order they stand: what their source says of them and
/// how the reader stands to them, whom they follow, who follows them, what they pinned, and
/// their posts.
///
/// **Which of them a page has is not said here**: it is decided where the source is asked
/// (`ShellPersonTabs.tabs`) and handed down, and a tab a page has not is absent — never grey.
/// Selection is not held here either: it lives with the pages, by who they are.
enum PersonTab: String, ShellTab, CaseIterable, Sendable {
    case about, following, followers, pinned, posts

    var id: String { rawValue }

    var titleKey: String { "person.tab.\(rawValue)" }

    var symbol: String {
        switch self {
        case .about: "person.text.rectangle"
        case .following: "star"
        case .followers: "eye"
        case .pinned: "pin"
        case .posts: "doc.text"
        }
    }

    /// Which list of people the tab is, where it is one.
    var list: PeopleList.Which? {
        switch self {
        case .following: .following
        case .followers: .followers
        case .about, .pinned, .posts: nil
        }
    }

    /// Whether the tab's rows are posts: what a mark's key acts on, and what Return opens as
    /// a conversation.
    var listsPosts: Bool { self == .posts || self == .pinned }
}
