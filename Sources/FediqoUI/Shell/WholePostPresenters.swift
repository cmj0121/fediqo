import SwiftUI

/// What the root presents of a post as a whole (#330, #332, #333): the change sheet, the list of
/// what waits, and quoting — one link of the root's chain rather than three, which is what keeps
/// that chain inside what a slower compiler type-checks in time.
struct WholePostPresenters: ViewModifier {
    let session: ShellSession
    let hosts: ShellHostsKnown
    @Binding var composing: Bool

    func body(content: Content) -> some View {
        content
            .modifier(ChangePresenter(session: session))
            .modifier(LaterPresenter(session: session))
            .modifier(QuotePresenter(session: session, hosts: hosts, composing: $composing))
    }
}

/// What a staged run draws over the shell (`ShellStaged`): the report at the top, and the menus
/// over everything — one link of the root's chain rather than two.
struct StagedOverlays: ViewModifier {
    let staged: ShellStaged?
    let session: ShellSession

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if staged?.reports == true { StagedReport(session: session, counts: staged?.counts == true) }
            }
            .overlay {
                if staged?.menus == true { StagedMenus(session: session) }
            }
    }
}

/// The mascot a launch draws over the shell (#357) — one link of the root's chain, as the two
/// above are. **Drawn over, and never in the way**: a press, a key or a pointer goes to the app
/// under it, which is there and usable from the first frame.
struct LandingOverlay: ViewModifier {
    let plays: Bool
    let tick: Int
    @Binding var showing: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if plays {
                LandingView { showing = false }
                    .id(tick)
                    .allowsHitTesting(false)
            }
        }
    }
}
