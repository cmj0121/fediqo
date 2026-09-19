import Foundation
import FediqoCore
import Testing
@testable import FediqoUI

/// The layer order, and what `v`, `a`, `m` and `s` do once the viewer is open.
///
/// The rules that have cases in them are pure and are asserted directly. The view is the glue
/// between them; what that glue does is asserted by `Shell`, below, which is the root's own switch
/// rearranged into something a test can hold — the same composition `PressTests` uses for `m` and
/// `s` in the row.
@Suite("Opening what is attached")
struct ViewerTests {
    // MARK: The layer order

    @Test("The order is viewer, shortcuts, thread, search, selection")
    func theOrderIsTheOrder() {
        #expect(DummyLayer.allCases == [.viewer, .shortcuts, .thread, .search, .selection])
    }

    @Test("A dismissing press closes the outermost thing that is open, and only that")
    func theOutermostAndOnlyThat() {
        #expect(DummyCommand.outermost(of: []) == nil)
        #expect(DummyCommand.outermost(of: [.selection]) == .selection)
        #expect(DummyCommand.outermost(of: [.thread, .selection]) == .thread)
        #expect(DummyCommand.outermost(of: [.shortcuts, .thread, .selection]) == .shortcuts)
        #expect(
            DummyCommand.outermost(of: [.viewer, .shortcuts, .thread, .selection]) == .viewer
        )
        // The viewer is outermost whatever else happens to be open under it — a viewer left
        // behind a popped thread is the failure the order exists to make unreachable.
        #expect(DummyCommand.outermost(of: [.viewer, .thread]) == .viewer)
        #expect(DummyCommand.outermost(of: [.viewer, .selection]) == .viewer)
    }

    // The dual of the close order, read out of the same list. A layer may open only if it would
    // then be the outermost one; otherwise the key yields, and it never closes what is above it
    // to make room for itself.
    @Test("A layer may open only if it would then be the outermost")
    func theEntryRule() {
        for layer in DummyLayer.allCases {
            #expect(DummyCommand.canOpen(layer, whenOpen: []))
        }
        // The viewer is outermost, so it may always open.
        #expect(DummyCommand.canOpen(.viewer, whenOpen: Set(DummyLayer.allCases)))
        // `?` under an open viewer does not open, and must not close the viewer to fit.
        #expect(!DummyCommand.canOpen(.shortcuts, whenOpen: [.viewer]))
        // A conversation does not open under either of the two above it.
        #expect(!DummyCommand.canOpen(.thread, whenOpen: [.viewer]))
        #expect(!DummyCommand.canOpen(.thread, whenOpen: [.shortcuts]))
        #expect(DummyCommand.canOpen(.thread, whenOpen: [.selection]))
        // Re-opening what is already open is still the outermost question, not a special case.
        #expect(DummyCommand.canOpen(.shortcuts, whenOpen: [.shortcuts, .thread]))
    }

    /// The two rules, over **every** set of open layers there is, against an order worked out
    /// independently of them.
    ///
    /// The cases above are the ones worth reading; this is the one that cannot be wrong about a
    /// combination nobody thought of. Every subset of the layers is the whole world, and it
    /// is enumerated from `allCases` rather than listed — so a fifth layer widens this test on
    /// the day it is added instead of leaving its new combinations unasserted.
    @Test("Both rules hold for every set of open layers")
    func theRulesOverTheWholeWorld() {
        let layers = DummyLayer.allCases
        // Independently of `outermost`: how far in a layer sits, read straight off the order.
        func depth(_ layer: DummyLayer) -> Int { layers.firstIndex(of: layer)! }

        for bits in 0 ..< (1 << layers.count) {
            let open = Set(layers.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element))
            #expect(DummyCommand.outermost(of: open) == open.min(by: { depth($0) < depth($1) }))
            for layer in layers {
                // A layer may open exactly when nothing already open sits in front of it.
                let nothingInFront = open.allSatisfy { depth($0) >= depth(layer) }
                #expect(DummyCommand.canOpen(layer, whenOpen: open) == nothingInFront)
            }
        }
    }

    @Test("? under an open viewer does nothing, and leaves the viewer alone")
    func theGuideDoesNotOpenUnderTheViewer() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.viewAttachment))
        #expect(!shell.press(.showShortcuts))
        #expect(!shell.shortcutsOpen)
        #expect(shell.viewing == Self.a)
    }

    @Test("Return under the guide does not open a conversation beneath it")
    func aThreadDoesNotOpenUnderTheGuide() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.showShortcuts))
        #expect(!shell.press(.expandPost))
        #expect(!shell.threadOpen)
    }

    @Test("Tab under the guide rotates the guide's tabs, not a conversation beneath it")
    func tabUnderTheGuideRotatesTheGuide() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.showShortcuts))
        #expect(shell.shortcutTab == .timeline)
        #expect(shell.press(.nextTab))
        #expect(shell.shortcutTab == .app)
        #expect(shell.press(.nextTab))
        #expect(shell.shortcutTab == .timeline)
        #expect(shell.press(.previousTab))
        #expect(shell.shortcutTab == .app)
        #expect(!shell.threadOpen)
    }

    // `q` used to intersect its own subset of the layers, which was the order written down a
    // second time. It reads the one list now, so it reaches past nothing.
    @Test("q leaves the outermost layer and reaches past nothing")
    func backReachesPastNothing() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.expandPost))
        #expect(shell.press(.showShortcuts))
        // The guide is in front, and `q` is not the key that closes it.
        #expect(!shell.press(.back))
        #expect(shell.threadOpen)
        #expect(shell.shortcutsOpen)
        // `Escape` is.
        #expect(shell.press(.dismiss))
        #expect(!shell.shortcutsOpen)
        #expect(shell.press(.back))
        #expect(!shell.threadOpen)
    }

    // MARK: The size a picture is opened at

    @Test("A picture is drawn at its own size and never larger")
    func drawnAtItsOwnSize() {
        let shape = FediqoCore.Attachment(kind: .image, url: Self.picture, width: 800, height: 600)
        #expect(AttachmentViewer.ceiling(for: shape, tier: .viewer, scale: 1)
            == CGSize(width: 800, height: 600))
        // On a 2x display its own size is half as many points as it has pixels, which is what
        // draws it one pixel to one pixel rather than one pixel to four.
        #expect(AttachmentViewer.ceiling(for: shape, tier: .viewer, scale: 2)
            == CGSize(width: 400, height: 300))
    }

    @Test("Never larger than the decode in hand either")
    func heldToTheDecode() {
        let huge = FediqoCore.Attachment(kind: .image, url: Self.picture, width: 6000, height: 3000)
        let ceiling = AttachmentViewer.ceiling(for: huge, tier: .viewer, scale: 1)
        // 2048 on the long edge is all there is, however large the file was.
        #expect(ceiling?.width == 2048)
        #expect(ceiling?.height == 1024)
    }

    @Test("A server that said nothing about the shape gets no ceiling")
    func nothingSaidIsNotASquare() {
        let unsaid = FediqoCore.Attachment(kind: .image, url: Self.picture)
        #expect(AttachmentViewer.ceiling(for: unsaid, tier: .viewer, scale: 2) == nil)
        let halfSaid = FediqoCore.Attachment(kind: .image, url: Self.picture, width: 800, height: 0)
        #expect(AttachmentViewer.ceiling(for: halfSaid, tier: .viewer, scale: 2) == nil)
    }

    // MARK: What the keys do with it open

    @Test("v opens what is on top, and a second v does not close it")
    func openingAndNotClosing() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.viewAttachment))
        #expect(shell.viewing == Self.a)
        // `Escape` and `q` are how this is left. One key that both opens and closes a layer is
        // the conditional rule the order is kept free of.
        #expect(!shell.press(.viewAttachment))
        #expect(shell.viewing == Self.a)
    }

    @Test("v on a row that brought nothing opens nothing")
    func nothingToOpen() {
        let shell = Shell(items: Self.list, selected: Self.c)
        #expect(!shell.press(.viewAttachment))
        #expect(shell.viewing == nil)
    }

    @Test("Escape and q both close the viewer before the thread under it")
    func leavingTheViewerFirst() {
        for command in [DummyCommand.dismiss, .back] {
            let shell = Shell(items: Self.list, selected: Self.a)
            shell.threadOpen = true
            #expect(shell.press(.viewAttachment))
            #expect(shell.press(command))
            #expect(shell.viewing == nil)
            #expect(shell.threadOpen)
            #expect(shell.press(command))
            #expect(!shell.threadOpen)
        }
    }

    @Test("m turns the same deck the row is turning, and stops what was playing")
    func turningWithTheViewerOpen() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.viewAttachment))
        #expect(shell.press(.playAttachment))
        #expect(shell.playing.here(Self.film, of: Self.a, on: .viewer) == Self.film)
        #expect(shell.press(.nextAttachment))
        #expect(shell.decks.top(of: Self.a, of: 3) == 1)
        // Sound out of a card the reader has just turned away from is a fault.
        #expect(shell.playing.url == nil)
        // And it turned the row's deck, not a copy of its own.
        #expect(shell.viewing == Self.a)
    }

    @Test("m in the row stops what the row was playing")
    func turningInTheRow() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.playAttachment))
        #expect(shell.playing.here(Self.film, of: Self.a, on: .row) == Self.film)
        #expect(shell.press(.nextAttachment))
        #expect(shell.playing.url == nil)
    }

    // Ward's ruling. Not "toggle, and also close if that leaves nothing to show" — a conditional
    // rule inside the layer order is the named risk.
    @Test("s with the viewer open blurs in place and never navigates")
    func coveringBlursInPlace() {
        let shell = Shell(items: Self.list, selected: Self.b)
        #expect(shell.press(.viewAttachment))
        #expect(shell.press(.reveal))
        #expect(shell.decks.isLifted(Self.b))
        #expect(shell.viewing == Self.b)
        // And another `s` puts it back, still without leaving.
        #expect(shell.press(.reveal))
        #expect(!shell.decks.isLifted(Self.b))
        #expect(shell.viewing == Self.b)
        // `Escape` still means leave.
        #expect(shell.press(.dismiss))
        #expect(shell.viewing == nil)
    }

    @Test("a plays in the row silently and in the viewer with everything")
    func theTwoStages() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.playAttachment))
        #expect(shell.playing.here(Self.film, of: Self.a, on: .row) == Self.film)
        #expect(shell.playing.here(Self.film, of: Self.a, on: .viewer) == nil)

        // Opening the viewer stops the row's: it would go on playing behind an opaque ground
        // where nobody can see it or stop it.
        #expect(shell.press(.viewAttachment))
        #expect(shell.playing.url == nil)

        #expect(shell.press(.playAttachment))
        #expect(shell.playing.here(Self.film, of: Self.a, on: .viewer) == Self.film)
        // And leaving stops it again.
        #expect(shell.press(.dismiss))
        #expect(shell.playing.url == nil)
    }

    // A row film was never stopped when the reader walked to another page: the old code stopped
    // playback only where the viewer had been open, and with a row playing it never was.
    @Test("Leaving the page stops a film playing in a row")
    func leavingThePageStopsTheRow() {
        let shell = Shell(items: Self.list, selected: Self.a)
        #expect(shell.press(.playAttachment))
        #expect(shell.playing.here(Self.film, of: Self.a, on: .row) == Self.film)
        shell.leavePlace()
        #expect(shell.playing.url == nil)
    }

    // The drawing half was already safe, but the id was not: with the post gone the viewer is not
    // a layer, so `Escape` resolves to something underneath and never reaches `closeViewer` — and
    // a refresh that brought the post back opened the viewer over the whole app with no press.
    @Test("A viewer whose post the refresh took away does not come back with it")
    func aVanishedViewerDoesNotReturn() {
        let after = Shell(items: [], selected: nil)
        after.viewing = "a"
        after.refresh()
        #expect(after.viewing == nil)
    }

    @Test("A press while the viewer names a post that is gone acts on what is really open")
    func aStaleViewerIsNotALayer() {
        let shell = Shell(items: Self.list, selected: Self.a)
        shell.viewing = "nobody"
        shell.threadOpen = true
        // `q` must give back the conversation, not pretend to close a viewer nobody can see.
        #expect(shell.press(.back))
        #expect(shell.viewing == nil)
        #expect(!shell.threadOpen)
    }

    @Test("Nothing plays under a cover")
    func nothingPlaysUnderACover() {
        let shell = Shell(items: Self.list, selected: Self.b)
        #expect(!shell.press(.playAttachment))
        #expect(shell.playing.url == nil)
        // Lifted, it plays.
        #expect(shell.press(.reveal))
        #expect(shell.press(.playAttachment))
        #expect(shell.playing.here(Self.film, of: Self.b, on: .row) == Self.film)
    }

    @Test("a on a picture does nothing at all")
    func aPictureDoesNotPlay() {
        let shell = Shell(items: Self.list, selected: Self.d)
        #expect(!shell.press(.playAttachment))
        #expect(shell.playing.url == nil)
    }

    // MARK: Magnifying

    // "Never enlarged unasked; the reader may enlarge it" — an amendment to decision 1, which
    // ruled on how a picture is sized and was silent about gesture.
    @Test("A pinch settles at the honest size, and snaps to it")
    func aPinchSettles() {
        #expect(AttachmentViewer.settled(1) == 1)
        // The floor is the size the viewer chose. There is nothing below it to reach.
        #expect(AttachmentViewer.settled(0.4) == 1)
        // Near enough is the same as there: the honest size is findable by feel.
        #expect(AttachmentViewer.settled(1.03) == 1)
        #expect(AttachmentViewer.settled(0.97) == 1)
        // Past the detent it is what the reader asked for.
        #expect(AttachmentViewer.settled(2.5) == 2.5)
        // And there is a ceiling, past which a photograph is pixels with edges.
        #expect(AttachmentViewer.settled(50) == 6)
    }

    // MARK: The words under the picture

    // The caption is a stranger's line like any other, so the shortcodes in it are drawn as
    // pictures. `EmojiText` needs the post's own list to do that, and the list reaches the viewer
    // through the item — which is the half a test can hold and the half that would go silently
    // missing, because an alt text with no emoji in it looks identical either way.
    @Test("The post's emoji reach the item the viewer draws its caption from")
    func theCaptionHasSomethingToDrawWith() {
        let blobcat = CustomEmoji(shortcode: "blobcat", url: Self.picture)
        let note = Note(
            id: "e",
            source: Source(host: "first.example", kind: .mastodon),
            author: "Ada",
            handle: "@ada@first.example",
            body: "words",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [.public],
            attachments: [FediqoCore.Attachment(
                kind: .image,
                previewURL: Self.picture,
                alt: "a cat :blobcat: asleep"
            )],
            emojis: [blobcat]
        )
        let item = DummyItem(note)
        #expect(item.emojis.map(\.shortcode) == ["blobcat"])
        // And the shortcode is still in the words, so there is something for the list to name.
        #expect(item.attachments.first?.alt.contains(":blobcat:") == true)
    }

    // MARK: The fixtures, and the glue

    private static let film = URL(string: "https://first.example/a-0.mp4")!
    private static let picture = URL(string: "https://first.example/p.jpg")!

    private static func item(
        _ id: String,
        attachments: [FediqoCore.Attachment] = [],
        spoiler: String? = nil
    ) -> DummyItem {
        DummyItem(Note(
            id: id,
            source: Source(host: "first.example", kind: .mastodon),
            author: "Ada",
            handle: "@ada@first.example",
            body: "words",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [.public],
            attachments: attachments,
            spoiler: spoiler
        ))
    }

    private static func filmed(_ name: String) -> FediqoCore.Attachment {
        FediqoCore.Attachment(
            kind: .video,
            url: URL(string: "https://first.example/\(name).mp4"),
            previewURL: URL(string: "https://first.example/\(name).jpg")
        )
    }

    private static let list = [
        item("a", attachments: [filmed("a-0"), filmed("a-1"), filmed("a-2")]),
        item("b", attachments: [filmed("a-0")], spoiler: "Blood"),
        item("c"),
        item("d", attachments: [
            FediqoCore.Attachment(kind: .image, previewURL: picture),
        ]),
    ]
    private static let a = NoteKey(host: "first.example", id: "a").rowID
    private static let b = NoteKey(host: "first.example", id: "b").rowID
    private static let c = NoteKey(host: "first.example", id: "c").rowID
    private static let d = NoteKey(host: "first.example", id: "d").rowID

    /// The root's own switch, rearranged into something a test can hold.
    ///
    /// The rules with cases in them — `DummyCommand.focused`, `DummyCommand.outermost`,
    /// `DummyCommand.canOpen`, `ShellDecks`, `ShellPlaying` — are the real thing and are asserted
    /// on their own above. What is composed here is only the order they are asked in, which is
    /// what a reader actually gets and the one part a view cannot be asked about from an SPM
    /// target.
    ///
    /// **It enumerates `DummyLayer.allCases` and never hand-lists a subset.** The first version
    /// of this harness kept its own set of layers and left `.shortcuts` out of it, so the harness
    /// described a smaller world than the code and the guide's place in the order went untested.
    /// An exhaustive `switch` in `isOpen` is what makes that unconstructable: a layer added later
    /// stops this compiling until it is answered here.
    private final class Shell {
        let items: [DummyItem]
        var selected: String?
        var viewing: String?
        var threadOpen = false
        var shortcutsOpen = false
        var searchOpen = false
        var shortcutTab = DummyShortcutGroup.timeline
        var decks = ShellDecks()
        var playing = ShellPlaying()

        init(items: [DummyItem], selected: String?) {
            self.items = items
            self.selected = selected
        }

        var viewedItem: DummyItem? {
            guard let viewing else { return nil }
            return items.first { $0.id == viewing }
        }

        private func isOpen(_ layer: DummyLayer) -> Bool {
            switch layer {
            case .viewer: viewedItem != nil
            case .shortcuts: shortcutsOpen
            case .thread: threadOpen
            case .search: searchOpen
            case .selection: selected != nil
            }
        }

        var openLayers: Set<DummyLayer> {
            Set(DummyLayer.allCases.filter(isOpen))
        }

        /// What the app does when the reader walks to another page.
        func leavePlace() {
            _ = closeViewer()
            playing.stop()
        }

        /// What a refresh does, when it brings back a list without the post the viewer was on.
        func refresh() {
            if viewing != nil, viewedItem == nil { _ = closeViewer() }
        }

        func press(_ command: DummyCommand) -> Bool {
            if viewing != nil, viewedItem == nil { _ = closeViewer() }
            switch command {
            case .viewAttachment:
                guard viewedItem == nil,
                      DummyCommand.canOpen(.viewer, whenOpen: openLayers) else { return false }
                return onFocusedItem { item in
                    guard decks.showing(item.attachments, of: item.id) != nil else { return false }
                    playing.stop()
                    viewing = item.id
                    return true
                }
            case .playAttachment:
                let stage: ShellPlaying.Stage = viewedItem == nil ? .row : .viewer
                return onActedItem { item in
                    guard !(item.covered && !decks.isLifted(item.id)) else { return false }
                    let file = ShellPlaying.playable(decks.showing(item.attachments, of: item.id))
                    return playing.toggle(file, of: item.id, on: stage)
                }
            case .nextAttachment:
                return onActedItem { item in
                    let turned = decks.turn(item.id, of: item.attachments.count)
                    guard turned else { return false }
                    playing.stop()
                    return true
                }
            case .reveal:
                return onActedItem { item in
                    guard item.covered else { return false }
                    return decks.toggleCover(item.id)
                }
            case .expandPost:
                guard selected != nil,
                      DummyCommand.canOpen(.thread, whenOpen: openLayers) else { return false }
                threadOpen = true
                return true
            case .showShortcuts:
                if shortcutsOpen {
                    shortcutsOpen = false
                    return true
                }
                guard DummyCommand.canOpen(.shortcuts, whenOpen: openLayers) else { return false }
                shortcutsOpen = true
                return true
            case .nextTab, .previousTab:
                guard DummyCommand.outermost(of: openLayers) == .shortcuts else { return false }
                shortcutTab = DummyShortcutGroup.rotated(
                    from: shortcutTab,
                    by: command == .nextTab ? 1 : -1
                )
                return true
            case .back, .dismiss:
                switch DummyCommand.outermost(of: openLayers) {
                case .viewer: return closeViewer()
                case .shortcuts:
                    guard command == .dismiss else { return false }
                    shortcutsOpen = false
                    return true
                case .thread: threadOpen = false; return true
                case .search:
                    guard command == .dismiss else { return false }
                    searchOpen = false
                    return true
                case .selection:
                    guard command == .dismiss else { return false }
                    selected = nil
                    return true
                case nil: return false
                }
            default:
                return false
            }
        }

        @discardableResult
        private func closeViewer() -> Bool {
            guard viewing != nil else { return false }
            let wasOpen = viewedItem != nil
            viewing = nil
            playing.stop()
            return wasOpen
        }

        private func onActedItem(_ act: (DummyItem) -> Bool) -> Bool {
            guard let item = viewedItem else { return onFocusedItem(act) }
            return act(item)
        }

        private func onFocusedItem(_ act: (DummyItem) -> Bool) -> Bool {
            switch DummyCommand.focused(in: items, selected: selected) {
            case .nothing: return false
            case .first(let id):
                guard DummyCommand.canOpen(.selection, whenOpen: openLayers) else { return false }
                selected = id
                return true
            case .post(let item): return act(item)
            }
        }
    }
}

