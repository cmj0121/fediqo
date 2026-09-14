import SwiftUI

/// Empty invitation to add a source. The catalog and hostname field come later.
struct AccountPane: View {
    private enum Metrics {
        static let pad: CGFloat = 16
        static let stack: CGFloat = 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.stack) {
            Text(L10n.t("account.add.title"))
                .font(.headline)
            Text(L10n.t("account.add.detail"))
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Metrics.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
