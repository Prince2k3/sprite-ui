# Choosing a package product

You want to put a game scene in a SwiftUI app. Later, you might want its movement rules in a separate simulation, or Game Center in a menu that has no scene. Choose the library product that supplies the part you need.

## Start with one import

Add the **SpriteUI** product to use the engine, Game Center integration, and save integration through `import SpriteUI`. This is the import used by the core lessons, including <doc:getting-started>.

All products live in the same Swift package and share its release version. You can select narrower products as your app's needs become clearer.

| Product | Choose it for |
| --- | --- |
| `SpriteUI` | The engine and optional integrations through one import |
| `SpriteUICore` | The complete engine, including `GameView`, without Game Center or save integration |
| `SpriteUIGameCenter` | Apple game services and their SwiftUI screens |
| `SpriteUISaves` | Typed player profiles and save slots, quest wallet transactions, and optional GameSave access |
| `Gameplay` | Algorithms and gameplay values without a scene or renderer |
| `ECSCore` | Entities, systems, snapshots, input values, and transport-independent networking |

## Build a scene with the engine alone

If your app does not need the service integrations, add **SpriteUICore** to its target and import that module. The same scene APIs are available, including rendering, input, gameplay adapters, and cross-layer helpers.

```swift
import SpriteUICore
import SwiftUI

@MainActor
struct EngineOnlyView: View {
    var body: some View {
        GameView { content in
            let entity = Entity(name: "player")
            entity.components.set(SpriteComponent(color: .mint, size: [24, 24]))
            content.add(entity)
        }
    }
}
```

This view works like the first scene in <doc:getting-started>. Choosing the core changes which modules your app depends on; it does not change how entities appear in a `GameView`.

To add Apple services later, select **SpriteUIGameCenter** alongside the core and import it. You can also switch to the **SpriteUI** umbrella.

## Put services in a menu without a renderer

A menu can present Game Center UI without depending on the game renderer. **SpriteUIGameCenter** uses ECSCore for peer and session values and Gameplay for progression mappings. It does not depend on SpriteBackend, GameUI, or SpriteUICore.

This example uses preview services for a practice player.

```swift
import ECSCore
import SpriteUIGameCenter
import SwiftUI

@MainActor
struct ServicesOnlyMenu: View {
    @State private var services = GameCenterServices.preview(player:
        NetworkPeer(id: .init(rawValue: "practice"), displayName: "Practice"))

    var body: some View {
        GameCenterServicesView(services: services)
            .gameCenter(services)
    }
}
```

Import `ECSCore` or `Gameplay` when directly naming their types in this arrangement. If a view imports `GameUI` directly, add and import `SpriteUIGameCenter` to use service symbols.

## Reuse game rules outside the scene

Choose **Gameplay** when you need pathfinding, agents, procedural generation, quests, or league values on their own. It has no target dependencies and does not import SpriteKit, GameKit, SwiftUI, or ECSCore. <doc:gameplay-and-movement> shows how these calculations can then drive entities through the engine's adapters.

Choose **SpriteUISaves** for profiles and save slots without adding a renderer or Game Center. It depends only on Gameplay; neither SpriteUICore nor SpriteUIGameCenter depends on it.

## Platform requirements

Build with Xcode 27.2, the tested toolchain, or a compatible newer version supplying the required SDK. The package uses Swift 6 and supports deployment to iOS 18 or macOS 15 and later. Local profiles use those deployment targets; the optional GameSave adapter requires iOS or macOS 26 or later. Adding a Game Center library does not configure entitlements or service identifiers for your app.

## Next lesson

Continue with <doc:getting-started> to build a scene. If you are adding persistence or services, read <doc:player-profiles-and-cloud-saves> or <doc:game-center-services> for the required setup.
