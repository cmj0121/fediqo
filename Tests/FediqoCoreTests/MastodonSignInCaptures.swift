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
/// | **the narrow four asked again by a sign-in whose own check of the token then fails** (asked 2026-10-11, #347: the check answered 503 on this side and never sent) | the same: no page, and **the very same token string**. Nothing having asked the server to end it, the token first issued goes on answering 200. Asked to end "the new one" instead, it is the held one that answers 401 |
/// | revoking the wider token | 200 `{}`; it then answers 401 `{"error":"The access token was revoked"}`; **the narrower one goes on working** |
/// | revoking the narrow token | 200 `{}`; every holder of that string is signed out at once — the "third" sign-in above was the same token. Revoked again: 200 `{}` |
/// | revoking with a wrong secret, another registration's id and secret, or none | 403 `unauthorized_client` (`revokeRefused`), and the token goes on working |
/// | **the person presses Deny** | 302 to the callback: `error=access_denied`, a sentence, and the `state` sent (`refusedCallback`). No token is made and the ones held are untouched |
/// | a word the registration does not hold, the whole of `read`, or no `scope` at all | 400 and a page of the server's own: "The requested scope is invalid, unknown, or malformed." **Nothing is sent to the callback** |
/// | the narrow page after every token of those words was revoked | 200: the page is shown again |
/// | a code traded twice; a code traded with the wrong verifier | 400 `invalid_grant` (`codeRefused`), each; the token the first trade made goes on working |
///
/// ## What asking a sign-in for a part still had to know (#347) — asked 2026-10-11
///
/// Of the same 4.6.6 image, as `servers/mastodon/seed.rb` left it, with `curl`, **asking in
/// English**; the server was then thrown away. One registration through `POST /api/v1/apps`
/// for the twenty-four words of `everyPart`; the sign-ins on the seed's own registration,
/// through the server's pages as above.
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | **the host's own list of scope words** — `GET /.well-known/oauth-authorization-server`, with no sign-in, and signed in | 200 `application/json`, 1,620 bytes, the same either way (`wordList`): a flat object whose `scopes_supported` is a list of forty-seven words — the whole of `read`, `write`, `follow`, `push`, `profile`, every finer word under the first two, and the `admin:` ones. Every word of `everyPart` is in it. Beside the list it names where to authorise, trade, revoke and register — each on this host, at the paths this app already uses |
/// | the same asked as OpenID names it (`/.well-known/openid-configuration`), and as a protected resource (`/.well-known/oauth-protected-resource`) | 404 and the server's own page, each: the one address above is the only one |
/// | **a registration for every word of every part, those of later stories among them** (`everyPart`) | 200; `scopes` echoes all twenty-four as a list, **in the order asked** (`widestRegistration`). Four registrations were left of the five this server takes in ten minutes (`X-RateLimit-Remaining: 4`) |
/// | **the same with one word the host does not know** (`read:nothing`), and that word alone | **422** `{"error":"Validation failed: Scopes doesn't match those configured on the server."}`, each — the registration is refused whole and **nothing is echoed**: no word says which one it was. Each refusal uses up one of the five. (`MastodonSaysTests` holds this sentence against the server) |
/// | **the source's own account of a token** — `GET /oauth/token/info`, with a sign-in that may do everything | 200, five things and no other (`wholeInfo`): `resource_owner_id` — a number, **the server's own for the person and not the account's id** (1, where the account check names the same person `117420549943948497`); `scope`, a list, here `["read","write"]` — **the words as the sign-in was made with them, a whole `read` never spelt out into its finer words**; `expires_in`, `null`; `application.uid`, the registration's client id; `created_at` |
/// | the same with this app's reading sign-in, its acting one, its acting and dismissing one, and one made for `read:statuses` alone | 200, `scope` the words each was made with, in that order — four, seven, nine, one. **No word is needed to ask it**: the one that may read posts and nothing else is answered as the rest |
/// | the same with a token that is none, and with no token | **401** `invalidInfo`, the header `invalidInfoHeader` |
/// | the same with a token **revoked** — through `/oauth/revoke`, or by its entry being removed (below) | **401, the very bytes a token that is none gets**: here it is "invalid", where every other signed-in path says of it "The access token was revoked" (`afterRevoke`). This address does not tell an ended sign-in from one that never was |
/// | the same with a token of the registration's own, nobody's (`grant_type=client_credentials`) | 200, `resource_owner_id` `null` |
/// | **the account check with the reading words alone** (`/api/v1/accounts/verify_credentials`) | 200: `id` a string, `acct` the name with no host. With `read:statuses` alone: 403, `checkRefusedHeader` — `read:accounts` is one of three words that would do |
/// | **the same words asked again, three seconds on: is the token handed back dated anew?** | no. The first trade answered `created_at` 1791695432 under `Date: … 05:10:32 GMT` — the second it was made in; the second trade answered **the same string and the same `created_at`**, under `Date: … 05:10:35 GMT`. `/oauth/token/info` says the same `created_at`. A wider one made then says 1791695435 under `05:10:35`. So a token whose `created_at` is earlier than its own answer's `Date` was not made by this trade |
/// | **the person's list of authorised apps** (`/oauth/authorized_applications`, signed in at a browser) with a narrow and a wider token of one registration live | **one entry for the registration, not one a token**, under the registration's name. What it lists is **what the registration was made for, not what either token holds**: `entryPermissions`, for two sign-ins that between them held the four reading words and the two for follows |
/// | **that entry removed** — the page's own Revoke: `POST /oauth/authorized_applications/<id>` with `_method=delete` and the page's own token | 302 back to the list. **Both tokens are ended at once**: each answers 401 "The access token was revoked". A token of another registration, the same person's, goes on answering 200. The entry is gone from the list; the registration is not — its page opens again for the same words and trades for a new string |
///
/// ## Follows, asked of a sign-in that only reads (#347, #313) — asked 2026-10-11
///
/// Of the same image as the seed left it, **asking in English**: first with `curl` and the
/// seed's own sign-ins, then by `MastodonSignInSaysTests` through the server's pages on the
/// seed's registration. Whoever is followed is the seed's `followable_313`, whom nobody
/// follows; they were unfollowed again each time.
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | **how the reader stands to somebody** (`GET /api/v1/accounts/relationships?id[]=…`) with the reading words alone | **403**, `standingRefusedHeader`: the whole of `read`, or `read:follows` |
/// | the same with the reading words and `read:follows` | 200: a list of one, the sixteen things of `standingNames`; `following` false, `followed_by` false |
/// | **following somebody** (`POST /api/v1/accounts/:id/follow`) with the reading words, with those and `read:follows`, and with the reading and acting words | **403**, `followRefusedHeader`, each: the word that posts does not follow, and the word that reads how the reader stands does not |
/// | **a reading sign-in asked where it stands for follows**: a page of the seed's registration for its four words and `read:follows write:follows`, while the reading one lives | the page is shown, for those six. Approved: a second, different token of the same registration and the same account, whose words are the six in the order asked. **The reading one goes on answering 200** — and is still refused how the reader stands to anybody, and following |
/// | following with the wider one | 200: the same sixteen things, `following` true and `showing_reblogs` true — an account that is not locked is followed at once. `relationships` then says the same |
/// | **posting with the wider one** (`POST /api/v1/statuses`), which holds `write:follows` and not `write:statuses` | **403**, `postRefusedHeader` — as the reading words alone are. Nothing is posted: holding follows is not writing |
/// | unfollowing with the wider one | 200: `following` false, `showing_reblogs` false. Unfollowing somebody not followed is answered the same 200 |
///
/// **Not asked here** — the fixture is 4.6.6 alone: what a Mastodon from before the list of
/// words was published answers at that address, and whether such a host echoes `scopes` at a
/// registration at all; whether any host refuses a registration for some of its words and not
/// others (this one is all or nothing); a reaction to an announcement with the acting words
/// (there is no announcement in the seed: it is asked with the unit that reads them).
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

    // MARK: - Asked 2026-10-11

    /// Every word of every part a sign-in may come to be asked for (#347), those of later
    /// stories among them, in the order of the design's table: what one registration for all of
    /// them asks.
    static let everyPart = "read:statuses read:lists read:accounts read:search write:statuses write:favourites write:bookmarks "
        + "read:notifications write:notifications read:follows write:follows read:mutes write:mutes read:blocks write:blocks "
        + "write:accounts read:bookmarks read:favourites write:media write:lists read:filters write:filters write:reports "
        + "write:conversations"

    /// `GET /.well-known/oauth-authorization-server`: 200, whole.
    static let wordList = #"{"issuer":"https://mastodon.localhost/","authorization_endpoint":"https://mastodon.localhost/oauth/authorize","token_endpoint":"https://mastodon.localhost/oauth/token","revocation_endpoint":"https://mastodon.localhost/oauth/revoke","userinfo_endpoint":"https://mastodon.localhost/oauth/userinfo","scopes_supported":["read","profile","write","write:accounts","write:blocks","write:bookmarks","write:collections","write:conversations","write:favourites","write:filters","write:follows","write:lists","write:media","write:mutes","write:notifications","write:reports","write:statuses","read:accounts","read:blocks","read:bookmarks","read:collections","read:favourites","read:filters","read:follows","read:lists","read:mutes","read:notifications","read:search","read:statuses","follow","push","admin:read","admin:read:accounts","admin:read:reports","admin:read:domain_allows","admin:read:domain_blocks","admin:read:ip_blocks","admin:read:email_domain_blocks","admin:read:canonical_email_blocks","admin:write","admin:write:accounts","admin:write:reports","admin:write:domain_allows","admin:write:domain_blocks","admin:write:ip_blocks","admin:write:email_domain_blocks","admin:write:canonical_email_blocks"],"response_types_supported":["code"],"response_modes_supported":["query","fragment","form_post"],"grant_types_supported":["authorization_code","client_credentials"],"token_endpoint_auth_methods_supported":["client_secret_basic","client_secret_post"],"code_challenge_methods_supported":["S256"],"service_documentation":"https://docs.joinmastodon.org/","app_registration_endpoint":"https://mastodon.localhost/api/v1/apps"}"#
    /// The one address it is at, and the four it names beside the list — each a path this app
    /// already uses on the host.
    static let wordListPath = "/.well-known/oauth-authorization-server"
    static let namedPaths = [
        "authorization_endpoint": "/oauth/authorize", "token_endpoint": "/oauth/token",
        "revocation_endpoint": "/oauth/revoke", "app_registration_endpoint": "/api/v1/apps",
    ]

    /// `POST /api/v1/apps` for `everyPart`: 200.
    static let widestRegistration = #"{"id":"7","name":"Fediqo F2a","website":null,"scopes":["read:statuses","read:lists","read:accounts","read:search","write:statuses","write:favourites","write:bookmarks","read:notifications","write:notifications","read:follows","write:follows","read:mutes","write:mutes","read:blocks","write:blocks","write:accounts","read:bookmarks","read:favourites","write:media","write:lists","read:filters","write:filters","write:reports","write:conversations"],"redirect_uris":["fediqo://oauth"],"vapid_key":"<vapid_key>","redirect_uri":"fediqo://oauth","client_id":"<client_id>","client_secret":"<client_secret>","client_secret_expires_at":0}"#

    /// `GET /oauth/token/info` with a sign-in made for the whole of `read` and `write`: 200.
    static let wholeInfo = #"{"resource_owner_id":1,"scope":["read","write"],"expires_in":null,"application":{"uid":"<client_id>"},"created_at":1791695403}"#
    /// What that answer holds, and nothing else.
    static let infoNames: Set<String> = ["resource_owner_id", "scope", "expires_in", "application", "created_at"]
    /// The same address with a token that is none, with no token, and with a revoked one: 401,
    /// this, and the header beside it.
    static let invalidInfo = #"{"error":"invalid_token","error_description":"The access token is invalid","state":"unauthorized"}"#
    static let invalidInfoHeader = #"Bearer realm="Doorkeeper", error="invalid_token", error_description="The access token is invalid""#

    /// The account check asked with `read:statuses` alone: 403, and this header.
    static let checkRefusedHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _profile read read:accounts_.""#

    // MARK: - Follows — asked 2026-10-11

    /// How the reader stands to somebody, asked with the reading words alone: 403, and this header.
    static let standingRefusedHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _read read:follows_.""#
    /// Following somebody without `write:follows`: 403, and this header.
    static let followRefusedHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _follow write write:follows_.""#
    /// Posting without `write:statuses`, whatever else is held: 403, and this header.
    static let postRefusedHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _write write:statuses_.""#
    /// What the server says of how the reader stands to one person, and nothing else — in
    /// `relationships`' list of one, and as the whole answer to a follow or an unfollow.
    static let standingNames: Set<String> = [
        "id", "following", "showing_reblogs", "notifying", "languages", "followed_by", "blocking", "blocked_by", "muting",
        "muting_notifications", "muting_expires_at", "requested", "requested_by", "domain_blocking", "endorsed", "note",
    ]

    /// What the entry on the list of authorised apps said the seed's registration (`registered`)
    /// may do, as the page's own words in the order it lists them, while the only sign-ins of
    /// it held `wide` at most.
    static let entryPermissions = "Posts Read and write access Lists Read-only access Accounts Read-only access Search Read-only access "
        + "Favorites Write-only access Bookmarks Write-only access Notifications Read and write access Follows Read and write access "
        + "Mutes Read and write access"
}
