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
        #expect(HTMLKind.classify(Self.html("discuz")) == .named(.discuz))
    }

    @Test("Every protocol in the list is reachable from its own name, whatever the order")
    func everyNameInTheListIsReachable() {
        // **Enumerated rather than listed**, because the hazard is the name added *next*.
        // `classify` is a ladder of substring tests, so it is correct only while no two names in
        // it contain one another — and the moment one does, the loser becomes unreachable in
        // silence: no error, no warning, just a host detected as the wrong software. A comment
        // saying "mind the ordering" is not a check; this is.
        //
        // `discuz` and `discourse` are the pair it was written for. They share four letters and
        // neither contains the other, which is why their order does not matter — but that is a
        // fact about today's list, not a property of the mechanism.
        for kind in ProtocolKind.allCases where kind != .unknown {
            let generator = #"<meta name="generator" content="\#(kind.rawValue)">"#
            #expect(HTMLKind.classify(generator) == .named(kind), "\(kind.rawValue)")
        }

        // And the two forums as the software really writes itself, exclamation mark and all.
        #expect(
            HTMLKind.classify(#"<meta name="generator" content="Discuz! X3.4" />"#) == .named(.discuz)
        )
        #expect(
            HTMLKind.classify(#"<meta name="generator" content="Discourse 3.4.0">"#)
                == .named(.discourse)
        )
    }

    @Test("A Discuz! front page is detected without a probe")
    func discuzIsNamedWithoutProbe() async throws {
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("discuz")),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("install-e.example") == .discuz)
        #expect(await http.paths == ["/"])
    }

    @Test("One byte that is not UTF-8 does not hide a whole forum")
    func oneBadByteDoesNotHideTheSoftware() async throws {
        // Captured byte for byte from `install-a.example`, a running Discuz! X3.4 whose front page
        // declares UTF-8 and is UTF-8 apart from a few leftover GBK bytes in a script comment.
        // Under the strict decode that stood here, the whole 50KB became `nil` and the host was
        // reported as an unknown protocol — found by running the thing against real forums, not
        // by any fixture, because every fixture had been captured clean.
        let page = Fixtures.html("discuz-mixed-encoding")
        #expect(String(data: page, encoding: .utf8) == nil, "the fixture must not be valid UTF-8")

        // The generator tag is ASCII, so it survives the lossy decode exactly.
        #expect(HTMLKind.classify(String(decoding: page, as: UTF8.self)) == .named(.discuz))

        let http = FixtureHTTP([
            "/": .body(page),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("install-a.example") == .discuz)
        // And it is named from the HTML, so the probe is never reached.
        #expect(await http.paths == ["/"])
    }

    @Test("A front page in an encoding this device does not guess still names its software")
    func aNonUTF8FrontPageStillNamesItself() async throws {
        // The general case behind the one above: an install that serves GBK throughout. Nothing
        // here guesses an encoding — the software's name is ASCII either way, and the words
        // around it are not read.
        let http = FixtureHTTP([
            "/": .body(Fixtures.html("discuz-gbk-guide")),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("install-d.example") == .discuz)
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
