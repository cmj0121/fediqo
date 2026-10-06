import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #305: a sideways swipe goes to the next timeline.
///
/// The rules are functions and are asked directly: whether a drag is a swipe at all, where one
/// let go leads, which timeline is beside which, when a swipe is heard, how far the list follows
/// the finger, and where a timeline switched to opens. The recogniser that feeds them is an
/// iPhone's and is not reached from here — nor is how any of it feels.
@Suite("A sideways swipe goes to the next timeline")
@MainActor
struct TimelineSwipeTests {
    @Test("A drag is a swipe only if it set out level: sideways at least twice as far as up or down — from anywhere on the list")
    func whatBegins() {
        #expect(TimelineSwipe.begins(dx: 10, dy: 0))
        #expect(TimelineSwipe.begins(dx: -10, dy: 5), "twice as far across as down is level enough")
        #expect(!TimelineSwipe.begins(dx: 10, dy: 5.5))
        #expect(!TimelineSwipe.begins(dx: 10, dy: 10), "a diagonal drag scrolls")
        #expect(!TimelineSwipe.begins(dx: 0, dy: 10), "a drag up or down scrolls")
        #expect(!TimelineSwipe.begins(dx: 3, dy: -40))
        #expect(!TimelineSwipe.begins(dx: 0, dy: 0))
    }

    @Test("Let go far enough across it goes, and so does a flick that way; short and slow it does not; flicked hard back the way it came it does not, however far it went. Toward the leading edge is the next timeline")
    func whereItLeads() {
        #expect(TimelineSwipe.outcome(dx: -64, velocity: 0) == 1, "pushed toward the leading edge, the next comes in")
        #expect(TimelineSwipe.outcome(dx: 64, velocity: 0) == -1)
        #expect(TimelineSwipe.outcome(dx: -63, velocity: 0) == 0)
        #expect(TimelineSwipe.outcome(dx: -24, velocity: -500) == 1, "a flick")
        #expect(TimelineSwipe.outcome(dx: 24, velocity: 500) == -1)
        #expect(TimelineSwipe.outcome(dx: -23, velocity: -900) == 0, "too short to be a flick")
        #expect(TimelineSwipe.outcome(dx: -30, velocity: -499) == 0, "too slow")
        #expect(TimelineSwipe.outcome(dx: -30, velocity: 900) == 0, "flicked back the way it came")
        #expect(TimelineSwipe.outcome(dx: -200, velocity: 500) == 0, "far across, and flicked hard back")
        #expect(TimelineSwipe.outcome(dx: 200, velocity: -500) == 0)
        #expect(TimelineSwipe.outcome(dx: -200, velocity: 499) == 1, "drifting back slowly is not a flick back")
        #expect(TimelineSwipe.outcome(dx: 0, velocity: 0) == 0)
    }

    @Test("A drag let go is acted on only if the timeline in front is still the one it began on; and no new drag is heard while the list is still sliding")
    func stillTheSameTimeline() {
        #expect(TimelineSwipe.completes(startedOn: "all", inFront: "all"))
        #expect(!TimelineSwipe.completes(startedOn: "all", inFront: "trends"))
        #expect(!TimelineSwipe.completes(startedOn: nil, inFront: "all"))
        #expect(!TimelineSwipe.completes(startedOn: nil, inFront: nil))
        #expect(TimelineSwipe.hears(leaving: false) && !TimelineSwipe.hears(leaving: true))
    }

