import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import FediqoCore
@testable import FediqoUI

/// #312, drawn: the sheet that changes the reader's own account lays out in each of its states
/// at a Mac's 600 and a phone's 390 and 320 — the narrowest at the largest text — in light and
/// in dark; and Change stands inside the head of the reader's own page, live or as its lock.
@MainActor
@Suite("The sheet that changes your own account, hosted")
struct ProfileSheetHostedTests {
    private static let host = "m.example"
    private static let account = OwnAccount(
        name: "Alice Example", words: "I write about rivers.",
        fields: [
            OwnAccount.Field(name: "Site", value: "https://alice.example", verifiedAt: Date(timeIntervalSince1970: 1_767_225_600)),
            OwnAccount.Field(name: "Pronouns", value: "she/her"),
        ],
        followWithoutAsking: false, findable: true, listsShown: nil
    )

    private static let states: [ProfileState] = [
        .asking, .readFailed, .read, .sending,
        .refused(sentence: "Validation failed: Display name is too long", rows: [.name: "is too long", .listsShown: "is not allowed"]),
        .forbidden, .partGone, .failed, .ended, .partly(failed: [.picture]),
    ]

    private static let arrangements: [(width: CGFloat, size: DynamicTypeSize)] = [(600, .large), (390, .large), (320, .accessibility5)]

    private func said(_ state: ProfileState) -> ProfileSaid {
        var draft = ProfileDraft(Self.account, limits: OwnLimits(name: 30, words: 500, fields: 4, fieldName: 12))
        draft.follow = true
        draft.fields[0].content = "https://alice.example/now"
        return ProfileSaid(
            host: Self.host, state: state, draft: state == .asking || state == .readFailed ? nil : draft, waiting: 3,
            lock: state == .partGone ? PartWords.Place(kind: .unasked, key: "part.account.unasked") : nil
        )
    }

    @Test("Every state of the sheet lays out at 600, 390 and 320 at the largest text, in light and in dark, and no wider than its room", arguments: 0..<2)
    func laidOut(_ dark: Int) {
        let scheme: ColorScheme = dark == 1 ? .dark : .light
        for state in Self.states {
            for (width, size) in Self.arrangements {
                let said = said(state)
                let sheet = ProfileSheet(said: said, draft: .constant(said.draft ?? ProfileDraft(OwnAccount())), framed: false)
                let view = NSHostingView(
                    rootView: sheet.frame(width: width, height: 900)
                        .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
                )
                view.layoutSubtreeIfNeeded()
                #expect(view.fittingSize.height > 0, "\(state) at \(width)")
                #expect(view.fittingSize.width <= width + 0.5, "\(state) at \(width)")
            }
        }
    }

    @Test("The picture and the header lay out held, chosen, removed, absent, refused and saved in part at 600, 390 and 320 at the largest text, in light and in dark, no wider than the room", arguments: 0..<2)
    func picturesLaidOut(_ dark: Int) {
        let scheme: ColorScheme = dark == 1 ? .dark : .light
        let pictured = OwnAccount(
            name: "Alice Example", picture: URL(string: "https://m.example/a.png"), header: URL(string: "https://m.example/h.png")
        )
        var chosen = ProfileDraft(pictured, limits: OwnLimits(picture: 16 << 20))
        chosen.stage(.picture, data: ProfileDraftTests.png(side: 64), type: .png, name: "me.png")
        chosen.remove(.header)
        var refused = ProfileDraft(OwnAccount(name: "Alice Example"), limits: OwnLimits(picture: 10))
        refused.stage(.header, data: ProfileDraftTests.png(), type: .png, name: "a-rather-long-file-name-for-a-header.png")
        let cases: [(ProfileState, ProfileDraft)] = [
            (.read, ProfileDraft(pictured)), (.read, chosen), (.read, refused), (.partly(failed: [.header]), chosen),
            (.refused(sentence: "Validation failed", rows: [.picture: "must be less than 2 MB"]), chosen),
        ]
        for (state, draft) in cases {
            for (width, size) in Self.arrangements {
                let said = ProfileSaid(host: Self.host, state: state, draft: draft)
                let view = NSHostingView(
                    rootView: ProfileSheet(said: said, draft: .constant(draft), framed: false).frame(width: width, height: 900)
                        .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
                )
                view.layoutSubtreeIfNeeded()
                #expect(view.fittingSize.height > 0, "\(state) at \(width)")
                #expect(view.fittingSize.width <= width + 0.5, "\(state) at \(width)")
            }
        }
    }

    @Test("Change stands at the far end of the name line on a wide page and beside the figures on a narrow one, inside the head, live and as its lock, in light and in dark")
    func changeInTheHead() {
        let me = Person(
            source: Source(host: Self.host, kind: .mastodon), accountID: "7", handle: "@alice@m.example", name: "Alice Example",
            tally: Person.Tally(posts: 4, following: 1, followers: 2)
        )
        for lock in [nil, PartWords.Place(kind: .unasked, key: "part.account.unasked")] {
            var head = PersonHeadSaid.made(
                of: DummyPerson(me), said: PersonSaid(source: Self.host, reading: .said(me)), tabs: PersonTab.allCases, held: 0, standing: nil
            )
            head.change = OwnChangeEntry(host: Self.host, lock: lock)
            for scheme in [ColorScheme.light, .dark] {
                for (layout, width, size) in [(ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .accessibility5)] {
                    let probe = PersonHeadProbe()
                    let view = NSHostingView(
                        rootView: PersonHead(head: head).frame(width: width)
                            .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                            .environment(\.dynamicTypeSize, size).environment(\.personHeadProbe, probe)
                    )
                    view.layoutSubtreeIfNeeded()
                    let acts = probe.frames[.acts]
                    #expect(acts != nil, "Change is drawn at \(width)")
                    if let acts { #expect(acts.minX >= 0 && acts.maxX <= probe.width + 0.5, "inside the head at \(width)") }
                    if layout == .wide, let acts, let name = probe.frames[.name] {
                        #expect(acts.minX >= name.maxX, "at the far end of the name line")
                    }
                }
            }
        }
    }
}
