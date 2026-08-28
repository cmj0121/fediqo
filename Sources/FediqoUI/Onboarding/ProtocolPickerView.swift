import SwiftUI
import FediqoCore

/// A fresh install has to say where it is reading from. Every protocol is listed, and the
/// ones this build cannot speak say so rather than being hidden.
struct ProtocolPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Palette.surface(colorScheme).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: Space.gap) {
                        ForEach(SocialProtocol.allCases) { row($0) }
                    }
                    .padding(Space.band)
                }
            }
            .frame(maxWidth: Size.pageColumn)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.step) {
            HStack(spacing: Space.pad) {
                MascotView(side: Size.wideIconColumn + Space.mid)
                Text(t("onboarding.protocol.title")).fediqoFont(TypeScale.display, weight: .semibold)
            }
            Text(t("onboarding.protocol.subtitle"))
                .fediqoFont(TypeScale.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.band)
        .padding(.top, Space.page)
    }

    private func row(_ socialProtocol: SocialProtocol) -> some View {
        Button {
            app.route = .serverPicker(socialProtocol)
        } label: {
            HStack(spacing: Space.pad) {
                Image(systemName: socialProtocol.symbolName)
                    .fediqoSymbol(Glyph.action, weight: .regular)
                    .frame(width: Size.wideIconColumn)
                    .foregroundStyle(socialProtocol.isImplemented ? Palette.accent : Color.secondary)

                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(t("onboarding.protocol.\(socialProtocol.rawValue)")).fediqoFont(TypeScale.lead, weight: .medium)
                    Text(t("onboarding.protocol.\(socialProtocol.rawValue).summary"))
                        .fediqoFont(TypeScale.small)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Space.gap)

                if socialProtocol.isImplemented {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                } else {
                    Text(t("onboarding.protocol.soon")).fediqoFont(TypeScale.minor, weight: .medium).fediqoPill()
                }
            }
            .padding(Space.withinGroup)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fediqoCard(radius: 12)
        }
        .buttonStyle(.plain)
        .disabled(!socialProtocol.isImplemented)
        .opacity(socialProtocol.isImplemented ? 1 : 0.55)
    }
}
