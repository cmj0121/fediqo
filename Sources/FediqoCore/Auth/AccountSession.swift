import Foundation
import GRDB

/// The seam between the OAuth client and the store: signing in, signing out, and who is
/// signed in now. It lives beside `AuthClient` and `SecretStore` because they are what it
/// orchestrates — the store's part is a few short statements against `owned_accounts`,
/// reusing the post path's upserts.
///
/// The browser stays outside Core: `signIn` hands the consent URL to whatever closure the
/// app gives it — ASWebAuthenticationSession, in practice — and takes the callback URL back.
public struct SignInCoordinator: Sendable {
    private let store: LocalStore

    public init(store: LocalStore) {
        self.store = store
    }

    /// The whole flow: app credentials from the Keychain or a fresh registration; PKCE and
    /// a random `state`; the browser; the exchange; `verify_credentials`. Then the token
    /// goes into `secrets` under the author_id, and one transaction writes the rows —
    /// server, account, `owned_accounts` — so the fact of being signed in never lands
    /// without the account it names.
    public func signIn(
        server: Server,
        using auth: any AuthClient,
        secrets: any SecretStore,
        authenticate: @Sendable (URL, String) async throws -> URL
    ) async throws -> SignedInAccount {
        let app: AppCredentials
        if let kept = try secrets.appCredentials(for: server.endpoint) {
            app = kept
        } else {
            app = try await auth.registerApp(host: server.host)
            try secrets.setAppCredentials(app, for: server.endpoint)
        }

        let pkce = PKCE()
        let state = Data.random(16).base64URL
        let consent = try auth.authorizationURL(host: server.host, app: app, pkce: pkce, state: state)
        // The scheme is the client's promise, asked of the client: a redirect without one
        // could never have been registered.
        let callback = try await authenticate(consent, auth.redirectURI.scheme!)
        let code = try Self.code(in: callback, expecting: state)

        let token = try await auth.exchangeCode(host: server.host, app: app, code: code, pkce: pkce)
        let account = try await auth.verifyCredentials(host: server.host, token: token)

        try secrets.setToken(token, for: account.authorId)

        let serverRow = LocalStore.serverRow(server)
        let accountRow = LocalStore.AccountRow(id: account.authorId, proto: serverRow.proto, serverURL: serverRow.url,
                                               handle: account.handle, displayName: account.displayName,
                                               avatarURL: account.avatarURL?.absoluteString)
        let ms = LocalStore.milliseconds(Date())
        // One account per server is policy (decision 9), not schema: whoever else was owned
        // here signs out locally — the row in this transaction, the token once it committed,
        // so the Keychain is never asked while the one database queue is held.
        let displaced = try await store.write { db -> [String] in
            let old = try String.fetchAll(db, sql: "SELECT author_id FROM owned_accounts WHERE server_url = ? AND author_id <> ?",
                                          arguments: [serverRow.url, accountRow.id])
            for authorId in old {
                try db.execute(sql: "DELETE FROM owned_accounts WHERE author_id = ?", arguments: [authorId])
            }
            try LocalStore.upsertServer(db, serverRow, now: ms)
            try LocalStore.upsertAccount(db, accountRow, now: ms)
            try db.execute(sql: "INSERT INTO owned_accounts (author_id, server_url, created_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                           arguments: [accountRow.id, serverRow.url, ms])
            return old
        }
        for authorId in displaced {
            await attempt("sign-in: displaced revoke") {
                guard let old = try secrets.token(for: authorId) else { return }
                try await auth.revoke(host: server.host, app: app, token: old)
            }
            await attempt("sign-in: displaced token removal") { try secrets.removeToken(for: authorId) }
        }
        return account
    }

    /// Signing out. The revoke is best-effort (decision 6 — a server that cannot be reached
    /// cannot keep you signed in); the local half always completes: the token leaves the
    /// Keychain and the `owned_accounts` row goes. What fails is logged, never thrown.
    public func signOut(authorId: String, using auth: any AuthClient, secrets: any SecretStore) async {
        await attempt("sign-out: revoke") {
            guard let serverURL = try await store.read({ db in
                try String.fetchOne(db, sql: "SELECT server_url FROM owned_accounts WHERE author_id = ?", arguments: [authorId])
            }),
                let app = try secrets.appCredentials(for: serverURL),
                let token = try secrets.token(for: authorId) else { return }
            try await auth.revoke(host: LocalStore.host(of: serverURL), app: app, token: token)
        }
        await attempt("sign-out: token removal") {
            try secrets.removeToken(for: authorId)
        }
        await attempt("sign-out: row removal") {
            try await store.write { db in
                try db.execute(sql: "DELETE FROM owned_accounts WHERE author_id = ?", arguments: [authorId])
            }
        }
    }

    /// Every owned account on one server, signed out — what removing a server calls before
    /// its selection is cleared, and what forgetting all servers calls per server (decision 8).
    public func signOutAll(for serverURL: String, using auth: any AuthClient, secrets: any SecretStore) async {
        var owned: [String] = []
        await attempt("sign-out: listing owned accounts") {
            owned = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT author_id FROM owned_accounts WHERE server_url = ?", arguments: [serverURL])
            }
        }
        for authorId in owned {
            await signOut(authorId: authorId, using: auth, secrets: secrets)
        }
    }

    /// Best effort, logged: sign-out promises its local half completes even when a step fails.
    private func attempt(_ what: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            LocalStore.log.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The `code` the browser brought back — read only after the `state` proves the answer
    /// belongs to the question this sign-in asked.
    private static func code(in callback: URL, expecting state: String) throws -> String {
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == state else {
            throw SourceFailure.signInFailed("the state came back changed")
        }
        guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw SourceFailure.signInFailed("the callback carries no code")
        }
        return code
    }
}

extension LocalStore {
    /// Who is signed in, said from the rows alone — the accounts and servers the post path
    /// already keeps. No network, and never the Keychain.
    public func signedIn() async throws -> [SignedInAccount] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.author_id, a.handle, a.display_name, a.avatar_url
                FROM owned_accounts o
                JOIN accounts a ON a.author_id = o.author_id
                ORDER BY o.created_at, o.author_id
                """).map { row in
                SignedInAccount(
                    authorId: row["author_id"],
                    handle: row["handle"] ?? "",
                    displayName: row["display_name"] ?? "",
                    avatarURL: (row["avatar_url"] as String?).flatMap(URL.init(string:))
                )
            }
        }
    }
}
