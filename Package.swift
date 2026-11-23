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
        .library(name: "DemoBotsGame", targets: ["DemoBotsGame"]),
    ],
    targets: [
        // Pure Swift ECS: Entity, Component, System, queries, events. No SpriteKit.
        .target(name: "ECSCore"),

        // Pure algorithms: random, state machines, pathfinding, and more.
        // No SpriteKit and no ECS, so it's deterministic and usable on its own.
        .target(name: "Gameplay"),

        // Thin adapters that wrap Gameplay as ECS components and systems.
        .target(name: "GameplayECS", dependencies: ["ECSCore", "Gameplay"]),

        // SpriteKit backend: mirrors entities onto SKNodes and drives the frame loop.
        .target(name: "SpriteBackend", dependencies: ["ECSCore", "Gameplay"]),

        // SwiftUI host (RealityView-style GameView).
        .target(name: "GameUI", dependencies: ["ECSCore", "SpriteBackend"]),

        // Umbrella that re-exports the public modules.
        .target(name: "SpriteUI", dependencies: ["ECSCore", "SpriteBackend", "GameUI", "Gameplay", "GameplayECS"]),
        .target(name: "DemoBotsGame", dependencies: ["SpriteUI"], path: "Examples/DemoBots/Game", resources: [.process("Resources")]),

        .testTarget(name: "ECSCoreTests", dependencies: ["ECSCore"]),
        .testTarget(name: "GameplayTests", dependencies: ["Gameplay", "GameplayECS", "ECSCore"]),
        .testTarget(name: "SpriteBackendTests", dependencies: ["ECSCore", "SpriteBackend"]),
        .testTarget(name: "SpriteUITests", dependencies: ["SpriteUI"]),
        .testTarget(name: "GameUITests", dependencies: ["GameUI", "SpriteBackend", "ECSCore"]),
        .testTarget(name: "DemoBotsTests", dependencies: ["DemoBotsGame"]),
    ]
)
