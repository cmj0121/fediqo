import FediqoCore
import FediqoPersistence
import FediqoUI
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// What a launch read from disk, built once, and the one saver that writes it back.
///
/// **One instance, reached by the app and by its delegate alike**, so the save a quit waits for
/// is the save a backgrounding runs, and neither can find it unset: it is a constant made on
/// first use, not a slot something has to remember to fill.
@MainActor
final class Launch {
    static let shared = Launch()

    let store: ItemStore
    let forums: ForumSessions
    let saver: StoreSaver

    /// The index is opened and read here, on the main actor, before the first frame. Moving it
    /// off would leave the store empty while the first frame draws, and every save asked for in
    /// that gap would have to be held back or it would write the empty store over the index.
    private init() {
        let opened = StoreFile.openApplicationSupport()
        store = ItemStore(sources: opened.sources, notes: opened.notes)
        // `nil` when the index could not be read and could not be set aside either: this run
        // then saves nothing, so what is on disk survives it (`StoreFile.open(at:now:)`).
        saver = StoreSaver(store: store, index: opened.file)
        // Built on first use only: a reader with no forum never opens the WebKit store.
        forums = ForumSessions(dataStore: ForumWebsiteData.onDevice())
        // Where Caches cannot be made, pictures are read from their hyperlinks only.
        if let media = try? MediaCache.caches() {
            FediqoRootView.keepPictures(in: media, for: opened.sources.map(\.host))
        }
    }
}

#if os(macOS)
/// Cmd+Q on a Mac often never delivers `scenePhase == .background`, and a fire-and-forget Task
/// is cancelled when the process exits. Termination waits for the write — up to
/// `PersistOnQuit.deadline`, and then quits anyway.
@MainActor
final class FediqoAppDelegate: NSObject, NSApplicationDelegate {
    private let saver: StoreSaver

    override init() {
        saver = Launch.shared.saver
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let saver = saver
        PersistOnQuit.holdUntilSaved(save: { try await saver.save() }) { _ in
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`.
@main
struct FediqoApp: App {
    private let launch = Launch.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(FediqoAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FediqoRootView(store: launch.store, forums: launch.forums, persist: save)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        saveInBackground()
                    }
                }
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }

    /// A failure is already logged by the saver; there is nothing more to do about it here.
    private func save() async {
        try? await launch.saver.save()
    }

    /// On iOS a backgrounded app is suspended within moments, which would stop a write halfway;
    /// the background task asks for the time to finish it, and gives it back as soon as it has.
    private func saveInBackground() {
        #if os(iOS)
        let grant = BackgroundGrant()
        Task {
            await save()
            grant.end()
        }
        #else
        Task { await save() }
        #endif
    }
}

#if os(iOS)
/// One background task, ended exactly once: when the save returns, or when the system runs out
/// of patience first.
@MainActor
private final class BackgroundGrant {
    private var id = UIBackgroundTaskIdentifier.invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Save the index") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
