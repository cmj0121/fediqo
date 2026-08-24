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
    private let secrets: any SecretStore

    public init(store: LocalStore, secrets: any SecretStore) {
        self.store = store
        self.secrets = secrets
    }

    /// The whole flow: app credentials from the Keychain or a fresh registration; PKCE and
    /// a random `state`; the browser; the exchange; `verify_credentials`. Then the token
    /// goes into `secrets` under the author_id, and one transaction writes the rows —
    /// server, account, `owned_accounts` — so the fact of being signed in never lands
    /// without the account it names.
    public func signIn(
        server: Server,
        using auth: any AuthClient,
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
        let callback = try await authenticate(consent, auth.callbackScheme)
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
        // here signs out locally — the rows in one statement in this transaction, the tokens
        // once it committed, so the Keychain is never asked while the one database queue is held.
        let displaced = try await store.write { db -> [String] in
            let old = try String.fetchAll(db, sql: "SELECT author_id FROM owned_accounts WHERE server_url = ? AND author_id <> ?",
                                          arguments: [serverRow.url, accountRow.id])
            try db.execute(sql: "DELETE FROM owned_accounts WHERE server_url = ? AND author_id <> ?",
                           arguments: [serverRow.url, accountRow.id])
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
    public func signOut(authorId: String, using auth: any AuthClient) async {
        var serverURL: String?
        var app: AppCredentials?
        await attempt("sign-out: app credentials") {
            serverURL = try await store.read { db in
                try String.fetchOne(db, sql: "SELECT server_url FROM owned_accounts WHERE author_id = ?", arguments: [authorId])
            }
            app = try serverURL.flatMap { try secrets.appCredentials(for: $0) }
        }
        await signOut(authorId: authorId, serverURL: serverURL, app: app, using: auth)
    }

    /// Every owned account on one server, signed out — what removing a server calls before
    /// its selection is cleared, and what forgetting all servers calls per server (decision 8).
    /// The server's app credentials are read once, not once per account.
    public func signOutAll(for serverURL: String, using auth: any AuthClient) async {
        var owned: [String] = []
        await attempt("sign-out: listing owned accounts") {
            owned = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT author_id FROM owned_accounts WHERE server_url = ?", arguments: [serverURL])
            }
        }
        guard !owned.isEmpty else { return }
        var app: AppCredentials?
        await attempt("sign-out: app credentials") { app = try secrets.appCredentials(for: serverURL) }
        for authorId in owned {
            await signOut(authorId: authorId, serverURL: serverURL, app: app, using: auth)
        }
    }

    /// The shared half of both sign-outs: revoke best-effort with what the caller already
    /// read, then the local half, which always completes.
    private func signOut(authorId: String, serverURL: String?, app: AppCredentials?, using auth: any AuthClient) async {
        await attempt("sign-out: revoke") {
            guard let serverURL, let app, let token = try secrets.token(for: authorId) else { return }
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
    /// Who is signed in, keyed by the `servers.url` that owns each account — answered from
    /// the rows alone: the accounts and servers the post path already keeps. No network,
    /// and never the Keychain. One account per server is policy (decision 9), enforced by
    /// `SignInCoordinator`, so the endpoint is a key here, not a grouping.
    public func signedInByServer() async throws -> [String: SignedInAccount] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.server_url, o.author_id, a.handle, a.display_name, a.avatar_url
                FROM owned_accounts o
                JOIN accounts a ON a.author_id = o.author_id
                """).reduce(into: [:]) { accounts, row in
                accounts[row["server_url"]] = SignedInAccount(
                    authorId: row["author_id"],
                    handle: row["handle"] ?? "",
                    displayName: row["display_name"] ?? "",
                    avatarURL: (row["avatar_url"] as String?).flatMap(URL.init(string:))
                )
            }
        }
    }
}
