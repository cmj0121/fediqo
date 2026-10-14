import SwiftUI

/// What the bar of a conversation's page says: what the page is, the way out to the opened
/// post's own page where it has one, and whom the mark that asks again asks.
///
/// **What a post lacks is absent, not greyed**: one with no page of its own to go to has no
/// way out, and where there is nobody to ask there is no mark.
struct ConversationSaid: Equatable {
    /// The post's own page, and what the press that opens it is called.
    struct WayOut: Equatable {
        let name: String
        let url: URL
    }

    let title: String
    var wayOut: WayOut?
    var reload: String?

    static let wayOutSymbol = "arrow.up.forward.app"

    /// The bar of the conversation around `root`: a blog's where it is open on one, and the
    /// mark that asks again only where `r` would ask — called what the keys guide calls `r`,
    /// since a conversation asked again may ask more than the source its post came from.
    static func made(of root: DummyItem, blog: Bool, canReload: Bool, language: DummyLanguage? = nil) -> ConversationSaid {
        ConversationSaid(
            title: L10n.t(blog ? "blog.title" : "thread.title", language: language),
            wayOut: root.outwardURL.map {
                WayOut(name: DummyItem.wayOutName(host: root.source.host, language: language), url: $0)
            },
            reload: canReload ? L10n.t(ReloadMark.reload.name, language: language) : nil
        )
    }

    /// The page's own marks in its bar: the way out, where the post has a page to go to. A
    /// pointer resting on it is told where it leads, and a listener that it leaves the app.
    func marks(language: DummyLanguage? = nil, open: @escaping (URL) -> Void) -> [PageMark] {
        guard let wayOut else { return [] }
        return [PageMark(
            symbol: Self.wayOutSymbol, name: wayOut.name,
            help: String(format: L10n.t("thread.open.hint", language: language), wayOut.url.absoluteString),
            hint: L10n.t("thread.open.leaves", language: language), action: { open(wayOut.url) }
        )]
    }

    /// Whether the title is the first row of the list and not in the bar, at `size`: at an
    /// accessibility text size, where the frame's head scrolls away too (F10 §2).
    static func titleScrolls(at size: DynamicTypeSize) -> Bool { PageFrame.headScrolls(at: size) }
}

/// A conversation, opened: a page of its own (F10), drawn in the frame every opened page
/// stands in (`OpenedPage`) — with no head, no tabs and no figures. Its bar holds the way
/// back, what the page is, the way out to the post's own page and the mark that asks again;
/// under it is the conversation, as it always was.
///
/// **It is handed everything it draws** and asks nothing. **At an accessibility text size
/// the title leaves the bar and is the first row of the conversation**, which scrolls away:
/// `rows` is handed it there, and nothing everywhere else.
struct ConversationPage<Rows: View>: View {
    let said: ConversationSaid
    /// How far a sideways swipe has slid the conversation.
    let slide: PageSlide
    var onBack: () -> Void = {}
    var onReload: () -> Void = {}
    /// The same, pulled for: it returns when the answers have landed.
    var onPull: () async -> Void = {}
    /// What stops the asking the reader pressed for, while one is running.
    var onStop: (() -> Void)?
    @ViewBuilder var rows: (_ titleRow: String?) -> Rows

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL

    var body: some View {
        let scrolls = ConversationSaid.titleScrolls(at: typeSize)
        OpenedPage(
            slide: slide, title: scrolls ? nil : said.title, marks: said.marks { openURL($0) }, reload: said.reload,
            onBack: onBack, onReload: onReload, onPull: onPull, onStop: onStop,
            head: { EmptyView() },
            inFront: { _ in rows(scrolls ? said.title : nil) }
        )
    }
}

/// What a conversation's page is, said as the first row of its list where the bar has no
/// room for it.
struct ConversationTitleRow: View {
    let title: String

    /// What the row is called in its list: where `g` scrolls to while it is there.
    static let rowID = "conversation.title"

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .shellFont(.pane)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .padding(.horizontal, ShellSpace.pad)
            .accessibilityAddTraits(.isHeader)
    }
}
