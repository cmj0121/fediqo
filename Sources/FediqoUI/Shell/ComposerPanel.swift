import SwiftUI

/// The composer, floating over whatever you were looking at, and the sheet of nothing behind
/// it that closes it when you look elsewhere.
///
/// Drawn here rather than handed to `.popover` for the same reason the action bar is drawn
/// rather than made a split view: where a platform popover lands, and whether it stays inside
/// the window, is the platform's decision. On a button at the very foot of the bar that
/// decision was to hang off the bottom of the screen. This one cannot.
struct ComposerPanel: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    /// Which corner the panel sits in, and how far off the edges.
    let alignment: Alignment
    let inset: EdgeInsets

    func body(content: Content) -> some View {
        ZStack(alignment: alignment) {
            content

            if app.composing {
                // Invisible, and the whole point: anywhere you press that is not the panel
                // is somewhere else, and looking somewhere else closes it.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { app.setComposing(false) }

                ComposerView()
                    .fediqoChrome(app)
                    .padding(inset)
                    .transition(.scale(scale: 0.96, anchor: .init(x: 0, y: 1)).combined(with: .opacity))
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
