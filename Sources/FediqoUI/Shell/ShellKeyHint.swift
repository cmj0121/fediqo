import SwiftUI
#if os(iOS)
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
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            keyboard = ShellKeyboard.present
        }
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
        GCKeyboard.coalesced != nil
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
