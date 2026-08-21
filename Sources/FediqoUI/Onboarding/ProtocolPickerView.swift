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
                    VStack(spacing: 12) {
                        ForEach(SocialProtocol.allCases) { row($0) }
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: 640)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                MascotView(side: 44)
                Text(t("onboarding.protocol.title")).fediqoFont(26, weight: .semibold)
            }
            Text(t("onboarding.protocol.subtitle"))
                .fediqoFont(13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }

    private func row(_ socialProtocol: SocialProtocol) -> some View {
        Button {
            app.route = .serverPicker(socialProtocol)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: socialProtocol.symbolName)
                    .font(.system(size: 20))
                    .frame(width: 34)
                    .foregroundStyle(socialProtocol.isImplemented ? Palette.accent : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(t("onboarding.protocol.\(socialProtocol.rawValue)")).fediqoFont(15, weight: .medium)
                    Text(t("onboarding.protocol.\(socialProtocol.rawValue).summary"))
                        .fediqoFont(12)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if socialProtocol.isImplemented {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                } else {
                    Text(t("onboarding.protocol.soon")).fediqoFont(11, weight: .medium).fediqoPill()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fediqoCard(radius: 12)
        }
        .buttonStyle(.plain)
        .disabled(!socialProtocol.isImplemented)
        .opacity(socialProtocol.isImplemented ? 1 : 0.55)
    }
}
