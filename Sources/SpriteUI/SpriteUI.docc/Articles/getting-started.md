# Getting started

Start with a player on an empty screen. Once it appears, give it a color controlled by SwiftUI, then make it move over time. These three steps show where scene setup, app state, and game rules belong.

## Put a player on screen

Build with Xcode 27.2, the tested toolchain, or a compatible newer version. The source requires its build SDK even though your app can deploy to iOS 18 or macOS 15 and later. SpriteUI uses Swift 6.

In Xcode, choose **File > Add Package Dependencies**, enter `https://github.com/Prince2k3/sprite-ui.git`, and select **Exact Version: 0.5.0**. Add the **SpriteUI** library to your app target. If you already have a local checkout, choose **Add Local** instead and select the folder containing `Package.swift`.

A ``SpriteUI/GameView`` gives your SwiftUI layout a place to draw a game. Inside it, create an ``SpriteUI/Entity`` for the player. The entity gives the player an identity; its ``SpriteUI/SpriteComponent`` supplies the color and size.

This view needs no image files. Present `FirstScene()` from your app's window or an existing view.

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

`content.add(player)` puts the player in the view's ``SpriteUI/World``. Creating an entity alone does not display it. The world holds the scene's entities, and the view's renderer draws them.

The origin is at the center when there is no camera, and positive y points upward. A sprite is centered on its position by default. Here, `[0, 0]` places the cyan square in the middle of the view. The frame gives it room in the SwiftUI layout.

## Let a SwiftUI control change the player

Suppose a toggle should highlight the player. Create the player once, then change the existing sprite when the toggle changes.

`GameView` has a setup closure called `make` and an `update` closure for applying current app state. Setup can also await resources. The update closure runs after setup and as SwiftUI updates or the observable values read there change.

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

The setup closure adds one named player. The update closure finds it and sets its color from `isHighlighted`. Because the closure can run again, it edits the existing player each time.

Keep the toggle's state in SwiftUI. Ordinary component data does not automatically make a view observe it. Name lookup is convenient here; as a scene grows, a scene owner can retain entity references or IDs.

## Move the player every frame

A player moving at 30 points per second needs a different kind of update. Its movement depends on elapsed game time, rather than a change to a SwiftUI control.

Put the speed in a component and the movement rule in a ``SpriteUI/System``. A system asks the world for entities with the data it needs. Here, `CruiseSystem` finds entities with `CruiseVelocity` and advances each position by speed multiplied by elapsed seconds.

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

`addSystem` installs the movement rule in this world. Adding `CruiseVelocity` makes the player match the system's query. The sprite starts to the left and moves right, even when no SwiftUI state changes.

The speed uses the entity's local coordinates. With no parent transform in this example, those match scene coordinates. <doc:systems-and-input> shows movement that also works under rotated or scaled parents.

The three places for work now have distinct jobs: setup creates the player, the view's update closure applies the toggle, and a system advances movement. Use that division as you add more game rules.

## Before you continue

`GameView` drives its world's frames. Calling `world.update(deltaTime:)` yourself on that same world would advance it again. That method is for worlds you advance without a renderer; it does not run backend physics.

For setup that needs to handle scheduling errors, use `try world.systems.add(_:)`. `registerSystem()` affects worlds created afterward, while per-world installation affects the world in front of you.

## Next lesson

Read <doc:entity-and-scene-lifecycle> to attach a label to the player and keep related entities together. For a guided sequence of examples, follow <doc:spriteui-tutorials>.
