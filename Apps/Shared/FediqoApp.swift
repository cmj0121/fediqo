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

    /// `file` is `nil` when the index could not be read and could not be set aside either:
    /// this run then saves nothing, so what is on disk survives it (`StoreFile.open(at:now:)`).
    init() {
        let opened = StoreFile.openApplicationSupport()
        self.file = opened.file
        self.store = ItemStore(sources: opened.sources, notes: opened.notes)
        // Built on first use only: a reader with no forum never opens the WebKit store.
        self.forums = ForumSessions(dataStore: ForumWebsiteData.onDevice())
        // Where Caches cannot be made, pictures are read from their hyperlinks only.
        if let media = try? MediaCache.caches() {
            FediqoRootView.keepPictures(in: media, for: opened.sources.map(\.host))
        }
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
        let snapshot = await store.snapshot()
        try? file?.save(sources: snapshot.sources, notes: snapshot.notes)
    }
}
