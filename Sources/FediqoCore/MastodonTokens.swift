import Foundation
import Security

/// What a Mastodon sign-in leaves on this device: the access token, and the app registration it
/// was issued to, which revoking it needs.
///
/// **It prints as its host and nothing else**, for `ForumCredential`'s reason: a description,
/// an error or a mirror is how a secret reaches a log. No `Codable` either; the Keychain value is
/// written by a private wire type below, and only there.
public struct MastodonToken: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let host: String
    public let accessToken: String
    public let clientID: String
    public let clientSecret: String
    /// What the sign-in that issued it asked for, or **nothing for a token kept before this app
    /// asked the reader anything about writing** (#69).
    ///
    /// The two are not the same fact and must not be spelt the same way: a token with the reading
    /// scopes written down is one whose reader was offered the writing part and said no, and a
    /// token with nothing written down is one whose reader was never asked. Both read and neither
    /// writes; only the second is owed the question.
    public let scopes: String?
    /// What the sign-in that issued it asked the source for, at its widest (#285), or nothing for
    /// a token kept before this was written down. **Not what it may do** — that is `scopes` — but
    /// what tells a sign-in that asked for bookmarks and was not given them from one made before
    /// bookmarks were asked for at all: the first is not asked again, and the second is owed it.
    public let asked: String?
    /// The words of what the person refused on the source's own page (#347), or nothing where
    /// nothing was — and in every sign-in kept before this was written down. **Apart from
    /// `asked`**, which cannot tell the two ways a part is asked and not held: refused there,
    /// which may be asked again, and given less of or not had by the source, which is not.
    public let refused: String?
    /// The store's mark of one filing of this token string (#347): made when the string is
    /// first filed and carried through every later write of the same string, so a sign-in
    /// replaced from anywhere shows as another stamp with no token read. Nothing until a store
    /// has filed it, and in every sign-in kept before this was written down.
    ///
    /// **Random — not a clock and not a count**, so it says nothing of when or how often, and
    /// two filings cannot come to share one. Not a secret.
    public private(set) var stamp: String?
    /// Whose sign-in this is, as its source said through it: the id the source gives the
    /// account, and its handle as `@user@host`. Nothing until the source has been asked — a
    /// token kept before this was written down, or one a package brought. **Kept with the
    /// sign-in**, so what the person writes can be named as theirs with no network at all.
    public let accountID: String?
    public let handle: String?

    public init(
        host: String, accessToken: String, clientID: String, clientSecret: String,
        scopes: String? = nil, asked: String? = nil, refused: String? = nil,
        accountID: String? = nil, handle: String? = nil
    ) {
        self.refused = refused
        self.accountID = accountID
        self.handle = handle
        self.host = host.lowercased()
        self.accessToken = accessToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.asked = asked
    }

    /// This token, written down as issued by a sign-in that asked for `asked` — the fact beside
    /// it, and never the token itself.
    public func recorded(asked: String?) -> MastodonToken {
        with(asked: asked, refused: refused, accountID: accountID, handle: handle)
    }

    /// This token, written down as one whose source's page was refused for `refused`.
    public func recorded(refused: String?) -> MastodonToken {
        with(asked: asked, refused: refused, accountID: accountID, handle: handle)
    }

    /// This token, written down as the sign-in of the account its source named through it.
    public func named(accountID: String, handle: String?) -> MastodonToken {
        with(asked: asked, refused: refused, accountID: accountID, handle: handle)
    }

    /// The same token string with other facts beside it — and so the same stamp.
    private func with(asked: String?, refused: String?, accountID: String?, handle: String?) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: accessToken, clientID: clientID, clientSecret: clientSecret,
            scopes: scopes, asked: asked, refused: refused, accountID: accountID, handle: handle
        ).stamped(stamp)
    }

    /// This token as a store files it. Only a store stamps.
    func stamped(_ stamp: String?) -> MastodonToken {
        var filed = self
        filed.stamp = stamp
        return filed
    }

    /// This token with what the sign-in it replaces was refused written beside its own, **less
    /// every word this one was given**: a part granted is no longer one refused, and another
    /// part's refusal is not lost with it. Nothing, where no word is left.
    ///
    /// **What a swap is handed.** A swap writes the token's own `refused` and nothing of the
    /// one it replaces, so a fresh token swapped in as it came would wipe every refusal.
    public func carrying(refusedFrom held: MastodonHeld) -> MastodonToken {
        recorded(refused: MastodonParts.refused([held.refused, refused], given: scopes))
    }

    /// This token with each fact it leaves out taken from `held`, the same string as the
    /// device holds it: what an update in place writes, which writes down and never unwrites.
    /// **Nothing for `refused` keeps what is held; the empty string is what clears it.**
    /// **Who it is, is one fact**: a token that names the account carries that account's
    /// handle, none included, and the handle held is kept only where it names nobody.
    func over(_ held: MastodonToken) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: accessToken, clientID: clientID, clientSecret: clientSecret,
            scopes: scopes ?? held.scopes, asked: asked ?? held.asked, refused: refused ?? held.refused,
            accountID: accountID ?? held.accountID, handle: accountID == nil ? handle ?? held.handle : handle
        )
    }

    /// What this sign-in is known to hold, **as its value says** — what a decision reads.
    public var held: MastodonHeld {
        MastodonHeld(scopes: scopes, asked: asked, refused: refused, stamp: stamp)
    }

    /// Whether this sign-in asked for bookmarks and was not given them (#285).
    public var bookmarksRefused: Bool { held.bookmarksRefused }

    /// Whether this sign-in asked for notices and was not given them (#323).
    public var noticesRefused: Bool { held.noticesRefused }

    /// **The stamp is left out.** It marks a filing and not the sign-in: a token read back is
    /// the one that was saved, and no two filings of one string are held at once.
    public static func == (one: MastodonToken, other: MastodonToken) -> Bool {
        one.host == other.host && one.accessToken == other.accessToken
            && one.clientID == other.clientID && one.clientSecret == other.clientSecret
            && one.scopes == other.scopes && one.asked == other.asked && one.refused == other.refused
            && one.accountID == other.accountID && one.handle == other.handle
    }

    public var app: MastodonApp {
        MastodonApp(host: host, clientID: clientID, clientSecret: clientSecret)
    }

    public var description: String { "MastodonToken(host: \(host))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host]) }
}

