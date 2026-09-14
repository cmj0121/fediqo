import SwiftUI

/// The whole app, until there is a timeline again: the mascot, and nothing else.
public struct FediqoRootView: View {
    public init() {}

    public var body: some View {
        Image("Mascot", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 280)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Fediqo")
    }
}
