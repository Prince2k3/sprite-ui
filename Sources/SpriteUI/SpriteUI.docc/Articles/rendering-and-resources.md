# Rendering and resources

Load shared assets before use, compose visual hierarchies, and give playback and reusable instances clear owners.

## Keep the entity model authoritative

``SpriteUI/SpriteRenderer`` mirrors entities onto backend nodes and batches component changes until a flush. In a ``SpriteUI/GameView``, the host owns that renderer and drives its frame loop. Normal game code changes components rather than maintaining a second node hierarchy. `GameViewContent.renderer` remains available for backend-specific integration.

Use one visual responsibility per entity when independent transforms or animations matter. For example, give a character a sprite, put a world-space caption on a child, and put an attachment anchor on another child. This makes z ordering, opacity, and reuse explicit.

Use <doc:render-layers-and-camera-visibility> for separate world and map art under the same physical parent. Its visibility gates affect presentation while simulation continues; <doc:presenting-a-world-with-render-layers> provides three complete runnable stages.

## Preload resources before exposing content

``SpriteUI/ResourceLibrary`` loads and caches textures, atlases, audio, shaders, and prefabs. Retain a library for an app or level, or use `shared`. Completed and in-flight loads are shared; cancelling one waiter does not cancel a shared load. Clearing the library's cache does not invalidate resources that entities still use.

This complete loader expects two images named `runner-1` and `runner-2`, plus `pickup.wav`, in the supplied bundle. It creates a reusable two-frame clip. Call it from asynchronous setup, catch errors there, and add the entity after loading succeeds.

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

``SpriteUI/TextureAtlasResource`` groups named textures and can create clips from an explicit frame-name sequence. Choose the frame order intentionally; sorted texture names are not necessarily your animation order. ``SpriteUI/TextureResource`` values share immutable backend texture storage, while playback state belongs to each entity.

For a procedural texture, construct ``SpriteUI/SpriteImage`` from valid RGBA bytes or from a ``SpriteUI/NoiseMap`` through the umbrella integration. The pixel initializer needs positive dimensions and exactly `width * height * 4` bytes. Set `smoothsScaling: false` for hard pixel edges.

## Control one playback instance at a time

An ``SpriteUI/AnimationResource`` describes a reusable clip. `entity.playAnimation(_:options:)` returns an ``SpriteUI/AnimationPlaybackController`` for one instance. Audio uses the same pattern with ``SpriteUI/AudioResource`` and ``SpriteUI/AudioPlaybackController``.

This complete helper accepts already loaded resources and returns the running animation's handle:

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

Keep a handle when you need to pause, resume, seek, change speed, or stop that instance. Dropping a handle does not stop playback; the entity owns it until termination. Completed, stopped, and failed controllers are terminal, so play the resource again to create a new instance. Different audio voices on one entity can overlap. Retain event tokens when listening to ``SpriteUI/PlaybackEvents`` markers, completion, stop, or failure.

The renderer installs ``SpriteUI/PlaybackSystem`` automatically. A headless world that needs clip advancement must install it explicitly. Playback advances on scaled scene time, and ordinary entity deactivation or scene pause suspends advancement without changing the requested controller state. Removing an attached entity cancels active playback. Controllers and clocks are runtime state, not snapshot content.

Property timelines use the same resource/controller API. The following complete helper creates a move followed by a fade, with a marker at the end of the move:

```swift
import SpriteUI

func makeExitClip() throws -> AnimationResource {
    let move = try AnimationResource.move(to: [80, 0], duration: 0.4)
    let fade = try AnimationResource.fade(to: 0, duration: 0.2)
    return try AnimationResource.sequence([move, fade])
        .addingMarker("departed", at: 0.4)
}
```

Move targets are parent-relative; rotation tracks use unwrapped radians. A missing `from` captures the presented starting value or a preceding sequence segment's endpoint. Sequences chain clips; groups combine independent properties and reject overlapping tracks on the same property. A new overlapping playback replaces the entire older controller. External writes to an owned property are overwritten on the next sample, so stop playback before handing the property back to gameplay. Dynamic physics bodies reject transform tracks.