/// What a sign-in is known to hold (#347): three lists of scope words and a stamp, none of
/// them a secret — so this is what rides beside a token where it can be read without one.
///
/// Every reading of what a sign-in may do is made here, off these, whichever place they were
/// read from: the item's value (`MastodonToken.held`), or the copies beside it
/// (`MastodonTokenStore.parts()`).
public struct MastodonHeld: Equatable, Sendable {
    /// What the source said it granted, never more than was asked; nothing for a sign-in kept
    /// before anything was written down.
    public let scopes: String?
    /// Every word a page of this sign-in asked for.
    public let asked: String?
    /// The words of what was refused on the source's own page.
    public let refused: String?
    /// The store's mark of the filing; see `MastodonToken.stamp`.
    public let stamp: String?

    public init(scopes: String?, asked: String?, refused: String? = nil, stamp: String? = nil) {
        self.scopes = scopes
        self.asked = asked
        self.refused = refused
        self.stamp = stamp
    }

    public var grant: MastodonGrant { MastodonGrant.of(scopes: scopes) }
    /// Whether it may bookmark (#285). Nothing written down says nothing, and nothing is no.
    public var bookmarks: Bool { MastodonOAuth.bookmarks(scopes) }
    /// Whether it asked for bookmarks and was not given them (#285).
    public var bookmarksRefused: Bool { MastodonParts.standing(.bookmarks, of: self) == .notGiven }
    /// Whether it may read notices (#323).
    public var notices: Bool { MastodonOAuth.notices(scopes) }
    /// Whether it may dismiss notices (#323).
    public var dismisses: Bool { MastodonOAuth.dismisses(scopes) }
    /// Whether it asked for notices and was not given them (#323).
    public var noticesRefused: Bool { MastodonParts.standing(.notices, of: self) == .notGiven }
}

/// This app's registration on one server, kept so a second sign-in does not register again.
/// Prints as its host, as the token does: the secret is a secret.
public struct MastodonApp: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let host: String
    public let clientID: String
    public let clientSecret: String
    /// The scopes it was registered for, or nothing for one kept before they were recorded. A
    /// page asks for some or all of them (#347); a registration that lacks a word the sign-in
    /// in hand asks for is made again — see `MastodonRegistration`.
    public let scopes: String?

    public init(host: String, clientID: String, clientSecret: String, scopes: String? = nil) {
        self.host = host.lowercased()
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }

    public var description: String { "MastodonApp(host: \(host))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host]) }
}

/// Where a Mastodon token and its app registration live. A protocol so `swift test` never
/// touches the real Keychain — see `ForumCredentialStore`.
public protocol MastodonTokenStore: Sendable {
    func token(host: String) throws -> MastodonToken?
    func save(_ token: MastodonToken) throws
    func forget(host: String) throws
    /// Forgets `token` only while it is still the one held for its host, and says whether it was.
    /// A late 401 for a token the reader has since replaced must not take the new one with it.
    func forget(_ token: MastodonToken) throws -> Bool
    /// Forgets `token` as a 401 from its source's account check does (#347) — only while it
    /// is still the one held, nothing where it was not — **and, in the same step under the
    /// store's one lock, deals with what was left for it**. Says how many left sign-ins it
    /// took out of the journal.
    ///
    /// - `saidBySource`: the source said so in its own words. The journal is untouched:
    ///   whoever goes through it next ends what was left, as the person was told.
    /// - Not said by the source — a page, a password asked for by something in front of it:
    ///   **every entry written down as left leaves the journal, unended**, before the
    ///   token goes. No moment is left in which the device shows a journal and no sign-in
    ///   for anything to end by, on a quit or in a pass already running.
    ///
    /// **Only what is left goes.** One owed an end, and one made and never kept, were to be
    /// ended whatever this 401 means, and stay to be; one lost is the person's own sign-in,
    /// which nothing ends but them. A journal that cannot be read or written stops it with
    /// the sign-in still held.
    func forget(_ token: MastodonToken, saidBySource: Bool) throws -> Int?
    /// What each held token's sign-in bought, **without reading one** (#69).
    ///
    /// **The scopes ride as an item attribute rather than inside the value, and that is the whole
    /// reason this is a separate question from `token(host:)`.** Reading a generic password's
    /// *data* is what makes macOS ask the reader to allow access; reading its attributes does not.
    /// A source page that had to open every token to say what may be done on its rows would put an
    /// access prompt in front of the launch screen, once per source — and in `swift test` it hangs
    /// on the first one. The scopes are not a secret; the token is.
    func grants() throws -> [String: MastodonGrant]
    /// The hosts whose sign-in may bookmark (#285), **without reading a token** — `grants()`'s
    /// rule and for its reason, read off the same attribute. Apart from `grants()` because it is
    /// another question: a sign-in made before bookmarks were asked for writes as it always did,
    /// and only lacks this.
    func bookmarking() throws -> Set<String>
    /// The hosts whose sign-in asked for bookmarks and was not given them (#285), **without
    /// reading a token** — so the row and Account stop offering to ask a source that has already
    /// answered, across a relaunch. A sign-in made before bookmarks were asked for is in neither
    /// this nor `bookmarking()`.
    func bookmarksRefused() throws -> Set<String>
    /// The hosts whose sign-in may read notices (#323), **without reading a token** —
    /// `bookmarking()`'s rule, off the same attribute. A sign-in made before notices were asked
    /// for is not among them, and does everything it did.
    func noticing() throws -> Set<String>
    /// The hosts whose sign-in may dismiss notices (#323), read the same way.
    func dismissing() throws -> Set<String>
    /// The hosts whose sign-in asked for notices and was not given them (#323), **without
    /// reading a token** — `bookmarksRefused()`'s rule: a sign-in that never asked is in neither
    /// this nor `noticing()`.
    func noticesRefused() throws -> Set<String>
    /// `noticing()`, `dismissing()` and `noticesRefused()` at once, each nothing where it could
    /// not be had — for whoever asks all three, so a store that answers them off one look makes
    /// that look once. A store that does not say is asked each in turn.
    func noticeGrants() -> MastodonNoticeGrants
    /// What each held sign-in is known to hold (#347), **without reading a token** — `grants()`'s
    /// rule and for its reason. Every look above is a reading of this one.
    ///
    /// **For drawing, and for nothing else.** These are the copies that ride beside the value.
    /// What decides anything — what a page asks, whether a sign-in is replaced — is read from
    /// the value itself: `parts(host:)`.
    func parts() throws -> [String: MastodonHeld]
    /// Writes down beside the held sign-in what `token` says of it, **in place and only while
    /// the token string held for its host is `token`'s**, and says whether it was. A fact
    /// `token` leaves out stays as held; the stamp stays.
    ///
    /// So nothing for `refused` leaves the refusals held as they are, other parts' included,
    /// and **only the empty string clears them**; words written replace the words held.
    /// Who the sign-in is, is written whole: an id named with no handle takes away the handle
    /// held.
    ///
    /// **Never `save`**, which deletes before it adds: a write that only notes something — a
    /// refusal, who the reader is — must not be able to lose the sign-in it is a note on. One
    /// that fails has changed nothing.
    func update(_ token: MastodonToken) throws -> Bool
    /// Keeps `token` only while the token string held for its host is still `held` — nothing,
    /// where none was — and says whether it was kept. **The read and the write are one step**
    /// under the lock every write of the store takes, so nothing files a sign-in between them
    /// from another thread (a package read back does, off the main actor).
    ///
    /// **Three ends, and the caller can tell them apart:**
    /// - `true`: `token` is the one held. Over a sign-in it is written in place, value and
    ///   every copy beside it at once, with no moment in which nothing is held; a fact `token`
    ///   leaves out is blanked, and a string not held before is filed under a new stamp.
    /// - `false`: the string held was not `held`. Nothing is written.
    /// - it throws: nothing is written, and **whatever was held is still held, exactly as it
    ///   was** — the read failed, or the keychain refused the write.
    ///
    /// **`refused` is `token`'s own**: the caller carries the refusals of the sign-in replaced
    /// across with `MastodonToken.carrying(refusedFrom:)`, or they are gone.
    func swap(expecting held: String?, with token: MastodonToken) throws -> Bool

