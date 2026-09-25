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
        // A phone's width at the largest size: still one height, and still the same one.
        let narrow = Set(Self.faces().map { Self.height($0, size: .accessibility5, width: 320) })
        #expect(narrow == largest, "at 320 wide and the largest size, got \(narrow.sorted())")
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

    @Test("A source row's sentences: the errand, then a refusal, then the notice — none hidden by another")
    func statusLine() {
        let refused = (host: "a.example", key: "account.source.boards.unread")
        #expect(SourceRow.statusLines(waiting: nil, refusal: nil, notice: nil, host: "a.example").isEmpty)
        #expect(SourceRow.statusLines(waiting: "w", refusal: nil, notice: "n", host: "a.example") == ["w", "n"])
        #expect(SourceRow.statusLines(waiting: nil, refusal: refused, notice: "n", host: "b.example") == ["n"])
        #expect(SourceRow.statusLines(waiting: nil, refusal: refused, notice: "n", host: "a.example")
            == [String(format: L10n.t("account.source.boards.unread"), "a.example"), "n"],
            "a refusal does not hide the notice: both are said")
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
    @Test("A source row on Account is one height at rest, waiting, refused or with a notice",
          arguments: [(DynamicTypeSize.large, CGFloat(900)), (.accessibility5, 900), (.large, 340), (.accessibility5, 340)])
    func sourceRowIsOneHeight(_ size: DynamicTypeSize, _ width: CGFloat) {
        let source = Source(host: "forum.example", kind: .discuz)
        let row = SourceRow(source: source, profile: .unasked(host: "forum.example", kind: .discuz))
        func drawn(waiting: String? = nil, refusal: (host: String, key: String)? = nil, notice: String? = nil) -> some View {
            SourceRowView(
                row: row, signedIn: false, width: width, widest: SourceRow.controls(of: source),
                actsLive: true, waiting: waiting, refusal: refusal, notice: notice,
                signIn: {}, clear: {}, remove: {}, changeBoards: {}, open: {}
            )
        }
        let heights = Set([
            Self.height(drawn(), size: size, width: width),
            Self.height(drawn(waiting: "Signing in to forum.example…"), size: size, width: width),
            Self.height(drawn(refusal: (host: "forum.example", key: "account.source.boards.unread")), size: size, width: width),
            Self.height(drawn(notice: Self.long), size: size, width: width),
            Self.height(drawn(waiting: Self.long, refusal: (host: "forum.example", key: "account.source.boards.unread"),
                              notice: Self.long), size: size, width: width),
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
    private static func rowHeight(
        _ item: DummyItem, layout: ShellLayout, size: DynamicTypeSize, lifted: Bool = false, asked: Bool = false,
        acting: ItemActing = ItemActing()
    ) -> CGFloat {
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                               marks: .constant(DummyMarks()), acting: acting, bandAsked: asked, lifted: lifted,
                               onToast: { _ in })
            .environment(\.shellLayout, layout)
        return height(row, size: size, width: layout == .wide ? 720 : 390)
    }

    /// One case a layout and a size, so no case holds the main actor for long.
    @Test("Every post in a timeline is one height, wide and narrow, at the standard and the largest type",
          arguments: [ShellLayout.wide, .narrow], [DynamicTypeSize.large, .accessibility3])
    func timelineRowIsOneHeight(_ layout: ShellLayout, _ size: DynamicTypeSize) {
        var measured = Self.variants().map { ($0.0, Self.rowHeight($0.1, layout: layout, size: size)) }
        // Every mark, counted: the longest marks line a row draws is the same one line.
        measured.append(("every act", Self.rowHeight(Self.counted(), layout: layout, size: size, acting: Self.everyAct)))
        let heights = Set(measured.map(\.1))
        #expect(heights.count == 1, "\(layout) at \(size): \(measured.map { "\($0.0) \($0.1)" })")
    }

    /// **The band holds what it is given, rather than cutting it mid-line.** Each worst case —
    /// a reply that is boosted and quotes, on a board, with a title and a long warning, lifted and
    /// covered — is drawn twice: with the band held to the slot, and with the band at the height
    /// its contents ask for. The asked-for row may be shorter, never taller.
    @Test("The words band holds its worst case whole, wide and narrow, at the standard and the largest type",
          arguments: [ShellLayout.wide, .narrow], [DynamicTypeSize.large, .xxxLarge, .accessibility5])
    func bandHoldsTheWorstCase(_ layout: ShellLayout, _ size: DynamicTypeSize) {
        let quote = Quote(state: .pending)
        let worst = [
            Self.note(body: Self.longPost, title: "A thread's title " + Self.longPost, board: "A board",
                      kind: .discuz, reply: Reply(handle: "@bob@first.example"), boostedBy: "Bob",
                      attachments: [Self.picture("a")], sensitive: true, spoiler: Self.longPost, quote: quote),
            Self.note(body: Self.longPost, reply: Reply(handle: "@bob@first.example"), boostedBy: "Bob",
                      attachments: [Self.picture("a")], sensitive: true, spoiler: Self.longPost, quote: quote),
            Self.note(body: Self.longPost, title: "A title", board: "A board", kind: .discuz,
                      reply: Reply(handle: "@bob@first.example")),
            Self.note(body: Self.longPost),
        ]
        for item in worst {
            for lifted in [false, true] {
                let held = Self.rowHeight(item, layout: layout, size: size, lifted: lifted)
                let asked = Self.rowHeight(item, layout: layout, size: size, lifted: lifted, asked: true)
                #expect(asked <= held, "\(layout) \(size) lifted \(lifted): asks \(asked), held \(held)")
            }
        }
    }

    /// Lays a row out at its own height and reads back where each band went.
    private static func bands(_ item: DummyItem, layout: ShellLayout) -> [RowBand: CGRect] {
        let probe = RowBandProbe()
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                               marks: .constant(DummyMarks()), probe: probe, onToast: { _ in })
            .environment(\.shellLayout, layout)
        let host = NSHostingView(rootView: row.frame(width: layout == .wide ? 720 : 390))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return probe.frames
    }

    /// **What happened to a post is the row's first line** — above who wrote it, not the first
    /// line of the words under the header — and then the post, then its marks.
    @Test("A boosted, answering or quoting row reads decorator, header, post, marks, top to bottom",
          arguments: [ShellLayout.wide, .narrow])
    func decoratorHeadsTheRow(_ layout: ShellLayout) throws {
        let quote = Quote(state: .pending)
        let decorated = [
            ("boosted", Self.note(body: Self.longPost, boostedBy: "Bob")),
            ("answering", Self.note(body: "Short.", reply: Reply(handle: "@bob@first.example"))),
            ("quoting", Self.note(body: Self.longPost, attachments: [Self.picture("a")], quote: quote)),
        ]
        for (name, item) in decorated {
            let bands = Self.bands(item, layout: layout)
            let decorator = try #require(bands[.decorator], "\(name): no decorator drawn")
            let header = try #require(bands[.header])
            let content = try #require(bands[.content])
            let marks = try #require(bands[.marks])
            #expect(decorator.height > 0)
            #expect(decorator.maxY <= header.minY, "\(layout) \(name): decorator \(decorator), header \(header)")
            #expect(header.maxY <= content.minY, "\(layout) \(name): header \(header), post \(content)")
            #expect(content.maxY <= marks.minY, "\(layout) \(name): post \(content), marks \(marks)")
        }
    }

    /// A post of the reader's own that offers every act, with counts: the most marks a row draws.
    private static let everyAct = ItemActing(acts: PostActs(offered: Set(PostAct.allCases)), perform: { _ in })

    private static func counted() -> DummyItem {
        DummyItem(Note(
            id: "n1", source: Source(host: "first.example", kind: .mastodon), author: "Ada",
            handle: "@ada@author.example", body: "Short.", postedAt: posted, categories: [.public],
            counts: Counts(replies: 12_345, reblogs: 67_890, favourites: 123_456), statusID: "1"
        ))
    }

    /// **One line, where a narrow Mac window and the larger sizes used to break it in two.** Every
    /// mark is laid out, at one height, inside the row.
    @Test("A post's marks sit on one line at a narrow width and at the larger sizes",
          arguments: [(ShellLayout.narrow, DynamicTypeSize.large), (.narrow, .xxLarge), (.wide, .xxLarge),
                      (.narrow, .accessibility3), (.wide, .accessibility5)])
    func marksOnOneLine(_ layout: ShellLayout, _ size: DynamicTypeSize) throws {
        let probe = RowBandProbe()
        let width: CGFloat = layout == .wide ? 720 : 390
        let row = DummyItemRow(item: Self.counted(), catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                               marks: .constant(DummyMarks()), acting: Self.everyAct, probe: probe, onToast: { _ in })
            .environment(\.shellLayout, layout)
            .dynamicTypeSize(size)
        let host = NSHostingView(rootView: row.frame(width: width))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let marks = probe.marks
        #expect(marks.count == 8, "every mark is laid out: \(marks.keys.sorted())")
        let middles = Set(marks.values.map { ($0.midY * 2).rounded() / 2 })
        #expect(middles.count == 1, "\(layout) \(size): marks at \(marks.values.map(\.midY).sorted())")
        let band = try #require(probe.frames[.marks])
        for (name, frame) in marks {
            #expect(frame.minX >= band.minX - 0.5 && frame.maxX <= band.maxX + 0.5,
                    "\(layout) \(size): \(name) \(frame) outside \(band)")
            #expect(frame.width > 0, "\(name) is drawn")
        }
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
        #expect(place(Self.note(body: "\u{200B}\u{FEFF} \u{200D}", attachments: pictures)) == .column,
                "characters that draw nothing are no words")
        #expect(place(Self.note(body: "", board: "A board", kind: .discuz, attachments: pictures)) == .slot,
                "a board's post keeps its board's name over the words' column")
        #expect(place(Self.note(body: "Words.", attachments: pictures)) == .slot)
        #expect(place(Self.note(body: "", attachments: pictures, sensitive: true, spoiler: "")) == .slot,
                "a covered post's pictures stay under its cover, in the slot")
        #expect(place(Self.note(body: "", attachments: pictures, sensitive: true, spoiler: "Weather")) == .slot)
        #expect(place(Self.note(body: "", attachments: pictures), inFull: true) == .slot, "the thread keeps its layout")
        #expect(place(Self.note(body: "")) == nil)
    }

    @Test("A picture pressed in a spread comes to the top, so the viewer opens the one pressed")
    func pressedPictureOpens() {
        var decks = ShellDecks()
        decks.show("a", at: 2, of: 4)
        #expect(decks.top(of: "a", of: 4) == 2)
        decks.show("a", at: 5, of: 4)
        #expect(decks.top(of: "a", of: 4) == 1)
        #expect(decks.top(of: "b", of: 4) == 0, "another post's deck does not move")
    }

    @Test("A board's or a list's name is one line, and two held open at the accessibility sizes")
    func pickNameLines() {
        #expect(PickName.lines(at: .xxxLarge) == 1)
        #expect(PickName.lines(at: .accessibility1) == 2)
    }

    @Test("A source's detail says every sentence its row cut, light and dark", arguments: [ColorScheme.light, .dark])
    func standingDraws(_ scheme: ColorScheme) throws {
        let standing = SourceStanding(lines: ["Signing in…", Self.long, "Its password was not forgotten."])
        for size in [DynamicTypeSize.large, .accessibility5] {
            let renderer = ImageRenderer(
                content: standing.environment(\.colorScheme, scheme).dynamicTypeSize(size).frame(width: 360)
            )
            let image = try #require(renderer.cgImage)
            #expect(image.height > 0)
        }
    }

    @Test("A spread draws the one on top first and the rest in turning order")
    func spreadOrder() {
        #expect(AttachmentDeck.following(0, of: 1).isEmpty)
        #expect(AttachmentDeck.following(0, of: 3) == [1, 2])
        #expect(AttachmentDeck.following(2, of: 3) == [0, 1])
        #expect(AttachmentDeck.following(0, of: 9) == [1, 2, 3, 4])
    }

    @Test("What happened to a post has a line of the row's own, and takes none of its words")
    func decoratorKeepsTheWords() {
        func lines(_ item: DummyItem) -> Int {
            DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                         marks: .constant(DummyMarks()), onToast: { _ in }).bodyLines
        }
        #expect(lines(Self.note()) == 4, "the wide layout's four lines stay four")
        #expect(lines(Self.note(boostedBy: "Bob")) == 4)
        #expect(lines(Self.note(reply: Reply(handle: "@bob@first.example"))) == 4)
        #expect(lines(Self.note(quote: Quote(state: .pending))) == 4)
        #expect(lines(Self.note(title: "t", kind: .discuz)) == 3, "a title still takes a line of the words")
    }

    @Test("The marks' line closes its gaps first, then narrows every mark, and always ends inside the width")
    func marksLineGivesWay() {
        let widths: [CGFloat] = [40, 40, 32, 40, 32, 32, 32, 32]
        let gaps: [CGFloat] = [8, 8, 8, 8, 24, 8, 8, 8]
        let ideal = widths.reduce(0, +) + gaps.dropFirst().reduce(0, +)
        let roomy = MarksLine.fit(widths, gaps: gaps, least: 1, width: ideal + 10)
        #expect(roomy.gaps == gaps && roomy.widths == widths, "room enough: nothing gives way")
        let closer = MarksLine.fit(widths, gaps: gaps, least: 1, width: ideal - 30)
        #expect(closer.widths == widths, "the gaps close before a mark is narrowed")
        #expect(closer.gaps.dropFirst().allSatisfy { $0 >= 1 })
        #expect(abs(closer.widths.reduce(0, +) + closer.gaps.dropFirst().reduce(0, +) - (ideal - 30)) < 0.01)
        let narrowed = MarksLine.fit(widths, gaps: gaps, least: 1, width: 150)
        #expect(narrowed.gaps.dropFirst().allSatisfy { $0 == 1 })
        #expect(abs(narrowed.widths.reduce(0, +) + 7 - 150) < 0.01, "every mark gives up its share")
        #expect(narrowed.widths.allSatisfy { $0 > 0 }, "no mark is dropped")
    }
}
