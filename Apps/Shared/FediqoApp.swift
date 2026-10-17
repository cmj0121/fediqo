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
/// is the save a backgrounding runs.
///
/// **There is none until the store has been opened** (#344), and it is made from what was
/// opened: a launch behind a locked device waits (`StoreGate`), and nothing here — no session,
/// no saver — exists to run without the store and then write its emptiness over it. So
/// `shared` is nil until then, whoever asks: a quit or a backgrounding before the first frame
/// finds nothing to save, where it once built all of this itself. Made once; a second making
/// is a mistake in the app, and stops it.
@MainActor
final class Launch {
    private(set) static var shared: Launch?

    /// The one gate of this run, made at the first evaluation of a body — once the app object
    /// exists, which the platform's signals ask — and never from a static or the app's own
    /// initializer.
    private static var gate: StoreGate?
    /// Whether the walk of everything outside the store's folder has been set going.
    private static var walked = false

    /// The run, where the store could be opened at once — every ordinary launch, before the
    /// first frame — and nothing where the device is locked.
    static func atOnce() -> Launch? {
        shared ?? opening().opened.map { make($0) }
    }

    /// The run, once the store can be opened: waited for where the device is locked.
    static func whenOpened() async -> Launch? {
        let gate = opening()
        await gate.wait()
        return shared ?? gate.opened.map { make($0) }
    }

    private static func make(_ opened: StoreFile.Opened) -> Launch {
        precondition(shared == nil, "the store is opened, and the run made of it, once")
        let made = Launch(opened)
        shared = made
        return made
    }

    private static func opening() -> StoreGate {
        if let gate { return gate }
        let directory = StoreFile.applicationSupportDirectory
        let protected = ProtectedSignals.protected(store: directory)
        let made = StoreGate(
            protected: protected, waits: ProtectedSignals.waits, unlockedForSomebody: ProtectedSignals.unlockedForSomebody
        ) { unlocked in
            // First of all (#344): the store's folder, the canary, and the folders the system
            // writes into are at the class before anything here opens, reads or writes a file —
            // and what an earlier build left beside the index is brought to it before the index
            // is opened. The walk of everything else is nothing a first frame waits for.
            ProtectedFolders.first()
            // Once a run, however many times the gate comes to ask.
            if !walked {
                walked = true
                Task.detached(priority: .utility) { ProtectedFolders.rest() }
            }
            // What a take-away or a read back that was killed midway left on disk goes next
            // (#247): a plaintext index in scratch is nothing a later run reads. Only where the
            // canary reads — the sweep asks it.
            let media = try? MediaCache.caches()
            StorePackager.sweepLeftovers(directory: directory, media: media?.location, protected: protected)
            return StoreFile.openApplicationSupport(protected: protected, unlocked: unlocked)
        }
        gate = made
        return made
    }

    let store: ItemStore
    let forums: ForumSessions
    let mastodon: MastodonSessions
    let saver: StoreSaver
    /// What takes the store away as one locked file and reads one back (#247). Built on what
    /// this launch opened, so it writes the index this run writes and replaces it in place.
    let carrier: StorePackager
    /// Whether what this device keeps can be read: the canary the gate asked.
    private let protected: ProtectedData
    /// The index on disk, measured for Usage (#194); nil where this run has none.
    let file: StoreFile?
    /// The words index's build (#360), begun once the timeline shows; nil where this run has no
    /// index.
    let words: WordsBuilder?
    /// The limits' account beside the index (#251); nil where the folder could not be made.
    let limits: LimitAccountFile?
    /// The person's own lists beside the index (#344): what may be reached beyond a source,
    /// and the timelines they wrote. Read in every kind of run, with a store or without.
    let lists: ListFiles
    /// The index was written by a newer build and left alone; the root view says so. Cleared when
    /// the reader dismisses that, so it is said once a launch rather than once a window.
    var storeIsNewer: Bool
    /// What the person is to be told about the store, where it did not simply open (#295); the
    /// root view says so. Cleared when they answer, so it is said once a launch.
    var storeTrouble: StoreTrouble?
    /// Whether the store this run holds is the one on disk, read whole: not where it could not
    /// be opened, was a newer build's, or was damaged and replaced this launch. Every sweep that
    /// keeps "the sources' own" and lets the rest go asks this first (#295): a run with no
    /// sources to name would otherwise let go of everything.
    let storeRead: Bool

