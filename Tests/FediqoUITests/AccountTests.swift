import FediqoCore
import Testing
@testable import FediqoUI

@Suite("Account add")
@MainActor
struct AccountAddTests {
    init() {
        L10n.language = .english
    }

    @Test("Adding first.example stores the source, All and Trends, and enables the timeline")
    func addMastodonSocial() async {
        let session = ShellSession(http: Self.joinHTTP())
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
        let http = FixtureHTTP(["/": .body(Fixtures.html("pleroma"))])
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
        let session = ShellSession(http: Self.joinHTTP())
        session.hostname = "https://first.example/about"
        await session.add()
        #expect(session.sources.count == 1)
        session.hostname = "first.example"
        await session.add()
        #expect(session.refuse == L10n.t("account.refuse.duplicate", language: .english))
        #expect(session.sources.count == 1)
        #expect(session.availability.timelineEnabled)
    }

    @Test("Catalog maps fixture servers.json domains")
    func catalogMapsFixtureDomains() async {
        let session = ShellSession(http: Self.joinHTTP())
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
        let session = ShellSession(http: Self.joinHTTP())
        await session.loadCatalog()
        session.hostname = "hachy"
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
        let session = ShellSession(http: Self.joinHTTP())
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
        let session = ShellSession(http: Self.joinHTTP())
        await session.loadCatalog()
        session.hostname = "social"
        #expect(session.extraJoinHost == nil)
        #expect(session.visibleServers.map(\.domain) == ["first.example"])
    }

    @Test("A catalog host in the field is not an extra row")
    func catalogHostIsNotExtra() async {
        let session = ShellSession(http: Self.joinHTTP())
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
        #expect(L10n.t("account.catalog.meta", language: .english) == "%@ · WAU %@ · %@")
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

    private static func joinHTTP() -> FixtureHTTP {
        FixtureHTTP([
            "/": .body(Fixtures.html("mastodon")),
            "/api/v2/instance": .body(Fixtures.json("instance-v2")),
            "/api/v1/timelines/public": .body(Fixtures.json("public-timeline")),
            "/api/v1/trends/statuses": .body(Fixtures.json("trending-statuses")),
            "/servers": .body(Fixtures.json("servers")),
        ])
    }
}
