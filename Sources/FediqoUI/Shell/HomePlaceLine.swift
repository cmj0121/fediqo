import SwiftUI

/// The line at the head of Home: the sentence, and the two presses. Drawn with the shell's ink.
/// Appearing it does not move the list; `apply` runs only after the press that goes to the
/// source's post.
struct HomePlaceLine: View {
    let session: ShellSession
    var touch: Bool
    var apply: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let line = session.homePlace.line {
            switch line {
            case .apart(let host, _, _):
                places(host)
            case .missing(let host):
                sentence(String(format: L10n.t("home.place.missing"), host))
            case .failed(let host):
                sentence(String(format: L10n.t("home.place.failed"), host))
            }
        }
    }

    private func places(_ host: String) -> some View {
        let here = L10n.t("home.place.here")
        let there = String(format: L10n.t("home.place.there"), host)
        return VStack(alignment: .leading, spacing: ShellSpace.tight) {
            sentence(String(format: L10n.t("home.place.line"), host))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ShellSpace.step) { presses(here: here, there: there) }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { presses(here: here, there: there) }
            }
        }
    }

    @ViewBuilder
    private func presses(here: String, there: String) -> some View {
        ShellLinkButton(here) { Task { await session.homePlace.here(in: session) } }
            .accessibilityLabel(here)
        ShellLinkButton(there) {
            session.homePlace.there(touch: touch)
            apply()
        }
        .accessibilityLabel(there)
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }
}
