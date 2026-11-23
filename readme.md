---
title: SpriteUI
tags: [spriteui, library, documentation]
created: 2026-11-23
updated: 2026-11-23
status: active
type: permanent
---

# SpriteUI

SpriteUI brings a RealityKit-style entity-and-component API to 2D games, with SpriteKit rendering and a SwiftUI host. Add entities to a `GameView`, describe them with value components, and run frame logic in query-driven systems.

## Requirements

- Swift 6 and an Xcode toolchain that supports it.
- iOS 18 or macOS 15 or later.
- Python 3 for the documentation commands; XcodeGen only when regenerating the example app projects.

## Installation

In your SwiftUI app's Xcode project, choose **File > Add Package Dependencies > Add Local**, then select this checkout's root folder. Add the **SpriteUI** library product to your app target and set its deployment target to iOS 18 or macOS 15 or later.

For a package alongside this checkout, add a local dependency and link its product:

```swift
// In your Package.swift, inside Package(...):
dependencies: [
    .package(path: "../swiftui-ecs")
],
targets: [
    .target(
        name: "MyGame",
        dependencies: [.product(name: "SpriteUI", package: "swiftui-ecs")]
    )
]
```

Adjust the path to your checkout. Import `SpriteUI` to use the complete library. Smaller library products expose `ECSCore` and `Gameplay` separately; `DemoBotsGame` contains the example game's implementation. [[Package.swift]] defines the products, and [[Sources/SpriteUI/SpriteUI.swift]] re-exports the SDK modules.

## Quick start

