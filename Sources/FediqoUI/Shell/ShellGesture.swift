import SwiftUI

/// What a finger does in this app, each said once (#308): the page in Preferences that lists
/// them is drawn from this, and the keys' own table says which of them is the way to each key's
/// act (`DummyShortcut.gestures`).
///
/// **Only what the app does.** A gesture is here because something answers it, and the order is
/// the order a reader meets them in: a post, the timeline it is in, the timelines beside it,
/// and the way back.
public enum ShellGesture: String, CaseIterable, Identifiable, Sendable {
    /// One press on a post opens it and what is said around it.
    case press
    /// Pressed and held, a post says what it is and offers what can be done to it.
    case hold
    /// The list pulled down from its top is read again.
    case pull
    /// The reload mark is Stop while a reload runs.
    case stop
    /// The system's own press on the top of the screen goes to the top of the list.
    case top
    /// The name at the top, pressed, lists what it is one of: every timeline, with a new one and
    /// changing this one there; or, on a page with tabs, its tabs.
    case name
    /// A sideways swipe goes to the timeline beside this one.
    case swipe
    /// A sideways swipe on an opened post, person or tag goes back.
    case back
    /// On a wide page, where every timeline's name is in a row: a name pressed goes to it.
    case pill
    /// And a name pressed and held changes that timeline.
    case pillHold

    public var id: String { rawValue }

    var titleKey: String { "gesture.\(rawValue)" }
    var detailKey: String { "gesture.\(rawValue).detail" }
    func title(language: DummyLanguage? = nil) -> String { L10n.t(titleKey, language: language) }
    func detail(language: DummyLanguage? = nil) -> String { L10n.t(detailKey, language: language) }

    /// One row as VoiceOver reads it: the gesture, then what it does.
    func spoken(language: DummyLanguage? = nil) -> String {
        title(language: language) + ", " + detail(language: language)
    }

    var symbol: String {
        switch self {
        case .press: "hand.tap"
        case .hold: "hand.tap.fill"
        case .pull: "arrow.down"
        case .stop: "stop.circle"
        case .top: "arrow.up.to.line"
        case .name: "list.bullet"
        case .swipe: "arrow.left.arrow.right"
        case .back: "chevron.left"
        case .pill: "capsule"
        case .pillHold: "pencil"
        }
    }

    /// The gestures no key's line names: there is no key that says what a post is, and none is
    /// needed where a pointer rests on its parts.
    static let keyless: Set<ShellGesture> = [.hold]

    /// What the Gestures page lists, in order: **only what works in the arrangement in front.**
    /// A narrow page names its one timeline, and the name is the way to the rest; a wide one
    /// writes every name in a row and has no name to press for a list. The swipes are the same
    /// on both.
    static func listed(narrow: Bool) -> [ShellGesture] {
        narrow
            ? [.press, .hold, .pull, .stop, .top, .name, .swipe, .back]
            : [.press, .hold, .pull, .stop, .top, .pill, .pillHold, .swipe, .back]
    }

    /// The gestures the keys' table names, across all its lines.
    static var named: Set<ShellGesture> { Set(DummyShortcut.all.flatMap(\.gestures)) }
}

/// The page itself: one row a gesture, its name and under it what it does.
struct GesturesSection: View {
    @Environment(\.shellLayout) private var shellLayout

    var body: some View {
        Section {
            ForEach(ShellGesture.listed(narrow: shellLayout == .narrow)) { gesture in
                GestureRow(gesture: gesture)
            }
        } header: {
            Text(L10n.t("gesture.head"))
                .textCase(nil)
        }
    }
}

/// One gesture: its name, and under it what it does. Both break into as many lines as they
/// need; neither is cut.
struct GestureRow: View {
    let gesture: ShellGesture

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            Image(systemName: gesture.symbol)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                .frame(width: ShellSpace.room)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                Text(gesture.title())
                    .fixedSize(horizontal: false, vertical: true)
                Text(gesture.detail())
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gesture.spoken())
    }
}