    /// Built from what the gate opened, on the main actor, before the first frame that shows
    /// anything: the sources, what each said, the texts and the notices — and no row, so it is
    /// quick whatever the store weighs (#357). The rows are the file's, read by the pages.
    private init(_ opened: StoreFile.Opened) {
        // **The very first write of the run** (#357): the pages' index, made where an older
        // build's file lacks it, off the main actor and with nothing queued on the file ahead of
        // it — the first page waits for it, and for nothing else. The rest wait for the timeline
        // to show (`afterFirstPage`).
        if let file = opened.file {
            Task.detached(priority: .userInitiated) { try? await file.makePageIndex() }
        }
        // Where Caches cannot be made, pictures are read from their hyperlinks only.
        let media = try? MediaCache.caches()
        // The one the gate asked: made once for the store, and the same one here.
        let protected = ProtectedSignals.protected(store: StoreFile.applicationSupportDirectory)
        self.protected = protected
        store = Self.store(of: opened)
        // `nil` when the index could not be read and could not be set aside either: this run
        // then saves nothing, so what is on disk survives it (`StoreFile.open(at:now:)`).
        // It is also `nil` when the index was written by a newer build, which is left as found.
        saver = StoreSaver(store: store, file: opened.file, protected: protected)
        file = opened.file
        words = opened.file.map { WordsBuilder(file: $0, saver: saver, protected: protected) }
        // Only beside an index this run writes: a run that must not write the index (a newer
        // build's, or one that could not be set aside) writes no lines about it either.
        limits = opened.file == nil ? nil : try? LimitAccountFile(directory: StoreFile.applicationSupportDirectory)
        storeIsNewer = opened.storeIsNewer
        storeTrouble = opened.trouble
        storeRead = opened.file != nil && opened.setAside == nil
        carrier = StorePackager(
            directory: StoreFile.applicationSupportDirectory, file: opened.file, store: store,
            media: media, tokens: KeychainMastodonTokens(), credentials: KeychainCredentials(),
            defaults: .standard, device: Self.deviceName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            storeIsNewer: opened.storeIsNewer,
            storeNotOpened: opened.file == nil && !opened.storeIsNewer, saver: saver, protected: protected
        )
        // An undo a lock refused is still owed (#344), and done when the device is back: each
        // wake-up asks, and the carrier asks the canary itself before it does anything.
        // And a save a lock refused is written then: the saver asks the canary, counts its
        // tries afresh and saves at once.
        Task { [carrier, saver] in
            for await _ in protected.changes() {
                await carrier.finishOwed()
                await saver.owedNow()
            }
        }
        // Before anything is asked: every act from here on belongs to one of these, or to a host
        // the person names to add (#220).
        lists = ListFiles(directory: StoreFile.applicationSupportDirectory, defaults: .standard, protected: protected)
        FediqoRootView.onlyToSources(
            opened.sources.map(\.host), kept: store, read: opened.file != nil && opened.setAside == nil,
            lists: lists
        )
        // Built on first use only: a reader with no forum never opens the WebKit store.
        let sessions = ForumSessions(dataStore: ForumWebsiteData.onDevice())
        sessions.sourcesRead = storeRead
        forums = sessions
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
        if let media {
            FediqoRootView.keepPictures(in: media, for: opened.sources.map(\.host), read: storeRead)
        }
        // The store is saved behind every change from here on, on the saver's own actor. Started
        // here and not by a window: one closed must not stop the saving, and nothing ends this
        // but the run ending, which flushes (`end()`).
        Task { [saver] in await saver.follow() }
    }

    /// The run's store, made of what was opened. **No row was read** (#357): a pool over the
    /// file, each row read once it is wanted — a page of the timeline in front, a row a landing
    /// merges with — and a save writes only what changes from here. With no file there is
    /// nothing to read, and the store holds what this run brings.
    private static func store(of opened: StoreFile.Opened) -> ItemStore {
        guard let file = opened.file else {
            return ItemStore(
                sources: opened.sources, notes: [], said: opened.said, notices: opened.notices,
                unsent: opened.unsent, readFromDisk: true
            )
        }
        return ItemStore(
            sources: opened.sources, said: opened.said, notices: opened.notices, unsent: opened.unsent, rows: file
        )
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
        await forgetChangedReaders()
        _ = await saver.flush()
        // The words' build stood down for good: a write of it left is one chunk, where a save would run.
        await words?.end()
        let hosts = await store.sources().map(\.host)
        // Nothing where this run never read the store: `ForumSessions.sourcesRead`.
        await forums.leaveNothing(keeping: hosts, within: StoreSaver.deadline)
    }

    /// What a source said of, and to, a reader whose sign-in has ended, let go from the store
    /// before the save that follows — the sweep a session queues for it (`forgetReaderMarksDue`)
    /// may not have run when the app is left or quit, and its notices would then stay on disk
    /// until the next launch (#292). The store's part only, and not taken from the session,
    /// whose own sweep still does the rest. **Bounded**: a step in memory a host, with no
    /// request and no write; the write is the flush after it, which answers by
    /// `StoreSaver.deadline`. **Not covered by a test**: nothing tests the app target; what it
    /// calls (`ItemStore.forgetReaderMarks`, the flush) is tested where it lives.
    private func forgetChangedReaders() async {
        for host in mastodon.readersChangedWaiting.sorted() {
            await store.forgetReaderMarks(host: host)
        }
    }

