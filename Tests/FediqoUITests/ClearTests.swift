import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Decision 14's promise, pinned end to end: something is held for a server, the reader presses
/// Clear, and **all four kinds are gone** — the emoji catalogue, the emoji pictures, the
/// attachment previews and the avatars — along with the marks saying why a picture is absent.
///
/// Three caches and one button, so the thing worth testing is the button rather than any one of
/// them. Each cache's own `forget(host:)` is pinned in its own suite; what is pinned here is that
/// `ShellSession.clear` presses all three, that it presses them for the right server, and that
/// the readouts the screen draws fall where the reader can see them.
@MainActor
@Suite("Clearing a server")
struct ClearTests {
    private let alpha = "alpha.test"
    private let beta = "beta.test"

    /// Somewhere an observation callback can leave a mark. `withObservationTracking` hands its
    /// `onChange` a `@Sendable` closure, which cannot write to a local.
    private final class Signal: @unchecked Sendable {
        var fired = false
    }

    /// A barrier a test opens by hand — the shape unit 10 established. `opened` is checked
    /// **before** waiting, so a caller arriving after the gate is open does not park on a
    /// continuation nobody will resume.
    private actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            opened = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
    }

    /// Every address is at one third-party host, which is the point: an address says nothing
    /// about which server it was read through, so the source is whatever the call site said.
    nonisolated private func address(_ name: String) -> URL {
        URL(string: "https://cdn.example.test/\(name)")!
    }

    private func key(_ name: String) -> ShellPictures.Key {
        ShellPictures.Key(url: address(name), scale: 2, tier: .deck)
    }

    /// `nonisolated` because `refresh(host:using:)` takes a `@Sendable` closure that runs off
    /// this suite's actor: a fixture the closure has to hop back to the main actor for is one the
    /// compiler refuses, and rightly.
    nonisolated private func emoji(_ shortcode: String) -> CustomEmoji {
        CustomEmoji(shortcode: shortcode, url: address("\(shortcode).gif"), staticURL: nil)
    }

    private func request(_ shortcodes: [String], host: String) -> EmojiCache.Request {
        EmojiCache.Request(
            emojis: shortcodes.map(emoji),
            metrics: .init(side: 20, baseline: -4),
            scale: 2,
            host: host,
            still: false
        )
    }

    /// Answers every emoji address with a real two-frame GIF, so the emoji half of this is a
    /// decode that was kept rather than a record of nothing.
    private func emojiClient() -> FixtureHTTP {
        FixtureHTTP([
            "/wave.gif": .body(EmojiFixture.gif(delays: [0.1, 0.1])),
            "/blobcat.gif": .body(EmojiFixture.gif(delays: [0.1, 0.1])),
        ])
    }

    /// One server holding all four kinds, plus a mark for an address that came back with
    /// nothing. The preview and the avatar are two entries in one cache because that is what they
    /// are; naming them apart is what makes the assertions below readable as the promise.
    private func loaded(
        _ session: ShellSession,
        host: String,
        pictures: ShellPictures,
        emojis: EmojiCache
    ) async {
        let registered = [emoji("wave"), emoji("blobcat")]
        await session.emoji.refresh(host: host) { registered }
        await session.emoji.settle(host: host)
        await emojis.fetch(request(["wave", "blobcat"], host: host))
        pictures.keep(
            Image(systemName: "photo"), cost: 4096, for: key("\(host)-preview.jpg"),
            startedAt: 0, hosts: [host]
        )
        pictures.keep(
            Image(systemName: "photo"), cost: 2048, for: key("\(host)-avatar.png"),
            startedAt: 0, hosts: [host]
        )
        pictures.note(.refused, for: key("\(host)-gone.png"), hosts: [host])
    }

    @Test("One press drops the catalogue, the emoji, the previews, the avatars and the marks")
    func clearingDropsAllFourKinds() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let emojis = EmojiCache(http: emojiClient())
        let session = ShellSession(http: FixtureHTTP(), pictures: pictures, emojis: emojis)
        await loaded(session, host: alpha, pictures: pictures, emojis: emojis)

        // The premise, stated rather than assumed: a test of a Clear that started with nothing
        // held measures nothing at all.
        #expect(await session.emoji.catalogue(host: alpha)?.count == 2)
        #expect(emojis.holding(host: alpha).count == 2)
        #expect(pictures.holding(host: alpha).count == 2)
        #expect(pictures.isMissing(address("\(alpha)-gone.png"), scale: 2, tier: .deck))

        await session.clear(host: alpha)

        #expect(await session.emoji.catalogue(host: alpha) == nil, "the catalogue survived")
        #expect(emojis.holding(host: alpha).count == 0, "the emoji pictures survived")
        #expect(pictures.holding(host: alpha).count == 0, "the previews and avatars survived")
        #expect(pictures.order.isEmpty)
        #expect(pictures.heldBytes == 0)
        #expect(
            !pictures.isMissing(address("\(alpha)-gone.png"), scale: 2, tier: .deck),
            "the mark survived, so this address is blank for the rest of the run"
        )
    }

    @Test("Clearing one server leaves another server's alone")
    func clearingOneLeavesTheOther() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let emojis = EmojiCache(http: emojiClient())
        let session = ShellSession(http: FixtureHTTP(), pictures: pictures, emojis: emojis)
        await loaded(session, host: alpha, pictures: pictures, emojis: emojis)
        await loaded(session, host: beta, pictures: pictures, emojis: emojis)

        await session.clear(host: alpha)

        #expect(await session.emoji.catalogue(host: beta)?.count == 2)
        #expect(emojis.holding(host: beta).count == 2)
        #expect(pictures.holding(host: beta).count == 2)
        #expect(pictures.isMissing(address("\(beta)-gone.png"), scale: 2, tier: .deck))
        #expect(await session.emoji.catalogue(host: alpha) == nil)
        #expect(pictures.holding(host: alpha).count == 0)
    }

    /// The host is folded on the way in, so a server the reader typed in another case is still
    /// the server their button clears.
    @Test("Clear finds the server whatever case the row was drawn in")
    func clearingFoldsTheHost() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let emojis = EmojiCache(http: emojiClient())
        let session = ShellSession(http: FixtureHTTP(), pictures: pictures, emojis: emojis)
        await loaded(session, host: alpha, pictures: pictures, emojis: emojis)

        await session.clear(host: "ALPHA.Test")

        #expect(await session.emoji.catalogue(host: alpha) == nil)
        #expect(pictures.holding(host: alpha).count == 0)
    }

    /// **Decision 19's trade, made visible, and the answer to what Clear means.** Clear drops the
    /// cache; it does not forget the server. So a picture two servers are both drawing survives
    /// the first press — it is still being read through the second — and a row still on screen
    /// under the cleared server puts that source straight back on its next pass, which is what
    /// `picture(…)` does on every body pass and what the generation bump guarantees happens.
    ///
    /// The consequence, pinned rather than left to be discovered: after that re-tag, clearing the
    /// second server frees nothing either, because the first is back. Two servers on screen
    /// showing one photograph is one photograph. That is the same trade the set was chosen for,
    /// and the reason the button is drawn on a *place* rather than over the timeline.
    @Test("A shared picture survives the first Clear, and a drawn row puts its source back")
    func aSharedPictureIsFreedOnlyWhenNobodyIsReadingIt() {
        let pictures = ShellPictures(http: FixtureHTTP())
        let shared = key("shared-avatar.png")
        pictures.keep(Image(systemName: "photo"), cost: 4096, for: shared,
                      startedAt: 0, hosts: [alpha, beta])

        pictures.forget(host: alpha)
        #expect(pictures.order == [shared], "beta is still reading it")
        #expect(pictures.sources[shared] == [beta])

        // A row of alpha's, still drawn, reads the same address and tags it again — the case this
        // test exists for. Nothing here is a leak: a source drawing a picture is a source holding
        // it, and what was freed is what nobody was looking at.
        _ = pictures.picture(address("shared-avatar.png"), scale: 2, tier: .deck, host: alpha)
        #expect(pictures.sources[shared] == [alpha, beta])

        pictures.forget(host: beta)
        #expect(pictures.order == [shared], "alpha's row put it back before this press")

        // With no row drawing it, the last press frees it. This is the state the reader is
        // actually in when they press Clear, because Preferences is a place and the timeline is
        // not in the view tree behind it.
        pictures.forget(host: alpha)
        #expect(pictures.order.isEmpty)
        #expect(pictures.heldBytes == 0)
    }

    /// The failure mode this screen is designed against is a button that appears to do nothing,
    /// so what the row draws beside it is pinned too: both figures fall to zero for the server
    /// that was cleared and neither moves for the one that was not.
    @Test("The readings beside the button fall where the reader can see them")
    func theReadingsFall() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let emojis = EmojiCache(http: emojiClient())
        let session = ShellSession(http: FixtureHTTP(), pictures: pictures, emojis: emojis)
        await loaded(session, host: alpha, pictures: pictures, emojis: emojis)
        await loaded(session, host: beta, pictures: pictures, emojis: emojis)

        let heldBefore = pictures.holding(host: beta)
        #expect(pictures.holding(host: alpha).bytes == 4096 + 2048)
        #expect(emojis.holding(host: alpha).bytes > 0)

        await session.clear(host: alpha)

        #expect(pictures.holding(host: alpha) == (count: 0, bytes: 0))
        #expect(emojis.holding(host: alpha) == (count: 0, bytes: 0))
        #expect(pictures.holding(host: beta) == heldBefore, "the other server's reading moved")
    }

    /// The signal a line of text keys on. `EmojiCache` announces nothing — deliberately, because
    /// waking every line on screen for one emoji is what it exists not to do — so a line that has
    /// already resolved its pictures keeps drawing them after a Clear, and its `.task(id:)` does
    /// not re-run because its request has not changed. This counter is what a line can watch.
    @Test("A Clear is counted, so a line that has already drawn its emoji can ask again")
    func clearingIsAnnouncedToTheLines() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let emojis = EmojiCache(http: emojiClient())
        let session = ShellSession(http: FixtureHTTP(), pictures: pictures, emojis: emojis)
        #expect(session.cleared == 0)

        await session.clear(host: alpha)
        #expect(session.cleared == 1)

        // It counts the press, not what the press happened to find — a reader who clears a
        // server this device is holding nothing for has still made a decision.
        await session.clear(host: beta)
        #expect(session.cleared == 2)
    }

    /// **The case `clearingFoldsTheHost` does not reach.** That one folds the *argument* while
    /// the fixture stored a lowercase host already, so it would pass with no folding anywhere.
    /// This one stores under a host the way a call site would if it passed an account's domain
    /// rather than `source.host` — unit 8 is wiring exactly such a call site now.
    ///
    /// What makes it worse than an ordinary miss: before the fold, `forget` and `holding`
    /// compared the same way, so the sweep and the reading were **wrong together**. Entries up
    /// to the whole emoji budget would sit there for the run while the pane printed "No pictures
    /// held" beside them, and nothing anywhere would report the leak. So this asserts both
    /// halves: that the reading finds them, and that the button drops them.
    @Test("An emoji filed under a differently-cased host is still found, read and cleared")
    func theEmojiKeyFoldsItsHost() async {
        let emojis = EmojiCache(http: emojiClient())
        await emojis.fetch(request(["wave", "blobcat"], host: "ALPHA.Test"))

        // Stored folded, so every spelling is the same server to both the reading and the sweep.
        #expect(emojis.holding(host: alpha).count == 2, "the reading missed what it is holding")
        #expect(emojis.holding(host: "ALPHA.Test").count == 2)
        #expect(emojis.holding(host: "Alpha.TEST").count == 2)

        emojis.forget(host: alpha)
        #expect(
            emojis.holding(host: "ALPHA.Test").count == 0,
            "the sweep missed them, and the reading would have missed them by the same rule"
        )
        #expect(emojis.entriesHeld == 0)
        #expect(emojis.bytesHeld == 0)
    }

    /// **The shared-entry reading must not freeze silently.** `holding` answers from `sources`,
    /// which is `@ObservationIgnored` on purpose, so a Clear that only strikes a host off a
    /// shared entry changes the answer while leaving `pictures` untouched. Nothing in the loop
    /// would notice. `forget` bumps `generation` unconditionally and `holding` reads it, and this
    /// is what says so — delete that read and the figure beside the button stops moving for the
    /// one case hardest to catch by looking.
    @Test("Striking a host off a shared entry invalidates the reading that depends on it")
    func theSharedReadingAnnouncesItself() {
        let pictures = ShellPictures(http: FixtureHTTP())
        let shared = key("shared-avatar.png")
        pictures.keep(Image(systemName: "photo"), cost: 4096, for: shared,
                      startedAt: 0, hosts: [alpha, beta])

        let signal = Signal()
        withObservationTracking {
            _ = pictures.holding(host: beta)
        } onChange: {
            signal.fired = true
        }

        // Frees nothing — beta is still reading it — so `pictures` does not move.
        pictures.forget(host: alpha)
        #expect(
            pictures.order == [shared],
            "the premise: nothing was evicted, so this measures the path pictures cannot announce"
        )
        #expect(signal.fired, """
            A Clear that only strikes a host off a shared entry changed the answer without \
            touching `pictures`, and nothing told the screen. The `_ = generation` read in \
            holding(host:) is what closes this; it looks like a stray line and is not.
            """)
    }

    /// Why `readCatalogues` waits on `settle(host:)` before it reads. A catalogue is commissioned
    /// by the join and lands whenever the server answers, so the pane can easily be drawn while
    /// it is still on the wire — and the `.task` id does not move when it lands, so without the
    /// wait the reading says "No emoji names held" beside a server whose names arrived a moment
    /// later, for as long as the pane stays open.
    @Test("A catalogue still on the wire is waited for rather than reported as absent",
          .timeLimit(.minutes(1)))
    func aCatalogueInFlightIsWaitedFor() async {
        let session = ShellSession(http: FixtureHTTP())
        let registered = [emoji("wave"), emoji("blobcat")]
        // A barrier and **not** a sleep. "Still on the wire" is a happens-before requirement, and
        // the first version of this test encoded it as 50ms — which is the substitution this
        // branch has been caught by three times: under load the machine simply stops scheduling
        // you, and the premise check races the thing it is meant to exclude. It went red on its
        // first unfiltered run, which is the cheapest possible way to learn it again.
        let gate = Gate()
        await session.emoji.refresh(host: alpha) {
            await gate.wait()
            return registered
        }

        // The premise, now arranged: commissioned and held, which is what the pane walks in on.
        #expect(await session.emoji.catalogue(host: alpha) == nil,
                "it landed before the read; this measures nothing")

        // Opened before anything waits on it, so a regression is a wrong answer rather than a
        // hung job — `.timeLimit` does not rescue a task parked on a continuation.
        await gate.open()
        await session.emoji.settle(host: alpha)
        #expect(await session.emoji.catalogue(host: alpha)?.count == 2)
    }

    /// **Decision 20's one failure mode that nothing else can catch.** Gating the fetch with a
    /// `guard` alone stops the work and nothing restarts it: a tab that was inactive when its
    /// task last ran never re-runs it on becoming active, so the reader switches back to a page
    /// of empty wells that will not fill — and every test in this package would still be green,
    /// because the cache is not involved.
    ///
    /// The gate therefore has to be part of the `.task` identity, and this is what says so. It
    /// is an equality assertion because that is exactly what `.task(id:)` does with it.
    @Test("The place gate is part of what the task is keyed on, not only of what it guards")
    func theGateIsInTheTaskIdentity() {
        func wanted(active: Bool) -> RemoteImage.Wanted {
            RemoteImage.Wanted(
                url: address("avatar.png"), scale: 2, tier: .deck, have: false,
                generation: 0, host: alpha, active: active, here: true
            )
        }
        #expect(wanted(active: true) != wanted(active: false), """
            `active` has dropped out of Wanted. The guard in the task still stops the fetch, so \
            an inactive tab costs nothing — and never asks again when it becomes active, because \
            its task identity did not change. Decision 20.
            """)
        #expect(wanted(active: true) == wanted(active: true))
    }

    /// The default is what the app gets until `FediqoRootView` provides the value, and it has to
    /// be "fetch as today". A default of `false` would turn one missing `.environment` line in a
    /// file this unit does not own into an app that silently never loads a picture — which is F1
    /// exactly, and F1 is why this assertion is here rather than left to the comment.
    @Test("A subtree nobody has told counts as the active place")
    func theGateDefaultsToActive() {
        #expect(EnvironmentValues().shellPlaceIsActive)
    }

    /// The catalogue is handed to the screen with what a screen needs and nothing that resolves a
    /// shortcode, which is what `EmojiCatalogue.lookup` being non-public is for. Pinned because
    /// `PreferencesPane` copies exactly these three out into its own state.
    @Test("What the screen reads off a catalogue is its host, its age and its count")
    func theScreenReadsThreeThings() async throws {
        let session = ShellSession(http: FixtureHTTP())
        let before = Date()
        let registered = [emoji("wave")]
        await session.emoji.refresh(host: "ALPHA.Test") { registered }
        await session.emoji.settle(host: alpha)

        let held = try #require(await session.emoji.catalogue(host: alpha))
        #expect(held.host == alpha, "filed under the spelling the reader typed")
        #expect(held.count == 1)
        #expect(held.fetchedAt >= before)
        #expect(!held.isStale(at: before))
    }
}
