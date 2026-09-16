#if os(macOS)
import AppKit
import SwiftUI

/// The sign-in page in a window the reader can resize, rather than in a sheet they cannot.
///
/// **A sheet on macOS has no grab handles, and that is why this exists.** `.sheet` draws a modal
/// attached to the window, sized by its content and resizable by nobody — so a forum's login page,
/// which is a real web page written for a browser, was stuck at whatever size this app had decided
/// was reasonable. A reader who could not see the password field had no way to make the thing
/// bigger, which is not a preference about window sizes, it is a sign-in they cannot complete.
///
/// A window is also the more honest object. What is inside it is somebody else's web page and the
/// reader is being asked to type a password into it; a thing with a title bar saying which host it
/// belongs to, which can be moved and resized and put behind the app, describes that better than a
/// panel that has taken over the app until it is dismissed.
///
/// **iOS keeps the sheet**, because there are no windows to resize there: a sheet already fills the
/// screen, and that is already every point the device has.
@MainActor
final class ForumSignInWindows {
    /// Opened at the size a login page is written for, and never smaller than a login page can be
    /// used at. The reader's own size, once they set one, is the window's business and not ours.
    private static let opening = NSSize(width: 800, height: 600)
    private static let smallest = NSSize(width: 380, height: 480)

    private var window: NSWindow?
    private var delegate: Closing?

    /// Shows the page for one request, replacing whatever was open.
    ///
    /// `onFinish` is called **exactly once** for a window, whichever way it ends: Cancel, Done, or
    /// the close button in the title bar. A reader who closes the window with the red button has
    /// said the same thing as one who pressed Cancel, and a flow that only heard about one of them
    /// would leave the app waiting for a sign-in that is not happening.
    func show(
        _ request: ForumSignInRequest,
        sessions: ForumSessions,
        onFinish: @escaping (Bool) -> Void
    ) {
        close()

        var answered = false
        let answer: (Bool) -> Void = { [weak self] reached in
            guard !answered else { return }
            answered = true
            self?.close()
            onFinish(reached)
        }

        let view = ForumSignInSheet(request: request, sessions: sessions, finished: answer)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.opening),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Held by this object rather than by AppKit, so that closing it from either side leaves
        // something valid behind to call `onFinish` through.
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.contentMinSize = Self.smallest
        // Set after the content view controller, which would otherwise size the window to the
        // view's own ideal and quietly undo the opening size.
        window.setContentSize(Self.opening)
        window.title = String(format: L10n.t("forum.signin.title"), request.host)
        window.center()

        let closing = Closing { answer(false) }
        window.delegate = closing

        self.window = window
        self.delegate = closing
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        delegate = nil
    }

    /// Turns the title bar's close button into the same answer as Cancel.
    private final class Closing: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }
}
#endif
