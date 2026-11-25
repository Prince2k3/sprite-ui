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

## Record engine performance without changing simulation

Every ``SpriteUI/World`` owns an ``SpriteUI/EngineProfiler``. Recording is off by default and independent of `isProfilingEnabled`/`lastSystemTimings`. Start it explicitly, inspect the throttled `latestFrame` and `summary`, then stop to freeze completed frames. Profiling does not advance clocks, install systems, evaluate queries a second time, or run another render pass.

Add `.profiling` to a debug controller's options to show Start, Stop, Reset, and JSON export controls. Merely displaying this panel does not start a capture. This complete scene moves a small grid through fixed systems, so recording includes both query and fixed-step work:

```swift
import SpriteUI
import SwiftUI

struct ProfiledMotion: Component {
    var speed: Float
}

struct ProfiledMotionSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    init(world: World) {}

    func update(context: UpdateContext) {
        for entity in context.entities(matching: EntityQuery(where: .has(ProfiledMotion.self))) {
            let speed = entity.components[ProfiledMotion.self]?.speed ?? 0
            entity.position.x += speed * Float(context.deltaTime)
            if entity.position.x > 180 { entity.position.x = -180 }
        }
    }
}

@MainActor
struct EngineProfilingScene: View {
    @State private var debug = SceneDebugController(options: [.profiling])

    var body: some View {
        GameView(debug: debug) { content in
            content.world.fixedStep = .init(stepsPerSecond: 60, maximumCatchUpSteps: 4)
            content.world.addSystem(ProfiledMotionSystem.self)
            for index in 0..<48 {
                let entity = Entity(components:
                    SpriteComponent(color: .cyan, size: [8, 8]),
                    ProfiledMotion(speed: 30), TransformInterpolationComponent())
                entity.position = [Float(index % 8) * 36 - 140, Float(index / 8) * 30 - 90]
                content.add(entity)
            }
        }
        .frame(minWidth: 320, minHeight: 320)
    }
}
```

For an application-owned recording, configure the capacity, target cadence, sampling interval, and optional Instruments signposts directly. This complete helper pair starts a capture and exports an immutable JSON report to a caller-owned local file URL:

```swift
import Foundation
import SpriteUI

@MainActor
func beginEngineCapture(in world: World) {
    world.profiler.start(configuration: .init(
        frameCapacity: 600, targetFramesPerSecond: 60,
        sampleInterval: 0.25, emitsSignposts: true
    ))
}

@MainActor
func exportEngineCapture(from world: World, to url: URL) throws -> EngineProfileCapture {
    world.profiler.stop()
    let capture = world.profiler.capture()
    try capture.write(to: url)
    return capture
}
```

`capture()` copies completed values without stopping a live recording; `stop()` freezes them, and `reset()` stops and clears them. A new `start` discards the previous ring and changes `recordingID`. Hosts that own a recording can retain that ID and compare it before cleanup. The `onEngineProfileRecordingStarted` view modifier observes only the debug panel's explicit Start action; it does not start recording itself. Detaching a debug controller does not stop an application-owned recording.

### Read the report's measurement boundaries

``SpriteUI/EngineProfileCapture`` exports format version 1, capture dates, configuration, a summary, total/overwritten/abandoned frame counts, and retained frame values. The ring retains the **newest** configured frames in chronological order; capacity is clamped to 1...3,600. Each completed frame keeps at most 128 distinct system/phase aggregates and flags truncation. No entity names, component values, peer identities, or packet payloads are included. These reports are diagnostics, not world snapshots or replay inputs.

Frame intervals describe render-update callback cadence; headless frames use the caller's supplied delta. Average, maximum, and nearest-rank p95 use positive intervals in the retained window. Over-budget counts compare those intervals with the configured target cadence. They do not prove a GPU missed a display deadline. Keep the target aligned with the game's intended refresh rate.

| Metric | Meaning |
| --- | --- |
| World update | Elapsed work in world simulation and presentation callbacks |
| Renderer update/finish | Elapsed main-actor callback work, including world work and binding/constraint/debug overhead |
| SpriteKit interval | Gap from `update` returning to `didSimulatePhysics` entering; includes actions, physics, and scheduling |
| Systems | Inclusive elapsed duration and invocation count by type/phase; repeated fixed ticks are aggregated |
| ECS queries | Calls, indexed candidate count, returned entities, and inclusive query duration |
| Collision queries | Raycast/overlap/sweep calls, indexed candidates, returned hits, and complete traversal/geometry/sorting duration |
| Network | Actual replication-update duration and encoded-envelope bytes/packet counts from existing send/receive paths |
| Workload | Periodic entity/activity, native node, sprite, physics-body, and emitter counts |

These durations overlap: query and networking work may be inside a system, which is inside world/renderer callbacks. **Do not add them together.** SpriteKit interval is not isolated physics CPU time. The capture does not measure GPU time. SpriteKit exposes no exact public draw-call or live-particle counter, so those fields stay unavailable rather than reporting zero or substituting node/emitter counts. Native subtree counts include inactive nodes and exclude the debug drawing layer; they are not visible-object counts.

System phase order and invocation counts come from the actual schedule. Paused redraws and debug priming can produce completed renderer frames with `isSimulated == false` and empty system timings. Fixed-step dropped time records the clock's actual clamp/catch-up discard, even if gameplay subsequently resets that clock. Profiling does not change catch-up budgets.

ECS predicates and collision geometry run once. Indexed candidates include inactive entities even when the query skips them. Network bytes include encoded envelopes, exclude transport headers/retransmissions, and a successful send means transport acceptance, not remote delivery. Receive counters count messages processed from known peers, including messages later rejected by decoding; enqueue-rejected and unknown-source arrivals are excluded. Explicit network updates are measured without calling them again. Queries and traffic outside a callback frame are assigned to the next completed frame; stopping first discards pending unframed work.

Frame timings are recorded every completed frame. Workload censuses and observable UI publications use `sampleInterval`, clamped to 0.1...10 seconds; `sampledAt` identifies a reused census. `stop()` publishes the newest completed sample immediately. Abandoned/incomplete frames are excluded and counted separately. Diagnostics add measurement and census overhead, so compare like-for-like recordings and use Instruments on a physical device for deeper attribution.

With `emitsSignposts`, the `dev.spriteui.engine` / `Profiling` category emits `Engine frame` and `System` intervals. This is opt-in; no signposts or capture buffers are collected by default. See Apple's [OSSignposter documentation](https://developer.apple.com/documentation/os/ossignposter) for Instruments integration. Rendering target budgets and completed viewport statistics remain available separately through ``SpriteUI/GameRenderMonitor``; enabling a monitor can select a different presentation driver, so it is not enabled automatically by profiling.

## Diagnose from the owner outward

When something fails to appear or move, first check that the entity belongs to the expected world and is active. Then inspect its components, the installed system schedule, and pause/time scale. For interaction problems, inspect the collider and input-target hierarchy before the gesture resolver. For visual disagreement, compare model and presented transforms, then check camera, masks, and render groups. For load problems, inspect registration and reconnection before assuming the saved IDs refer to the old objects.

## See also

- <doc:input-recording-and-replay>
- <doc:entity-and-scene-lifecycle>
- <doc:systems-and-input>
- <doc:rendering-and-resources>
