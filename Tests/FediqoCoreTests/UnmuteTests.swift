import Foundation
import Testing
@testable import FediqoCore

/// Letting a mute go (#114).
///
/// **The one state this app could enter and not leave.** A muted author's posts do not appear,
/// so the menu that muted them cannot be reached again — every layer here took `muted: false`
/// and nothing above ever passed it.
@Suite("A mute you can take back")
struct UnmuteTests {
    @Test("What is muted is written down, and letting it go takes it off")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        try await store.mute(.author, "https://a.example/users/loud", muted: true)
        #expect(try await store.mutes().map(\.value) == ["https://a.example/users/loud"])

        try await store.mute(.author, "https://a.example/users/loud", muted: false)
        #expect(try await store.mutes().isEmpty)
    }

    /// **Two rows and not a flag**, which is what lets this app always say which of the two hid
    /// something — so letting one go must not take the other with it.
    @Test("Undoing one place leaves the other standing")
    func twoPlaces() async throws {
        let store = try LocalStore.inMemory()
        // A mute a server is carrying out names that server, and a server has to be one this
        // device has heard of — which is the foreign key saying the same thing.
        let mine = Server(host: "mine.example", socialProtocol: .mastodon)
        try await store.save([makePost(uri: "https://mine.example/1", at: 1, from: "mine.example")],
                             from: mine)
        let who = "https://a.example/users/loud"
        try await store.mute(.author, who, muted: true)
        try await store.mute(.author, who, on: mine.endpoint, muted: true)
        #expect(try await store.mutes().count == 2)

        // The device's own, let go. The server is still carrying its own out.
        try await store.mute(.author, who, muted: false)
        let left = try await store.mutes()
        #expect(left.count == 1)
        #expect(left.first?.isLocal == false)
        #expect(left.first?.serverURL == mine.endpoint)
    }

    /// A host and an author are different things to have muted, and undoing one is not undoing
    /// the other even where the words look alike.
    @Test("A host and an author are muted apart")
    func hostAndAuthor() async throws {
        let store = try LocalStore.inMemory()
        try await store.mute(.host, "loud.example", muted: true)
        try await store.mute(.author, "https://loud.example/users/a", muted: true)

        try await store.mute(.host, "loud.example", muted: false)
        #expect(try await store.mutes().map(\.kind) == [.author])
    }

    /// Letting go of something that was never muted is not an error and not a second row: the
    /// reader pressing undo twice has undone it once.
    @Test("Undoing what was never done changes nothing")
    func undoingNothing() async throws {
        let store = try LocalStore.inMemory()
        try await store.mute(.author, "https://a.example/users/quiet", muted: false)
        #expect(try await store.mutes().isEmpty)
    }
}
