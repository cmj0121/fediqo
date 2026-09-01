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

    #if os(iOS)
    /// Whether the app is in front. The only thing this file does with it is ask the system
    /// to wake us later, on the way out — there is nothing to schedule while somebody is
    /// looking, because the connections are already open and hearing everything.
    @Environment(\.scenePhase) private var phase
    #endif

    var body: some Scene {
        WindowGroup {
            FediqoRootView(app: app)
        }
        #if os(iOS)
        // #9: no push server, no third party, no registration. The app asks iOS to wake it,
        // iOS decides when, and what it does when woken is exactly what a reconnect does —
        // read what happened since the last event this device saw. Then it asks again, because
        // a wake that does not schedule the next one is the last wake there will ever be.
        .backgroundTask(.appRefresh(AppState.noticeRefresh)) {
            await app.catchUpOnNotices()
            await AppState.scheduleNoticeRefresh()
        }
        .onChange(of: phase) { _, now in
            if now == .background { AppState.scheduleNoticeRefresh() }
        }
        #endif
        #if os(macOS)
        // .contentSize would pin the window to whatever the views want and refuse to shrink.
        // .contentMinSize lets it go as small as the shell says it can, and no smaller.
        .windowResizability(.contentMinSize)
        .commands { FediqoCommands(app: app) }
        #endif
    }
}
