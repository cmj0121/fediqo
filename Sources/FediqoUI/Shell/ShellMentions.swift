import FediqoCore
import SwiftUI

// Somebody mentioned in a post's words, pressed (#310): their page, one more step of the walk —
// the page a face or a name on a row opens, asked of the source the words were read through by
// the handle it listed them under. Somebody this device never met is asked for the same way.

/// Where a press on a mention in a post's words goes: the root's walk, handed down once as
/// `ShellTags` is, and for its reason.
///
/// **Nothing, and somebody mentioned stays the letters they were written with.** Outside the
/// shell there is no page for them to open, so they are neither inked nor pressable.
@MainActor
final class ShellMentions {
    /// The walk's own answer to a press: whether a page was opened. Set by the root.
    var placing: (@MainActor (_ handle: String, _ host: String, _ row: String?) -> Bool)?

    /// Somebody mentioned by `handle` in words read through `host`, pressed on the row `row` —
    /// or in words that stand on no row.
    @discardableResult
    func press(_ handle: String, at host: String, from row: String?) -> Bool {
        placing?(handle, host, row) ?? false
    }

    /// The address a mention's letters carry, so a press on them reaches `openURL` as a link's
    /// does. Never a way out of the app: `ProseLinks` answers it before anything else sees it.
    static func url(for handle: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "person"
        components.path = "/" + handle
        return components.url
    }

    /// The handle an address pressed in a line stands for, or nothing where it is an address.
    static func handle(in url: URL) -> String? {
        guard url.scheme == scheme, url.host == "person" else { return nil }
        let handle = String(url.path.dropFirst())
        return handle.isEmpty ? nil : handle
    }

    /// Who a pressed address names among the people this line mentions, or nobody: the address
    /// is this app's own, and one that names somebody the line does not opens nobody.
    static func listed(in url: URL, among mentions: [PostMention]) -> String? {
        handle(in: url).flatMap { handle in mentions.first { $0.handle == handle }?.handle }
    }

    /// The answer to an address pressed in a line read through `source`, standing on `row`:
    /// whether somebody's page was opened — asked of `source`, the line's own — or nothing where
    /// the address is not a mention's.
    static func answer(
        _ url: URL, among mentions: [PostMention], at source: String, from row: String?, by pressing: ShellMentions?
    ) -> Bool? {
        guard handle(in: url) != nil else { return nil }
        guard let handle = listed(in: url, among: mentions) else { return false }
        return pressing?.press(handle, at: source, from: row) ?? false
    }

    private static let scheme = "fediqo-mention"
}

extension EnvironmentValues {
    /// See `ShellMentions`.
    @Entry var shellMentions: ShellMentions?
}

/// The people a line of words mentions, offered to VoiceOver as actions on the element the
/// reader lands on, each named by their whole handle — the press a finger makes on the name,
/// for a reader who makes none (#310). `TagWays`' reason, for a person.
struct MentionWays: View {
    let mentions: [PostMention]
    let pressing: ShellMentions?
    /// The source the words were read through, which the person is asked of.
    let source: String
    let row: String?

    var body: some View {
        if let pressing {
            ForEach(Self.handles(in: mentions), id: \.self) { handle in
                Button(Self.name(of: handle)) {
                    pressing.press(handle, at: source, from: row)
                }
            }
        }
    }

    /// What the action is called: the press, naming them by their handle **whole, server and
    /// all** and on one line — as long as a handle is, and no longer.
    static func name(of handle: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("link.open.here", language: language),
               LineText.oneLine(handle, limit: PostMention.handleLength + 1))
    }

    /// Each person once, in the order the words name them: somebody named twice is one action.
    static func handles(in mentions: [PostMention]) -> [String] {
        var seen: Set<String> = []
        return mentions.map(\.handle).filter { seen.insert($0).inserted }
    }
}
