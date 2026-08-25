import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// No scrollbar, anywhere.
    ///
    /// It is pointer furniture, and this app is steered without one: where the reader is in a
    /// timeline is said by the ring on the post they are on, and how far down they have come
    /// by the back-to-top button appearing.
    ///
    /// On iOS asking is the whole of it. On macOS the same ask is carried down and a scroller
    /// is drawn over the content regardless, so the bar is taken off the scroll views
    /// themselves — and off the window's, rather than at each `ScrollView` in turn. A screen
    /// that forgot to ask would be exactly the screen this was forgotten on, and every scroll
    /// view in the app ends up in a window either way.
    func fediqoWithoutScrollbars() -> some View {
        #if os(macOS)
        scrollIndicators(.hidden).background(ScrollerSweep())
        #else
        scrollIndicators(.hidden)
        #endif
    }
}

#if os(macOS)
/// Nothing on the screen. Its only job is to be in a window, so that the scroll views in that
/// window can be found from it.
private struct ScrollerSweep: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerSweeper { ScrollerSweeper() }

    /// Every SwiftUI pass through the chrome is a chance for a screen to have appeared with a
    /// scroller on it. Cheap enough to spend: what a pass costs is a walk of the view tree and
    /// two flags, and a pass only happens when something about the app has actually changed.
    func updateNSView(_ view: ScrollerSweeper, context: Context) { view.sweep() }
}

/// Takes the scrollers off every scroll view in its window, and goes round again whenever the
/// window says something about it has changed.
///
/// Again, because SwiftUI builds a screen's scroll view when the reader first goes there: a
/// single sweep on the way in would cover the timeline and miss Settings, and a scroller put
/// back by a later layout would stay back. `didUpdate` is where AppKit says a window has
/// finished changing, so it is where this asks the question a second time.
private final class ScrollerSweeper: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(sweep),
                                               name: NSWindow.didUpdateNotification,
                                               object: window)
        sweep()
    }

    @objc func sweep() {
        guard let content = window?.contentView else { return }
        strip(content)
    }

    /// The two flags, and nothing else. A scroll view without a scroller scrolls exactly as it
    /// did — the wheel, the trackpad and `scrollTo` all go through the clip view and none of
    /// them through the bar — so this takes the furniture away and leaves the behaviour.
    private func strip(_ view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
        }
        for subview in view.subviews { strip(subview) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
#endif
