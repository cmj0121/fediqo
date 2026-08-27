import SwiftUI

/// A screen whose feature has not landed yet. It says which issue owns it rather than
/// pretending to be empty — a blank pane reads as a bug, and this is not one.
struct PlaceholderView: View {
    let titleKey: String
    let bodyKey: String
    let symbolName: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(t(titleKey)).fediqoFont(19, weight: .medium)
            Text(t(bodyKey))
                .fediqoFont(12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct KeptView: View {
    var body: some View {
        PlaceholderView(titleKey: "kept.title", bodyKey: "kept.soon", symbolName: "archivebox")
    }
}
