import Foundation

/// What a Mastodon says it has (#315, #320, #321), **as a real server sent it** — the Mastodon
/// 4.6.6 image `servers/compose.yml` pins, as `servers/mastodon/seed.rb` leaves it: a new
/// server with nothing switched on or off by hand, the web process alone (no worker, no
/// streaming service). Fetched with `curl` on 2026-10-11, each address with no sign-in, with a
/// sign-in that may do everything, and with this app's reading sign-in. In a second short
/// window four things were switched off from inside the server — the directory, what is
/// rising, the servers it knows, how busy it has been — asked again, and switched back; the
/// server was thrown away after each.
///
/// **Trimmed, not edited.** The document is whole but for its icons, cut to the first of nine,
/// the kinds of file it takes, cut to the first three of twenty-eight, and its push key. No
/// token and nobody real is in here.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | its own account of itself (`/api/v2/instance`) | 200, the same bytes to anyone, signed in or not. It names itself, a version, and under `configuration`: where it serves addresses and its live line, what an account may hold (`max_featured_tags: 10`, pinned posts, fields and their lengths, the lengths of a name and of a note), what a post, a picture, a film and a poll may be, whether it translates, who may read its live feeds, and whether it federates with a chosen few. Beside it: `api_versions` (`{"mastodon": 11}`), registrations, a contact, rules |
/// | the older document (`/api/v1/instance`) | 200 still, a different shape with less in it. Not read by this app, and not asked here again |
/// | what the document says of the things #309 asks about | **only how many hashtags an account may feature.** Nothing of suggestions, the directory, featured people, rising hashtags or links, announcements, its longer account, the servers it knows or how busy it has been |
/// | an address it does not serve (`/api/v1/fediqo_no_such_thing`, `/api/v9/instance`) | 404 and **a page of its own**, 1,481 bytes of HTML, to anyone |
/// | somebody or something it has not got (`accounts/1`; its terms of service, never written) | 404 `{"error":"Record not found"}` — the address is served, the record is not there |
/// | a thing it has but has no means for (`statuses/:id/translate`, with no translator set up) | 404 `{"error":"Not Found"}` signed in — a third spelling; 401 with no sign-in |
/// | a thing its administrator keeps from strangers (`instance/domain_blocks`) | 404, `text/html`, **no body at all**, to anyone |
/// | the people it suggests (`/api/v2/suggestions`, and the older `/api/v1/`) | signed in, with the whole of reading or this app's reading words: 200 and the five people the seed named whom the writer may be suggested, each an account beside why it is suggested (`MastodonSuggestionsCaptures`) — `200 []` where whoever runs a server named nobody, as on a new one. No sign-in: 401 `{"error":"The access token is invalid"}`. Taking one off (`DELETE suggestions/1`) is `200 {}` for somebody never suggested, and 403 for the reading sign-in |
/// | its directory (`/api/v1/directory`, `?local=true&order=new`) | `200 []` to anyone: nobody seeded chose to be listed. **Switched off: 404 `{"error":"Not Found"}`** — the not-found of a thing it has no means for. (The seed has since been taught to list a few people — `MastodonDirectoryCaptures` — so the server it leaves no longer answers with nobody) |
/// | what is rising (`trends/tags`, `trends/links`) | `200 []` to anyone; `trends/statuses` gives posts. **Switched off, all three answer `200 []`**: for hashtags and links exactly what an empty one answers, and nothing in the document says which. (The seed has since been taught to make one hashtag and one link rise — `MastodonRisingCaptures` — so the server it leaves no longer answers these two with nothing; switched off, they still do) |
/// | the document, with those four switched off | **the same bytes**: it says nothing of any of them |
/// | what it announces (`/api/v1/announcements`) | signed in `200 []`; no sign-in **422** `{"error":"This method requires an authenticated user"}` — not 401 |
/// | its longer account, the servers it knows, how busy it has been | `200 {"updated_at":null,"content":""}` — never written, and present; `200 ["elsewhere.example"]`; 200, twelve weeks, **every figure a string** (`"statuses":"74"`). To anyone. **The last two switched off: 404, `text/html`, no body** — as a thing kept from strangers answers |
/// | what an account features (`accounts/:id/featured_tags`, `accounts/:id/endorsements`) | `200 []` each, to anyone. One's own (`/api/v1/endorsements`, `/api/v1/featured_tags`): `200 []` signed in, 401 not |
/// | the languages it translates between (`instance/translation_languages`) | `200 {}`; the document says `"translation": {"enabled": false}` |
/// | where its live line is served | the document: `"streaming": "wss://mastodon.localhost"` — its own host here, and often another's elsewhere. `/api/v1/streaming` answers 301 to itself: the fixture runs no streaming service |
/// | posts that wait, the year's account, where the reader stopped, what they set | signed in `200 []`, `200 {"annual_reports":[],"accounts":[],"statuses":[]}`, `200 {}`, and their settings; 401 with no sign-in. The hashtags they follow: 200 with the whole of reading, **403 for this app's reading sign-in** |
///
/// So of the ten things, a new 4.6.6 serves every address and says of one how much of it there
/// is. Switched off, three say so by a not-found of their own address — the directory, the
/// servers it knows, how busy it has been — and two cannot be told from an empty one at all:
/// the hashtags and the links rising. Suggestions, announcements, featured people and the
/// longer account have no switch that was found to ask.
///
/// A not-found is believed to be about the address only where it is one of the three spellings
/// above that are: the page, the empty body, and `{"error":"Not Found"}`. Any other sentence of
/// the server's own — its `Record not found`, or a wording no server here was heard to use — is
/// not, and the thing stays unsaid.
enum MastodonHostCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v2/instance`.
    static let document = #"""
    {
      "domain": "mastodon.localhost",
      "title": "Mastodon",
      "version": "4.6.6",
      "source_url": "https://github.com/mastodon/mastodon",
      "description": "",
      "usage": {
        "users": {
          "active_month": 0
        }
      },
      "thumbnail": {
        "url": "https://mastodon.localhost/packs/assets/preview-vSUsFXid.png",
        "description": "Two smiling cartoon mastodons (who look like elephants) toss a paper plane between them. They're surrounded by a bright blue sky and floating planets with trees and more mastodons on them."
      },
      "icon": [
        {
          "src": "https://mastodon.localhost/packs/assets/android-chrome-36x36-DLiBQg3N.png",
          "size": "36x36"
        }
      ],
      "languages": [
        "en"
      ],
      "configuration": {
        "urls": {
          "streaming": "wss://mastodon.localhost",
          "status": null,
          "about": "https://mastodon.localhost/about",
          "privacy_policy": "https://mastodon.localhost/privacy-policy",
          "terms_of_service": null
        },
        "vapid": {
          "public_key": "(cut)"
        },
        "accounts": {
          "max_display_name_length": 40,
          "max_note_length": 500,
          "max_avatar_description_length": 150,
          "max_header_description_length": 150,
          "max_featured_tags": 10,
          "max_pinned_statuses": 5,
          "max_profile_fields": 4,
          "profile_field_name_limit": 255,
          "profile_field_value_limit": 255
        },
        "statuses": {
          "max_characters": 500,
          "max_media_attachments": 4,
          "characters_reserved_per_url": 23
        },
        "media_attachments": {
          "description_limit": 10000,
          "image_matrix_limit": 33177600,
          "image_size_limit": 16777216,
          "supported_mime_types": [
            "image/jpeg",
            "image/png",
            "image/gif"
          ],
          "video_frame_rate_limit": 120,
          "video_matrix_limit": 8294400,
          "video_size_limit": 103809024
        },
        "polls": {
          "max_options": 4,
          "max_characters_per_option": 50,
          "min_expiration": 300,
          "max_expiration": 2629746
        },
        "translation": {
          "enabled": false
        },
        "timelines_access": {
          "live_feeds": {
            "local": "public",
            "remote": "public"
          },
          "hashtag_feeds": {
            "local": "public",
            "remote": "public"
          },
          "trending_link_feeds": {
            "local": "public",
            "remote": "public"
          }
        },
        "limited_federation": false
      },
      "registrations": {
        "enabled": false,
        "approval_required": false,
        "reason_required": false,
        "message": null,
        "min_age": null,
        "url": null
      },
      "api_versions": {
        "mastodon": 11
      },
      "wrapstodon": null,
      "contact": {
        "email": "",
        "account": null
      },
      "rules": []
    }
    """#

    /// The first lines of what `GET /api/v1/fediqo_no_such_thing` answered with 404: a page.
    static let noSuchAddress = #"""
    <!DOCTYPE html>
    <html data-color-scheme="auto" data-contrast="auto" lang="en">
    <head>
    <meta content="text/html; charset=UTF-8" http-equiv="Content-Type">
    <meta charset="utf-8">
    <title>The page you are looking for isn&#39;t here.
     - Mastodon</title>
    """#

    /// `GET /api/v1/accounts/1`, and `GET /api/v1/instance/terms_of_service`: 404.
    static let noSuchRecord = #"{"error":"Record not found"}"#

    /// `POST /api/v1/statuses/:id/translate`, signed in, with no translator set up: 404.
    static let noMeansForIt = #"{"error":"Not Found"}"#

    /// `GET /api/v1/instance/domain_blocks`: 404 and no body.
    static let keptFromStrangers = ""

    /// `GET /api/v1/announcements` with no sign-in: 422.
    static let wantsASignIn = #"{"error":"This method requires an authenticated user"}"#
}
