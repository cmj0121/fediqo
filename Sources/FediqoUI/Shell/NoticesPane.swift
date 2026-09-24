import SwiftUI

struct NoticesPane: View {
    var body: some View {
        ShellNotice(
            symbol: "bell",
            title: L10n.t("notices.empty.title"),
            detail: L10n.t("notices.empty.line"),
            help: L10n.t("notices.empty.detail")
        )
    }
}
