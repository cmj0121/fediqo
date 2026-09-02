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
    dependencies: [
        // The one external dependency (#2): SQLite, with migrations and a serialised queue.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "FediqoCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/schema.sql"), .copy("Resources/schema-002.sql"),
                        .copy("Resources/schema-003.sql"), .copy("Resources/schema-004.sql"),
                        .copy("Resources/schema-005.sql"), .copy("Resources/schema-006.sql"),
                        .copy("Resources/schema-007.sql"), .copy("Resources/schema-008.sql"),
                        .copy("Resources/schema-009.sql"),
                        .copy("Resources/schema-010.sql"),
                        .copy("Resources/schema-011.sql"),
                        .copy("Resources/schema-012.sql"),
                        .copy("Resources/schema-013.sql"),
                        .copy("Resources/schema-014.sql")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FediqoUI",
            dependencies: ["FediqoCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FediqoCoreTests",
            dependencies: ["FediqoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The UI layer's own reasoning — which pages have which tabs, which feed a screen is
        // reading, what the refreshing clock is keyed to, where a launch variable lands. No
        // view is built here: these are the decisions taken before anything is drawn.
        .testTarget(
            name: "FediqoUITests",
            dependencies: ["FediqoUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
