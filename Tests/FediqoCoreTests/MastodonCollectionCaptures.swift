import Foundation

/// What a Mastodon 4.6.6 says of collections being made and tended (#433), **as a real server sent it**.
///
/// Asked with `curl` on 2026-10-31 of the image `servers/compose.yml` pins, under its own compose
/// project, thrown away after. No token is in here. Every constant is every byte the server sent.
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | a name alone on making | 422: `sensitive` and `discoverable` are both wanted |
/// | `PATCH` one field | 200, the others stand; a description of nothing comes back `""` |
/// | `GET …/accounts/:id/collections`, its owner with `read:collections` | 200, the ones not to be found too |
/// | the same with no sign-in, or by another | 200, only those to be found |
/// | any read by a sign-in without `read:collections` | 403, naming the word |
/// | any write by a sign-in without `write:collections` | 403, naming the word |
/// | add someone discoverable and unlocked | 200, `accepted` |
/// | add someone not discoverable, or locked and not followed | 403 `This action is not allowed` |
/// | add someone already in, or who took themselves out | 422 `Account has already been taken` |
/// | add a 26th, 27th… one by one | **200**: the server refuses more than 25 only on making (`overPeople`) |
/// | add an id it has not; remove or change what is gone | 404 `Record not found` |
/// | `DELETE` a collection, `DELETE` an item, `POST …/revoke` | 200, no body |
/// | `DELETE` an item or a collection not one's own | 403 |
/// | `…/revoke` by anyone but the person in it | 403; by them, twice, 200 each |
/// | a revoked item | gone from every read, its owner's too |
/// | a `pending` item (set by Rails: only a person of another server is pending) | its owner's signed read shows it and counts it; every other read shows neither |
/// | an eleventh collection (`UserRole#collection_limit` 10) | 422, the sentence `Translation missing…` |
enum MastodonCollectionCaptures {
    static let host = "mastodon.localhost"
    static let owner = "117532228402837528"
    static let bob = "117532228418753996"