    /// The sign-ins this device made at `host` and does not use (#347) — its journal: none,
    /// where there is none. **A set by token string**: a sign-in is in it once, in one state,
    /// and one that comes to be the sign-in held leaves it (`save`, `swap`).
    ///
    /// Kept apart from the sign-in held, in an item of its own, so a source ending that
    /// sign-in — which takes its item — leaves these to be ended by.
    func left(host: String) throws -> [MastodonLeft]
    /// Which hosts have a journal, **without reading one**.
    func leftHosts() throws -> Set<String>
    /// Writes `entry` into its host's journal, in place of the same sign-in in another state
    /// where it is there already. Under the lock every write of the store takes.
    func journal(_ entry: MastodonLeft) throws
    /// Writes `held` — the sign-in the person had, which could not be kept or put back —
    /// into its host's journal as lost: **the one way a lost entry is made**, since a lost
    /// one is filed again as the sign-in held (`restoreLost`). `accountID` is whose it is
    /// where the token itself does not say.
    func journalLost(_ held: MastodonToken, accountID: String?) throws
    /// Takes `entry`'s sign-in out of its host's journal, whatever state it is in there.
    func unjournal(_ entry: MastodonLeft) throws
    /// Forgets everything journalled for `host`.
    func forgetLeft(host: String) throws
    /// Files the sign-in journalled as lost for `host` again as the one held, **only where
    /// none is held**, and says whether it did. Kept, it leaves the journal.
    func restoreLost(host: String) throws -> Bool

    func app(host: String) throws -> MastodonApp?
    func save(_ app: MastodonApp) throws
    func forgetApp(host: String) throws
}

extension MastodonTokenStore {
    /// Which hosts hold a token, **without reading one** — the keys of `grants()`, so that the two
    /// answers are one query and cannot come to disagree about who is signed in.
    public func signedInHosts() throws -> Set<String> {
        Set(try grants().keys)
    }

    /// No host, for a store that does not say — and so none in any look read off it: nothing
    /// is bookmarked and no notice read through a sign-in nobody can show bought it, and a
    /// source nobody can show was asked is asked.
    public func parts() throws -> [String: MastodonHeld] { [:] }

    /// What one host's sign-in is known to hold, **read from the item's value** — what a
    /// decision reads, where `parts()` is for drawing.
    public func parts(host: String) throws -> MastodonHeld? {
        try token(host: host)?.held
    }

    public func bookmarking() throws -> Set<String> { try hosts(\.bookmarks) }

    public func bookmarksRefused() throws -> Set<String> { try hosts(\.bookmarksRefused) }

    public func noticing() throws -> Set<String> { try hosts(\.notices) }

    public func dismissing() throws -> Set<String> { try hosts(\.dismisses) }

    public func noticesRefused() throws -> Set<String> { try hosts(\.noticesRefused) }

    private func hosts(_ holds: (MastodonHeld) -> Bool) throws -> Set<String> {
        Set(try parts().filter { holds($0.value) }.keys)
    }

    /// Nothing written, for a store that does not say how it writes in place: the sign-in
    /// held stands, and the caller hears that the note was not taken.
    public func update(_ token: MastodonToken) throws -> Bool {
        throw ForumCredentialError.keychain(errSecUnimplemented)
    }

    /// Nothing kept, for a store that cannot make the read and the write one step.
    public func swap(expecting held: String?, with token: MastodonToken) throws -> Bool {
        throw ForumCredentialError.keychain(errSecUnimplemented)
    }

    /// A plain forgetting, for a store that keeps no journal to deal with.
    public func forget(_ token: MastodonToken, saidBySource: Bool) throws -> Int? {
        try forget(token) ? 0 : nil
    }

    /// No journal, for a store that does not say it keeps one.
    public func left(host: String) throws -> [MastodonLeft] { [] }

    public func leftHosts() throws -> Set<String> { [] }

    /// Nothing written, for a store that keeps no journal — so a sign-in whose keeping
    /// turns on a note being taken first is not kept by one.
    public func journal(_ entry: MastodonLeft) throws {
        throw ForumCredentialError.keychain(errSecUnimplemented)
    }

    public func journalLost(_ held: MastodonToken, accountID: String?) throws {
        throw ForumCredentialError.keychain(errSecUnimplemented)
    }

    public func unjournal(_ entry: MastodonLeft) throws {}

    public func forgetLeft(host: String) throws {}

