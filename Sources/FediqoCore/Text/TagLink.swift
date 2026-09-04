import Foundation

/// How a hashtag in a post's words is handed from the line it is in to the app around it (#107).
///
/// **A URL, because a `Text` can only carry one.** A pressable run inside a line of prose is an
/// `AttributedString` with a `.link` on it — that is the one way SwiftUI offers to put something
/// pressable inside a line and have the line still wrap, still be selected, and still be read as
/// a sentence. So the tag is spelled as an address, and the shell recognises its own and never
/// lets one reach a browser.
///
/// The scheme is this app's own and is registered nowhere: nothing outside this process can be
/// handed one, and nothing inside it opens one except the shell.
public enum TagLink {
    public static let scheme = "fediqo-tag"

    /// The address for a tag, which arrives normalised the way the store keeps one.
    public static func url(for tag: String) -> URL? {
        guard let escaped = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              !escaped.isEmpty
        else { return nil }
        return URL(string: "\(scheme):\(escaped)")
    }

    /// The tag an address names, or nothing where it is somebody else's address.
    ///
    /// Nothing is what a browser gets handed: the shell asks this first, and only an address it
    /// does not recognise goes out of the app.
    public static func tag(in url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let name = url.absoluteString.dropFirst(scheme.count + 1)
        return name.removingPercentEncoding.flatMap { Post.normalisedTags([$0]).first }
    }
}
