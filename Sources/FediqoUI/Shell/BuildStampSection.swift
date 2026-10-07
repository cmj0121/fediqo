import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Preferences' own place for which Fediqo this is (#143): the whole of its second tab, on both
/// platforms — inside the Form Preferences already is, rather than a second window or a sheet,
/// so it is reached by the same pills, Tab key and touch as Usage's tabs.
///
/// Everything drawn comes from `BuildStamp`, which is where it is decided and tested; this view
/// only lays the rows out and puts `copyText` on the clipboard. Nothing here reaches the network.
struct BuildStampSection: View {
    let stamp: BuildStamp

    /// Bumped by each Copy, so the button says it worked and then goes back to saying what it
    /// does. A count rather than a flag, so a second press restarts the wait.
    @State private var copies = 0
    @State private var copied = false

    var body: some View {
        Section {
            ForEach(stamp.rows(), id: \.label) { row in
                line(row)
            }
            ShellLinkButton(
                L10n.t(copied ? "about.copied" : "about.copy"),
                symbol: copied ? "checkmark" : "doc.on.doc", action: copy
            )
            .accessibilityHint(L10n.t("about.copy.hint"))
            .modifier(CopiedFades(copies: copies, copied: $copied))
        } header: {
            ShellSectionHead(title: "about.title", line: "about.brief", help: "about.footer")
        }
    }

    /// The label and what this build says: **one row shape for every row**, the label leading
    /// and what the build says trailing, in the Form's own inks. A revision is drawn short
    /// (`BuildStamp.shortRevision`) and in the face a hash is read in — a font on the value, not
    /// a layout of its own, so Source is set out exactly as Version is. Copy still takes the
    /// whole of it.
    ///
    /// **One rule for a value that does not fit**, whichever row it is on: it wraps under
    /// itself rather than being cut, since "not recorded: …" is a sentence and a sentence cut
    /// in the middle says nothing. Each row is one element to VoiceOver, read label then what
    /// is drawn.
    private func line(_ row: BuildStamp.Row) -> some View {
        LabeledContent(row.label) {
            Text(row.shown ?? row.value)
                .fontDesign(row.isReading ? .monospaced : nil)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
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
