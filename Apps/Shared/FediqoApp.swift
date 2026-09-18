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
        let signedIn = (try? opened.file?.loadSignedIn()) ?? []
        self.file = opened.file
        self.store = ItemStore(sources: opened.sources, notes: opened.notes)
        self.forums = ForumSessions(persistentCookies: true, reached: signedIn)
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
        try? file?.saveSignedIn(forums.reachedHosts)
    }
}
