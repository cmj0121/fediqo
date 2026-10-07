import SwiftUI
#if os(iOS)
import Combine
import GameController
#endif

/// What is said only where there is a keyboard to press it on (#239): "Esc or q", the editor's
/// strip of keys.
///
/// A Mac always has one. An iPhone or iPad has one only while a hardware keyboard is attached,
/// which the Game Controller framework reports and announces as it comes and goes; without one a
/// hint is a sentence about keys the reader cannot reach, so nothing is drawn.
struct ShellWithKeyboard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var keyboard = ShellKeyboard.present

    var body: some View {
        Group {
            if keyboard { content() }
        }
        #if os(iOS)
        .onReceive(
            NotificationCenter.default.publisher(for: .GCKeyboardDidConnect).receive(on: DispatchQueue.main)
        ) { _ in keyboard = true }
        .onReceive(
            NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect).receive(on: DispatchQueue.main)
        ) { _ in keyboard = ShellKeyboard.present }
        #endif
    }
}

enum ShellKeyboard {
    /// Whether a key can be pressed here right now.
    @MainActor
    static var present: Bool {
        #if os(macOS)
        true
        #else
        !stagedAbsent && GCKeyboard.coalesced != nil
        #endif
    }

    /// A launch made for a picture stands as a device with no keyboard (`ShellStaged`): a
    /// simulator reports the keyboard of the Mac it runs on, and a phone has none. Never set
    /// by anything a reader launches.
    @MainActor static var stagedAbsent = false
}

/// Whether there is a keyboard, as something a view can read and be drawn again by (#303): the
/// same question `ShellKeyboard.present` answers, kept current as one comes and goes.
///
/// One for the app. `ShellWithKeyboard` asks for itself, per hint; what the lists do under a
/// finger is asked here once and handed down as `\.shellTouch`.
@MainActor
@Observable
final class ShellHands {
    static let shared = ShellHands()

    private(set) var keyboard = ShellKeyboard.present

    /// Whether there is nothing here but a finger.
    var touch: Bool { Self.touch(keyboard: keyboard) }

    /// A Mac always has a keyboard, so it is never touch; an iPhone or iPad is while none is attached.
    nonisolated static func touch(keyboard: Bool) -> Bool { !keyboard }

    private init() {
        #if os(iOS)
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboard = ShellKeyboard.present }
            }
        }
        #endif
    }
}

/// A hint about a key, in the page's quietest ink, where there is a keyboard.
///
/// Hidden from VoiceOver everywhere: the way out it names is a button beside it, which VoiceOver
/// already reads.
struct ShellKeyHint: View {
    let key: String
    @Environment(\.colorScheme) private var colorScheme

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        ShellWithKeyboard {
            Text(L10n.t(key))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityHidden(true)
        }
    }
}
