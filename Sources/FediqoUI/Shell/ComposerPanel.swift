import SwiftUI

/// The composer, over whatever you were looking at, and the sheet of nothing behind it that
/// closes it when you look elsewhere.
///
/// **Most of the room and in the middle of it**, rather than a small panel in a corner. Writing
/// is the one thing in this app that is not reading, and a composer that took a corner of the
/// screen was a composer sized for a sentence — while what it is asked to hold is a post, a
/// content warning, a list of destinations, and now the whole of the post being answered.
///
/// Drawn here rather than handed to `.popover` for the same reason the action bar is drawn
/// rather than made a split view: where a platform popover lands, and whether it stays inside
/// the window, is the platform's decision. On a button at the very foot of the bar that
/// decision was to hang off the bottom of the screen. This one cannot.
struct ComposerPanel: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    /// Which corner the panel used to sit in, and how far off the edges.
    ///
    /// Kept because both shells still name them and because where a composer belongs on a phone
    /// is a question this change has not asked. What they no longer decide is the size: the
    /// composer is a share of the room now, and a share is the same share in either corner.
    let alignment: Alignment
    let inset: EdgeInsets

    func body(content: Content) -> some View {
        ZStack(alignment: .center) {
            content

            if app.composing {
                // Not invisible any more. A panel in a corner left most of the window readable
                // and a dimmed one behind this says the same thing louder: what is behind is
                // not what you are doing. Pressing it is still how you leave.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { app.setComposing(false) }
                    .transition(.opacity)

                ComposerView()
                    .fediqoChrome(app)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        // Losing focus closes it too. A panel that survives the app going away is a window
        // that forgot it was a panel.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { app.setComposing(false) }
        }
    }
}

extension View {
    func composerPanel(alignment: Alignment, inset: EdgeInsets) -> some View {
        modifier(ComposerPanel(alignment: alignment, inset: inset))
    }
}
