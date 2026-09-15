import SwiftUI

struct UsagePane: View {
    var body: some View {
        ShellNotice(
            symbol: "chart.bar.xaxis",
            title: L10n.t("usage.empty.title"),
            detail: L10n.t("usage.empty.detail")
        )
    }
}
