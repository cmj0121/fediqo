import SwiftUI
import FediqoUI

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`.
@main
struct FediqoApp: App {
    var body: some Scene {
        WindowGroup {
            FediqoRootView()
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }
}