/// Which card the row, the viewer and the key that plays it all agree is on top.
@Suite("Which card is on top")
struct DeckShowingTests {
    private static func picture(_ name: String) -> FediqoCore.Attachment {
        FediqoCore.Attachment(
            kind: .image,
            previewURL: URL(string: "https://first.example/\(name).jpg")
        )
    }

    @Test("It is the one the deck is turned to, and it follows m")
    func showingFollowsTheTurn() {
        var decks = ShellDecks()
        let three = [Self.picture("0"), Self.picture("1"), Self.picture("2")]
        #expect(decks.showing(three, of: "a") == three[0])
        let turned = decks.turn("a", of: 3)
        #expect(turned)
        #expect(decks.showing(three, of: "a") == three[1])
    }

    @Test("A row that brought nothing is showing nothing")
    func nothingIsShowing() {
        let decks = ShellDecks()
        #expect(decks.showing([], of: "a") == nil)
    }

    // A refresh can bring back the same post carrying fewer things than it did, and a position
    // remembered from the longer version would point past the end of the shorter one.
    @Test("A deck turned past the end of a shorter list folds rather than traps")
    func showingFoldsByTheCount() {
        var decks = ShellDecks()
        let once = decks.turn("a", of: 3)
        #expect(once)
        let twice = decks.turn("a", of: 3)
        #expect(twice)
        let one = [Self.picture("0")]
        #expect(decks.showing(one, of: "a") == one[0])
    }
}
