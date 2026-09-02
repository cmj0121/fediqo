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
            // A fixture run opens the same size in the same place every time, and on the second
            // display where there is one. Nothing at all on a reader's own run.
            .fixtureWindow(app.isFixture)
            // A screenshot run photographs this window and stops. Nothing at all on any other
            // run, and not compiled into a build anybody ships.
            .shooting(to: app.shootTo)
            .preferredColorScheme(app.preferences.theme.colorScheme)
            // Strings are read through a bundle chosen at runtime, so a language change has
            // to rebuild the tree rather than merely redraw it.
            .id(app.preferences.language)
            // Outside the `.id`, so that changing the language redraws the app rather than
            // asking every signed-in server about its credential all over again.
            .task { await app.onLaunch() }
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
