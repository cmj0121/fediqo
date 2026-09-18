import FediqoCore
import FediqoPersistence
import FediqoUI
import SwiftUI

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`.
@main
struct FediqoApp: App {
    private let store: ItemStore
    private let file: StoreFile?
    private let forums: ForumSessions
    @Environment(\.scenePhase) private var scenePhase

    /// `file` is `nil` when the index could not be read and could not be set aside either:
    /// this run then saves nothing, so what is on disk survives it (`StoreFile.open(at:now:)`).
    init() {
        let opened = StoreFile.openApplicationSupport()
        let forums = ForumSessions(dataStore: ForumSessions.deviceDataStore())
        self.file = opened.file
        self.store = ItemStore(sources: opened.sources, notes: opened.notes)
        self.forums = forums
        // Which forums are still signed in is read off the cookies this device kept, not off
        // the index: the index is not where a secret lives (#5).
        let forumHosts = opened.sources.filter { $0.kind == .discuz }.map(\.host)
        Task { await forums.restoreSignIns(among: forumHosts) }
        // Where Caches cannot be made, pictures are read from their hyperlinks only.
        if let media = try? MediaCache.caches() {
            FediqoRootView.keepPictures(in: media, for: opened.sources.map(\.host))
        }
    }

    var body: some Scene {
        WindowGroup {
            FediqoRootView(store: store, forums: forums)
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
