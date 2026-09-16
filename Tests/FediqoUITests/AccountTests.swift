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
        await session.add()
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
        #expect(session.sources.count == 1)
        session.hostname = "first.example"
        await session.add()
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
        await session.pick(servers[0])
        #expect(session.hostname == "first.example")
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

    @Test("Keyword filters domain and description live, without joining")
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
        session.search()
        #expect(session.sources.isEmpty)
        #expect(!session.availability.timelineEnabled)
        session.hostname = ""
        #expect(session.visibleServers.map(\.domain) == ["first.example", "second.example"])
    }

    @Test("A typed host not in the catalog is an extra row; search does not join")
    func extraJoinHostDoesNotJoin() async {
        let session = ShellSession(http: FixtureHTTP(["/servers": .text(#"""
        [{"domain": "first.example", "description": "The flagship server"}]
        """#)]))
        await session.loadCatalog()
        session.hostname = "my.example"
        session.search()
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
        session.search()
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
        #expect(L10n.t("account.catalog.addHost", language: .english) == "Add %@")
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
        await session.add()
        #expect(session.refuse == nil)
        #expect(session.sources.isEmpty)
        #expect(!session.checking)
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
        #expect(AccountPane.mark(Source(host: "a.example", kind: .discourse)).kind == .forum)
        #expect(AccountPane.mark(Source(host: "b.example", kind: .discuz)).kind == .forum)

        // The control: the shape that was right by accident stays right on purpose. Without it
        // a `mark` hard-coded the other way round would pass everything above.
        #expect(AccountPane.mark(Source(host: "c.example", kind: .mastodon)).kind == .microblog)

        // Stated, not derived from `shape(of:)` — a test that asks the code what it does agrees
        // with it whatever it does.
        let mark = AccountPane.mark(Source(host: "a.example", kind: .discourse))
        #expect(mark.host == "a.example")
        #expect(!mark.isSignedIn)
    }
}
