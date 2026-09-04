import Foundation
import Testing
import GRDB
@testable import FediqoCore

/// Leaving a server takes its posts with it (#117).
///
/// The load-bearing assertion is not that posts go. It is that **a post two servers handed over is
/// not one server's to take away**: it stays, with one fewer source. Getting that wrong is not a
/// missing feature, it is a reader losing posts a server they still read is still giving them.
@Suite("Leaving a server")
struct LeavingAServerTests {
    private func server(_ host: String) -> Server {
        Server(host: host, socialProtocol: .mastodon)
    }

    private func post(_ id: String, from host: String, at seconds: TimeInterval = 100) -> Post {
        makePost(uri: "https://\(host)/api/v1/statuses/\(id)",
                 originURI: "https://\(host)/users/a/statuses/\(id)",
                 at: seconds, from: host, text: id)
    }

    /// One post as a given server hands it over: that server's own copy, at that server's own
    /// address, of something written somewhere else.
    ///
    /// **Two servers carrying one post is two of these**, not one saved twice. The identity is
    /// `originURI` — where it was written — so both fold to one row, and each carries its own
    /// `sourceURL`, which is what an origin is recorded from. A single value saved twice would be
    /// one server handing the same thing over again, which is a different fact and the one this
    /// test is not about.
    private func copy(_ id: String, at host: String) -> Post {
        makePost(uri: "https://\(host)/api/v1/statuses/\(id)",
                 originURI: "https://elsewhere.example/users/a/statuses/\(id)",
                 at: 200, from: host, text: id)
    }

    private func timeline(_ store: LocalStore) async throws -> [Post] {
        try await store.timeline(matching: TimelineQuery(source: .public))
    }

    @Test("A post only that server gave leaves with it")
    func itsOwnPostsGo() async throws {
        let store = try LocalStore.inMemory()
        let leaving = server("leaving.example")
        try await store.save([post("1", from: "leaving.example")], from: leaving)
        #expect(try await timeline(store).count == 1)

        try await store.left(leaving)

        #expect(try await timeline(store).isEmpty)
    }

    /// **The one that matters.** A post both servers carried is still being given by the one that
    /// stays, and taking it away would be losing a post nobody stopped sending.
    @Test("A post two servers carried stays, with one fewer source")
    func acarriedPostStays() async throws {
        let store = try LocalStore.inMemory()
        let leaving = server("leaving.example")
        let staying = server("staying.example")
        try await store.save([copy("2", at: "leaving.example")], from: leaving)
        try await store.save([copy("2", at: "staying.example")], from: staying)
        #expect(try await timeline(store).first?.sources.count == 2)

        try await store.left(leaving)

        let left = try await timeline(store)
        #expect(left.count == 1)
        #expect(left.first?.sources == ["staying.example"])
    }

    /// Nothing else's arrivals are touched. A delete keyed on the wrong column would take the
    /// timeline apart quietly, and quietly is how it would stay.
    @Test("What another server gave is left alone")
    func othersAreUntouched() async throws {
        let store = try LocalStore.inMemory()
        let leaving = server("leaving.example")
        let staying = server("staying.example")
        try await store.save([post("3", from: "leaving.example", at: 300)], from: leaving)
        try await store.save([post("4", from: "staying.example", at: 400)], from: staying)

        try await store.left(leaving)

        #expect(try await timeline(store).map(\.text) == ["4"])
    }

    /// The posts stay in the store — what is kept is retention's answer, not this act's. A reader
    /// who rejoins has not lost what they read.
    @Test("The posts themselves are not deleted")
    func thepostsRemain() async throws {
        let store = try LocalStore.inMemory()
        let leaving = server("leaving.example")
        try await store.save([post("5", from: "leaving.example")], from: leaving)

        try await store.left(leaving)

        let rows = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM posts WHERE deleted_at IS NULL") ?? 0
        }
        #expect(rows == 1)
        #expect(try await timeline(store).isEmpty)
    }

    /// Leaving a server nothing came from is not an error and takes nothing.
    @Test("Leaving a server that gave nothing takes nothing")
    func aserverThatGaveNothing() async throws {
        let store = try LocalStore.inMemory()
        try await store.save([post("6", from: "staying.example")], from: server("staying.example"))

        #expect(try await store.left(server("never.example")) == 0)
        #expect(try await timeline(store).count == 1)
    }
}
