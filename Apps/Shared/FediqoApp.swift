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
    /// What takes the store away as one locked file and reads one back (#247). Built on what
    /// this launch opened, so it writes the index this run writes and replaces it in place.
    let carrier: StorePackager
    /// The index on disk, measured for Usage (#194); nil where this run has none.
    let file: StoreFile?
    /// The limits' account beside the index (#251); nil where the folder could not be made.
    let limits: LimitAccountFile?
    /// The index was written by a newer build and left alone; the root view says so. Cleared when
    /// the reader dismisses that, so it is said once a launch rather than once a window.
    var storeIsNewer: Bool

    /// The index is opened and read here, on the main actor, before the first frame. Moving it
    /// off would leave the store empty while the first frame draws, and every save asked for in
    /// that gap would have to be held back or it would write the empty store over the index.
    private init() {
        // What a take-away or a read back that was killed midway left on disk goes first (#247):
        // a plaintext index in scratch is nothing a later run reads.
        let media = try? MediaCache.caches()
        StorePackager.sweepLeftovers(directory: StoreFile.applicationSupportDirectory, media: media?.location)
        let opened = StoreFile.openApplicationSupport()
        store = ItemStore(sources: opened.sources, notes: opened.notes, said: opened.said)
        // `nil` when the index could not be read and could not be set aside either: this run
        // then saves nothing, so what is on disk survives it (`StoreFile.open(at:now:)`).
        // It is also `nil` when the index was written by a newer build, which is left as found.
        saver = StoreSaver(store: store, file: opened.file)
        file = opened.file
        // Only beside an index this run writes: a run that must not write the index (a newer
        // build's, or one that could not be set aside) writes no lines about it either.
        limits = opened.file == nil ? nil : try? LimitAccountFile(directory: StoreFile.applicationSupportDirectory)
        storeIsNewer = opened.storeIsNewer
        carrier = StorePackager(
            directory: StoreFile.applicationSupportDirectory, file: opened.file, store: store,
            media: media, tokens: KeychainMastodonTokens(), credentials: KeychainCredentials(),
            defaults: .standard, device: Self.deviceName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            storeIsNewer: opened.storeIsNewer, saver: saver
        )
        // Before anything is asked: every act from here on belongs to one of these, or to a host
        // the person names to add (#220).
        FediqoRootView.onlyToSources(
            opened.sources.map(\.host), kept: store, read: opened.file != nil && opened.setAside == nil
        )
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
            keeping: opened.sources.map(\.host), onDisk: ForumWebsiteData.isOnDisk(),
            within: StoreSaver.deadline
        )
        forums.signInAgain(hosts: opened.sources.filter { $0.kind == .discuz }.map(\.host))
        // Where Caches cannot be made, pictures are read from their hyperlinks only.
        if let media {
            FediqoRootView.keepPictures(in: media, for: opened.sources.map(\.host))
        }
    }

    /// What this device calls itself, written into a take-away's header so the device it came
    /// from can be named when it is read back.
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
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
#elseif os(iOS)
/// An iPhone is seldom told it is quitting: a suspended app is killed without a word, and then the
/// forum browser's store is swept at the next launch (`ForumSessions.sweepAtLaunch`). Where the
/// system does say so — the app ends while running, or its last scene is let go — the whole of
/// `end()` runs, bounded by the save's deadline, so the store is swept then and not a launch later.
@MainActor
final class FediqoAppDelegate: NSObject, UIApplicationDelegate {
    /// The one end of this run, whichever of the two ways in asked first: `end()` runs once.
    private var ending: Task<Void, Never>?
    private var finished = false

    private func endOnce() {
        guard ending == nil else { return }
        ending = Task { @MainActor in
            await Launch.shared.end()
            self.finished = true
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: nil, queue: .main
        ) { note in
            let gone = note.object as? UIScene
            MainActor.assumeIsolated {
                let left = UIApplication.shared.connectedScenes.filter { $0 !== gone }
                guard left.isEmpty else { return }
                self.endOnce()
            }
        }
        return true
    }

    /// **Best effort.** Called on the main thread with a few seconds left and nothing awaited
    /// after it returns, so the run loop is turned here until `end()` is done or four seconds
    /// pass; the system may end the process sooner, and then the next launch sweeps.
    func applicationWillTerminate(_ application: UIApplication) {
        endOnce()
        let until = Date().addingTimeInterval(4)
        while !finished, Date() < until {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
#endif

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`.
@main
struct FediqoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(FediqoAppDelegate.self) private var appDelegate
    #elseif os(iOS)
    @UIApplicationDelegateAdaptor(FediqoAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    /// The index's one measure on disk (#194), or nothing where this run has no index.
    private var measureStore: (@Sendable () async -> Int)? {
        guard let file = Launch.shared.file else { return nil }
        return { file.bytesOnDisk() }
    }

    /// Gives the index back what rows let go of left in it (#249), or nothing where this run
    /// has no index.
    private var compactStore: (@Sendable () async throws -> Void)? {
        guard let file = Launch.shared.file else { return nil }
        let saver = Launch.shared.saver
        // Where a save would run: after every save asked for before it and before any after,
        // and never inside a read back's commit, which holds the same place (#247).
        return { try await saver.exclusively { try await file.compact() } }
    }

    /// What the rows held weigh, whatever the file does (#249); nothing where this run has no index.
    private var weighStore: (@Sendable () async -> Int)? {
        guard let file = Launch.shared.file else { return nil }
        return { file.bytesHeld() }
    }

    var body: some Scene {
        WindowGroup {
            FediqoRootView(
                store: Launch.shared.store, forums: Launch.shared.forums,
                mastodon: Launch.shared.mastodon, persist: save,
                measureStore: measureStore, compactStore: compactStore, weighStore: weighStore,
                limits: Launch.shared.limits,
                storeIsNewer: Launch.shared.storeIsNewer,
                storeNoticeSeen: { Launch.shared.storeIsNewer = false },
                carrier: Launch.shared.carrier,
                nearby: NWNearbyLink(), deviceName: Launch.deviceName
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