    /// As the app goes to the background, which may be a moment away to a password manager in the
    /// middle of a sign-in: the save, and only the forum browser's copies of what it fetched. The
    /// rest waits for the quit, or for the next launch's sweep.
    #if os(iOS)
    /// **On a phone** this is the last the app does before the device may lock (#344): the
    /// save first and to its end, under the grant the caller already holds, and the cache
    /// dropped only where there is still time and a device to do it on (`Leaving`).
    func pause(holding grant: any BackgroundGranting) async {
        await Leaving.leave(
            holding: grant, decide: { await forgetChangedReaders() }, saver: saver, protected: protected,
            stillLeft: { UIApplication.shared.applicationState != .active },
            then: { await forums.dropCache(within: StoreSaver.deadline) }
        )
    }
    #else
    /// **A Mac has no leaving step for a lock, and needs none**: nothing announces one, its
    /// app is not suspended behind a locked screen, and a save goes through the lock on the
    /// connection it holds. Where a phase is delivered at all, this is what it always was.
    func pause() async {
        await forgetChangedReaders()
        _ = await saver.flush()
        await forums.dropCache(within: StoreSaver.deadline)
    }
    #endif
}

#if os(macOS)
/// Cmd+Q on a Mac often never delivers `scenePhase == .background`, and a fire-and-forget Task
/// is cancelled when the process exits. Termination waits for the write — up to
/// `StoreSaver.deadline`, and then quits anyway.
@MainActor
final class FediqoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        // A launch made for a picture opened nothing, so it has nothing to save or sweep.
        if Staged.isOn { return .terminateNow }
        #endif
        Task {
            await Launch.shared?.end()
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
        #if DEBUG
        // A launch made for a picture opened nothing, so it has nothing to save or sweep.
        if Staged.isOn {
            finished = true
            return
        }
        #endif
        ending = Task { @MainActor in
            await Launch.shared?.end()
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

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if Staged.isOn { Staged.root } else { Opening() }
                #else
                Opening()
                #endif
            }
            // The window's own ground is the page's, so what shows before the first frame and
            // at the edge of a window being dragged wider is not the system's grey. `Ground` is
            // the catalogue's copy of `ShellChrome.page`, the one a phone's launch screen names.
            #if os(macOS)
            .containerBackground(Color("Ground"), for: .window)
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }
}

/// What a window shows until this run has its store (#344): on every ordinary launch that is
/// no time at all, and the app is drawn in the first frame as it always was. Behind a locked
/// device it is the launch ground and nothing else — no words — until the device is unlocked.
/// Apart from the app's own body so that a launch made for a picture (`Staged`) can stand in
/// its place without the store ever being asked for.
private struct Opening: View {
    @State private var launch = Launch.atOnce()

    var body: some View {
        if let launch {
            Live(launch: launch)
        } else {
            Waiting { launch = $0 }
        }
    }
}

/// The launch ground, while the store waits for the device to be unlocked. **Anything a person
/// does to it asks again**: the system's own notices of an unlock are wake-ups nobody has
/// promised, and a finger, a key or a pointer on the app is proof of somebody in front of it.
private struct Waiting: View {
    let opened: (Launch?) -> Void
    #if os(macOS)
    @State private var listening: Any?
    #endif

    var body: some View {
        Color("Ground").ignoresSafeArea()
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in ProtectedSignals.somebodyIsHere() })
            #if os(macOS)
            .onAppear {
                // One at a time: a ground shown again without having gone would leave the first.
                ProtectedSignals.stop(listening)
                listening = ProtectedSignals.listenForSomebody()
            }
            .onDisappear { ProtectedSignals.stop(listening) }
            #endif
            .task { opened(await Launch.whenOpened()) }
    }
}

/// The app as a person launches it, once its store is open.
private struct Live: View {
    let launch: Launch
    @Environment(\.scenePhase) private var scenePhase

    /// The index's one measure on disk (#194), or nothing where this run has no index.
    private var measureStore: (@Sendable () async -> Int)? {
        guard let file = launch.file else { return nil }
        return { file.bytesOnDisk() }
    }

    /// Gives the index back what rows let go of left in it (#249), or nothing where this run
    /// has no index.
    private var compactStore: (@Sendable () async throws -> Void)? {
        guard let file = launch.file else { return nil }
        let saver = launch.saver
        // Where a save would run: after every save asked for before it and before any after,
        // and never inside a read back's commit, which holds the same place (#247).
        return { try await saver.exclusively { try await file.compact() } }
    }

