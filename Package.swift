// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fediqo",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "FediqoCore", targets: ["FediqoCore"]),
        .library(name: "FediqoUI", targets: ["FediqoUI"]),
    ],
    targets: [
        .target(
            name: "FediqoCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FediqoUI",
            dependencies: ["FediqoCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // **AVKit, said out loud.** `import AVKit` links SwiftUI's overlay and not the
            // framework under it, and the overlay does not link it either — so nothing in the
            // app's load commands names AVKit and `AVPlayerView` is not in the process. The
            // first `VideoPlayer` a reader opens then aborts the app while the runtime tries to
            // resolve its superclass: `failed to demangle superclass of VideoPlayerView from
            // mangled name 'So12AVPlayerViewC'`. Nothing in this package references an AVKit
            // symbol directly — the reference is inside the overlay, made from metadata — so
            // autolinking has nothing to hang the framework on and the linker drops it.
            //
            // Here rather than in each app's `project.yml`: the target that uses AVKit is the
            // one that should carry it, or every app that ever embeds `FediqoUI` has to
            // remember, and the one that forgets does not find out until a reader presses `a`.
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        .testTarget(
            name: "FediqoCoreTests",
            dependencies: ["FediqoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FediqoUITests",
            dependencies: ["FediqoUI", "FediqoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
