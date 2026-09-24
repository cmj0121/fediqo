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
    let mastodon: MastodonSessions
    let saver: StoreSaver
    /// The index was written by a newer build and left alone; the root view says so. Cleared when
    /// the reader dismisses that, so it is said once a launch rather than once a window.
    var storeIsNewer: Bool

    /// The index is opened and read here, on the main actor, before the first frame. Moving it
    /// off would leave the store empty while the first frame draws, and every save asked for in
    /// that gap would have to be held back or it would write the empty store over the index.
    private init() {
        let opened = StoreFile.openApplicationSupport()
        store = ItemStore(sources: opened.sources, notes: opened.notes)
        // `nil` when the index could not be read and could not be set aside either: this run
        // then saves nothing, so what is on disk survives it (`StoreFile.open(at:now:)`).
        // It is also `nil` when the index was written by a newer build, which is left as found.
        saver = StoreSaver(store: store, file: opened.file)
        storeIsNewer = opened.storeIsNewer
        // Before anything is asked: every act from here on belongs to one of these, or to a host
        // the person names to add (#220).
        FediqoRootView.onlyToSources(opened.sources.map(\.host))
        // Built on first use only: a reader with no forum never opens the WebKit store.
        forums = ForumSessions(dataStore: ForumWebsiteData.onDevice())
        // Signed in is what the Keychain holds; each server is asked once a launch whether it
        // still honours its token, in the background, and only a 401 signs out.
        mastodon = MastodonSessions(tokens: KeychainMastodonTokens())
        Task { [mastodon] in await mastodon.verifyAll() }
        // And each forum whose sign-in did not outlive the last run, and whose username and
        // password the reader kept, signs in again by itself (#153) — registered here, before the
        // first frame, so a post read a moment later waits for it rather than asking as a guest.
        // What an older build left in the system's shared network stores goes, once (#219); and
        // what an earlier run left in the forum browser's store is swept before anything reads it.
        SharedStores.forgetOnce()
        forums.sweepAtLaunch(
            keeping: opened.sources.map(\.host), onDisk: ForumWebsiteData.isOnDisk()
        )
        forums.signInAgain(hosts: opened.sources.filter { $0.kind == .discuz }.map(\.host))
        // Where Caches cannot be made, pictures are read from their hyperlinks only.
        if let media = try? MediaCache.caches() {
            FediqoRootView.keepPictures(in: media, for: opened.sources.map(\.host))
        }
    }

    /// As a run ends: the save, and then nothing of where this run went left behind (#219) — the
    /// forum browser's store keeps its sources' sign-ins and nothing else. Bounded like the save,
    /// so a WebKit that stops answering cannot hold a quit up.
    func end() async {
        _ = await saver.flush()
        let hosts = await store.sources().map(\.host)
        await forums.leaveNothing(keeping: hosts, within: StoreSaver.deadline)
    }

    /// As the app goes to the background, which may be a moment away to a password manager in the
    /// middle of a sign-in: the save, and only the forum browser's copies of what it fetched. The
    /// rest waits for the quit, or for the next launch's sweep.
    func pause() async {
        _ = await saver.flush()
        await forums.dropCache(within: StoreSaver.deadline)
    }
}

#if os(macOS)
/// Cmd+Q on a Mac often never delivers `scenePhase == .background`, and a fire-and-forget Task
/// is cancelled when the process exits. Termination waits for the write — up to
/// `StoreSaver.deadline`, and then quits anyway.
@MainActor
final class FediqoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await Launch.shared.end()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`.
@main
struct FediqoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(FediqoAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FediqoRootView(
                store: Launch.shared.store, forums: Launch.shared.forums,
                mastodon: Launch.shared.mastodon, persist: save,
                storeIsNewer: Launch.shared.storeIsNewer,
                storeNoticeSeen: { Launch.shared.storeIsNewer = false }
            )
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
        try? await Launch.shared.saver.save()
    }

    /// On iOS a backgrounded app is suspended within moments, which would stop a write halfway;
    /// the background task asks for the time to finish it, and gives it back as soon as it has —
    /// or at the deadline, the same one a quit has.
    private func saveInBackground() {
        #if os(iOS)
        let grant = BackgroundGrant()
        #endif
        Task {
            await Launch.shared.pause()
            #if os(iOS)
            grant.end()
            #endif
        }
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
