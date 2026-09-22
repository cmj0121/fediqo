#if os(macOS)
import AppKit
@testable import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #168: `/`, a pattern, Return, `j`, `j`, `k` — followed through the keys' own path to the light.
///
/// **Hosted in a window, because the fault is a first responder's.** The timeline pane and the
/// search line are drawn as the root draws them — the pane handed a lamp in `@State` and the
/// root's one `ShellSearch`, the line inset at its foot with the root's Return — inside an
/// `NSWindow` that is never ordered onto a screen, so the field is a real AppKit field with a
/// real field editor. Letters reach it as key events sent to that window.
///
/// **The shell reads a key first**, as `DummyKeyMonitor` does ahead of any responder: what
/// `DummyCommand.from` maps while the field does not hold the keys is the shell's, and `j` and
/// `k` land where `FediqoRootView.moved` puts them; anything else goes on to the window, and so
/// to the field. `/` is answered as the root's `openSearch` answers it.
///
/// **What a key window adds, done by hand.** After sending Return's action, AppKit selects the
/// field's text again, which makes it first responder once more. In the reader's window SwiftUI
/// hears that as the field being focused, and the keys went back to it; in a window that is not
/// key its own resign lands afterwards and hides it. So the test makes the call AppKit makes —
/// `selectText` — on the same press, which is the part of the reader's path this process cannot
/// have by itself. Nothing else stands in for the product: the field's focus handling, Return
/// and the pane are the code under test.
///
/// **It gives the main actor back between passes**, as `TimelinePlacesHostedTests` explains:
/// one layout, one brief turn of the run loop and a `Task.yield()` per settle.
@Suite("Return in the search lights a result and j and k walk them, hosted", .serialized)
@MainActor
struct SearchLampHostedTests {
    private let microblog = Source(host: "m.example", kind: .mastodon)

    init() {
        L10n.language = .english
    }

    /// The lamp as the pane last drew it.
    @MainActor
    final class Lamp {
        var seen: String?
    }

    /// The root's share of the timeline place: a lamp in `@State`, the one search, the line at the
    /// foot of the pane, and Return lighting the first of what is in front.
    private struct Host: View {
        let session: ShellSession
        let search: ShellSearch
        let lamp: Lamp
        /// A key the shell has answered: what it lit.
        let pressed: Pressed
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: LampDefaults())

        var body: some View {
            lamp.seen = selected
            return TimelinePane(
                session: session,
                selectedID: $selected,
                standing: nil,
                onOpenPerson: { _ in },
                decks: $decks,
                playback: playback,
                onPlayRow: { _ in },
                onViewRow: { _ in },
                onTurnRow: { _ in },
                onOpenThread: { _ in },
                jumpToTop: 0,
                onBack: {},
                ways: TimelineWays(canSearch: true, onSearch: {}, canReload: false, onReload: {}),
                search: search
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if search.isOpen {
                    SearchBar(
                        search: search,
                        timeline: "All",
                        found: nil,
                        // The root's Return: the first of the list in front.
                        onSubmit: { selected = streamItems.first?.id },
                        onCleared: {},
                        onClose: {}
                    )
                }
            }
            .environment(prefs)
            .onChange(of: pressed.tick) { _, _ in selected = pressed.lit }
        }

