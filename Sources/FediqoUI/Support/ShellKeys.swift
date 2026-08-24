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
}

#if os(macOS)
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
/// the keyboard happens to be. What decides is the same thing it always was:
/// `KeyCommand.from` — nothing while text is being typed except `Escape`, nothing that a
/// modifier makes the menu bar's, and nothing on a page that has nothing to do with it. Any
/// press that is not ours is handed straight back untouched.
///
/// A sheet is its own window and keeps its own keyboard entirely: the pickers and their
/// fields live there, and this steps aside for them.
private struct ShellKeyMonitor: ViewModifier {
    @Environment(AppState.self) private var app
    @State private var monitor: Any?

    /// Tab and Escape, as AppKit numbers the keys. They are read by number rather than by
    /// what they type, because what they type is not one thing: ⇧Tab arrives as backtab, not
    /// as a tab with a flag on it, and a modifier turns the rest into control characters.
    /// The key pressed is the same key either way, and that is what the commands are written
    /// in.
    private static let tabKeyCode: UInt16 = 48
    private static let escapeKeyCode: UInt16 = 53

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Belt and braces beside the monitor below. The monitor is what keeps a Tab
                // we recognise away from AppKit; this says the app has no window tabs at all,
                // so no press of any kind can fold a window into a set — and the Window menu
                // stops offering to. Nothing in Fediqo puts two windows side by side.
                NSWindow.allowsAutomaticWindowTabbing = false
                guard monitor == nil else { return }
                let app = app
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.window?.isSheet != true,
                          let character = Self.character(for: event) else { return event }
                    let modifiers = event.modifierFlags.eventModifiers
                    // AppKit calls this on the main thread; the app is only ever touched
                    // there, and answering with a `Bool` keeps the event itself out of the
                    // hop, since an `NSEvent` cannot cross one.
                    let handled = MainActor.assumeIsolated {
                        guard let command = KeyCommand.from(character,
                                                            modifiers: modifiers,
                                                            typing: app.isTyping) else { return false }
                        return app.consumes(command)
                    }
                    return handled ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// Which key was pressed, in the spelling `KeyCommand` reads.
    private static func character(for event: NSEvent) -> Character? {
        switch event.keyCode {
        case tabKeyCode: KeyEquivalent.tab.character
        case escapeKeyCode: KeyEquivalent.escape.character
        default: event.charactersIgnoringModifiers?.first
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
