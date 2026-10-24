import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

extension ShellMore {
    /// What the menu's dim items say after their names, once each, in their order: what is drawn
    /// of why they do nothing, where the menu has its own words for it (`ShellMoreItem.because`).
    var whys: [String] {
        var said: [String] = []
        for item in items {
            guard case .dim = item.look, let why = item.why, !said.contains(why) else { continue }
            said.append(why)
        }
        return said
    }
}

/// #385, what every `…` holds: acts and nothing about what it belongs to; on a post's row nothing
/// its marks offer; and every act that takes something away red, last, and asked first — on a
/// question of the menu's, or on the sheet the act opens.
@Suite("A `…` holds acts, and what takes something away is red and asks first")
@MainActor
struct MoreHoldsActsTests {
    init() {
        L10n.language = .english
    }

    private static let host = "m.example"

    // MARK: - Red, its question a sheet

    @Test("An item whose question is a sheet is red, puts no question of the menu's, and its press only opens that sheet")
    func aSheetIsItsQuestion() {
        var opened = 0
        let item = ShellMoreItem.danger("hand.raised", "Block…", sheet: { opened += 1 })
        #expect(item.isDanger && item.asksOnSheet && item.question == nil && !item.isCounted)
        var put: ShellMoreAsk?
        item.press { put = $0 }
        #expect(opened == 1 && put == nil, "the press opened the sheet, and nothing else")
        // Dim, it neither opens nor acts.
        let dim = ShellMoreItem.danger("hand.raised", "Block…", look: .dim(.notNow), sheet: { opened += 1 })
        #expect(!dim.answers)
        dim.press { _ in }
        #expect(opened == 1)
        // Red stands last, under the divider, whatever order it was built in.
        let menu = ShellMore(items: [item, .plain("pencil", "Change") {}])
        #expect(menu.ordinary.map(\.name) == ["Change"] && menu.dangers.map(\.name) == ["Block…"] && menu.divides)
    }

    // MARK: - A person's page

    private static func acting(_ standing: PersonStanding, server: String? = "far.example") -> PersonActing {
        var acting = PersonActing(source: host, named: "@ada@far.example", reading: .said(standing), changes: true)
        acting.server = server
        acting.blockable = true
        acting.reportable = true
        return acting
    }