        private var streamItems: [DummyItem] {
            session.searched(search, latest: nil) ?? session.timelineItems(latest: nil)
        }
    }

    /// What the shell's key handling decided, handed to the pane's `@State` the way the root's
    /// own writes reach it.
    @Observable
    @MainActor
    final class Pressed {
        var tick = 0
        @ObservationIgnored var lit: String?
    }

    @MainActor
    private struct Harness {
        let session: ShellSession
        let search: ShellSearch
        let lamp: Lamp
        let pressed: Pressed
        let window: NSWindow
        let view: NSView

        var field: NSTextField? { Self.field(in: view) }

        private static func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(field(in:)).first
        }

        /// The layers the root would say are open.
        private var open: Set<DummyLayer> {
            var open: Set<DummyLayer> = []
            if search.isOpen { open.insert(.search) }
            if lamp.seen != nil { open.insert(.selection) }
            return open
        }

        /// One key, the way the app hears it: the shell first, then the window.
        func press(_ key: Character, code: UInt16) async {
            if let command = DummyCommand.from(key, fieldFocused: search.fieldFocused) {
                let did = shell(command)
                if DummyCommand.consumes(key, did: did) {
                    await settle()
                    return
                }
            }
            let text = String(key)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code
            )
            if let event { window.sendEvent(event) }
            await settle()
        }

        func type(_ text: String) async {
            for key in text { await press(key, code: 0) }
        }

        /// The root's answers to the keys this test presses.
        private func shell(_ command: DummyCommand) -> Bool {
            switch command {
            case .search:
                // `/`, as the root's `openSearch` answers it.
                if search.isOpen {
                    search.focus()
                } else {
                    search.open(from: lamp.seen, over: session.notes)
                    light(nil)
                }
                return true
            case .nextPost, .previousPost:
                let ids = (session.searched(search, latest: nil) ?? session.timelineItems(latest: nil)).map(\.id)
                let step = command == .nextPost ? 1 : -1
                guard let next = FediqoRootView.moved(
                    in: ids.isEmpty ? nil : ids, from: lamp.seen, by: step, open: open
                ) else { return false }
                light(next)
                return true
            default:
                return false
            }
        }

        private func light(_ id: String?) {
            pressed.lit = id
            pressed.tick += 1
        }

        /// What AppKit does after Return's action in the reader's key window: the field's text
        /// selected again, on the same press.
        func reselect() async {
            field?.selectText(nil)
            await settle()
        }

        func settle() async {
            for _ in 0 ..< 2 {
                turn()
                await Task.yield()
            }
        }

        private func turn() {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: .distantPast)
        }
    }

    private func note(_ id: String, _ body: String, at t: Double) -> Note {
        Note(id: id, source: microblog, author: "Ada", handle: "@ada@m.example", body: body,
             postedAt: Date(timeIntervalSince1970: t), categories: [.public])
    }

    private func harness() async -> Harness {
        _ = NSApplication.shared
        let session = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: LampDefaults()))
        session.sources = [microblog]
        session.rebuildQueries()
        session.notes = [
            note("a", "swift one", at: 9),
            note("b", "other", at: 8),
            note("c", "swift two", at: 7),
            note("d", "swift three", at: 6),
            note("e", "other again", at: 5),
        ]
        session.timelineID = .all
        let search = ShellSearch()
        let lamp = Lamp()
        let pressed = Pressed()
        let view = NSHostingView(rootView: Host(session: session, search: search, lamp: lamp, pressed: pressed))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        let harness = Harness(session: session, search: search, lamp: lamp, pressed: pressed, window: window, view: view)
        await harness.settle()
        return harness
    }

    private func results(_ h: Harness) -> [String] {
        (h.session.searched(h.search, latest: nil) ?? []).map(\.id)
    }

    @Test("/, a pattern, Return, j, j, k: the first result lit, then the second, and the pattern kept")
    func returnThenJJK() async throws {
        let h = await harness()
        defer { h.window.contentView = nil }
        // The reader was on a row of the timeline before the search.
        await h.press("j", code: 38)
        #expect(h.lamp.seen != nil)

        await h.press("/", code: 44)
        await h.search.indexed()
        await h.settle()
        #expect(h.search.fieldFocused, "the field has the keys")
        await h.type("swift")
        #expect(h.search.text == "swift")

        await h.press("\r", code: 36)
        await h.reselect()
        let found = results(h)
        #expect(found.count == 3)
        let first = try #require(found.first)
        #expect(h.lamp.seen == first, "Return lights the first result")
        #expect(!h.search.fieldFocused, "and the keys are the list's")

        await h.press("j", code: 38)
        await h.press("j", code: 38)
        await h.press("k", code: 40)
        #expect(h.lamp.seen == found[1], "j, j, k ends on the second result")
        #expect(h.search.text == "swift", "no letter typed after Return reached the field")
        #expect(results(h) == found)

        // `/` hands the field the keys again, with the pattern kept.
        await h.press("/", code: 44)
        #expect(h.search.fieldFocused)
        await h.type("x")
        #expect(h.search.text.contains("x"), "a letter now reaches the field")
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class LampDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
#endif
