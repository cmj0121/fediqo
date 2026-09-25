import Foundation
#if os(iOS)
import UIKit
#endif

/// Keeps the device from sleeping while a move runs (#253, #247) — **one owner per flow, and
/// balanced by construction**: `set` tells the platform only when the wish changes, so a flow
/// that says "awake" twice says it once, and one that ends says "asleep" once.
///
/// On a phone or a tablet the screen stays on (`isIdleTimerDisabled`): a phone that locks is a
/// link that drops, and a code on a screen that went dark cannot be read across a room. On a Mac
/// the system is kept from idle sleep while the display may still dim
/// (`ProcessInfo.beginActivity`).
///
/// **The platform is behind `hook`**, so a test counts what was asked and never touches
/// `UIApplication`. The app's own hook counts too (`System`): two flows that each want the
/// device awake keep it so until both let go.
@MainActor
final class StayAwake {
    typealias Hook = @MainActor (Bool) -> Void

    private(set) var on = false
    private let hook: Hook

    init(hook: @escaping Hook = System.hold) {
        self.hook = hook
    }

    /// What the flow wants now; the platform is told only of a change.
    func set(_ wanted: Bool) {
        guard wanted != on else { return }
        on = wanted
        hook(wanted)
    }

    /// The device's own: a count of the owners that want it awake, told to the platform as it
    /// crosses zero.
    @MainActor
    enum System {
        private static var owners = 0
        #if os(macOS)
        private static var activity: (any NSObjectProtocol)?
        #endif

        static func hold(_ on: Bool) {
            let before = owners
            owners = max(0, owners + (on ? 1 : -1))
            guard (before == 0) != (owners == 0) else { return }
            let awake = owners > 0
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = awake
            #elseif os(macOS)
            if awake {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated], reason: "Moving what this device holds"
                )
            } else if let held = activity {
                ProcessInfo.processInfo.endActivity(held)
                activity = nil
            }
            #endif
        }
    }
}
