// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "tmuxpal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tmuxpal", targets: ["TmuxPal"]),
        .library(name: "TmuxPalCore", targets: ["TmuxPalCore"])
    ],
    targets: [
        .target(name: "TmuxPalCore"),
        .executableTarget(
            name: "TmuxPal",
            dependencies: ["TmuxPalCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "TmuxPalTests",
            dependencies: ["TmuxPalCore"],
            resources: [.copy("Resources")]
        )
    ]
)
