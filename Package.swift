// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpriteUI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // Umbrella product: `import SpriteUI` gives you everything.
        .library(name: "SpriteUI", targets: ["SpriteUI"]),
        .library(name: "ECSCore", targets: ["ECSCore"]),
        .library(name: "Gameplay", targets: ["Gameplay"]),
    ],
    targets: [
        // Pure Swift ECS: Entity, Component, System, queries, events. No SpriteKit.
        .target(name: "ECSCore"),

        // Modern GameplayKit: pure algorithms (random, state machines, pathfinding...).
        // No SpriteKit and no ECS, so it's deterministic and usable on its own.
        .target(name: "Gameplay"),

        // Thin adapters that wrap Gameplay as ECS components and systems.
        .target(name: "GameplayECS", dependencies: ["ECSCore", "Gameplay"]),

        // SpriteKit backend: mirrors entities onto SKNodes and drives the frame loop.
        .target(name: "SpriteBackend", dependencies: ["ECSCore"]),

        // SwiftUI host (RealityView-style GameView).
        .target(name: "GameUI", dependencies: ["ECSCore", "SpriteBackend"]),

        // Umbrella that re-exports the public modules.
        .target(name: "SpriteUI", dependencies: ["ECSCore", "SpriteBackend", "GameUI", "Gameplay", "GameplayECS"]),

        .testTarget(name: "ECSCoreTests", dependencies: ["ECSCore"]),
        .testTarget(name: "GameplayTests", dependencies: ["Gameplay", "GameplayECS", "ECSCore"]),
        .testTarget(name: "SpriteBackendTests", dependencies: ["ECSCore", "SpriteBackend"]),
        .testTarget(name: "SpriteUITests", dependencies: ["SpriteUI"]),
    ]
)
