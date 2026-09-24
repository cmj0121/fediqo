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
/// **What else a page may pull in is `Allowance`'s, and nothing here names a host.** A forum's
/// own browser lets through the entries that apply on its pages — Cloudflare's check in front of
/// it — and, while the person has its sign-in in front of them, the entries that apply there: the
/// check a sign-in shows to prove a person is there. A page opened out of a post gets none.
///
/// **The list is the person's** (#226): an entry switched off is not let through, and a host they
/// added for a forum is let through on that forum's pages and no other's. So a list is compiled for
/// the rules it holds, not for its kind: a change of the list is a new list, put on the next time a
/// browser asks — and a forum's browser asks at once (`SourceWork.allowancesChanged`).
@MainActor
enum PageRules {
    /// Which page the rules are for.
    enum Kind: Hashable, Sendable {
        /// A page a post links to, in the app's reader.
        case page
        /// A page in a forum's own browser.
        case forum
        /// A forum's sign-in, with the person in front of it.
        case signIn

        /// The entries of `Allowance` whose frames it lets through, on the pages `of` a source.
        func allowances(_ list: [Allowance], of source: String? = nil) -> [Allowance] {
            let applying: [Allowance] = switch self {
            case .page: []
            case .forum: Allowance.applying(.forumPage, in: list, of: source)
            case .signIn: Allowance.applying(.signingIn, in: list, of: source)
            }
            return applying.filter { $0.reach == .frame }
        }
    }

    /// The rules, as WebKit reads them: every other site's load blocked, and then each host an
    /// entry lets through for this kind of page, `of` this source, let through again.
    static func rules(
        _ kind: Kind, of source: String? = nil, allowing list: [Allowance] = Allowance.standing
    ) -> String {
        var rules = [#"{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block"}}"#]
        for entry in kind.allowances(list, of: source) {
            for pattern in entry.hosts {
                let filter = pattern.urlFilter.replacingOccurrences(of: "\\", with: "\\\\")
                rules.append(
                    #"{"trigger":{"url-filter":""# + filter
                        + #"","load-type":["third-party"]},"action":{"type":"ignore-previous-rules"}}"#
                )
            }
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// Every list compiled this run, by the rules it holds.
    static var compiled: [String: Task<WKContentRuleList?, Never>] = [:]

    /// How a list of rules is compiled. WebKit's own; a test hands in one that fails.
    static var compile: @MainActor (String) async -> WKContentRuleList? = { rules in
        // A store of its own in the temporary directory: what it keeps is these rules — the
        // list's hosts, never a page — under a name made of them, and it is rebuilt in a moment
        // where it is gone.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FediqoPageRules", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: folder) else { return nil }
        return try? await store.compileContentRuleList(
            forIdentifier: identifier(rules), encodedContentRuleList: rules
        )
    }

    /// A name for a list, the same for the same rules on every run: FNV-1a of its text.
    static func identifier(_ rules: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rules.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return "rules-" + String(hash, radix: 16)
    }

    /// The compiled list for `kind`'s pages `of` a source under `list`, compiled once a run for
    /// the rules it holds. Nil only where WebKit would not compile it, and a page is then not
    /// loaded at all: a page that would reach anybody it liked is not shown.
    /// **A failure is not kept**: the next page asks WebKit again, so one bad moment — a full
    /// disk, a temporary directory swept from under it — does not stop every page for the run.
    static func list(
        _ kind: Kind, of source: String? = nil, allowing list: [Allowance] = Allowance.standing
    ) async -> WKContentRuleList? {
        await compiled(rules(kind, of: source, allowing: list))
    }

    /// The compiled list for `rules`.
    static func compiled(_ rules: String) async -> WKContentRuleList? {
        if let held = compiled[rules] { return await held.value }
        let compile = compile
        let task = Task { @MainActor () -> WKContentRuleList? in await compile(rules) }
        compiled[rules] = task
        let list = await task.value
        if list == nil, compiled[rules] == task { compiled[rules] = nil }
        return list
    }

    /// Puts `kind`'s list on `controller` in place of any other, and answers whether it is on.
    static func install(on controller: WKUserContentController, _ kind: Kind) async -> Bool {
        guard let list = await list(kind) else { return false }
        controller.removeAllContentRuleLists()
        controller.add(list)
        return true
    }
}
