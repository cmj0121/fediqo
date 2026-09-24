import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #242: a description heads its data, and every row of a list is one height.
///
/// **Measured, not argued.** Each row is hosted off screen and its fitting height read back, at
/// the standard type size and at the largest; a row that grew with what it holds would measure a
/// second number. Only relations are asserted — the ink a system font reports is a fact about the
/// machine. Few and cheap, for the watchdog `test-before-push` names.
@Suite("A description heads its data, and a row is one height", .serialized)
@MainActor
struct OneHeightTests {
    #if os(macOS)
    private static func height(_ view: some View, size: DynamicTypeSize, width: CGFloat = 360) -> CGFloat {
        let host = NSHostingView(rootView: view.dynamicTypeSize(size).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private static let long = String(repeating: "a brief line that runs on well past one line of this row ", count: 6)

    /// The faces a list draws: short, long, none, a long title, a figure and none.
    private static func faces() -> [ShellListRowFace<Image>] {
        let mark = Image(systemName: "server.rack")
        return [
            ShellListRowFace(title: "mastodon.social", brief: "12 posts", figure: "4.2 MB", selected: false, mark: mark),
            ShellListRowFace(title: "mastodon.social", brief: long, figure: "4.2 MB", selected: true, mark: mark),
            ShellListRowFace(title: "forum.example", brief: nil, figure: nil, selected: false, mark: mark),
            ShellListRowFace(title: long, brief: long, figure: nil, selected: false, mark: mark),
            ShellListRowFace(title: "a.example", brief: "short", figure: "12,345 posts held", selected: false, mark: mark),
        ]
    }

    @Test("Every list row is one height, whatever it holds, and the largest type makes them all taller alike")
    func listRowIsOneHeight() {
        let standard = Set(Self.faces().map { Self.height($0, size: .large) })
        #expect(standard.count == 1, "one height at the standard size, got \(standard.sorted())")
        let largest = Set(Self.faces().map { Self.height($0, size: .accessibility5) })
        #expect(largest.count == 1, "one height at the largest size, got \(largest.sorted())")
        #expect((largest.first ?? 0) > (standard.first ?? 0))
    }

    @Test("A row's control does not make it taller than its neighbours")
    func controlKeepsTheHeight() {
        let lit = Binding<String?>.constant(nil)
        let plain = ShellListRow(id: "a", title: "a", brief: "b", selection: lit, onOpen: {}) {
            Image(systemName: "server.rack")
        }
        let switched = ShellListRow(id: "b", title: "b", brief: Self.long, selection: lit, onOpen: {}) {
            Image(systemName: "server.rack")
        } control: {
            Toggle("", isOn: .constant(true)).labelsHidden()
        }
        #expect(Self.height(plain, size: .large) == Self.height(switched, size: .large))
    }
    #endif

    @Test("At the accessibility sizes the figure leads the brief line, and an empty row says nothing")
    func briefLineReads() {
        let font = Font.body
        #expect(ShellListRowFace<Image>.brief(nil, figure: nil, figureFont: font) == nil)
        #expect(ShellListRowFace<Image>.brief("b", figure: nil, figureFont: font) == Text(verbatim: "b"))
        #expect(ShellListRowFace<Image>.brief(nil, figure: "4 MB", figureFont: font) == Text(verbatim: "4 MB").font(font))
        #expect(ShellListRowFace<Image>.brief("b", figure: "4 MB", figureFont: font)
            == Text(verbatim: "4 MB").font(font) + Text(verbatim: " \u{00B7} ") + Text(verbatim: "b"))
    }

    @Test("A group's heading draws its title, its line and its (?), light and dark and at the largest type",
          arguments: [ColorScheme.light, .dark])
    func sectionHeadDraws(_ scheme: ColorScheme) throws {
        for head in [
            ShellSectionHead("Held on this device", line: "Most of this is read again.", help: "The long of it."),
            ShellSectionHead("Sources", line: "Everything this device reads.", help: nil),
            ShellSectionHead("Hosts you added", line: nil, help: "Each serves one of your sources."),
        ] {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let renderer = ImageRenderer(
                    content: head.environment(\.colorScheme, scheme).dynamicTypeSize(size).frame(width: 360)
                )
                let image = try #require(renderer.cgImage)
                #expect(image.width > 0 && image.height > 0)
            }
        }
    }

