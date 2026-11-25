# Switch levels while keeping the player

When the player walks from a garden into a workshop, the room should change while their score, identity, and controls remain. The next room may need time to load, and a failed load should leave the garden playable.

Use the game view's ``SpriteUI/LevelCoordinator`` to replace the current level's hierarchy inside the existing world. Keep the player and camera outside that hierarchy when they must survive the switch.

## Load a room as one hierarchy

Build a detached root in `content.levels.load`, then return it. The coordinator installs that root and replaces only the previous root it managed. Other top-level entities remain in the world.

This first room is a mint rectangle. An instant load gets it on screen without needing an outgoing frame.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct ContentView: View {
    var body: some View {
        GameView(viewports: []) { content in
            do {
                try await content.levels.load(id: "Garden", transition: .instant) { context in
                    Entity(name: context.id, components:
                        SpriteComponent(color: .mint, size: [160, 100]))
                }
            } catch {
                // Present this error through your app's observable scene owner.
                print(error)
            }
        }
    }
}
```

Do not add the prepared root to the world yourself. The coordinator validates it, installs it, selects a requested camera if provided, and runs activation callbacks. Using `content.levels` connects loading to the view's transition presenter. Here, `viewports: []` selects one full-size automatic-camera Metal surface.

## Choose how the room changes on screen

| Transition | What the player sees |
| --- | --- |
| `.instant` | The next room appears after preparation succeeds. |
| `.fade(duration: 0.8)` | The game fades to black for 0.4 seconds, changes rooms, then fades in for 0.4 seconds. |
| `.crossFade(duration: 0.8)` | A still image of the outgoing room fades over the live incoming room for 0.8 seconds. |

The default is `.fade()` over 0.35 seconds. A first animated load fades in because there is no outgoing room. Crossfade captures pixels rather than running both rooms: a persistent moving player may briefly appear in both the captured and current positions. Entity attachments are not in that captured image.

The default transition overlay sits above native game content and attachments. Controls outside the game view need your own input policy. The animation uses elapsed real time, so it can finish while simulation is paused.

## Preserve the player and camera

Add persistent entities to the world, then call `preserve(_:)` before loading. This moves them directly under `world.root` while retaining their world transforms. You can also promote a child out of an existing room before the next switch.

```swift
import SpriteUI

struct PlayerProgress: Component, Codable {
    var score = 0
}

@MainActor
func installPlayer(in content: GameViewContent) throws -> (player: Entity, camera: Entity) {
    PlayerProgress.registerComponent()
    let player = Entity(name: "Player", components:
        SpriteComponent(color: .cyan, size: [28, 28]), PlayerProgress())
    let camera = Entity(name: "Camera", components: CameraComponent(smoothing: 0))
    content.add(player)
    content.add(camera)
    try content.levels.preserve(player)
    try content.levels.preserve(camera)
    return (player, camera)
}
```

Retain those references in your scene owner. The same entity IDs, components, resource handles, and runtime player sessions survive later loads. Input sessions do not need a disconnect/reconnect cycle.

Set `context.camera` during preparation to select the persistent camera or an enabled camera in the incoming hierarchy. A camera outside the allowed hierarchy is rejected. If outgoing cleanup removes an already validated persistent camera, installation falls back to automatic selection.

Keep room-specific floors, decorations, and counters under the level root. Keep progress that must survive outside it. You cannot preserve the world root, the managed level root, or an entity from another world. <doc:entity-and-scene-lifecycle> explains hierarchy ownership more broadly.

## Prepare resources while the old room keeps playing

Each ``SpriteUI/LevelContext`` has a ``SpriteUI/ResourceLibrary`` for that request. Await room textures, audio, or prefabs there while assembling the detached hierarchy. During preparation, the outgoing room continues to simulate and accept input.

This helper loads `coin.wav` from the app bundle and plays it after the new room is installed. Bundle that file before using the helper. A resource error reaches the caller and leaves the old room intact.

```swift
import SpriteUI

@MainActor
func loadGarden(using levels: LevelCoordinator) async throws {
    try await levels.load(id: "Garden", transition: .fade()) { context in
        let chime = try await context.resources.audio(named: "coin.wav")
        try Task.checkCancellation()
        let root = Entity(name: context.id)
        let floor = Entity(components:
            SpriteComponent(color: .mint, size: [280, 12]),
            PhysicsBodyComponent(shape: .rectangle(size: [280, 12]), isDynamic: false))
        floor.position = [0, -76]
        root.addChild(floor)
        context.onActivate { installedRoot in
            _ = try? installedRoot.playAudio(chime, volume: 0.15)
        }
        return root
    }
}
```

Use `onActivate` for work that needs the installed root, such as starting room audio or resetting a visible room counter. A callback created during preparation should check that its root is attached before doing room work.

Pass room event subscriptions to `context.retain(_:)` and external cleanup to `context.onUnload(_:)`. When preparation fails, is cancelled, or an installed room is replaced, the coordinator cancels retained subscriptions, runs cleanup once, and closes its resource library. Already loaded immutable handles remain usable; later loads through the disposed context throw cancellation. Let the coordinator remove its own root rather than detaching it in cleanup.

For a prefab, load through `context.resources.prefab(named:)` and return its detached instance. Procedural sprites or textures can be built directly without loading a file. <doc:rendering-and-resources> covers those resource choices.

## Keep loading and gameplay controls responsive

Own the load task in the scene model, report errors in observable state, and disable duplicate load requests while one is pending. Cancel the task and call `levels.cancel()` when leaving the view. Forward setup cancellation to any initial load task owned by the model.

Use `blocksInput` for gameplay controls. Preparation leaves play available; fading, installation, and crossfade block it. The host cancels and suppresses its routed gestures, attachment actions, and attached controllers or hubs during those phases, then resumes through neutral input. Disable external gameplay buttons too, while keeping a Cancel button outside the surface available.

`isLoading` is useful for a load button, but using it for every gameplay control would also block the preparation time when the outgoing room can still run.

## Know which room remains after cancellation

Before installation commits, cancelling restores the outgoing visuals and keeps the old room. After commit, it finishes the visual transition and keeps the new root. Read `currentID` to find which level survived. Disappearance cancels a pending transition while retaining the committed room.

A failed preparation or invalid incoming hierarchy leaves the outgoing room intact before commit. A newer request supersedes an older one; a stale root never installs even if its preparation ignores cancellation. Check cancellation in your own loops and after awaits to release work promptly.

Observe `LevelEvents.DidLoad`, `DidFail`, and `DidCancel` for app-wide status. Cancellation includes a `committed` flag. Keep these subscriptions in the scene owner, separate from subscriptions that belong to a room. Invalid IDs and durations throw before a request starts and do not emit `DidFail`.

## Limits to keep in mind

Animated loads need an available presentation bridge and usable surface; crossfade also needs a usable outgoing frame. Missing presentation throws `LevelLoadingError.presentationUnavailable` rather than advancing simulation to manufacture a frame. A standalone `LevelCoordinator(world:)` can load instantly without a presenter. Zero duration is instant; other animated durations must be finite, positive, and no more than 30 seconds.

Do not reenter loading or preservation during installation. Coordinator tasks, subscriptions, and player sessions are runtime state rather than snapshot data; use <doc:saving-and-debugging> for saved component state.

Continue with <doc:switching-levels-with-persistent-players> to build two rooms and test successful loads, failures, and cancellation with the same player.

## See also

- <doc:parallax-and-repeating-backgrounds>
- <doc:player-input-sessions-and-feedback>
