# SpriteUI

A RealityKit-style API for 2D games, powered by SpriteKit and SwiftUI.

Build scenes from entities and value components, run gameplay in query-driven
systems, and present your game with `GameView`.

## Installation

Deployment targets start at iOS 18 and macOS 15; newer platform features are availability-gated.

Add `https://github.com/Prince2k3/sprite-ui.git` in Xcode's **File → Add Package
Dependencies** and select **Exact Version: 0.5.0** once the release tag is published.
Choose **SpriteUI** for the complete SDK, or **SpriteUICore** for the engine without
Game Center and cloud-save integration.

In a Swift package, add:

```swift
.package(url: "https://github.com/Prince2k3/sprite-ui.git", exact: "0.5.0")
```

Link the chosen library to your app target. To use a local checkout,
choose **Add Local** instead.

SpriteUI is pre-1.0. Pin an exact version and review [[changelog]] before upgrading.

## Your first scene

Present this view from your app's window. No assets are required.

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

Without a camera, the origin is the view's center and positive y points upward.
Entity positions are relative to their parent. Create scenes in the setup closure;
use systems for per-frame logic. The optional `GameView` update closure follows
SwiftUI updates, rather than the simulation clock.

## What's included

- **Scene composition:** relative transforms, activation, prefabs, pooling, and level transitions.
- **Rendering:** sprites, shapes, text, cameras, tile maps, particles, audio, viewports, and SwiftUI attachments.
- **Movement:** agent goals, navigation, collision queries, character controllers, physics, and joints.
- **Input:** actions, rebinding, touch and controllers, local-player sessions, and recording/replay.
- **Simulation and diagnostics:** fixed ticks, interpolation, snapshots, scene inspection, and opt-in profiling.
- **Optional services:** Game Center, replication, quests, leagues, player profiles, and cloud saves.

## Libraries 

| Library | Use it for |
| --- | --- |
| `SpriteUI` | Complete SDK |
| `SpriteUICore` | Complete engine without Game Center or cloud-save integration |
| `Gameplay` | Standalone gameplay algorithms without ECS or rendering |
| `ECSCore` | Entity model, systems, events, snapshots, and networking primitives |
| `SpriteUIGameCenter` | Optional Game Center services and session integration |
| `SpriteUISaves` | Optional player profiles, local persistence, and cloud saves |

[[Sources/SpriteUI/SpriteUI.docc/Articles/package-products-and-dependencies.md]]
explains product boundaries and imports.

## Learn and explore

**[Read the documentation and tutorials online](https://prince2k3.github.io/sprite-ui/documentation/spriteui/)**

## License

SpriteUI is MIT-licensed; see `LICENSE`. Apple-derived DemoBots material retains
its separate license in `Examples/DemoBots/APPLE-LICENSE.txt`.
