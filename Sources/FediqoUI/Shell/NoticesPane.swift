import SwiftUI

struct NoticesPane: View {
    var body: some View {
        ContentUnavailableView(
            L10n.t("notices.empty.title"),
            systemImage: "bell",
            description: Text(L10n.t("notices.empty.detail"))
        )
    }
}
