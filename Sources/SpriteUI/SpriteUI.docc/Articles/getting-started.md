# Getting started

Install SpriteUI, display an entity, and choose where setup, state updates, and frame logic belong.

## Add the local package to an app

SpriteUI requires Swift 6 and deployment targets of iOS 18 or macOS 15 or later. Open an app project in Xcode, choose **File > Add Package Dependencies**, choose **Add Local**, and select the folder containing SpriteUI's `Package.swift`. Add the **SpriteUI** library product to your app target. Set the app's deployment target accordingly, then import `SpriteUI` in your scene code.

The local package already declares its module dependencies. You do not need a separate documentation package plugin or an external dependency to use the SDK. Import SwiftUI as well when declaring views, gestures, and controls.

## Display a first scene

This complete view uses a solid-color sprite, so it runs without asset files. Present `FirstScene()` from your app's window or existing view hierarchy.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct FirstScene: View {
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

``SpriteUI/GameView`` owns the world and renderer for its view identity. Its asynchronous `make` closure receives ``SpriteUI/GameViewContent``, which exposes `world`, `renderer`, and view-scoped attachments. `content.add(_:)` attaches an entity to the world; constructing an entity alone does not display it.

Positions use scene points with positive y upward. With no camera, the view centers on the scene origin. An entity's `position` is relative to its parent, and the default sprite anchor is its center. Give the view useful layout space before diagnosing missing content.

## Separate three kinds of work

| Entry point | When it runs | Put this work here |
| --- | --- | --- |
| `GameView`'s `make` closure | Initial setup for the host's identity; it can await resources | Create entities, install systems, load a level, and wire subscriptions |
| `GameView`'s `update` closure | After setup and as SwiftUI updates or observable state read there changes | Reconcile current app state into existing components |
| ``SpriteUI/System`` updates | Each advancing simulation frame | Movement, timers, decisions, and other time-dependent rules |

The `update` closure is not a display-link callback. Keep it safe to repeat: look up and modify an existing entity rather than adding another copy. Do not accumulate movement there; put elapsed-time calculations in a system.

This complete view creates one player and reflects a toggle into its sprite color:

```swift
import SpriteUI
import SwiftUI

@MainActor
struct ColorScene: View {
    @State private var isHighlighted = false

    var body: some View {
        VStack {
            Toggle("Highlight player", isOn: $isHighlighted)
            GameView { content in
                content.add(Entity(
                    name: "player",
                    components: SpriteComponent(color: .cyan, size: [40, 40])
                ))
            } update: { content in
                let player = content.world.root.findEntity(named: "player")
                player?.components[SpriteComponent.self]?.color =
                    isHighlighted ? .yellow : .cyan
            }
            .frame(minWidth: 320, minHeight: 240)
        }
    }
}
```

Changing ordinary component data does not itself create SwiftUI observation. Let observable app state drive controls, and use the closure to apply that state to the world. Name lookup is convenient for a small scene; a larger scene can keep entity references or IDs in a main-actor scene owner.

## Add frame-based movement

A component holds data; a system finds matching entities and advances their data. The following declarations form a complete, asset-free moving scene. The velocity is in local points per second, so the system multiplies by `context.deltaTime` before adding a displacement.

```swift
import SpriteUI
import SwiftUI

struct CruiseVelocity: Component {
    var pointsPerSecond: SIMD2<Float>
}

@MainActor
struct CruiseSystem: System {
    private static let movers = EntityQuery(where: .has(CruiseVelocity.self))

    init(world: World) {}

    mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: Self.movers) {
            guard let velocity = entity.components[CruiseVelocity.self] else {
                continue
            }
            entity.position += velocity.pointsPerSecond * Float(context.deltaTime)
        }
    }
}

@MainActor
struct MovingScene: View {
    var body: some View {
        GameView { content in
            content.world.addSystem(CruiseSystem.self)
            let player = Entity(components: [
                SpriteComponent(color: .cyan, size: [24, 24]),
                CruiseVelocity(pointsPerSecond: [30, 0])
            ])
            player.position = [-100, 0]
            content.add(player)
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}
```

The renderer drives frames while presenting a `GameView`; do not also call `world.update(deltaTime:)` for the same hosted world. For a world you own without a renderer, that method advances simulation and presentation systems in sequence. It does not create a graphics view or run backend physics.

Use `world.addSystem(_:)` for a known, valid setup. Use `try world.systems.add(_:)` when your app needs to handle scheduling errors. Calling `registerSystem()` on a system type affects worlds constructed afterward, so per-world installation is usually easier to reason about in reusable views.

## Read the unified documentation

From the package root, the documentation helper provides these commands:

```sh
Tools/build-documentation.sh build
Tools/build-documentation.sh check
Tools/build-documentation.sh preview
```

The default archive is `.build/documentation/SpriteUI.doccarchive`. Open that built archive in Xcode to browse the unified SDK reference. `preview` serves it at `http://localhost:8080/documentation/spriteui`. The umbrella symbol graph represents the public APIs from ECSCore, Gameplay, GameplayECS, SpriteBackend, and GameUI; DemoBots is excluded.

`check` treats DocC warnings strictly and type-checks the tutorial Swift stages. Documentation catalogs are discovered by Xcode without adding a package plugin. Use the helper's built archive when you need the unified reference; this guide does not assume Xcode's **Build Documentation** action produces the same merged result.

## Next steps

Read <doc:entity-and-scene-lifecycle> before building reusable hierarchies, then <doc:systems-and-input> for scheduling and gestures. <doc:rendering-and-resources> adds resource loading and SwiftUI attachments. For a step-by-step learning path, continue with <doc:spriteui-tutorials>.
