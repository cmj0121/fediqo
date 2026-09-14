import SwiftUI

/// Who you are on a source. Unsigned: the host. Signed in: avatar and account meta.
struct AccountPane: View {
    let source: DummySource

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SourceMark(source: source)
            if source.isSignedIn {
                Text(L10n.t("source.signedIn"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.t("source.unsigned"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
