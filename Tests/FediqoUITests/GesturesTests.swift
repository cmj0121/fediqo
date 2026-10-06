import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #308: the gestures are said in one place.
///
/// The page is drawn from `ShellGesture`, and the keys' table names which gesture does each
/// key's act: both are asked here, and against each other, so a gesture cannot be on the page
/// that no line of the table accounts for, nor a line name one the page leaves out.
@Suite("The gestures are said in one place", .serialized)
@MainActor
struct GesturesTests {
    @Test("The page lists only what works in the arrangement in front: on a narrow page the timeline's name and the swipe back; on a wide one the names in their row, held to change, and the Back button")
    func whatThePageLists() {
        #expect(ShellGesture.listed(narrow: true) == [.press, .hold, .pull, .stop, .top, .name, .swipe, .back])
        #expect(ShellGesture.listed(narrow: false) == [.press, .hold, .pull, .stop, .top, .pill, .pillHold, .swipe, .backButton])
        #expect(!ShellGesture.listed(narrow: false).contains(.back), "the screen's edge is the rail's on a wide page")
        #expect(!ShellGesture.listed(narrow: false).contains(.name), "and there is no one name to press")
        #expect(Set(ShellGesture.listed(narrow: true)).union(ShellGesture.listed(narrow: false)) == Set(ShellGesture.allCases), "every gesture is on one page or the other")
    }

    @Test("In both arrangements, every gesture on the page is named by a line of the keys' table or is one no key does; and every gesture a line names is on one of the two pages",
          arguments: [true, false])
    func thePageAndTheTableAgree(narrow: Bool) {
        let listed = Set(ShellGesture.listed(narrow: narrow))
        #expect(listed.subtracting(ShellGesture.named) == ShellGesture.keyless, "on the page and accounted for by no key: \(listed.subtracting(ShellGesture.named))")
        #expect(ShellGesture.keyless == [.hold])
        #expect(ShellGesture.named.isSubset(of: Set(ShellGesture.allCases)))
        #expect(ShellGesture.named.union(ShellGesture.keyless) == Set(ShellGesture.allCases))
    }

    private func gestures(_ name: String) -> [ShellGesture] {
        DummyShortcut.all.first { $0.name == name }?.gestures ?? []
    }

    @Test("Each key's line names the gesture that does its act: the swipe and the name for Tab, the top of the screen for g, the pull for r, Stop and the swipe back for Escape")
    func whichLineNamesWhich() {
        #expect(gestures("tabs") == [.swipe, .name, .pill])
        #expect(gestures("top") == [.top])
        #expect(gestures("back") == [.back, .backButton])
        #expect(gestures("expand") == [.press])
        #expect(gestures("reload") == [.pull])
        #expect(gestures("edit") == [.name, .pillHold])
        #expect(gestures("dismiss") == [.stop, .back])
        #expect(gestures("landing").isEmpty && gestures("boost").isEmpty)
    }

    @Test("No act is listed as a keyboard's alone that a finger can do: the keys' own list and replaying the landing are, and Escape is the one line still partly so")
    func whatIsStillAKeyboards() throws {
        #expect(DummyShortcut.all.filter { $0.touch == .keysOnly }.map(\.name) == ["list", "landing"])
        // The keys' list is a keyboard's still, and says where a finger reads its own.
        let list = try #require(DummyShortcut.all.first { $0.name == "list" })
        #expect(list.counterpart == "prefs.tab.gestures" && list.gestures.isEmpty)
        #expect(DummyShortcut.all.filter { $0.counterpart != nil }.map(\.name) == ["list"])
        #expect(DummyShortcut.all.filter { $0.touch == .partly }.map(\.name) == ["dismiss"])
        let dismiss = try #require(DummyShortcut.all.first { $0.name == "dismiss" })
        #expect(dismiss.also == .press && !dismiss.gestures.isEmpty, "what of Escape a finger does is said")
        #expect(DummyShortcut.all.first { $0.name == "expand" }?.also == .press, "one press opens under a finger")
        #expect(DummyShortcut.all.first { $0.name == "edit" }?.also == .press, "and changing a timeline is a press in the list of them")
    }

