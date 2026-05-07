// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tmux-ai-pet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "tmux-ai-pet", targets: ["TmuxAiPet"]),
        .library(name: "TmuxAiPetCore", targets: ["TmuxAiPetCore"])
    ],
    targets: [
        .target(name: "TmuxAiPetCore"),
        .executableTarget(
            name: "TmuxAiPet",
            dependencies: ["TmuxAiPetCore"]
        ),
        .testTarget(
            name: "TmuxAiPetTests",
            dependencies: ["TmuxAiPetCore"],
            resources: [.copy("Resources")]
        )
    ]
)
