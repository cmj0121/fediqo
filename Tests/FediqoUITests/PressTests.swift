import Foundation
import FediqoCore
import Testing
@testable import FediqoUI

/// What `m` and `s` do to the post the reader is on — the rule about *which* post that is, and
/// the rule about what happens to it. Both are pure; the view is the six lines of glue between
/// them, and what those six lines do is asserted here by composing the same two pieces.
@Suite("Pressing m and s")
struct PressTests {
    private static func item(_ id: String, attachments: Int = 0, spoiler: String? = nil) -> DummyItem {
        DummyItem(Note(
            id: id,
            source: Source(host: "first.example", kind: .mastodon),
            author: "Ada",
            handle: "@ada@first.example",
            body: "words",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            origins: [.publicTimeline],
            attachments: (0..<attachments).map { n in
                FediqoCore.Attachment(
                    kind: .image,
                    previewURL: URL(string: "https://first.example/\(id)-\(n).jpg")
                )
            },
            spoiler: spoiler
        ))
    }

    private static let list = [item("a", attachments: 3), item("b", spoiler: "Blood"), item("c")]

    @Test("Where a press lands, in all five cases")
    func whereAPressLands() {
        #expect(DummyCommand.focused(in: [], selected: nil) == .nothing)
        // An empty list stays empty however sure the selection is that it is on something.
        #expect(DummyCommand.focused(in: [], selected: "a") == .nothing)
        // Nothing focused: the press puts the reader on the first row, the way `j` does, and
        // stops there rather than acting on a post they have not seen yet.
        #expect(DummyCommand.focused(in: Self.list, selected: nil) == .first("a"))
        // A selection the last refresh took away is no selection at all.
        #expect(DummyCommand.focused(in: Self.list, selected: "gone") == .first("a"))
        #expect(DummyCommand.focused(in: Self.list, selected: "b") == .post(Self.list[1]))
    }

    /// The view's own switch, so that what is asserted below is the behaviour a reader gets
    /// rather than a rearrangement of it. `m` and `s` differ only in what they do once they have
    /// a post; everything before that is shared, which is why it is one function there and here.
    ///
    /// **`s` reads `DummyCommand.reveal` rather than re-deciding**, which is the whole point of
    /// that function existing. This harness used to spell the cover rule out for itself — `guard
    /// item.covered` — and the moment `s` grew a second job that copy would have been a test
    /// asserting the old behaviour while the app did something else. Convention one: a test must
    /// not be free to describe a smaller world than the code.
    ///
    /// `repliesWanted` is a parameter because the replies are a fact about the forum cache and an
    /// open pane, neither of which this suite has. `FediqoRootView.repliesWanted(of:)` is what
    /// answers it in the app, and `ThreadReadingTests` is where the answer is pinned.
    private func press(
        _ command: DummyCommand,
        items: [DummyItem],
        selected: inout String?,
        decks: inout ShellDecks,
        repliesWanted: Bool = false
    ) -> Bool {
        switch DummyCommand.focused(in: items, selected: selected) {
        case .nothing:
            return false
        case .first(let id):
            selected = id
            return true
        case .post(let item):
            switch command {
            case .nextAttachment:
                return decks.turn(item.id, of: item.attachments.count)
            case .reveal:
                switch DummyCommand.reveal(
                    hasCover: item.covered, repliesWanted: repliesWanted
                ) {
                case .cover: return decks.toggleCover(item.id)
                // Standing in for the fetch the app starts. What is asserted here is which of the
                // three this press chose, not what the cache did with it.
                case .replies: return true
                case .nothing: return false
                }
            default:
                return false
            }
        }
    }

    @Test("m turns the focused row's deck and leaves every other row where it was")
    func turningTheFocusedRow() {
        var selected: String? = "a"
        var decks = ShellDecks()
        #expect(press(.nextAttachment, items: Self.list, selected: &selected, decks: &decks))
        #expect(decks.top(of: "a", of: 3) == 1)
        #expect(decks.top(of: "b", of: 1) == 0)
        #expect(selected == "a")
    }

    @Test("m on a post with nothing to turn does nothing")
    func turningWhatCannotTurn() {
        var selected: String? = "c"
        var decks = ShellDecks()
        #expect(!press(.nextAttachment, items: Self.list, selected: &selected, decks: &decks))
        #expect(decks.top(of: "c", of: 0) == 0)
    }

