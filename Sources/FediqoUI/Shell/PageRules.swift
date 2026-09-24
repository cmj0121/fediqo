import Foundation
import WebKit

/// What a page drawn inside the app may pull in beside itself (#220): **nothing from another
/// site.**
///
/// A page shown here — a forum's own page in its browser, a page a post links to in the reader —
/// is the site it came from. What that site's markup asks for from anybody else — an outside
/// script, a tracker's pixel, an advertiser's frame, a font or a library off somebody's CDN — is
/// a third party the app would be reaching on the page's say-so, and none of them is a source the
/// person added. So every load a page makes to a site other than its own is blocked before it
/// leaves, by WebKit, for every kind of resource: a subframe, a script, a picture, a stylesheet, a
/// font, a `fetch`, a beacon, a socket.
///
/// **"Its own site" is the page's registrable domain**, as WebKit reads it from the public suffix
/// list: `bbs.example.org` may load from `static.example.org` and `example.org`, and not from
/// `example-cdn.net`. That is WebKit's `third-party`, the same line its own storage partitioning
/// draws. A forum that keeps its pictures and scripts on its own domain reads as before; one
/// that serves them from another company's CDN reads without them, and the reader's browser
/// button is where the whole page is.
///
/// **One exception, and only in a forum's own browser: Cloudflare's challenge.** A forum behind
/// Cloudflare is served by Cloudflare — every request to the forum's own host already goes to it —
/// and when it checks a browser, the check is a frame from `challenges.cloudflare.com`. Without
/// it a challenged forum can never be cleared, and so can never be read at all. It is the forum's
/// own front door, chosen by the forum; nothing else is let through, and a page opened out of a
/// post gets no exception.
@MainActor
enum PageRules {
    /// The one host a forum's own browser may reach beyond the forum's site.
    static let challengeHost = "challenges.cloudflare.com"

    /// The rules, as WebKit reads them. A `forum` page also lets Cloudflare's challenge through.
    static func rules(forum: Bool) -> String {
        var rules = [#"{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block"}}"#]
        if forum {
            let host = challengeHost.replacingOccurrences(of: ".", with: "\\\\.")
            rules.append(
                #"{"trigger":{"url-filter":"^https://"# + host
                    + #"/","load-type":["third-party"]},"action":{"type":"ignore-previous-rules"}}"#
            )
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    private static var compiled: [Bool: Task<WKContentRuleList?, Never>] = [:]

    /// The compiled list, compiled once a run. Nil only where WebKit would not compile it, and a
    /// page is then not loaded at all: a page that would reach anybody it liked is not shown.
    static func list(forum: Bool) async -> WKContentRuleList? {
        if let held = compiled[forum] { return await held.value }
        let task = Task { @MainActor () -> WKContentRuleList? in
            // A store of its own in the temporary directory: what it keeps is these fixed rules
            // and nothing that names a page, and it is rebuilt in a moment where it is gone.
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("FediqoPageRules", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let store = WKContentRuleListStore(url: folder) else { return nil }
            return try? await store.compileContentRuleList(
                forIdentifier: forum ? "forum" : "page", encodedContentRuleList: rules(forum: forum)
            )
        }
        compiled[forum] = task
        return await task.value
    }

    /// Puts the list on `controller` once, and answers whether it is on.
    static func install(on controller: WKUserContentController, forum: Bool) async -> Bool {
        guard let list = await list(forum: forum) else { return false }
        controller.remove(list)
        controller.add(list)
        return true
    }
}
