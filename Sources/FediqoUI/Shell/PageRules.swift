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

    /// The lists compiled this run, by the rules they hold, the one used last at the end.
    /// **Bounded** (`kept`): a list is made of the hosts on the person's list, so one left behind
    /// names a host they removed, or one added for a source they removed (#221) — a list let go
    /// here is taken out of WebKit's store too. One in use on a page stays in use: WebKit holds
    /// what it compiled for as long as a page has it on.
    static var compiled: [String: Task<WKContentRuleList?, Never>] = [:]
    private static var used: [String] = []
    /// How many lists are held at once, besides any on a page: a handful of forums, reading and
    /// signing in, around a change of the list.
    static let kept = 16
    /// How many browsers have each list on (`hold`): a list on a page is never let go.
    private static var holders: [String: Int] = [:]

    /// A browser put the list for `rules` on.
    static func hold(_ rules: String) { holders[rules, default: 0] += 1 }

    /// A browser took the list for `rules` off, or went.
    static func release(_ rules: String) {
        guard let held = holders[rules] else { return }
        holders[rules] = held > 1 ? held - 1 : nil
    }

    /// How a list of rules is compiled. WebKit's own; a test hands in one that fails.
    ///
    /// **Each compile under a name of its own** — the rules' and this run's count — so a list let
    /// go and asked for again at once is never compiled over, or taken out from under, a compile
    /// of the same name still running.
    static var compile: @MainActor (String) async -> WKContentRuleList? = { rules in
        guard let store = await store() else { return nil }
        compiles += 1
        return try? await store.compileContentRuleList(
            forIdentifier: identifier(rules) + "-\(compiles)", encodedContentRuleList: rules
        )
    }

    private static var compiles = 0

    /// How a list let go leaves WebKit's store, by the name it was compiled under. WebKit's own; a
    /// test hands in one that counts.
    static var discard: @MainActor (String) async -> Void = { name in
        guard let store = await store() else { return }
        try? await store.removeContentRuleList(forIdentifier: name)
    }

    /// This run's emptying of what an earlier run left, which every use of the store waits for.
    private static var sweep: Task<Void, Never>?

    /// A store of its own in the temporary directory: what it keeps is lists of the person's
    /// hosts, never a page. **Emptied once a run, before it is first used**, so no list an earlier
    /// run left — naming a host since removed — outlives the run that made it by more than the
    /// next launch.
    private static func store() async -> WKContentRuleListStore? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FediqoPageRules", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: folder) else { return nil }
        let sweeping = sweep ?? Task { @MainActor in
            for name in await store.availableIdentifiers() ?? [] {
                try? await store.removeContentRuleList(forIdentifier: name)
            }
        }
        sweep = sweeping
        await sweeping.value
        return store
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
        touch(rules)
        if let held = compiled[rules] { return await held.value }
        let compile = compile
        let task = Task { @MainActor () -> WKContentRuleList? in await compile(rules) }
        compiled[rules] = task
        let list = await task.value
        if list == nil, compiled[rules] == task { compiled[rules] = nil }
        return list
    }

    /// `rules` used now; the one used longest ago that no page has on let go past `kept`.
    private static func touch(_ rules: String) {
        used.removeAll { $0 == rules }
        used.append(rules)
        while used.count - used.filter({ holders[$0] != nil }).count > kept,
              let index = used.firstIndex(where: { holders[$0] == nil })
        {
            let old = used.remove(at: index)
            guard let held = compiled.removeValue(forKey: old) else { continue }
            let discard = discard
            Task { @MainActor in
                if let list = await held.value { await discard(list.identifier) }
            }
        }
    }

    /// Puts `kind`'s list on `controller` in place of any other, and answers whether it is on.
    static func install(on controller: WKUserContentController, _ kind: Kind) async -> Bool {
        guard let list = await list(kind) else { return false }
        controller.removeAllContentRuleLists()
        controller.add(list)
        return true
    }
}
