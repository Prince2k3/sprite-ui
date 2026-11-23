# Scene transitions and level management

Replace a level's hierarchy inside one retained world while keeping player identity, state, and camera selection.

## Overview

Use ``SpriteUI/GameViewContent/levels`` to load through the coordinator already connected to your game surface. ``SpriteUI/LevelCoordinator`` owns one current level root, its preparation resource library, and its cleanup callbacks. The world, game view, and runtime player input sessions remain in place. Continue from <doc:entity-and-scene-lifecycle> and <doc:parallax-and-repeating-backgrounds>, or follow <doc:switching-levels-with-persistent-players> for three complete, asset-free `ContentView.swift` replacements.

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

Return a detached root from preparation. Do not add it to the world yourself. The coordinator validates it, replaces only its previous managed root, selects an optional prepared camera, and calls activation callbacks after installation. Top-level entities outside the managed root are left alone. The empty viewport list selects one automatic-camera Metal surface; the tutorial and Levels demo use this presentation path for a full-surface crossfade.

## Choose a transition

| Transition | Behavior |
| --- | --- |
| `.instant` | Installs immediately after successful preparation. No captured frame is required. |
| `.fade(duration: 0.8)` | Fades the surface to black for 0.4 seconds, replaces the root, then fades in for 0.4 seconds. |
| `.crossFade(duration: 0.8)` | Captures one outgoing rendered frame, installs the new root, and fades that image over the live incoming world for 0.8 seconds. |

The default load transition is `.fade()` with a total duration of 0.35 seconds. Zero duration behaves as instant. Animated durations must be finite, positive, and at most 30 seconds; invalid values throw `LevelLoadingError.invalidTransition`. A first animated load has no outgoing level and fades in. The examples load their first room with `.instant`, allowing the native surface to become ready before a later animated switch.

Crossfade freezes outgoing pixels; it does not run a second simulation. Its image includes persistent sprites as they appeared in the outgoing frame, so a moving persistent sprite can appear in both the captured and live positions until the image fades. SwiftUI entity attachments are not included in the capture. The default game view supplies the transition overlay above native content and attachments; application controls outside the game view remain your responsibility.

Animations use elapsed wall-clock time on the main actor and finish even when world simulation is paused. Positive animated loads require an available presentation bridge and a usable game surface. Crossfade additionally requires a usable outgoing frame. An unavailable or hidden surface throws `LevelLoadingError.presentationUnavailable`; the coordinator does not manufacture a frame by advancing simulation. A coordinator you construct with `LevelCoordinator(world:)` can perform instant loads without a presenter; use the view's `content.levels` for normal animated UI.

## Promote persistent entities before loading

Add your player and camera to the same world, then call `preserve(_:)` before the first load. Preservation reparents an entity directly under `world.root` as a persistent sibling of the managed level root, preserving its world transform. There is no additional persistent container. Promoting an existing level child before the next switch also works.

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

Keep these entity references in your scene owner. The same entity IDs, components, resource handles, and runtime player sessions survive later level switches. Persistent input sessions need no detach/reconnect cycle. Set `context.camera` to your persistent camera or an enabled incoming camera when you want explicit selection at commit. A camera outside the allowed hierarchy is rejected.

If outgoing-level cleanup removes the requested persistent camera after prevalidation, the coordinator falls back to automatic camera selection at commit.

You cannot preserve the world root, the current managed level root, or an entity from another world. Preservation and reentrant loading during installation throw `busy`. The tutorial registers custom Codable progress and counter components before snapshots could be taken; the coordinator itself and its tasks, subscriptions, and player sessions are runtime state rather than snapshot data. See <doc:saving-and-debugging> for save/restore boundaries.

## Prepare resources inside the request

Each ``SpriteUI/LevelContext`` has its own ``SpriteUI/ResourceLibrary``. Await textures, audio, or prefab loads there and assemble a detached hierarchy. The outgoing room continues its normal simulation and accepts input while phase is `preparing`.

The following helper assumes the app bundles `coin.wav`, as the demo app already does. It performs a real cached audio load during preparation and starts a voice after activation. Resource errors propagate to the caller and keep the outgoing room intact.

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

Likewise, `try await context.resources.prefab(named: "Garden.prefab")` followed by `instantiate()` returns a detached resource instance, or load a texture and attach its handle with `SpriteComponent(texture:)`. Prepare the corresponding files in your app bundle first. Procedural roots and `TextureResource(image:)` need no bundle assets, filesystem writes, or library load; the tutorial uses that path throughout. Constructing a procedural texture is distinct from preloading a file through the resource library.

