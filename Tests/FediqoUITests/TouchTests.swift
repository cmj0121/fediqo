import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #33 — what the keys do on a timeline, done by touch.
///
/// What a test can reach: the written-down list itself, the four rules the new controls read —
/// what a press on a row means, whether the search may open, whether there is anything to reload,
/// and whether a conversation may open — and the surfaces' own shapes, which is what
/// `everySurfaceStillTakesItsPress` is for. What it cannot: the presses. Every mark added here
/// lives in a `View` body, and this package cannot execute one, so "the mark is drawn where this
/// says it is" is named in the report rather than claimed here.
///
/// **The suite is `@MainActor`, and the whole suite rather than the tests inside it.**
/// `FediqoRootView`'s statics belong to a `View`, which is isolated to the main actor. The Swift
/// on this machine allows a synchronous test to reach them; the Swift CI runs refuses it as a
/// build error and the whole bundle stops compiling. Annotating each test instead compiles and
/// then kills the bundle with signal 5 as it starts. `WaitingTests` and `LinkTests` both say so.
@Suite("What the keys do, done by touch")
@MainActor
struct TouchTests {
    private static func line(_ name: String) -> DummyShortcut {
        DummyShortcut.all.first { $0.name == name }!
    }

    // MARK: - The list is the promise

    /// **This is #33's acceptance line, executable.** Every key the guide names outside its App
    /// tab has a way in that needs no keyboard — and because `touch` is not optional, another
    /// key cannot be added to the list without answering the question. A key that genuinely has
    /// no touch path, or only part of one, would have to write `.keysOnly` or `.partly` here,
    /// either of which fails this test rather than passing quietly. Since #152 this reaches the
    /// two lines the old Every-tab group held that a finger does reach, `⌃Tab` and `c`.
    @Test("Every key the guide names outside App can be done without one")
    func everyTimelineKeyHasATouchPath() {
        let timeline = DummyShortcut.all.filter { $0.group != .app }
        #expect(timeline.count == 21)
        let short = timeline.filter { $0.touch == .keysOnly || $0.touch == .partly }.map(\.name)
        #expect(short.isEmpty, "no touch path for: \(short.joined(separator: ", "))")
    }

    /// The answers themselves, line by line, so that changing one is a change to this file too.
    /// A mark quietly dropped from a surface leaves this test passing — that is what the report
    /// says it cannot do — but a mark dropped *and* the list left claiming it is the drift this
    /// catches at review.
    @Test("Each timeline key names the way a finger reaches it")
    func eachTimelineKeyNamesItsTouchPath() {
        #expect(Self.line("tabs").touch == .press)
        #expect(Self.line("posts").touch == .press)
        // The list under a thumb. No mark of ours, and none wanted — see the line's own note.
        #expect(Self.line("top").touch == .scroll)
        #expect(Self.line("expand").touch == .pressAgain)
        #expect(Self.line("view").touch == .press)
        #expect(Self.line("play").touch == .press)
        #expect(Self.line("turn").touch == .press)
        #expect(Self.line("reveal").touch == .press)
        #expect(Self.line("back").touch == .press)
        // A tab held, or double-clicked. The one secondary press among the sixteen.
        #expect(Self.line("edit").touch == .hold)
        #expect(Self.line("search").touch == .press)
        #expect(Self.line("reload").touch == .press)
        // The boost mark under the post (#106). Absent where the post cannot be boosted, and the
        // key is refused there too, so there is no half of it a finger cannot reach.
        #expect(Self.line("boost").touch == .press)
        // The star under the post (#107), for the boost's reason.
        #expect(Self.line("favourite").touch == .press)
        // The answer mark (#108): inside a conversation it opens the answer, and on the timeline
        // it opens the conversation first, which is where the key is answered too.
        #expect(Self.line("answer").touch == .press)
        // Taking back (#109): the mark on the reader's own posts, which asks before anything goes.
        #expect(Self.line("withdraw").touch == .press)
        // Whoever wrote it (#140): the face or the name at the head of the row, pressed (#99).
        #expect(Self.line("person").touch == .press)
        #expect(Self.line("tag").touch == .press)
    }

