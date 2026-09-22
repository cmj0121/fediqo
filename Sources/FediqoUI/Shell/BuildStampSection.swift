import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Preferences' own place for which Fediqo this is (#143): a section of the page, after what a
/// person chooses, on both platforms — the Form Preferences already is, rather than a second
/// window or a sheet, so it is reached by the same walk, key and touch as the rows above it.
///
/// Everything drawn comes from `BuildStamp`, which is where it is decided and tested; this view
/// only lays the rows out and puts `copyText` on the clipboard. Nothing here reaches the network.
struct BuildStampSection: View {
    let stamp: BuildStamp

    @Environment(\.colorScheme) private var colorScheme

    /// Bumped by each Copy, so the button says it worked and then goes back to saying what it
    /// does. A count rather than a flag, so a second press restarts the wait.
    @State private var copies = 0
    @State private var copied = false

    var body: some View {
        Section {
            ForEach(stamp.rows(), id: \.label) { row in
                line(row)
            }
            Button(action: copy) {
                Label(
                    L10n.t(copied ? "about.copied" : "about.copy"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
            .accessibilityHint(L10n.t("about.copy.hint"))
            .modifier(CopiedFades(copies: copies, copied: $copied))
        } header: {
            Text(L10n.t("about.title"))
        } footer: {
            Text(L10n.t("about.footer"))
                .shellFont(.meta)
        }
    }

    /// The label and what this build says. A revision is set under its label rather than beside
    /// it: forty characters beside a label on a phone would be squeezed into a column a few
    /// characters wide. Each row is one element to VoiceOver, read label then value.
    @ViewBuilder
    private func line(_ row: BuildStamp.Row) -> some View {
        if row.isReading {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(row.label)
                Text(row.value)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            LabeledContent(row.label) {
                Text(row.value)
                    .textSelection(.enabled)
            }
        }
    }

    private func copy() {
        Self.put(stamp.copyText())
        copied = true
        copies += 1
    }

    /// The clipboard, whole: what was there is replaced rather than added to, so a paste is the
    /// report and only the report.
    @MainActor
    static func put(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

/// Two seconds after the last Copy, the button goes back to saying what it does. A modifier, not
/// a `.task` closure spelled on the button, for the compiler reason `FediqoRootView` gives.
private struct CopiedFades: ViewModifier {
    let copies: Int
    @Binding var copied: Bool

    func body(content: Content) -> some View {
        content.task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}
