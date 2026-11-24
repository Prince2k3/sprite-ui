// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpriteUI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // Umbrella product: `import SpriteUI` gives you everything.
        .library(name: "SpriteUI", targets: ["SpriteUI"]),
        // Engine-only aggregate; Game Center can be selected independently.
        .library(name: "SpriteUICore", targets: ["SpriteUICore"]),
        .library(name: "SpriteUIGameCenter", targets: ["SpriteUIGameCenter"]),
        .library(name: "SpriteUISaves", targets: ["SpriteUISaves"]),
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

        // Optional platform integration, independent of the renderer and scene host.
        .target(name: "SpriteUIGameCenter", dependencies: ["ECSCore", "Gameplay"]),
        // Optional typed persistence and GameSave integration, independent of the renderer.
        .target(name: "SpriteUISaves", dependencies: ["Gameplay"]),

        // Engine-only aggregate and integration bridges.
        .target(name: "SpriteUICore", dependencies: ["ECSCore", "SpriteBackend", "GameUI", "Gameplay", "GameplayECS"]),

        // Backward-compatible convenience import for the complete SDK.
        .target(name: "SpriteUI", dependencies: ["SpriteUICore", "SpriteUIGameCenter", "SpriteUISaves"]),
        .target(name: "DemoBotsGame", dependencies: ["SpriteUI"], path: "Examples/DemoBots/Game", resources: [.process("Resources")]),

        .testTarget(name: "ECSCoreTests", dependencies: ["ECSCore"]),
        .testTarget(name: "GameplayTests", dependencies: ["Gameplay", "GameplayECS", "ECSCore"]),
        .testTarget(name: "SpriteBackendTests", dependencies: ["ECSCore", "SpriteBackend"]),
        .testTarget(name: "SpriteUITests", dependencies: ["SpriteUI"]),
        .testTarget(name: "GameUITests", dependencies: ["GameUI", "SpriteBackend", "ECSCore"]),
        .testTarget(name: "SpriteUIGameCenterTests", dependencies: ["SpriteUIGameCenter", "ECSCore", "Gameplay"]),
        .testTarget(name: "SpriteUISavesTests", dependencies: ["SpriteUISaves", "Gameplay"]),
        .testTarget(name: "DemoBotsTests", dependencies: ["DemoBotsGame"]),
    ]
)
