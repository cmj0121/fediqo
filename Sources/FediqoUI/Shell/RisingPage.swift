import SwiftUI

/// What is rising, opened (F10): one page in the frame every opened page stands in — the bar,
/// the head that says once what the page is and whose ranking it shows, Hashtags · Links where
/// its sources have both, and the tab in front.
///
/// **It draws what it is handed and asks nothing**: which tabs there are, which is in front and
/// what each band says are worked out where the sources are asked (`ShellRising`), and which
/// kind of source any of them is is never looked at here. With one tab there is no strip, and
/// the page is that one list.
struct RisingPage: View {
    /// What the tab in front is handed: `said.which` is that tab.
    let said: RisingSaid
    let tabs: [RisingWhich]
    @Binding var selectedID: String?
    var slide = PageSlide()
    /// What the bar's mark is called, or nothing where there is nobody to ask again.
    var reload: String?
    var acts = OpenedPageActs<RisingWhich>()
    /// A row opened, answered by the root.
    var onOpen: (RisingRow) -> Void = { _ in }
    /// A band's "Try again": that source asked again.
    var onAskAgain: (String) -> Void = { _ in }
    var jumpToTop: Int = 0

    /// What the bar's mark is called where `r` would ask the sources again, and nothing where
    /// it would not: then there is no mark, not a dim one, and a pull asks nothing.
    static func reloadName(canReload: Bool, language: DummyLanguage? = nil) -> String? {
        canReload ? L10n.t("rising.reload", language: language) : nil
    }

    /// What the frame presses on this page. **No Stop**: the page's asks are its sources' and
    /// never the timeline's reload, so a Stop in its bar could only stop a reload running out of
    /// sight under it.
    static func acts(
        onBack: @escaping () -> Void, onTab: @escaping (RisingWhich) -> Void, onReload: @escaping () -> Void,
        onPull: @escaping () async -> Void
    ) -> OpenedPageActs<RisingWhich> {
        OpenedPageActs(onBack: onBack, onTab: onTab, onReload: onReload, onPull: onPull, onStop: nil)
    }

    var body: some View {
        OpenedPage(
            tabs: tabs, front: said.which, slide: slide, reload: reload, acts: acts,
            head: {
                RisingHead()
                ShellRule()
            },
            inFront: { lead in
                RisingPane(said: said, selectedID: $selectedID, onOpen: onOpen, onAskAgain: onAskAgain, jumpToTop: jumpToTop) { lead }
            }
        )
    }
}
