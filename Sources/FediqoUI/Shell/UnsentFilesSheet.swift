import FediqoCore
import SwiftUI

/// The files of a text not yet sent (#438): each named, how it stands at its source, what it says
/// of itself to correct, and taking it back, asked first. Draws what `ShellOutbox` holds and
/// decides nothing. **Closing it changes nothing**; a description is sent at its Save alone.
struct UnsentFilesSheet: View {
    let id: UUID
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var typed: [UUID: String] = [:]
    @State private var takingBack: UnsentMedia?

    private var sending: ShellOutbox.Sending? { session.outbox.sending(id) }
    private var open: Bool { sending.map(ShellOutbox.filesOpen) ?? false }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(sending?.files ?? []) { file in row(file) }
                if let refused = session.outbox.fileRefusals[id] {
                    Text(refused).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle(L10n.t("outbox.files"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("servers.close")) { session.filesOfUnsent = nil } }
            }
            .confirmationDialog(
                String(format: L10n.t("outbox.files.takeBack.title"), takingBack?.name ?? ""),
                isPresented: Binding(get: { takingBack != nil }, set: { if !$0 { takingBack = nil } }),
                titleVisibility: .visible, presenting: takingBack
            ) { file in
                Button(L10n.t("outbox.files.takeBack"), role: .destructive) { session.outbox.takeBack(file.id, of: id, in: session) }
            } message: { _ in
                Text(String(format: L10n.t("outbox.files.takeBack.line"), sending?.unsent.host ?? ""))
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }

    private func row(_ file: UnsentMedia) -> some View {
        let name = LineText.oneLine(file.name)
        let words = Binding(get: { typed[file.id] ?? file.description }, set: { typed[file.id] = $0 })
        return Section {
            if let stands = Self.standing(of: file, in: sending) {
                Text(stands).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme)).fixedSize(horizontal: false, vertical: true)
            }
            TextField(L10n.t("outbox.files.description"), text: words, axis: .vertical)
                .accessibilityLabel(String(format: L10n.t("outbox.files.description.spoken"), name))
            HStack(spacing: ShellSpace.step) {
                Button(L10n.t("outbox.files.save")) { session.outbox.correct(file.id, of: id, to: words.wrappedValue, in: session) }
                    .accessibilityLabel(String(format: L10n.t("outbox.files.save.spoken"), name))
                    .disabled(!open || words.wrappedValue == file.description)
                Button(L10n.t("outbox.files.takeBack"), role: .destructive) { takingBack = file }
                    .accessibilityLabel(String(format: L10n.t("outbox.files.takeBack.spoken"), name))
                    .disabled(!open)
            }
            .buttonStyle(.borderless)
        } header: {
            Text(name)
        }
    }

    /// What is known of a file at its source, where there is something to say.
    static func standing(of file: UnsentMedia, in sending: ShellOutbox.Sending?, language: DummyLanguage? = nil) -> String? {
        if file.unprepared { return L10n.t("outbox.files.unprepared", language: language) }
        if sending?.standing == .preparing { return L10n.t("outbox.files.preparing", language: language) }
        return nil
    }
}
