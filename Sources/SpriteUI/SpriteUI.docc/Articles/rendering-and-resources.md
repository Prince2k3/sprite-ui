# Giving a scene its artwork and controls

A runner needs a walking animation, a pickup sound, and a label. Later, several runners may share the same artwork while playing at different speeds. Load the shared resources once, then let each entity control its own appearance and playback.

## Load what the runner needs

Keep scene data on entities. ``SpriteUI/SpriteRenderer`` draws that data, and ``SpriteUI/GameView`` drives the renderer. Changing components lets the renderer keep its nodes in sync with the scene.

Before adding the runner, load its images and sound in asynchronous setup. ``SpriteUI/ResourceLibrary`` caches completed and in-progress loads, so callers can share the same resources.

This helper expects `runner-1`, `runner-2`, and `pickup.wav` in the supplied bundle. It builds a two-frame clip from the images. Call it during setup, handle loading errors in your UI, and add the runner when loading succeeds.

```swift
import Foundation
import SpriteUI

struct RunnerResources {
    let firstFrame: TextureResource
    let run: AnimationResource
    let pickup: AudioResource
}

@MainActor
func loadRunnerResources(in bundle: Bundle = .main) async throws -> RunnerResources {
    let library = ResourceLibrary.shared
    let first = try await library.texture(named: "runner-1", in: bundle)
    let second = try await library.texture(named: "runner-2", in: bundle)
    let pickup = try await library.audio(named: "pickup.wav", in: bundle)
    let run = try AnimationResource(frames: [first, second], framesPerSecond: 8)
    return RunnerResources(firstFrame: first, run: run, pickup: pickup)
}
```

Retain a library for a level or use `shared` as above. Textures share immutable storage; each runner's playback state stays separate. A ``SpriteUI/TextureAtlasResource`` is useful for many named frames. Supply their intended order when making a clip.

For generated artwork, ``SpriteUI/SpriteImage`` can use RGBA bytes or a ``SpriteUI/NoiseMap``. Use `smoothsScaling: false` when scaled pixel art should keep hard edges.

## Start and control a runner's animation

An ``SpriteUI/AnimationResource`` describes the clip. Calling `playAnimation` starts one playback instance on an entity and returns a controller for it.

```swift
import SpriteUI

@MainActor
func beginRunner(_ entity: Entity, texture: TextureResource,
                 clip: AnimationResource) throws -> AnimationPlaybackController {
    entity.components.set(SpriteComponent(texture: texture, size: [32, 32]))
    return try entity.playAnimation(
        clip, options: PlaybackOptions(repeatMode: .forever)
    )
}
```

Keep the ``SpriteUI/AnimationPlaybackController`` when you need to pause, seek, change speed, or stop this run. Dropping the handle does not stop it; the entity owns the playback. Once it completes, stops, or fails, start the resource again for a new instance.

Audio follows the same pattern with ``SpriteUI/AudioResource`` and ``SpriteUI/AudioPlaybackController``. Several audio voices on one entity can overlap. Retain event subscriptions when reacting to ``SpriteUI/PlaybackEvents``.

## Give an exit animation a beginning and an end

A departing runner might move out of the way, then fade. A sequence expresses that order and can mark a moment your game cares about.

```swift
import SpriteUI

func makeExitClip() throws -> AnimationResource {
    let move = try AnimationResource.move(to: [80, 0], duration: 0.4)
    let fade = try AnimationResource.fade(to: 0, duration: 0.2)
    return try AnimationResource.sequence([move, fade])
        .addingMarker("departed", at: 0.4)
}
```

The move uses parent coordinates. Without a `from` value, it starts from the displayed value or the preceding sequence segment's endpoint. A group plays independent properties together; a sequence plays clips in order.

While a clip controls a property, let it finish or stop it before gameplay writes that property again. A newer clip that overlaps a track replaces the whole older controller.

For a simple state change, SpriteUI's `withAnimation` uses ``SpriteUI/ActionAnimation``: components receive their destination immediately while the renderer animates toward it. Use playback events when gameplay needs to distinguish reaching the end from interruption. A transaction completion can also run after replacement or removal.

## Change the look without changing the texture

A damage flash should affect one runner even when several runners share its image. ``SpriteUI/SpriteMaterial`` keeps per-sprite parameters while sharing texture and shader resources.

This helper copies the sprite's material, selects the built-in effect shader, changes the flash amount, and writes the sprite back.

```swift
import SpriteUI

@MainActor
func setDamageFlash(on entity: Entity, amount: Float) throws {
    guard var sprite = entity.components[SpriteComponent.self] else { return }
    var material = sprite.material
    if material.shader != ShaderResource.spriteEffects {
        material.shader = .spriteEffects
    }
    try material.setParameter(.float(amount), named: "a_flash")
    sprite.material = material
    entity.components.set(sprite)
}
```

Changing a shader clears its previous parameter overrides. Parameter writes check names, types, and finite values; `nil` restores the resource default. The effect changes the artwork, while collision and input shapes keep their own geometry.

A sprite can use a texture, a procedural image, or an image name, in that order of preference. With none of those, its color and size draw a rectangle. Use ``SpriteUI/LightComponent`` and matching material masks when artwork needs lighting or shadows.

## Build a label that belongs to the world

A checkpoint badge should move and zoom with the level. Use ``SpriteUI/ShapeComponent`` for its background and ``SpriteUI/TextComponent`` for the caption. Putting the text on a child lets you control its draw order independently.