    /// One page of a timeline read from the index (#357), or nothing where this run has none: the
    /// store then holds every row there is, and nothing is paged.
    private var readPage: (@Sendable (PageQuery, PageAsk, Int) async throws -> Page)? {
        guard let file = launch.file else { return nil }
        return { query, ask, limit in try await file.page(query, ask, limit: limit) }
    }

    /// One page of what a search finds in a timeline, read from the index (#360), or nothing where
    /// this run has none: the search then reads what is held, which is everything.
    private var readSearch: (@Sendable (PageQuery, NoteSearch, PageAsk, Int) async throws -> Page?)? {
        guard let file = launch.file else { return nil }
        return { query, search, ask, limit in try await file.search(query, search, ask, limit: limit) }
    }

    /// A provisional first page (C15), read beside the index's pages' index while a first launch
    /// after an older build makes it, and nothing once it is made.
    private var readEarly: (@Sendable (PageQuery, Int) async throws -> Page?)? {
        guard let file = launch.file else { return nil }
        return { query, limit in try await file.provisionalPage(query, limit: limit) }
    }

    /// What waits for the timeline to show (C1): the indexes the reads by key and the lettings go
    /// go by, made where an older build's file lacks them, and then the index's free pages
    /// scrubbed, where they are due, where a save would run.
    private var afterFirstPage: (@Sendable () async -> Void)? {
        guard let file = launch.file else { return nil }
        let saver = launch.saver
        let words = launch.words
        return {
            try? await file.makeIndexes(in: saver)
            _ = try? await saver.exclusively { await file.scrubIfDue() }
            // The words index (#360), built a chunk at a time behind everything else and waited
            // for by nothing: until it is, a keyword reads as it did.
            await words?.begin()
        }
    }

    /// What the rows held weigh, whatever the file does (#249); nothing where this run has no index.
    private var weighStore: (@Sendable () async -> Int)? {
        guard let file = launch.file else { return nil }
        return { file.bytesHeld() }
    }

    var body: some View {
        FediqoRootView(
            store: launch.store, forums: launch.forums,
            mastodon: launch.mastodon, persist: save, persistUnsent: saveUnsent,
            savesLanded: { [saver = launch.saver] in await saver.landings() },
            measureStore: measureStore, compactStore: compactStore, weighStore: weighStore,
            readPage: readPage, readEarly: readEarly, readSearch: readSearch, afterFirstPage: afterFirstPage,
            limits: launch.limits,
            storeIsNewer: launch.storeIsNewer,
            storeNoticeSeen: { launch.storeIsNewer = false },
            storeTrouble: launch.storeTrouble,
            storeTroubleAnswered: { answer in
                guard let trouble = launch.storeTrouble else { return }
                launch.storeTrouble = nil
                Task {
                    await launch.saver.answered(
                        answer, to: trouble, in: StoreFile.applicationSupportDirectory
                    )
                }
            },
            carrier: launch.carrier,
            storeWritable: launch.file != nil,
            lists: launch.lists,
            nearby: NWNearbyLink(), deviceName: Launch.deviceName
        )
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                saveInBackground()
            }
        }
    }

    /// Whether the write happened: no where it failed — the saver has logged it, and owes
    /// another try by itself (`StoreSaver.follow`) — which an act that takes something off
    /// this device tells the person (`ShellSession.saveNow`). A run with no store to write
    /// has no file for anything to be left in, and its save is the logged no-op it always was.
    private func save() async -> Bool {
        (try? await launch.saver.save()) != nil
    }

    /// Only what the person pressed to send (`StoreSaver.saveUnsent`): awaited by a send before
    /// its request leaves, and answered with whether the texts are on disk — no where the write
    /// failed, which the saver has logged, and where this run has no store to write.
    private func saveUnsent() async -> Bool {
        (try? await launch.saver.saveUnsent()) ?? false
    }

    /// On iOS a backgrounded app is suspended within moments, which would stop a write halfway:
    /// the background task asks for the time to finish it, and is given back when leaving is
    /// done — the save having run to its end, not to a deadline — or when the system takes it.
    private func saveInBackground() {
        #if os(iOS)
        // Taken now, as the app is told, and not a turn of the run loop later: everything
        // leaving does is done under it, and it is given back there (`Leaving`).
        let grant = BackgroundGrant()
        Task { await launch.pause(holding: grant) }
        #else
        Task { await launch.pause() }
        #endif
    }
}

#if os(iOS)
/// One background task, ended exactly once: when leaving is done, or when the system runs out
/// of patience first.
@MainActor
private final class BackgroundGrant: BackgroundGranting {
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