    public func restoreLost(host: String) throws -> Bool { false }

    /// The three asked one by one, each failing by itself.
    public func noticeGrants() -> MastodonNoticeGrants {
        MastodonNoticeGrants(
            noticing: try? noticing(), dismissing: try? dismissing(), refused: try? noticesRefused()
        )
    }
}

/// What the held sign-ins may do with notices (#323), by host: `MastodonTokenStore`'s three
/// answers about them together. One that is nothing could not be read, which is not "no host".
public struct MastodonNoticeGrants: Equatable, Sendable {
    public let noticing: Set<String>?
    public let dismissing: Set<String>?
    public let refused: Set<String>?

    public init(noticing: Set<String>?, dismissing: Set<String>?, refused: Set<String>?) {
        self.noticing = noticing
        self.dismissing = dismissing
        self.refused = refused
    }
}

/// The query dictionaries, built where a test can read them back.
///
/// A generic password and not an internet password: a token is not a website's password, must
/// never be offered by AutoFill on the server's own login form, and cannot collide with
/// `ForumKeychain`'s items. The service is what makes an item this app's — every query is scoped
/// by it, so nothing here can read or delete another program's item.
///
/// **Where the item actually lives differs by platform.** On iOS it is in the data-protection
/// keychain and `WhenUnlockedThisDeviceOnly` holds: never synced, never restored onto other
/// hardware. On macOS, as with the forum password, it lands in the file-based login keychain —
/// `kSecUseDataProtectionKeychain` needs a team-signed build, and an ad-hoc Debug build gets
/// -34018. That keychain never syncs, but it ignores the accessibility attribute, so
/// "this device only" is not enforced there. Once the app is team-signed, adding
/// `kSecUseDataProtectionKeychain` to every query here moves it.
public enum MastodonKeychain {
    public static let service = "fediqo.mastodon"
    /// The app registration's items, apart from the tokens so that listing who is signed in never
    /// counts a registration.
    public static let appService = "fediqo.mastodon.app"

    /// `kSecAttrSynchronizable` written false rather than left to a default, and
    /// `WhenUnlockedThisDeviceOnly`: the token does not follow the Apple account to another
    /// device, and is not restored from a backup onto other hardware.
    public static func lookup(host: String, service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.lowercased(),
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// **The scopes ride as an attribute as well as inside the value** (#69), so that what may be
    /// done on a source is readable without reading the secret — see `MastodonTokenStore.grants()`
    /// for why that distinction is the whole point.
    ///
    /// **What this rests on, and what no test here can see:** that `kSecAttrGeneric` written with
    /// `SecItemAdd` comes back from an attributes-only `SecItemCopyMatching`. That round trip was
    /// verified by hand against the real Keychain on macOS and iOS; `swift test` may not touch the
    /// Keychain at all, so the suite pins only the dictionary this file builds and CI can never
    /// prove the other half. `KeychainMastodonTokens.grants()` says which way it fails.
    ///
    /// **Absent, and not empty, for a token kept before the question** — see `MastodonGrant`. The
    /// attribute and the value cannot drift: both are written from one token in one call, and
    /// `save` deletes before it adds, so no second item with a stale one can exist. A write in
    /// place writes both from one token too (`changes(for:)`), and blanks each copy the token
    /// has no fact for, so it leaves no attribute behind that its value no longer holds.
    public static func attributes(for token: MastodonToken) -> [String: Any] {
        item(lookup(host: token.host), label: token.host, value: Wire.encode(token))
            .merging(noted(token)) { _, noted in noted }
    }

    /// What a write in place writes over an item (#347): its value and the copies beside it.
    /// **Nothing of where the item is kept or how it is protected** — no class, service,
    /// account, label or accessibility — so those stay as the item was made with.
    ///
    /// **Every copy is written, blank where the token has no such fact**: an update cannot
    /// take an attribute off an item, and one left out would stay as the sign-in before left
    /// it. `held(_:)` reads a blank one as not there.
    public static func changes(for token: MastodonToken) -> [String: Any] {
        let blank: [String: Any] = [
            kSecAttrGeneric as String: Data(), kSecAttrComment as String: "", kSecAttrDescription as String: "",
        ]
        var changes = blank.merging(noted(token)) { _, noted in noted }
        changes[kSecValueData as String] = Wire.encode(token)
        return changes
    }

    /// The copies that ride beside a token's value, none of them a secret.
    private static func noted(_ token: MastodonToken) -> [String: Any] {
        var noted: [String: Any] = [:]
        if let scopes = token.scopes {
            noted[kSecAttrGeneric as String] = Data(scopes.utf8)
        }
        // What the sign-in asked for (#285), beside what it was given and for the same reason:
        // readable without the secret. Scope names, which are not one. **Fails the safe way** if
        // it ever stops coming back: a source that had refused bookmarks is offered the question
        // once more, and nothing is widened.
        if let asked = token.asked {
            noted[kSecAttrComment as String] = asked
        }
        // On macOS's file keychain this one is kept in plain text, as every attribute there is,
        // and Keychain Access shows it as the item's "Kind". A random stamp and scope words:
        // nothing in it is made from the token.
        if let mark = mark(stamp: token.stamp, refused: token.refused) {
            noted[kSecAttrDescription as String] = mark
        }
        return noted
    }

    /// The stamp and what was refused (#347), as the one attribute they share: the stamp, then
    /// a space and the refused words where there are any. One attribute because a generic
    /// password has one string left unused; the stamp first because it holds no space.
    ///
    /// **Unproven in the way `kSecAttrGeneric` was, until looked at on a device.** If it stops
    /// coming back, a part refused on the source's page reads as never asked — the question
    /// is offered once more — and a sign-in replaced from outside the session is not seen to
    /// have changed until the next look at its value. Nothing is widened.
    static func mark(stamp: String?, refused: String?) -> String? {
        guard let refused else { return stamp }
        return "\(stamp ?? "") \(refused)"
    }

    public static func attributes(for app: MastodonApp) -> [String: Any] {
        item(
            lookup(host: app.host, service: appService), label: "\(app.host) app",
            value: Wire.encode(app)
        )
    }

    private static func item(_ lookup: [String: Any], label: String, value: Data) -> [String: Any] {
        var attributes = lookup
        attributes[kSecAttrLabel as String] = "\(Fediqo.name) — \(label)"
        attributes[kSecAttrAccessible as String] = ForumKeychain.accessibility
        attributes[kSecValueData as String] = value
        return attributes
    }

    /// What one item's attributes say its sign-in is known to hold: the one look every
    /// reading below is made off. An attribute that is not there, or is blank — what a write
    /// in place leaves of a fact the sign-in before had (`changes(for:)`) — is a fact not
    /// written down.
    public static func held(_ row: [String: Any]) -> MastodonHeld {
        let scopes = (row[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) }
        let asked = row[kSecAttrComment as String] as? String
        let mark = (row[kSecAttrDescription as String] as? String ?? "")
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let stamp = mark.first.flatMap { $0.isEmpty ? nil : String($0) }
        return MastodonHeld(
            scopes: scopes?.isEmpty == true ? nil : scopes, asked: asked?.isEmpty == true ? nil : asked,
            refused: mark.count > 1 ? String(mark[1]) : nil, stamp: stamp
        )
    }

    /// What one item's attributes say its sign-in bought.
    public static func grant(_ row: [String: Any]) -> MastodonGrant { held(row).grant }

    /// Whether one item's attributes say its sign-in may bookmark (#285). A token kept before
    /// the scopes were written down says nothing, and nothing is no.
    public static func bookmarks(_ row: [String: Any]) -> Bool { held(row).bookmarks }

    /// Whether one item's attributes say its sign-in asked for bookmarks and was not given them
    /// (#285): asked is written down, and what it was given leaves them out.
    public static func bookmarksRefused(_ row: [String: Any]) -> Bool { held(row).bookmarksRefused }

    /// Whether one item's attributes say its sign-in may read notices (#323). Nothing written
    /// down is no, as it is for bookmarks.
    public static func notices(_ row: [String: Any]) -> Bool { held(row).notices }

    /// Whether one item's attributes say its sign-in may dismiss notices (#323).
    public static func dismisses(_ row: [String: Any]) -> Bool { held(row).dismisses }

    /// Whether one item's attributes say its sign-in asked for notices and was not given them
    /// (#323): asked is written down, and what it was given leaves them out.
    public static func noticesRefused(_ row: [String: Any]) -> Bool { held(row).noticesRefused }

    /// Every host this app holds a token for, attributes only — no `kSecReturnData`.
    public static func allItems() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
    }

