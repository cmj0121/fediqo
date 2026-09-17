import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

@Suite("Account add")
@MainActor
struct AccountAddTests {
    init() {
        L10n.language = .english
    }

    @Test("Adding a Mastodon stores the source, All and Trends, and enables the timeline")
    func addAMastodon() async {
        // One server that names itself, one instance document, one public status and one
        // trending status — the four answers a join needs, and nothing else.
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head>
            <body><div id="mastodon"></div></body></html>
            """#),
            "/api/v2/instance": .text(#"""
            {"domain": "first.example", "title": "First", "version": "4.3.0"}
            """#),
            "/api/v1/timelines/public": .text(#"""
            [{"id": "100", "uri": "https://first.example/users/ada/statuses/1",
              "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Hello</p>",
              "visibility": "public",
              "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}]
            """#),
            "/api/v1/trends/statuses": .text(#"""
            [{"id": "400", "uri": "https://first.example/users/ada/statuses/2",
              "created_at": "2024-09-01T00:00:00.000Z", "content": "<p>Trending</p>",
              "visibility": "public",
              "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}]
            """#),
        ]))
        session.hostname = "first.example"
        await session.add()
        await session.confirm()
        #expect(session.sources.map(\.host) == ["first.example"])
        #expect(session.queries.map(\.id) == ["all", "trends"])
        #expect(session.timelineID == "all")
        #expect(session.availability.timelineEnabled)
        #expect(!session.availability.allows(.notices))
        #expect(!session.availability.canCompose)
        #expect(!session.notes.isEmpty)
        #expect(session.refuse == nil)
        #expect(session.isAdded("first.example"))
    }

    @Test("Pleroma HTML is refused by name; store empty; timeline still disabled")
    func refusePleromaByName() async {
        // The one line that decides it: Pleroma puts its own name in the generator meta.
        let http = FixtureHTTP(["/": .text(#"""
        <html><head><meta name="generator" content="Pleroma"></head>
        <body><p>Mastodon clients can talk to it.</p></body></html>
        """#)])
        let session = ShellSession(http: http)
        session.hostname = "pleroma.example"
        await session.add()
        #expect(
            session.refuse
                == String(
                    format: L10n.t("account.refuse.kind", language: .english),
                    "pleroma.example",
                    "Pleroma"
                )
        )
        #expect(session.sources.isEmpty)
        #expect(session.notes.isEmpty)
        #expect(session.queries.isEmpty)
        #expect(!session.availability.timelineEnabled)
    }

    @Test("Adding the same host again is a duplicate")
    func duplicateAdd() async {
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [{"id": "100", "uri": "https://first.example/users/ada/statuses/1",
              "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Hello</p>",
              "visibility": "public",
              "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}]
            """#),
            "/api/v1/trends/statuses": .text("[]"),
        ]))
        session.hostname = "https://First.Example/about"
        await session.add()
        await session.confirm()
        #expect(session.sources.count == 1)
        session.hostname = "first.example"
        // **The duplicate is caught before the look**, which is what keeps it free: a host this
        // device already reads costs no detection and no profile request, only the sentence.
        await session.add()
        #expect(session.stage == nil, "a duplicate opened a preview of a server already added")
        #expect(session.refuse == L10n.t("account.refuse.duplicate", language: .english))
        #expect(session.sources.count == 1)
        #expect(session.availability.timelineEnabled)
    }

    @Test("The catalog maps the directory's rows, in the order it listed them")
    func catalogMapsDirectoryRows() async {
        let session = ShellSession(http: FixtureHTTP([
            "/servers": .text(#"""
            [
              {"domain": "first.example", "description": "The flagship server",
               "language": "en", "region": "europe", "category": "general",
               "total_users": 1000000, "last_week_users": 50000,
               "approval_required": false,
               "proxied_thumbnail": "https://proxy.example/first.png"},
              {"domain": "second.example", "description": "A community for professionals",
               "language": "en", "region": "north_america", "category": "tech",
               "total_users": 40000, "last_week_users": 2000,
               "approval_required": true, "proxied_thumbnail": null}
            ]
            """#),
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
            """#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [{"id": "100", "uri": "https://first.example/users/ada/statuses/1",
              "created_at": "2024-01-01T00:00:00.000Z", "content": "<p>Hello</p>",
              "visibility": "public",
              "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}}]
            """#),
            "/api/v1/trends/statuses": .text("[]"),
        ]))
        await session.loadCatalog()
        guard case .ready(let servers) = session.catalog else {
            Issue.record("catalog \(session.catalog)")
            return
        }
        #expect(servers.map(\.domain) == ["first.example", "second.example"])
        #expect(servers[0].summary == "The flagship server")
        // **Decision 39: the picker row keeps the description and the figures**, because this row
        // is the evidence a reader decides on. `CatalogServer` carries all of it, so it costs no
        // request — and a directory that stopped serving them would leave a row with nothing on it
        // to choose by.
        #expect(servers[0].weekUsers == 50_000)
        #expect(servers[0].users == 1_000_000)
        #expect(servers[0].language == "en")
        // A chosen server fills the field and looks, exactly as typing does — decision 38.
        // Pressing one opens the preview and adds nothing; it is the press after it that joins.
        await session.pick(servers[0])
        #expect(session.hostname == "first.example")
        #expect(session.sources.isEmpty, "a catalog row joined a server the reader only looked at")
        await session.confirm()
        #expect(session.sources.map(\.host) == ["first.example"])
        #expect(session.availability.timelineEnabled)
    }

    @Test("Invalid host is refused as unknown, never 'is unknown'")
    func invalidHost() async {
        let session = ShellSession(http: FixtureHTTP())
        session.hostname = "http://first.example"
        await session.add()
        #expect(
            session.refuse
                == String(
                    format: L10n.t("account.refuse.unknown", language: .english),
                    "http://first.example"
                )
        )
        #expect(!(session.refuse ?? "").contains("is unknown"))
        #expect(session.sources.isEmpty)
        #expect(!session.availability.timelineEnabled)
    }

    @Test("Unreachable host is a network refuse")
    func unreachableHost() async {
        let http = FixtureHTTP(["/": .fail, "/api/v2/instance": .fail])
        let session = ShellSession(http: http)
        session.hostname = "gone.example"
        await session.add()
        #expect(session.refuse == L10n.t("account.refuse.network", language: .english))
        #expect(session.sources.isEmpty)
        #expect(!session.availability.timelineEnabled)
    }

    /// **The browser shows the directory as the directory listed it, and filters nothing** —
    /// decision 38's "no input", which deletes four tests and is declared rather than done
    /// quietly.
    ///
    /// What went: `visibleServers` (the live filter over domain and description), `extraJoinHost`
    /// (a typed host the directory does not carry, offered as its own row), `matches(_:query:)`
    /// and `query`. All four were computed off `session.hostname`, which is the *page's* field —
    /// so with no field in the sheet they would have become a hidden filter with no visible cause:
    /// a reader who typed `flagship`, pressed Browse and picked Mastodon would meet one server and
    /// no explanation. The four tests that pinned them described a screen that no longer exists.
    ///
    /// **The route those tests were really protecting is not lost, it moved to the page.** A host
    /// the directory does not list is typed into the field and pressed, which is `typedHost()` and
    /// is pinned in `SourcePageTests`; the browser is for readers who do not have a hostname.
    ///
    /// **What this checks, stated exactly, because the claim above is larger than the assertion.**
    /// It observes one thing: `ShellSession` offers no reading of the catalogue that `hostname`
    /// can move. That is the whole of what a test can reach here — the four deleted members are
    /// gone at compile time, which is a stronger pin than any assertion and is also why nothing
    /// here can fail on their account.
    ///
    /// **What it does not reach: a filter reintroduced inside `JoinSheet.servers(of:)`.** The
    /// sheet's body is a `View` body and this project has no UI test target (risk 12), so a
    /// `.filter` written between the catalogue and the `ForEach` would pass this test. Named
    /// rather than implied — a doc claiming the screen is covered is how the four defects risk 12
    /// counts survived a green suite, and this test's first draft made exactly that claim.
    @Test("The session offers no filtered reading of the catalogue for the field to move")
    func theBrowserDoesNotFilter() async {
        let session = ShellSession(http: FixtureHTTP(["/servers": .text(#"""
        [
          {"domain": "first.example", "description": "The flagship server"},
          {"domain": "second.example", "description": "A community for professionals"}
        ]
        """#)]))
        session.browse()
        session.chooseProtocol(.mastodon)
        await session.loadCatalog()

        // Whatever is in the page's field, and whether it is a hostname or a word.
        for typed in ["", "seco", "flagship", "my.example"] {
            session.hostname = typed
            guard case .ready(let servers) = session.catalog else {
                Issue.record("catalog \(session.catalog)")
                return
            }
            #expect(servers.map(\.domain) == ["first.example", "second.example"], """
                The session grew a reading of the catalogue that the page's field narrows — a \
                filter with no visible cause, which is what "no input" rules out.
                """)
        }
        #expect(session.sources.isEmpty)
        #expect(!session.availability.timelineEnabled)
    }

    @Test("Account copy is translated and unknown never says is unknown")
    func accountCopy() {
        #expect(L10n.t("account.add", language: .english) == "Add")
        #expect(L10n.t("account.add.host", language: .english) == "Hostname")
        #expect(L10n.t("account.search", language: .english) == "Search")
        #expect(L10n.t("account.search.placeholder", language: .english) == "Host or keyword")
        // **Three more keys are retired here and pinned absent below.** `join.browse.look` and
        // `join.browse.look.detail` were the extra row — a typed host the directory does not carry
        // — and `join.browse.filter` was the sheet's own field. Decision 38 takes all three: the
        // browser has no input, so there is nothing to filter by and nothing typed in it to offer.
        #expect(L10n.t("account.catalog.weekly", language: .english) == "%@ active this week")
        #expect(L10n.t("account.catalog.people", language: .english) == "%@ people")
        #expect(
            L10n.t("account.refuse.closed", language: .english)
                == "%@ answered, but would not hand over its public timeline."
        )
        #expect(
            L10n.t("account.detect.progress", language: .english) == "Checking %@…"
        )
        #expect(
            L10n.t("account.refuse.kind", language: .english)
                == "%@ is %@. Only Mastodon can be added this session."
        )
        #expect(
            L10n.t("account.refuse.unknown", language: .english)
                == "Fediqo could not tell what %@ speaks. Only Mastodon can be added this session."
        )
        #expect(!L10n.t("account.refuse.unknown", language: .english).contains("is unknown"))
        #expect(L10n.t("account.refuse.network", language: .english) == "That host could not be reached.")
        #expect(
            L10n.t("account.refuse.duplicate", language: .english)
                == "That host is already a source this session."
        )
        #expect(L10n.t("account.catalog.added", language: .english) == "Added")
        #expect(L10n.t("account.catalog.loading", language: .english) == "Loading the directory…")
        #expect(
            L10n.t("account.catalog.failed", language: .english)
                == "The directory could not be reached. Type a hostname."
        )
        #expect(
            L10n.t("account.catalog.empty", language: .english)
                == "The directory listed none. Type a hostname."
        )
        #expect(L10n.t("account.add", language: .taiwanese) == "新增")
        #expect(L10n.t("account.catalog.added", language: .taiwanese) == "已新增")
        #expect(L10n.t("account.refuse.network", language: .taiwanese) != "account.refuse.network")

        // **Retired with the browser's field, and pinned absent in the shape unit A used for six
        // keys and unit F for three.** A string nothing reads is a translation cost in three
        // bundles and a reader of this file inferring a control that is not there.
        for key in ["join.browse.filter", "join.browse.look", "join.browse.look.detail"] {
            #expect(L10n.t(key, language: .english) == key, """
                \(key) is back in the bundle. Nothing draws it: the browser has no field, so \
                there is nothing to filter by and nothing typed in it to offer as its own row. \
                If a field has returned, it needs a decision, not a revived key.
                """)
        }
    }

    // MARK: - The reader who walked away

    @Test("A directory the reader walked away from is not a directory that could not be reached")
    func cancelledCatalogIsNotAFailure() async {
        // The only one of this view-model's three sites a raw `URLError(.cancelled)` can still
        // reach: `ServerDirectory.servers()` has no error vocabulary of its own and hands the
        // transport's failures up as they are. Without the fix the sheet says "The directory
        // could not be reached. Type a hostname." about a third party that answered fine.
        let session = ShellSession(http: FixtureHTTP(["/servers": .cancelled]))
        await session.loadCatalog()
        #expect(session.catalog == .loading)
        #expect(session.catalog != .failed)
    }

    @Test("A join the reader walked away from says nothing and adds nothing")
    func cancelledAddSaysNothing() async {
        // End-to-end rather than at the catch: Core now reports a cancelled transfer as
        // `CancellationError`, so what this pins is the whole chain — revert any of the Core
        // sites and the reader is told their own leaving was the server's fault.
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(#"""
            <html><head><meta name="application-name" content="Mastodon"></head>
            <body><div id="mastodon"></div></body></html>
            """#),
            "/api/v2/instance": .text(#"""
            {"domain": "first.example", "title": "First", "version": "4.3.0"}
            """#),
            "/api/v1/timelines/public": .cancelled,
            "/api/v1/trends/statuses": .text("[]"),
        ]))
        session.hostname = "first.example"
        await session.add()
        // The premise, pinned. Every assertion below is about an *absence*, so without this the
        // test is satisfied by a look that never reached the press — and its own claim to pin
        // the whole chain end to end would be false.
        guard case .previewing = session.stage else {
            Issue.record("the look should have opened a preview to press from")
            return
        }
        await session.confirm()
        #expect(session.refuse == nil)
        #expect(session.sources.isEmpty)
        #expect(!session.checking)
        #expect(session.progressHost == "")
    }

    @Test("A pick the reader walked away from names no board and blames no forum")
    func cancelledSubscribeSaysNothing() async {
        let front = #"""
        <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
        """#
        let index = #"""
        <h2><a href="forum.php?gid=56">Tools and software</a></h2>
        <div id="category_56">
        <table class="fl_tb"><tr>
        <td class="fl_g"><dl><dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt></dl></td>
        </tr></table>
        </div>
        """#
        let session = ShellSession(http: FixtureHTTP([
            "/": .text(front),
            "https://install-a.example/forum.php": .text(index),
            "https://install-a.example/forum.php?mod=forumdisplay&fid=33": .cancelled,
        ]))
        session.hostname = "install-a.example"
        await session.add()
        await session.confirm()
        guard let choice = session.choosing else {
            Issue.record("a Discuz! should pause on the picker")
            return
        }
        await session.subscribe(choice.offer.boards)
        // No sentence about the forum, and no count standing in for one. `unreadAll` is what the
        // "every board failed" message is written from, and a reader who left failed at nothing.
        #expect(session.refuse == nil)
        #expect(session.unreadAll == 0)
        #expect(session.unread.isEmpty)
        #expect(session.sources.isEmpty)
    }
}

/// The shape a joined source is handed to be drawn with — `AccountPane`'s one line of it.
@Suite("Account mark")
@MainActor
struct AccountMarkTests {
    init() {
        L10n.language = .english
    }

    @Test("A joined forum is marked as a forum, and both forums are")
    func aForumIsNotMarkedAsAMicroblog() {
        // **The regression this exists for was user-visible and silent for both forums.**
        // `mark` called `DummySource.unsigned(host)` and let a default argument answer
        // `.microblog` for everything, so a joined Discourse and a joined Discuz! were both
        // drawn with the globe — a microblog's mark standing over a named discussion. The
        // default is gone; this fails if anything puts a fixed kind back in its place.
        //
        // Both protocols named rather than one, because Discuz! is only the one that was
        // noticed. Nothing about the bug was particular to it.
        func row(_ host: String, _ kind: ProtocolKind) -> SourceRow {
            SourceRow(source: Source(host: host, kind: kind),
                      profile: .unasked(host: host, kind: kind))
        }

        #expect(AccountPane.mark(row("a.example", .discourse), signedIn: false).shape == .forum)
        #expect(AccountPane.mark(row("b.example", .discuz), signedIn: false).shape == .forum)

        // The control: the shape that was right by accident stays right on purpose. Without it
        // a `mark` hard-coded the other way round would pass everything above.
        #expect(AccountPane.mark(row("c.example", .mastodon), signedIn: false).shape == .microblog)

        // Stated, not derived from `shape(of:)` — a test that asks the code what it does agrees
        // with it whatever it does.
        let mark = AccountPane.mark(row("a.example", .discourse), signedIn: false)
        #expect(mark.id == "a.example")
        #expect(!mark.signedIn)

        // **The dead branch, now reachable.** This used to build a `DummySource.unsigned(_:_:)`,
        // so the glance's signed-in variant could never be drawn from this page however signed in
        // the reader was — a mark that could not fill, three lines above a sign-in control that
        // does. The fact travels with the value now.
        #expect(AccountPane.mark(row("d.example", .discuz), signedIn: true).signedIn)

        // **One derivation, not two.** The glance takes the shape the row beside it already
        // derived, so the masthead and the list three lines below cannot disagree about what a
        // protocol looks like — which is what `SourceRow`'s own doc demands of `shape(of:)`.
        let discuz = row("e.example", .discuz)
        #expect(AccountPane.mark(discuz, signedIn: false).shape == discuz.shape)

        // **One server, one picture.** The glance carried only the shape, so a Discuz! was drawn
        // `text.bubble` in the masthead and as its own mark in the row three lines below — one
        // server with two pictures on one screen. Both halves now travel from the same `SourceRow`
        // and cannot be handed in disagreeing.
        #expect(AccountPane.mark(discuz, signedIn: false).kind == .discuz)
        #expect(AccountPane.mark(row("f.example", .mastodon), signedIn: false).kind == .mastodon)
    }

    /// **The property that stops this recurring**: the glance and the row ask *one* tier pair —
    /// `SourceMark.kindMark` first, `SourceMark.symbol` where that draws none — so a protocol that
    /// gains a drawing gains it in both places at once. Asked here of every protocol, because a
    /// surface reading only the shape table is exactly how the two came to disagree.
    ///
    /// **And at both sign-in states, which is the half the first version of this test could not
    /// see.** It compared the picture and never the ink, and the ink was where a fourth difference
    /// was hiding: the row's shape glyph hardcoded `inkFaint` with no variant while the glance's
    /// honoured `signedIn`. Unreachable today only because Discuz! is both the one protocol with a
    /// sign-in and the one with a drawing — so the **first protocol with a sign-in and no drawing**
    /// would have had the masthead and the row saying different things about one server, which is
    /// the ruling this test exists for arriving through the ink instead of the picture.
    @Test("The glance and the row draw one server with one picture, for every protocol")
    func theGlanceAndTheRowDrawOnePicture() {
        // **Signed in is signed in, whichever surface and whichever tier.** The quiet inks differ
        // on purpose — a glance is not a control — but whether `signedIn` is honoured at all must
        // not, and that is `SourceMark.ink`.
        for scheme in [ColorScheme.light, .dark] {
            for quiet in [ShellChrome.inkDim(scheme), ShellChrome.inkFaint(scheme)] {
                #expect(SourceMark.ink(signedIn: true, quiet: quiet, scheme: scheme)
                    == ShellChrome.filament(scheme))
                #expect(SourceMark.ink(signedIn: false, quiet: quiet, scheme: scheme) == quiet)
            }
        }

        for kind in ProtocolKind.allCases {
            let row = SourceRow(source: Source(host: "a.example", kind: kind),
                                profile: .unasked(host: "a.example", kind: kind))
            let mark = AccountPane.mark(row, signedIn: false)
            #expect(mark.kind == row.source.kind, "\(kind)")
            #expect(mark.shape == row.shape, "\(kind)")
            // Both surfaces ask the same two questions of the same source, so whichever tier
            // answers, it answers identically for the glance and for the row.
            for pixels in [CGFloat(16), 32, 48, 72] {
                let drawn = SourceMark.kindMark(mark.kind, pixels: pixels)
                #expect(drawn == SourceMark.kindMark(row.source.kind, pixels: pixels), "\(kind)")
                if drawn == nil {
                    #expect(SourceMark.symbol(mark.shape) == SourceMark.symbol(row.shape), "\(kind)")
                }
            }
        }
        // The case that made the ruling: a Discuz! has a drawing, so neither surface falls to the
        // shape glyph and neither draws `text.bubble` any more.
        #expect(SourceMark.kindMark(.discuz, pixels: 16) != nil)
        #expect(SourceMark.symbol(DummyItem.shape(of: .discuz)) == "text.bubble", """
            The fallback tier moved. It is still what a Discourse draws, and it is what a Discuz! \
            no longer needs — both facts matter to the ruling this test pins.
            """)
        // And a Discourse still falls through to it, which is a chosen fallback and not a gap.
        #expect(SourceMark.kindMark(.discourse, pixels: 16) == nil)

        // **The fourth difference, closed at both surfaces and in both tiers.** A protocol with a
        // drawing and one without, signed in and out, on both surfaces: `filament` exactly where
        // the reader has switched this device's relationship on, and never anywhere else.
        for kind in [ProtocolKind.discuz, .discourse] {
            for signedIn in [false, true] {
                let row = SourceRow(source: Source(host: "a.example", kind: kind),
                                    profile: .unasked(host: "a.example", kind: kind))
                let drawn = SourcePageTests.drawn(row, at: 900, signedIn: signedIn)
                let glance = SourceMarkRow.ink(
                    AccountPane.mark(row, signedIn: signedIn), scheme: .light
                )
                #expect((drawn.markInk == ShellChrome.filament(.light)) == signedIn, """
                    The row's leading mark stopped saying whether this device is signed in, for \
                    \(kind). The shape-glyph tier used to ignore it outright.
                    """)
                #expect((glance == ShellChrome.filament(.light)) == signedIn, "\(kind)")
            }
        }
    }

    // MARK: - The masthead glance

    /// **What it is for, once the Sources list exists three lines beneath it**: the whole, on one
    /// line, without scrolling. You read three things and are signed in to one. The list below is
    /// per-source; this is the collection, and the count is the one fact a list of rows cannot
    /// state at a glance.
    @Test("The glance says how many sources there are, and how many are signed in")
    func theGlanceCountsTheCollection() {
        // The kind is immaterial here — this test is about the *sentence*, which counts marks and
        // signed-in marks and never asks what any of them is drawn with.
        func marks(_ shapes: [DummySourceKind], signedIn: Int) -> [SourceMarkRow.Mark] {
            shapes.enumerated().map {
                SourceMarkRow.Mark(id: "\($0.offset).example", kind: .mastodon, shape: $0.element,
                                   signedIn: $0.offset < signedIn)
            }
        }

        // **Chosen on `signedIn > 0`, so an all-Mastodon reader is not told "0 signed in"** about
        // a capability their protocols never had.
        #expect(SourceMarkRow.countKey(signedIn: 0) == "account.standing.count")
        #expect(SourceMarkRow.countKey(signedIn: 1) == "account.standing.count.signedIn")
        #expect(SourceMarkRow.count(marks([.microblog, .microblog, .forum], signedIn: 0))
            == "3 sources")
        #expect(SourceMarkRow.count(marks([.microblog, .forum, .forum], signedIn: 1))
            == "3 sources, 1 signed in")

        // **A seventh source is counted although it is not drawn**, which is what makes the cap
        // affordable: nothing is hidden by it.
        let seven = marks(Array(repeating: .forum, count: 7), signedIn: 2)
        #expect(SourceMarkRow.shown == 6)
        #expect(SourceMarkRow.count(seven) == "7 sources, 2 signed in")

        // **Drawn only at two or more, which disposes of the plural problem rather than working
        // around it.** This repo ships no `.stringsdict`, and "1 sources" is the one bad case.
        #expect(!SourceMarkRow.drawn(sources: 0))
        #expect(!SourceMarkRow.drawn(sources: 1), """
            The glance was drawn over one source, which is the only count whose English is \
            ungrammatical — and the pane title already says it.
            """)
        #expect(SourceMarkRow.drawn(sources: 2))

        // The Chinese says 來源 for a source, never 主機 or 伺服器 — the terminology rule, from
        // the side a derived ban cannot check: that the noun is present at all.
        for key in ["account.standing.count", "account.standing.count.signedIn"] {
            #expect(L10n.t(key, language: .taiwanese).contains("來源"), "\(key)")
        }
    }

    /// **The wiring, which is the half risk 12 counts.** `drawn(sources:)`, `countKey`, `count`
    /// and `mark` are each named and driven — and before this nothing proved the masthead body
    /// called any of them: not that the gate is asked with the *source count*, not that the marks
    /// come from `session.rows`. That is the shape of all four defects this branch has shipped.
    @Test("The masthead asks the gate with its source count and builds marks from the rows")
    func theGlanceIsWiredToTheRulesItDeclares() async throws {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        let pane = AccountPane(session: session)

        // Nothing joined, and nothing drawn.
        #expect(pane.glance == nil)

        // One source: the gate is asked with the count, so the glance is withheld and "1 sources"
        // cannot be produced.
        await session.store.add(Source(host: "a.example", kind: .mastodon))
        session.sources = await session.store.sources()
        #expect(pane.glance == nil, """
            The masthead drew a glance over one source. Either the gate is not being asked, or it \
            is being asked with something other than the source count.
            """)

        // Two: drawn, and every mark is the row's own — same host, same shape, in join order.
        await session.store.add(Source(host: "b.example", kind: .discuz))
        session.sources = await session.store.sources()
        let glance = try #require(pane.glance)
        #expect(glance.count == 2)
        #expect(glance.map(\.id) == session.rows.map(\.source.host))
        #expect(glance.map(\.shape) == session.rows.map(\.shape), """
            The glance derived the shape itself instead of taking the row's, so the masthead and \
            the list three lines below it can disagree about what a protocol looks like.
            """)
        #expect(glance.allSatisfy { !$0.signedIn }, "nobody has signed in to either")

        // And the signed-in fact reaches it from the same place the row's control reads.
        session.forums.recordSignIn(host: "b.example")
        let after = try #require(pane.glance)
        #expect(after.filter(\.signedIn).map(\.id) == ["b.example"])
        #expect(SourceMarkRow.count(after) == "2 sources, 1 signed in")
    }

    /// **The fourth instance of style-over-state on this branch, and the one on the page whose
    /// other controls were just fixed.** `.buttonStyle(.plain)` supplies no dimming and an
    /// explicit `.foregroundStyle` overrides the one `.disabled` would supply, so the magnifier
    /// was refused behind a sheet and looked exactly as pressable as before.
    @Test("The magnifier stops looking pressable exactly when it stops being pressable")
    func theMagnifierLooksRefusedWhenItIsRefused() {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        let pane = AccountPane(session: session)

        #expect(!pane.busy)
        #expect(pane.searchInk == ShellChrome.ink(.light))

        // A sheet is up: the field and both buttons are out of the reader's hands, and now the
        // magnifier says so.
        session.stage = .browsing
        #expect(pane.busy)
        #expect(pane.searchInk == ShellChrome.inkFaint(.light), """
            The magnifier drew at full ink while refused — zero visual difference between a \
            control the reader can press and one they cannot.
            """)
    }

    /// The glyph table stays shared, and the override that was never safe to share is gone: a
    /// signed-in microblog drawn as a person gave `person.crop.circle` a third meaning, two of
    /// them on the Account page at once — the row's sign-in control being the other.
    @Test("The glance and the row read one glyph table, and nothing overrides it")
    func theGlanceReadsTheOneTable() {
        #expect(SourceMark.symbol(.microblog) == "globe")
        #expect(SourceMark.symbol(.forum) == "text.bubble")
        // The signed-in microblog is a globe, filled — not a person. The person is a control.
        #expect(SourceMark.symbol(.microblog) != "person.crop.circle")
    }
}
