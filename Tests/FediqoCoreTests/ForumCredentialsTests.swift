import Foundation
import Security
import Testing

@testable import FediqoCore

/// The saved password: what is written, what it is scoped to, and what it must never say.
///
/// **Nothing here touches the real Keychain, on purpose.** A Keychain call from an unsigned test
/// binary can prompt, can answer `errSecMissingEntitlement` on one machine and succeed on the
/// next, and can leave an item behind for the following run to find — three ways to write this
/// branch's fourth flaky test. What is asserted here is the query, which is where every decision
/// actually lives; that `Security` honours it is verified by running the app, which is the only
/// thing that can verify it.
@Suite("What is saved for a forum")
struct ForumCredentialsTests {
    private let credential = ForumCredential(
        host: "BBS.Example.ORG", username: "reader", password: "s3cret-'\\\"-passphrase"
    )

    // MARK: - The thing it must never do

    /// The single line this unit is least allowed to get wrong.
    @Test("A credential prints without its password, however it is printed")
    func neverPrintsThePassword() {
        let secret = credential.password
        #expect(!"\(credential)".contains(secret), "string interpolation spelled it out")
        #expect(!String(describing: credential).contains(secret), "description spelled it out")
        #expect(!String(reflecting: credential).contains(secret), "debugDescription spelled it out")
        // `dump` walks the mirror rather than the description, and a struct's default mirror is
        // exactly how this escapes into a log nobody meant to write.
        var dumped = ""
        dump(credential, to: &dumped)
        #expect(!dumped.contains(secret), "the reflective dump spelled it out")
    }

    @Test("What it does print is enough to debug with")
    func printsEnoughToBeUseful() {
        #expect("\(credential)".contains("bbs.example.org"))
        #expect("\(credential)".contains("reader"))
    }

    @Test("An error carries a status and nothing else")
    func errorsCarryNoSecret() {
        // An error path is the likeliest place in any program for a secret to escape.
        let error = ForumCredentialError.keychain(errSecItemNotFound)
        #expect(!"\(error)".contains(credential.password))
        #expect(!"\(ForumCredentialError.incomplete)".contains(credential.password))
    }

    // MARK: - Scope and shape

