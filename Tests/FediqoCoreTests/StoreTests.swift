import Foundation
import Testing
@testable import FediqoCore

/// What the app remembers. #2 replaces the implementation; these describe the behaviour it
/// will have to keep.
@MainActor
@Suite("Servers and preferences survive being put down and picked up")
struct StoreTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "fediqo.tests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test("A server written down is there again next time")
    func serversPersist() {
        let defaults = scratch("servers")
        let store = UserDefaultsServerStore(defaults: defaults)
        store.add(Server(host: "one.test", socialProtocol: .mastodon))
        store.add(Server(host: "two.test", socialProtocol: .mastodon))

        #expect(UserDefaultsServerStore(defaults: defaults).servers.map(\.host) == ["one.test", "two.test"])
    }

    @Test("The same server twice is one server, however it was typed")
    func addingIsIdempotent() {
        let store = UserDefaultsServerStore(defaults: scratch("dedupe"))
        store.add(Server(host: "one.test", socialProtocol: .mastodon))
        store.add(Server(host: "https://ONE.test/", socialProtocol: .mastodon))

        #expect(store.servers.count == 1)
    }

    @Test("Removing one leaves the others where they were")
    func removing() {
        let store = UserDefaultsServerStore(defaults: scratch("remove"))
        for host in ["a.test", "b.test", "c.test"] { store.add(Server(host: host, socialProtocol: .mastodon)) }
        store.remove(Server(host: "b.test", socialProtocol: .mastodon))

        #expect(store.servers.map(\.host) == ["a.test", "c.test"])
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

        let second = Preferences(defaults: defaults)
        #expect(second.theme == .light)
        #expect(second.textScale == .small)
        #expect(second.language == .traditionalChinese)
        #expect(second.railExpanded)
        #expect(second.showBoosts == false)
        #expect(second.showMediaOnly)
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
