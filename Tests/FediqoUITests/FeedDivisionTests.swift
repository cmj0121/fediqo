import Foundation
import Observation
import Testing
import FediqoCore
@testable import FediqoUI

/// Three jobs, three objects.
///
/// `FeedModel` did all of it: the list and the cache in front of it, the reader's place in that
/// list, and whether anything was on its way. Fifteen stored properties in one object, and a
/// screen that read two of them read one thing — so a spinner at the foot of a cold start, which
/// changes several times a second, rebuilt the header, the tabs and every row (#70).
///
/// What these ask is what the division bought: each of the three answers on its own, with the
/// other two absent — no loader anywhere near the ring, no network anywhere near the filter —
/// and the foot changing is not the list changing.
@Suite("Three jobs, three objects")
@MainActor
struct FeedDivisionTests {
    private let a = makePost("a", at: 300)
    private let b = makePost("b", at: 200)
    private let c = makePost("c", at: 100)

    private func list(_ name: String) -> FeedPosts {
        FeedPosts(timeline: .publicFixture, preferences: Preferences(defaults: scratch(name)))
    }

    /// The list, with nothing that can load and nobody standing in it. Every one of these was a
    /// question about an object that also held a `TimelineLoader` and a ring.
    @Test("The list joins and drops with no loader and no reader anywhere near it")
    func theListAnswersAlone() {
        let posts = list("division-list")
        posts.show([a, b])

        #expect(posts.visible.map(\.uri) == ["a", "b"])

        // Older joins the end; the page already read is not touched.
        let joined = posts.append([b, c])
        #expect(joined.map(\.uri) == ["c"])
        #expect(posts.visible.map(\.uri) == ["a", "b", "c"])

        // And what an authority has taken back goes, with everything else where it was.
        posts.drop([b.mergeKey])
        #expect(posts.visible.map(\.uri) == ["a", "c"])
    }

    /// The ring, over a list, with no loader in sight. It reads the list and never writes one:
    /// moving the ring cannot change what is on the screen, which is why a press of `j` has no
    /// business redrawing anything but the two rows it moved between.
    @Test("The ring moves over a list that has no idea anything can load")
    func thePlaceAnswersAlone() {
        let posts = list("division-place")
        posts.show([a, b, c])
        let place = FeedPlace(rows: posts)

        #expect(place.moveSelection(by: 1))
        #expect(place.selectedPost?.uri == "a")
        #expect(place.moveSelection(by: 1))
        #expect(place.selectedPost?.uri == "b")

        // The bottom is the one end that is not a wall: nothing moves, and the ring is left
        // waiting for whoever holds the servers — which is not this object.
        place.moveSelection(by: 1)
        #expect(place.moveSelection(by: 1) == false)
        #expect(place.awaitingOlder)

        // And the page that arrives takes it, still with nothing that could have fetched one.
        place.land(theRingOn: [makePost("d", at: 50)])
        #expect(place.selection == "d")
        #expect(place.awaitingOlder == false)
    }

    /// What the screen leans on now that the foot is a view of its own: a reach starting and
    /// ending is the foot's news and nobody else's, so somebody watching the list is not woken
    /// for it.
    ///
    /// Asked through `FeedModel`, because that is how a screen asks — the forwarding must read
    /// the sub-object's own property, or the whole division would be undone by the façade in
    /// front of it.
    @Test("A reach starting and ending does not wake anything reading the list")
    func theFootIsNotTheList() async {
        let feed = freshFeed("division-foot")
        feed.show([a, b, c])

        let woken = Woken()
        withObservationTracking {
            _ = feed.visible
            _ = feed.hidden
        } onChange: {
            woken.raise()
        }

        await feed.loadOlder(servers: [])

        // It went out and came back — so there were writes to be woken by, and none of them
        // was the list's.
        #expect(feed.bottom == .idle)
        #expect(woken.wasWoken == false)
        #expect(feed.visible.map(\.uri) == ["a", "b", "c"])
    }

    /// The other way round, and the same rule: the list changing is not the foot's news.
    @Test("The list changing does not wake anything reading the foot")
    func theListIsNotTheFoot() {
        let feed = freshFeed("division-list-not-foot")

        let woken = Woken()
        withObservationTracking {
            _ = feed.bottom
            _ = feed.loading
        } onChange: {
            woken.raise()
        }

        feed.show([a, b, c])

        #expect(feed.visible.count == 3)
        #expect(woken.wasWoken == false)
    }
}

/// Whether a tracker fired, raisable from wherever `withObservationTracking` runs its
/// `onChange` — which is not promised to be this actor, so the flag cannot be a local `var`.
private final class Woken: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var wasWoken: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}
