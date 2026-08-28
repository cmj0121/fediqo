#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// Where a fixture run puts its window: the same size every time, and out of the way where
/// there is somewhere to be out of the way.
///
/// **`#if DEBUG`, whole file**, and asked for only when `FEDIQO_FIXTURE` is on — the build that
/// goes to the store cannot compile this, and a reader's own window is never touched by it.
///
/// Two reasons, and the second is the one that caused this to be written. A run that exists to
/// be photographed wants the same frame every time, or the screenshots differ by whatever the
/// window happened to be when somebody last dragged it. And a run being driven by a test takes
/// over the machine it is on: it needs the app frontmost, which nothing can avoid, but it does
/// not need to sit on top of whatever the person at the keyboard was reading. Where there is a
/// second display it goes there.
///
/// macOS restores a window's frame from the last session, which is what makes "the same every
/// time" untrue by default and is why this sets the frame rather than trusting one. A driver
/// should also pass `-ApplePersistenceIgnoreState YES` so nothing is restored in the first
/// place; this is the other half of that, and either alone leaves a run that depends on where
/// the last one was left.
struct FixtureWindow: ViewModifier {
    /// Big enough that a card is a card and the rail has its labels, and small enough to sit
    /// on a laptop's own screen when there is no second one.
    private static let size = CGSize(width: 1000, height: 800)

    func body(content: Content) -> some View {
        content.onAppear(perform: place)
    }

    /// The window this view is in, put where fixture runs go.
    ///
    /// Asked for on the next turn of the run loop rather than now: `onAppear` happens while the
    /// scene is still being built, and there is no window to move yet.
    private func place() {
        // The next turn of the run loop, and not a `Task`. Both compile; only one of them is
        // soon enough. A `Task` is scheduled rather than queued and can land well after the
        // screen is up — late enough that a driver has begun pressing keys, and a window that
        // moves to another display mid-press takes the keyboard with it. This runs before
        // anybody has touched anything, which is the whole point of moving it at all.
        //
        // `assumeIsolated` because the queue's closure is isolated to nothing and everything
        // in it — the window, `NSApp` — belongs to the main actor. It is already on the main
        // thread; this is only saying so in a way a strict compiler accepts.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                place(in: NSApp.windows.first(where: \.isVisible))
            }
        }
    }

    /// The window put where fixture runs go, or nothing to do where there is no window.
    @MainActor
    private func place(in window: NSWindow?) {
        guard let window else { return }
        // The second display where there is one — `screens[0]` is the one with the menu bar,
        // which is where everything else the person is doing already is.
        let screen = NSScreen.screens.dropFirst().first ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = CGSize(width: min(Self.size.width, visible.width),
                          height: min(Self.size.height, visible.height))
        window.setFrame(CGRect(x: visible.midX - size.width / 2,
                               y: visible.midY - size.height / 2,
                               width: size.width, height: size.height),
                        display: true)
    }
}
#endif

extension View {
    /// The window a fixture run opens in. Nothing at all in a build anybody ships, and nothing
    /// on a run reading the reader's own servers.
    @ViewBuilder
    func fixtureWindow(_ on: Bool) -> some View {
        #if DEBUG && os(macOS)
        if on { modifier(FixtureWindow()) } else { self }
        #else
        self
        #endif
    }
}
