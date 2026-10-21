import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #335, the row: a post's link drawn with its preview — where it is drawn and where not, what it
/// says of where it leads, the one line it takes in a list and the height it keeps, its picture
/// asked only through the gate as a picture its own source pointed to, and the preference that
/// turns every preview off.
@Suite("A link's preview under its post", .serialized)
@MainActor
struct LinkPreviewTests {
    private static let source = Source(host: "first.example", kind: .mastodon)
    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)
    private static let card = PostCard(
        title: "A page with a preview", description: "What the page says it is about", provider: "The Daily Example",
        url: URL(string: "https://WWW.News.Example/2026/a-story"), image: URL(string: "https://cdn.example/p.png"),
        width: 64, height: 32
    )
    private static let long = String(repeating: "a line of words that runs on past the edge of this row ", count: 6)

    private static func item(
        card: PostCard? = LinkPreviewTests.card, attachments: [FediqoCore.Attachment] = [], covered: Bool = false, body: String = "Short."
    ) -> DummyItem {
        DummyItem(Note(
            id: "n1", source: source, author: "Ada", handle: "@ada@first.example", body: body, postedAt: posted,
            categories: [.public], attachments: attachments, sensitive: covered ? true : nil, spoiler: covered ? "careful" : nil,
            statusID: "1", card: card
        ))
    }

    private static func acting(_ item: DummyItem, picture: Bool = false) -> ItemActing {
        var acting = ItemActing()
        acting.preview = LinkPreview.of(item, shown: true) { _, _ in picture }
        return acting
    }

    // MARK: - Where it is drawn

    @Test("A preview is drawn under a post with a card and no media of its own, while previews are on; where it leads is the link's host as every destination is named — never the provider's name; its picture only where the gate lets it through for the post's own source")
    func whereDrawn() throws {
        var asked: [(String, String)] = []
        let shown = LinkPreview.of(Self.item(), shown: true) { reached, source in
            asked.append((reached, source))
            return true
        }
        let preview = try #require(shown)
        #expect(preview.leadsTo == "news.example" && preview.whereItLeads() != Self.card.provider)
        #expect(preview.picture == Self.card.image && preview.host == Self.source.host)
        #expect(asked.map(\.0) == ["cdn.example"] && asked.map(\.1) == [Self.source.host], "the picture's host, for the post's source")
        #expect(LinkPreview.of(Self.item(), shown: true) { _, _ in false }?.picture == nil, "not let through: no picture, the card stands")

        var never = false
        #expect(LinkPreview.of(Self.item(), shown: false) { _, _ in never = true; return true } == nil)
        #expect(!never, "previews off: nothing is drawn and the gate is not even asked")
        #expect(LinkPreview.of(Self.item(card: nil), shown: true) { _, _ in true } == nil, "a post with no card reads as before")
        let picture = FediqoCore.Attachment(kind: .image, url: URL(string: "https://cdn.example/a.png"))
        #expect(LinkPreview.of(Self.item(attachments: [picture]), shown: true) { _, _ in true } == nil, "media of its own wins")

        let nowhere = LinkPreview.of(Self.item(card: PostCard(title: "Plain page")), shown: true) { _, _ in true }
        #expect(nowhere?.leadsTo == nil && nowhere?.whereItLeads(language: .english) == "not a link this app opens")
        #expect(preview.spoken(language: .english) == "Link: A page with a preview, leads to news.example")
        #expect(nowhere?.spoken(language: .taiwanese) == "連結預覽：Plain page，不是這個 App 會開啟的連結")
        // In the opened post a listener hears what the page says it is about too; the list's line does not.
        #expect(preview.spoken(described: true, language: .english)
            == "Link: A page with a preview, leads to news.example. What the page says it is about")
    }

    @Test("A card named by the host it leads to says the host once — as its name, and not again as where it leads; the gate is asked in its own spelling of the picture's host")
    func namedByItsHost() throws {
        let named = PostCard(title: "WWW.News.Example", url: URL(string: "https://WWW.News.Example/p"), image: URL(string: "https://CDN.Example/p.png"))
        var asked: [String] = []
        let preview = try #require(LinkPreview.of(Self.item(card: named), shown: true) { reached, _ in
            asked.append(reached)
            return true
        })
        #expect(preview.namedByHost && preview.title == "news.example" && preview.whereItLeads() == nil)
        #expect(preview.spoken(language: .english) == "Link to news.example")
        #expect(preview.spoken(language: .taiwanese) == "連結，通往 news.example")
        #expect(asked == ["cdn.example"])
        let titled = try #require(LinkPreview.of(Self.item(), shown: true) { _, _ in true })
        #expect(!titled.namedByHost && titled.title == Self.card.title && titled.whereItLeads() == "news.example")
    }

    @Test("In a list the preview takes the words' last line, and the pane none; under a cover not lifted there is no preview, and no line is taken for one")
    func takesALine() {
        func row(_ item: DummyItem, _ acting: ItemActing, inFull: Bool = false, lifted: Bool = false) -> DummyItemRow {
            DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), acting: acting, inFull: inFull, lifted: lifted)
        }
        let item = Self.item()
        #expect(row(item, ItemActing()).bodyLines == 5)
        #expect(row(item, Self.acting(item)).bodyLines == 4, "the preview's line is the words' fifth")
        #expect(row(item, Self.acting(item), inFull: true).wordLines == nil)
        let covered = Self.item(covered: true)
        #expect(row(covered, Self.acting(covered)).bodyLines == row(covered, ItemActing()).bodyLines, "a cover keeps it back")
        #expect(row(covered, Self.acting(covered), lifted: true).bodyLines == row(covered, ItemActing()).bodyLines - 1)
    }

    #if os(macOS)
    private static func height(_ item: DummyItem, _ acting: ItemActing, layout: ShellLayout, size: DynamicTypeSize, inFull: Bool = false, scheme: ColorScheme = .light) -> CGFloat {
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), acting: acting, inFull: inFull)
            .environment(\.shellLayout, layout)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: row.dynamicTypeSize(size).frame(width: layout == .wide ? 720 : 390))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("A row with a preview is the height of every row, wide and narrow, light and dark, at the standard and the largest type",
          arguments: [ShellLayout.wide, .narrow], [DynamicTypeSize.large, .accessibility5])
    func oneHeight(_ layout: ShellLayout, _ size: DynamicTypeSize) {
        let plain = Self.item(card: nil, body: Self.long)
        let carded = Self.item(card: PostCard(title: Self.long, description: Self.long, url: Self.card.url), body: Self.long)
        let heights = [
            Self.height(plain, ItemActing(), layout: layout, size: size),
            Self.height(carded, Self.acting(carded), layout: layout, size: size),
            Self.height(carded, Self.acting(carded), layout: layout, size: size, scheme: .dark),
        ]
        #expect(Set(heights).count == 1, "\(layout) at \(size): \(heights)")
    }

    @Test("In the pane the preview is a band of its own lines under the words, as tall whatever the page says of itself — a preview never pushes the post")
    func paneBandIsOneHeight() {
        let short = Self.item(card: PostCard(title: "t", description: "d", url: Self.card.url))
        let longer = Self.item(card: PostCard(title: Self.long, description: Self.long, url: Self.card.url))
        for layout in [ShellLayout.wide, .narrow] {
            let without = Self.height(Self.item(card: nil), ItemActing(), layout: layout, size: .large, inFull: true)
            let a = Self.height(short, Self.acting(short), layout: layout, size: .large, inFull: true)
            let b = Self.height(longer, Self.acting(longer), layout: layout, size: .large, inFull: true)
            #expect(a == b && a > without, "\(layout): \(without) \(a) \(b)")
        }
    }
    #endif

    // MARK: - Its picture, and the preference

    @Test("Its picture is asked as a picture under the post's own source, and the run's record lists it under that source")
    func pictureUnderItsSource() async throws {
        let work = SourceWork()
        let pictures = ShellPictures(http: FixtureHTTP(["/p.png": .fail]), enforcingViewerContract: false)
        pictures.work = work
        let preview = try #require(LinkPreview.of(Self.item(), shown: true) { reached, source in
            work.admits(reached: reached, source: source)
        })
        let url = try #require(preview.picture)
        await pictures.fetch(url, scale: 2, tier: .deck, host: preview.host)
        #expect(work.record.map { "\($0.source) \($0.reached) \($0.purpose.rawValue)" } == ["first.example cdn.example picture"])
    }

    @Test("Previews are on unless the person turns them off, and the choice is kept and read again")
    func preference() {
        let defaults = UserDefaults(suiteName: "fediqo.linkPreviews.\(UUID().uuidString)")!
        let prefs = DummyPrefs(defaults: defaults)
        #expect(prefs.linkPreviews)
        prefs.linkPreviews = false
        #expect(!DummyPrefs(defaults: defaults).linkPreviews)
        defaults.set("", forKey: "fediqo.dummy.linkPreviews")
        prefs.reread()
        #expect(prefs.linkPreviews)
        for key in ["prefs.previews", "prefs.previews.head", "prefs.previews.brief", "prefs.previews.footer", "card.nowhere", "card.spoken", "card.spoken.nowhere"] {
            #expect(L10n.t(key, language: .english) != key && L10n.t(key, language: .taiwanese) != key, "\(key)")
        }
    }
}
