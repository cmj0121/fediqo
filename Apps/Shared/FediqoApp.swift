import SwiftUI
import FediqoUI

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`,
/// so iOS is this same file with a different scene modifier — not a second copy of the app.
@main
struct FediqoApp: App {
    var body: some Scene {
        WindowGroup {
            FediqoRootView()
        }
        #if os(macOS)
        // .contentSize would pin the window to whatever the views want and refuse to shrink.
        // .contentMinSize lets it go as small as the shell says it can, and no smaller.
        .windowResizability(.contentMinSize)
        .commands {
            // Nothing here makes a document, so the File > New that AppKit assumes is a lie.
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
