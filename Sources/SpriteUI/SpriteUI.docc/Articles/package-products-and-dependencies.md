# Choose package products

Select the complete SDK, the engine without Game Center, or standalone gameplay values.

## Keep the convenience import

The `SpriteUI` library product retains the existing `import SpriteUI` API. It re-exports the engine and optional integration modules: `SpriteUICore` for the complete engine and its cross-layer bridges, `SpriteUIGameCenter` for Apple service integration, and `SpriteUISaves` for profiles and optional GameSave access. Existing applications using the umbrella do not need to change their imports.

All products remain in this one Swift package and share its release version. This separation does not introduce a remote dependency, a runtime plugin loader, or separate package repositories.

| Product | Import | Includes |
| --- | --- | --- |
| SpriteUI | `SpriteUI` | Engine plus Game Center and save integration |
| SpriteUICore | `SpriteUICore` | ECSCore, Gameplay, GameplayECS, SpriteBackend, GameUI, and cross-layer helpers |
| SpriteUIGameCenter | `SpriteUIGameCenter` | Game Center services and UI, with ECSCore and Gameplay dependencies |
| SpriteUISaves | `SpriteUISaves` | Typed player/slot persistence, quest wallet transactions, and optional GameSave; depends only on Gameplay |
| Gameplay | `Gameplay` | Pure algorithms, agents, pathfinding, quest journals, and league values |
| ECSCore | `ECSCore` | Entity model, systems, snapshots, input values, and transport-independent networking |
| DemoBotsGame | `DemoBotsGame` | The example game's implementation |

## Build an engine-only game

Choose the `SpriteUICore` product in the consuming app's target dependencies and use `import SpriteUICore`. This aggregate has no dependency on the `SpriteUIGameCenter` target. It includes ``SpriteUI/GameView`` and all engine functionality, including quest rules, ``SpriteUI/QuestJournalComponent``, input replay world helpers, noise images, and tile-map grids. Game Center services, sign-in screens, and native match transports are omitted from this product's dependency graph.

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

If the app later needs Apple services, add the `SpriteUIGameCenter` product alongside the core and import it explicitly. The full convenience product is another option. Module separation does not enable the Game Center entitlement or configure identifiers; follow <doc:game-center-services> for those steps.

## Use services without the renderer

The service target depends on ECSCore for peer/session values and Gameplay for optional progression mappings. It does not depend on SpriteBackend, GameUI, or SpriteUICore. Its built-in screens use SwiftUI directly. Add `import ECSCore` or `import Gameplay` explicitly when directly naming their types in this narrower configuration.

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

Direct `import GameUI` users who previously accessed Game Center symbols through that implementation module must now add the Game Center product and import `SpriteUIGameCenter`. There is deliberately no reverse re-export from GameUI, because that would reintroduce the dependency being removed. The `SpriteUI` umbrella remains the source-compatible route.

## Keep gameplay independent

`Gameplay` was already a standalone target and product. It has no target dependencies and does not import SpriteKit, GameKit, SwiftUI, or ECSCore. Select it alone for simulation rules, procedural generation, navigation, or progression logic outside an entity scene. Quest and league rules remain there; only their optional Apple reporting lives in SpriteUIGameCenter.

Use a separate package repository only when gameplay needs an independent release/version lifecycle or separate distribution. Splitting the repository now would add version coordination without changing these target boundaries. See <doc:quests-and-leagues> for the rules/reporting boundary and <doc:gameplay-and-movement> for the existing algorithms.

`SpriteUISaves` is independently selectable and has no renderer or Game Center dependency. SpriteUICore and SpriteUIGameCenter do not depend on it. Local profiles support iOS 18/macOS 15; its GameSave adapter requires iOS/macOS 26+. See <doc:player-profiles-and-cloud-saves>.
