import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #66 — an avatar, and a picture a post carries, take their place before they fill it.
///
/// What is assertable without a screen is the fill RemoteImage decides from, that a still-coming
/// picture waits as ShellWaiting rather than a second well, that a held copy skips waiting, that
/// a missing URL still has a place, and that VoiceOver is owed the waiting sentence only when
/// this view is the waiting place. The suite is `@MainActor` for the reason WaitingTests is:
/// everything it reads belongs to a View.
@Suite("A picture takes its place before it fills it")
@MainActor
struct PictureWaitingTests {
    private let url = URL(string: "https://example.test/1.png")!
    private let host = "alpha.test"

    /// The still-coming branch is the shell's plate filling the same frame, not a second well
    /// of RemoteImage's own. The inner plate is silent: this view is the waiting place, and
    /// `speaks` is how a surface that already talks takes the sentence over.
    @Test("A still-coming picture waits as ShellWaiting, not a second well")
    func waitingIsTheShellPlate() {
        #expect(RemoteImage.fill(have: false, url: url, missing: false) == .waiting)
        #expect(RemoteImage.plateSpeaks == false)
        #expect(RemoteImage.waitingPlate().speaks == false)
        #expect(RemoteImage.waitingPlate().speaks == RemoteImage.plateSpeaks)
        #expect(RemoteImage.clock(reduceMotion: true) == ShellWaiting.clock(reduceMotion: true))
    }

    /// `cache.picture(...)` non-nil is held: no plate, no flicker. Missing is ignored when
    /// the picture is already in hand, so a note that it was once gone cannot hide a copy
    /// this device is holding. Network off is the same fact: if the file is here, show it.
    @Test("A picture this device already holds is drawn at once, with no waiting state")
    func heldPictureSkipsWaiting() {
        #expect(RemoteImage.fill(have: true, url: url, missing: false) == .held)
        #expect(RemoteImage.fill(have: true, url: url, missing: true) == .held)

        let cache = ShellPictures()
        cache.keep(
            Image(systemName: "photo"),
            cost: 1024,
            for: ShellPictures.Key(url: url, scale: 2, tier: .deck),
            startedAt: 0,
            hosts: [host]
        )
        let have = cache.picture(url, scale: 2, tier: .deck, host: host) != nil
        #expect(have)
        #expect(
            RemoteImage.fill(
                have: have,
                url: url,
                missing: cache.isMissing(url, scale: 2, tier: .deck)
            ) == .held
        )
    }

    /// The call site already frames RemoteImage. A nil URL is still absent, not a collapsed
    /// view, not a wait that never ends, and not a failure with nothing to try.
    @Test("A missing URL still has a place, and it is absent rather than waiting")
    func nilURLStillHasAPlace() {
        #expect(RemoteImage.fill(have: false, url: nil, missing: false) == .absent)
        #expect(RemoteImage.fill(have: false, url: nil, missing: true) == .absent)
        #expect(DummyItemRow.Box.avatar > 0)
        #expect(DummyItemRow.Box.thumb > 0)
    }

    /// A URL that was asked for and came back with nothing is failed, in the frame the
    /// picture would have filled. Held still wins over a mark that it was once gone.
    @Test("A wait that ended with nothing is failed, not absent and not still waiting")
    func missingAfterAFetchIsFailed() {
        #expect(RemoteImage.fill(have: false, url: url, missing: false) == .waiting)
        #expect(RemoteImage.fill(have: false, url: url, missing: true) == .failed)
        #expect(RemoteImage.fill(have: true, url: url, missing: true) == .held)
        #expect(RemoteImage.fill(have: false, url: nil, missing: true) == .absent)
    }

    /// Reduce Motion is the shell's clock, not a second one. A waiting picture that kept its
    /// own tick would keep moving after the rest of the app had stopped.
    @Test("Reduce Motion still uses ShellWaiting's clock")
    func reduceMotionUsesTheShellClock() {
        #expect(RemoteImage.clock(reduceMotion: true)
            == ShellWaiting.clock(reduceMotion: true))
        #expect(RemoteImage.clock(reduceMotion: false)
            == ShellWaiting.clock(reduceMotion: false))
        #expect(RemoteImage.clock(reduceMotion: true) == nil)
    }

    /// A plate standing alone is the place and says so. A plate inside a row that already
    /// speaks as a post says nothing, so a timeline of arriving avatars is not one "on its
    /// way" per face. Waiting reuses the shell's sentence; it does not add a string per row.
    @Test("VoiceOver names a waiting place, and is silent when the surface already speaks")
    func waitingSpeaksOnlyWhenItIsThePlace() {
        #expect(RemoteImage.voice(fill: .waiting, alt: nil, speaks: true)
            == ShellWaiting.spoken)
        #expect(RemoteImage.voice(fill: .waiting, alt: nil, speaks: false) == nil)
        #expect(RemoteImage.voice(fill: .waiting, alt: "a cat", speaks: true)
            == ShellWaiting.spoken)
        #expect(RemoteImage.voice(fill: .waiting, alt: "a cat", speaks: false) == nil)
        #expect(RemoteImage.voice(fill: .waiting, alt: nil, speaks: true)
            == L10n.t("shell.waiting"))
        #expect(RemoteImage(url: nil, tier: .deck, host: host).speaks)
        #expect(RemoteImage(url: nil, tier: .deck, host: host, speaks: false).speaks == false)
    }

    /// What arrived keeps the author's alt. A nil URL stays the absent mark. A wait that
    /// ended names the source, even when this view is one picture inside a row that already
    /// speaks — the retry has to be reachable.
    @Test("What arrived is named by its alt, and a failed wait names the source")
    func arrivedUsesAltAndFailedNamesTheSource() {
        #expect(RemoteImage.voice(fill: .held, alt: "a cat", speaks: true) == "a cat")
        #expect(RemoteImage.voice(fill: .held, alt: nil, speaks: true) == nil)
        #expect(RemoteImage.voice(fill: .absent, alt: "a cat", speaks: true) == "a cat")
        #expect(RemoteImage.voice(fill: .absent, alt: nil, speaks: true) == nil)
        #expect(RemoteImage.voice(fill: .absent, alt: nil, speaks: true)
            != ShellWaiting.spoken)
        #expect(RemoteImage.voice(fill: .failed, alt: "a cat", speaks: true, source: host)
            == ShellFailure.spoken([host]))
        #expect(RemoteImage.voice(fill: .failed, alt: nil, speaks: false, source: host)
            == ShellFailure.spoken([host]))
        #expect(RemoteImage.voice(fill: .failed, alt: nil, speaks: true, source: host)
            != ShellWaiting.spoken)
    }
}
