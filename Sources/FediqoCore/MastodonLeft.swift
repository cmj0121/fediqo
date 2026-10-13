import Foundation
import Security

/// A sign-in this device made at a source and does not use (#347): one a wider sign-in took
/// the place of, one made and not yet kept, one the device held and could not keep, or one
/// the source was asked to end and did not say it had.
///
/// **It can be ended, and nothing else.** The token string and the registration's secret are
/// not readable outside this module, so no signed-in request can be built from one: what a
/// place outside is given is which host it is at, what it held, whose it was, and its state.
///
/// **It prints as its host and its state**, as a token prints as its host: a description, an
/// error or a mirror is how a secret reaches a log.
public struct MastodonLeft: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public enum State: String, Sendable, CaseIterable {
        /// A wider sign-in took its place. Left live at the source, so another device carrying
        /// it goes on working, until the person signs out here.
        case left
        /// Made by a sign-in whose check has not come back: ended unless it comes to be held.
        case pending
        /// The sign-in the person held, which this device could not keep or put back. Filed
        /// again as held when it can be; ended only when the person signs out.
        case lost
        /// The source was asked to end it and did not say it had: asked again.
        case owed
        /// A read back is taking it out, with a package's sign-in or nothing put in its
        /// place — and may yet put it back as the one held, where a later step refuses,
        /// at once or when a locked device is unlocked. **Nothing ends it meanwhile but
        /// the person signing out.**
        case replacing
        /// A read back that held took it out. Whether it is an earlier form of the sign-in
        /// now held, and so left, or another account's or one that may do more, and so
        /// ended, is said only by what its source answers of the one now held — never by
        /// what the package said.
        case replaced
    }

    public let host: String
    let accessToken: String
    let clientID: String
    let clientSecret: String
    /// What it was granted, as its sign-in wrote down; nothing where nothing was.
    public let words: String?
    /// Whose sign-in it was, by the id its source gives the account, where that was known.
    public let accountID: String?
    public let state: State

    /// `token` as one this device leaves in `state`. `accountID` is whose it is where the
    /// token itself does not say — a sign-in whose check named the account this run.
    ///
    /// **Never as lost**: a lost one is filed again as the sign-in held, so only a store
    /// writes one down (`MastodonTokenStore.journalLost`). Asked for here, it is left.
    public init(_ token: MastodonToken, as state: State, accountID: String? = nil) {
        self.init(token, accountID: accountID, state: state == .lost ? .left : state)
    }

    /// The sign-in the person held, as a store writes it down where it could not be kept.
    static func lost(_ held: MastodonToken, accountID: String?) -> MastodonLeft {
        MastodonLeft(held, accountID: accountID, state: .lost)
    }

    private init(_ token: MastodonToken, accountID: String?, state: State) {
        self.init(
            host: token.host, accessToken: token.accessToken, clientID: token.clientID,
            clientSecret: token.clientSecret, words: token.scopes,
            accountID: token.accountID ?? accountID, state: state
        )
    }

    init(
        host: String, accessToken: String, clientID: String, clientSecret: String,
        words: String?, accountID: String?, state: State
    ) {
        self.host = host.lowercased()
        self.accessToken = accessToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.words = words
        self.accountID = accountID
        self.state = state
    }

    /// The same sign-in in another state — **and never as lost**, which nothing outside a
    /// store makes of one (`init`): asked for that, it is handed back as it is.
    public func marked(_ state: State) -> MastodonLeft {
        if state == .lost { return self }
        return MastodonLeft(
            host: host, accessToken: accessToken, clientID: clientID, clientSecret: clientSecret,
            words: words, accountID: accountID, state: state
        )
    }

    /// Whether this is the sign-in `token` is: the same token string, whatever is written
    /// beside either. Nothing held is no sign-in.
    public func isToken(_ token: MastodonToken?) -> Bool {
        token?.accessToken == accessToken
    }

    /// Whether this and `other` are one sign-in, in whatever state each is.
    public func isSame(as other: MastodonLeft) -> Bool {
        other.accessToken == accessToken
    }

    /// Whether it may do something a sign-in granted `words` may not — or, with nothing
    /// written down of what it holds, cannot be shown not to.
    public func holdsMore(than words: String?) -> Bool {
        guard let mine = self.words else { return true }
        return !MastodonRegistration.holds(mine, on: words)
    }

    /// The sign-in the person held, as it is filed again: granted what it was, asked at
    /// least that, and whose it was — without which the next wider sign-in could not be
    /// shown to be the same account's, and would end it. What was refused of it and its
    /// handle are not kept here, so a part it was refused reads as never asked — one
    /// question more, and nothing widened.
    var restored: MastodonToken {
        MastodonToken(
            host: host, accessToken: accessToken, clientID: clientID, clientSecret: clientSecret,
            scopes: words, asked: words, accountID: accountID
        )
    }

    public var description: String { "MastodonLeft(host: \(host), \(state.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host, "state": state.rawValue]) }
}

