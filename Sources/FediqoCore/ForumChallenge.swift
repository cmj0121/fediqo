import Foundation

/// The two rules a new wire boundary has to obey, said once and reachable from outside Core.
///
/// **A re-export, deliberately, and not a second copy.** `Host.isFetchable` is the one definition
/// of what this device will fetch — `https`, and a host to reach — and decision 9 puts it at
/// *every* wire boundary rather than at the first one somebody thought of. Unit F2's web view is
/// a new boundary and it lives in `FediqoUI`, where the internal rule cannot be seen; writing the
/// scheme check out again there would be the exact shape this branch wrote down as a convention
/// it had to learn twice — "a rule enforced at each consumer's door is a rule consumer N+1
/// misses". These forward. They cannot drift, because there is nothing in them to drift.
extension Host {
    /// Decision 9's rule, for a caller outside this module.
    public static func allowsFetch(_ url: URL) -> Bool { isFetchable(url) }

    /// An address on a host, built the one way this package builds them.
    public static func https(host: String, path: String, query: [URLQueryItem] = []) -> URL? {
        httpsURL(host: host, path: path, query: query)
    }
}

/// What came back when this device asked a forum for a page.
///
/// **A challenge is an answer, not a failure and not content.** The whole point of naming it
/// here is that a caller must not be able to parse a challenge page as though it were a thread
/// list: Cloudflare's interstitial is well-formed HTML with a `<title>` and a body, so every
/// parser this project has will happily read it and find nothing, and the reader is told their
/// forum is empty. It is not empty. It is asking them something.
public enum ForumPage: Sendable, Equatable {
    /// The forum's own markup.
    case content(String)
    /// Something in front of the forum answered instead.
    case wall(ForumWall)
}

/// What a filter in front of a forum said, when it said no.
///
/// Three sorts, and each one is read off evidence that is actually in the response rather than
/// inferred. There is deliberately **no "this one needs a person" sort**: whether a managed
/// challenge clears by itself or escalates to something the reader must touch is not written
/// anywhere in the page — it is decided by Cloudflare while the page runs, and the only honest
/// way to find out is to run it and see whether it cleared. The engine answers that question by
/// waiting; this type does not pretend to answer it from markup. See `ForumWall.read`.
public struct ForumWall: Sendable, Equatable {
    public enum Sort: String, Sendable, Equatable {
        /// A browser check. It may clear by itself, and it may ask the reader something.
        case challenge
        /// A refusal with nothing to pass — an address or a country the forum's owner excluded.
        case blocked
        /// Too many requests. The same page later is a different answer.
        case rateLimited
    }

    public let sort: Sort
    /// The status the response carried, where there was one.
    public let status: Int?

    public init(sort: Sort, status: Int? = nil) {
        self.sort = sort
        self.status = status
    }
}

public enum ForumWallReader {
    /// Markers that cannot plausibly occur in a forum's own prose.
    ///
    /// **Structural, and that is the point.** An earlier sketch of this matched the phrase
    /// "Just a moment…" and the sentence about enabling JavaScript and cookies — which is to say
    /// it would have classified *a forum thread about Cloudflare* as a Cloudflare challenge, and
    /// on a Chinese-language forum discussing exactly the problem this unit exists for, that
    /// thread is likely to be on the front page. Each of these is a script identifier or a path
    /// that only Cloudflare's own interstitial emits.
    static let structural = [
        "_cf_chl_opt",
        "/cdn-cgi/challenge-platform/",
        "__CF$cv$params",
        "cf-browser-verification",
    ]

    /// Phrases that count only in the company of Cloudflare's own script host.
    ///
    /// Kept because a challenge page whose script markers change name still carries its widget
    /// from `challenges.cloudflare.com`, and the pairing is what makes a phrase evidence rather
    /// than a coincidence.
    static let phrases = [
        "Just a moment",
        "Enable JavaScript and cookies to continue",
        "cType: 'managed'",
        "Checking your browser",
    ]

    static let widgetHost = "challenges.cloudflare.com"

    /// Cloudflare's own error numbers, which it prints in the page it serves for them.
    static let blockedCodes = ["Error 1020", "error code: 1020", "Error 1009", "Error 1006"]

    /// Reads one response as either the forum or a wall in front of it.
    ///
    /// `mitigated` is the `cf-mitigated` response header, and where it is present it is
    /// **authoritative**: it is Cloudflare stating in a header what it did, which is a better
    /// source than anything guessed from the body, and it is present on `challenge.example` today
    /// (measured: `cf-mitigated: challenge` on `/forum.php`, `/robots.txt` and every other path).
    /// The body markers are the fallback for a filter that does not send it.
    ///
    /// **Status alone is never enough.** A forum answers 403 for a board the reader may not
    /// read, and that is the forum talking, not a wall. So a bare 403 with no marker and no
    /// header is returned as content, and whoever parses it gets to say it was not a thread list.
    /// The one exception is 429, which no forum in this project's survey used for anything else
    /// and which has a true and useful thing to tell the reader on its own.
    public static func read(html: String, status: Int? = nil, mitigated: String? = nil) -> ForumPage {
        if let sort = sortFromHeader(mitigated) {
            return .wall(ForumWall(sort: sort, status: status))
        }
        if structural.contains(where: html.contains) {
            return .wall(ForumWall(sort: .challenge, status: status))
        }
        if html.contains(widgetHost), phrases.contains(where: html.contains) {
            return .wall(ForumWall(sort: .challenge, status: status))
        }
        if blockedCodes.contains(where: html.contains) {
            return .wall(ForumWall(sort: .blocked, status: status))
        }
        if status == 429 {
            return .wall(ForumWall(sort: .rateLimited, status: status))
        }
        return .content(html)
    }

    /// `cf-mitigated` carries one token. Anything Cloudflare adds later that this does not know
    /// is **not** quietly treated as a challenge: an unknown mitigation read as a challenge would
    /// send the reader to a web view that has nothing to show them, forever.
    private static func sortFromHeader(_ mitigated: String?) -> ForumWall.Sort? {
        switch mitigated?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "challenge": .challenge
        case "block": .blocked
        case "ratelimit", "rate_limit": .rateLimited
        default: nil
        }
    }
}