    @Test("On somebody's page, unfollowing, removing a follower, muting, blocking, blocking their server and reporting are red; taking a mute or a block back is not")
    func thePersonsRedSet() {
        let taking = Self.acting(PersonStanding(accountID: "42", following: true, followedBy: true))
        let menu = taking.menu { _ in }
        let red = Set(menu.dangers.map(\.name))
        let expected: Set<String> = [
            PersonActing.name(.unfollow), PersonActing.name(.removeFollower), PersonActing.name(.mute),
            PersonActing.name(.block), PersonActing.name(.blockServer, server: "far.example"), PersonActing.name(.report),
        ]
        #expect(red == expected, "\(red)")
        #expect(menu.ordinary.isEmpty)
        // A question of the menu's for unfollowing and removing; a sheet for the rest.
        let asked = menu.dangers.filter { $0.question != nil }.map(\.name)
        #expect(Set(asked) == [PersonActing.name(.unfollow), PersonActing.name(.removeFollower)])
        #expect(menu.dangers.filter(\.asksOnSheet).count == 4)

        let undoing = Self.acting(PersonStanding(accountID: "42", muting: true, blocking: true, serverBlocked: true))
        let back = undoing.menu { _ in }
        #expect(Set(back.ordinary.map(\.name)) == [
            PersonActing.name(.unmute), PersonActing.name(.unblock), PersonActing.name(.unblockServer, server: "far.example"),
        ])
        #expect(back.dangers.map(\.name) == [PersonActing.name(.report)])
    }

    @Test("Unfollowing asks every time: of somebody anyone may follow, that they can be followed again in one press; of somebody who must agree, that it is asked for again — and only the yes unfollows")
    func unfollowingAlwaysAsks() throws {
        for asksFirst in [false, true] {
            var acting = Self.acting(PersonStanding(accountID: "42", following: true))
            acting.asksFirst = asksFirst
            var acted: [PersonAct] = []
            let item = try #require(acting.menu { acted.append($0) }.dangers.first { $0.name == PersonActing.name(.unfollow) })
            let question = try #require(item.question)
            #expect(question == ShellQuestion.unfollow("@ada@far.example", at: Self.host, asksFirst: asksFirst))
            var put: ShellMoreAsk?
            item.press { put = $0 }
            #expect(acted.isEmpty, "choosing it only asks")
            put?.answered(try #require(question.chorded?.id))
            #expect(acted == [.unfollow])
        }
        let open = ShellQuestion.unfollow("@ada", at: Self.host, asksFirst: false, language: .english)
        let agreed = ShellQuestion.unfollow("@ada", at: Self.host, asksFirst: true, language: .english)
        #expect(open.line != agreed.line)
        #expect(ShellQuestion.unfollow("@ada", at: Self.host, asksFirst: false, language: .taiwanese).line
            != L10n.t("person.unfollow.ask.line.open", language: .english))
    }

    // MARK: - What a dim item says

    @Test("A locked item says its lock's line after its name, signed-out Translate says to sign in, and who may quote it tells the pointer and a listener that quotes already made stay")
    func whatDimItemsSay() {
        let lock = ItemActing.Lock(place: PartWords.Place(kind: .unasked, key: "part.account.unasked"), host: Self.host)
        let line = lock.headLine(language: .english)
        let pin = ItemActing.PostMore.Turn(on: false, out: false, lock: lock, press: {})
        let post = ItemActing.PostMore(translateSignedOut: Self.host, pin: pin)
        var acting = ItemActing()
        acting.post = post
        acting.report = ItemActing.Report(lock: lock) {}
        let note = Note(
            id: "1", source: Source(host: Self.host, kind: .mastodon), author: "Ada", handle: "@ada@m.example", body: "Words.",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], statusID: "1"
        )
        let menu = ItemActs.more(on: DummyItem(note), acting: acting, language: .english)
        func title(_ name: String) -> String? { menu.items.first { $0.name == name }?.title(language: .english) }
        #expect(title("Pin to your page") == ShellMark.said("Pin to your page", line, language: .english))
        #expect(title("Report post…") == ShellMark.said("Report post…", line, language: .english))
        let signIn = String(format: L10n.t("item.act.translate.signIn", language: .english), Self.host)
        #expect(title("Translate") == ShellMark.said("Translate", signIn, language: .english))
        #expect(!(title("Translate") ?? "").contains(L10n.t("mark.dim.notNow", language: .english)))

        let quotes = ItemActing.OwnQuotes(policy: .anyone, fixed: false, choose: { _ in })
        let own = ItemActs.quoteItems(quotes, language: .english)
        let stay = L10n.t("item.act.quotePolicy.line", language: .english)
        #expect(own.prefix(3).allSatisfy { $0.hint == stay && $0.look == .live })
        #expect(!ShellMore(items: own).whys.contains(stay), "a live item's line is its hint, not a reason")
    }

    // MARK: - A post's row

    @Test("On a post's row, reporting is red, last under the divider, and opens its sheet; taking a post back is red too; nothing the marks offer is there")
    func thePostsRedSet() throws {
        let note = Note(
            id: "1", source: Source(host: Self.host, kind: .mastodon), author: "Ada", handle: "@ada@m.example", body: "Words.",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], statusID: "1"
        )
        let item = DummyItem(note)
        var reported = 0, taken = 0
        var acting = ItemActing(
            acts: PostActs(offered: Set(PostAct.allCases)), perform: { _ in }, keep: {}, ask: { _ in },
            withdraw: ItemActing.Withdraw(asks: { ShellQuestion.withdraw(item) }, yes: { taken += 1 })
        )
        acting.report = ItemActing.Report(lock: nil) { reported += 1 }
        let menu = ItemActs.more(on: item, acting: acting, leave: {}, language: .english)
        #expect(menu.ordinary.map(\.name) == [item.outwardName])
        #expect(menu.dangers.map(\.name) == ["Report post…", "Take back what you wrote"])
        let report = try #require(menu.dangers.first)
        #expect(report.asksOnSheet && report.question == nil)
        report.press { _ in }
        #expect(reported == 1 && taken == 0)
        let marks = Set(ItemActs.marks(on: item, acting: acting, language: .english).map(\.mark.name))
        #expect(marks.isDisjoint(with: menu.items.map(\.name)))
        // Nothing that is not red puts a question.
        #expect(menu.ordinary.allSatisfy { $0.question == nil && !$0.asksOnSheet && !$0.isCounted })
    }
}