/// What a source answered when asked to end a sign-in.
public enum MastodonEnd: Sendable, Equatable {
    /// It said it had: the sign-in is ended, or was already.
    case ended
    /// It refused, and will every time: this registration may not end that sign-in (a 403).
    case refused
    /// It gave no answer to go by — unreachable, or busy. Worth asking again.
    case unanswered
}

extension MastodonKeychain {
    /// The sign-ins this device left at each host, apart from the ones it holds: a host's
    /// journal is one item, and a confirmed sign-out by the source — which deletes the
    /// sign-in's own item — leaves it where it is.
    public static let leftService = "fediqo.mastodon.left"

    /// **No attribute but the label**: nothing of a journal is readable without its value,
    /// since nothing of it is drawn before the app has read what it holds. Kept as the
    /// sign-in itself is — this device only, while unlocked, never synchronised.
    static func attributes(forLeft entries: [MastodonLeft], host: String) -> [String: Any] {
        var attributes = lookup(host: host, service: leftService)
        attributes[kSecAttrLabel as String] = "\(Fediqo.name) — \(host.lowercased()) earlier sign-ins"
        attributes[kSecAttrAccessible as String] = ForumKeychain.accessibility
        attributes[kSecValueData as String] = LeftWire.encode(entries)
        return attributes
    }

    /// What a write over a journal already there writes: its value, and nothing of where
    /// the item is kept or how it is protected.
    static func changes(forLeft entries: [MastodonLeft]) -> [String: Any] {
        [kSecValueData as String: LeftWire.encode(entries)]
    }

    /// Every host with a journal, attributes only.
    static func allLeft() -> [String: Any] {
        var query = allItems()
        query[kSecAttrService as String] = leftService
        return query
    }

    /// A journal's value. The one place an entry is turned into bytes and back.
    enum LeftWire {
        private struct Entry: Codable {
            var accessToken: String
            var clientID: String
            var clientSecret: String
            var words: String?
            var accountID: String?
            var state: String
        }

        static func encode(_ entries: [MastodonLeft]) -> Data {
            let value = entries.map {
                Entry(
                    accessToken: $0.accessToken, clientID: $0.clientID, clientSecret: $0.clientSecret,
                    words: $0.words, accountID: $0.accountID, state: $0.state.rawValue
                )
            }
            return (try? JSONEncoder().encode(value)) ?? Data()
        }

        /// Nothing, where the value is not a journal. **A state this build does not know is
        /// read as left**: nothing is dropped unended, and nothing is taken for the
        /// person's own or for one to end at once.
        ///
        /// **Read so, it is not safe from being ended before the person signs out**: a
        /// left sign-in is ended by a going-through where none is held at its host, and
        /// where the one held is another account's. So a build from before a read back
        /// wrote its own states (#347), run over a journal this one wrote, would end what
        /// a read back took out as it ends any left one — the cost of going back a build,
        /// and of nothing else.
        static func decode(_ data: Data, host: String) -> [MastodonLeft]? {
            guard let value = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
            return value.filter { !$0.accessToken.isEmpty }.map {
                MastodonLeft(
                    host: host, accessToken: $0.accessToken, clientID: $0.clientID,
                    clientSecret: $0.clientSecret, words: $0.words, accountID: $0.accountID,
                    state: MastodonLeft.State(rawValue: $0.state) ?? .left
                )
            }
        }
    }
}
