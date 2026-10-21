import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #332, drawn: the change sheet lays out refused, and filled with a poll whose change loses its
/// votes — in light and in dark, at the regular and the largest text, no wider than its sheet.
@MainActor
@Suite("The sheet that changes your own post, hosted")
struct ChangeSheetHostedTests {
    private static let poll = #"{"id":"7","expires_at":"2099-01-01T00:00:00.000Z","expired":false,"multiple":false,"votes_count":2,"voters_count":2,"options":[{"title":"A","votes_count":2},{"title":"B","votes_count":0}]}"#
    private static let status = """
    {"id":"9","uri":"https://social.example/users/me/statuses/9","created_at":"2026-10-01T00:00:00.000Z","content":"<p>which?</p>",
     "visibility":"public","account":{"username":"me","acct":"me","display_name":"me"},"poll":\(poll)}
    """

    private func session(refused: Bool) async throws -> ShellSession {
        let server = ChangeServer([
            "GET /api/v1/statuses/9/source": [(refused ? "{}" : #"{"id":"9","text":"which?","spoiler_text":""}"#, refused ? 500 : 200)],
            "GET /api/v1/statuses/9": [(Self.status, 200)],
        ])
        let source = Source(host: "social.example", kind: .mastodon)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: source.host, accessToken: "tok-1", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.scopes(writing: true)
        ))
        let store = ItemStore()
        await store.add(source)
        await store.ingest([
            try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status.utf8)).asNote(source: source, category: .home, sent: .now()),
        ])
        let session = ShellSession(http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        session.mastodon.deadlineSleep = TurnedClock().sleep
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: source.host)
        await session.reloadFromStore()
        let item = try #require(session.notes.first.flatMap { session.held($0.key.rowID) })
        session.changes.start(item, in: session)
        await session.changes.settled()
        return session
    }

    @Test("The sheet lays out refused and filled, the reset line under the poll, in light and in dark", arguments: 0..<2)
    func laidOut(_ dark: Int) async throws {
        L10n.language = .english
        let scheme = HostedFit.scheme(dark)
        for refused in [true, false] {
            let session = try await session(refused: refused)
            if !refused { session.changes.draft.poll?.multiple = true }
            #expect(session.changes.phase == (refused ? .failed : .ready))
            #expect(session.changes.resets == !refused)
            for size in [DynamicTypeSize.large, .accessibility5] {
                // The sheet's own room: a writing sheet's width.
                #expect(HostedFit.fits(ChangeSheet().environment(session), room: 600, scheme: scheme, size: size), "refused \(refused) at \(size)")
            }
        }
    }
}
