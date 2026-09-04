import Foundation
import Testing
@testable import FediqoCore

/// Several people doing the same thing to one post, as one row (#124).
@Suite("One thing that happened")
struct NoticeGroupTests {
    private func notice(_ id: String, _ kind: NoticeKind = .favourite,
                        about key: String? = "https://a.example/1",
                        by who: String = "a", late minutes: Int = 0) -> Notice {
        Notice(remoteId: id, serverURL: "https://a.example", kind: kind, ownerId: "me",
               actorId: "https://a.example/users/\(who)", actorName: "Who \(who)",
               actorHandle: "@\(who)@a.example", post: nil, postKey: key,
               noticedAt: Date(timeIntervalSince1970: 1000 - Double(minutes) * 60),
               arrivedAt: Date(timeIntervalSince1970: 1000))
    }

    @Test("The same kind about the same post is one row that says how many")
    func onerow() {
        let rows = Notice.grouped([notice("1", by: "a"), notice("2", by: "b"), notice("3", by: "c")])
        #expect(rows.count == 1)
        #expect(rows[0].count == 3)
        #expect(rows[0].actors == ["Who a", "Who b", "Who c"])
    }

    /// Two different things somebody did are two rows. A favourite and a boost on one post are
    /// not one event that happened three times.
    @Test("Different kinds about one post stay different rows")
    func differentKinds() {
        let rows = Notice.grouped([notice("1", .favourite), notice("2", .boost)])
        #expect(rows.count == 2)
    }

    @Test("The same kind about different posts stays different rows")
    func differentPosts() {
        let rows = Notice.grouped([notice("1", about: "https://a.example/1"),
                                   notice("2", about: "https://a.example/2")])
        #expect(rows.count == 2)
    }

    /// A follow is about a person. Being followed is not something that happens to you
    /// repeatedly in a way worth adding up, and two follows are two people.
    @Test("Events about no post never group")
    func aboutNoPost() {
        let rows = Notice.grouped([notice("1", .follow, about: nil, by: "a"),
                                   notice("2", .follow, about: nil, by: "b")])
        #expect(rows.count == 2)
    }

    /// **The one the photograph found.** The store keeps the post's key on the notice's own row
    /// and joins to `posts`; a post it has let go of leaves `post` nil while the event still
    /// knows which post it was about. Grouping on `post?.mergeKey` said *no* to every one of
    /// them and drew a row each.
    @Test("A post this device no longer holds is still the same post")
    func apostNoLongerHeld() {
        let rows = Notice.grouped([notice("1", by: "a"), notice("2", by: "b")])
        #expect(rows[0].notices.allSatisfy { $0.post == nil })
        #expect(rows.count == 1)
    }

    /// A row sits where its newest event sat, so grouping never reorders the list.
    @Test("A row sits where its newest event sat")
    func whereTheNewestSat() {
        let rows = Notice.grouped([
            notice("1", about: "https://a.example/1", late: 0),
            notice("2", about: "https://a.example/2", late: 5),
            notice("3", about: "https://a.example/1", late: 20),
        ])
        #expect(rows.map(\.newest.remoteId) == ["1", "2"])
        #expect(rows[0].count == 2)
    }

    /// Any of them unseen makes the row unseen: a reader who has read five of six has not read
    /// the sixth.
    @Test("One thing unread makes the row unread")
    func onethingUnread() {
        let read = Notice(remoteId: "1", serverURL: "https://a.example", kind: .favourite,
                          ownerId: "me", actorId: "x", postKey: "k",
                          noticedAt: Date(), arrivedAt: Date(), seenAt: Date())
        let unread = Notice(remoteId: "2", serverURL: "https://a.example", kind: .favourite,
                            ownerId: "me", actorId: "y", postKey: "k",
                            noticedAt: Date(), arrivedAt: Date())
        #expect(NoticeGroup([read, unread]).isUnseen)
        #expect(!NoticeGroup([read]).isUnseen)
    }

    /// Somebody who favourited, unfavourited and favourited again is one person, not three.
    @Test("Each person is named once")
    func namedOnce() {
        let rows = Notice.grouped([notice("1", by: "a"), notice("2", by: "a"), notice("3", by: "b")])
        #expect(rows[0].count == 3)
        #expect(rows[0].actors == ["Who a", "Who b"])
    }

    /// A row that stops being a group must not change its name and take the ring somewhere else.
    @Test("A row of one is named by the pair, like a row of three")
    func arowOfOne() {
        let alone = Notice.grouped([notice("1")])[0]
        let several = Notice.grouped([notice("1"), notice("2", by: "b")])[0]
        #expect(alone.id == several.id)
    }
}
