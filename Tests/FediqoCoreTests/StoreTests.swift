import Foundation
import Testing
@testable import FediqoCore

private func scratch(_ name: String) -> UserDefaults {
    let suite = "fediqo.tests.\(name)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

/// The two places a chosen server can be written down. Each case opens a fresh place once
/// and then hands out stores over it, so "next time" is a second store on the same place.
enum ServerBackend: String, CaseIterable, Sendable {
    case defaults, sqlite

    @MainActor
    func opener(_ name: String) throws -> () -> any ServerStore {
        switch self {
        case .defaults:
            let defaults = scratch(name)
            return { UserDefaultsServerStore(defaults: defaults) }
        case .sqlite:
            let store = try LocalStore.inMemory()
            return { SQLiteServerStore(store: store, defaults: scratch("\(name)-import")) }
        }
    }
}

/// What the app remembers. Both server backends have to keep the same behaviour.
@MainActor
@Suite("Servers and preferences survive being put down and picked up")
struct StoreTests {
    @Test("A server written down is there again next time", arguments: ServerBackend.allCases)
    func serversPersist(backend: ServerBackend) throws {
        let open = try backend.opener("servers")
        let store = open()
        store.add(Server(host: "one.test", socialProtocol: .mastodon))
        store.add(Server(host: "two.test", socialProtocol: .mastodon))

        #expect(open().servers.map(\.host) == ["one.test", "two.test"])
    }

    @Test("The same server twice is one server, however it was typed", arguments: ServerBackend.allCases)
    func addingIsIdempotent(backend: ServerBackend) throws {
        let store = try backend.opener("dedupe")()
        store.add(Server(host: "one.test", socialProtocol: .mastodon))
        store.add(Server(host: "https://ONE.test/", socialProtocol: .mastodon))

        #expect(store.servers.count == 1)
    }

    @Test("Removing one leaves the others where they were", arguments: ServerBackend.allCases)
    func removing(backend: ServerBackend) throws {
        let store = try backend.opener("remove")()
        for host in ["a.test", "b.test", "c.test"] { store.add(Server(host: host, socialProtocol: .mastodon)) }
        store.remove(Server(host: "b.test", socialProtocol: .mastodon))

        #expect(store.servers.map(\.host) == ["a.test", "c.test"])
    }

    @Test("Dropping a server keeps its row and every post it handed over")
    func removingKeepsRowAndPosts() async throws {
        let local = try LocalStore.inMemory()
        let store = SQLiteServerStore(store: local, defaults: scratch("keep-import"))
        let one = Server(host: "one.example", socialProtocol: .mastodon)
        store.add(one)
        try await local.save([makePost(uri: "https://one.example/1", at: 100)], from: one)

        store.remove(one)

        #expect(store.servers.isEmpty)
        let (rows, selected) = try await local.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM servers WHERE url = 'https://one.example'"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM servers WHERE selected_at IS NOT NULL"))
        }
        #expect(rows == 1)
        #expect(selected == 0)
        #expect(try await local.timeline().count == 1)
    }

    @Test("A server met through its posts is not a chosen one until it is added")
    func postPathDoesNotSelect() async throws {
        let local = try LocalStore.inMemory()
        let one = Server(host: "one.example", socialProtocol: .mastodon, title: "One")
        try await local.save([makePost(uri: "https://one.example/1", at: 100)], from: one)

        let store = SQLiteServerStore(store: local, defaults: scratch("unselected-import"))
        #expect(store.servers.isEmpty)

        store.add(one)
        #expect(store.servers.map(\.host) == ["one.example"])
        #expect(try await local.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM servers") } == 1)
    }

    @Test("A title the network taught is not overwritten by the host, only by a title")
    func titleIsNotClobbered() async throws {
        let local = try LocalStore.inMemory()
        let one = Server(host: "one.example", socialProtocol: .mastodon, title: "One")
        try await local.save([makePost(uri: "https://one.example/1", at: 100)], from: one)
        let store = SQLiteServerStore(store: local, defaults: scratch("title-import"))

        store.add(Server(host: "one.example", socialProtocol: .mastodon))
        #expect(store.servers.map(\.title) == ["One"])

        store.remove(one)
        store.add(Server(host: "one.example", socialProtocol: .mastodon, title: "Uno"))
        #expect(store.servers.map(\.title) == ["Uno"])
    }

    @Test("A server is filed under the endpoint its protocol speaks")
    func endpoints() throws {
        #expect(Server(host: "one.example", socialProtocol: .mastodon).endpoint == "https://one.example")
        #expect(Server(host: "relay.example", socialProtocol: .nostr).endpoint == "wss://relay.example")

        let local = try LocalStore.inMemory()
        let store = SQLiteServerStore(store: local, defaults: scratch("endpoint-import"))
        store.add(Server(host: "one.example", socialProtocol: .mastodon))
        store.add(Server(host: "relay.example", socialProtocol: .nostr))
        let urls = try local.readSync { db in try String.fetchAll(db, sql: "SELECT url FROM servers ORDER BY position") }
        #expect(urls == ["https://one.example", "wss://relay.example"])
    }

    @Test("The list UserDefaults kept is taken over once, in order, and then let go")
    func importsFromDefaultsOnce() throws {
        let defaults = scratch("import")
        let old = UserDefaultsServerStore(defaults: defaults)
        old.add(Server(host: "b.test", socialProtocol: .mastodon))
        old.add(Server(host: "a.test", socialProtocol: .mastodon))
        let local = try LocalStore.inMemory()

        let store = SQLiteServerStore(store: local, defaults: defaults)
        #expect(store.servers.map(\.host) == ["b.test", "a.test"])
        #expect(defaults.data(forKey: UserDefaultsServerStore.defaultsKey) == nil)

        store.remove(Server(host: "b.test", socialProtocol: .mastodon))
        UserDefaultsServerStore(defaults: defaults).add(Server(host: "c.test", socialProtocol: .mastodon))
        #expect(SQLiteServerStore(store: local, defaults: defaults).servers.map(\.host) == ["a.test"])
    }

    @Test("A fresh install is dark and larger, and reading follows the system")
    func defaults() {
        let preferences = Preferences(defaults: scratch("defaults"))
        #expect(preferences.theme == .dark)
        #expect(preferences.textScale == .larger)
        #expect(preferences.language == .system)
        #expect(preferences.railExpanded == false)
        #expect(preferences.showBoosts)
        #expect(preferences.showMediaOnly == false)
        #expect(preferences.refreshInterval == .seconds30)
    }

    @Test("Every preference survives a relaunch")
    func preferencesPersist() {
        let defaults = scratch("preferences")
        let first = Preferences(defaults: defaults)
        first.theme = .light
        first.textScale = .small
        first.language = .traditionalChinese
        first.railExpanded = true
        first.showBoosts = false
        first.showMediaOnly = true
        first.refreshInterval = .off

        let second = Preferences(defaults: defaults)
        #expect(second.theme == .light)
        #expect(second.textScale == .small)
        #expect(second.language == .traditionalChinese)
        #expect(second.railExpanded)
        #expect(second.showBoosts == false)
        #expect(second.showMediaOnly)
        #expect(second.refreshInterval == .off)
    }

    @Test("Off is the one interval that is no interval, and the rest say how long they are")
    func refreshIntervals() {
        #expect(RefreshInterval.allCases.filter { $0.duration == nil } == [.off])
        #expect(RefreshInterval.allCases.compactMap(\.duration) == [.seconds(15), .seconds(30), .seconds(60), .seconds(300)])
    }

    @Test("The text sizes only ever go up")
    func scalesAreOrdered() {
        let factors = TextScale.allCases.map(\.factor)
        #expect(factors == factors.sorted())
        #expect(TextScale.regular.factor == 1.0)
    }

    @Test("Choosing a language carries a locale, and following the system carries none")
    func languageLocales() {
        #expect(AppLanguage.system.locale == nil)
        #expect(AppLanguage.english.locale?.identifier == "en")
        #expect(AppLanguage.traditionalChinese.locale?.identifier == "zh-TW")
    }

    @Test("What is spoken is what has a client registered, and nothing else")
    func protocols() {
        #expect(SocialProtocol.allCases.filter(\.isImplemented) == [.mastodon])
        #expect(SourceRegistry.standard().client(for: .mastodon) != nil)
        #expect(SourceRegistry.standard().client(for: .nostr) == nil)
        #expect(Set(SocialProtocol.allCases.map(\.id)).count == SocialProtocol.allCases.count)
    }
}
