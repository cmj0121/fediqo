#if os(macOS)
import AppKit
import Testing
import WebKit

@testable import FediqoUI

/// Who owns a keystroke when two things in the app both want it.
@Suite("Shell keys and a web view")
@MainActor
struct ShellKeysWebTests {
    // The live defect this exists for: the shell's key handler is an *application* monitor, so it
    // sees the key down for every window the app has open. It exempted sheets, and the moment the
    // sign-in page moved out of a sheet into a window of its own the exemption stopped covering
    // it — the shell ate every letter a reader typed at a login form, and `v`, `a`, `m` and `s`
    // could not be typed into a password at all.
    @Test("A key inside a web view belongs to the web view, however deep the responder is")
    func aWebViewKeepsItsKeys() {
        let web = WKWebView(frame: .zero)

        // WebKit's own internal view is the first responder, never the `WKWebView` itself, so the
        // chain has to be walked upward rather than tested at the first link.
        let inner = NSView(frame: .zero)
        web.addSubview(inner)
        #expect(dummyWebIsTyping(inner))
        #expect(dummyWebIsTyping(web))
    }

    @Test("A key outside one does not, so the shell's own letters still work")
    func theShellKeepsItsOwn() {
        #expect(!dummyWebIsTyping(nil))
        #expect(!dummyWebIsTyping(NSView(frame: .zero)))

        // A plain view several links deep is still not a web view: the walk must not answer yes
        // merely because it ran out of chain.
        let outer = NSView(frame: .zero)
        let middle = NSView(frame: .zero)
        let inner = NSView(frame: .zero)
        outer.addSubview(middle)
        middle.addSubview(inner)
        #expect(!dummyWebIsTyping(inner))
    }

    @Test("A responder chain that loops answers rather than hanging the app")
    func aLoopedChainTerminates() {
        // A chain is a linked list built by other people's code. A cycle in one would hang the key
        // handler for the whole application rather than drop a single keystroke, so the walk is
        // bounded; this pins that the bound exists.
        final class Looping: NSResponder {
            override var nextResponder: NSResponder? {
                get { self }
                set {}
            }
        }
        #expect(!dummyWebIsTyping(Looping()))
    }
}
#endif