    @Test("Every gesture has a name and a sentence in each language the app ships, and is read as the two together")
    func theWords() {
        for gesture in ShellGesture.allCases {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(gesture.title(language: language) != gesture.titleKey, "\(gesture) has no name in \(language)")
                #expect(gesture.detail(language: language) != gesture.detailKey, "\(gesture) has no sentence in \(language)")
                #expect(gesture.spoken(language: language) == gesture.title(language: language) + ", " + gesture.detail(language: language))
            }
            #expect(gesture.title(language: .english) != gesture.title(language: .taiwanese))
        }
        #expect(Set(ShellGesture.allCases.map(\.symbol)).count == ShellGesture.allCases.count, "each its own glyph")
        for key in ["prefs.tab.gestures", "gesture.head"] {
            #expect(L10n.t(key, language: .english) != key && L10n.t(key, language: .taiwanese) != L10n.t(key, language: .english))
        }
    }

    @Test("The page is among Preferences' pages only where there is no keyboard; with one it is not offered, not reached by Tab, and not what is drawn")
    func whereThePageIs() {
        typealias Page = PreferencesPane.Purpose
        #expect(Page.shown(touch: true) == Page.allCases + [.gestures])
        #expect(Page.shown(touch: false) == Page.allCases)
        #expect(!Page.allCases.contains(.gestures), "the six pages every reader has are still six")
        #expect(Page.drawn(.gestures, touch: true) == .gestures)
        #expect(Page.drawn(.gestures, touch: false) == .choices, "a keyboard attached while it was in front")
        #expect(Page.drawn(.reach, touch: false) == .reach)
        let session = ShellSession(http: FixtureHTTP([:]), timelines: nil)
        session.preferencesPurpose = .move
        #expect(session.rotatePreferencesTab(by: 1))
        #expect(session.preferencesPurpose == .choices, "Tab goes round past the gestures, which a keyboard has no page of")
        // The gestures in front as a keyboard is attached: the first page is what is drawn,
        // and Tab goes on from it.
        session.preferencesPurpose = .gestures
        #expect(session.rotatePreferencesTab(by: 1) && session.preferencesPurpose == .build)
        session.preferencesPurpose = .gestures
        #expect(session.rotatePreferencesTab(by: -1) && session.preferencesPurpose == .move)
    }

    @Test("A post kept as the one being read is let go once it has been on screen and is not: the list moved away from it by the press on the top of the screen does not leave the mark out of sight")
    func theMarkFollowsToTheTop() {
        #expect(!ShellReadingMark.letsGo(kept: nil, seen: true, visible: ["a"]))
        #expect(!ShellReadingMark.letsGo(kept: "k", seen: false, visible: ["a"]), "not yet scrolled to: it is on its way")
        #expect(!ShellReadingMark.letsGo(kept: "k", seen: true, visible: ["k", "a"]))
        #expect(!ShellReadingMark.letsGo(kept: "k", seen: true, visible: []), "the list said nothing")
        #expect(ShellReadingMark.letsGo(kept: "k", seen: true, visible: ["a", "b"]))
        let mark = ShellReadingMark()
        mark.list(["a", "b", "c", "k"])
        mark.keep("k")
        mark.visible(["a", "b"])
        #expect(mark.id == "k", "kept and not yet seen: the list is still on its way to it")
        mark.visible(["c", "k"])
        mark.whole(["c", "k"])
        #expect(mark.id == "k")
        // The press on the top of the screen: no hand on the list, and the kept post leaves it.
        mark.whole(["a", "b"])
        mark.visible(["a", "b"])
        #expect(mark.kept == nil && mark.id == "a", "the mark is the first post at the top")
    }

    @Test("A scroll view that does not scroll up and down is told the press on the top of the screen is not for it, whether or not it scrolls sideways; a list that does is never told so")
    func whichScrollViewIsToldNo() {
        #expect(ScrollAxis.notUpAndDown(content: CGSize(width: 900, height: 30), bounds: CGSize(width: 300, height: 30)))
        #expect(ScrollAxis.notUpAndDown(content: CGSize(width: 200, height: 30), bounds: CGSize(width: 300, height: 30)), "two names that fit: still a scroll view the system counts")
        #expect(!ScrollAxis.notUpAndDown(content: CGSize(width: 300, height: 4000), bounds: CGSize(width: 300, height: 600)), "a list")
        #expect(!ScrollAxis.notUpAndDown(content: CGSize(width: 900, height: 4000), bounds: CGSize(width: 300, height: 600)), "one that scrolls both ways")
        #expect(!ScrollAxis.notUpAndDown(content: .zero, bounds: CGSize(width: 300, height: 30)), "one not yet laid out")
    }

    #if os(macOS)
    /// Where a row's far edge landed, written as it is laid out.
    private final class Landed {
        var maxX: CGFloat = 0
    }

    /// One gesture's row offered `room` and free to be wider: how tall it came out, and how far across it reached.
    private func row(_ gesture: ShellGesture, room: CGFloat, type: DynamicTypeSize) -> (height: CGFloat, reach: CGFloat) {
        let landed = Landed()
        let view = GestureRow(gesture: gesture)
            .background(GeometryReader { place in
                let _ = landed.maxX = place.frame(in: .named("page")).maxX
                Color.clear
            })
            .dynamicTypeSize(type)
            .frame(minWidth: 0, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: room, alignment: .leading)
            .coordinateSpace(.named("page"))
        let hosted = NSHostingView(rootView: view)
        hosted.frame = NSRect(x: 0, y: 0, width: room, height: 2000)
        hosted.layoutSubtreeIfNeeded()
        return (hosted.fittingSize.height, landed.maxX)
    }

    @Test("At the room a 320-point phone leaves, with the largest text, every gesture's row ends inside it and breaks into lines rather than being cut: taller than it is with room to spare")
    func thePageFits() {
        let type = DummyFontSize.largest.dynamicType
        let room: CGFloat = 250
        L10n.language = .english
        for gesture in ShellGesture.allCases {
            let narrow = row(gesture, room: room, type: type)
            let roomy = row(gesture, room: 3000, type: type)
            #expect(narrow.reach > 0 && narrow.reach <= room + 0.5, "\(gesture): the row reaches \(narrow.reach) of \(room)")
            #expect(narrow.height >= roomy.height)
        }
        // The longest sentence is longer than a line there, and is given the lines it needs.
        let long = ShellGesture.hold
        #expect(row(long, room: room, type: type).height > row(long, room: 3000, type: type).height + 10, "the sentence was cut to one line instead of broken")
    }
    #endif
}
