import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// Where the reader is standing in their inbox (#122).
///
/// The one ring in this app that is not `FeedPlace`, and these assertions are why: **a notice is
/// not a post.** Somebody following you is a notice with no post at all, so a ring keyed on merge
/// keys would have skipped every follow in the list.
@Suite("Standing in the inbox")
@MainActor
struct NoticePlaceTests {
    private func notice(_ id: String, post: Post? = nil) -> Notice {
        Notice(remoteId: id, serverURL: "https://inbox.example", kind: .mention,
               ownerId: "https://inbox.example/users/me",
               actorId: "https://inbox.example/users/a",
               actorName: "A", actorHandle: "@a@inbox.example", post: post,
               noticedAt: Date(timeIntervalSince1970: 100),
               arrivedAt: Date(timeIntervalSince1970: 100))
    }

    /// `Notice.id` is the pair — a remote id is unique on one server and nowhere else — so the
    /// ring names the pair too.
    private func key(_ id: String) -> String { "https://inbox.example#\(id)" }

    /// The ring names a row rather than an event since #124, so the list it walks is the
    /// grouped one — which for these, each about a different post, is one row each.
    private func place(_ notices: [Notice]) -> NoticePlace {
        let rows = Notice.grouped(notices)
        return NoticePlace(rows: { rows })
    }

    /// A follow has no post, and it is still a row the ring must be able to stand on.
    @Test("The ring stands on notices, post or no post")
    func onNoticesAndNotPosts() {
        let list = [notice("1"), notice("2")]
        let standing = place(list)
        standing.move(by: 1)
        #expect(standing.selection == key("1"))
        standing.move(by: 1)
        #expect(standing.selection == key("2"))
        #expect(standing.selected?.id == key("2"))
    }

    /// From nothing, either direction lands on the first: a reader pressing `k` on a list they
    /// have not entered means "start", not "go back past the beginning".
    @Test("From nothing, either way lands on the first")
    func fromNothing() {
        for step in [1, -1] {
            let standing = place([notice("1"), notice("2")])
            #expect(standing.move(by: step))
            #expect(standing.selection == key("1"))
        }
    }

    /// It stops at the ends rather than wrapping, which is what the timeline's does — a ring
    /// that wrapped would take a reader from the oldest thing that happened to the newest
    /// without saying it had.
    @Test("It stops at both ends")
    func stopsAtTheEnds() {
        let standing = place([notice("1"), notice("2")])
        standing.move(by: 1)
        #expect(standing.selection == key("1"))
        // At the top already, so back is nowhere and the ring stays where it was.
        #expect(!standing.move(by: -1))
        #expect(standing.selection == key("1"))
        #expect(standing.move(by: 1))
        #expect(standing.selection == key("2"))
        #expect(!standing.move(by: 1))
        #expect(standing.selection == key("2"))
    }

    @Test("An empty inbox has nowhere to stand")
    func nowhereToStand() {
        let standing = place([])
        #expect(!standing.move(by: 1))
        #expect(standing.selection == nil)
    }

    /// Rotation takes old notices, so the ring can be left pointing at one that has gone — and
    /// a ring pointing at nothing must say nothing rather than the wrong thing.
    @Test("A notice that has gone is not what the ring is on")
    func agoneNotice() {
        var list = Notice.grouped([notice("1"), notice("2")])
        let standing = NoticePlace(rows: { list })
        standing.select(list[1])
        #expect(standing.selected?.id == key("2"))
        list = Notice.grouped([notice("1")])
        #expect(standing.selected == nil)
    }

    @Test("The top is the first, and says it was asked for")
    func theTop() {
        let standing = place([notice("1"), notice("2")])
        standing.select(NoticeGroup([notice("2")]))
        let before = standing.topRequests
        standing.goToTop()
        #expect(standing.selection == key("1"))
        #expect(standing.topRequests == before + 1)
    }
}