This complete view displays a cyan square without requiring any assets. Present `ContentView()` from your app's window.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    var body: some View {
        GameView { content in
            let player = Entity(
                name: "player",
                components: SpriteComponent(color: .cyan, size: [40, 40])
            )
            player.position = [0, 0]
            content.add(player)
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}
```

With no camera, the scene origin is at the view's center. Positions are in points, with positive y upward, and an entity's position is relative to its parent.

- **Entities** provide identity, hierarchy, and transforms.
- **Components** hold data describing appearance, movement, collisions, and game state.
- **Systems** query entities and update their components each simulation frame.
- **Events** connect systems, scene owners, and app interfaces without coupling their implementations.

Create entities and install systems in `GameView`'s setup closure. Use its `update` closure to apply SwiftUI state to existing entities; use a `System` for movement and other elapsed-time work. The `update` closure runs with SwiftUI updates, rather than once per simulation frame.

## Features

| Area | Included tooling |
| --- | --- |
| Scene structure | Entity hierarchies, relative transforms, activation, prefabs, cloning, and pooling |
| Simulation | Query-driven systems, scheduling, typed events, pause, and time control |
| Rendering | Sprites, shapes, text, materials, cameras, single-world split screen and minimaps, lighting, masks, and effects |
| Resources | Scene and tile-map loading, resource caching, animation and audio playback |
| Movement | Collision shapes and queries, character controllers, physics bodies, joints, and transform constraints |
| Gameplay | Agents and goals, pathfinding, navigation meshes, spatial indexes, state machines, decisions, rules, strategists, noise, and seeded random generators |
| Input | Observable actions, stacked and Codable binding maps, virtual controls, focused hardware input, explicit local-player device ownership, adaptive prompts, and capability-checked controller feedback |
| Presentation | Automatic entity dragging, rotation, and scaling; targeted gestures; SwiftUI attachments; particles and contact effects |
| Persistence and debugging | Registered component snapshots, entity-reference remapping, scene inspection, and frame diagnostics |

## Package modules

| Module | Responsibility |
| --- | --- |
| `SpriteUI` | Umbrella import for the complete SDK and bridges between gameplay and rendering |
| `ECSCore` | Entities, components, transforms, events, scheduling, and snapshots |
| `Gameplay` | Standalone algorithms and value types |
| `GameplayECS` | Components and systems that adapt gameplay algorithms to entities |
| `SpriteBackend` | SpriteKit rendering, physics, resources, playback, and scene services |
| `GameUI` | SwiftUI hosting, attachments, input, and inspection interfaces |

The module boundaries let pure gameplay algorithms run independently of rendering. Most apps can start with `import SpriteUI`.

## Documentation and tutorials

The DocC catalog lives in [[Sources/SpriteUI/SpriteUI.docc/SpriteUI.md]]. It includes a getting-started guide, conceptual articles, the public API reference, and seven hands-on tutorials covering your first scene, systems and targeted input, collision-aware agents, player input actions, direct entity manipulation, local-player device ownership and feedback, and shared-world viewports.

The tutorial sequence includes complete Swift code for every stage and expected-result illustrations:

1. **Creating your first scene:** add entities, arrange them, and change component data from SwiftUI.
2. **Moving with systems and input:** implement frame-based movement, targeted taps, and pause/resume.
3. **Steering and collision-aware movement:** combine agent goals, collision queries, character movement, and a route around a wall.
4. **Controlling a player with input actions:** build on-screen controls, read held 2D movement from a system, observe press transitions, and add optional keyboard, pointer, and gamepad bindings. No physical keyboard or gamepad is required.
5. **Manipulating sprites with gestures:** opt into automatic drag, rotation, and scale, constrain a child under a rotated and scaled parent, observe lifecycle events, and add accessible session controls with physics release.
6. **Sharing devices between players:** create independent action sessions, assign two virtual pads, transfer held input through neutral, and add adaptive prompts and optional native controller feedback. All three stages run without physical hardware.
7. **Sharing a world between viewports:** create two cameras in one world, drive independent players with virtual buttons, change side-by-side, stacked, and single layouts, then add a third-camera minimap, viewport-scoped selection, labels, and actual simulation counters. All three stages are complete replacements for `ContentView.swift`; no hardware is required. [[Sources/SpriteUI/SpriteUI.docc/Tutorials/sharing-a-world-between-viewports.tutorial]] links the staged Swift and SVG previews.

The ten guides cover getting started, entity and scene lifecycle, systems and input, input actions and controllers, player input sessions and feedback, direct manipulation, gameplay and movement, rendering and resources, viewports and split screen, and saving and debugging. [[Sources/SpriteUI/SpriteUI.docc/Articles/input-actions-and-controllers.md]] explains context priority, cancellation and dead zones, shared controller ownership, and persisted rebinding.

[[Sources/SpriteUI/SpriteUI.docc/Articles/player-input-sessions-and-feedback.md]] explains exclusive device ownership, transfer cancellation, last meaningful input, remapped control presentations, and feedback results. The **Players** tab in [[Demo/SpriteUIDemo/PlayerInputDemoView.swift]] has two independently moving sprites, assignable virtual pads, a live device list, adaptive Fire hints, and feedback outcome readouts. Tap a direction to hold it, transfer its pad, release, then press again to exercise neutral gating. Assign real controllers when available; none are required. Keyboard and pointer entries represent logical sources rather than hardware discovery. Sessions and assignments are runtime state; save action maps instead.

[[Sources/SpriteUI/SpriteUI.docc/Articles/manipulating-entities.md]] covers parent-local axis locks, bounds and snapping, uniform local scale limits, lifecycle events, and renderer sessions. Add `InputTargetComponent` plus `ManipulationComponent` for automatic `GameView` gestures without an explicit `.gesture` modifier. The [[Demo/SpriteUIDemo/ManipulationDemoView.swift]] playground includes free, constrained-child, and dynamic-body examples with accessible buttons. Physics capture temporarily suspends native bodies without changing component configuration; end/cancel restores dynamics with zero release velocity by default, or `.restoreVelocity`. Placement does not avoid collisions or throw on release. Character-controller, transform-constraint, and joint-connected ownership deliberately reject manipulation.

[[Sources/SpriteUI/SpriteUI.docc/Articles/viewports-and-split-screen.md]] covers the single-world Metal viewport host, normalized top-left frames, stable string viewport IDs and camera entity IDs, overlap/input rules, camera bounds, and attachment projection. The **Viewports** tab in [[Demo/SpriteUIDemo/ViewportDemoView.swift]] keeps a 360-point-tall arena above two independent virtual pads. Tap an arrow to keep moving and Stop to release; switch layouts without rebuilding the world. The third-camera map blocks scene input beneath it. Tap entities in a player pane to select only there; name labels project in every viewport, while selection labels use a specific `viewportID`. Optional keyboard and controller assignment is below the controls. One hub is attached once to the game surface.

Its world-update, presentation-completion, and physics-contact counters count actual event callbacks, and scene time sums actual update deltas. They stay continuous through layout changes. Counts are not multiplied by pane count, and presentation completion is not a GPU-pass count. The bouncing probe supplies real contacts; exact totals depend on elapsed simulation. Supplying `viewports: []` chooses one automatic-camera Metal view; omitting the argument preserves the legacy host. The checked-in demo project lists files explicitly: after adding new demo sources, regenerate it with `xcodegen generate` from `Demo/` before building.

With Xcode command-line tools and Python 3 installed, run from the repository root:

```sh
# Build a DocC archive and a static-hosting site.
Tools/build-documentation.sh