    /// `POST /api/v1/collections`, name, description, `sensitive` and `discoverable`
    static let created = #"""
{"collection":{"id":"117532232905645516","uri":"https://mastodon.localhost/ap/users/117532228402837528/collections/117532232905645516","name":"Friends","description":"People worth reading","language":null,"account_id":"117532228402837528","local":true,"sensitive":false,"discoverable":true,"url":"https://mastodon.localhost/collections/117532232905645516","item_count":0,"created_at":"2026-10-30T22:32:29.951Z","updated_at":"2026-10-30T22:32:29.951Z","tag":null,"items":[]}}
"""#

    /// the same, not to be found
    static let hiddenCreated = #"""
{"collection":{"id":"117532232909740656","uri":"https://mastodon.localhost/ap/users/117532228402837528/collections/117532232909740656","name":"Hidden","description":null,"language":null,"account_id":"117532228402837528","local":true,"sensitive":false,"discoverable":false,"url":"https://mastodon.localhost/collections/117532232909740656","item_count":0,"created_at":"2026-10-30T22:32:30.014Z","updated_at":"2026-10-30T22:32:30.014Z","tag":null,"items":[]}}
"""#

    /// `PATCH /api/v1/collections/:id`, name and a description of nothing
    static let changed = #"""
{"collection":{"id":"117532232905645516","uri":"https://mastodon.localhost/ap/users/117532228402837528/collections/117532232905645516","name":"Friends renamed","description":"","language":null,"account_id":"117532228402837528","local":true,"sensitive":false,"discoverable":true,"url":"https://mastodon.localhost/collections/117532232905645516","item_count":0,"created_at":"2026-10-30T22:32:29.951Z","updated_at":"2026-10-30T22:32:30.228Z","tag":null,"items":[]}}
"""#

    /// `POST /api/v1/collections/:id/items`
    static let itemAdded = #"""
{"collection_item":{"id":"117532232938512782","state":"accepted","created_at":"2026-10-30T22:32:30.461Z","account_id":"117532228418753996"}}
"""#

    /// `GET /api/v1/accounts/:id/collections`, by its owner, holding `read:collections`: the one not to be found is there
    static let ownList = #"""
{"collections":[{"id":"117532232909740656","uri":"https://mastodon.localhost/ap/users/117532228402837528/collections/117532232909740656","name":"Hidden","description":null,"language":null,"account_id":"117532228402837528","local":true,"sensitive":false,"discoverable":false,"url":"https://mastodon.localhost/collections/117532232909740656","item_count":0,"created_at":"2026-10-30T22:32:30.014Z","updated_at":"2026-10-30T22:32:30.014Z","tag":null,"items":[]},{"id":"117532232905645516","uri":"https://mastodon.localhost/ap/users/117532228402837528/collections/117532232905645516","name":"Friends renamed","description":"","language":null,"account_id":"117532228402837528","local":true,"sensitive":false,"discoverable":true,"url":"https://mastodon.localhost/collections/117532232905645516","item_count":2,"created_at":"2026-10-30T22:32:29.951Z","updated_at":"2026-10-30T22:32:30.310Z","tag":null,"items":[{"id":"117532232938512782","state":"accepted","created_at":"2026-10-30T22:32:30.461Z","account_id":"117532228418753996"},{"id":"117532232944933579","state":"accepted","created_at":"2026-10-30T22:32:30.551Z","account_id":"117532228402837528"}]}]}
"""#

    /// the same with no sign-in: only the one to be found
    static let listUnsigned = #"""
{"collections":[{"id":"117532232905645516","uri":"https://mastodon.localhost/ap/users/117532228402837528/collections/117532232905645516","name":"Friends renamed","description":"","language":null,"account_id":"117532228402837528","local":true,"sensitive":false,"discoverable":true,"url":"https://mastodon.localhost/collections/117532232905645516","item_count":2,"created_at":"2026-10-30T22:32:29.951Z","updated_at":"2026-10-30T22:32:30.310Z","tag":null,"items":[{"id":"117532232938512782","state":"accepted","created_at":"2026-10-30T22:32:30.461Z","account_id":"117532228418753996"},{"id":"117532232944933579","state":"accepted","created_at":"2026-10-30T22:32:30.551Z","account_id":"117532228402837528"}]}]}
"""#

    /// a name of 41 letters: 422
    static let tooLong = #"""
{"error":{"error":"Validation failed: Name is too long (maximum is 40 characters)","details":{"name":[{"error":"ERR_TOO_LONG","description":"is too long (maximum is 40 characters)"}]}}}
"""#

    /// a description of 101 letters: 422
    static let wordsTooLong = #"""
{"error":{"error":"Validation failed: Description is too long (maximum is 100 characters)","details":{"description":[{"error":"ERR_TOO_LONG","description":"is too long (maximum is 100 characters)"}]}}}
"""#

    /// a name of nothing: 422
    static let blank = #"""
{"error":{"error":"Validation failed: Name can't be blank","details":{"name":[{"error":"ERR_BLANK","description":"can't be blank"}]}}}
"""#

    /// a name alone: 422, `sensitive` and `discoverable` are wanted on making
    static let needsBoth = #"""
{"error":{"error":"Validation failed: Sensitive is not included in the list, Discoverable is not included in the list","details":{"sensitive":[{"error":"ERR_INCLUSION","description":"is not included in the list"}],"discoverable":[{"error":"ERR_INCLUSION","description":"is not included in the list"}]}}}
"""#

    /// adding someone in it, or who took themselves out of it: 422, and the error is a plain string
    static let alreadyIn = #"""
{"error":"Validation failed: Account has already been taken"}
"""#

    /// the eleventh collection of a person: 422, in a sentence the server failed to find
    static let tooManyCollections = #"""
{"error":{"error":"Validation failed: Translation missing. Options considered were:\n- en.activerecord.errors.models.collection.attributes.base.too_many\n- en.activerecord.errors.models.collection.too_many\n- en.activerecord.errors.messages.too_many\n- en.errors.attributes.base.too_many\n- en.errors.messages.too_many","details":{"base":[{"error":"ERR_TOO_MANY","description":"Translation missing. Options considered were:\n- en.activerecord.errors.models.collection.attributes.base.too_many\n- en.activerecord.errors.models.collection.too_many\n- en.activerecord.errors.messages.too_many\n- en.errors.attributes.base.too_many\n- en.errors.messages.too_many"}]}}}
"""#

    /// 403: not theirs, or a person who does not let themselves be added, or not in it
    static let notAllowed = #"""
{"error":"This action is not allowed"}
"""#

    /// 403 by a sign-in without the word
    static let outOfScope = #"""
{"error":"This action is outside the authorized scopes"}
"""#

    /// 404
    static let notFound = #"""
{"error":"Record not found"}
"""#

    /// making with 26 people: 422
    static let overPeople = #"""
{"error":{"error":"Validation failed: Collection items are too many, no more than 25 are allowed","details":{"collection_items":[{"error":"ERR_TOO_MANY","description":"are too many, no more than 25 are allowed"}]}}}
"""#

    /// `GET /api/v1/collections/:id` by its owner: one `pending`, one `accepted`
    static let pendingAsOwner = #"""
{"collection":{"id":"117532239155670303","uri":"https://mastodon.localhost/ap/users/117532228446847631/collections/117532239155670303","name":"With two","description":null,"language":null,"account_id":"117532228446847631","local":true,"sensitive":true,"discoverable":false,"url":"https://mastodon.localhost/collections/117532239155670303","item_count":2,"created_at":"2026-10-30T22:34:05.320Z","updated_at":"2026-10-30T22:34:05.320Z","tag":null,"items":[{"id":"117532239155632249","state":"pending","created_at":"2026-10-30T22:34:05.326Z","account_id":"117532228418753996"},{"id":"117532239155632250","state":"accepted","created_at":"2026-10-30T22:34:05.329Z","account_id":"117532228456870897"}]},"accounts":[{"id":"117532228446847631","username":"p2","acct":"p2","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-30T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@p2","uri":"https://mastodon.localhost/ap/users/117532228446847631","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]},{"id":"117532228418753996","username":"bob","acct":"bob","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-30T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@bob","uri":"https://mastodon.localhost/ap/users/117532228418753996","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]},{"id":"117532228456870897","username":"p3","acct":"p3","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-30T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@p3","uri":"https://mastodon.localhost/ap/users/117532228456870897","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]}]}
"""#

    /// the same by anyone else: the one `accepted` alone
    static let pendingAsAnother = #"""
{"collection":{"id":"117532239155670303","uri":"https://mastodon.localhost/ap/users/117532228446847631/collections/117532239155670303","name":"With two","description":null,"language":null,"account_id":"117532228446847631","local":true,"sensitive":true,"discoverable":false,"url":"https://mastodon.localhost/collections/117532239155670303","item_count":1,"created_at":"2026-10-30T22:34:05.320Z","updated_at":"2026-10-30T22:34:05.320Z","tag":null,"items":[{"id":"117532239155632250","state":"accepted","created_at":"2026-10-30T22:34:05.329Z","account_id":"117532228456870897"}]},"accounts":[{"id":"117532228446847631","username":"p2","acct":"p2","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-30T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@p2","uri":"https://mastodon.localhost/ap/users/117532228446847631","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]},{"id":"117532228456870897","username":"p3","acct":"p3","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-30T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@p3","uri":"https://mastodon.localhost/ap/users/117532228456870897","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]}]}
"""#

    /// What says a sign-in lacks the word.
    static let outOfScopeHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _write write:collections_.""#
}
