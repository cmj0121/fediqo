import SwiftUI
import FediqoCore

/// The whole app, and the only type the platform app targets need to know about. macOS
/// hosts it today; an iOS target hosts the same view and gets the same screens.
public struct FediqoRootView: View {
    @State private var app: AppState

    public init(app: AppState = AppState()) {
        _app = State(initialValue: app)
    }

    public var body: some View {
        content
            .fediqoChrome(app)
            .preferredColorScheme(app.preferences.theme.colorScheme)
            // Strings are read through a bundle chosen at runtime, so a language change has
            // to rebuild the tree rather than merely redraw it.
            .id(app.preferences.language)
    }

    @ViewBuilder
    private var content: some View {
        switch app.route {
        case .landing:
            LandingView()
        case .protocolPicker:
            ProtocolPickerView()
        case .serverPicker(let socialProtocol):
            ServerPickerView(socialProtocol: socialProtocol)
        case .shell:
            AppShell()
        }
    }
}
