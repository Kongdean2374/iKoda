// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KodaCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KodaCore", targets: ["KodaCore"]),
    ],
    targets: [
        .target(name: "KodaCore", resources: [.process("Resources")]),
        .testTarget(
            name: "KodaCoreTests",
            dependencies: ["KodaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
