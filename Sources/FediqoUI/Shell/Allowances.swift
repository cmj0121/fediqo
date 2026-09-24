import FediqoCore
import Foundation

/// What reaches beyond a source the person added, each only because the person asked for it
/// (#220): one list of named entries, and nothing else anywhere.
///
/// **Data, not conditionals.** The gate (`SourceWork.admission`), a forum's browser
/// (`ForumWebEngine.decide`) and the rules a page loads under (`PageRules`) all read this list and
/// nothing else, and every act an entry lets through is written to the run's record with the
/// entry's `id` (`SourceAct.allowedBy`). So what is let through is said in one place, and a
/// later list the person edits is this one, handed in.
struct Allowance: Identifiable, Equatable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        /// The directory of servers, while a source is being added.
        case directory
        /// Cloudflare's browser check in front of a forum, in its own browser.
        case forumChallenge
        /// The check a forum's sign-in shows to prove a person is there.
        case personCheck
        /// A page the person follows away from a forum's sign-in.
        case signInPage
    }

    /// When an entry applies.
    enum When: Sendable {
        /// While the person is adding a source: the browse step of the add sheet.
        case adding
        /// On any page in a forum's own browser, the sign-in included.
        case forumPage
        /// Only while the person has a forum's sign-in in front of them.
        case signingIn
    }

    /// What it lets through.
    enum Reach: Sendable, Equatable {
        /// A request the app makes, for this purpose, to one of `hosts`.
        case request(SourceWork.Purpose)
        /// A frame, script or picture a page pulls in from one of `hosts`.
        case frame
        /// The page itself moving to any host at all.
        case navigation
    }

    /// A host an entry lets through: that host, or it and every host under it; and, where named,
    /// only addresses whose path starts with `path`.
    struct Pattern: Equatable, Sendable {
        let host: String
        var subdomains = false
        var path = "/"
        /// `https`, always, in the app. A test serves its pages under a scheme of its own.
        var scheme = "https"

        func matches(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == scheme, let there = url.host()?.lowercased() else {
                return false
            }
            let hostMatches = there == host || (subdomains && there.hasSuffix("." + host))
            return hostMatches && (url.path.isEmpty ? "/" : url.path).hasPrefix(path)
        }

        /// As WebKit's content rules read an address: no alternation, so one rule per pattern.
        var urlFilter: String {
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            let path = path.replacingOccurrences(of: ".", with: "\\.")
            return "^" + scheme + "://" + (subdomains ? "([^/]*\\.)?" : "") + escaped + path
        }
    }

    let id: ID
    let when: When
    let reach: Reach
    /// Empty for `navigation`, which lets the page go anywhere.
    let hosts: [Pattern]

    /// What is let through today. A later build hands in the person's own (#226).
    static let standing: [Allowance] = [
        Allowance(
            id: .directory, when: .adding, reach: .request(.directory),
            hosts: [Pattern(host: ServerDirectory.host)]
        ),
        Allowance(
            id: .forumChallenge, when: .forumPage, reach: .frame,
            hosts: [Pattern(host: "challenges.cloudflare.com")]
        ),
        Allowance(
            id: .personCheck, when: .signingIn, reach: .frame,
            hosts: [
                // reCAPTCHA
                Pattern(host: "www.google.com", path: "/recaptcha/"),
                Pattern(host: "www.gstatic.com", path: "/recaptcha/"),
                Pattern(host: "recaptcha.net", subdomains: true),
                // hCaptcha
                Pattern(host: "hcaptcha.com", subdomains: true),
                // Geetest
                Pattern(host: "geetest.com", subdomains: true),
                // Tencent
                Pattern(host: "captcha.qq.com", subdomains: true),
                Pattern(host: "captcha.gtimg.com"),
            ]
        ),
        Allowance(id: .signInPage, when: .signingIn, reach: .navigation, hosts: []),
    ]

    /// Whether this entry, where it applies, lets `url` through.
    func allows(_ url: URL) -> Bool {
        reach == .navigation || hosts.contains { $0.matches(url) }
    }

    /// The entries that apply `in` a context — `signingIn` also takes every `forumPage` entry.
    static func applying(_ when: When, in list: [Allowance] = standing) -> [Allowance] {
        list.filter { $0.when == when || (when == .signingIn && $0.when == .forumPage) }
    }
}
