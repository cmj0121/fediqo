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

    @Test("A swipe in from the leading edge goes back only under a finger and only from a page opened over the list: a post, a person, a tag")
    func theSwipeBack() {
        #expect(TimelineSwipe.backHeard(touch: true, opened: true))
        #expect(!TimelineSwipe.backHeard(touch: false, opened: true))
        #expect(!TimelineSwipe.backHeard(touch: true, opened: false))
        #expect(TimelinePane.backs(from: .thread("a")))
        if let tag = PostTag("fediqo") { #expect(TimelinePane.backs(from: .tag(tag))) }
        #expect(!TimelinePane.backs(from: nil), "the list itself has nothing to go back to")
        #expect(!TimelinePane.backs(from: .link(URL(string: "https://fixture.example/")!)), "somebody's page keeps its own edge")
    }

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

    @Test("A swipe is heard only with nothing but a finger and the list itself in front: not with a keyboard, a post opened, a search, the list of timelines or the editor")
    func whenItIsHeard() {
        #expect(TimelineSwipe.enabled(touch: true, opened: false, searching: false, listShown: false, editing: false))
        #expect(!TimelineSwipe.enabled(touch: false, opened: false, searching: false, listShown: false, editing: false))
        #expect(!TimelineSwipe.enabled(touch: true, opened: true, searching: false, listShown: false, editing: false))
        #expect(!TimelineSwipe.enabled(touch: true, opened: false, searching: true, listShown: false, editing: false))
        #expect(!TimelineSwipe.enabled(touch: true, opened: false, searching: false, listShown: true, editing: false))
        #expect(!TimelineSwipe.enabled(touch: true, opened: false, searching: false, listShown: false, editing: true))
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
