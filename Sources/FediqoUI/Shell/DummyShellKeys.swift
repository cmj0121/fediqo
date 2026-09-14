import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Dummy single keys. macOS listens through AppKit so Tab and `?` still work after compose.
    func dummyShellKeys(handle: @escaping (Character, Bool, Bool) -> Bool) -> some View {
        #if os(macOS)
        modifier(DummyKeyMonitor(handle: handle))
        #else
        modifier(DummyKeyPresses(handle: handle))
        #endif
    }
}

#if os(iOS)
private struct DummyKeyPresses: ViewModifier {
    var handle: (Character, Bool, Bool) -> Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(keys: ["?", "/", "c", .escape, .tab], phases: .down) { press in
                let shift = press.modifiers.contains(.shift)
                let control = press.modifiers.contains(.control)
                return handle(press.key.character, shift, control) ? .handled : .ignored
            }
    }
}
#endif

#if os(macOS)
private enum DummyKeyCode {
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
}

private struct DummyKeyMonitor: ViewModifier {
    var handle: (Character, Bool, Bool) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                let handle = handle
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.window?.isSheet != true,
                          !event.modifierFlags.contains(.command),
                          let character = dummyCharacter(of: event)
                    else { return event }
                    let shift = event.modifierFlags.contains(.shift)
                    let control = event.modifierFlags.contains(.control)
                    let kept = MainActor.assumeIsolated {
                        handle(character, shift, control)
                    }
                    return kept ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// Tab and Escape by key code: Shift-Tab types backtab, and modifiers turn Tab into a control character.
private func dummyCharacter(of event: NSEvent) -> Character? {
    switch event.keyCode {
    case DummyKeyCode.tab: KeyEquivalent.tab.character
    case DummyKeyCode.escape: KeyEquivalent.escape.character
    default: event.charactersIgnoringModifiers?.first
    }
}
#endif
