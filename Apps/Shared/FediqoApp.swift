import FediqoCore
import FediqoPersistence
import FediqoUI
import SwiftUI

/// The app entry, shared by every platform host. Everything it shows lives in `FediqoUI`.
@main
struct FediqoApp: App {
    private let store: ItemStore
    private let file: StoreFile?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let file = try? StoreFile.applicationSupport()
        let snapshot = (try? file?.load()) ?? (sources: [], notes: [])
        self.file = file
        self.store = ItemStore(sources: snapshot.sources, notes: snapshot.notes)
    }

    var body: some Scene {
        WindowGroup {
            FediqoRootView(store: store)
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
    }
}
