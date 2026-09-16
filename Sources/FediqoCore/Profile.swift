import Foundation

/// What a server says about itself, in its own words, before anybody has joined it.
///
/// **Every scalar is Optional and `rules` is not, and that asymmetry is the whole design.** For a
/// scalar, "this source has no such idea" and "the source stated it blank" are different facts,
/// and Optional is the only thing that tells them apart — the rule `Note.title` already sets for
/// this package. For a list the two are the same drawing: no rules and an empty list of rules are
/// both nothing on the screen, so a second spelling of empty would buy nothing except one more
/// thing for a wire boundary to get wrong. Mastodon guarantees the array and routinely sends
/// `[]`; neither forum has the concept at all.
///
/// **A field nothing filled in is not a field nobody could read.** Everything here is nil because
/// the protocol has no such idea, never because a request failed — a failure is
/// `ProfileAnswer.unread` and never reaches this type.
///
/// **One Optional carries two facts, and that is a ruling rather than an oversight** (D11). `nil`
/// on `readsWithoutAccount` is "Mastodon has no such idea"; `nil` on `summary` is "this Discourse
/// has the field and left it unset" — different facts in one spelling. They were left in one
/// because both are already recoverable without a second representation:
///
/// - **For the strings, the two are not folded at all.** `nil` is "this source has no such field"
///   and `""` is "it has one and the administrator left it blank", which is the distinction
///   `Note.title` draws and the reason every string here is Optional rather than defaulted.
///   Mastodon's `description` is guaranteed present and routinely empty — the case that proves
///   the pair is real and that this type keeps it.
/// - **For the numbers and the one Bool, which fields are a concept at all is a function of
///   `kind`, and `kind` is on this type.** `activeMonth` is a Mastodon idea; `people`, `posts` and
///   `readsWithoutAccount` are Discourse ideas. A reader that ever has to draw "this server did
///   not say" differently from "this protocol has no such field" can ask `kind` and know which it
///   is holding. A two-level enum across eleven fields would buy that same answer at the price of
///   eleven wire boundaries to get wrong.
///
/// What would change this: the first caller that genuinely needs the two drawn differently for a
/// **numeric** field. `Note.sensitive` took the harder line — "Nothing is not `false`" — and it
/// was right to, because there `false` is a meaningful value and reading silence as it would
/// uncover what nobody uncovered. Here both facts draw as nothing, so nothing is what they are.
public struct SourceProfile: Sendable, Hashable, Identifiable {
    public var id: String { host }
    public let host: String
    public let kind: ProtocolKind
    /// What the server calls itself. Nothing where the protocol publishes no such field; empty
    /// where the administrator left it blank.
    public let title: String?
    /// The paragraph under the name — Mastodon's `description`, Discourse's `description`.
    public let summary: String?
    /// The picture the server chose to be known by.
    ///
    /// Admitted through `Host.fetchableURL`, because this address arrived in a stranger's JSON
    /// and is not ours: `data:` and `javascript:` are both things `URL(string:)` will build out
    /// of it, and a picture cache handed one would do as it was told.
    public let thumbnail: URL?
    /// How many people used this server in the last month. **Mastodon only.**
    ///
    /// `/api/v2/instance` carries `usage.users.active_month` and **no total** — the count of
    /// registered accounts left v2 with v1's `stats` block and did not come back. So this is
    /// nothing on a Discourse because a Discourse has no such idea, and the reverse is true of
    /// `people` below. Neither is ever "we could not find out".
    public let activeMonth: Int?
    /// How many accounts the forum has. **Discourse only** — see `activeMonth`.
    public let people: Int?
    /// How many posts the forum holds. **Discourse only.**
    public let posts: Int?
    /// Whether a stranger may make an account, and on what terms.
    public let registration: Registration?
    /// Whether a signed-out reader may read this source at all.
    ///
    /// **The one field here that predicts a failure, which is why it is worth carrying.** A
    /// Discourse with `login_required` set answers `/latest.json` with 403, so a reader who
    /// subscribes gets `JoinError.refused` and a sentence about being turned away — after
    /// pressing the button. It arrives in a document this preview fetches anyway, so the preview
    /// can say so *before* the press instead of explaining it afterwards.
    ///
    /// Discourse's `login_required`, inverted, because what a reader wants to know is whether
    /// they can read it and not what the setting is called.
    public let readsWithoutAccount: Bool?
    /// The rules the server asks its people to keep, in the order it listed them. Empty is both
    /// "there are none" and "this protocol has no such idea" — see the note on the type.
    public let rules: [String]

    public enum Registration: String, Sendable, Hashable {
        case open
        case byApproval
        case closed
    }

