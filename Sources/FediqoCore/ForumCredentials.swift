import Foundation
import Security

/// A username and password the reader asked this device to keep for one forum.
///
/// **It prints as nothing.** Swift synthesises a reflective description for every struct, so
/// `print(credential)`, `"\(credential)"`, an `assert` message, an `os_log` interpolation and
/// the debugger's own `po` would each have spelled the password out in full — and the one place
/// a secret most often escapes is an error path somebody wrote in a hurry. Overriding both
/// description protocols makes that impossible to do by accident: the only way to get the
/// password out of this type is to ask for `.password` by name, which is a line a reviewer can
/// see. There is deliberately no `Codable` conformance either, for the same reason.
public struct ForumCredential: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let host: String
    public let username: String
    public let password: String

    public init(host: String, username: String, password: String) {
        // Folded where it enters, decision 21: every consumer below compares exactly.
        self.host = host.lowercased()
        self.username = username
        self.password = password
    }

    public var description: String { "ForumCredential(host: \(host), username: \(username))" }
    public var debugDescription: String { description }

    /// Whether this is worth storing at all. A forum with an empty password is a forum the
    /// reader has not actually signed in to, and half a credential saved is a silent automatic
    /// sign-in that fails forever.
    public var isComplete: Bool { !host.isEmpty && !username.isEmpty && !password.isEmpty }
}

public enum ForumCredentialError: Error, Equatable, Sendable {
    /// The Keychain refused, with its own `OSStatus`. **The status and nothing else** — no
    /// query, no attributes, and above all no credential, because an error is the thing most
    /// likely to be logged.
    case keychain(OSStatus)
    case incomplete
}

/// Where a saved forum password lives.
///
/// A protocol so that `swift test` never touches the real Keychain. That is not test purity: a
/// Keychain call from an unsigned test binary can prompt, can fail with `errSecMissingEntitlement`
/// on one machine and succeed on the next, and can leave an item behind that the next run finds —
/// which is three ways to write the fourth flaky test this branch ships. What is tested here is
/// the query this builds (`ForumKeychain`), which is where the decisions actually are; that the
/// Keychain honours it is verified by running the app.
public protocol ForumCredentialStore: Sendable {
    func credential(host: String) throws -> ForumCredential?
    func save(_ credential: ForumCredential) throws
    func forget(host: String) throws
    /// Which hosts have something saved, **without reading a single password**. The Preferences
    /// pane needs to draw "there is a password here" beside a server and must never have the
    /// password in order to do it.
    func savedHosts() throws -> Set<String>
}

/// The query dictionaries, built where they can be read back.
///
/// Split out from the store so the decisions in them are assertable. Every one of the four
/// attributes below is a decision somebody could quietly reverse, and three of them fail
/// invisibly if they are: an item scoped to the wrong server is handed to the wrong forum, an
/// item left synchronisable leaves the reader's forum password on every device on their Apple
/// account, and an accessibility class of `AfterFirstUnlock` hands it to anybody holding a
/// locked phone's backup. None of those produce an error anywhere.
public enum ForumKeychain {
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — D23, and the strictest class that still
    /// lets the app read it while the reader is using it. `ThisDeviceOnly` also keeps it out of
    /// an encrypted backup restored onto different hardware.
    ///
    /// Bridged to `String` rather than left as the `CFString` the framework declares: a `CFString`
    /// is not `Sendable`, so a constant of that type cannot be a `static let` under Swift 6 at
    /// all. The bridge back across the call is free and `Security` reads either.
    public static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    /// The mark that makes an item **this app's**, written on everything saved and required by
    /// everything read, listed or deleted.
    ///
    /// **This is not belt and braces. Without it, this type deletes other programs' passwords.**
    /// Measured in a real sandboxed `.app`: a query of class, server and protocol alone answered
    /// with `ghcr.io`, `gitlab.com` and `index.docker.io` — internet passwords belonging to Docker
    /// and two git credential helpers, sitting in the same login keychain. So `savedHosts()` was
    /// reporting other software's servers; `credential(host:)` would have handed back another
    /// program's password for any host the reader happened to add; and — the one that cannot be
    /// undone — `forget(host:)` issues `SecItemDelete` under that same query, so a reader pressing
    /// **Clear** on a source called `gitlab.com` would have deleted their git credential. `save`
    /// calls `forget` first, so saving would have done it too.
    ///
    /// A correctly team-signed sandboxed build has a keychain access group that would also have
    /// stopped it. That is a build setting enforcing this type's invariant, which is precisely the
    /// shape this branch already wrote down: put the guarantee in the data, not in a rule each
    /// consumer — or each signing configuration — has to remember.
    ///
    /// `kSecAttrSecurityDomain` is part of an internet password's primary key, so it both marks
    /// the item and keeps Fediqo's entry for a host distinct from anybody else's for the same one.
    public static let domain = "fediqo.forum"