    /// The other tab, recorded rather than wished for: two of its five keys are a keyboard's
    /// alone, and a third is one in part. #33 asks for the timeline, and this says in one place
    /// what it did not ask for.
    ///
    /// `Escape` is the partial one and is the reason `.partly` exists. Everything it closes has a
    /// control of its own, and the two things it does that none of them do — stopping a running
    /// reload, putting the lamp out — have no touch path at all, so `.press` was this list
    /// claiming a way in that is drawn nowhere.
    @Test("Two of the app's own keys stay a keyboard's, one is partly, and the list says which")
    func theAppTabSaysWhatIsStillKeysOnly() {
        let keysOnly = DummyShortcut.lines(in: .app).filter { $0.touch == .keysOnly }.map(\.name)
        #expect(keysOnly == ["list", "landing"])
        #expect(Self.line("dismiss").touch == .partly)
        let partly = DummyShortcut.all.filter { $0.touch == .partly }.map(\.name)
        #expect(partly == ["dismiss"])
    }

    /// The sentence each new mark wears is the sentence the guide explains its key with — one
    /// string, so the press and the written-down key cannot come to describe themselves
    /// differently. A missing key would come back as its own name.
    @Test("The marks say what the keys list says")
    func theMarksSayWhatTheKeysListSays() {
        for name in ["search", "reload", "view", "turn", "expand"] {
            let key = "shortcut.\(name)"
            #expect(L10n.t(key) != key, "\(key) is not in the strings")
            #expect(Self.line(name).detail == L10n.t(key))
        }
    }

    // MARK: - A press on a row

    /// The keyboard says this in two keys and a finger has one press.
    @Test("A press lights a row; a press on the row already lit opens it")
    func aPressOnTheRowAlreadyLitOpensIt() {
        #expect(DummyCommand.tapped("a", selected: nil) == .select)
        #expect(DummyCommand.tapped("a", selected: "b") == .select)
        #expect(DummyCommand.tapped("a", selected: "a") == .open)
    }

    /// The rule that press now reads, which is `Return`'s own. A press on a row carries the post
    /// it means and the root lights it and opens it together — so this is what stands between a
    /// press and a conversation, and it is the same function `Return` is refused by.
    @Test("A press opens a conversation exactly where Return would")
    func aPressOpensAThreadWhereReturnWould() {
        func can(_ place: ShellPlace = .timeline, open: Set<DummyLayer> = []) -> Bool {
            FediqoRootView.canWalk(place: place, open: open)
        }
        #expect(can(open: [.selection]))
        // A reply inside an open thread opens its own conversation: one more step of the walk.
        #expect(can(open: [.thread, .selection]))
        // And so does a row on somebody's page, which is #122 — the walk is one stack, so a
        // conversation is no longer refused by the step the reader took before it.
        #expect(can(open: [.person, .selection]))
        // A result found on this device can be opened, which is what puts search under thread.
        #expect(can(open: [.search]))
        // Nothing opens *under* the picture or the keys list.
        #expect(!can(open: [.viewer]))
        #expect(!can(open: [.shortcuts]))
        #expect(!can(.account))
    }

    // MARK: - The two marks in the header

    /// The same rule `/` reads, which is the whole point of it being a function: under a thread,
    /// the viewer or the keys list there is no search to open, so no mark is drawn.
    @Test("The search mark is there exactly where / would open one")
    func theSearchMarkIsThereWhereSlashWouldOpen() {
        #expect(FediqoRootView.canSearch(place: .timeline, open: []))
        #expect(FediqoRootView.canSearch(place: .timeline, open: [.selection]))
        // A search already open is still searchable: a second `/` hands the field the keys again.
        #expect(FediqoRootView.canSearch(place: .timeline, open: [.search, .selection]))
        #expect(!FediqoRootView.canSearch(place: .timeline, open: [.thread]))
        #expect(!FediqoRootView.canSearch(place: .timeline, open: [.viewer]))
        #expect(!FediqoRootView.canSearch(place: .timeline, open: [.shortcuts]))
        // Another page is not the timeline, whatever is open on it.
        #expect(!FediqoRootView.canSearch(place: .account, open: []))
    }

