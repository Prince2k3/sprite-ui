# Saving a checkpoint and finding scene problems

A player reaches a checkpoint with three health points left. Loading it should restore the player and its target, then reconnect the UI and game rules. Save the data needed to rebuild that situation, and inspect the rebuilt scene when something looks wrong.

## Choose what the checkpoint remembers

A snapshot captures the entity hierarchy and registered components. To save health, make it Codable and register its type before saving and loading. ``SpriteUI/ComponentRegistry`` associates each type with a name stored in the file.

Use stable names for your own save data so a later type or module rename does not silently change the file format. Codable conformance by itself does not register a component.

This example registers health and the scene components it uses, encodes a checkpoint, and decodes it before replacing the current hierarchy.

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

If decoding throws, the old scene remains intact. `world.restore` replaces the top-level entities after decoding; it is not a throwing file operation. Use `WorldSnapshot.write(to:)` for an atomic file write and `WorldSnapshot(contentsOf:)` to read a file. Report failures through app UI.

The renderer normally registers backend components. Calling `SpriteRenderer.registerComponents()` also supports saving or loading before a renderer exists. Register the additional Codable components your game uses, including attachment references when doing standalone file I/O.

`snapshot(including:)` selects top-level roots, then includes their children recursively. Put temporary effects under an excluded root if they should stay out of the checkpoint.

## Reconnect the restored player

Restoration keeps the world object and its runtime configuration but creates new entity objects. Even if a saved ID stays the same, an old object reference still points at the old player.

Use the dictionary returned by `world.restore` to reconnect selections, UI, and scene controllers. It maps saved IDs to restored entities. Saved IDs are preserved where possible; conflicts with the hidden root or duplicate saved IDs can require new ones.

If a component points at another entity, teach it how to update that reference. This ``SpriteUI/EntityReferencingComponent`` remaps a target ID while leaving its desired distance unchanged.

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

Register `TargetLink` before saving or decoding. Remapping runs after destination entities exist and before they enter the world. References inside the restored or copied set follow their new entities; references outside it remain external.

After restore, replace old entity-filtered subscriptions, recreate pools, select the camera if needed, and start playback appropriate to the restored state. Built-in components remap their own references; app-owned references still need this reconnection work.

## Plan for the next version of the game

Loading an old checkpoint is also a game design decision. Unknown component type names are skipped, so validate the data your rules require and supply deliberate defaults before resuming play.

Keep an app-level save version for migrations. The snapshot's `version` describes its file layout, rather than changes to your health or inventory rules. Registering a type under a new name does not keep the old name as an alias.

## Pause the scene and look at it

If the loaded player is missing or moving incorrectly, inspect the world before changing the movement code. A ``SpriteUI/SceneDebugController`` can show collision shapes, origins, selection, and scene statistics alongside pause controls.

Keep one controller in SwiftUI state for each `GameView`.

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

Pause stops simulation while the surrounding controls remain usable. `refresh()` updates the inspection without advancing the game. `stepFrame()` requests one renderer frame while paused, using the next ordinary capped frame interval at 1×. It leaves the saved pause and time-scale settings unchanged; audio remains suspended.

First check membership and activation, then components, installed systems, and the scene clock. For input problems, inspect the collider and input-target hierarchy. For visual problems, compare model and displayed transforms before changing the camera or artwork.

``SpriteUI/SceneDebugEntity`` exposes both transforms. During animation they can differ because the model already contains the destination. Collision outlines show query geometry, and visual bounds can extend beyond a mask.

## Record a slow section of gameplay

Once the behavior is right, a performance recording can show where time goes. Add `.profiling` to the debug options, then use Start and Stop around the section you want to examine. Showing the panel does not begin recording.

This scene moves a grid of sprites with a fixed-step system. Its recording includes system and query work, giving you a small example to inspect before profiling a larger level.

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

Every world owns an ``SpriteUI/EngineProfiler``. Recording is off by default and separate from `isProfilingEnabled` and `lastSystemTimings`. During recording, `latestFrame` and `summary` provide sampled updates for UI.

Your app can also start and export a recording directly. This helper retains up to 600 frames, compares cadence with a 60 FPS target, and enables Instruments signposts.

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

`stop()` freezes completed frames. `capture()` copies the retained values into an ``SpriteUI/EngineProfileCapture`` for export. `reset()` stops and clears recording; starting again replaces the previous recording. Detaching a debug controller does not stop a recording started by your app.

Read timings as nested work. Queries may run inside a system, which runs inside a world update, which runs inside a renderer callback. Adding those durations together counts the same work more than once.

Frame intervals show callback cadence. Compare recordings with the same settings and workload, since the measurements and inspection also take time. Use Instruments on a physical device when you need deeper attribution.

## What a checkpoint and a report leave out

A standard snapshot omits the hidden root, including `world.resources`, and world settings such as pause, time scale, physics configuration, systems, and camera selection. Save persistent settings separately or on a saved entity, then reapply them. Playback clocks, subscriptions, actions, live particles and audio, and SwiftUI attachment content and view state must be rebuilt. Copy mutable reference storage in `cloned()` or omit it so the checkpoint cannot change through a shared object.

A debug controller binds to one renderer at a time. Inspection can be truncated; check `inspectionTruncated` before treating it as a complete hierarchy. Debug picking suppresses targeted game gestures, while unrelated SwiftUI gestures retain normal arbitration.

Performance reports retain the newest frames and can truncate system detail. They are diagnostics rather than save files or replay inputs, and contain no entity names, component values, peer identities, or packet payloads. Timings do not measure GPU work; the SpriteKit interval is not isolated physics CPU time. Native node counts include inactive nodes, and exact draw-call and live-particle counts are unavailable. Network byte counts cover encoded envelopes, and transport acceptance does not prove remote delivery.

## Next lesson

Read <doc:input-recording-and-replay> when you need to repeat a sequence of player actions. Return to <doc:entity-and-scene-lifecycle> when deciding which scene owner should rebuild references and subscriptions after loading.
