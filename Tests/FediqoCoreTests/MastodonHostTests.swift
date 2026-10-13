import Foundation
import Testing
@testable import FediqoCore

/// What one Mastodon host has, as far as a run knows: what its document says, read leniently
/// and bounded; a not-found told apart from a record that is not there; and the run's memory of
/// both. The document and each not-found are a real server's (`MastodonHostCaptures`).
@Suite("What one host says it has")
struct MastodonHostTests {
    private static let host = "m.example"
    private static let unsaid: [MastodonHostThing] = [
        .suggestions, .directory, .featuredPeople, .risingTags, .risingLinks, .announcements,
        .longerAccount, .knownServers, .activity, .pinnedPosts,
    ]

    private static func says(_ document: String) -> MastodonHostSays {
        MastodonHostSays(document: Data(document.utf8))
    }

    @Test("A real server's document says how many hashtags an account may feature, and of every other thing asked about it says nothing")
    func theDocumentSaysLittle() {
        let said = Self.says(MastodonHostCaptures.document)
        #expect(said.featuredTagLimit == 10 && said.has(.featuredTags) == .present)
        #expect(Self.unsaid.count == MastodonHostThing.allCases.count - 1)
        for thing in Self.unsaid { #expect(said.has(thing) == .unsaid, "\(thing)") }
        for thing in MastodonHostThing.allCases { #expect(MastodonHostSays.nothing.has(thing) == .unsaid, "\(thing)") }
    }

    @Test("A document is read leniently and never fails: a key missing or of another shape costs that fact and no other; none is not nothing said; less than none is nothing said; and a figure past belief is cut to what is believed")
    func readLeniently() {
        func limit(_ document: String) -> Int? { Self.says(document).featuredTagLimit }
        #expect(limit(#"{"configuration":{"accounts":{"max_featured_tags":3}}}"#) == 3)
        for silent in [
            "", "not a document", "[]", "null", "{}", #"{"configuration":null}"#, #"{"configuration":"closed"}"#,
            #"{"configuration":{"accounts":[1,2]}}"#, #"{"configuration":{"accounts":{}}}"#,
            #"{"configuration":{"accounts":{"max_featured_tags":"10"}}}"#, #"{"configuration":{"accounts":{"max_featured_tags":null}}}"#,
            #"{"configuration":{"accounts":{"max_featured_tags":-1}}}"#, #"{"configuration":{"accounts":{"max_featured_tags":2.5}}}"#,
            #"{"configuration":{"accounts":{"max_featured_tags":99999999999999999999999}}}"#,
        ] {
            #expect(Self.says(silent) == .nothing, "\(silent)")
        }
        let none = Self.says(#"{"configuration":{"accounts":{"max_featured_tags":0}}}"#)
        #expect(none.featuredTagLimit == 0 && none.has(.featuredTags) == .absent && none != .nothing)
        #expect(limit(#"{"configuration":{"accounts":{"max_featured_tags":5000000}}}"#) == MastodonHostSays.most && MastodonHostSays.most == 1_000)
        #expect(MastodonHostSays(featuredTagLimit: -4) == .nothing && MastodonHostSays(featuredTagLimit: Int.max).featuredTagLimit == 1_000)
        // A branch of another shape beside it costs nothing: the fact is still read.
        #expect(limit(#"{"title":7,"rules":"none","configuration":{"statuses":"long","accounts":{"max_featured_tags":4,"max_pinned_statuses":"x"}}}"#) == 4)
    }

    @Test("What a host has is read out of the document already asked for — one request, three readings, each its own: a document the profile cannot be read from still says what it has, and one that did not come is not a host that said nothing")
    func oneRequest() async throws {
        let whole = FixtureHTTP(["/api/v2/instance": .text(MastodonHostCaptures.document)])
        let said = try await MastodonClient(http: whole, host: Self.host).said()
        #expect(said.kind == .mastodon && said.profile?.statusLimit == 500 && said.has.featuredTagLimit == 10)
        #expect(await whole.paths == ["/api/v2/instance"])

        // The profile's reading is strict and this one is not: a title that is no string costs the profile alone.
        let odd = FixtureHTTP(["/api/v2/instance": .text(#"{"title":7,"configuration":{"accounts":{"max_featured_tags":2}}}"#)])
        let partly = try await MastodonClient(http: odd, host: Self.host).said()
        #expect(partly.profile == nil && partly.has.featuredTagLimit == 2)

        let silent = FixtureHTTP(["/api/v2/instance": .text("{}")])
        let nothing = try await MastodonClient(http: silent, host: Self.host).said()
        #expect(nothing.has == .nothing && nothing.profile != nil)
        // What was read before is read as before, by the same one request.
        let before = try await MastodonClient(http: silent, host: Self.host).introduction()
        #expect(before.kind == nothing.kind && before.profile == nothing.profile)
        #expect(await silent.paths == ["/api/v2/instance", "/api/v2/instance"])

        for outcome in [FixtureHTTP.Outcome.fail, .text(MastodonHostCaptures.noSuchAddress, status: 404), .text("{}", status: 503)] {
            let down = FixtureHTTP(["/api/v2/instance": outcome])
            await #expect(throws: (any Error).self) { try await MastodonClient(http: down, host: Self.host).said() }
        }
    }

    @Test("A not-found is a word about the host only where it is about the address: a page of its own, a thing switched off, a thing kept from strangers — and never somebody or something it has not got, nor any answer that is no not-found")
    func notFoundToldApart() {
        func address(_ status: Int, _ body: String) -> Bool {
            MastodonHostNotFound.isOfTheAddress(status: status, body: Data(body.utf8))
        }
        #expect(address(404, MastodonHostCaptures.noSuchAddress))
        #expect(address(404, MastodonHostCaptures.noMeansForIt))
        #expect(address(404, MastodonHostCaptures.keptFromStrangers))
        #expect(!address(404, MastodonHostCaptures.noSuchRecord))
        #expect(!address(404, #"{"error":"RECORD NOT FOUND"}"#) && !address(404, #"{"error":"Record not found","status":404,"more":[1]}"#))
        #expect(address(404, #"{"error":"NOT FOUND"}"#) && address(404, #"{"error":"Not Found","status":404,"more":[1]}"#))
        // Its own sentence in a wording nobody asked of it is not known to be about the address:
        // one account a fork has not got must not hide the thing for every account there.
        for unknown in [#"{"error":"Can't find user"}"#, #"{"error":"Not found: account"}"#, #"{"error":7}"#, #"{"message":"Not Found"}"#,
                        #"["Not Found"]"#, #""Not Found""#, "{}", "null"] {
            #expect(!address(404, unknown), "\(unknown)")
        }
        // No sentence at all — nothing, a page, words that are no document — is the address.
        #expect(address(404, "Record not found") && address(404, "<html>Not here</html>") && address(404, "{"))
        // A whole page is not read for the sentence.
        #expect(address(404, String(repeating: " ", count: MastodonHostNotFound.bodyLength) + MastodonHostCaptures.noSuchRecord))
        for status in [200, 301, 401, 403, 410, 422, 429, 500, 503] {
            #expect(!address(status, MastodonHostCaptures.noMeansForIt) && !address(status, ""), "\(status)")
        }
        #expect(!address(422, MastodonHostCaptures.wantsASignIn))
    }

    @Test("The run remembers, by host: nothing of one not heard from, which is how its one ask is known to be owed; what its document said once it is; a not-found for the one thing at the one host, believed over the document — until the document is read again, or the host is asked afresh, and then nothing of it stands")
    func theRunRemembers() {
        var known = MastodonHostsKnown()
        #expect(known.said(at: Self.host) == nil && known == MastodonHostsKnown())
        for thing in MastodonHostThing.allCases { #expect(known.has(thing, at: Self.host) == .unsaid) }

        known.heard(Self.says(MastodonHostCaptures.document), at: "M.Example")
        #expect(known.said(at: Self.host)?.featuredTagLimit == 10 && known.said(at: "other.example") == nil)
        #expect(known.has(.featuredTags, at: Self.host) == .present && known.has(.featuredTags, at: "other.example") == .unsaid)
        #expect(known.has(.suggestions, at: Self.host) == .unsaid)

        known.notFound(.suggestions, at: Self.host)
        known.notFound(.featuredTags, at: "m.EXAMPLE")
        #expect(known.has(.suggestions, at: Self.host) == .absent && known.has(.featuredTags, at: Self.host) == .absent)
        #expect(known.has(.directory, at: Self.host) == .unsaid && known.has(.suggestions, at: "other.example") == .unsaid)

        // A not-found before the document was read: remembered, and the document is still owed.
        known.notFound(.activity, at: "late.example")
        #expect(known.has(.activity, at: "late.example") == .absent && known.said(at: "late.example") == nil)

        // Read again, the document is believed afresh and what its addresses answered is let go — there, and nowhere else.
        known.heard(MastodonHostSays(featuredTagLimit: 3), at: "M.example")
        #expect(known.said(at: Self.host)?.featuredTagLimit == 3 && known.has(.featuredTags, at: Self.host) == .present)
        #expect(known.has(.suggestions, at: Self.host) == .unsaid, "a not-found is not for ever")
        #expect(known.has(.activity, at: "late.example") == .absent)

        // Asked afresh — the person's reload, a sign-in that changed: a host not heard from.
        known.notFound(.directory, at: Self.host)
        known.askAfresh("M.EXAMPLE")
        #expect(known.said(at: Self.host) == nil, "its document is owed again")
        for thing in MastodonHostThing.allCases { #expect(known.has(thing, at: Self.host) == .unsaid, "\(thing)") }
        #expect(known.has(.activity, at: "late.example") == .absent)
        known.askAfresh("late.example")
        #expect(known == MastodonHostsKnown())
    }

    @Test("What a host has is kept here and nowhere a kind of source is described; nothing of it is an address; and no version is read")
    func whereItLives() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let core = root.appending(path: "Sources/FediqoCore")
        let here = try String(contentsOf: core.appending(path: "MastodonHost.swift"), encoding: .utf8)
        let code = here.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for word in ["URL", "version", "Version", "apiVersions", "http", "SourceOffers", "ProtocolKind"] {
            #expect(!code.contains(word), "MastodonHost.swift's code names \(word)")
        }
        // The one reader of the document hands on three readings and reads no version for this
        // one. (`Probe.kind` does read the version string, for what KIND of server answers —
        // which is not what a host has, and is how a fork is told from a Mastodon at all.)
        let reader = try String(contentsOf: core.appending(path: "Mastodon.swift"), encoding: .utf8)
        let from = try #require(reader.range(of: "public func said() async throws"))
        let body = reader[from.lowerBound...].prefix { $0 != "}" }
        #expect(body.contains("MastodonHostSays(document: data)") && body.contains("Probe.kind(from: data)"))
        for word in ["version", "Version", "apiVersions"] { #expect(!body.contains(word), "said() reads \(word)") }
        let offers = try String(contentsOf: core.appending(path: "SourceOffers.swift"), encoding: .utf8)
        for word in ["MastodonHostThing", "MastodonHostSays", "MastodonHostsKnown", "suggestions", "directory", "announcements", "featured"] {
            #expect(!offers.contains(word), "SourceOffers.swift names \(word)")
        }
    }
}