For a direct state transition, `withAnimation` applies an ``SpriteUI/ActionAnimation`` transaction: components contain their target values immediately, and the renderer interpolates presentation. Explicitly typed SwiftUI `Animation` values select SwiftUI's overload instead. Use the SDK's `ActionAnimation` when sprites should animate. A transition completion can also run after replacement or removal, so it is not a guarantee that the entity reached a gameplay destination. Reusable timelines provide explicit playback events for that distinction.

## Style sprites without duplicating resources

``SpriteUI/SpriteComponent`` chooses a texture resource ahead of procedural `image`, and an `image` ahead of `imageName`. Without any image source, a color and size draw a rectangle. Its material owns tint, tint amount, opacity, blending, optional normal map, lighting masks, and shader parameters.

``SpriteUI/SpriteMaterial`` copies retain shared immutable shader code and textures while owning their parameter overrides. This complete helper applies the built-in damage-flash shader to an existing sprite:

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

Changing the shader clears previous parameter overrides. Parameter writes validate declared names, types, and finite values; passing `nil` restores a resource default. Custom ``SpriteUI/ShaderResource`` schemas use `a_` float/vector attributes and `u_` texture uniforms. Resource construction validates the schema; the backend compiles shader source at render time. Shader output uses premultiplied RGBA. Shader effects do not automatically change interaction or collision geometry.

``SpriteUI/LightComponent`` is a point light. Match its category mask with the sprite material's lighting and shadow masks, and use normal maps for surface detail. Lighting, shadow casting, and shadow receiving are separate opt-ins. Custom fragment shaders take precedence over built-in illumination. Keep lights and lit sprites together within a compositing boundary.

## Choose world text, vector shapes, or SwiftUI

``SpriteUI/TextComponent`` is scene content: it follows camera zoom, participates in render groups, and can be cloned, pooled, and saved. ``SpriteUI/TextFont`` supports system fonts or installed PostScript names. Give wrapping text a width and an intentional line count. Font and layout edits apply immediately; transform and opacity changes can animate.

``SpriteUI/ShapeComponent`` draws a ``SpriteUI/ShapeGeometry`` primitive or ``SpriteUI/VectorPath`` with independent fill and stroke. It does not create a physics body. Visual hit testing includes drawn fill and stroke but not a glow halo. For large repeated decorations, a shared texture can be a better fit than many live vector shapes.

This complete helper assembles a badge without asset files:

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

Use a SwiftUI attachment when the content needs controls or normal SwiftUI layout. Definitions belong to one `GameView`; ``SpriteUI/AttachmentComponent`` stores a reference to a named definition on an anchor entity. `entity(for:)` returns the shared anchor for an ID, while `makeEntity(for:)` makes an independent anchor. Cloned anchors can reuse a definition while keeping separate view state.

The following complete view creates an interactive attachment above a sprite. The button uses ``SpriteUI/AttachmentContext`` to validate that the action still belongs to that attachment instance:

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

`AttachmentContext.perform` rejects an invalid context or a noninteractive anchor. Use it even for an action resumed asynchronously after a view disappears. Definition replacement, removal, and activation/reuse invalidate old contexts. Reading ordinary ECS components in an attachment does not itself establish SwiftUI observation; use observable app state for live control content.

Attachment sizing `.screen` stays upright in view points; `.scene` follows the full presented transform. Attachments overlay rendered content, so their z ordering applies among attachments, and they do not participate in physics or sprite occlusion. They inherit visibility and opacity, while masks and render-group filters do not clip or filter them. Interactive content reserves its full layout rectangle; give scrolling or wrapping UI an explicit frame.

## Frame the scene and bound visual effects

