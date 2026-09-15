import SwiftUI

/// Compose over the current page. The same shape a reply will use: a sheet, not a destination.
struct ComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(ShellType.body)
                .padding(ShellSpace.step)
                .navigationTitle(L10n.t("compose.title"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("compose.cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("compose.post")) { dismiss() }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        #if os(macOS)
        .frame(width: 600, height: 400)
        #else
        .frame(minWidth: 600, minHeight: 400)
        #endif
    }
}
