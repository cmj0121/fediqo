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
            resources: [.copy("Resources/schema.sql")],
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
    ]
)