Place ``SpriteUI/CameraComponent`` on a top-level entity. It can follow an entity ID or name, smooth motion, constrain the visible area, zoom, and shake. Add the camera before assigning it to `world.activeCamera`; a selected camera must belong to that world. Assigning `nil` returns to automatic selection. Use `GameViewContent.scenePoint(fromView:)` and `viewPoint(fromScene:)` for conversion through the active camera.

``SpriteUI/RenderGroupComponent`` composites a subtree as one layer with ``SpriteUI/PostProcessEffect`` filters. Child z positions sort within the group, and the group's z orders the flattened result among siblings. Filters are live, add offscreen work, and do not enlarge collision geometry or input regions. Keep cameras outside filtered groups.

``SpriteUI/MaskComponent`` clips visuals and targeted input using alpha artwork. Nested masks intersect, and an empty mask hides content; disabling the component bypasses clipping. Masks do not change model-space physics queries. On the same entity, clipping happens before group filters; put a mask on a parent to clip a child's filter halo too. Keep large, nested, animated masks limited to content that needs them.

``SpriteUI/TransformConstraintComponent`` maintains visual relationships after actions, physics, and presentation systems, before camera following. Its ordered rules have final authority over the properties they affect. Use its status values to diagnose missing targets, cycles, singular transforms, or incompatible motion owners rather than adding another position writer.

``SpriteUI/ParticleEmitterComponent`` and ``SpriteUI/AudioComponent`` provide component-driven effects. Prefer loaded audio resources and playback handles when you need independently controlled voices. Give temporary effects explicit lifetime or pool-release policies so they do not accumulate indefinitely.

## Reuse hierarchies with a bounded pool

A ``SpriteUI/PrefabResource`` captures a detached template without changing the original hierarchy. Instances have fresh IDs, independent value components, and remapped internal references. Immutable resources stay shared. In-memory prefabs can copy unregistered components; writing a prefab file uses registered Codable components.

``SpriteUI/EntityPool`` keeps idle instances attached but disabled, retaining IDs, hierarchy, and render nodes. Capacity includes both leased and idle instances, and acquisition returns `nil` at capacity. This complete helper creates a small asset-free projectile pool:

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

Keep the returned pool in a scene owner. Use `try pool.acquire { entity in ... }` to configure an instance while disabled, and `try pool.release(entity)` on impact or expiry. Reset hooks must not enable or reparent the instance or call the pool recursively. Reset velocity, health, lifetime, and other game data explicitly; child enabled flags are preserved. Rebind joints if their rest frame should change with the reset pose.

Release stops playback and clears particles/actions; it is stronger than setting `isEnabled = false`. A cancelled pooled transition does not deliver its completion. Call `removeAll()` when the pool is no longer needed. Replacing a world through snapshot restoration invalidates the pool's old ownership, so recreate the runtime pool afterward.

## Import authored scenes deliberately

``SpriteUI/SceneLoader`` imports `.sks` hierarchies, and registered user-data makers can create your own components. Sprite, label, shape, physics, light, tile-map, supported filter, and supported mask content have explicit mappings. Unsupported mask artwork throws before returning the imported tree; some other editor features are omitted or approximated. Inspect the loader's API notes before relying on a particular editor feature, especially physics shape reconstruction.

``SpriteUI/TileMapComponent`` stores tile visuals and metadata. The umbrella's grid helpers can turn walkability metadata into a route graph; see <doc:gameplay-and-movement>. Keep loading at a setup boundary and report errors through app UI rather than leaving a partly configured scene visible.

## See also

- <doc:parallax-and-repeating-backgrounds>
- <doc:entity-and-scene-lifecycle>
- <doc:systems-and-input>
- <doc:saving-and-debugging>

## Multiple camera views

Use one `GameView(viewports:)` to draw the same world through independent player cameras and a noninteractive minimap. <doc:viewports-and-split-screen> covers normalized layouts, viewport-aware input, scoped attachments, and the single simulation clock. Follow <doc:sharing-a-world-between-viewports> for three complete stages.
