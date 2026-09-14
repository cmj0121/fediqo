import SwiftUI

struct UsagePane: View {
    var body: some View {
        ContentUnavailableView(
            L10n.t("usage.empty.title"),
            systemImage: "chart.bar.xaxis",
            description: Text(L10n.t("usage.empty.detail"))
        )
    }
}