    /// The items' values. The one place a token or a registration is turned into bytes and back.
    enum Wire {
        private struct Token: Codable {
            var accessToken: String
            var clientID: String
            var clientSecret: String
            /// Absent in an item kept before a sign-in asked about writing — which is what makes
            /// that reader one this app still owes the question to.
            var scopes: String?
            /// Absent in an item kept before what a sign-in asked for was written down (#285).
            var asked: String?
            /// Absent in an item kept before whose sign-in it is was written down, and until
            /// its source has said. Optional and ignored by a build that does not know them.
            var accountID: String?
            var handle: String?
            /// Absent in an item kept before a refusal on the source's page, or the filing's
            /// stamp, was written down (#347) — and ignored by a build that knows neither,
            /// which reads everything above as it did.
            var refused: String?
            var stamp: String?
        }

        private struct App: Codable {
            var clientID: String
            var clientSecret: String
            /// Absent in an item kept before the scopes were recorded.
            var scopes: String?
        }

        static func encode(_ token: MastodonToken) -> Data {
            let value = Token(
                accessToken: token.accessToken, clientID: token.clientID,
                clientSecret: token.clientSecret, scopes: token.scopes, asked: token.asked,
                accountID: token.accountID, handle: token.handle,
                refused: token.refused, stamp: token.stamp
            )
            return (try? JSONEncoder().encode(value)) ?? Data()
        }

        static func encode(_ app: MastodonApp) -> Data {
            let value = App(clientID: app.clientID, clientSecret: app.clientSecret, scopes: app.scopes)
            return (try? JSONEncoder().encode(value)) ?? Data()
        }

        static func decode(_ data: Data, host: String) -> MastodonToken? {
            guard let value = try? JSONDecoder().decode(Token.self, from: data),
                  !value.accessToken.isEmpty
            else { return nil }
            return MastodonToken(
                host: host, accessToken: value.accessToken, clientID: value.clientID,
                clientSecret: value.clientSecret, scopes: value.scopes, asked: value.asked,
                refused: value.refused, accountID: value.accountID, handle: value.handle
            ).stamped(value.stamp)
        }

        static func decodeApp(_ data: Data, host: String) -> MastodonApp? {
            guard let value = try? JSONDecoder().decode(App.self, from: data),
                  !value.clientID.isEmpty
            else { return nil }
            return MastodonApp(
                host: host, clientID: value.clientID, clientSecret: value.clientSecret, scopes: value.scopes
            )
        }
    }
}

/// What a keychain does to the one item a host's sign-in is kept in: a call each, and no rule
/// among them. The rules of keeping a sign-in are written once over these (`TokenFiling`), so
/// the store the tests run and the real one cannot come to differ in them.
protocol TokenItems: Sendable {
    func token(host: String) throws -> MastodonToken?
    /// Callers delete first: an add over an item already there changes nothing.
    func add(_ token: MastodonToken) throws
    /// Writes `token` over the item already there — its value and every copy beside it, those
    /// it has no fact for blanked — with no moment in which nothing is held.
    func change(_ token: MastodonToken) throws
    func delete(host: String) throws
    /// The host's journal as it is kept: none, where there is no item.
    func left(host: String) throws -> [MastodonLeft]
    /// Callers add only where there is no journal: an add over one already there changes
    /// nothing.
    func add(left entries: [MastodonLeft], host: String) throws
    /// Writes `entries` over the journal already there, whole and in place: one that fails
    /// has left the journal as it was.
    func change(left entries: [MastodonLeft], host: String) throws
    func deleteLeft(host: String) throws
}

/// Every write of a sign-in, under the store's one lock (#347).
///
/// **One lock, and every write takes it.** Keeping a fresh sign-in only while the one it
/// replaces is still the one held is a read and then a write. A package read back files its
/// sign-ins from off the main actor, through `save`: without the lock it could land between
/// the two, and the fresh sign-in would be kept over one nobody compared it with.
struct TokenFiling: Sendable {
    let items: any TokenItems
    let lock: NSLock
    /// Run inside `swap`, under the lock, between its read and its write. For tests.
    var betweenReadAndWrite: (@Sendable () -> Void)?

