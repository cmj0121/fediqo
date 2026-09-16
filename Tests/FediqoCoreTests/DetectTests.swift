import Foundation
import Testing
@testable import FediqoCore

/// Naming the software a host speaks.
///
/// **Where the markup in this file comes from, stated plainly.** The six protocol pages below are
/// hand-written and always were: each is the few lines that carry one marker `HTMLKind.classify`
/// looks for, and nothing else. The three Discuz! pages are hand-written *now* — they replace
/// captures of running installs, and what they can no longer do is stand as evidence that a real
/// Discuz! emits these bytes. What they still do honestly is the part the encoding tests are
/// about: `Self.mixedEncodingPage` and `Self.gbkIndexPage` are assembled from **raw bytes** rather
/// than from a Swift `String`, so the claim "these bytes are not valid UTF-8" is a fact about the
/// data and not a round-trip through Foundation, and each test asserts it before relying on it.
@Suite("Detect")
struct DetectTests {
    @Test("HTML names Pleroma as Pleroma and does not probe")
    func htmlNamesPleromaWithoutProbe() async throws {
        let http = FixtureHTTP([
            "/": .text(Self.pleromaPage),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        let kind = try await Detector(http: http).detect("pleroma.example")
        #expect(kind == .pleroma)
        #expect(await http.paths == ["/"])
    }

    @Test("HTML unknown and a Mastodon v2 instance is Mastodon")
    func htmlUnknownV2Mastodon() async throws {
        let http = FixtureHTTP([
            "/": .text(Self.unknownPage),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("first.example") == .mastodon)
        #expect(await http.paths == ["/", "/api/v2/instance"])
    }

    @Test("HTML unknown and a Pleroma version on v2 is Pleroma")
    func htmlUnknownPleromaVersion() async throws {
        let http = FixtureHTTP([
            "/": .text(Self.unknownPage),
            "/api/v2/instance": .text(
                #"{"version":"2.7.2 (compatible; Pleroma 2.6.3)","title":"Pleroma"}"#
            ),
        ])
        #expect(try await Detector(http: http).detect("pleroma.example") == .pleroma)
    }

    @Test("HTML names Akkoma even when v2 would look like Mastodon")
    func htmlAkkomaSkipsMastodonProbe() async throws {
        let http = FixtureHTTP([
            "/": .text(Self.akkomaPage),
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
            "/": .text(Self.pleromaPage),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("https://[::1]/") == .pleroma)
        #expect(await http.requested.map(\.absoluteString) == ["https://[::1]/"])
    }

    @Test("A page names its software; a body saying Mastodon is not enough")
    func htmlPagesAndBodySubstring() {
        #expect(HTMLKind.classify(Self.mastodonPage) == .named(.mastodon))
        #expect(HTMLKind.classify(Self.pleromaPage) == .named(.pleroma))
        #expect(HTMLKind.classify(Self.akkomaPage) == .named(.akkoma))
        #expect(HTMLKind.classify(Self.misskeyPage) == .named(.misskey))
        #expect(HTMLKind.classify(Self.pixelfedPage) == .named(.pixelfed))
        #expect(HTMLKind.classify(Self.unknownPage) == .unknown)
        #expect(HTMLKind.classify("<p>Welcome to Mastodon</p>") == .unknown)
        #expect(HTMLKind.classify(#"<meta name="generator" content="Lemmy">"#) == .named(.lemmy))
        #expect(HTMLKind.classify(#"<meta name="generator" content="PeerTube">"#) == .named(.peertube))
        #expect(HTMLKind.classify(#"<meta name="generator" content="Friendica">"#) == .named(.friendica))
        #expect(HTMLKind.classify(#"<meta name="generator" content="GoToSocial">"#) == .named(.gotosocial))
        #expect(HTMLKind.classify(#"<meta name="application-name" content="Mastodon">"#) == .named(.mastodon))
        #expect(HTMLKind.classify(#"<div id="mastodon"></div>"#) == .named(.mastodon))
        #expect(HTMLKind.classify(#"<a href="https://joinmastodon.org/">join</a>"#) == .named(.mastodon))
        #expect(HTMLKind.classify(Self.discuzPage) == .named(.discuz))
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
            "/": .text(Self.discuzPage),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("install-e.example") == .discuz)
        #expect(await http.paths == ["/"])
    }

    @Test("One byte that is not UTF-8 does not hide a whole forum")
    func oneBadByteDoesNotHideTheSoftware() async throws {
        // The defect: a front page that declares UTF-8 and is UTF-8 apart from a few leftover
        // GBK bytes in a script comment. Under a strict `String(data:encoding:.utf8)` the whole
        // page becomes `nil` — not a mangled string somebody would notice, nothing at all — and
        // the host falls through to the probe and is reported as an unknown protocol.
        //
        // The two stray bytes here are put in by hand, as bytes, for exactly that reason: the
        // assertion below is then a fact about the data rather than a fact about Foundation.
        let page = Self.mixedEncodingPage
        #expect(String(data: page, encoding: .utf8) == nil, "the page must not be valid UTF-8")

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
        let page = Self.gbkIndexPage
        #expect(String(data: page, encoding: .utf8) == nil, "the page must not be valid UTF-8")

        let http = FixtureHTTP([
            "/": .body(page),
            "/api/v2/instance": .text(Self.mastodonV2),
        ])
        #expect(try await Detector(http: http).detect("install-d.example") == .discuz)
        #expect(await http.paths == ["/"])
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
            "/": .text(Self.unknownPage),
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

    @Test("Named HTML pages do not probe")
    func namedPagesSkipProbe() async throws {
        for (page, kind) in [
            (Self.mastodonPage, ProtocolKind.mastodon),
            (Self.misskeyPage, .misskey),
            (Self.pixelfedPage, .pixelfed),
        ] {
            let http = FixtureHTTP([
                "/": .text(page),
                "/api/v2/instance": .text(Self.mastodonV2),
            ])
            #expect(try await Detector(http: http).detect("\(kind.rawValue).example") == kind)
            #expect(await http.paths == ["/"])
        }
    }

    private static let mastodonV2 = #"{"version":"4.3.0","title":"Mastodon","domain":"first.example"}"#

    private static func probe(_ json: String) async throws -> ProtocolKind {
        let http = FixtureHTTP([
            "/": .text(Self.unknownPage),
            "/api/v2/instance": .text(json),
        ])
        return try await Detector(http: http).detect("probe.example")
    }

    // MARK: - The six protocol pages
    //
    // One marker each, written out rather than captured, which is what they always were. Between
    // them they cover the three ways `classify` can be told a name: a `generator` meta, an
    // `application-name` meta, and a boot script's own global.

    private static let mastodonPage = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="application-name" content="Mastodon">
      <link rel="help" href="https://joinmastodon.org/">
      <title>Mastodon</title>
    </head>
    <body>
      <div id="mastodon"></div>
    </body>
    </html>
    """#

    private static let pleromaPage = #"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta name="generator" content="Pleroma">
      <title>Pleroma</title>
    </head>
    <body>
      <p>A Pleroma instance. Mastodon clients can talk to it.</p>
    </body>
    </html>
    """#

    private static let akkomaPage = #"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta content="Akkoma" name="generator">
      <title>Akkoma</title>
    </head>
    <body>
      <p>Akkoma, based on Pleroma. Mastodon API is nearby.</p>
    </body>
    </html>
    """#

    private static let misskeyPage = #"""
    <!DOCTYPE html>
    <html>
    <head>
      <title>Misskey</title>
    </head>
    <body>
      <div id="misskey_app"></div>
      <script>window.__misskey_boot__ = { version: "2024.5.0" };</script>
    </body>
    </html>
    """#

    private static let pixelfedPage = #"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta name="generator" content="pixelfed">
      <title>Pixelfed</title>
    </head>
    <body>
      <p>Photos on Pixelfed.</p>
    </body>
    </html>
    """#

    private static let unknownPage = #"""
    <!DOCTYPE html>
    <html>
    <head>
      <title>A personal site</title>
    </head>
    <body>
      <p>Welcome. This mentions Mastodon in passing, which is not enough.</p>
    </body>
    </html>
    """#

    // MARK: - Three Discuz! pages

    /// A Discuz! X3.4 head that declares UTF-8 and is UTF-8, naming itself in the generator meta.
    private static let discuzPage = #"""
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <title>示例论坛 -  Powered by Discuz!</title>
    <meta name="keywords" content="示例,论坛" />
    <meta name="generator" content="Discuz! X3.4" />
    <meta name="author" content="Discuz! Team and Comsenz UI Team" />
    <meta name="MSSmartTagsPreventParsing" content="True" />
    <base href="https://install-e.example/" />
    <meta name="application-name" content="示例论坛" />
    </head>
    <body></body></html>
    """#

    /// Bytes that **declare** UTF-8 and are not UTF-8: valid markup with two GBK leftovers spliced
    /// into a script comment, the way a template that was converted years ago still serves them.
    ///
    /// Built as bytes rather than by encoding a Swift `String`, so that the test's
    /// `String(data:encoding:.utf8) == nil` is a claim about this data and not a claim that
    /// Foundation round-trips itself.
    private static var mixedEncodingPage: Data {
        var bytes = Array(#"""
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
        <title>示例数码论坛</title>
        <meta name="generator" content="Discuz! X3.4" />
        <meta name="author" content="Discuz! Team and Comsenz UI Team" />
        <base href="https://install-a.example/" />
        </head>
        <body>
        <script type="text/javascript">
        //
        """#.utf8)
        // Neither of these can begin a UTF-8 sequence where it stands: 0xB2 is a continuation
        // byte with nothing in front of it, and 0xE2 announces two continuation bytes that the
        // ASCII newline after it is not. Two bytes in fifty kilobytes were enough.
        bytes += [0xB2, 0xE2]
        bytes += Array(#"""

        var comiis_mobreg_timeout;
        function comiis_mobreg_fkey(type){
        var phone = jQuery("."+type);
        }
        </script>
        </body></html>
        """#.utf8)
        return Data(bytes)
    }

    /// A whole index served as GBK, which a great many Discuz! installs still are.
    ///
    /// The board names are real GBK code points written out byte by byte — `官方区`,
    /// `官方软件区`, `资讯区` — so the page is genuinely undecodable as UTF-8 rather than
    /// decoratively so.
    private static var gbkIndexPage: Data {
        let officialBoard: [UInt8] = [0xB9, 0xD9, 0xB7, 0xBD, 0xC7, 0xF8]  // 官方区
        let softwareBoard: [UInt8] = [
            0xB9, 0xD9, 0xB7, 0xBD, 0xC8, 0xED, 0xBC, 0xFE, 0xC7, 0xF8,
        ]  // 官方软件区
        let newsBoard: [UInt8] = [0xD7, 0xCA, 0xD1, 0xB6, 0xC7, 0xF8]  // 资讯区

        var bytes = Array(#"""
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta http-equiv="Content-Type" content="text/html; charset=gbk" />
        <title>
        """#.utf8)
        bytes += officialBoard
        bytes += Array(#"""
        </title>
        <meta name="generator" content="Discuz! X3.4" />
        <meta name="author" content="Discuz! Team and Comsenz UI Team" />
        <base href="https://install-d.example/" />
        </head>
        <body>
        <div class="bm bmw flg cl">
        <h2><a href="forum-2-1.html">
        """#.utf8)
        bytes += softwareBoard
        bytes += Array(#"""
        </a></h2>
        <h2><a href="forum-3-1.html">
        """#.utf8)
        bytes += newsBoard
        bytes += Array(#"""
        </a></h2>
        </div>
        </body></html>
        """#.utf8)
        return Data(bytes)
    }
}