    public init(
        host: String,
        kind: ProtocolKind,
        title: String? = nil,
        summary: String? = nil,
        thumbnail: URL? = nil,
        activeMonth: Int? = nil,
        people: Int? = nil,
        posts: Int? = nil,
        registration: Registration? = nil,
        readsWithoutAccount: Bool? = nil,
        rules: [String] = []
    ) {
        self.host = host
        self.kind = kind
        self.title = title
        self.summary = summary
        self.thumbnail = thumbnail
        self.activeMonth = activeMonth
        self.people = people
        self.posts = posts
        self.registration = registration
        self.readsWithoutAccount = readsWithoutAccount
        self.rules = rules
    }
}

/// What came of asking a host about itself.
///
/// **Four cases, because there are four different sentences to say to a reader and three of them
/// are not failures.** "Here is what it says", "it publishes nothing to ask", "we asked and could
/// not read the answer", "nobody has asked yet". Folding any two of them together is how a reader
/// gets told the wrong one — a Discuz! reported as unreadable reads as a broken server, and an
/// unasked one reported as silent says a server stayed quiet when nothing ever spoke to it.
///
/// **`.unasked` is a case and not an `Optional<ProfileAnswer>`.** In this package Optional already
/// means "this source has no such idea", which is `.silent`; a nil that meant "unknown" here would
/// break that convention in the one place it is hardest to see, because both readings are
/// plausible for exactly this type.
public enum ProfileAnswer: Sendable, Hashable {
    /// The server answered, and this is what it said.
    case stated(SourceProfile)
    /// There was nothing to ask. The protocol publishes no machine-readable self-description, so
    /// **no request was made** — this is not a failed read, it is a read that never happened
    /// because there is no document.
    case silent(host: String, kind: ProtocolKind)
    /// It was asked, and the answer could not be read.
    case unread(host: String, kind: ProtocolKind, ProfileError)
    /// Nobody has asked yet. The state a source sits in before its preview is fetched.
    case unasked(host: String, kind: ProtocolKind)
}

/// Why a profile could not be read.
///
/// **Not `JoinError`, and the distance between them is the point.** A profile that cannot be read
/// is not a source that cannot be joined, and reporting one as the other sends a reader away from
/// a server they can perfectly well have. The evidence that this is real rather than tidy: a
/// Mastodon older than 4.0 serves no `/api/v2/instance` at all and reads its timeline perfectly,
/// and a 4.0–4.3 in limited-federation mode answered 401 there while serving everything else.
public enum ProfileError: Error, Hashable, Sendable {
    /// No answer at all — a dropped connection, a name that does not resolve.
    case unreachable
    /// The server answered with a status that says no, in the way a filter says it.
    case refused(Int)
    /// It answered, and there was no profile in the answer: a status that is not a refusal, or a
    /// document this device could not decode.
    case unreadable

    /// Which of these a status code is.
    ///
    /// **The same four numbers `DiscourseClient.check` calls a refusal**, and for its reason: a
    /// filter that has decided this app is a robot answers 401, 403, 429 or 503, and that is a
    /// door somebody closed on purpose. Everything else non-2xx is `unreadable` rather than
    /// refused — a 404 here is a Mastodon too old to have the endpoint, which is a server that
    /// reads fine and has nothing to say about itself in this format.
    static func of(status: Int) -> ProfileError {
        switch status {
        case 401, 403, 429, 503: .refused(status)
        default: .unreadable
        }
    }
}

/// Cancellation, recognised however it arrives.
///
/// **`URLSession` does not report a cancelled transfer as `CancellationError`.** It reports
/// `URLError(.cancelled)`, and `URLSessionClient.data(from:)` deliberately throws exactly that so
/// a reader walking away can be told apart from a body that tripped the ceiling. Everything above
/// it that promises to distinguish a reader from a server has to make the translation back, and
/// the two places in this unit that promise it share this one so they cannot disagree.
///
/// **`ForumWeb.translate` makes the same translation one layer up, and not the same way.** It
/// compares the bare `NSError` code with no domain beside it. This one checks the domain, for the
/// reason given at the comparison below — so where the two differ this is the stricter, and that
/// is a difference on purpose rather than a precedent being followed.
///
/// **`public` rather than a twin in FediqoUI**, which was the fork this unit had to settle. The
/// UI has a caller that needs it — `ShellSession.loadCatalog`, whose `ServerDirectory` has no
/// error vocabulary of its own and hands the transport's failures up exactly as they arrive — and
/// a second copy of a predicate this subtle is how two copies drift. `ForumWeb.translate` above is
/// the evidence for that rather than the worry about it: it is already a divergent second copy,
/// written without the domain check, and it is one because there was nothing to share.
public enum Cancellation {
    public static func happened(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        // The domain as well as the number. `NSURLErrorCancelled` is -999, and a Swift error
        // bridged to `NSError` takes its code from its own case number, so a bare code comparison
        // would eventually call somebody's third enum case a reader walking away.
        return (error as? URLError)?.code == .cancelled
    }
}

