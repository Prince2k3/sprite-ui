# Saving and debugging

Define a snapshot schema, reconnect restored identities, and inspect the model and the displayed scene together.

## Register the data that should persist

``SpriteUI/ComponentRegistry`` maps Codable component types to names used in snapshot files. A component is captured only when its type is registered. ``SpriteUI/Transform`` and ``SpriteUI/InputTargetComponent`` are registered automatically. A renderer registers backend components; call `SpriteRenderer.registerComponents()` yourself when saving or loading before a renderer exists.

Register app components before both capture and decoding. Use explicit, unique, stable names when files must survive a module or type rename. Registering a type again replaces its registered name. `Codable` conformance alone does not make a component persistent.

Gameplay adapter components and attachment references also need intentional registration. Register the Codable types your game actually uses, such as ``SpriteUI/SteeringComponent``, ``SpriteUI/PathComponent``, ``SpriteUI/PolygonObstacleComponent``, or ``SpriteUI/SpatialIndexComponent``. `GameView` registers ``SpriteUI/AttachmentComponent`` when hosting attachments; register it explicitly for standalone file I/O. Do not assume every runtime component has a serializable representation.

## Capture a checkpoint and restore it

A ``SpriteUI/WorldSnapshot`` captures top-level entities recursively, including their names, enabled flags, and registered copyable components. This complete example defines a small health schema and returns encoded checkpoint data. The restore helper decodes before replacing the current hierarchy, so a decoding failure leaves it intact.

```swift
import Foundation
import SpriteUI

struct CheckpointHealth: Component, Codable {
    var hitPoints: Int
}

func registerCheckpointSchema() {
    SpriteRenderer.registerComponents()
    AttachmentComponent.registerComponent()
    CheckpointHealth.registerComponent(named: "game.health.v1")
    SteeringComponent.registerComponent()
    PathComponent.registerComponent()
}

@MainActor
func checkpointData(from world: World) throws -> Data {
    registerCheckpointSchema()
    return try world.snapshot().jsonData(prettyPrinted: true)
}

@MainActor
func restoreCheckpoint(_ data: Data, in world: World) throws -> [Entity.ID: Entity] {
    registerCheckpointSchema()
    let saved = try WorldSnapshot(data: data)
    return world.restore(saved)
}
```

Use `WorldSnapshot.write(to:)` for an atomic write to an app-owned URL, and `WorldSnapshot(contentsOf:)` to read it. Report file or decoding failures through app UI. Decode and validate the data you need before calling `restore`; restoration itself is not a throwing file operation.

The `snapshot(including:)` predicate selects top-level roots. Once selected, a root's children are captured recursively. It is not a per-descendant filter. Group temporary effects under an excluded top-level root, or deliberately construct a custom snapshot when you need finer filtering.

### Know what a world snapshot omits

The hidden world root is not captured, so `world.resources` does not enter the standard snapshot. World pause, time scale, physics settings, installed systems, and explicit camera selection are also world runtime configuration. Encode persistent settings in an app-level save envelope or on an explicit saved entity, then reapply them when restoring.

Active playback controllers, animation clocks, actions, event subscriptions, debug state, particle effects, and audio runtime state do not resume from a snapshot. Sprite data retains its saved visual texture, not a running clip's clock. Attachment components save definition IDs and layout choices; SwiftUI content definitions and view state remain view-scoped. Match restored IDs with definitions on the new host.

Copy hooks matter during capture too. A custom component with mutable reference storage should implement `cloned()` to freeze independent state, or return `nil` to exclude runtime storage. Otherwise a supposedly captured value may still refer to mutable application objects.

## Remap references instead of assuming IDs never change

Clones and prefab instances get fresh IDs. World restoration preserves saved IDs when possible, but can assign new IDs if one conflicts with the hidden root or another saved entity. `world.restore(_:)` returns a dictionary from saved IDs to restored entities. It replaces top-level content while keeping the world object and its runtime configuration.

Use the returned map to reconnect app-owned references, selections, and scene controllers. A retained entity from before restoration is an old object, even if the new world contains an entity with the same numeric ID. Cancel or replace old entity-filtered subscriptions as part of that reconnection.

Components containing entity references should adopt ``SpriteUI/EntityReferencingComponent``. This complete component remaps only its entity ID, leaving its unrelated data alone:

```swift
import SpriteUI

struct TargetLink: EntityReferencingComponent, Codable {
    var targetID: Entity.ID
    var desiredDistance: Float

    @MainActor
    mutating func remapEntityReferences(_ context: EntityReferenceRemapping) {
        targetID = context.id(for: targetID)
    }
}
```

Register `TargetLink` before saving or decoding it. ``SpriteUI/EntityReferenceRemapping`` runs after all destination entities exist and before attachment to a world. Internal references point at destination copies; IDs outside the copied or restored set stay external. The context also exposes the operation, optional copied root, source transforms, and lookup helpers for components with more involved reference-frame needs.

