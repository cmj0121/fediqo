import Foundation

/// A list the reader made on their own server (#114).
///
/// **Not a timeline this app can read yet.** `/api/v1/timelines/list/:id` is #103's table and is
/// not built; this is the half #114 asks for — a subscription you can *see*, so that a list made
/// two years ago on a website is not a thing only that website knows about.
public struct ServerList: Sendable, Hashable, Identifiable {
    /// The server's own id for it, which is what reading it would name.
    public let id: String
    public let title: String
    /// Which server keeps it. A reader signed in to three has three sets of lists, and they are
    /// not one set.
    public let host: String

    public init(id: String, title: String, host: String) {
        self.id = id
        self.title = title
        self.host = host
    }
}
