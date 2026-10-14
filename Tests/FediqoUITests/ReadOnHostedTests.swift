#if os(macOS)
import AppKit
import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #201 — the place where more belong reads on as it comes into view, once, and then is gone,
/// asked of the real row hosted off-screen.
///
/// **What this reaches.** The row the list draws, hosted in an `NSHostingView` as
/// `FoldHostedTests` hosts its controls, under a view that renews from the session as the list
/// does. So "coming into view reads on" is SwiftUI's own `onAppear`, and "then it is gone" is the
/// hosted tree drawing nothing once the read has landed.
///
/// **What it does not reach.** No window is made and nothing is shown: light and dark, a finger
/// on a phone and what VoiceOver says are for the user to check on a running app.
///
/// **One layout, and no language set**, for `FoldHostedTests`' reasons.
@Suite("The place where more belong reads on as it comes into view, hosted", .serialized, .watched)
@MainActor
struct ReadOnHostedTests {
    private static let one = "one.example"

    /// Every place in the timeline in front where more belong, as the list draws them.
    private struct Places: View {
        let session: ShellSession

        var body: some View {
            let marks = session.gapMarks(in: session.timelineItems(latest: nil))
            VStack(spacing: 0) {
                ForEach(marks.keys.sorted(), id: \.self) { row in
                    TimelineGapRows(kind: .newerRemain, stretches: marks[row]?.above ?? [], session: session)
                }
            }
        }
    }

    /// Every place in the timeline in front where posts may be missing, as the list draws them (#204).
    private struct Missing: View {
        let session: ShellSession

        var body: some View {
            let marks = session.gapMarks(in: session.timelineItems(latest: nil))
            VStack(spacing: 0) {
                ForEach(marks.keys.sorted(), id: \.self) { row in
                    TimelineGapRows(
                        kind: .mayBeMissing, stretches: marks[row]?.below ?? [], session: session,
                        posts: marks[row]?.posts ?? [:]
                    )
                }
            }
        }
    }

    private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: .distantPast)
        view.layoutSubtreeIfNeeded()
    }

    /// Room for a place still in view to ask again, the main actor given away between the turns.
    /// Counted turns: a place that asks does so from its own coming into view, which is nothing
    /// a check can name — and where it rightly asks nothing, there is no end to wait for.
    private static func turns(_ count: Int, of view: NSView) async {
        for _ in 0..<count {
            settle(view)
            await Task.yield()
        }
    }

    @Test("It reads on once as it comes into view, and then it is gone")
    func readsOnceThenGoes() async throws {
        let source = Source(host: Self.one, kind: .mastodon)
        let store = ItemStore()
        await store.add(source)
        await store.ingest((1...10).map { id in
            Note(
                id: "https://\(Self.one)/users/ada/statuses/\(id)", source: source, author: "Ada",
                handle: "@ada", body: "\(id)", postedAt: ReadOnTests.posted(id), categories: [.public],
                statusID: "\(id)", listed: [.public: "\(id)"]
            )
        })
        let server = TimelineServer(host: Self.one, 1...300)
        let session = ShellSession(
            http: server, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:]))
        )
        await session.reloadFromStore()
        await session.reload.timeline(.all, in: session)
        let before = await server.cursors.count
        #expect(!session.gapMarks(in: session.timelineItems(latest: nil)).isEmpty, "the premise: more belong")

        let view = NSHostingView(rootView: Places(session: session))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        Self.settle(view)
        #expect(view.fittingSize.height > 0, "the place is drawn")

        // No `by:` in these: the read is the hosted place's own, begun by its coming into view.
        await met("the place has read on, and the read has ended") {
            Self.settle(view)
            return session.gapMarks(in: session.timelineItems(latest: nil)).isEmpty && session.reload.asking.isEmpty
        }
        await met("the place is gone from what is drawn") {
            Self.settle(view)
            return view.fittingSize.height == 0
        }
        await Self.turns(50, of: view)
        #expect(await server.cursors.count == before + 3, "one read on: 208 to 300 in three stretches")
        #expect(view.fittingSize.height == 0, "and the place is gone")
    }

    /// #204: a place where posts may be missing reads down as it comes into view — and, its read
    /// failing, stays, and does not ask again while it stays in view.
    @Test("A place where posts may be missing reads down once as it comes into view, and a failure does not loop")
    func readsDownOnce() async throws {
        let source = Source(host: Self.one, kind: .mastodon)
        let store = ItemStore()
        await store.add(source)
        await store.ingest((1...10).map { id in
            Note(
                id: "https://\(Self.one)/users/ada/statuses/\(id)", source: source, author: "Ada",
                handle: "@ada", body: "\(id)", postedAt: ReadOnTests.posted(id), categories: [.public],
                statusID: "\(id)", listed: [.public: "\(id)"]
            )
        })
        let server = TimelineServer(host: Self.one, 1...10)
        let session = ShellSession(
            http: server, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:]))
        )
        await session.reloadFromStore()
        await server.post(11...60)
        await server.keep(from: 31)
        await session.reload.timeline(.all, in: session)
        await server.refuse("max_id=31")
        let before = await server.cursors.count

        let view = NSHostingView(rootView: Missing(session: session))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        Self.settle(view)
        // No `by:`: the read is the hosted place's own, begun by its coming into view.
        await met("reached, the place has read down, and the read has ended") {
            Self.settle(view)
            return await server.cursors.count == before + 1 && session.reload.asking.isEmpty
        }
        await Self.turns(50, of: view)
        #expect(await server.cursors.count == before + 1, "and failing, it did not ask again while in view")
        #expect(view.fittingSize.height > 0, "the place stays")
    }
}
#endif