```swift
import SpriteUI
import SwiftUI

@MainActor
func makeCheckpointBadge() -> Entity {
    let badge = Entity(components: ShapeComponent(
        .roundedRectangle(size: [150, 44], cornerRadius: 10),
        fill: .blue, stroke: .white, lineWidth: 2
    ))
    let caption = Entity(components: TextComponent(
        "Checkpoint", font: .system(size: 18, weight: .bold)
    ))
    caption.zPosition = 1
    badge.addChild(caption)
    return badge
}
```

World text participates in scene rendering and can be copied and saved with its hierarchy. Give wrapping text a width and line count. Shapes draw fill and stroke without creating physics bodies.

A character can use the same arrangement: sprite on the parent, caption on a child. Separate children are useful whenever artwork needs its own transform or animation.

## Put a SwiftUI button above the player

Use an attachment when the content needs a button or ordinary SwiftUI layout. A `GameAttachment` defines the view, and an ``SpriteUI/AttachmentComponent`` anchors it to an entity in the scene.

This view puts the button above the player. `context.perform` checks that the button still belongs to a valid, interactive attachment before it changes the sprite.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct AttachmentScene: View {
    var body: some View {
        GameView { content in
            let player = Entity(components: SpriteComponent(
                color: .cyan, size: [32, 32]
            ))
            if let anchor = content.attachments.entity(for: "player-action") {
                anchor.position = [0, 42]
                anchor.components[AttachmentComponent.self]?.isInteractive = true
                player.addChild(anchor)
            }
            content.add(player)
        } attachments: {
            GameAttachment(id: "player-action") { context in
                Button("Highlight") {
                    context.perform { anchor in
                        anchor.parent?.components[SpriteComponent.self]?.color = .yellow
                    }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}
```

`entity(for:)` returns the shared anchor for a definition ID. Use `makeEntity(for:)` for independent anchors that use the same definition. Their SwiftUI state remains separate.

Use ``SpriteUI/AttachmentContext`` for delayed actions too, since removal, definition replacement, and reuse invalidate old contexts. Keep changing control values in observable app state; reading components alone does not establish SwiftUI observation.

Attachment sizing `.screen` stays upright in view points; `.scene` follows the displayed transform. Attachments overlay sprite content and sort among themselves. Interactive attachments reserve their layout rectangle, so give wrapping or scrolling controls a useful frame.

## Reuse a projectile instead of rebuilding it

Repeated shots can share a ``SpriteUI/PrefabResource`` and reuse instances through an ``SpriteUI/EntityPool``. The prefab copies a template; the pool keeps idle copies attached but disabled.

Here, the pool can hold 32 projectiles and prepares eight in advance. The acquire hook restores their starting appearance.

```swift
import SpriteUI
import SwiftUI

@MainActor
func makeProjectilePool(in world: World) throws -> EntityPool {
    let prototype = Entity(components: SpriteComponent(
        color: .yellow, size: [8, 8]
    ))
    let prefab = PrefabResource(root: prototype)
    return try EntityPool(prefab: prefab, scene: world, capacity: 32, prewarm: 8,
                          onAcquire: { entity in
        entity.position = .zero
        entity.rotation = 0
        entity.scale = [1, 1]
        entity.components[SpriteComponent.self]?.opacity = 1
    })
}
```

Retain the pool in a scene owner. Configure a shot with `try pool.acquire { entity in ... }`, then release it on impact or expiry. Acquisition returns `nil` at capacity, so decide whether to skip a shot or use another game rule.

Reset game data such as velocity, health, and lifetime when reusing an instance. Release stops playback and clears particles and actions, which is more cleanup than ordinary deactivation. Recreate pools after restoring a world, since the restored entities are new objects.

## Frame and compose the level

Add a top-level ``SpriteUI/CameraComponent`` entity before assigning it to `world.activeCamera`. It can follow a target, zoom, shake, or stay within a level's limits. Use <doc:viewports-and-split-screen> when a minimap or second player needs another camera on the same world.

A ``SpriteUI/RenderGroupComponent`` flattens a subtree for filters. A ``SpriteUI/MaskComponent`` clips artwork and targeted input. Keep cameras outside filtered groups, and remember that masks leave model collision queries unchanged. <doc:render-layers-and-camera-visibility> explains how cameras can show different artwork while sharing simulation.

For imported levels, ``SpriteUI/SceneLoader`` reads supported `.sks` content. Inspect its API notes for the editor features you use; unsupported content can be omitted, approximated, or rejected. ``SpriteUI/TileMapComponent`` can also supply walkability data for the routes in <doc:gameplay-and-movement>.

## Keep in mind

`GameView` installs ``SpriteUI/PlaybackSystem``. A world advanced without a renderer needs it installed to advance clips. Playback uses scaled scene time, pauses during ordinary deactivation, and is cancelled on removal. Controllers and clocks are runtime state rather than save data. Dynamic bodies reject transform tracks.

Attachments inherit visibility and opacity, but sprite masks and group filters do not clip or filter them. They do not take part in physics or sprite occlusion.

Pool hooks must not enable, reparent, or recursively acquire or release instances. Reset child flags and joint frames when your game requires it. In-memory prefabs can copy unregistered components; prefab files require registered Codable components.

For fixed-step smoothing, see <doc:fixed-step-simulation-and-interpolation>. Interpolation affects only display, trails simulation by one tick, and requires compatible kinematic entities. Rendering budgets and resource statistics are covered in <doc:bounded-rendering-and-read-only-presentation>; target reservations are not total GPU allocation.

## Next lesson

Read <doc:saving-and-debugging> to save the runner's game state, reconnect runtime behavior, and inspect a scene when its appearance differs from what you expected.
