import Foundation

/// What a Mastodon says of a hashtag followed (#318), **as a real server sent it**: the
/// Mastodon 4.6.6 image `servers/compose.yml` pins, the web process alone, as
/// `servers/mastodon/seed.rb` left it. Fetched with `curl`, asking in English
/// (`Accept-Language: en`), on 2026-10-11, with no sign-in and with five of the writer's the
/// seed makes: this app's reading words; those and `read:follows`; those and both words of
/// follows; reading and acting; and one for everything. Nothing was registered. Every hashtag
/// followed was unfollowed again, and the server was thrown away afterwards. No token and
/// nobody real is in here.
///
/// **Every constant here is every byte the server sent, and nothing else is in this file**:
/// each body whole, each header's value whole. The three stretches are three answers, asked
/// one after the other by the `Link` the one before gave, while the five hashtags they name
/// were all the sign-in followed. A row of the table whose answer is not kept as a constant
/// — a page of HTML, a name of three hundred letters — was answered so in the same sitting.
/// A shape no server sent, where a check needs one, is made up in that check and named as
/// made up there.
///
/// `MastodonTagFollowSaysTests` asks a server brought up again for every row of this table.
/// What it cannot hold is the numbers: the ids are those of the sitting recorded.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | a hashtag (`GET /api/v1/tags/:name`), with no sign-in | 200: `id`, `name`, `url`, `history` — and **no `following`** |
/// | the same, with any sign-in — the reading words alone among them | 200, the same and **`following` and `featuring`**, each `true` or `false`. No word of follows is needed to be told |
/// | a name nobody ever used | 200 all the same, its `id` empty: there is no "no such hashtag" |
/// | to follow one (`POST …/follow`) or unfollow it (`…/unfollow`), with no sign-in | **401** `{"error":"The access token is invalid"}` |
/// | the same, with the reading words, with those and `read:follows`, or with reading and acting | **403** `{"error":"This action is outside the authorized scopes"}`, and `WWW-Authenticate` naming `follow write write:follows` |
/// | the same, with reading and both words of follows | 200, the hashtag with `following` as it now is. A name never used is made by being followed |
/// | to follow one already followed, to unfollow one that is not, or one never used | 200, the same answer: **each is asked twice at no cost**. Unfollowing one never used does not make it |
/// | `FediQo318Case`, then `fediqo318case` and `FEDIQO318CASE` | one hashtag: `name` stays as it was first written, `url` is folded |
/// | `café318`, then `cafe318`; a name in full-width letters | one hashtag each: the server folds accents and width away, and `name` stays as first written |
/// | a name in Chinese, percent-encoded in the path | 200, `name` as written |
/// | a name with `#` (`%23`), a space, `/` (`%2F`), an emoji, or digits alone — asked about, or to be followed | **404** `{"error":"Not Found"}`; with a `.` in it, 404 and a page of HTML |
/// | a name of 300 letters | 200 — **the server sets no bound on a name** |
/// | the followed ones (`GET /api/v1/followed_tags`), with no sign-in | **401** |
/// | the same, with the reading words, or reading and acting | **403**, `WWW-Authenticate` naming `follow read read:follows` |
/// | the same, with `read:follows` beside the reading words | 200: a list of hashtags, **the one followed last first**, each with `following: true` |
/// | `limit=2` | two, and `Link`: `rel="next"` with `max_id`, `rel="prev"` with `since_id` — **ids of the follows, which no row carries**: after the hashtags numbered 14 and 13 the next was `max_id=12` |
/// | the last stretch | `Link` with `rel="prev"` alone: no `next` is the end |
/// | `limit=1000` | 200, all five: no bound of the server's was reached |
/// | `limit=0`, or `limit=x` | **500**, a page of HTML. `limit=-1`: 200, one |
/// | `max_id` of a place past the end, or one that is no number | 200, `[]`, no `Link` |
/// | anything, as to how often | `X-RateLimit-Limit: 300`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (a moment, on the five minutes) on every answer the API gives as JSON; a page of HTML carries none |
/// | to post, or to favourite, with reading and both words of follows | **403**, naming `write write:statuses` / `write write:favourites`: holding follows writes nothing else |
enum MastodonTagFollowCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v1/tags/fediqo318a`, with no sign-in: nothing of whether anybody follows it.
    static let unsigned = #"{"id":"","name":"fediqo318a","url":"https://mastodon.localhost/tags/fediqo318a","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}]}"#

    /// The same, signed in, before it was ever followed.
    static let notFollowed = #"{"id":"","name":"fediqo318a","url":"https://mastodon.localhost/tags/fediqo318a","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":false,"featuring":false}"#

    /// The same, once followed — and what `POST …/follow` itself answered.
    static let followed = #"{"id":"2","name":"fediqo318a","url":"https://mastodon.localhost/tags/fediqo318a","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false}"#

    /// `GET /api/v1/tags/FEDIQO318CASE`, of a hashtag first written `FediQo318Case`.
    static let otherCase = #"{"id":"4","name":"FediQo318Case","url":"https://mastodon.localhost/tags/fediqo318case","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false}"#

    /// `GET /api/v1/tags/cafe318`, of a hashtag first written with its accent.
    static let accent = #"{"id":"6","name":"café318","url":"https://mastodon.localhost/tags/cafe318","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false}"#

    /// `GET /api/v1/tags/%E6%A8%99%E7%B1%A4318`.
    static let chinese = #"{"id":"5","name":"標籤318","url":"https://mastodon.localhost/tags/%E6%A8%99%E7%B1%A4318","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false}"#

    /// With no sign-in: 401 and this.
    static let noSignIn = #"{"error":"The access token is invalid"}"#

    /// With a sign-in that lacks the word: 403, this, and the header under it.
    static let notGiven = #"{"error":"This action is outside the authorized scopes"}"#
    static let followRefusedHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _follow write write:follows_.""#
    static let listRefusedHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _follow read read:follows_.""#

    /// A name that is no hashtag: 404 and this.
    static let notFound = #"{"error":"Not Found"}"#

    /// One stretch of `GET /api/v1/followed_tags?limit=2`: its body, and its `Link` header.
    struct Stretch {
        let body: String
        let link: String?
    }

    /// Five hashtags followed in the order p1 … p5 and nothing else, read two at a time: the
    /// newest follow first, each next named by the id of a follow, and the last with no next.
    /// Each body and each header is the server's own.
    static let stretches: [Stretch] = [
        Stretch(
            body: #"[{"id":"14","name":"fediqo318p5","url":"https://mastodon.localhost/tags/fediqo318p5","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false},{"id":"13","name":"fediqo318p4","url":"https://mastodon.localhost/tags/fediqo318p4","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false}]"#,
            link: #"<https://mastodon.localhost/api/v1/followed_tags?limit=2&max_id=12>; rel="next", <https://mastodon.localhost/api/v1/followed_tags?limit=2&since_id=13>; rel="prev""#
        ),
        Stretch(
            body: #"[{"id":"12","name":"fediqo318p3","url":"https://mastodon.localhost/tags/fediqo318p3","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false},{"id":"11","name":"fediqo318p2","url":"https://mastodon.localhost/tags/fediqo318p2","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false}]"#,
            link: #"<https://mastodon.localhost/api/v1/followed_tags?limit=2&max_id=10>; rel="next", <https://mastodon.localhost/api/v1/followed_tags?limit=2&since_id=11>; rel="prev""#
        ),
        Stretch(
            body: #"[{"id":"10","name":"fediqo318p1","url":"https://mastodon.localhost/tags/fediqo318p1","history":[{"day":"1791676800","accounts":"0","uses":"0"},{"day":"1791590400","accounts":"0","uses":"0"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"}],"following":true,"featuring":false}]"#,
            link: #"<https://mastodon.localhost/api/v1/followed_tags?limit=2&since_id=9>; rel="prev""#
        ),
    ]

    /// The names of `stretches`, in the order the server gave them.
    static let names = ["fediqo318p5", "fediqo318p4", "fediqo318p3", "fediqo318p2", "fediqo318p1"]
}
