import Foundation
import Testing
@testable import FediqoCore

/// #309: what Fediqo believes a Mastodon says it has, held against the real one this checkout
/// brings up (`make servers`, Mastodon 4.6.6) — as `MastodonPeopleSaysTests` holds what it says
/// of people. The document is read through this app's own reader, `MastodonClient.said()`, and
/// beside it the server is asked plainly for each answer `MastodonHostCaptures` writes down.
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Nothing here writes, and nothing is switched.** What a directory or a list of what is
/// rising answers once its administrator has switched it off can be asked only from inside the
/// server; it was, once, and is in the captures' table.
///
/// **Asked gently.** A run makes some thirty requests and no registration.
@Suite("What a Mastodon says it has", .enabled(if: LocalServers.requested), .serialized)
struct MastodonHostSaysTests {
    private static let host = LocalServers.mastodon

    private struct Answer {
        let status: Int
        let body: Data
        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
        var object: [String: Any] { json as? [String: Any] ?? [:] }
        var ofTheAddress: Bool { MastodonHostNotFound.isOfTheAddress(status: status, body: body) }
    }

    private func ask(_ path: String, as token: String? = nil, method: String = "GET") async throws -> Answer {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, body: body)
    }

    @Test("Its document says how many hashtags an account may feature and nothing of the other things asked about, and is the document this app already reads for what the server is and how long a post may be")
    func theDocument() async throws {
        try await LocalServers.requireHealthy()
        let said = try await MastodonClient(http: try LocalHTTP.client(), host: Self.host).said()
        #expect(said.kind == .mastodon && said.profile?.statusLimit == 500)
        #expect(said.has == MastodonHostSays(document: Data(MastodonHostCaptures.document.utf8)), "as it was captured")
        #expect(said.has.featuredTagLimit == 10 && said.has.has(.featuredTags) == .present)
        // And, since #334, how many posts may be pinned and that it has no translator.
        #expect(said.has.pinLimit == 5 && said.has.translates == false && said.has.has(.translation) == .absent)
        // And, since #330, its API's own version, which says it has quotes.
        #expect(said.has.apiVersion == 11 && said.has.has(.quotes) == .present)
        // And, since #379, by the same word, that it lists the posts sharing a link rising on it.
        #expect(said.has.has(.linkPosts) == .present)
        for thing in MastodonHostThing.allCases where ![.featuredTags, .translation, .quotes, .linkPosts].contains(thing) {
            #expect(said.has.has(thing) == .unsaid, "\(thing)")
        }

        // The same bytes to anyone, and what the captures' table says is beside the one fact read.
        let plain = try await ask("/api/v2/instance"), signed = try await ask("/api/v2/instance", as: try LocalServers.writerToken())
        #expect(plain.status == 200 && plain.body == signed.body)
        let configuration = plain.object["configuration"] as? [String: Any] ?? [:]
        #expect((configuration["accounts"] as? [String: Any])?["max_featured_tags"] as? Int == 10)
        #expect((configuration["translation"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((configuration["urls"] as? [String: Any])?["streaming"] as? String == "wss://\(Self.host)")
        #expect((plain.object["api_versions"] as? [String: Any])?["mastodon"] is Int)
        for unsaid in ["suggestions", "directory", "trends", "announcements", "endorsements"] {
            #expect(plain.object[unsaid] == nil && configuration[unsaid] == nil, "\(unsaid) is said after all")
        }
        #expect(try await ask("/api/v1/instance").status == 200, "the older document is still served, and not read")
    }

    @Test("A not-found is spelled four ways, and only the one about a record is not about the address: an address it does not serve, a thing it has no means for, a thing kept from strangers — and somebody it has not got")
    func notFound() async throws {
        try await LocalServers.requireHealthy()
        let writer = try LocalServers.writerToken()
        for path in ["/api/v1/fediqo_no_such_thing", "/api/v9/instance", "/api/v1/instance/fediqo_no_such"] {
            let page = try await ask(path)
            #expect(page.status == 404 && page.json == nil && page.body.count > 500 && page.ofTheAddress, "\(path)")
        }
        let post = try LocalServers.seeded().seeded.plain
        let translate = try await ask("/api/v1/statuses/\(post)/translate", as: writer, method: "POST")
        #expect(translate.status == 404 && translate.object["error"] as? String == "Not Found" && translate.ofTheAddress)
        let kept = try await ask("/api/v1/instance/domain_blocks")
        #expect(kept.status == 404 && kept.body.isEmpty && kept.ofTheAddress)
        for path in ["/api/v1/accounts/1", "/api/v1/instance/terms_of_service"] {
            let record = try await ask(path)
            #expect(record.status == 404 && record.object["error"] as? String == "Record not found" && !record.ofTheAddress, "\(path)")
        }
    }

    @Test("A new server serves the address of every thing asked about: none answers that there is no such address, an empty one answers nobody and nothing, and the ones that want a sign-in say so with no not-found")
    func everyAddressIsServed() async throws {
        try await LocalServers.requireHealthy()
        let writer = try LocalServers.writerToken()
        let person = try #require(try LocalServers.seeded().people).person.id
        let open: [(MastodonHostThing, String)] = [
            (.directory, "/api/v1/directory"), (.risingTags, "/api/v1/trends/tags"), (.risingLinks, "/api/v1/trends/links"),
            (.longerAccount, "/api/v1/instance/extended_description"), (.knownServers, "/api/v1/instance/peers"),
            (.activity, "/api/v1/instance/activity"), (.featuredTags, "/api/v1/accounts/\(person)/featured_tags"),
            (.featuredPeople, "/api/v1/accounts/\(person)/endorsements"),
            (.pinnedPosts, "/api/v1/accounts/\(person)/statuses?pinned=true"),
        ]
        for (thing, path) in open {
            let answer = try await ask(path)
            #expect(answer.status == 200 && !answer.ofTheAddress, "\(thing): \(answer.status)")
        }
        // The directory was empty on a new server until the seed listed a few people in it
        // (#315). What is rising was too — exactly as it is switched off — until the seed made
        // a hashtag and a link rise (#320).
        #expect(((try await ask("/api/v1/directory").json as? [Any])?.count ?? 0) > 0, "the people the seed listed")
        for thing in [MastodonHostThing.risingTags, .risingLinks] {
            let path = try #require(open.first { $0.0 == thing }?.1)
            #expect((try await ask(path).json as? [Any])?.count == 1, "\(thing): what the seed made rise")
        }
        let signed: [(MastodonHostThing, String, Int)] = [
            (.suggestions, "/api/v2/suggestions", 401), (.announcements, "/api/v1/announcements", 422),
            (.featuredPeople, "/api/v1/endorsements", 401), (.featuredTags, "/api/v1/featured_tags", 401),
        ]
        for (thing, path, refusal) in signed {
            let asWriter = try await ask(path, as: writer), asNobody = try await ask(path)
            // Nobody was suggested on a new server until the seed named a few people to suggest
            // (#315), and nothing announced until it announced two (#321).
            let given: Int? = (asWriter.json as? [Any])?.count
            let asSeeded: Bool = switch thing {
            case .suggestions: given == 5
            case .announcements: given == 2
            default: asWriter.body == Data("[]".utf8)
            }
            #expect(asWriter.status == 200 && asSeeded, "\(thing): \(asWriter.status)")
            #expect(asNobody.status == refusal && !asNobody.ofTheAddress, "\(thing) with no sign-in: \(asNobody.status)")
        }
        let weeks = try await ask("/api/v1/instance/activity")
        #expect(((weeks.json as? [[String: Any]])?.first?["statuses"]) is String, "every figure a string")
        // All eleven were asked; translating is a post's, asked where posts are (`MastodonPostActsSaysTests`), and
        // the posts sharing a link a rising link's (`MastodonLinkPostsSaysTests`).
        #expect(Set(open.map(\.0)).union(signed.map(\.0)) == Set(MastodonHostThing.allCases).subtracting([.translation, .quotes, .linkPosts]))
    }
}