    func save(_ token: MastodonToken) throws {
        try lock.withLock {
            // The value is read, once, because only it says whether the string is the one
            // held — which is what the stamp turns on. A read that fails stops the save with
            // what is held untouched: gone on as if nothing were held, it would file an
            // unchanged sign-in under a new stamp, and that reads as a sign-in replaced.
            try put(token, over: try items.token(host: token.host))
            unjournal(held: token)
        }
    }

    func forget(host: String) throws {
        try lock.withLock { try items.delete(host: host) }
    }

    func forget(_ token: MastodonToken) throws -> Bool {
        try lock.withLock {
            guard try items.token(host: token.host)?.accessToken == token.accessToken else { return false }
            try items.delete(host: token.host)
            return true
        }
    }

    func forget(_ token: MastodonToken, saidBySource: Bool) throws -> Int? {
        try lock.withLock {
            guard try items.token(host: token.host)?.accessToken == token.accessToken else { return nil }
            var dropped = 0
            if !saidBySource {
                // Before the token goes: a write that fails leaves the sign-in held.
                let all = try items.left(host: token.host)
                let kept = all.filter { $0.state != .left }
                dropped = all.count - kept.count
                if dropped > 0 { try write(left: kept, host: token.host) }
            }
            try items.delete(host: token.host)
            return dropped
        }
    }

    func update(_ token: MastodonToken) throws -> Bool {
        try lock.withLock {
            guard let held = try items.token(host: token.host), held.accessToken == token.accessToken else {
                return false
            }
            try items.change(token.over(held).stamped(held.stamp ?? Self.stamp()))
            return true
        }
    }

    func swap(expecting: String?, with token: MastodonToken) throws -> Bool {
        try lock.withLock {
            let held = try items.token(host: token.host)
            guard held?.accessToken == expecting else { return false }
            betweenReadAndWrite?()
            if let held {
                // Over a sign-in, in place: a write that fails has let go of nothing.
                try items.change(Self.filed(token, over: held))
            } else {
                try put(token, over: nil)
            }
            unjournal(held: token)
            return true
        }
    }

    func journal(_ entry: MastodonLeft) throws {
        try lock.withLock { try note(entry) }
    }

    func journalLost(_ held: MastodonToken, accountID: String?) throws {
        try lock.withLock { try note(.lost(held, accountID: accountID)) }
    }

    /// `entry` in its host's journal, in place of the same sign-in in another state. Called
    /// under the lock.
    private func note(_ entry: MastodonLeft) throws {
        let others = try items.left(host: entry.host).filter { !$0.isSame(as: entry) }
        try write(left: others + [entry], host: entry.host)
    }

    func unjournal(_ entry: MastodonLeft) throws {
        try lock.withLock {
            let all = try items.left(host: entry.host)
            let others = all.filter { !$0.isSame(as: entry) }
            if others.count != all.count { try write(left: others, host: entry.host) }
        }
    }

    func forgetLeft(host: String) throws {
        try lock.withLock { try write(left: [], host: host) }
    }

    /// Writes a host's journal whole — **over the one already there, in place**, and as a
    /// new item only where there was none. Called under the lock. A write that fails has
    /// left every entry written before it where it was, and whoever asked hears so: a
    /// delete and then an add would lose them all to the add failing. None takes the item
    /// away.
    private func write(left entries: [MastodonLeft], host: String) throws {
        guard !entries.isEmpty else { return try items.deleteLeft(host: host) }
        do {
            try items.change(left: entries, host: host)
        } catch ForumCredentialError.keychain(errSecItemNotFound) {
            try items.add(left: entries, host: host)
        }
    }

    func restoreLost(host: String) throws -> Bool {
        try lock.withLock {
            guard try items.token(host: host) == nil,
                  let lost = try items.left(host: host).first(where: { $0.state == .lost })
            else { return false }
            try put(lost.restored, over: nil)
            unjournal(held: lost.restored)
            return true
        }
    }

    /// A sign-in that has come to be the one held leaves the journal: it is a set by token
    /// string. Called under the lock, **after the sign-in is kept, so it does not fail the
    /// keeping**: a write that fails has left the journal whole (`write`), the one that
    /// could not be taken out stays, and is harmless there — nothing ends a sign-in while
    /// it is the one held, and the next look at the journal takes it out.
    private func unjournal(held token: MastodonToken) {
        guard let all = try? items.left(host: token.host) else { return }
        let others = all.filter { !$0.isToken(token) }
        if others.count != all.count { try? write(left: others, host: token.host) }
    }

    /// Deletes, then adds — so no second item with stale attributes can exist.
    private func put(_ token: MastodonToken, over held: MastodonToken?) throws {
        try items.delete(host: token.host)
        try items.add(Self.filed(token, over: held))
    }

    /// `token` under the stamp it is filed with: the held one where the string is the one held,
    /// the token's own where it was filed before (one being put back), and a new one for a
    /// string filed for the first time.
    private static func filed(_ token: MastodonToken, over held: MastodonToken?) -> MastodonToken {
        let same = held?.accessToken == token.accessToken
        return token.stamped((same ? held?.stamp : nil) ?? token.stamp ?? stamp())
    }

    /// Sixteen bytes off the system's generator: the stamp is random, never a clock or a count.
    static func stamp() -> String {
        PKCE.random(bytes: 16)
    }
}

/// The real one.
public struct KeychainMastodonTokens: MastodonTokenStore {
    /// One for the process, not one a store: every `KeychainMastodonTokens` is the same Keychain.
    private static let writing = NSLock()

    public init() {}

    private var filing: TokenFiling { TokenFiling(items: Items(), lock: Self.writing) }

    public func token(host: String) throws -> MastodonToken? {
        try Items().token(host: host)
    }

    public func save(_ token: MastodonToken) throws {
        try filing.save(token)
    }

    public func forget(host: String) throws {
        try filing.forget(host: host)
    }

    public func forget(_ token: MastodonToken) throws -> Bool {
        try filing.forget(token)
    }

    public func forget(_ token: MastodonToken, saidBySource: Bool) throws -> Int? {
        try filing.forget(token, saidBySource: saidBySource)
    }

    public func update(_ token: MastodonToken) throws -> Bool {
        try filing.update(token)
    }

