import Foundation

/// How a Mastodon widens a sign-in (#347, #309), **as a real server answered through its own
/// pages** — the Mastodon 4.6.6 image `servers/compose.yml` pins. One registration was made
/// through `POST /api/v1/apps` for thirteen scopes; the seed's writer was signed in at
/// `/auth/sign_in` with the page's own form; and every sign-in below opened `/oauth/authorize`
/// with this app's callback and a PKCE challenge, sent the page's own Authorize or Deny form
/// back, and traded the code at `/oauth/token`. Driven with `curl` on 2026-10-10, in the one
/// window the story's plan calls step 0; the server was then thrown away. Nothing was minted in
/// the server.
///
/// **Whole, but for what must not be kept**: each token, code, client id and secret is struck
/// and its place marked.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | a registration for thirteen scopes | 200; it echoes them as a list (`registration`) |
/// | its page opened with nobody signed in | 302 to `/auth/sign_in`, which sends the person back to the same page once signed in |
/// | **a page asking for four of the thirteen** | 200: the page opens and lists those four and no other ("Posts, Lists, Accounts, Search: read-only access"). Approved: 302 to the callback with `code` and the `state` sent |
/// | what the token then says it holds | `scope` in the token's answer is the four words, in the order asked, as one string (`narrowToken`); `/oauth/token/info` says the same as a list |
/// | **a wider page of the same registration while the narrower token lives** (six words) | 200: the page is shown again, listing the six. Approved: a second, different token whose `scope` is the six. **Both live side by side**: the narrow one reads and is refused `relationships` (403), the wide one is given it |
/// | **the narrow four asked again** — the same words, or the same words in another order | **no page**: 302 straight to the callback, and the code trades for **the very same token string** as the first. One registration, one person, one set of words is one token, however many devices ask |
/// | revoking the wider token | 200 `{}`; it then answers 401 `{"error":"The access token was revoked"}`; **the narrower one goes on working** |
/// | revoking the narrow token | 200 `{}`; every holder of that string is signed out at once — the "third" sign-in above was the same token. Revoked again: 200 `{}` |
/// | revoking with a wrong secret, another registration's id and secret, or none | 403 `unauthorized_client` (`revokeRefused`), and the token goes on working |
/// | **the person presses Deny** | 302 to the callback: `error=access_denied`, a sentence, and the `state` sent (`refusedCallback`). No token is made and the ones held are untouched |
/// | a word the registration does not hold, the whole of `read`, or no `scope` at all | 400 and a page of the server's own: "The requested scope is invalid, unknown, or malformed." **Nothing is sent to the callback** |
/// | the narrow page after every token of those words was revoked | 200: the page is shown again |
/// | a code traded twice; a code traded with the wrong verifier | 400 `invalid_grant` (`codeRefused`), each; the token the first trade made goes on working |
enum MastodonSignInCaptures {
    /// What the registration asked for, and the two sign-ins made of it.
    static let registered = "read:statuses read:lists read:accounts read:search write:statuses write:favourites write:bookmarks "
        + "read:notifications write:notifications read:follows write:follows read:mutes write:mutes"
    static let narrow = "read:statuses read:lists read:accounts read:search"
    static let wide = "read:statuses read:lists read:accounts read:search read:follows write:follows"

    /// `POST /api/v1/apps`: 200.
    static let registration = #"{"id":"6","name":"Fediqo F4a","website":null,"scopes":["read:statuses","read:lists","read:accounts","read:search","write:statuses","write:favourites","write:bookmarks","read:notifications","write:notifications","read:follows","write:follows","read:mutes","write:mutes"],"redirect_uris":["fediqo://oauth"],"vapid_key":"<vapid_key>","redirect_uri":"fediqo://oauth","client_id":"<client_id>","client_secret":"<client_secret>","client_secret_expires_at":0}"#

    /// What the page for the narrow sign-in sent back in its Authorize form, beside the form's
    /// own token: everything the address asked, unchanged.
    static let pageFields = [
        "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "response_type", "scope",
    ]

    /// Where the approved page sent the person: 302, and this `Location`.
    static let approvedCallback = "fediqo://oauth?code=<code>&state=s1"
    /// `POST /oauth/token` for the narrow sign-in: 200. The same body, token and all, for the same
    /// words asked a second time.
    static let narrowToken = #"{"access_token":"<token>","token_type":"Bearer","scope":"read:statuses read:lists read:accounts read:search","created_at":1791643600}"#
    /// `GET /oauth/token/info` with it: 200.
    static let narrowInfo = #"{"resource_owner_id":1,"scope":["read:statuses","read:lists","read:accounts","read:search"],"expires_in":null,"application":{"uid":"<client_id>"},"created_at":1791643600}"#
    /// `POST /oauth/token` for the wider one, made while the narrow one lived: 200.
    static let wideToken = #"{"access_token":"<token>","token_type":"Bearer","scope":"read:statuses read:lists read:accounts read:search read:follows write:follows","created_at":1791643600}"#

    /// `POST /oauth/revoke` by the registration that made the token: 200, and this — the first
    /// time and every time after.
    static let revoked = "{}"
    /// By anybody else: 403, and this.
    static let revokeRefused = #"{"error":"unauthorized_client","error_description":"You are not authorized to revoke this token"}"#
    /// A revoked token at any signed-in path: 401, this, and the header beside it.
    static let afterRevoke = #"{"error":"The access token was revoked"}"#
    static let afterRevokeHeader = #"Bearer realm="Doorkeeper", error="invalid_token", error_description="The access token was revoked""#

    /// Where the page sent the person who pressed Deny: 302, and this `Location`.
    static let refusedCallback = "fediqo://oauth?error=access_denied&error_description=The+resource+owner+or+authorization+server+denied+the+request.&state=s5"
    /// The one sentence of the 400 page shown for a scope outside the registration, for the whole
    /// of `read`, and for no scope.
    static let outsideScope = "The requested scope is invalid, unknown, or malformed."
    /// A code traded a second time, or with the wrong verifier: 400, and this.
    static let codeRefused = #"{"error":"invalid_grant","error_description":"The provided authorization grant is invalid, expired, revoked, does not match the redirection URI used in the authorization request, or was issued to another client."}"#
}
