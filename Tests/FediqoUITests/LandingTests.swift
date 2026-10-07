import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

@Suite("The launch octopus")
struct LandingTests {
    /// **A reader who asked for less movement never sees a jet.** The same claim, in the
    /// same shape, as `ForumWaiting.clock(reduceMotion:)`: the skip is the starting value,
    /// not a zero-speed animation the view might still tick.
    @Test("Reduce motion starts dismissed, with the octopus at rest")
    func reduceMotionStartsDismissed() {
        let still = Landing.start(reduceMotion: true)
        #expect(!still.showing)
        #expect(still.squeeze == Landing.rest)
        #expect(still.lift == 0)
        #expect(still.opacity == 1)
    }

    @Test("A launch starts showing the octopus, at rest and whole")
    func aLaunchStartsShowingTheOctopusAtRest() {
        let launch = Landing.start(reduceMotion: false)
        #expect(launch.showing)
        #expect(launch.squeeze == CGSize(width: 1, height: 1))
        #expect(launch.lift == 0)
        #expect(launch.opacity == 1)
    }

    /// The jet, step by step, in the order the view plays it: gather is wider, shorter and
    /// lower; push off is narrower, taller and higher; the coast is rest again, exactly; and
    /// only then does it fade. It stays showing until it is dismissed.
    @Test("Gather sinks and widens, push off rises and narrows, coast is rest, leave fades")
    func theJetIsGatherPushOffCoastLeave() {
        var launch = Landing.start(reduceMotion: false)
        launch.gather()
        #expect(launch.squeeze == CGSize(width: 1.07, height: 0.90))
        #expect(launch.lift == -7)
        #expect(launch.opacity == 1)
        #expect(launch.showing)
        launch.pushOff()
        #expect(launch.squeeze == CGSize(width: 0.97, height: 1.05))
        #expect(launch.lift == 28)
        #expect(launch.opacity == 1)
        #expect(launch.showing)
        launch.coast()
        #expect(launch == Landing.start(reduceMotion: false))
        launch.leave()
        #expect(launch.opacity == 0)
        #expect(launch.squeeze == Landing.rest)
        #expect(launch.lift == 0)
        #expect(launch.showing)
        launch.dismiss()
        #expect(!launch.showing)
        #expect(launch.opacity == 0)
    }

    /// The numbers the person picked (motion A, Jet), and the size that keeps the animal the
    /// subject now that no tile is drawn round it.
    @Test("The jet keeps its picked times, and the octopus is larger than an icon")
    func theJetKeepsItsTimesAndTheMarkIsTheSubject() {
        #expect(Landing.mark == 200)
        #expect(Landing.mark > 72)
        #expect(Landing.hold == 0.20)
        #expect(Landing.gatherTime == 0.16)
        #expect(Landing.pushOffTime == 0.26)
        #expect(Landing.coastTime == 0.34)
        #expect(Landing.coastDamping == 0.8)
        #expect(Landing.leaveTime == 0.18)
        let whole = Landing.hold + Landing.gatherTime + Landing.pushOffTime
            + Landing.coastTime + Landing.leaveTime
        #expect(abs(whole - 1.14) < 0.0001)
    }

    /// `r` remounts this value from rest. A jet already spent must not be the next first frame.
    @Test("A dismissed launch can be shown again, at rest and whole")
    func aDismissedLaunchCanBeShownAgain() {
        var launch = Landing.start(reduceMotion: false)
        launch.gather()
        launch.pushOff()
        launch.coast()
        launch.leave()
        launch.dismiss()
        let again = Landing.start(reduceMotion: false)
        #expect(again.showing)
        #expect(again.squeeze == Landing.rest)
        #expect(again.lift == 0)
        #expect(again.opacity == 1)
    }

    /// **The launch draws the octopus and no tile.** `Image(_:bundle:)` draws nothing for a
    /// name it cannot find and says nothing about it, so the drawing is looked for here: in
    /// the bundle, as a template so the page's ink can paint it, and with nothing in it but
    /// the animal — no plate behind, no gradient, no rim.
    @MainActor
    @Test("The octopus drawing is in the bundle, a template, and has no tile")
    func theOctopusIsInTheBundleAloneAndATemplate() throws {
        #expect(
            Bundle.module.image(forResource: "Octopus") != nil
                || SourcePageTests.copiedCatalogue(Bundle.module.resourceURL, draws: "Octopus")
        )

        let imageset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources/Media.xcassets/Octopus.imageset")
        let contents = try JSONSerialization.jsonObject(
            with: Data(contentsOf: imageset.appendingPathComponent("Contents.json"))
        ) as? [String: Any]
        let properties = contents?["properties"] as? [String: Any]
        #expect(properties?["template-rendering-intent"] as? String == "template")

        let drawing = try String(
            contentsOf: imageset.appendingPathComponent("octopus.svg"), encoding: .utf8
        )
        #expect(drawing.contains("<path"))
        #expect(!drawing.contains("rx="))
        #expect(!drawing.contains("<defs"))
        #expect(!drawing.contains("stroke"))
        #expect(drawing.components(separatedBy: "<rect").count == 2)
    }
}
