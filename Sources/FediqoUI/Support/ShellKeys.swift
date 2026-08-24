import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// The single keys, on the platform where SwiftUI cannot be relied on to deliver them.
    func shellKeyCommands() -> some View {
        #if os(macOS)
        modifier(ShellKeyMonitor())
        #else
        self
        #endif
    }

    /// The single keys, on the platform where SwiftUI is the only one delivering them.
    ///
    /// Nothing on macOS: the monitor above sees every press before the view tree does and
    /// keeps everything `handles` claims, so a focus on the shell would decide nothing there
    /// — it would only be one more stop on the Tab loop, which on the pages that have no
    /// tabs of their own is exactly the loop this app hands the key back to.
    func shellKeyPresses() -> some View {
        #if os(iOS)
        modifier(ShellKeyPresses())
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Somewhere for the keyboard to be when it is nowhere in particular. `onKeyPress` is
/// delivered to whatever has focus and bubbles up from there, so without a focus of its own
/// the shell would hear nothing until the reader had tapped a control.
private struct ShellKeyPresses: ViewModifier {
    @Environment(AppState.self) private var app
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            // The composer takes the keyboard when it opens, so the shell asks for it back
            // once the panel has finished leaving — asking sooner asks over a field that is
            // still there and still holds it.
            //
            // `.task(id:)` rather than a `Task` of its own, because the wait has to be
            // undone as readily as it is started: opening the composer again inside those
            // few tenths would otherwise have the shell take the keyboard back off the field
            // the reader is already typing into. Changing the id cancels the wait, and so
            // does the shell going away.
            .task(id: app.composing) {
                guard !app.composing else { return }
                try? await Task.sleep(for: .seconds(0.25))
                guard !Task.isCancelled else { return }
                focused = true
            }
            .onKeyPress(keys: KeyCommand.listened, phases: .down) { press in
                let handled = KeyCommand.handles(press.key.character, modifiers: press.modifiers,
                                                 typing: app.isTyping) { app.perform($0) }
                return handled ? .handled : .ignored
            }
    }
}
#endif

#if os(macOS)
/// The keys AppKit numbers for us, because what they type is not one thing.
private enum KeyCode {
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    /// The Enter on the numeric pad. It types U+0003 where the Return above it types
    /// U+000D — one key to the reader, two characters to the keyboard layer, and only one
    /// of them is the character the commands are written in.
    static let keypadEnter: UInt16 = 76

    /// The five above. Asked first, so a press that is one of them never has its characters
    /// read at all.
    static let named: Set<UInt16> = [tab, escape, downArrow, upArrow, keypadEnter]
}

/// Which key was pressed, in the spelling `KeyCommand` reads.
///
/// The keys named by number are the ones whose typed character is not one thing: ⇧Tab arrives
/// as backtab rather than as a tab with a flag on it, a modifier turns the rest into control
/// characters, an arrow types a private-use character no keyboard has a cap for, and the
/// numeric pad's Enter types a different character from the Return above it. The key pressed
/// is the same key either way, and that is what the commands are written in. Everything else
/// is simply what it typed.
///
/// Internal, and written in plain numbers rather than in an `NSEvent`, so the table can be
/// checked on its own — the same reason `eventModifiers` below is not private.
func shellKey(keyCode: UInt16, typed: Character?) -> Character? {
    switch keyCode {
    case KeyCode.tab: KeyEquivalent.tab.character
    case KeyCode.escape: KeyEquivalent.escape.character
    case KeyCode.upArrow: KeyEquivalent.upArrow.character
    case KeyCode.downArrow: KeyEquivalent.downArrow.character
    case KeyCode.keypadEnter: KeyEquivalent.return.character
    default: typed
    }
}

/// The single keys, taken from AppKit rather than from SwiftUI.
///
/// Two things forced this, and either alone would have. `Tab` never reaches `onKeyPress` at
/// all: AppKit's key loop takes it first, because moving focus between controls is what
/// `Tab` has always been for, and what AppKit keeps SwiftUI never sees. And `onKeyPress` is
/// delivered to whatever holds the keyboard — so the moment the composer's field took it,
/// every other key went dead too, and a `@FocusState` on the shell would not take it back
/// once the field had had it. A shortcut that stops working after you have written one post
/// is not a shortcut.
///
/// So the shell listens where AppKit listens, and nothing about the keys depends on where
/// the keyboard happens to be. What decides is the same thing it always was: `AppState`'s
/// own `handles` — nothing while text is being typed except `Escape`, nothing that a
/// modifier makes the menu bar's, and nothing on a page that has nothing to do with it. Any
/// press that is not ours is handed straight back untouched.
///
/// A sheet is its own window and keeps its own keyboard entirely: the pickers and their
/// fields live there, and this steps aside for them.
/// Which of the keys this app listens for a press is, and nothing at all when it is none of
/// them. The numbered keys are asked about first, so a press that is one of them never has
/// its characters read; everything else has to be a key `listened` covers before `shellKey`
/// is troubled with it.
private func listenedKey(of event: NSEvent) -> Character? {
    if KeyCode.named.contains(event.keyCode) {
        return shellKey(keyCode: event.keyCode, typed: nil)
    }
    guard let typed = event.charactersIgnoringModifiers?.first,
          KeyCommand.listenedCharacters.contains(typed) else { return nil }
    return shellKey(keyCode: event.keyCode, typed: typed)
}

private struct ShellKeyMonitor: ViewModifier {
    @Environment(AppState.self) private var app
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                // What makes handing a Tab back safe. The press AppKit spends on window tabs
                // is ⌃Tab, and that one rotates the pages — there are always four, so it
                // always moved something and the monitor below always keeps it. This is the
                // second lock: the app says it has no window tabs at all, so no press of any
                // kind can fold a window into a set — and the Window menu stops offering to.
                // Nothing in Fediqo puts two windows side by side.
                NSWindow.allowsAutomaticWindowTabbing = false
                guard monitor == nil else { return }
                let app = app
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Every keystroke in the app arrives here, including every letter typed
                    // into a draft, so what is none of ours goes back before anything is
                    // allocated for it: a sheet keeps its own keyboard, the ⌘ forms belong to
                    // the menu bar, and a key nobody listens for is nobody's business.
                    guard event.window?.isSheet != true,
                          !event.modifierFlags.contains(.command),
                          let character = listenedKey(of: event)
                    else { return event }
                    let modifiers = event.modifierFlags.eventModifiers
                    // AppKit calls this on the main thread; the app is only ever touched
                    // there, and answering with a `Bool` keeps the event itself out of the
                    // hop, since an `NSEvent` cannot cross one.
                    let handled = MainActor.assumeIsolated {
                        KeyCommand.handles(character, modifiers: modifiers,
                                           typing: app.isTyping) { app.perform($0) }
                    }
                    return handled ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension NSEvent.ModifierFlags {
    /// The three flags a key command in this app is allowed to care about, in the spelling
    /// `KeyCommand` reads. Everything else AppKit tracks is none of its business.
    ///
    /// Internal rather than private so the translation can be checked on its own: it is the
    /// one place the two frameworks' spellings of a held key meet.
    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.control) { modifiers.insert(.control) }
        if contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}
#endif
