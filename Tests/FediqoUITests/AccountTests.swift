import FediqoCore
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
        await session.add(from: .field)
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
        await session.add(from: .field)
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
        await session.add(from: .field)
        await session.confirm()
        #expect(session.sources.count == 1)
        session.hostname = "first.example"
        // **The duplicate is caught before the look**, which is what keeps it free: a host this
        // device already reads costs no detection and no profile request, only the sentence.
        await session.add(from: .field)
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
        // A catalog row is a *look*, like every other way in — pressing one opens the preview
        // and adds nothing. It is the press after it that joins.
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
        await session.add(from: .field)
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
        await session.add(from: .field)
        #expect(session.refuse == L10n.t("account.refuse.network", language: .english))
        #expect(session.sources.isEmpty)
        #expect(!session.availability.timelineEnabled)
    }

    @Test("Keyword filters domain and description live, and filtering joins nothing")
    func keywordFiltersCatalog() async {
        // Two rows, and each one is reached by a different half of the filter: the first by a
        // word out of its description, the second by a piece of its domain. Nothing here joins,
        // so the directory is the only thing that has to answer.
        let session = ShellSession(http: FixtureHTTP(["/servers": .text(#"""
        [
          {"domain": "first.example", "description": "The flagship server"},
          {"domain": "second.example", "description": "A community for professionals"}
        ]
        """#)]))
        await session.loadCatalog()
        session.hostname = "seco"
        #expect(session.visibleServers.map(\.domain) == ["second.example"])
        #expect(session.extraJoinHost == nil)
        session.hostname = "flagship"
        #expect(session.visibleServers.map(\.domain) == ["first.example"])
        #expect(session.sources.isEmpty)
        #expect(!session.availability.timelineEnabled)
        session.hostname = ""
        #expect(session.visibleServers.map(\.domain) == ["first.example", "second.example"])
    }

    @Test("A typed host not in the catalog is an extra row the sheet offers")
    func extraJoinHostDoesNotJoin() async {
        let session = ShellSession(http: FixtureHTTP(["/servers": .text(#"""
        [{"domain": "first.example", "description": "The flagship server"}]
        """#)]))
        await session.loadCatalog()
        session.hostname = "my.example"
        #expect(session.extraJoinHost == "my.example")
        #expect(session.visibleServers.isEmpty)
        #expect(session.sources.isEmpty)
        #expect(!session.availability.timelineEnabled)
    }

    @Test("A keyword without a dot is not an Add-host row")
    func keywordIsNotAHost() async {
        let session = ShellSession(http: FixtureHTTP(["/servers": .text(#"""
        [{"domain": "first.example", "description": "The flagship server"}]
        """#)]))
        await session.loadCatalog()
        // No dot in it, so it is a word to search by and not a host to offer to add.
        session.hostname = "flagship"
        #expect(session.extraJoinHost == nil)
        #expect(session.visibleServers.map(\.domain) == ["first.example"])
    }

    @Test("A catalog host in the field is not an extra row")
    func catalogHostIsNotExtra() async {
        let session = ShellSession(http: FixtureHTTP(["/servers": .text(#"""
        [{"domain": "first.example", "description": "The flagship server"}]
        """#)]))
        await session.loadCatalog()
        session.hostname = "first.example"
        #expect(session.extraJoinHost == nil)
        #expect(session.visibleServers.map(\.domain) == ["first.example"])
        #expect(session.sources.isEmpty)
    }

    @Test("Account copy is translated and unknown never says is unknown")
    func accountCopy() {
        #expect(L10n.t("account.add", language: .english) == "Add")
        #expect(L10n.t("account.add.host", language: .english) == "Hostname")
        #expect(L10n.t("account.search", language: .english) == "Search")
        #expect(L10n.t("account.search.placeholder", language: .english) == "Host or keyword")
        // **`account.catalog.addHost` is retired, not renamed.** It read "Add %@" and the row no
        // longer adds anything — it opens a preview — so the verb was a lie about what the press
        // does. The two keys below replace it and say what actually happens.
        #expect(L10n.t("join.browse.look", language: .english) == "Look at %@")
        #expect(
            L10n.t("join.browse.look.detail", language: .english)
                == "Not in the directory. See what it is before you add it."
        )
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
        await session.add(from: .field)
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
        await session.add(from: .field)
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
    }

    // MARK: - The masthead glance

    /// **What it is for, once the Sources list exists three lines beneath it**: the whole, on one
    /// line, without scrolling. You read three things and are signed in to one. The list below is
    /// per-source; this is the collection, and the count is the one fact a list of rows cannot
    /// state at a glance.
    @Test("The glance says how many sources there are, and how many are signed in")
    func theGlanceCountsTheCollection() {
        func marks(_ shapes: [DummySourceKind], signedIn: Int) -> [SourceMarkRow.Mark] {
            shapes.enumerated().map {
                SourceMarkRow.Mark(id: "\($0.offset).example", shape: $0.element,
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
