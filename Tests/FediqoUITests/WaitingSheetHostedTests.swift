import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #333, drawn: the list of what waits — reading, none, rows with D2's pair band, a miss, the
/// lock — and the time to send, in light and in dark, at a Mac's 420 and a phone's 390 and 320,
/// the narrowest at the largest text, no wider than the room.
@MainActor
@Suite("The list of what waits and the time to send, hosted")
struct WaitingSheetHostedTests {
    private static let at = Date(timeIntervalSince1970: 1_792_003_600)
    private static let posts = [
        WaitingPost(id: "1", at: at, text: "the first two lines of its words, cut at their end", audience: .everyone,
                    media: [PostSource.Media(id: "9", kind: .image, description: "alt")]),
        WaitingPost(id: "2", at: at.addingTimeInterval(1800), text: "before the change", audience: .followers),
        WaitingPost(id: "3", at: at.addingTimeInterval(3600), text: "after the change", audience: .followers,
                    poll: NewPoll(choices: ["A", "B"])),
    ]

    private static func said(_ reading: ShellLater.Reading, posts: [WaitingPost], missed: String? = nil, locked: String? = nil) -> WaitingSaid {
        WaitingSaid(
            host: "mastodon.social", reading: reading, posts: posts, more: true, moving: ["1"], changing: [], leaving: [],
            missed: missed, pairs: [ShellLater.Pair(new: "3", old: "2", lostMedia: true)], locked: locked
        )
    }

    @Test("Each state of the list lays out at 420, 390 and 320 at the largest text, in light and in dark, no wider than its room", arguments: 0..<2)
    func laidOut(_ dark: Int) {
        L10n.language = .english
        let scheme: ColorScheme = dark == 1 ? .dark : .light
        let states = [
            Self.said(.reading, posts: []), Self.said(.read, posts: []), Self.said(.failed, posts: []),
            Self.said(.read, posts: Self.posts), Self.said(.read, posts: Self.posts, missed: "mastodon.social could not be reached."),
            Self.said(.read, posts: Self.posts, locked: "Sign in to mastodon.social with writing."),
        ]
        for said in states {
            for (width, size) in [(CGFloat(420), DynamicTypeSize.large), (390, .large), (320, .accessibility5)] {
                let sheet = WaitingSheet(
                    said: said, onChange: { _ in }, onMove: { _ in }, onWithdraw: { _ in }, onWithdrawNow: { _ in },
                    onReadOn: {}, onAgain: {}, onClose: {}
                )
                let view = NSHostingView(rootView: sheet.frame(width: width, height: 900)
                    .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
                view.layoutSubtreeIfNeeded()
                #expect(view.fittingSize.height > 0 && view.fittingSize.width <= width + 0.5, "\(said.reading) at \(width)")
            }
        }
    }

    @Test("The time to send lays out off, on and locked, in light and in dark", arguments: 0..<2)
    func timeLaidOut(_ dark: Int) {
        L10n.language = .english
        let scheme: ColorScheme = dark == 1 ? .dark : .light
        for (at, slot) in [(nil, DraftControls.LaterSlot()), (Self.at, DraftControls.LaterSlot()), (nil, DraftControls.LaterSlot(locked: "Sign in with writing."))] {
            let control = LaterControl(at: .constant(at), slot: slot, host: "mastodon.social")
            let view = NSHostingView(rootView: control.frame(width: 320).environment(\.colorScheme, scheme))
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.height > 0 && view.fittingSize.width <= 320.5)
        }
    }
}
