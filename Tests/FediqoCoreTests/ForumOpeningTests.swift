import Foundation
import Testing

@testable import FediqoCore

/// A forum row's opening post, kept with the row in the store — #154.
@Suite("An opening post kept with its row")
struct ForumOpeningTests {
    let forum = Source(host: "bbs.example", kind: .discuz)

    func row(_ tid: Int = 1, opening: ForumOpening? = nil) -> Note {
        Note(
            id: "discuz:bbs.example:\(tid)", source: forum, author: "a", handle: "@a@bbs.example",
            body: "", title: "t", postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [.board(id: "7")], opening: opening
        )
    }

    @Test("A withheld post is not an opening to keep; one with no words is")
    func withheldIsNotKept() {
        let withheld = DiscuzPost(pid: 1, tid: 1, author: "a", handle: "@a", body: "", isWithheld: true)
        #expect(ForumOpening(withheld) == nil)
        let silent = DiscuzPost(pid: 1, tid: 1, author: "a", handle: "@a", body: "")
        #expect(ForumOpening(silent) == ForumOpening(words: ""))
    }

    @Test("Kept only for a row held, and a board read again leaves it where it is")
    func keptWithTheRow() async {
        let store = ItemStore(sources: [forum], notes: [row()])
        let kept = ForumOpening(words: "words")
        #expect(await store.keep([row().key: kept]))
        #expect(await !store.keep([row().key: kept]), "the same words again changed something")
        #expect(await !store.keep([row(2).key: kept]), "a row nobody holds was brought in")
        #expect(await store.note(row().key)?.opening == kept)

        // A board listing carries no opening post: it neither replaces the row nor clears it.
        await store.ingest([row()])
        #expect(await store.note(row().key)?.opening == kept)
        await store.refresh([row()], ifSourceHere: "bbs.example")
        #expect(await store.note(row().key)?.opening == kept)
    }

    @Test("The keep-for window takes the words with the row")
    func retentionDecides() async {
        let store = ItemStore(sources: [forum], notes: [row(opening: ForumOpening(words: "w"))])
        let dropped = await store.setRetention(months: 1, from: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(dropped == 1)
        #expect(await store.note(row().key) == nil)
    }
}
