import Foundation

/// The servers and addresses a Mastodon the reader answers for refuses or allows (#383), **as a
/// real server sent them** — the Mastodon 4.6.6 image `servers/compose.yml` pins, seeded by
/// `servers/mastodon/seed.rb`: two servers refused, one allowed, a mail domain and an address range
/// refused. Fetched on 2026-10-22 as the seed's Admin, and each write taken back after.
///
/// **Whole, not trimmed.** Each body is every byte the server sent, and each `Link` header as it
/// came. The servers named are the seed's, the addresses the documentation's own ranges.
///
/// | Asked (`/api/v1/admin/…`)                         | Answered                                        |
/// | ------------------------------------------------- | ----------------------------------------------- |
/// | `domain_blocks`, `domain_allows`, `email_domain_blocks`, `ip_blocks` | 200, each a list, newest first |
/// | `domain_blocks`, a new block                      | 200, the block as held                          |
/// | `domain_blocks/:id`, `PUT`                        | 200, the block as changed                       |
/// | any of the four, `DELETE`                         | `200 {}`                                        |
/// | a server already suspended, blocked again         | 422, the server's sentence and its block        |
/// | an address that is none                           | 422, the server's sentence                      |
/// | `domain_blocks`, as the Moderator                 | `403 {"error":"This action is not allowed"}`    |
enum MastodonAdminFederationCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v1/admin/domain_blocks` as the Admin: the two seeded, newest first.
    static let blocks = #"""
    [{"id":"2","domain":"limited.example","digest":"152aca1e43c2837e2ff68a7882e9ea1508bb01378046910ed5accfebf5a06a57","created_at":"2026-10-22T07:19:55.834Z","severity":"silence","reject_media":true,"reject_reports":false,"private_comment":"","public_comment":"Too loud","obfuscate":false},{"id":"1","domain":"suspended.example","digest":"e59c8bb674a866f5bcfcef1406937ef735c1ac2f6b9af6dac4069e8aaeb00ca6","created_at":"2026-10-22T07:19:55.783Z","severity":"suspend","reject_media":false,"reject_reports":false,"private_comment":"fediqo383seed spam","public_comment":"Spam","obfuscate":false}]
    """#

    /// Its `Link` header.
    static let blocksLink = #"""
    <https://mastodon.localhost/api/v1/admin/domain_blocks?min_id=2>; rel="prev"
    """#

    /// `GET /api/v1/admin/domain_allows`: the one seeded.
    static let allows = #"""
    [{"id":"1","domain":"allowed.example","created_at":"2026-10-22T07:19:55.847Z"}]
    """#

    /// Its `Link` header.
    static let allowsLink = #"""
    <https://mastodon.localhost/api/v1/admin/domain_allows?min_id=1>; rel="prev"
    """#

    /// `GET /api/v1/admin/email_domain_blocks`: the one seeded, with its days of use.
    static let mail = #"""
    [{"id":"1","domain":"spam.example","created_at":"2026-10-22T07:19:55.864Z","history":[{"day":"1792627200","accounts":"0","uses":"0"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"allow_with_approval":false}]
    """#

    /// Its `Link` header.
    static let mailLink = #"""
    <https://mastodon.localhost/api/v1/admin/email_domain_blocks?min_id=1>; rel="prev"
    """#

    /// `GET /api/v1/admin/ip_blocks`: the range seeded.
    static let ips = #"""
    [{"id":"1","ip":"192.0.2.0/24","severity":"sign_up_block","comment":"fediqo383seed range","created_at":"2026-10-22T07:19:55.871Z","expires_at":null}]
    """#

    /// Its `Link` header.
    static let ipsLink = #"""
    <https://mastodon.localhost/api/v1/admin/ip_blocks?min_id=1>; rel="prev"
    """#

    /// `POST …/domain_blocks`, suspending `fediqo383.example`: the block as held.
    static let blockAdded = #"""
    {"id":"3","domain":"fediqo383.example","digest":"d6a9add80625f18ae7c2ff37066d7bea199361bd775fa6d88bc84b7dc6bb1f43","created_at":"2026-10-22T07:20:18.572Z","severity":"suspend","reject_media":false,"reject_reports":false,"private_comment":null,"public_comment":"Spam","obfuscate":false}
    """#

    /// `PUT …/domain_blocks/:id` to limit it and refuse its media.
    static let blockChanged = #"""
    {"id":"3","domain":"fediqo383.example","digest":"d6a9add80625f18ae7c2ff37066d7bea199361bd775fa6d88bc84b7dc6bb1f43","created_at":"2026-10-22T07:20:18.572Z","severity":"silence","reject_media":true,"reject_reports":false,"private_comment":null,"public_comment":"Spam","obfuscate":false}
    """#

    /// `DELETE …/domain_blocks/:id`: answered with nothing.
    static let blockRemoved = #"""
    {}
    """#

    /// A server already suspended, blocked again: 422, in its words, with the block it holds.
    static let blockTwice = #"""
    {"error":"You have already imposed stricter limits on suspended.example.","existing_domain_block":{"id":"1","domain":"suspended.example","digest":"e59c8bb674a866f5bcfcef1406937ef735c1ac2f6b9af6dac4069e8aaeb00ca6","created_at":"2026-10-22T07:19:55.783Z","severity":"suspend","reject_media":false,"reject_reports":false,"private_comment":"fediqo383seed spam","public_comment":"Spam","obfuscate":false}}
    """#

    /// `POST …/domain_allows`.
    static let allowAdded = #"""
    {"id":"2","domain":"fediqo383.example","created_at":"2026-10-22T07:20:18.768Z"}
    """#

    /// `DELETE …/domain_allows/:id`.
    static let allowRemoved = #"""
    {}
    """#

    /// `POST …/email_domain_blocks`.
    static let mailAdded = #"""
    {"id":"2","domain":"fediqo383.example","created_at":"2026-10-22T07:20:18.799Z","history":[{"day":"1792627200","accounts":"0","uses":"0"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"allow_with_approval":false}
    """#

    /// `DELETE …/email_domain_blocks/:id`.
    static let mailRemoved = #"""
    {}
    """#

    /// `POST …/ip_blocks`, a range whose sign-ups wait for approval.
    static let ipAdded = #"""
    {"id":"2","ip":"198.51.100.0/24","severity":"sign_up_requires_approval","comment":"fediqo383 check","created_at":"2026-10-22T07:20:18.837Z","expires_at":null}
    """#

    /// `DELETE …/ip_blocks/:id`.
    static let ipRemoved = #"""
    {}
    """#

    /// An address that is none: 422, in its words.
    static let ipBad = #"""
    {"error":"Validation failed: Ip can't be blank"}
    """#

    /// The servers refused, asked by the Moderator, whose role does not answer for them: 403.
    static let modBlocks = #"""
    {"error":"This action is not allowed"}
    """#
}