    /// The same rule `r` reads. An open thread is the one layer a reload still works under —
    /// that is `r`'s own arrangement, and it is what makes one mark cover both the timeline and
    /// the open thread.
    @Test("The reload mark is there exactly where r would ask for something")
    func theReloadMarkIsThereWhereRWouldAsk() {
        func can(_ place: ShellPlace = .timeline,
                 editing: Bool = false,
                 sources: Bool = true,
                 open: Set<DummyLayer> = []) -> Bool {
            FediqoRootView.canReload(place: place, editing: editing, hasSources: sources, open: open)
        }
        #expect(can())
        #expect(can(open: [.selection]))
        // The open thread, which is what `r` reloads when there is one.
        #expect(can(open: [.thread, .selection]))
        // Nobody to ask.
        #expect(!can(sources: false))
        // The editor owns the keys, and a reload under it is stopped rather than started.
        #expect(can(editing: true) == false)
        // A search's results are what this device holds, found without asking anybody.
        #expect(!can(open: [.search]))
        #expect(!can(open: [.viewer]))
        #expect(!can(open: [.shortcuts]))
        #expect(!can(.usage))
    }

    /// Every layer is answered, so a sixth one cannot be waved through by a `default:` that is
    /// not there. The two functions are asked about each layer standing alone, which is the only
    /// arrangement in which each one is the outermost.
    @Test("Both marks answer for every layer there is")
    func bothMarksAnswerForEveryLayer() {
        for layer in DummyLayer.allCases {
            let searchable = FediqoRootView.canSearch(place: .timeline, open: [layer])
            let reloadable = FediqoRootView.canReload(
                place: .timeline, editing: false, hasSources: true, open: [layer]
            )
            switch layer {
            case .selection:
                #expect(searchable)
                #expect(reloadable)
            case .search:
                #expect(searchable)
                #expect(!reloadable)
            case .thread:
                #expect(!searchable)
                #expect(reloadable)
            // Somebody's page is what this device already holds of theirs, so neither mark has
            // anything to do there — the search is under it in the order, and a reload that went
            // and asked their server for more would be 0.5.0 arriving through `r` (#99).
            case .person:
                #expect(!searchable)
                #expect(!reloadable)
            // A tag's page asks for itself as it opens, with its own way to ask again (#124).
            case .tag:
                #expect(!searchable)
                #expect(!reloadable)
            // A page read out of a post is somebody else's page: the search is under it, and it
            // holds nothing of this device's to ask for (#169).
            case .link:
                #expect(!searchable)
                #expect(!reloadable)
            case .viewer, .shortcuts:
                #expect(!searchable)
                #expect(!reloadable)
            }
        }
    }

    // MARK: - The surfaces the marks are on

    /// **The one check here that a control going missing can fail.** Everything above this line
    /// reads the written-down list or a rule beside it, and none of it notices a mark deleted
    /// from a `View` body — which is #33's only real failure mode, and was being counted as
    /// acceptance.
    ///
    /// This does not prove a mark is drawn: a body is still not something this package can
    /// execute. What it does is make each surface's way in part of a type — the callback exists,
    /// it is spelled this way, and it takes what a press has to hand it. Delete the entry point
    /// and this file stops compiling, which is a build error instead of a string comparison that
    /// goes on passing.
    @Test("Every surface #33 put a way in on still takes one")
    func everySurfaceStillTakesItsPress() {
        let deck = [Attachment(kind: .image), Attachment(kind: .image)]
        // The card is `v`, the counter is `m`, the mark on it is `a`.
        _ = AttachmentDeck(
            attachments: deck, top: 0, side: 96, host: Self.host,
            onPlay: {}, onOpen: {}, onTurn: {}
        )
        // Inside the viewer, the counter under the picture is the only way to `m`.
        _ = AttachmentViewer(
            attachments: deck, top: 0, covered: false, hasCover: false, coverLine: nil,
            emojis: [], host: Self.host, player: nil,
            onToggleCover: {}, onPlay: {}, onTurn: {}, onClose: {}
        )
        // The row: a press that opens the conversation, and the deck's three, passed through.
        // `onOpen` carries the post, which is what keeps the root off a state read.
        _ = DummyItemRow(
            item: Self.post, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
            marks: .constant(DummyMarks()),
            onOpen: {}, onView: {}, onTurn: {}, onToast: { _ in }
        )
        // The header's two, which cannot be handed a press without the answer that goes with it.
        let ways = TimelineWays(canSearch: true, onSearch: {}, canReload: true, onReload: {})
        #expect(ways.canSearch)
        #expect(ways.canReload)
    }

    private static let host = "example.social"

    private static var post: DummyItem {
        DummyItem(Note(
            id: "n1",
            source: Source(host: host, kind: .mastodon),
            author: "Ada",
            handle: "@ada@\(host)",
            body: "hello",
            postedAt: .distantPast,
            categories: [.public]
        ))
    }
}
