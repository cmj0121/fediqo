import SwiftUI

/// A screen whose feature has not landed yet. It says which issue owns it rather than
/// pretending to be empty — a blank pane reads as a bug, and this is not one.
struct PlaceholderView: View {
    let titleKey: String
    let bodyKey: String
    let symbolName: String

    var body: some View {
        VStack(spacing: Space.pad) {
            Image(systemName: symbolName)
                .fediqoSymbol(Glyph.huge, weight: .light)
                .foregroundStyle(.tertiary)
            Text(t(titleKey)).fediqoFont(TypeScale.title, weight: .medium)
            Text(t(bodyKey))
                .fediqoFont(TypeScale.small)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Size.prose)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.page)
    }
}

struct KeptView: View {
    var body: some View {
        PlaceholderView(titleKey: "kept.title", bodyKey: "kept.soon", symbolName: "archivebox")
    }
}
