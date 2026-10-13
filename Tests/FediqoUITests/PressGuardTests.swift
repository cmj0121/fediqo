import Foundation
import Testing
@testable import FediqoUI

/// The one guard of a press (#347), by itself: what a mark on a post, a notice dismissed and a
/// hashtag followed are each pressed under.
///
/// What each of the three then draws and says is held by its own suite — `ShownFirstTests`,
/// `NoticeActsShownFirstTests`, `TagFollowTests` — and every one of those fails with this
/// guard broken. Here is only what the guard itself promises, and that the three hold it.
@Suite("The one guard of a press")
struct PressGuardTests {
    @Test("One press is out for a name: a second begins nothing, another name's is its own, and what is drawn meanwhile is read here")
    func oneOutForAName() {
        var presses = PressGuard<String, Bool>()
        #expect(presses.isEmpty && !presses.isOut("a") && presses.shown("a") == nil)

        let first = presses.begin("a", showing: true)
        #expect(first != nil && presses.isOut("a") && presses.shown("a") == true)
        #expect(presses.begin("a", showing: false) == nil, "a second request went for a press already out")
        #expect(presses.shown("a") == true, "the press that began nothing changed what is drawn")
        #expect(presses.press("a") == first)

        let other = presses.begin("b", showing: false)
        #expect(other != nil && other != first, "two presses share a number")
        #expect(presses.names == ["a", "b"] && presses.all == ["a": true, "b": false])
    }

    @Test("A press turned is the same press, drawn the other way; with none out there is nothing to turn")
    func turned() {
        var presses = PressGuard<String, Bool>()
        #expect(!presses.change("a") { !$0 })
        #expect(presses.isEmpty)

        let press = presses.begin("a", showing: true)
        #expect(presses.change("a") { !$0 })
        #expect(presses.shown("a") == false)
        #expect(presses.isStill(press, "a"), "turning made it another press")
    }

    @Test("An answer is taken only by the press that began it: settled, let go of or cleared meanwhile, and begun again under the same name, the entry is another's")
    func stillItsOwn() {
        var presses = PressGuard<String, String>()
        let first = presses.begin("a", showing: "here")
        #expect(presses.isStill(first, "a"))
        #expect(!presses.isStill(first, "b"), "a press answers for a name it was not begun under")
        #expect(!presses.isStill(nil, "a"), "no press at all answers for one")

        presses.settle("a")
        #expect(!presses.isOut("a") && !presses.isStill(first, "a"))
        let second = presses.begin("a", showing: "here")
        #expect(second != nil && !presses.isStill(first, "a") && presses.isStill(second, "a"))

        let elsewhere = presses.begin("b", showing: "there")
        presses.letGo { _, shown in shown == "here" }
        #expect(!presses.isOut("a") && !presses.isStill(second, "a"), "a source's press outlived its sign-in")
        #expect(presses.isStill(elsewhere, "b"), "another source's press went with it")

        presses.clear()
        #expect(presses.isEmpty && !presses.isStill(elsewhere, "b"))
        let later = presses.begin("b", showing: "there")
        #expect(later != elsewhere && !presses.isStill(elsewhere, "b"), "a press begun after a Clear is taken for one out before it")
    }

    @Test("A mark on a post, a notice dismissed and a hashtag followed are each pressed under this guard, and none keeps a table or a count of presses of its own")
    func heldByAllThree() throws {
        let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/Shell")
        for file in ["ShellActs.swift", "ShellNoticeActs.swift", "ShellTagFollow.swift"] {
            let source = try String(contentsOf: shell.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains(" = PressGuard<"), "\(file) is not pressed under the one guard")
            #expect(!source.contains("flights"), "\(file) counts presses by itself")
        }
        let follow = try String(contentsOf: shell.appendingPathComponent("ShellTagFollow.swift"), encoding: .utf8)
        #expect(!follow.contains("ShellActs()") && !follow.contains("PostAct."), "a hashtag's press is filed under a post's act")
    }
}
