import SwiftUI

struct PreferencesPane: View {
    var body: some View {
        ContentUnavailableView(
            L10n.t("preferences.empty.title"),
            systemImage: "gearshape",
            description: Text(L10n.t("preferences.empty.detail"))
        )
    }
}
