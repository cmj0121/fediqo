import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #188: what a source said about itself, as the shell draws it and lets it go.
@MainActor
@Suite("What a source said, on the source page")
struct SourceSaidShellTests {
    private static let host = "social.example"
    private static let keptAt = Date(timeIntervalSince1970: 1_750_000_000)
    private static let kept = SourceProfile(
        host: host, kind: .mastodon, title: "Social", statusLimit: 1500
    ).said(at: keptAt)

    @Test("A word just read off the wire says no when; a kept one says it in the shell's language")
    func asOfLine() throws {
        let fresh = SourceProfile(host: Self.host, kind: .mastodon, title: "Social")
        #expect(SourcePreviewView.asOfLine(fresh, host: Self.host, language: .english) == nil)

        let english = try #require(SourcePreviewView.asOfLine(Self.kept, host: Self.host, language: .english))
        let when = Self.keptAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale(.english))
        )
        #expect(english == "As \(Self.host) said it, \(when).")

        let taiwanese = try #require(SourcePreviewView.asOfLine(Self.kept, host: Self.host, language: .taiwanese))
        let whenTW = Self.keptAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale(.taiwanese))
        )
        #expect(taiwanese.contains(whenTW), "the moment follows the shell's language, not the device's")
        #expect(taiwanese != english)
        #expect(L10n.t("source.said.asOf", language: .taiwanese) != "source.said.asOf", "and is in the Chinese")
    }

    @Test("Clear lets go of what the source said, from this run and from the store; the source stays")
    func clearForgets() async throws {
        let store = ItemStore(sources: [Source(host: Self.host, kind: .mastodon)], notes: [], said: [Self.kept])
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        #expect(session.rows.first?.profile == .stated(Self.kept))

        await session.clear(host: Self.host)

        #expect(await store.said(host: Self.host) == nil)
        #expect(session.rows.first?.profile == .unasked(host: Self.host, kind: .mastodon))
        #expect(session.postLimit(of: Self.host) == MastodonWrite.defaultLimit)
        #expect(await store.sources().map(\.host) == [Self.host], "Clear does not undo a join")
    }

    @Test("A kept word speaks for the source until this run asks: a Pleroma joined as one is spoken to as one")
    func keptKindSpeaks() async throws {
        let stored = Source(host: Self.host, kind: .mastodon)
        let said = SourceProfile(host: Self.host, kind: .pleroma, title: "Now a Pleroma").said(at: Self.keptAt)
        let store = ItemStore(sources: [stored], notes: [], said: [said])
        let session = ShellSession(http: FixtureHTTP(), store: store)

        await session.reloadFromStore()

        #expect(session.sources.first?.kind == .pleroma, "what it last said, ahead of what was written down at join")
        #expect(await store.sources().first?.kind == .mastodon, "and nothing is written to the index for it")
    }
}
