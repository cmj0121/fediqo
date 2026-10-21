import AppKit
import SwiftUI
@testable import FediqoUI

/// One way a sheet is laid out hosted and held to its room (#330, #332, #333): a Mac's 420 and a
/// phone's 390 at the usual text, and a phone's 320 at the largest, in the scheme asked.
@MainActor
enum HostedFit {
    /// The rooms a sheet is laid out in: width, and the text size it is read at there.
    static let rooms: [(width: CGFloat, size: DynamicTypeSize)] = [(420, .large), (390, .large), (320, .accessibility5)]

    /// The scheme a test's `dark` argument names.
    static func scheme(_ dark: Int) -> ColorScheme { dark == 1 ? .dark : .light }

    /// Whether `view`, hosted at `width` (and `height`, where given) in `scheme` at `size`, lays
    /// out with some height and no wider than `room` — `width` where none is given.
    static func fits(
        _ view: some View, width: CGFloat? = nil, height: CGFloat? = nil, room: CGFloat? = nil,
        scheme: ColorScheme, size: DynamicTypeSize = .large
    ) -> Bool {
        let hosted = NSHostingView(rootView: view.frame(width: width, height: height)
            .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
        hosted.layoutSubtreeIfNeeded()
        let limit = room ?? width ?? .infinity
        return hosted.fittingSize.height > 0 && hosted.fittingSize.width <= limit + 0.5
    }
}
