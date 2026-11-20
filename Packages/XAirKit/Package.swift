// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XAirKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "XAirKit", targets: ["XAirKit"]),
    ],
    targets: [
        .target(
            name: "XAirKit",
            resources: [
                .copy("Resources/xair-schema.json"),
                .copy("Resources/default-state.txt"),
                .copy("Resources/builtin-presets.json"),
            ]
        ),
        .testTarget(
            name: "XAirKitTests",
            dependencies: ["XAirKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