    @Test("s uncovers the focused row, and covers it again")
    func coveringTheFocusedRow() {
        var selected: String? = "b"
        var decks = ShellDecks()
        #expect(press(.reveal, items: Self.list, selected: &selected, decks: &decks))
        #expect(decks.isLifted("b"))
        #expect(press(.reveal, items: Self.list, selected: &selected, decks: &decks))
        #expect(!decks.isLifted("b"))
    }

    @Test("s on a row nobody covered, with nothing to load, does nothing")
    func coveringWhatIsNotCovered() {
        var selected: String? = "c"
        var decks = ShellDecks()
        #expect(!press(.reveal, items: Self.list, selected: &selected, decks: &decks))
        #expect(!decks.isLifted("c"))
    }

    /// **Both directions of `s`'s one rule, and the order between them.**
    ///
    /// The reader asked for `s` to load the replies. It already meant "lift the author's cover",
    /// so the whole of the risk is that the second job eats the first — and the whole of the
    /// answer is that the cover wins where there is one. Row `b` is covered and row `c` is not;
    /// the same press on the two of them does two different things, and neither of them is new
    /// behaviour for the row it lands on.
    @Test("The cover wins where there is one, and the replies where there is not")
    func theCoverWinsAndThenTheRepliesDo() {
        // Uncovered, with a topic behind it: the press acts, and takes nothing off any cover.
        var selected: String? = "c"
        var decks = ShellDecks()
        #expect(press(.reveal, items: Self.list, selected: &selected,
                      decks: &decks, repliesWanted: true))
        #expect(!decks.isLifted("c"))

        // Covered, with a topic behind it: the cover, and **not** a page fetched behind a blur
        // the reader has not lifted.
        selected = "b"
        decks = ShellDecks()
        #expect(press(.reveal, items: Self.list, selected: &selected,
                      decks: &decks, repliesWanted: true))
        #expect(decks.isLifted("b"), "the replies took a press that belonged to the cover")

        // And it degrades honestly: lifted, `s` is still the cover — because a lifted cover is
        // still a cover, and `s` is how it goes back.
        #expect(press(.reveal, items: Self.list, selected: &selected,
                      decks: &decks, repliesWanted: true))
        #expect(!decks.isLifted("b"))
    }

    /// The rule itself, over all four combinations of the two facts it reads. No case is left to
    /// be inferred from the three above.
    @Test("What one press of s means, in all four cases")
    func whatAPressOfSMeans() {
        #expect(DummyCommand.reveal(hasCover: true, repliesWanted: false) == .cover)
        #expect(DummyCommand.reveal(hasCover: true, repliesWanted: true) == .cover)
        #expect(DummyCommand.reveal(hasCover: false, repliesWanted: true) == .replies)
        #expect(DummyCommand.reveal(hasCover: false, repliesWanted: false) == .nothing)
        // Three answers and no fourth, enumerated rather than listed by hand — so a fourth thing
        // `s` could mean breaks this test as well as the build.
        #expect(Set(DummyReveal.allCases) == [.cover, .replies, .nothing])
    }

    // The first press of either key on a list nobody is on puts the reader on a row and stops.
    // Without it a reader's first press would do nothing and say nothing, which reads as broken.
    @Test("Either key with nothing focused focuses the first row instead")
    func aPressWithNothingFocused() {
        for command in [DummyCommand.nextAttachment, .reveal] {
            var selected: String?
            var decks = ShellDecks()
            #expect(press(command, items: Self.list, selected: &selected, decks: &decks))
            #expect(selected == "a")
            // And nothing else happened: focusing is the whole of that press.
            #expect(decks.top(of: "a", of: 3) == 0)
            #expect(!decks.isLifted("a"))
        }
    }

    @Test("Either key on an empty timeline does nothing at all")
    func aPressOnAnEmptyList() {
        for command in [DummyCommand.nextAttachment, .reveal] {
            var selected: String?
            var decks = ShellDecks()
            #expect(!press(command, items: [], selected: &selected, decks: &decks))
            #expect(selected == nil)
        }
    }
}
