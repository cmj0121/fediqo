import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Dummy single keys. macOS listens through AppKit so `?` still works after compose.
    func dummyShellKeys(handle: @escaping (Character, Bool) -> Bool) -> some View {
        #if os(macOS)
        modifier(DummyKeyMonitor(handle: handle))
        #else
        modifier(DummyKeyPresses(handle: handle))
        #endif
    }
}

#if os(iOS)
private struct DummyKeyPresses: ViewModifier {
    var handle: (Character, Bool) -> Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(keys: ["?", "/", "c", .escape], phases: .down) { press in
                let shift = press.modifiers.contains(.shift)
                return handle(press.key.character, shift) ? .handled : .ignored
            }
    }
}
#endif

#if os(macOS)
private struct DummyKeyMonitor: ViewModifier {
    var handle: (Character, Bool) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                let handle = handle
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.window?.isSheet != true,
                          !event.modifierFlags.contains(.command),
                          let character = event.charactersIgnoringModifiers?.first
                    else { return event }
                    let shift = event.modifierFlags.contains(.shift)
                    let kept = MainActor.assumeIsolated { handle(character, shift) }
                    return kept ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
#endif
