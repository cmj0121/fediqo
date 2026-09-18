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

    /// `file` is `nil` when the index could not be read and could not be set aside either:
    /// this run then saves nothing, so what is on disk survives it (`StoreFile.open(at:now:)`).
    init() {
        let opened = StoreFile.openApplicationSupport()
        self.file = opened.file
        self.store = ItemStore(sources: opened.sources, notes: opened.notes)
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