Keep physics bodies, room decorations, room counters, and their subscriptions under the managed level scope. Keep player progress outside it. Use `onActivate` for work that needs an installed root, such as resetting a displayed room counter or starting audio. A `WorldEvents.Update` subscription may be created during preparation, so its callback should check that the prepared root is actually attached before doing room work.

Pass level subscriptions to `context.retain(_:)`. Register external cleanup with `context.onUnload(_:)`. Disposal cancels retained subscriptions first, runs cleanup once, and clears the request's resource cache. It occurs when preparation fails or is cancelled, or when a successfully installed level is later replaced. Already retained immutable resource handles remain valid. Never manually detach coordinator-owned roots inside these callbacks. After disposal, a late `onActivate` registration is ignored, a late `onUnload` registration executes immediately, and a retained subscription is cancelled immediately.

Disposal also closes the per-level resource library, so future loads through a retained context throw `CancellationError`, while already loaded handles remain usable by persistent entities.

## Own loading tasks and gate external controls

Retain a load task in the view's observable scene owner. Cancel it and call `levels.cancel()` on disappearance, and forward cancellation of the async game-view setup closure to any model-owned initial task. Catch errors in that task and publish a visible status message. The tutorial files include this ownership pattern and clear their handles when work finishes; button actions do not launch untracked loads.

| State | Gameplay and external controls |
| --- | --- |
| `idle` | Gameplay active; a new load can start. |
| `preparing` | Outgoing room keeps running; player movement and score controls remain usable. |
| `fadingOut`, `installing`, `fadingIn`, `crossFading` | `blocksInput` gates game input; disable external gameplay controls too. |

Use `isLoading` or a model's pending-task flag to disable duplicate load controls. Use `blocksInput` for gameplay controls rather than disabling them throughout preparation. Keep Cancel outside the game surface, enabled during both preparation and transitions. The default host suppresses targeted gestures, manipulation, attachment actions, keyboard/gamepad actions, and attached input controllers/hubs while blocked, then resumes neutral input. It preserves user enablement preferences, assignments, backend ownership, and player identity. The host cancels a pending transition when it disappears and retains the committed level.

## Handle cancellation, failure, and replacement

Before commit, cancellation restores the old visuals and keeps the outgoing level. After commit, cancellation finishes the visual transition and keeps the incoming root. The displayed `currentID` tells you which level survived. `cancel()` during installation defers until the hierarchy is coherent.

A failed preparation, invalid detached root, ID, camera, or duration leaves the outgoing root intact before commit. Newer requests supersede older ones. Even if an old preparation ignores cancellation and eventually returns, its stale root never attaches. Cooperate with cancellation in your own loops and after awaits to release work promptly.

Observe `LevelEvents.DidLoad` for the installed ID/root, `DidFail` for the ID/error, and `DidCancel` for the ID and `committed` flag. Events arrive after the coordinator's state is valid. A level's retained subscriptions and unload callbacks belong to that level; app-wide event subscriptions should be retained separately by the scene owner.

ID and duration validation happen before a request starts, so handle those immediate throws at the call site without expecting a `DidFail` event; later preparation and installation-validation errors in a started request emit `DidFail`.

## Try the Levels demo

The Levels tab keeps one cyan player and one camera while switching between Garden and Workshop. Each room owns a floor, a physical bouncing ball, and an actual update counter. Move the player and add score, then switch: its ID, position, and component-backed score stay the same while room updates restart.

Choose Instant, Fade, or Crossfade. Every later preparation loads the tiny bundled sound and waits one second, giving you time to move or score in the outgoing room or press Cancel. Turn on Fail next preparation to throw a deterministic error after that delay. The outgoing counter continues; the failed request's cleanup still runs. During an animated phase the player buttons disable while Cancel stays available. Fade uses 1.6 seconds total, leaving time to cancel before or after commit. The disposal count includes failed/cancelled preparations and successfully loaded rooms that were later replaced; exact update totals depend on elapsed time.

## See also

- <doc:switching-levels-with-persistent-players>
- <doc:entity-and-scene-lifecycle>
- <doc:rendering-and-resources>
- <doc:parallax-and-repeating-backgrounds>
- <doc:player-input-sessions-and-feedback>
