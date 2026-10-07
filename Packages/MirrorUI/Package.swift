// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MirrorUI",
    platforms: [.iOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "MirrorUI", targets: ["MirrorUI"]),
    ],
    targets: [
        .target(
            name: "MirrorUI",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