# Also type-check every tutorial stage and guide example in Swift 6.
Tools/build-documentation.sh check

# Rebuild on documentation edits and browse locally.
Tools/build-documentation.sh preview
```

Browse `http://localhost:8080/documentation/spriteui` during preview. Open `.build/documentation/SpriteUI.doccarchive` in Xcode to read the generated archive in its Documentation window. Stop preview with Control-C.

For a site hosted under a subdirectory, specify its base path:

```sh
Tools/build-documentation.sh build --hosting-base-path SpriteUI
```

You can change the output directory with `--output /path/to/SpriteUI.doccarchive` and the preview port with `--port 8081`. These commands build local files; publishing them is a separate step.

[[Tools/documentation.py]] extracts SwiftPM symbol graphs, restores source comments on the umbrella module's re-exported symbols, and verifies that all public APIs are present. It normalizes module-qualified documentation links for the single SpriteUI archive. DocC warnings fail the build, and generated graphs, logs, diagnostics, and archives stay under the ignored `.build/documentation/` directory. No documentation plugin or network dependency is added to the package.

## Working on the documentation

The catalog uses native [DocC markup](https://www.swift.org/documentation/docc/), including symbol links, articles, tutorial directives, images, and complete Swift code resources. Keep catalog page titles first, as required by DocC.

Edit articles under `Sources/SpriteUI/SpriteUI.docc/Articles/`, tutorials under `Tutorials/`, and their staged code and illustrations under `Resources/`. Every code stage is a complete view or scene implementation that can replace the preceding stage. Run `Tools/build-documentation.sh check` before committing documentation changes. The script checks links and tutorial structure, every standalone tutorial stage, and every Swift guide example (combining explicitly marked fragments with their preceding example); its diagnostic report is `.build/documentation/diagnostics.json`.

The new top-level `Tools/` folder contains documentation tooling. The `.docc` directory is documentation source for the SpriteUI target; it is not an app resource bundle. Existing source modules and example layouts remain in place.

## Example apps

- **Feature demo:** open `Demo/SpriteUIDemo.xcodeproj` and run the **SpriteUIDemo** scheme on an iOS simulator. Its tabs demonstrate individual SDK features.
- **DemoBots:** open `Examples/DemoBots/DemoBots.xcodeproj` and choose **DemoBots** for iOS or **DemoBotsMac** for macOS. [[Examples/DemoBots/readme.md]] describes controls, checkpoints, scene tools, and the features used by the game.

Both projects reference the local package. To regenerate either project, run `xcodegen generate` in its containing directory.

## Build and test

From the repository root:

```sh
swift build
swift test
```

Package tests use Swift Testing. Run `Tools/build-documentation.sh check` when changing documentation or its examples. App interaction and graphics checks run in the example apps on a simulator or device.
