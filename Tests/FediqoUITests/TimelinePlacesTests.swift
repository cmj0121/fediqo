import Foundation
@testable import FediqoCore
import Testing
@testable import FediqoUI

/// #100: each timeline keeps the post the reader was on, for as long as this run lasts.
@Suite("Where each timeline was left")
@MainActor
struct TimelinePlacesTests {
    private let mine = TimelineQuery.written(UUID())

    /// The ids All holds, in the test's own shorthand. A timeline is a list of posts to this
    /// type and nothing more, so the tests state one rather than standing a store up.
    private let allPosts = ["a1", "a2", "a3"]
    private let trendPosts = ["t1", "t2"]
    private let minePosts = ["a2", "m1"]

    // MARK: Acceptance: leave a timeline and come back to the post you were on

    @Test("Standing on a post, switching away and switching back lands on that post")
    func comingBack() {
        var places = TimelinePlaces()
        // On All, standing on the third post; press Trends.
        #expect(places.switched(from: .all, to: .trends, standingOn: "a3", among: trendPosts) == nil)
        // Press All again.
        #expect(places.switched(from: .trends, to: .all, standingOn: nil, among: allPosts) == "a3")
    }

    @Test("All, Trends and a written timeline each keep their own")
    func eachKeepsItsOwn() {
        var places = TimelinePlaces()
        _ = places.switched(from: .all, to: .trends, standingOn: "a1", among: trendPosts)
        _ = places.switched(from: .trends, to: mine, standingOn: "t2", among: minePosts)
        _ = places.switched(from: mine, to: .all, standingOn: "m1", among: allPosts)

        #expect(places.arriving(at: .all, among: allPosts) == "a1")
        #expect(places.arriving(at: .trends, among: trendPosts) == "t2")
        #expect(places.arriving(at: mine, among: minePosts) == "m1")
    }

    /// The same post in two timelines is two places, not one: All moving does not move the one
    /// the reader wrote, and neither is the other's.
    @Test("One timeline does not overwrite another")
    func noOverwriting() {
        var places = TimelinePlaces()
        _ = places.switched(from: .all, to: mine, standingOn: "a2", among: minePosts)
        _ = places.switched(from: mine, to: .all, standingOn: "m1", among: allPosts)
        _ = places.switched(from: .all, to: mine, standingOn: "a1", among: minePosts)

        #expect(places.arriving(at: .all, among: allPosts) == "a1")
        #expect(places.arriving(at: mine, among: minePosts) == "m1")
    }

    @Test("A timeline opened for the first time this run borrows nobody's place")
    func firstOpenInheritsNothing() {
        var places = TimelinePlaces()
        // Two switches, and Trends has never been in front.
        _ = places.switched(from: .all, to: mine, standingOn: "a3", among: minePosts)
        #expect(places.switched(from: mine, to: .trends, standingOn: nil, among: trendPosts) == nil)
        #expect(places.arriving(at: .trends, among: trendPosts) == nil)
    }

    @Test("A post the timeline no longer holds is not lit")
    func aPostThatLeft() {
        var places = TimelinePlaces()
        _ = places.switched(from: .all, to: .trends, standingOn: "a3", among: trendPosts)
        // `a3` fell out of the reader's window, or the source it came from was removed.
        #expect(places.switched(from: .trends, to: .all, standingOn: nil, among: ["a1", "a2"]) == nil)
    }

    /// A reader who left a timeline with nothing lit comes back to nothing lit, rather than to
    /// whatever was lit the time before that.
    @Test("Standing nowhere is kept as nowhere")
    func nowhereIsAPlaceToo() {
        var places = TimelinePlaces()
        _ = places.switched(from: .all, to: .trends, standingOn: "a1", among: trendPosts)
        _ = places.switched(from: .trends, to: .all, standingOn: nil, among: allPosts)
        _ = places.switched(from: .all, to: .trends, standingOn: nil, among: trendPosts)
        #expect(places.arriving(at: .all, among: allPosts) == nil)
    }

    /// A switch straight back onto the timeline just left reads what this same call wrote, and
    /// not what was there before it — which is why leaving and arriving are one call.
    @Test("A switch onto the timeline just left reads what that switch wrote")
    func leaveBeforeArrive() {
        var places = TimelinePlaces()
        _ = places.switched(from: .all, to: .trends, standingOn: "a1", among: trendPosts)
        #expect(places.switched(from: .all, to: .all, standingOn: "a2", among: allPosts) == "a2")
    }

    // MARK: The session is what holds them, for this run

    @Test("The session holds one set of places, and a fresh session holds none")
    func heldBySession() {
        let session = ShellSession(http: FixtureHTTP([:]))
        #expect(session.timelinePlaces.arriving(at: .all, among: allPosts) == nil)
        session.timelinePlaces.leave(.all, standingOn: "a2")
        #expect(session.timelinePlaces.arriving(at: .all, among: allPosts) == "a2")

        let next = ShellSession(http: FixtureHTTP([:]))
        #expect(next.timelinePlaces.arriving(at: .all, among: allPosts) == nil)
    }
}
