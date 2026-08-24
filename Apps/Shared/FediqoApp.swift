import SwiftUI
import FediqoUI

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`,
/// so iOS is this same file with a different scene modifier — not a second copy of the app.
@main
struct FediqoApp: App {
    /// Built here rather than inside the root view, because the menu bar is part of the
    /// scene and not part of the view tree: the menu and the screens have to be steering the
    /// same app, so there is one of it and the scene holds it.
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            FediqoRootView(app: app)
        }
        #if os(macOS)
        // .contentSize would pin the window to whatever the views want and refuse to shrink.
        // .contentMinSize lets it go as small as the shell says it can, and no smaller.
        .windowResizability(.contentMinSize)
        .commands { FediqoCommands(app: app) }
        #endif
    }
}