    @Test("A sideways swipe means one thing a page: on the timeline's own page — with posts or with none — the timeline beside; on a post, a person or a tag opened over it, back; on a page read out of a post, nothing")
    func whatASwipeMeans() {
        func means(_ page: TimelineSwipe.Page, touch: Bool = true, searching: Bool = false, list: Bool = false, editing: Bool = false) -> TimelineSwipe.Means? {
            TimelineSwipe.means(touch: touch, page: page, searching: searching, listShown: list, editing: editing)
        }
        #expect(means(.timeline) == .beside)
        #expect(means(.opened) == .back)
        #expect(means(.link) == nil)
        #expect(means(.timeline, touch: false) == nil && means(.opened, touch: false) == nil, "nothing with a keyboard")
        #expect(means(.timeline, searching: true) == nil, "a search's results are no timeline")
        #expect(means(.opened, searching: true) == .back)
        #expect(means(.timeline, list: true) == nil && means(.opened, editing: true) == nil)
        // Anything drawn over the page — a picture, the keys' guide, the landing — and no swipe.
        for page in [TimelineSwipe.Page.timeline, .opened] {
            #expect(TimelineSwipe.means(touch: true, page: page, searching: false, listShown: false, editing: false, covered: true) == nil)
        }
        #expect(FediqoRootView.covered(viewing: true, shortcuts: false, landing: false))
        #expect(FediqoRootView.covered(viewing: false, shortcuts: true, landing: false))
        #expect(FediqoRootView.covered(viewing: false, shortcuts: false, landing: true))
        #expect(!FediqoRootView.covered(viewing: false, shortcuts: false, landing: false))
        // The page is what the walk stands on, and nothing about what the timeline has to draw:
        // an empty one, one still reading and one that failed are all the timeline's own page.
        #expect(TimelinePane.page(nil) == .timeline)
        #expect(TimelinePane.page(.thread("a")) == .opened)
        if let tag = PostTag("fediqo") { #expect(TimelinePane.page(.tag(tag)) == .opened) }
        #expect(TimelinePane.page(.link(URL(string: "https://fixture.example/")!)) == .link)
        #expect(TimelinePane.openedID(.thread("a")) == "thread:a" && TimelinePane.openedID(nil) == nil)
    }

    @Test("Back is the swipe that goes to the timeline before: the finger toward the trailing edge, by the same distance or the same flick; the other way, short, or flicked hard back, it is not")
    func theSwipeBack() {
        #expect(TimelineSwipe.goesBack(dx: 64, velocity: 0))
        #expect(TimelineSwipe.goesBack(dx: 24, velocity: 500))
        #expect(!TimelineSwipe.goesBack(dx: 63, velocity: 0))
        #expect(!TimelineSwipe.goesBack(dx: -200, velocity: 0), "the other way goes nowhere")
        #expect(!TimelineSwipe.goesBack(dx: 200, velocity: -500), "flicked hard back the way it came")
        let ways = TimelineSwipe.ways(.back, index: 2, count: 5)
        #expect(!ways.next && ways.previous, "only the way back: the other way is a rubber band")
        #expect(TimelineSwipe.follow(dx: -90, hasNext: ways.next, hasPrevious: ways.previous) == -30)
        #expect(TimelineSwipe.follow(dx: 90, hasNext: ways.next, hasPrevious: ways.previous) == 90)
    }

    @Test("On a page with tabs a swipe goes to the tab beside and stops at the first and the last; with a row's detail open it means back and no tab; with a keyboard it means nothing")
    func aPageWithTabs() {
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 4) == .beside)
        #expect(TimelineSwipe.means(touch: true, detail: true, tabs: 4) == .back)
        #expect(TimelineSwipe.means(touch: false, detail: false, tabs: 4) == nil && TimelineSwipe.means(touch: false, detail: true, tabs: 4) == nil)
        // With fewer than two tabs and no detail there is no swipe at all; a detail is still left by one.
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 0) == nil)
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 1) == nil)
        #expect(TimelineSwipe.means(touch: true, detail: true, tabs: 0) == .back)
        // And none under anything drawn over the page.
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: 4, covered: true) == nil)
        #expect(TimelineSwipe.means(touch: true, detail: true, tabs: 4, covered: true) == nil)
        #expect(TimelineSwipe.backstop > 0.16 + 0.2 + 0.02, "the backstop comes after both animations")
        for count in [UsagePane.Purpose.allCases.count, PreferencesPane.Purpose.shown(touch: true).count, AccountPane.Purpose.allCases.count, EditorTab.allCases.count] {
            #expect(count >= 2)
            let first = TimelineSwipe.ways(.beside, index: 0, count: count), last = TimelineSwipe.ways(.beside, index: count - 1, count: count)
            #expect(first.next && !first.previous, "nothing before the first tab: a swipe never goes on into another place")
            #expect(!last.next && last.previous)
            #expect(TimelineSwipe.target(from: 0, count: count, step: 1) == 1)
        }
        // A page with no tabs has nowhere to go either way.
        let none = TimelineSwipe.ways(.beside, index: nil, count: 0)
        #expect(!none.next && !none.previous)
    }

    @Test("A swipe that sets out on a row that scrolls sideways is that row's; a list that scrolls up and down is swiped across")
    func whatIsNotSwipedAcross() {
        #expect(SwipeObstacle.scrollsSideways(content: CGSize(width: 900, height: 30), bounds: CGSize(width: 300, height: 30)))
        #expect(!SwipeObstacle.scrollsSideways(content: CGSize(width: 300, height: 4000), bounds: CGSize(width: 300, height: 600)), "a list is swiped across")
    }

    @Test("A swipe does not begin on a page's head — the timeline's name and marks, a row of tabs — and does begin under it")
    func whereASwipeBegins() {
        let head = CGRect(x: 0, y: 0, width: 320, height: 60), tabs = CGRect(x: 16, y: 80, width: 288, height: 30)
        #expect(SwipeZone.refuses(CGPoint(x: 100, y: 30), zones: [head, tabs]))
        #expect(SwipeZone.refuses(CGPoint(x: 100, y: 95), zones: [head, tabs]))
        #expect(!SwipeZone.refuses(CGPoint(x: 100, y: 300), zones: [head, tabs]), "under the head, on what moves")
        #expect(!SwipeZone.refuses(CGPoint(x: 100, y: 30), zones: []))
    }

    @Test("The head's dot leans by the share of the page a finger has moved it, toward the next as positive — and not at all where the swipe means back, or before the page is measured")
    func theLean() {
        #expect(TimelineSwipe.lean(moved: -128, width: 320, beside: true) == 0.4)
        #expect(TimelineSwipe.lean(moved: 128, width: 320, beside: true) == -0.4)
        #expect(TimelineSwipe.lean(moved: 128, width: 320, beside: false) == 0, "a swipe back leans toward nobody")
        #expect(TimelineSwipe.lean(moved: -128, width: 0, beside: true) == 0)
        let slide = PageSlide()
        #expect(slide.lean == 0 && !slide.listShown)
        // Toward the trailing edge is positive whichever way the language reads (the recogniser
        // turns it round before asking), so the lean is toward the next in both.
        // Let go, the dots are sent the rest of the way to the one beside, with the page.
        #expect(TimelineSwipe.leaves(by: 1, beside: true, still: false) == 1)
        #expect(TimelineSwipe.leaves(by: -1, beside: true, still: false) == -1)
        #expect(TimelineSwipe.leaves(by: -1, beside: false, still: false) == 0, "going back, there is no one beside")
        #expect(TimelineSwipe.leaves(by: 1, beside: true, still: true) == 0, "with motion reduced nothing leans")
    }

    #if os(macOS)
    /// Where two things landed, written as they are laid out.
    private final class Landed {
        var head = CGRect.zero
        var under = CGRect.zero
    }

    @Test("What is slid is what the slide is put on, and nothing beside it: the head above stays exactly where it was, before, during and after")
    func onlyWhatIsUnderTheHeadMoves() {
        let slide = PageSlide()
        let landed = Landed()
        let view = VStack(spacing: 0) {
            Color.clear.frame(height: 40)
                .background(GeometryReader { place in
                    let _ = landed.head = place.frame(in: .global)
                    Color.clear
                })
            Color.clear.frame(height: 100)
                .background(GeometryReader { place in
                    let _ = landed.under = place.frame(in: .global)
                    Color.clear
                })
                .modifier(Slid(slide: slide, applies: true))
        }
        .frame(width: 300)
        let hosted = NSHostingView(rootView: view)
        hosted.frame = NSRect(x: 0, y: 0, width: 300, height: 140)
        func settle() {
            hosted.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: .distantPast)
        }
        settle()
        let head = landed.head, under = landed.under
        slide.x = -120
        settle()
        #expect(landed.head == head, "the head moved to \(landed.head) from \(head)")
        #expect(abs(landed.under.minX - (under.minX - 120)) <= 0.5, "what is under it is at \(landed.under.minX), slid from \(under.minX)")
        slide.x = 0
        settle()
        #expect(landed.head == head && abs(landed.under.minX - under.minX) <= 0.5)
    }
    #endif

    @Test("A list slid sideways is held to its pane's own sides under a finger, and cut nowhere above or below; with a keyboard nothing is cut at all")
    func theSlideIsHeld() {
        let pane = CGRect(x: 0, y: 0, width: 300, height: 600)
        let held = SlideBounds(holds: true).path(in: pane).boundingRect
        #expect(held.minX == 0 && held.maxX == 300, "the sides are the pane's")
        #expect(held.minY < -1000 && held.maxY > 1600, "nothing is cut above or below")
        let free = SlideBounds(holds: false).path(in: pane).boundingRect
        #expect(free.minX < -1000 && free.maxX > 1300 && free.minY < -1000)
    }

    @Test("VoiceOver is told the timeline arrived at by its name and where it stands, in both languages; one timeline is its name alone")
    func whatIsAnnounced() {
        #expect(TimelineSwipe.announcement(name: "Lin", position: 4, count: 5, language: .english) == "Lin, 5 of 5")
        #expect(TimelineSwipe.announcement(name: "Lin", position: 0, count: 5, language: .taiwanese) == "Lin, 第 1 條，共 5 條")
        #expect(TimelineSwipe.announcement(name: "All", position: 0, count: 1, language: .english) == "All")
        #expect(TimelineSwipe.announcement(name: "All", position: nil, count: 5, language: .english) == "All")
    }

    @Test("The timeline beside is one on or one back, and at either end there is none: they do not go round")
    func theNeighbour() {
        #expect(TimelineSwipe.target(from: 0, count: 3, step: 1) == 1)
        #expect(TimelineSwipe.target(from: 1, count: 3, step: -1) == 0)
        #expect(TimelineSwipe.target(from: 2, count: 3, step: 1) == nil)
        #expect(TimelineSwipe.target(from: 0, count: 3, step: -1) == nil)
        #expect(TimelineSwipe.target(from: nil, count: 3, step: 1) == nil)
        #expect(TimelineSwipe.target(from: 0, count: 3, step: 0) == nil)
        #expect(TimelineSwipe.target(from: 0, count: 1, step: 1) == nil)
    }

    @Test("The list follows the finger all the way toward a timeline that is there, and a third as far at an end where there is none")
    func howFarTheListFollows() {
        #expect(TimelineSwipe.follow(dx: -90, hasNext: true, hasPrevious: false) == -90)
        #expect(TimelineSwipe.follow(dx: 90, hasNext: true, hasPrevious: false) == 30, "no timeline before the first")
        #expect(TimelineSwipe.follow(dx: -90, hasNext: false, hasPrevious: true) == -30, "none after the last")
        #expect(TimelineSwipe.follow(dx: 90, hasNext: false, hasPrevious: true) == 90)
    }

    @Test("A timeline switched to opens at the post it was left at, and one never visited at its first post")
    func whereATimelineOpens() {
        #expect(TimelineSwipe.opensAt(kept: "kept", first: "first") == "kept")
        #expect(TimelineSwipe.opensAt(kept: nil, first: "first") == "first")
        #expect(TimelineSwipe.opensAt(kept: nil, first: nil) == nil)
        // As the list asks it: under a finger and with a keyboard alike.
        #expect(TimelinePane.arrival(selected: nil, returning: nil, touch: true, first: "first") == .top("first"))
        #expect(TimelinePane.arrival(selected: nil, returning: nil, touch: false, first: "first") == .top("first"))
        #expect(TimelinePane.arrival(selected: nil, returning: "kept", touch: true, first: "first") == .top("kept"))
        #expect(TimelinePane.arrival(selected: "kept", returning: nil, touch: false, first: "first") == .centred("kept"))
        #expect(TimelinePane.arrival(selected: nil, returning: nil, touch: true, first: nil) == nil)
    }

    @Test("VoiceOver's scroll goes on toward the trailing edge and back toward the leading, and nowhere up or down")
    func theScrollAction() {
        #expect(ScrollsToNeighbour.step(toward: .trailing) == 1)
        #expect(ScrollsToNeighbour.step(toward: .leading) == -1)
        #expect(ScrollsToNeighbour.step(toward: .top) == 0 && ScrollsToNeighbour.step(toward: .bottom) == 0)
    }

    @Test("A step goes to the timeline beside the one in front, in the order they are listed, and stops at either end leaving it where it was")
    func aStep() throws {
        let session = ShellSession(http: FixtureHTTP([:]), timelines: nil)
        session.sources = [Source(host: "m.example", kind: .mastodon)]
        session.rebuildQueries()
        session.timelineID = .all
        let count = session.queries.count
        #expect(count >= 2)
        #expect(!session.stepTimeline(by: -1) && session.currentTimeline == .all, "nothing before the first")
        for index in 1 ..< count {
            #expect(session.stepTimeline(by: 1))
            #expect(session.currentTimeline == session.queries[index])
        }
        #expect(!session.stepTimeline(by: 1) && session.currentTimeline == session.queries[count - 1], "nothing after the last")
        #expect(session.stepTimeline(by: -1) && session.currentTimeline == session.queries[count - 2])
        #expect(!session.stepTimeline(by: 0))
    }
}
