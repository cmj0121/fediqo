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
        .library(name: "FediqoPersistence", targets: ["FediqoPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
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
        // **No resources, and that is the point.** This target carried a `Fixtures` directory of
        // captured pages until unit S removed it: a fixture that is a capture of somebody's
        // running forum is a copy of their server in this repository, and the reader asked for
        // none of it to be left. What a test needs now it writes inline, as the smallest literal
        // that carries the one property it pins. A `resources:` line naming a directory that is
        // not there is not a soft failure — SwiftPM warns at manifest time and then fails the
        // build outright when it tries to copy it — so the declaration goes with the directory.
        .target(
            name: "FediqoPersistence",
            dependencies: [
                "FediqoCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FediqoCoreTests",
            dependencies: ["FediqoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FediqoPersistenceTests",
            dependencies: ["FediqoPersistence", "FediqoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FediqoUITests",
            dependencies: ["FediqoUI", "FediqoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