    // MARK: - #244: every description on its group's heading

    private static var shell: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell")
    }

    /// **Read off the sources, so a screen added tomorrow is held to it too.** A group's foot is
    /// where descriptions used to live; no group has one now, and the footer piece Usage kept for
    /// it is gone rather than kept beside the heading.
    @Test("No group carries a description at its foot")
    func noFooters() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.shell, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("} footer: {"), "\(file.lastPathComponent) has a group footer")
            #expect(!text.contains("UsageFooter("), "\(file.lastPathComponent) draws a footer line")
        }
    }

    @Test("Every list a join step shows has a heading with its line; a preview heads itself")
    func joinStepsHaveHeadings() {
        let offer = JoinOffer(host: "forum.example", kind: .discuz, categories: [])
        let stages: [JoinStage] = [
            .browsing, .browsingServers(.mastodon), .choosingBoards(offer, from: .joined(subscribed: [], ticked: [])),
            .choosingLists(ListChoice(host: "m.example", offered: [], ticked: [])),
        ]
        for stage in stages {
            for language in [DummyLanguage.english, .taiwanese] {
                let head = JoinSheet.head(for: stage, language: language)
                #expect(head != nil, "\(stage) has no heading")
                #expect(head?.title.isEmpty == false && head?.line.isEmpty == false)
            }
        }
        #expect(JoinSheet.head(for: nil) == nil)
        #expect(JoinSheet.head(for: .choosingBoards(offer, from: .joined(subscribed: [], ticked: [])))?.help
            == L10n.t("board.choose.detail.change"))
    }

    @Test("The record's heading says newest first, and how many old lines went where any did")
    func activityLine() {
        #expect(ActivityPanel.line(dropped: 0, language: .english) == L10n.t("activity.brief", language: .english))
        let dropped = ActivityPanel.line(dropped: 3, language: .taiwanese)
        #expect(dropped.hasPrefix(L10n.t("activity.brief", language: .taiwanese)))
        #expect(dropped.contains("3"))
    }

    @Test("The adding field's heading says the first thing to do, or how to add another")
    func addingHeading() {
        #expect(AccountPane.addingKeys(tabbed: false) == ("account.hero.line", "account.hero.detail"))
        #expect(AccountPane.addingKeys(tabbed: true) == ("account.add.line", "account.add.detail"))
    }

    @Test("The sources list's (?) holds what stood under the list")
    func sourcesHelpHoldsTheFoot() {
        for language in [DummyLanguage.english, .taiwanese] {
            let help = AccountPane.sourcesHelp(language: language)
            #expect(help.contains(L10n.t("account.sources.writing", language: language)))
            #expect(help.contains(L10n.t("account.sources.held", language: language)))
        }
    }

    @Test("A source row's brief line says one sentence: a refusal first, then the forum's notice")
    func statusLine() {
        let refused = (host: "a.example", key: "account.source.boards.unread")
        #expect(SourceRow.statusLine(refusal: nil, notice: nil, host: "a.example") == nil)
        #expect(SourceRow.statusLine(refusal: nil, notice: "n", host: "a.example") == "n")
        #expect(SourceRow.statusLine(refusal: refused, notice: "n", host: "b.example") == "n")
        #expect(SourceRow.statusLine(refusal: refused, notice: "n", host: "a.example")
            == String(format: L10n.t("account.source.boards.unread"), "a.example"))
    }

    @Test("Every new heading is in all three languages")
    func headingStrings() throws {
        let resources = Self.shell.deletingLastPathComponent().appendingPathComponent("Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in ["prefs.askEvery.head", "prefs.latest.head", "activity.list", "join.browse.protocols",
                        "join.browse.servers", "board.choose.boards", "list.choose.lists", "forum.signin.page"] {
                #expect(strings.contains("\"\(key)\" = "), "\(lproj) is missing \(key)")
            }
        }
    }

    #if os(macOS)
    @Test("A source row on Account is one height at rest, waiting, refused or with a notice")
    func sourceRowIsOneHeight() {
        let source = Source(host: "forum.example", kind: .discuz)
        let row = SourceRow(source: source, profile: .unasked(host: "forum.example", kind: .discuz))
        func drawn(waiting: String? = nil, refusal: (host: String, key: String)? = nil, notice: String? = nil) -> some View {
            SourceRowView(
                row: row, signedIn: false, width: 900, widest: SourceRow.controls(of: source),
                actsLive: true, waiting: waiting, refusal: refusal, notice: notice,
                signIn: {}, clear: {}, remove: {}, changeBoards: {}, open: {}
            )
        }
        let heights = Set([
            Self.height(drawn(), size: .large, width: 900),
            Self.height(drawn(waiting: "Signing in to forum.example…"), size: .large, width: 900),
            Self.height(drawn(refusal: (host: "forum.example", key: "account.source.boards.unread")), size: .large, width: 900),
            Self.height(drawn(notice: Self.long), size: .large, width: 900),
        ])
        #expect(heights.count == 1, "one height, got \(heights.sorted())")
    }
    #endif

    // MARK: - #245: every post in a timeline is one height

    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)
    private static let longPost = String(repeating: "A post that goes on and on about the weather and more. ", count: 30)

    private static func note(
        body: String = "Short.", title: String? = nil, board: String? = nil, kind: ProtocolKind = .mastodon,
        reply: Reply? = nil, boostedBy: String? = nil, attachments: [FediqoCore.Attachment] = [],
        sensitive: Bool? = nil, spoiler: String? = nil, quote: Quote? = nil
    ) -> DummyItem {
        DummyItem(Note(
            id: "n1", source: Source(host: "first.example", kind: kind), author: "Ada",
            handle: "@ada@author.example", body: body, title: title, board: board, postedAt: posted,
            categories: [.public], reply: reply, boostedBy: boostedBy, attachments: attachments,
            sensitive: sensitive, spoiler: spoiler, statusID: "1", quote: quote
        ))
    }

    private static func picture(_ name: String) -> FediqoCore.Attachment {
        FediqoCore.Attachment(kind: .image, previewURL: URL(string: "https://first.example/\(name).jpg"))
    }

    /// Every shape a post takes in a timeline: short, long, pictured, boosted, answering, quoting,
    /// covered with and without a warning, a long warning, a forum thread with its title, and all
    /// of it at once.
    private static func variants() -> [(String, DummyItem)] {
        let quoted = QuotedPost(
            id: "https://first.example/users/bob/statuses/0", statusID: "0", author: "Bob",
            handle: "@bob@first.example", body: longPost, postedAt: posted, sensitive: false, spoiler: "",
            audience: .everyone, quoting: nil
        )
        let quote = Quote(state: .accepted, post: quoted)
        return [
            ("short", note()),
            ("pictured and long", note(body: longPost, attachments: [picture("a"), picture("b")])),
            ("pictures alone", note(body: "", attachments: [picture("a"), picture("b"), picture("c")])),
            ("boosted pictures alone", note(body: " ", boostedBy: "Bob", attachments: [picture("a")])),
            ("boosted and quoting", note(body: longPost, boostedBy: "Bob", quote: quote)),
            ("answering, long warning", note(body: longPost, reply: Reply(handle: "@bob@first.example"),
                                             sensitive: true, spoiler: longPost)),
            ("thread", note(body: longPost, title: "A thread's title", board: "A board", kind: .discuz)),
            ("everything", note(body: longPost, reply: Reply(handle: "@bob@first.example"), boostedBy: "Bob",
                                attachments: [picture("a")], sensitive: true, spoiler: longPost, quote: quote)),
        ]
    }

    #if os(macOS)
    private static func rowHeight(_ item: DummyItem, layout: ShellLayout, size: DynamicTypeSize) -> CGFloat {
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                               marks: .constant(DummyMarks()), onToast: { _ in })
            .environment(\.shellLayout, layout)
        return height(row, size: size, width: layout == .wide ? 720 : 390)
    }

    /// One case a layout and a size, so no case holds the main actor for long.
    @Test("Every post in a timeline is one height, wide and narrow, at the standard and the largest type",
          arguments: [ShellLayout.wide, .narrow], [DynamicTypeSize.large, .accessibility3])
    func timelineRowIsOneHeight(_ layout: ShellLayout, _ size: DynamicTypeSize) {
        let measured = Self.variants().map { ($0.0, Self.rowHeight($0.1, layout: layout, size: size)) }
        let heights = Set(measured.map(\.1))
        #expect(heights.count == 1, "\(layout) at \(size): \(measured.map { "\($0.0) \($0.1)" })")
    }

    @Test("The largest type makes every timeline row taller alike")
    func timelineRowGrowsWithType() {
        let short = Self.note()
        #expect(Self.rowHeight(short, layout: .wide, size: .accessibility3) > Self.rowHeight(short, layout: .wide, size: .large))
    }
    #endif

    @Test("A post of pictures alone draws them where its words would be; any other post, beside them")
    func picturesAloneTakeTheColumn() {
        func place(_ item: DummyItem, inFull: Bool = false) -> DummyItemRow.PicturePlace? {
            DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                         marks: .constant(DummyMarks()), inFull: inFull, onToast: { _ in }).picturePlace
        }
        let pictures = [Self.picture("a"), Self.picture("b")]
        #expect(place(Self.note(body: "", attachments: pictures)) == .column)
        #expect(place(Self.note(body: " \n ", boostedBy: "Bob", attachments: pictures)) == .column)
        #expect(place(Self.note(body: "Words.", attachments: pictures)) == .slot)
        #expect(place(Self.note(body: "", attachments: pictures, sensitive: true, spoiler: "")) == .slot,
                "a covered post's pictures stay under its cover, in the slot")
        #expect(place(Self.note(body: "", attachments: pictures, sensitive: true, spoiler: "Weather")) == .slot)
        #expect(place(Self.note(body: "", attachments: pictures), inFull: true) == .slot, "the thread keeps its layout")
        #expect(place(Self.note(body: "")) == nil)
    }

    @Test("A spread draws the one on top first and the rest in turning order")
    func spreadOrder() {
        #expect(AttachmentDeck.following(0, of: 1).isEmpty)
        #expect(AttachmentDeck.following(0, of: 3) == [1, 2])
        #expect(AttachmentDeck.following(2, of: 3) == [0, 1])
        #expect(AttachmentDeck.following(0, of: 9) == [1, 2, 3, 4])
    }

    @Test("What happened to a post takes one of its lines, not a line of its own")
    func decoratorTakesALine() {
        func lines(_ item: DummyItem) -> Int {
            DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                         marks: .constant(DummyMarks()), onToast: { _ in }).bodyLines
        }
        #expect(lines(Self.note()) == 4, "the wide layout's four lines stay four")
        #expect(lines(Self.note(boostedBy: "Bob")) == 3)
        #expect(lines(Self.note(reply: Reply(handle: "@bob@first.example"))) == 3)
        #expect(lines(Self.note(title: "t", kind: .discuz)) == 3)
    }

    @Test("The marks break the same way on every row: by the page and the type size alone")
    func marksBreakByPage() {
        #expect(!DummyItemRow.marksStack(narrow: false, size: .large))
        #expect(!DummyItemRow.marksStack(narrow: false, size: .xxxLarge))
        #expect(DummyItemRow.marksStack(narrow: true, size: .large))
        #expect(DummyItemRow.marksStack(narrow: false, size: .accessibility1))
    }
}