    @Test("The host is folded where it enters, so every comparison below is exact")
    func hostIsFoldedOnce() {
        // Decision 21. Two spellings of one host is an ingestion bug, not a comparison bug.
        #expect(credential.host == "bbs.example.org")
        #expect(ForumCredential(host: "BBS.Example.ORG", username: "a", password: "b")
            == ForumCredential(host: "bbs.example.org", username: "a", password: "b"))
    }

    @Test("A lookup is an internet password for one server over https, and not synchronised")
    func lookupIsScopedAndLocal() {
        let query = ForumKeychain.lookup(host: "BBS.Example.ORG")
        #expect(query[kSecClass as String] as? String == kSecClassInternetPassword as String)
        #expect(query[kSecAttrServer as String] as? String == "bbs.example.org",
                "the query was not folded, so a capitalised host finds nothing")
        #expect(query[kSecAttrProtocol as String] as? String == kSecAttrProtocolHTTPS as String)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false,
                "the reader's forum password could reach every device on their Apple account")
    }

    /// Found by running a real app, and the only defect in this unit that destroys data.
    @Test("Every query is marked as this app's, so a Clear cannot delete another program's password")
    func everyQueryIsMarkedAsOurs() {
        // Measured without the mark, in a sandboxed `.app`: the list came back with `ghcr.io`,
        // `gitlab.com` and `index.docker.io` — Docker's and two git credential helpers'. Since
        // `forget` deletes under the same query, a reader pressing Clear on a source called
        // `gitlab.com` would have deleted their git credential, and `save` calls `forget` first.
        // All three queries, because the one that is missed is the one that does the damage.
        for query in [
            ForumKeychain.lookup(host: "bbs.example.org"),
            ForumKeychain.attributes(for: credential),
            ForumKeychain.allItems(),
        ] {
            #expect(query[kSecAttrSecurityDomain as String] as? String == ForumKeychain.domain,
                    "an unmarked query reaches other software's passwords")
        }
    }

    @Test("What is written is readable only while this device is unlocked, and only on it")
    func savedItemIsThisDeviceOnly() {
        let attributes = ForumKeychain.attributes(for: credential)
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            "a weaker class hands it to a locked device's backup")
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrAccount as String] as? String == "reader")
        #expect(attributes[kSecValueData as String] as? Data == Data(credential.password.utf8))
    }

    @Test("A saved item is labelled so the reader can find it themselves")
    func itemIsLabelled() {
        let label = ForumKeychain.attributes(for: credential)[kSecAttrLabel as String] as? String
        #expect(label?.contains(Fediqo.name) == true)
        #expect(label?.contains("bbs.example.org") == true)
    }

    @Test("Asking which hosts are saved cannot be a way to read a password")
    func listingReturnsNoData() {
        let query = ForumKeychain.allItems()
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecReturnData as String] == nil,
                "the screen's way of asking became a way of reading")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test("A saved item is found by the same query that writes it")
    func writeAndLookupAgree() {
        // If these ever disagreed, every save would succeed and every read would find nothing —
        // a reader who saves a password and is asked for it again on every launch.
        let lookup = ForumKeychain.lookup(host: credential.host)
        let attributes = ForumKeychain.attributes(for: credential)
        for (key, _) in lookup {
            #expect(attributes[key] as? String == lookup[key] as? String
                || attributes[key] as? Bool == lookup[key] as? Bool,
                "\(key) differs between what is written and what is looked up")
        }
    }

    // MARK: - The store's contract

    @Test("Half a credential is not saved at all")
    func incompleteIsRefused() throws {
        // Half a credential saved is an automatic sign-in that fails silently on every launch.
        let store = MemoryCredentials()
        for bad in [
            ForumCredential(host: "a.example", username: "", password: "p"),
            ForumCredential(host: "a.example", username: "u", password: ""),
            ForumCredential(host: "", username: "u", password: "p"),
        ] {
            #expect(!bad.isComplete)
            #expect(throws: ForumCredentialError.incomplete) { try store.save(bad) }
        }
        #expect(try store.savedHosts().isEmpty)
    }

    @Test("Saved, found, listed and forgotten — and forgotten twice is not an error")
    func theWholeRound() throws {
        let store = MemoryCredentials()
        try store.save(credential)
        #expect(try store.credential(host: "bbs.example.org") == credential)
        #expect(try store.credential(host: "BBS.EXAMPLE.ORG") == credential, "the lookup did not fold")
        #expect(try store.savedHosts() == ["bbs.example.org"])
        try store.forget(host: "BBS.Example.ORG")
        #expect(try store.credential(host: "bbs.example.org") == nil)
        #expect(try store.savedHosts().isEmpty)
        // A Clear on a host with nothing saved must not throw; it is the ordinary case.
        try store.forget(host: "bbs.example.org")
    }

    @Test("One host's password is never handed to another")
    func hostsDoNotBleed() throws {
        let store = MemoryCredentials()
        try store.save(ForumCredential(host: "one.example", username: "a", password: "p1"))
        try store.save(ForumCredential(host: "two.example", username: "b", password: "p2"))
        #expect(try store.credential(host: "one.example")?.password == "p1")
        #expect(try store.credential(host: "two.example")?.password == "p2")
        try store.forget(host: "one.example")
        #expect(try store.credential(host: "two.example")?.password == "p2",
                "forgetting one host took the other with it")
    }

    @Test("Signing in again replaces the password rather than keeping the old one")
    func savingAgainReplaces() throws {
        let store = MemoryCredentials()
        try store.save(ForumCredential(host: "a.example", username: "u", password: "old"))
        try store.save(ForumCredential(host: "a.example", username: "u", password: "new"))
        #expect(try store.credential(host: "a.example")?.password == "new",
                "a changed password would look exactly like the forum rejecting the reader")
        #expect(try store.savedHosts().count == 1)
    }
}
