// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MirrorUI",
    platforms: [.iOS(.v18), .watchOS(.v11), .tvOS(.v18), .visionOS(.v2), .macCatalyst(.v18)],
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