    /// Finds the item for one host **that this app saved**, and nothing else on this device.
    ///
    /// `kSecAttrSynchronizable` is written **explicitly false** rather than left out. On a query
    /// an absent `synchronizable` means "non-synchronisable only" today, which is the answer
    /// wanted — but it means it by default rather than by instruction, and a default is the kind
    /// of thing that is read as an oversight and helpfully "fixed" to `Any` by somebody chasing
    /// a bug. Written down, it is a line with a reason attached.
    public static func lookup(host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host.lowercased(),
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrSecurityDomain as String: domain,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// What is written for a new item: the lookup, plus who and what, plus when it may be read.
    ///
    /// The label is for the reader, not for this app — it is what they will see if they ever go
    /// looking in Keychain Access, and "Fediqo — bbs.example.org" is findable where a bare
    /// hostname among a thousand website passwords is not.
    public static func attributes(for credential: ForumCredential) -> [String: Any] {
        var attributes = lookup(host: credential.host)
        attributes[kSecAttrAccount as String] = credential.username
        attributes[kSecAttrLabel as String] = "\(Fediqo.name) — \(credential.host)"
        attributes[kSecAttrAccessible as String] = accessibility
        attributes[kSecValueData as String] = Data(credential.password.utf8)
        return attributes
    }

    /// Everything **this app** has saved, attributes only.
    ///
    /// `kSecReturnData` is deliberately absent: this call is how the screen finds out that a
    /// password exists, and it must not be a way to read one. `kSecAttrSecurityDomain` is what
    /// makes "this app" true rather than aspirational — see `domain`.
    public static func allItems() -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrSecurityDomain as String: domain,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
    }
}

/// The real one.
public struct KeychainCredentials: ForumCredentialStore {
    public init() {}

    public func credential(host: String) throws -> ForumCredential? {
        var query = ForumKeychain.lookup(host: host)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
        guard let found = item as? [String: Any],
              let data = found[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8),
              let username = found[kSecAttrAccount as String] as? String
        else {
            // An item that is there but unreadable is not an error to show a reader: it is a
            // stored credential this build cannot use, and the honest thing is to behave as
            // though there were none and let them sign in again.
            return nil
        }
        return ForumCredential(host: host, username: username, password: password)
    }

    /// Replaces rather than adds. `SecItemAdd` over an existing item answers `errSecDuplicateItem`
    /// and changes nothing, so a reader who signs in again with a new password would keep being
    /// signed in with the old one — a failure that looks exactly like the forum rejecting them.
    public func save(_ credential: ForumCredential) throws {
        guard credential.isComplete else { throw ForumCredentialError.incomplete }
        try forget(host: credential.host)
        let status = SecItemAdd(ForumKeychain.attributes(for: credential) as CFDictionary, nil)
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
    }

    public func forget(host: String) throws {
        let status = SecItemDelete(ForumKeychain.lookup(host: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ForumCredentialError.keychain(status)
        }
    }

    public func savedHosts() throws -> Set<String> {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(ForumKeychain.allItems() as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ForumCredentialError.keychain(status) }
        guard let rows = item as? [[String: Any]] else { return [] }
        return Set(
            rows.compactMap { $0[kSecAttrServer as String] as? String }
                .map { $0.lowercased() }
        )
    }
}

/// The one tests and previews use. Never written to disk, and never reached by the app.
public final class MemoryCredentials: ForumCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: ForumCredential] = [:]

    public init() {}

    public func credential(host: String) throws -> ForumCredential? {
        lock.withLock { held[host.lowercased()] }
    }

    public func save(_ credential: ForumCredential) throws {
        guard credential.isComplete else { throw ForumCredentialError.incomplete }
        lock.withLock { held[credential.host] = credential }
    }

    public func forget(host: String) throws {
        _ = lock.withLock { held.removeValue(forKey: host.lowercased()) }
    }

    public func savedHosts() throws -> Set<String> {
        lock.withLock { Set(held.keys) }
    }
}
