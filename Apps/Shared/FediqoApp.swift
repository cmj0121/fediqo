import FediqoCore
import FediqoPersistence
import FediqoUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// Cmd+Q on a Mac often never delivers `scenePhase == .background`, and a
/// fire-and-forget Task is cancelled when the process exits. Termination
/// waits until the write returns.
@MainActor
final class FediqoAppDelegate: NSObject, NSApplicationDelegate {
    static var save: (@MainActor () async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let save = Self.save else { return .terminateNow }
        PersistOnQuit.holdUntilSaved(save: save) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`.
@main
struct FediqoApp: App {
    private let store: ItemStore
    private let file: StoreFile?
    private let forums: ForumSessions
    #if os(macOS)
    @NSApplicationDelegateAdaptor(FediqoAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let file = try? StoreFile.applicationSupport()
        let snapshot = (try? file?.load()) ?? (sources: [], notes: [])
        let signedIn = (try? file?.loadSignedIn()) ?? []
        self.file = file
        self.store = ItemStore(sources: snapshot.sources, notes: snapshot.notes)
        self.forums = ForumSessions(persistentCookies: true, reached: signedIn)
        #if os(macOS)
        FediqoAppDelegate.save = save
        #endif
    }

    var body: some Scene {
        WindowGroup {
            FediqoRootView(store: store, forums: forums, persist: save)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        Task { await save() }
                    }
                }
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }

    private func save() async {
        let sources = await store.sources()
        let notes = await store.all()
        try? file?.save(sources: sources, notes: notes)
        try? file?.saveSignedIn(forums.reachedHosts)
    }
}
