import Foundation
import Testing
@testable import FediqoCore

@Suite("Detect")
struct DetectTests {
    @Test("HTML names Pleroma as Pleroma and does not probe")
    func htmlNamesPleromaWithoutProbe() async throws {
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("pleroma")),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        let kind = try await Detector(http: http).detect("pleroma.example")
        #expect(kind == .pleroma)
        #expect(await http.paths == ["/"])
    }

    @Test("HTML unknown and a Mastodon v2 instance is Mastodon")
    func htmlUnknownV2Mastodon() async throws {
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("unknown")),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("first.example") == .mastodon)
        #expect(await http.paths == ["/", "/api/v2/instance"])
    }

    @Test("HTML unknown and a Pleroma version on v2 is Pleroma")
    func htmlUnknownPleromaVersion() async throws {
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("unknown")),
            "/api/v2/instance": .text(
                #"{"version":"2.7.2 (compatible; Pleroma 2.6.3)","title":"Pleroma"}"#
            ),
        ])
        #expect(try await Detector(http: http).detect("pleroma.example") == .pleroma)
    }

    @Test("HTML names Akkoma even when v2 would look like Mastodon")
    func htmlAkkomaSkipsMastodonProbe() async throws {
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("akkoma")),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("https://akkoma.example/about") == .akkoma)
        #expect(await http.paths == ["/"])
    }

    @Test("Both GETs failing to talk is unreachable")
    func bothGetsFailUnreachable() async {
        let http = FixtureHTTP([
            "/": .fail,
            "/api/v2/instance": .fail,
        ])
        await #expect(throws: DetectError.unreachable) {
            try await Detector(http: http).detect("gone.example")
        }
        #expect(await http.paths == ["/", "/api/v2/instance"])
    }

    @Test("http:// and @user@host are invalidHost")
    func invalidHostFromDetect() async {
        let http = FixtureHTTP()
        await #expect(throws: DetectError.invalidHost) {
            try await Detector(http: http).detect("http://first.example")
        }
        await #expect(throws: DetectError.invalidHost) {
            try await Detector(http: http).detect("@a@b")
        }
        await #expect(throws: DetectError.invalidHost) {
            try await Detector(http: http).detect("{")
        }
        #expect(await http.paths.isEmpty)
    }

    @Test("IPv6 detect still uses the fixture client")
    func detectIPv6UsesFixtureHTTP() async throws {
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("pleroma")),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("https://[::1]/") == .pleroma)
        #expect(await http.requested.map(\.absoluteString) == ["https://[::1]/"])
    }

    @Test("HTML fixtures name their software; a body saying Mastodon is not enough")
    func htmlFixturesAndBodySubstring() {
        #expect(HTMLKind.classify(Self.html("mastodon")) == .named(.mastodon))
        #expect(HTMLKind.classify(Self.html("pleroma")) == .named(.pleroma))
        #expect(HTMLKind.classify(Self.html("akkoma")) == .named(.akkoma))
        #expect(HTMLKind.classify(Self.html("misskey")) == .named(.misskey))
        #expect(HTMLKind.classify(Self.html("pixelfed")) == .named(.pixelfed))
        #expect(HTMLKind.classify(Self.html("unknown")) == .unknown)
        #expect(HTMLKind.classify("<p>Welcome to Mastodon</p>") == .unknown)
        #expect(HTMLKind.classify(#"<meta name="generator" content="Lemmy">"#) == .named(.lemmy))
        #expect(HTMLKind.classify(#"<meta name="generator" content="PeerTube">"#) == .named(.peertube))
        #expect(HTMLKind.classify(#"<meta name="generator" content="Friendica">"#) == .named(.friendica))
        #expect(HTMLKind.classify(#"<meta name="generator" content="GoToSocial">"#) == .named(.gotosocial))
        #expect(HTMLKind.classify(#"<meta name="application-name" content="Mastodon">"#) == .named(.mastodon))
        #expect(HTMLKind.classify(#"<div id="mastodon"></div>"#) == .named(.mastodon))
        #expect(HTMLKind.classify(#"<a href="https://joinmastodon.org/">join</a>"#) == .named(.mastodon))
    }

    @Test("HTML unknown, probe version names the software; a v2 shape is Mastodon")
    func probeVersions() async throws {
        #expect(try await Self.probe(#"{"version":"2.7.2 (compatible; Akkoma 3.13.2)"}"#) == .akkoma)
        #expect(try await Self.probe(#"{"version":"0.17.0 (compatible; GoToSocial 0.17.0)"}"#) == .gotosocial)
        #expect(try await Self.probe(#"{"version":"2024.5.0 (Misskey)"}"#) == .misskey)
        #expect(try await Self.probe(#"{"version":"0.12.3+pixelfed"}"#) == .pixelfed)
        #expect(try await Self.probe(#"{"version":"4.3.0","domain":"first.example"}"#) == .mastodon)
        #expect(try await Self.probe(#"{"version":"4.3.0"}"#) == .unknown)
        #expect(try await Self.probe("not-json") == .unknown)
    }

    @Test("HTML that talks but does not name, and a dead probe, is unknown")
    func htmlTalksProbeFailsIsUnknown() async throws {
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("unknown")),
            "/api/v2/instance": .fail,
        ])
        #expect(try await Detector(http: http).detect("mystery.example") == .unknown)
    }

    @Test("A dead front page still probes")
    func deadHTMLStillProbes() async throws {
        let http = FixtureHTTP([
            "/": .fail,
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("first.example") == .mastodon)
    }

    @Test("Named HTML fixtures do not probe")
    func namedFixturesSkipProbe() async throws {
        for (name, kind) in [
            ("mastodon", ProtocolKind.mastodon),
            ("misskey", .misskey),
            ("pixelfed", .pixelfed),
        ] {
            let http = FixtureHTTP([
                "/": .body(Fixtures.html(name)),
                "/api/v2/instance": .text(Self.mastodonV2),
            ])
            #expect(try await Detector(http: http).detect("\(name).example") == kind)
            #expect(await http.paths == ["/"])
        }
    }

    private static let mastodonV2 = #"{"version":"4.3.0","title":"Mastodon","domain":"first.example"}"#

    private static func html(_ name: String) -> String {
        String(data: Fixtures.html(name), encoding: .utf8)!
    }

    private static func probe(_ json: String) async throws -> ProtocolKind {
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("unknown")),
            "/api/v2/instance": .text(json),
        ])
        return try await Detector(http: http).detect("probe.example")
    }
}
