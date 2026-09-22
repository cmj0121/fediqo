import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #169: on a Mac, a page read out of a post takes the place of the page it was opened from, as
/// one more step of the walk, and leaving it unwinds the walk in the order the reader walked.
///
/// What this holds without a screen: where a reading opens (in place or in a sheet), the walk it
/// becomes a step of, what the page underneath is handed while it is open, and the order the
/// keys read. The page itself is a web view and is not drawn here — building one would load a
/// stranger's address from a test — so how it looks, and that Back and Escape reach it from
/// inside the page, are for a running Mac.
///
/// `@MainActor` on the suite, for the reason `LinkTests` gives at length.
@MainActor
@Suite("A link read in place of the page it was opened from")
struct LinkInPlaceTests {
    private let address = URL(string: "https://example.test/a")!

    /// What the root holds and hands `FediqoRootView.placeLink`: the walk, the lamp, the place
    /// and the layers open. The answer is the root's own rule, not a copy of it.
    private final class Root {
        var walk = ShellWalk()
        var lamp: String?
        var place = ShellPlace.timeline
        var open: Set<DummyLayer> = []

        func place(_ url: URL) -> Bool {
            FediqoRootView.placeLink(url, on: &walk, from: lamp, place: place, open: open)
        }
    }

    /// One step back, as `FediqoRootView.leaveWalk` takes it.
    private func back(_ root: Root) -> (step: ShellStep, lamp: String?)? {
        root.walk.back()
    }

    private func reader(for root: Root) -> ShellReader {
        let reader = ShellReader()
        reader.placing = { url in root.place(url) }
        return reader
    }

    // MARK: Where it opens

    @Test("On a Mac a link is a step of the walk, and no sheet is presented for it")
    func aLinkIsAStep() throws {
        let root = Root()
        root.lamp = "d"
        let reader = reader(for: root)
        #expect(reader.open(address))
        #expect(reader.inPlace)
        #expect(reader.sheet == nil, "the sheet would be a second copy of the page, floating over it")
        #expect(try #require(reader.reading).host == "example.test")
        #expect(root.walk.openedLink == address)
    }

    @Test("Where no step can be taken it is the sheet, as on iPad and iPhone")
    func elsewhereItIsTheSheet() throws {
        // Under the viewer: nothing walks there.
        let root = Root()
        root.open = [.viewer, .selection]
        let under = reader(for: root)
        #expect(under.open(address))
        #expect(!under.inPlace)
        #expect(try #require(under.sheet).url == address)
        #expect(root.walk.isEmpty)

        // Pressed on another place's page — a preview on the sources page — where there is no
        // walk to take a step in.
        let elsewhere = Root()
        elsewhere.place = .account
        let account = reader(for: elsewhere)
        #expect(account.open(address))
        #expect(!account.inPlace)
        #expect(elsewhere.walk.isEmpty)

        // Nobody answering where it goes — iPad and iPhone, or a preview.
        let tablet = ShellReader()
        #expect(tablet.open(address))
        #expect(!tablet.inPlace)
        #expect(tablet.sheet?.url == address)
    }

    @Test("A refused address takes no step and opens nothing")
    func aRefusedAddressTakesNoStep() {
        let root = Root()
        let reader = reader(for: root)
        #expect(!reader.open(URL(string: "http://example.test/a")!))
        #expect(root.walk.isEmpty)
        #expect(reader.reading == nil)
        #expect(!reader.inPlace)
    }

    @Test("Closing it leaves nothing in place and nothing for a sheet")
    func closingLeavesNothing() {
        let root = Root()
        let reader = reader(for: root)
        reader.open(address)
        reader.close()
        #expect(reader.reading == nil)
        #expect(!reader.inPlace)
        #expect(reader.sheet == nil)
    }

    // MARK: The walk

    /// The issue's own order: timeline → conversation → link → back to the conversation → back
    /// to the timeline, each on the post it was left on.
    @Test("Leaving unwinds in the order walked, each step on the post it was left on")
    func leavingUnwindsInOrder() throws {
        let root = Root()
        root.lamp = "d"
        let walked = root.walk.walk(to: .thread("a"), from: root.lamp)
        #expect(walked)
        // Inside the conversation the reader walks to its third post, then presses a link in it.
        root.lamp = "c"
        let reader = reader(for: root)
        #expect(reader.open(address))
        #expect(root.walk.depth == 2)

        let link = try #require(back(root))
        #expect(link.step == .link(address))
        #expect(link.lamp == "c", "back on the post the link was pressed on")
        #expect(root.walk.standing == .thread("a"))
        let thread = try #require(back(root))
        #expect(thread.lamp == "d", "and the timeline on the post the conversation was opened from")
        #expect(root.walk.isEmpty)
    }

    @Test("Opened from somebody's page, leaving returns there")
    func fromAPersonsPage() throws {
        let root = Root()
        let note = Note(
            id: "n1", source: Source(host: "m.example", kind: .mastodon), author: "Ada",
            handle: "@ada@m.example", body: "hello", postedAt: Date(timeIntervalSince1970: 0),
            categories: [.public]
        )
        let ada = try #require(DummyPerson(DummyItem(note)))
        let walked = root.walk.walk(to: .person(ada), from: "b")
        #expect(walked)
        root.lamp = "p2"
        #expect(reader(for: root).open(address))
        let left = try #require(back(root))
        #expect(left.lamp == "p2")
        #expect(root.walk.standing == .person(ada))
    }

    /// **The page under the link is not rebuilt.** What the timeline place is handed to draw is
    /// the step beneath the link, and it is the same value before the link opens, while it is open
    /// and after it has gone — so SwiftUI has nothing to tear down or build again, and the list,
    /// its scroll and its lamp are the ones the reader left.
    @Test("What the page underneath draws is the same before, during and after the link")
    func thePageBeneathIsUnchanged() {
        for start in [ShellStep?.none, .thread("a")] {
            let root = Root()
            if let start { _ = root.walk.walk(to: start, from: "d") }
            let before = root.walk.beneath
            #expect(before == start)
            #expect(reader(for: root).open(address))
            #expect(root.walk.standing == .link(address))
            #expect(root.walk.beneath == before)
            _ = root.walk.back()
            #expect(root.walk.beneath == before)
            #expect(root.walk.standing == start)
        }
    }

    @Test("A second press of the same address is not a second step")
    func theSameAddressTwice() {
        let root = Root()
        let reader = reader(for: root)
        #expect(reader.open(address))
        #expect(reader.open(address))
        #expect(reader.inPlace)
        #expect(root.walk.depth == 1)
    }

    // MARK: The order the keys read

    @Test("Escape and q leave the link before anything under it")
    func escapeLeavesTheLinkFirst() {
        #expect(DummyCommand.outermost(of: [.link, .search, .selection]) == .link)
        #expect(DummyCommand.walk.contains(.link))
        // Nothing opens under the viewer or the keys list, a link included.
        #expect(!DummyCommand.canWalk(whenOpen: [.viewer]))
        #expect(!DummyCommand.canWalk(whenOpen: [.shortcuts]))
        // From the stream, a search's results, a conversation or a page, it may.
        for open: Set<DummyLayer> in [[], [.selection], [.search, .selection], [.thread, .selection], [.person]] {
            #expect(DummyCommand.canWalk(whenOpen: open))
        }
        // `e` edits no timeline from inside somebody's page.
        #expect(!DummyCommand.canEditTimeline(whenOpen: [.link, .selection]))
    }
}
