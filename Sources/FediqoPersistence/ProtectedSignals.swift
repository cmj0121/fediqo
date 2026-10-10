import FediqoCore
import Foundation
import os
#if os(macOS)
import AppKit
import CoreGraphics
#elseif os(iOS)
import UIKit
#endif

/// The platform's own word on whether the device is locked (#344), and the events that may
/// mean it has changed — **all of them wake-ups, none of them the answer**: the canary's read
/// is (`ProtectedData`).
///
/// On a Mac none of this is documented to follow the lock of the screen, and some of it may
/// not be heard inside a sandbox. So every event that arrives is written to the log by name —
/// what a Mac really sends at a lock and an unlock is read there — and nothing is correct
/// only if one of them comes.
public enum ProtectedSignals {
    /// The events listened for, each with the centre it is posted to.
    static var events: [(center: NotificationCenter, name: Notification.Name)] {
        #if os(macOS)
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        return [
            (.default, NSNotification.Name.NSApplicationProtectedDataDidBecomeAvailable),
            (.default, NSNotification.Name.NSApplicationProtectedDataWillBecomeUnavailable),
            (.default, NSApplication.didBecomeActiveNotification),
            // A window of the app's coming back into sight, or becoming the one typed into:
            // what a person returning to a Mac produces whether or not it was ever inactive.
            (.default, NSApplication.didChangeOcclusionStateNotification),
            (.default, NSWindow.didBecomeKeyNotification),
            (.default, somebody),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            // Undocumented and long-standing: what the system itself says at a lock and an unlock.
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        #elseif os(iOS)
        return [
            (.default, UIApplication.protectedDataDidBecomeAvailableNotification),
            (.default, UIApplication.protectedDataWillBecomeUnavailableNotification),
            (.default, UIApplication.didBecomeActiveNotification),
            (.default, UIScene.didActivateNotification),
            (.default, somebody),
        ]
        #else
        return []
        #endif
    }

    /// Somebody touched the app: a key, a pointer, a finger on the launch ground. **Itself
    /// proof of a person in front of the device**, and so the one wake-up a person coming back
    /// always produces, whatever the system does or does not announce.
    static let somebody = Notification.Name("fediqo.protected.somebody")

    /// Says so (`somebody`): what the launch ground calls when it is touched.
    public static func somebodyIsHere() {
        NotificationCenter.default.post(name: somebody, object: nil)
    }

    #if os(macOS)
    /// Any key or pointer event that reaches this app says somebody is here, for as long as
    /// what this returns is kept; `stop` ends it. Local to the app: nothing outside it is heard.
    @MainActor
    public static func listenForSomebody() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]) { event in
            somebodyIsHere()
            return event
        }
    }

    @MainActor
    public static func stop(_ listening: Any?) {
        if let listening { NSEvent.removeMonitor(listening) }
    }
    #endif

    /// A stream that says something each time one of `events` arrives, having subscribed to
    /// all of them before it returns. Each arrival is logged by its name.
    /// `heard` is told each as it arrives, by name, on whatever thread posted it.
    static func changes(
        _ events: [(center: NotificationCenter, name: Notification.Name)] = ProtectedSignals.events,
        heard: (@Sendable (String) -> Void)? = nil
    ) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let tokens = events.map { event in
                Token(center: event.center, token: event.center.addObserver(forName: event.name, object: nil, queue: nil) { _ in
                    NetLog.protection.notice("woken by \(event.name.rawValue, privacy: .public)")
                    heard?(event.name.rawValue)
                    continuation.yield()
                })
            }
            continuation.onTermination = { _ in tokens.forEach { $0.center.removeObserver($0.token) } }
        }
    }

    private struct Token: @unchecked Sendable {
        let center: NotificationCenter
        let token: any NSObjectProtocol
    }

    /// Whether this Mac's screen is locked, as the session says; nil where the session will
    /// not say — which inside a sandbox it may not.
    static func screenLocked() -> Bool? {
        #if os(macOS)
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
        #else
        return nil
        #endif
    }

    /// What the app was last told of itself, kept where anything may read it: both facts are
    /// the main actor's to ask, and are asked from wherever a save runs.
    private struct Told {
        var available = true
        var active = false
    }

    /// Whether a person is in front of an unlocked device, **read now, on the main actor,
    /// from the application itself** — what the gate asks. Nothing kept from an earlier notice.
    @MainActor
    public static func unlockedForSomebody() -> Bool {
        #if os(macOS)
        // Not locked, by the session's own word; where it will not say, a Mac is taken as a
        // phone is: the app being active is somebody in front of it.
        if let locked = screenLocked() { return !locked }
        return NSApp?.isActive ?? false
        #elseif os(iOS)
        // On a phone an active scene is itself proof of an unlocked device.
        return UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
        #else
        return true
        #endif
    }

    /// What was made for each store, so that asking again makes nothing — and registers
    /// nothing — a second time.
    @MainActor private static var made: [URL: ProtectedData] = [:]

    /// The canary in `store`, with this platform's flag, level and events. **Made once the
    /// app object exists** — from the first evaluation of a body, never from a static or the
    /// app's own initializer — since it asks the application. Once for a store: asked again,
    /// the same one.
    ///
    /// **Its `flag` and its `unlockedForSomebody` are copies, kept from the last notice**, for
    /// whoever asks off the main actor; they may be a notice behind. Nothing waits on either:
    /// the gate reads the level live (`unlockedForSomebody()`), and whatever holds a save
    /// holds on the canary alone.
    @MainActor
    public static func protected(store: URL) -> ProtectedData {
        if let made = made[store] { return made }
        let told = OSAllocatedUnfairLock(initialState: Told())
        var watched: [(NotificationCenter, Notification.Name, @Sendable (inout Told) -> Void)] = []
        #if os(macOS)
        told.withLock {
            $0.available = NSApp?.isProtectedDataAvailable ?? true
            $0.active = NSApp?.isActive ?? false
        }
        watched = [
            (.default, NSNotification.Name.NSApplicationProtectedDataDidBecomeAvailable, { $0.available = true }),
            (.default, NSNotification.Name.NSApplicationProtectedDataWillBecomeUnavailable, { $0.available = false }),
            (.default, NSApplication.didBecomeActiveNotification, { $0.active = true }),
            (.default, NSApplication.didResignActiveNotification, { $0.active = false }),
        ]
        #elseif os(iOS)
        told.withLock {
            $0.available = UIApplication.shared.isProtectedDataAvailable
            $0.active = UIApplication.shared.applicationState == .active
        }
        watched = [
            (.default, UIApplication.protectedDataDidBecomeAvailableNotification, { $0.available = true }),
            (.default, UIApplication.protectedDataWillBecomeUnavailableNotification, { $0.available = false }),
            (.default, UIApplication.didBecomeActiveNotification, { $0.active = true }),
            (.default, UIApplication.willResignActiveNotification, { $0.active = false }),
        ]
        #endif
        // For the life of the process: there is one of these for a store, and it is never let go.
        for (center, name, change) in watched {
            _ = center.addObserver(forName: name, object: nil, queue: nil) { _ in told.withLock(change) }
        }
        let protected = ProtectedData.canary(
            in: store,
            flag: { told.withLock { $0.available } },
            unlockedForSomebody: {
                #if os(macOS)
                if let locked = screenLocked() { return !locked }
                return told.withLock { $0.active }
                #else
                return told.withLock { $0.active && $0.available }
                #endif
            },
            changes: { changes() }
        )
        made[store] = protected
        return protected
    }

    /// Whether a canary that refuses is ever a lock here: not in the simulator, where the
    /// files are a Mac's underneath and nothing closes them.
    public static var waits: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}