The built-in reference-bearing components provide their own remapping. Your app remains responsible for references held outside components. After restore, recreate pools and reconnect UI, reapply camera selection if needed, and start any playback that current game state requires.

## Treat schema changes as game data changes

Decoding skips components whose registered type name is unknown. This allows a reader to ignore unavailable data, but it is not an automatic migration of your game's rules. A missing health, navigation, or interaction component can still make a loaded scene incomplete. Validate required components and supply deliberate defaults before resuming play.

The snapshot's `version` describes its file layout. Keep an app-level save version when you need migrations for your own schema. Changing a registered name, stored property meaning, or default should be an intentional compatibility decision. Re-registering a type under a new name does not create an alias for the old name.

## Inspect one presented world with a debug controller

``SpriteUI/SceneDebugController`` is an observable, view-scoped controller. Pass one instance to `GameView(debug:)` and choose the ``SpriteUI/SceneDebugOptions`` you need. The following complete view shows the built-in debug panel plus app controls that remain usable while scene simulation is paused:

```swift
import SpriteUI
import SwiftUI

@MainActor
struct InspectionScene: View {
    @State private var debug = SceneDebugController(options: [
        .collisionShapes, .origins, .selection, .statistics,
        .inspector, .simulationControls
    ])

    var body: some View {
        VStack {
            HStack {
                Button(debug.isPaused ? "Resume" : "Pause") {
                    debug.isPaused.toggle()
                }
                .disabled(!debug.isAttached)
                Button("Step") { debug.stepFrame() }
                    .disabled(!debug.canStep)
                Button("Refresh") { debug.refresh() }
                    .disabled(!debug.isAttached)
                Text("Entities: \(debug.snapshot.entityCount)")
            }
            GameView(debug: debug) { content in
                content.add(Entity(components: SpriteComponent(
                    color: .cyan, size: [40, 40]
                )))
            }
            .frame(minWidth: 320, minHeight: 240)
        }
    }
}
```

A controller binds to one renderer at a time; sharing it across two mounted `GameView` instances is rejected. Keep one per view identity. It detaches with presentation, and its state does not become snapshot or prefab data.

Pause and time-scale controls operate on the bound scene. `stepFrame()` requests one renderer frame while paused, at 1×, without changing the stored pause flag or time scale. Requests coalesce while a step is pending. A step uses the next normal capped frame interval, not a deterministic fixed timestep, and audio voices stay suspended. `refresh()` updates inspection and drawings without advancing simulation.

## Read diagnostics in the right coordinate and timing context

``SpriteUI/SceneDebugSnapshot`` reports entity and node counts, nonterminal playback controllers, system timings, and bounded entity inspection values. Counts include disabled entities and exclude the hidden root. Inspection can be truncated; check `inspectionTruncated` before treating the rows as an exhaustive hierarchy. Routine UI sampling is throttled to ten times per second; use `refresh()` for immediate inspection after a command.

``SpriteUI/SceneDebugEntity`` exposes both model `transform` and `presentedTransform`, plus the displayed scene position. Compare them when an animation's destination differs from visible artwork. Collision outlines describe query geometry rather than the backend's internal contact manifold. Visual bounds are unclipped bounds, so a mask can explain why an outlined area is not visible or interactive.

System timings measure system wall-clock work, not GPU time or the physics engine's cost. FPS describes callback cadence, not GPU throughput. Enable only the drawings and inspection that help with the current question; diagnostics themselves require work. For direct world profiling, `isProfilingEnabled` controls collection and `lastSystemTimings` contains systems that actually ran.

Debug selection can inspect visible content without an input-target component and can select disabled entities through the controller or hierarchy UI. Removal, replacement, or activation/reuse invalidates selection. Explicit debug picking suppresses entity-targeted game gestures; unrelated ancestor SwiftUI gestures still use normal gesture arbitration. Do not use inspector selection as a substitute for your game's input validation.

For an interactive SwiftUI attachment, keep mutations inside `AttachmentContext.perform`, including delayed actions. That context validates the view's instance and activation before changing its entity. Combine it with observable app state for context UI that remains accurate across restore, removal, and reuse; see <doc:rendering-and-resources>.

## Diagnose from the owner outward

When something fails to appear or move, first check that the entity belongs to the expected world and is active. Then inspect its components, the installed system schedule, and pause/time scale. For interaction problems, inspect the collider and input-target hierarchy before the gesture resolver. For visual disagreement, compare model and presented transforms, then check camera, masks, and render groups. For load problems, inspect registration and reconnection before assuming the saved IDs refer to the old objects.

## See also

- <doc:entity-and-scene-lifecycle>
- <doc:systems-and-input>
- <doc:rendering-and-resources>