/// Asks a host what it says about itself, and turns whatever happens into one of four sentences.
///
/// One request for Mastodon, two for Discourse, and **none at all** for everything else.
public struct SourceProfiles: Sendable {
    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    /// What `host` says about itself, given what it was already found to speak.
    ///
    /// **Throws `CancellationError` and nothing else, and says so in the signature.** A reader who
    /// walked away must not have their leaving recorded as a server that would not answer: that is
    /// a fact about a host, it is what a preview shows next time, and it would be a lie. Every
    /// other outcome — including every failure — is a case of `ProfileAnswer`, so a caller has
    /// exactly one thing to catch and it is never about the server.
    ///
    /// The kind is passed in rather than detected here, because the caller has already asked this
    /// stranger's server what it is and asking twice is traffic nobody owes us — the rule
    /// `SourceJoin` states as "one detection, not one per protocol".
    ///
    /// Never answers `.unasked`: that case belongs to a caller holding a source nothing has asked
    /// about yet, and this function is the asking.
    ///
    /// **The host is normalised here rather than trusted from the caller**, which is this
    /// package's habit — the guarantee goes at the boundary and not into a rule each caller
    /// remembers (`DiscuzJoin.refusal` says so in as many words). Two things go wrong without it,
    /// and neither announces itself: `https://install.example` and ` install.example ` are both a
    /// host this device can reach and would be reported as one it could not, and
    /// `INSTALL.example` would succeed under an `id` that is a different string from the
    /// normalised spelling of the same server — which is a `profiles` map with two rows for one
    /// source, one unit from here.
    ///
    /// A string that is not a host at all survives as itself and answers `.unread(.unreachable)`,
    /// because nothing was ever asked and nothing ever answered. That is the closest true sentence
    /// of the four; a caller with a host to check has `Host.parse` and should not be finding out
    /// here.
    public func answer(
        host raw: String,
        kind: ProtocolKind
    ) async throws(CancellationError) -> ProfileAnswer {
        let host = (try? Host.parse(raw)) ?? raw
        // **No `default:`.** A protocol falling through a switch here is a silent wrong answer,
        // not a safe one — the shape that once drew a whole Discuz! forum as microblog posts with
        // the compiler saying nothing (`DummyItem.shape(of:)`, `SourceJoin.join`). Here it would
        // be a preview that is blank for a protocol somebody has just finished writing a client
        // for, with nothing anywhere to say why. Every case is named, so the next protocol breaks
        // the build at the place that has to decide whether it can be asked.
        switch kind {
        case .mastodon:
            return try await read(host: host, kind: kind) {
                try await MastodonClient(http: http, host: host).profile()
            }
        case .discourse:
            return try await read(host: host, kind: kind) {
                try await DiscourseClient(http: http, host: host).profile()
            }
        // **Discuz! is silent, and no request is made.** It is a page, not an endpoint: there is
        // no public, documented, machine-readable self-description in X3.4, X3.5 or X5. The
        // statistics block a theme draws on `/forum.php` is not one — it is theme-dependent, it
        // is not on the front page, and its labels are localised. Reading numbers out of a
        // template's markup and presenting them as what the forum said is the true-looking lie
        // this package is written against.
        case .discuz:
            return .silent(host: host, kind: kind)
        // Silent because nothing can ask: none of these can be joined yet, so there is no preview
        // for a reader to be shown. Each becomes a real answer in the unit that gives it a client.
        case .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial,
            .unknown:
            return .silent(host: host, kind: kind)
        }
    }

    /// One read, with every way it can fail sorted into the sentence it deserves.
    ///
    /// The catch ladder is `MastodonJoin.ingest`'s, for its reasons: a decode failure is a host
    /// that answered with something that was not a profile, and anything left is a host that did
    /// not answer. Cancellation is lifted out ahead of both, through `Cancellation.happened` —
    /// a reader who walked away arrives here looking exactly like a server that hung up, and
    /// recording their leaving as a fact about the host is the one thing this unit must not do.
    private func read(
        host: String,
        kind: ProtocolKind,
        _ fetch: () async throws -> SourceProfile
    ) async throws(CancellationError) -> ProfileAnswer {
        do {
            return .stated(try await fetch())
        } catch let error as ProfileError {
            return .unread(host: host, kind: kind, error)
        } catch {
            if Cancellation.happened(error) { throw CancellationError() }
            if error is DecodingError {
                return .unread(host: host, kind: kind, .unreadable)
            }
            return .unread(host: host, kind: kind, .unreachable)
        }
    }
}
