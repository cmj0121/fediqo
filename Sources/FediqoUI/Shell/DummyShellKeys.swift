import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

extension View {
    /// Dummy single keys. macOS listens through AppKit so Tab and `?` still work after compose.
    ///
    /// `home` is bumped when a field of the shell's hands the keys back — Return in the search
    /// (#163). On iOS the keys are heard only while this view holds the focus, and a field that
    /// lets go leaves it with nobody, so `j` and `k` went nowhere; a change of `home` takes it
    /// back. macOS reads the keys ahead of any responder and needs no such thing.
    func dummyShellKeys(home: Int = 0, handle: @escaping (Character, Bool, Bool, Bool) -> Bool) -> some View {
        #if os(macOS)
        modifier(DummyKeyMonitor(handle: handle))
        #else
        modifier(DummyKeyPresses(home: home, handle: handle))
        #endif
    }
}

#if os(iOS)
private struct DummyKeyPresses: ViewModifier {
    var home: Int
    var handle: (Character, Bool, Bool, Bool) -> Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: home) { _, _ in focused = true }
            .onKeyPress(
                keys: [
                    "?", "/", "b", "c", "d", "f", "j", "k", "g", "v", "a", "m", "s", "q", "r", "e", "w", "p", " ",
                    .escape, .tab, .return, .upArrow, .downArrow,
                ],
                phases: .down
            ) { press in
                // ⌘ chords are the platform's except the one dummy chord `DummyCommand.from`
                // names (⌘R). Anything this handle refuses is ignored, so ⌘Q and ⌘C still quit
                // and copy.
                let shift = press.modifiers.contains(.shift)
                let control = press.modifiers.contains(.control)
                let command = press.modifiers.contains(.command)
                // A key press here carries no physical key, so the slash key is told by what it
                // typed: Shift on the ANSI `/` types `?`, and on a layout whose `/` is shifted, `/`.
                let character = DummyCommand.typed(
                    press.key.character, shift: shift, onSlashKey: press.characters == "?"
                )
                return handle(character, shift, control, command) ? .handled : .ignored
            }
    }
}
#endif

#if os(macOS)
private enum DummyKeyCode {
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    /// The key that is `/` on an ANSI keyboard, wherever the layout puts its `/`.
    static let slash: UInt16 = 44
}

private struct DummyKeyMonitor: ViewModifier {
    var handle: (Character, Bool, Bool, Bool) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                let handle = handle
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.window?.isSheet != true,
                          let pressed = dummyCharacter(of: event)
                    else { return event }
                    let shift = event.modifierFlags.contains(.shift)
                    let character = DummyCommand.typed(
                        pressed, shift: shift, onSlashKey: event.keyCode == DummyKeyCode.slash
                    )
                    let control = event.modifierFlags.contains(.control)
                    let command = event.modifierFlags.contains(.command)
                    let kept = MainActor.assumeIsolated {
                        // Asked here rather than in the guard above because a responder chain is
                        // main-actor's, and this closure is not on it until this point.
                        guard !dummyWebIsTyping(event.window?.firstResponder) else { return false }
                        return handle(character, shift, control, command)
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

/// Whether a web view is what the keyboard is talking to.
///
/// **A local monitor is the whole application's, not this view's.** It sees the key down for every
/// window the app has open, which is what `isSheet` was already working around — and the moment
/// the sign-in page moved out of a sheet and into a window of its own, the exemption stopped
/// covering it and the shell ate every letter the reader typed at a login form. A reader could not
/// type `v`, `a`, `m` or `s` into their own password.
///
/// Asking about the web view rather than about the window is the rule that does not need patching
/// again for the next auxiliary window: **a page being typed into owns its own keys**, wherever it
/// is drawn. The chain is walked upward because the first responder inside a `WKWebView` is one of
/// WebKit's own internal views, not the `WKWebView` itself.
///
/// It deliberately says nothing about text fields. The shell's own fields are inside the shell and
/// handled by `DummyCommand`, which knows when one has focus; this is only about a subtree this
/// app does not own and cannot reason about.
@MainActor
func dummyWebIsTyping(_ responder: NSResponder?) -> Bool {
    var current = responder
    // Bounded rather than `while let`: a responder chain is a linked list built by other people's
    // code, and a cycle in one would hang the key handler for the whole app rather than drop a
    // keystroke. Sixteen is far past any real chain.
    for _ in 0..<16 {
        guard let responder = current else { return false }
        if responder is WKWebView { return true }
        current = responder.nextResponder
    }
    return false
}

/// Tab and Escape by key code: Shift-Tab types backtab, and modifiers turn Tab into a control character.
private func dummyCharacter(of event: NSEvent) -> Character? {
    switch event.keyCode {
    case DummyKeyCode.tab: KeyEquivalent.tab.character
    case DummyKeyCode.escape: KeyEquivalent.escape.character
    case DummyKeyCode.returnKey, DummyKeyCode.keypadEnter: KeyEquivalent.return.character
    case DummyKeyCode.upArrow: KeyEquivalent.upArrow.character
    case DummyKeyCode.downArrow: KeyEquivalent.downArrow.character
    default: event.charactersIgnoringModifiers?.first
    }
}
#endif
