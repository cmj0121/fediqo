import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #330, drawn: the quotes of one's own post — reading, none, rows with one taken back, a miss —
/// and who may quote it, chosen and fixed, in light and in dark, at 420, 390 and 320, the
/// narrowest at the largest text, no wider than the room.
@MainActor
@Suite("The quotes of your post and who may quote it, hosted")
struct QuotesSheetHostedTests {
    private static func note(_ id: String, state: String) throws -> Note {
        let json = """
        {"id":"\(id)","uri":"https://social.example/users/bob/statuses/\(id)","created_at":"2026-10-01T00:00:00.000Z",
         "content":"<p>the first line of their words, cut at its end</p>","visibility":"public",
         "account":{"username":"bob","acct":"bob@example.org","display_name":"Bob Example"},
         "quote":{"state":"\(state)","quoted_status_id":"1"}}
        """
        return try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: Source(host: "social.example", kind: .mastodon), category: .home, sent: .now())
    }

    @Test("Each state of the list lays out at 420, 390 and 320, in light and in dark, no wider than its room", arguments: 0..<2)
    func laidOut(_ dark: Int) throws {
        L10n.language = .english
        let scheme = HostedFit.scheme(dark)
        let rows = [try Self.note("7", state: "accepted"), try Self.note("8", state: "revoked")]
        let states: [(ShellQuoting.Reading, [Note], String?)] = [
            (.reading, [], nil), (.read, [], nil), (.failed, [], nil), (.read, rows, nil), (.read, rows, "social.example could not be reached."),
        ]
        for (reading, listed, missed) in states {
            for (width, size) in HostedFit.rooms {
                let sheet = QuotesSheet(
                    host: "social.example", rows: listed, reading: reading, more: true, revoking: [], missed: missed,
                    onRevoke: { _ in }, onReadOn: {}, onClose: {}
                )
                #expect(HostedFit.fits(sheet, width: width, height: 800, scheme: scheme, size: size), "\(reading) at \(width)")
            }
        }
    }

    @Test("Who may quote it lays out unsaid, chosen and fixed at nobody, in light and in dark", arguments: 0..<2)
    func policyLaidOut(_ dark: Int) {
        L10n.language = .english
        let scheme = HostedFit.scheme(dark)
        for (policy, audience) in [(QuotePolicy?.none, Audience.everyone), (.followers, .everyone), (.anyone, .followers)] {
            var draft = PostDraft(quotePolicy: policy)
            draft.audience = audience
            let menu = QuotePolicyMenu(draft: .constant(draft), host: "social.example")
            #expect(HostedFit.fits(menu, width: 320, scheme: scheme))
        }
    }
}
