import SwiftUI

/// The narrow arrangement's way into Usage and back out of it (decisions 9 and 19).
///
/// **A phone's tab bar holds five places, and the shell has six.** So in the narrow arrangement
/// Usage is not a tab: it is drawn in Preferences' tab, entered by a "Usage ›" row at the head of
/// Preferences and left by a back row at the head of Usage. `place` still says Usage while it is
/// drawn, so Escape, ⌃Tab, an errand and a state put back all mean Usage as they did, and only
/// the tab lit is Preferences' (`ShellPlace.tab`).
///
/// **Handed down by the tabs alone**, so its being here is the answer to "is Usage folded into
/// Preferences". The rail and the Mac's folded pop-up list all six places and draw neither row,
/// and nor does a preview or a test that hands nothing down.
@MainActor
struct OpensUsage {
    /// Stand on `place`: Usage from Preferences' row, Preferences from Usage's back row.
    let go: (ShellPlace) -> Void
}

extension EnvironmentValues {
    /// See `OpensUsage`.
    @Entry var shellOpensUsage: OpensUsage?
}

/// The row at the head of a page that `OpensUsage` steps between: Usage's way in on Preferences,
/// the way back on Usage. Nothing where nothing was handed down.
///
/// **Over the page's tabs and not in its list**, so it is the head of whichever tab is in front
/// and a sideways swipe leaves it where it is. Set in as the tabs' own head is (`TabsOverForm`).
struct UsageStep: ViewModifier {
    /// The page the row is drawn at the head of: `.preferences` or `.usage`.
    let on: ShellPlace

    @Environment(\.shellOpensUsage) private var opens
    @Environment(\.colorScheme) private var colorScheme
    /// The way in is a row of a list, and lit and entered as one (`ShellListRow`).
    @State private var lit: Bool?

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let opens {
                row(opens)
                    .padding(.horizontal, TabsOverForm<EmptyView>.inset)
                    .padding(.top, ShellSpace.step)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ShellChrome.page(colorScheme))
                    .modifier(ProbedStep())
            }
        }
    }

    @ViewBuilder
    private func row(_ opens: OpensUsage) -> some View {
        if on == .usage {
            ShellBackButton("shell.usage.back") { opens.go(.preferences) }
        } else {
            ShellListRow(
                id: true, title: ShellPlace.usage.title, brief: ShellPlace.usage.summary,
                spoken: L10n.t("shell.usage.open"), selection: $lit, onOpen: { opens.go(.usage) }
            ) {
                Image(systemName: ShellPlace.usage.symbolName)
            }
        }
    }
}

/// Where the step's row was laid out, for a test that hands a probe down. Draws nothing.
final class UsageStepProbe {
    var frame = CGRect.zero
}

extension EnvironmentValues {
    /// See `UsageStepProbe`.
    @Entry var usageStepProbe: UsageStepProbe? = nil
}

private struct ProbedStep: ViewModifier {
    @Environment(\.usageStepProbe) private var probe

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { place in
                let _ = probe.frame = place.frame(in: .global)
                Color.clear
            })
        } else {
            content
        }
    }
}