    public func swap(expecting held: String?, with token: MastodonToken) throws -> Bool {
        try filing.swap(expecting: held, with: token)
    }

    public func left(host: String) throws -> [MastodonLeft] {
        try Items().left(host: host)
    }

    /// One query, attributes only: which hosts have a journal is read with no value.
    public func leftHosts() throws -> Set<String> {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(MastodonKeychain.allLeft() as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
        let rows = item as? [[String: Any]] ?? []
        return Set(rows.compactMap { ($0[kSecAttrAccount as String] as? String)?.lowercased() })
    }

    public func journal(_ entry: MastodonLeft) throws {
        try filing.journal(entry)
    }

    public func journalLost(_ held: MastodonToken, accountID: String?) throws {
        try filing.journalLost(held, accountID: accountID)
    }

    public func unjournal(_ entry: MastodonLeft) throws {
        try filing.unjournal(entry)
    }

    public func forgetLeft(host: String) throws {
        try filing.forgetLeft(host: host)
    }

    public func restoreLost(host: String) throws -> Bool {
        try filing.restoreLost(host: host)
    }

    /// **The one unproven step in the grant model, named here rather than left to be found.**
    /// Every row's answer to what may be done on its source comes from `kSecAttrGeneric` arriving
    /// back in these rows — see `MastodonKeychain.attributes(for:)`, which writes it. The round
    /// trip was verified by hand against the real Keychain on macOS and iOS and **cannot be
    /// verified by CI**: `swift test` may not touch the Keychain, so what the suite pins is the
    /// dictionary handed to `SecItemAdd`, not what `SecItemCopyMatching` hands back.
    ///
    /// **Which way it fails, if that attribute ever stops coming back:** `MastodonKeychain.grant`
    /// reads a missing one as `.unasked`, so every host degrades together — Account names every
    /// source as one that signed in before the question, every row says read, and nothing writes.
    /// No token is lost, no reading changes, and nothing is widened; the app asks the question
    /// again. That is the safe direction, and it is the reason this rests where it does.
    public func grants() throws -> [String: MastodonGrant] {
        try parts().mapValues(\.grant)
    }

    /// One query, attributes only. Who may bookmark, who may read or dismiss notices and who
    /// was refused either are read off it, with `grants()`'s failure direction: an attribute
    /// that stops coming back is a host that may not, and the place asks again.
    public func parts() throws -> [String: MastodonHeld] {
        try rows().mapValues(MastodonKeychain.held)
    }

    /// One query for the three: they are read off the same rows, so they are had or not together.
    public func noticeGrants() -> MastodonNoticeGrants {
        guard let parts = try? parts() else {
            return MastodonNoticeGrants(noticing: nil, dismissing: nil, refused: nil)
        }
        return MastodonNoticeGrants(
            noticing: Set(parts.filter(\.value.notices).keys),
            dismissing: Set(parts.filter(\.value.dismisses).keys),
            refused: Set(parts.filter(\.value.noticesRefused).keys)
        )
    }

    /// Every held token's attributes, by host, and never a value.
    private func rows() throws -> [String: [String: Any]] {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(MastodonKeychain.allItems() as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
        guard let rows = item as? [[String: Any]] else { return [:] }
        return rows.reduce(into: [:]) { found, row in
            guard let host = (row[kSecAttrAccount as String] as? String)?.lowercased() else {
                return
            }
            found[host] = row
        }
    }

    public func app(host: String) throws -> MastodonApp? {
        try Self.read(MastodonKeychain.lookup(host: host, service: MastodonKeychain.appService))
            .flatMap { MastodonKeychain.Wire.decodeApp($0, host: host) }
    }

    public func save(_ app: MastodonApp) throws {
        try Self.writing.withLock {
            try Self.delete(MastodonKeychain.lookup(host: app.host, service: MastodonKeychain.appService))
            try Self.add(MastodonKeychain.attributes(for: app))
        }
    }

    public func forgetApp(host: String) throws {
        try Self.writing.withLock {
            try Self.delete(MastodonKeychain.lookup(host: host, service: MastodonKeychain.appService))
        }
    }

    /// The Keychain's own calls on a token's item, one each.
    private struct Items: TokenItems {
        func token(host: String) throws -> MastodonToken? {
            try KeychainMastodonTokens.read(MastodonKeychain.lookup(host: host)).flatMap {
                MastodonKeychain.Wire.decode($0, host: host)
            }
        }

        func add(_ token: MastodonToken) throws {
            try KeychainMastodonTokens.add(MastodonKeychain.attributes(for: token))
        }

        func change(_ token: MastodonToken) throws {
            try KeychainMastodonTokens.change(MastodonKeychain.lookup(host: token.host), MastodonKeychain.changes(for: token))
        }

        func delete(host: String) throws {
            try KeychainMastodonTokens.delete(MastodonKeychain.lookup(host: host))
        }

        /// **A value that is no journal is an error, not an empty one**: read as empty, the
        /// next write would put a journal of one over sign-ins nobody had ended.
        func left(host: String) throws -> [MastodonLeft] {
            let lookup = MastodonKeychain.lookup(host: host, service: MastodonKeychain.leftService)
            guard let data = try KeychainMastodonTokens.read(lookup) else { return [] }
            guard let entries = MastodonKeychain.LeftWire.decode(data, host: host) else {
                throw ForumCredentialError.keychain(errSecDecode)
            }
            return entries
        }

        func add(left entries: [MastodonLeft], host: String) throws {
            try KeychainMastodonTokens.add(MastodonKeychain.attributes(forLeft: entries, host: host))
        }

        func change(left entries: [MastodonLeft], host: String) throws {
            try KeychainMastodonTokens.change(
                MastodonKeychain.lookup(host: host, service: MastodonKeychain.leftService),
                MastodonKeychain.changes(forLeft: entries)
            )
        }

        func deleteLeft(host: String) throws {
            try KeychainMastodonTokens.delete(MastodonKeychain.lookup(host: host, service: MastodonKeychain.leftService))
        }
    }

    private static func read(_ lookup: [String: Any]) throws -> Data? {
        var query = lookup
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
        return item as? Data
    }

    /// Callers delete first: `SecItemAdd` over an existing item changes nothing.
    private static func add(_ attributes: [String: Any]) throws {
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
    }

    /// Writes `changes` over the item already there; one that is not there is said so.
    private static func change(_ lookup: [String: Any], _ changes: [String: Any]) throws {
        let status = SecItemUpdate(lookup as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
    }

    private static func delete(_ lookup: [String: Any]) throws {
        let status = SecItemDelete(lookup as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ForumCredentialError.keychain(status)
        }
    }
}

/// The one tests and previews use. Never written to disk. **Its writes are the real store's**
/// (`TokenFiling`), over a dictionary where that one has the Keychain.
public final class MemoryMastodonTokens: MastodonTokenStore, @unchecked Sendable {
    /// A call the keychain underneath can be made to refuse. For tests.
    enum Call: Sendable {
        case reading, adding, changing
        /// Reading a host's journal, and writing it — as a new item or over the one there.
        case readingLeft, leaving
    }

    /// Its own lock is for the dictionary alone; the store's one lock is `writing`, outside it.
    private final class Items: TokenItems, @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: MastodonToken] = [:]
        private var journals: [String: [MastodonLeft]] = [:]
        private var refusals: [Call: (after: Int, times: Int)] = [:]

        var all: [String: MastodonToken] { lock.withLock { held } }
        var journalled: Set<String> { lock.withLock { Set(journals.keys) } }

        func refuse(_ call: Call, times: Int, after: Int) {
            lock.withLock { refusals[call] = (after, times) }
        }

        /// As a locked device's Keychain refuses.
        private func pass(_ call: Call) throws {
            guard let due = refusals[call], due.times > 0 else { return }
            guard due.after == 0 else {
                refusals[call] = (due.after - 1, due.times)
                return
            }
            refusals[call] = (0, due.times - 1)
            throw ForumCredentialError.keychain(errSecInteractionNotAllowed)
        }

        func token(host: String) throws -> MastodonToken? {
            try lock.withLock {
                try pass(.reading)
                return held[host.lowercased()]
            }
        }

        func add(_ token: MastodonToken) throws {
            try lock.withLock {
                try pass(.adding)
                held[token.host] = token
            }
        }

        func change(_ token: MastodonToken) throws {
            try lock.withLock {
                try pass(.changing)
                guard held[token.host] != nil else { throw ForumCredentialError.keychain(errSecItemNotFound) }
                held[token.host] = token
            }
        }

        func delete(host: String) throws {
            lock.withLock { held[host.lowercased()] = nil }
        }

        func left(host: String) throws -> [MastodonLeft] {
            try lock.withLock {
                try pass(.readingLeft)
                return journals[host.lowercased()] ?? []
            }
        }

        func add(left entries: [MastodonLeft], host: String) throws {
            try lock.withLock {
                try pass(.leaving)
                journals[host.lowercased()] = entries
            }
        }

        func change(left entries: [MastodonLeft], host: String) throws {
            try lock.withLock {
                guard journals[host.lowercased()] != nil else { throw ForumCredentialError.keychain(errSecItemNotFound) }
                try pass(.leaving)
                journals[host.lowercased()] = entries
            }
        }

        /// Refused by nothing, as taking a sign-in's item away is: what a keychain refuses
        /// of a journal is the writing of it.
        func deleteLeft(host: String) throws {
            lock.withLock { journals[host.lowercased()] = nil }
        }
    }

    private let items = Items()
    private let writing: NSLock
    private var apps: [String: MastodonApp] = [:]
    /// Run inside `swap`, under the lock, between its read and its write. For tests.
    var betweenReadAndWrite: (@Sendable () -> Void)?

    public init() {
        writing = NSLock()
    }

    /// A store whose one lock a test can watch.
    init(writing: NSLock) {
        self.writing = writing
    }

    private var filing: TokenFiling {
        TokenFiling(items: items, lock: writing, betweenReadAndWrite: betweenReadAndWrite)
    }

    /// Files `token` as a build from before the stamp left one: with no mark of its filing.
    /// For tests.
    func fileUnstamped(_ token: MastodonToken) throws {
        try items.delete(host: token.host)
        try items.add(token.stamped(nil))
    }

    /// Makes the keychain underneath refuse the next `times` of one call, as a locked device's
    /// does — once it has let `after` of them through. A refused add is a `save` that has
    /// already let go of what was held.
    func refuse(_ call: Call, times: Int = 1, after: Int = 0) {
        items.refuse(call, times: times, after: after)
    }

    public func token(host: String) throws -> MastodonToken? {
        try items.token(host: host)
    }

    public func save(_ token: MastodonToken) throws {
        try filing.save(token)
    }

    public func forget(host: String) throws {
        try filing.forget(host: host)
    }

    public func forget(_ token: MastodonToken) throws -> Bool {
        try filing.forget(token)
    }

    public func forget(_ token: MastodonToken, saidBySource: Bool) throws -> Int? {
        try filing.forget(token, saidBySource: saidBySource)
    }

    public func update(_ token: MastodonToken) throws -> Bool {
        try filing.update(token)
    }

    public func swap(expecting held: String?, with token: MastodonToken) throws -> Bool {
        try filing.swap(expecting: held, with: token)
    }

    public func left(host: String) throws -> [MastodonLeft] {
        try items.left(host: host)
    }

    public func leftHosts() throws -> Set<String> {
        items.journalled
    }

    public func journal(_ entry: MastodonLeft) throws {
        try filing.journal(entry)
    }

    public func journalLost(_ held: MastodonToken, accountID: String?) throws {
        try filing.journalLost(held, accountID: accountID)
    }

    public func unjournal(_ entry: MastodonLeft) throws {
        try filing.unjournal(entry)
    }

    public func forgetLeft(host: String) throws {
        try filing.forgetLeft(host: host)
    }

    public func restoreLost(host: String) throws -> Bool {
        try filing.restoreLost(host: host)
    }

    public func grants() throws -> [String: MastodonGrant] {
        items.all.mapValues(\.grant)
    }

    public func parts() throws -> [String: MastodonHeld] {
        items.all.mapValues(\.held)
    }

    public func app(host: String) throws -> MastodonApp? {
        writing.withLock { apps[host.lowercased()] }
    }

    public func save(_ app: MastodonApp) throws {
        writing.withLock { apps[app.host] = app }
    }

    public func forgetApp(host: String) throws {
        _ = writing.withLock { apps.removeValue(forKey: host.lowercased()) }
    }
}
