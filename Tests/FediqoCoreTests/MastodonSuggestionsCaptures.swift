import Foundation

/// The people a Mastodon suggests to whoever is signed in (#315), **as a real server sent it**:
/// the Mastodon 4.6.6 image `servers/compose.yml` pins, the web process alone.
///
/// **Two windows, both on 2026-10-12, and each row says which holds it.** The bodies below, and
/// every row a live check is named beside, are of the server **as `servers/mastodon/seed.rb`
/// leaves it today**: whoever runs it named nine people to suggest, and the writer is suggested
/// five of them. Those rows are asked again on every live run (`MastodonSuggestionsSaysTests`,
/// but for the one that names another suite). The rows marked **by hand** were asked once with
/// `curl`, most of them in an earlier window the seed no longer reproduces — the seed then
/// suggested nobody, and people were named from inside the server, first eight of the seed's
/// accounts, then nineteen, with eight sign-ins made inside for one word each — and nothing asks
/// them again. In that window whoever was told not to be suggested was put back from inside,
/// whoever was followed was unfollowed, and the server was thrown away afterwards.
///
/// **Whole, not trimmed.** Each body is every byte the server sent. No token and nobody real
/// is in here: the accounts are the seed's.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered | Held by |
/// | ----- | -------- | ------- |
/// | the people it suggests (`GET /api/v2/suggestions`), with no sign-in or a token that is none | **401**, and not the not-found of an address. Nobody is suggested anything unsigned | `whoMayRead` |
/// | the words of that 401 | `{"error":"The access token is invalid"}`, `WWW-Authenticate: Bearer realm="Doorkeeper", error="invalid_token", …` | by hand, 2026-10-12, not re-checked |
/// | the same, with each sign-in this app makes — its reading one, its acting one, the two of follows — and with one for reading posts alone | 200 to all four, and the same five people; `read:statuses` alone: **403** `{"error":"This action is outside the authorized scopes"}`, `WWW-Authenticate: … error="insufficient_scope", error_description="Access to this resource requires scope _read read:accounts_."`. So every sign-in this app makes may read it | `whoMayRead` |
/// | the same, with sign-ins made inside the server for one word each | **`read`, or `read:accounts`, and nothing else**: 200 with either alone; `read:follows`, `write`, `write:accounts`, `write:follows`, `follow`, `profile`: the same 403 | by hand, 2026-10-12, not re-checked |
/// | the shape of an entry | `{"source": "staff", "sources": ["featured"], "account": {…}}` — why, in an older word and in the newer list of words, and the account in the shape every account has. Nothing else, and no count of how many there are. No `Link` header beside it | `whoMayRead` |
/// | `GET /api/v1/suggestions` | still answers, by the same words: the same people in the same order, each the bare account with no reason beside it; 401 unsigned, the same 403 for reading posts alone | `theOlderAddress` |
/// | who is left out, asked as the reader: of the nine the seed names | whoever they block, whoever they mute, and for every reader the one suspended and the one limited — another reader is given the two the writer blocks and mutes. Somebody of another server is suggested like anyone. **No entry is marked suspended or limited, or says it moved** | `whoIsLeftOut` |
/// | following somebody suggested | they are gone from the very next read; unfollowed, they are suggested again | `followingTakesSomebodyOut` |
/// | who else is left out, of nineteen named inside the server | whoever they asked to follow, whoever blocks them, themself — and for every reader somebody who moved and whoever did not choose to be found. Somebody locked, somebody automated and somebody who hides their lists are suggested like anyone. The writer was given ten and another person fourteen, none marked | by hand, 2026-10-12, not re-checked |
/// | how long a stretch is: unasked, and with `limit=80`, `81` and `200` | what there is — five, so the most it gives in one was not seen. `limit=-1`: one, the first. A limit that is no number: `200 []` | `lengthsAndPlacesItDoesNotKnow` |
/// | `limit=0` | `200 []` — **nobody, which is not the end**. So a length of at least one is always asked | `readOnByACount` |
/// | how it goes on | nothing in the body names a next: only `offset` — how many to pass over. Stretches of two are five people, nobody twice; `&offset=5`, where there are five, is `200 []`. **An offset far past how many there are — `offset=1000` — is 500**, a page of the server's own. `max_id` is ignored | `readOnByACount` |
/// | an offset one past how many there are (`offset=6` of five) | **500** as well: only the place of exactly how many there are is answered with nobody. So reading on from a whole stretch meets the 500 only where the list grew shorter meanwhile — and a stretch shorter than was asked for is taken for the end, with nothing asked past it | by hand, 2026-10-12, not re-checked |
/// | `offset=-1`, an offset that is no number, `page` | the last one; the other two are ignored — the whole list | `lengthsAndPlacesItDoesNotKnow` |
/// | the order, asked twice | the same: one the server draws by lot for each reader and keeps for a while | `readOnByACount` |
/// | the order, across a change | **drawn again whenever what it suggests them changes**: after a dismissal and after a follow the people left came back in another order. So read on across such a change, somebody may arrive twice and somebody may be passed over | by hand, 2026-10-12, not re-checked |
/// | nobody to suggest, as the seed left it before it named anybody | `200 []`, to anyone signed in | by hand, 2026-10-12, not re-checked |
/// | "don't suggest" (`DELETE /api/v1/suggestions/:id`), with each sign-in this app makes, with none, and with one that may do everything | its reading one, its acting one (`write:statuses write:favourites write:bookmarks`), the two of follows (`read:follows`, and `read:follows write:follows`): **403** `{"error":"This action is outside the authorized scopes"}`, `WWW-Authenticate: … error="insufficient_scope", error_description="Access to this resource requires scope _write write:accounts_."`. Unsigned: 401. `read write`: `200 {}`. **No sign-in this app makes holds that word** | `dismissingNeedsAWordNoSignInHolds` |
/// | the same, with sign-ins made inside the server for one word each | **`write`, or `write:accounts`, and nothing else**: `200 {}` with `write:accounts` alone; `read`, `read:accounts`, `write:follows`, `follow`, `profile`: the same 403 | by hand, 2026-10-12, not re-checked |
/// | the same at `/api/v2/suggestions/:id` | **404**, a page of the server's own: this server takes a dismissal at the older address alone | `dismissingNeedsAWordNoSignInHolds` |
/// | a dismissal of an id nobody has, and of an id that is no number | `200 {}` all the same, and nobody is dismissed — the answer says nothing of whether anybody was | `dismissingNeedsAWordNoSignInHolds` |
/// | what a dismissal of somebody real does | the person is gone from the very next read, at both addresses, and stays gone once the server has drawn its order again; another reader is still suggested them. Asked twice, and for somebody not suggested: `200 {}` each time. There is no address that takes a dismissal back — which is why no check makes one | by hand, 2026-10-12, not re-checked |
/// | an address the server has not got | **404**, a page of its own — the not-found of an address (`MastodonHostCaptures`), which is how a host with no suggestions at all is known | `MastodonHostSaysTests.notFound` |
///
/// So the people a source suggests are read signed in, with what every sign-in of this app
/// holds, a stretch at a time, on by how many were passed over, to the first
/// stretch shorter than was asked for. And telling the source not to suggest somebody needs a
/// word that belongs to changing the reader's own account, which no sign-in of this app holds.
enum MastodonSuggestionsCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v2/suggestions?limit=1`, as this app's reading sign-in: the first of five.
    static let firstOne = #"""
    [{"source":"staff","sources":["featured"],"account":{"id":"117423408597360415","username":"fediqo_fan_1","acct":"fediqo_fan_1","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_fan_1","uri":"https://mastodon.localhost/ap/users/117423408597360415","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":6,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]}}]
    """#

    /// `GET /api/v2/suggestions?limit=2&offset=3`: the last two of the five — one with a name
    /// partly a picture, words in markup and two fields.
    static let afterThree = #"""
    [{"source":"staff","sources":["featured"],"account":{"id":"117423408602893050","username":"fediqo_fan_2","acct":"fediqo_fan_2","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_fan_2","uri":"https://mastodon.localhost/ap/users/117423408602893050","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":3,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]}},{"source":"staff","sources":["featured"],"account":{"id":"117423408585001560","username":"fediqo_person","acct":"fediqo_person","display_name":"Per :fediqo_mark: Son","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"<p>Reads <a href=\"https://mastodon.localhost/tags/fediqo309\" class=\"mention hashtag\" rel=\"tag\">#<span>fediqo309</span></a> beside <span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo_other\" class=\"u-url mention\">@<span>fediqo_other</span></a></span> :fediqo_mark:<br /><a href=\"https://example.com/about\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/about</span><span class=\"invisible\"></span></a></p>","url":"https://mastodon.localhost/@fediqo_person","uri":"https://mastodon.localhost/ap/users/117423408585001560","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":8,"following_count":4,"statuses_count":9,"last_status_at":"2026-10-11","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[{"shortcode":"fediqo_mark","url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/a71ae58fa4df43ca.png","static_url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/a71ae58fa4df43ca.png","visible_in_picker":true}],"roles":[],"fields":[{"name":"Site","value":"<a href=\"https://example.com/per\" target=\"_blank\" rel=\"nofollow noopener me\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/per</span><span class=\"invisible\"></span></a>","verified_at":"2026-10-01T00:00:00.000+00:00"},{"name":"Pronouns :fediqo_mark:","value":"they/them","verified_at":null}]}}]
    """#

    /// `GET /api/v2/suggestions`, with nobody to suggest — and at an offset of exactly how many
    /// there are.
    static let nobody = "[]"

    /// `DELETE /api/v1/suggestions/:id` with this app's reading sign-in, and with its acting
    /// one: 403 and this — and the header beside it, which names the words it wants.
    static let dismissalRefused = #"{"error":"This action is outside the authorized scopes"}"#
    static let dismissalWants = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _write write:accounts_.""#

    /// `GET /api/v2/suggestions` with a sign-in that holds neither word for reading it: 403,
    /// the same body, and this header.
    static let readingWants = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _read read:accounts_.""#

    /// `DELETE /api/v1/suggestions/:id` with a sign-in that holds `write:accounts`: 200 and this.
    static let dismissed = "{}"
}
