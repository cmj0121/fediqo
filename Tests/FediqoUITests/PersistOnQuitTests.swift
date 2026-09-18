import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

@Suite("Quit write")
@MainActor
struct PersistOnQuitTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Order {
        var steps: [String] = []
    }

    @Test("The quit reply waits until the write returns")
    func quitReplyWaitsForSave() async {
        let order = Order()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PersistOnQuit.holdUntilSaved(
                save: {
                    try? await Task.sleep(for: .milliseconds(20))
                    order.steps.append("save")
                },
                reply: {
                    order.steps.append("reply")
                    cont.resume()
                }
            )
        }
        #expect(order.steps == ["save", "reply"])
    }

    @Test("A store loaded at launch is visible after reload")
    func reloadFromStoreAdoptsTheIndex() async {
        let source = Source(host: "first.example", kind: .mastodon)
        let note = Note(
            id: "https://first.example/users/ada/statuses/1",
            source: source,
            author: "Ada",
            handle: "@ada@first.example",
            body: "hello",
            postedAt: origin,
            origins: [.publicTimeline, .trending]
        )
        let session = ShellSession(
            http: FixtureHTTP(),
            store: ItemStore(sources: [source], notes: [note])
        )
        #expect(session.sources.isEmpty)
        await session.reloadFromStore()
        #expect(session.sources.map(\.host) == ["first.example"])
        #expect(session.notes.map(\.id) == [note.id])
        #expect(session.queries.map(\.id) == ["all", "trends"])
    }
}
