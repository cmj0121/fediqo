import SwiftUI

/// A place, a tab or a timeline's name already in front, pressed again (#442): the page in front
/// goes to its top, as `g` takes it there. Handed down rather than asked of each bar, so the rail,
/// the tab bar, the fold and the tabs on a page cannot come to mean different things by it.
///
/// **Always equal**: what `go` reads is the root's state, whichever pass built it, and a new closure
/// on each of the root's passes would otherwise redraw every page that reads this.
struct PressedAgain: Equatable {
    let go: () -> Void

    static func == (_: PressedAgain, _: PressedAgain) -> Bool { true }
}

extension EnvironmentValues {
    /// See `PressedAgain`.
    @Entry var shellPressedAgain: PressedAgain?
    /// Bumped each time a page with no list the keys walk is asked to go to its top.
    @Entry var shellPageTop: Int = 0
}

/// The top of a page with no list the keys walk: Account, Preferences, Usage, what Notices hold.
enum ShellPageTop {
    static let id = "shell.page.top"
}

/// Takes the scroll view it stands on to `ShellPageTop.id` when the page is asked.
struct GoesToPageTop: ViewModifier {
    @Environment(\.shellPageTop) private var top

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: top) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(ShellPageTop.id, anchor: .top) }
            }
        }
    }
}

/// What a page's top is scrolled to: a mark that draws nothing and says nothing.
struct PageTopMark: View {
    var id = ShellPageTop.id

    var body: some View {
        Color.clear.frame(height: 0).id(id).accessibilityHidden(true)
    }
}

/// What the top of a `Form` is where its tabs stand over it and no row of its own is known to come
/// first: a row that draws nothing.
struct FormTop: View {
    var body: some View {
        Section {
            PageTopMark()
                .listRowBackground(Color.clear)
        }
    }
}
