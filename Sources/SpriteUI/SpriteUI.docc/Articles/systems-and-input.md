# Systems and input

Schedule frame logic, respect coordinate spaces, and route gestures to the entity that owns an interaction.

## Make systems the owners of frame logic

A ``SpriteUI/System`` is initialized for a world and receives an ``SpriteUI/UpdateContext`` at its scheduled cadence: once per advancing frame for variable systems, or once per executed tick for opted-in fixed systems. Query for the data the system needs rather than retaining a list that becomes stale as entities spawn, deactivate, or leave.

This system moves tagged entities at a scene-space velocity, even when their parents are rotated or scaled. It reports rejected coordinate conversions in a world resource rather than writing an invalid local position.

```swift
import SpriteUI

struct SceneVelocity: Component {
    var pointsPerSecond: SIMD2<Float>
}

struct MovementReport: Component {
    var rejectedMoves: Int
}

@MainActor
struct SceneMotionSystem: System {
    private static let movers = EntityQuery(where: .has(SceneVelocity.self))

    init(world: World) {}

    mutating func update(context: UpdateContext) {
        var rejected = 0
        for entity in context.entities(matching: Self.movers) {
            guard let velocity = entity.components[SceneVelocity.self] else {
                continue
            }
            let destination = entity.scenePosition
                + velocity.pointsPerSecond * Float(context.deltaTime)
            do {
                try entity.setPosition(destination, relativeTo: nil)
            } catch {
                rejected += 1
            }
        }
        context.world.resources.set(MovementReport(rejectedMoves: rejected))
    }
}
```

Install this system and add `SceneVelocity` to the entities it should move. This example assumes moving entities do not also move one another as ancestors. If both a parent and child move in scene space, first snapshot their starting scene poses, calculate destinations, then commit parents before children. Queries have no hierarchy-order guarantee. The built-in steering and path-following systems handle that ordering themselves.

Default queries omit inactive entities. Use `includingDisabled: true` deliberately for reset or inspection work; applying ordinary movement to dormant pooled entities can corrupt their next activation.

## Choose phases and explicit dependencies

``SpriteUI/SystemPhase`` has three phases:

1. `fixedSimulation` runs zero or more times before variable simulation when `world.fixedStep` is nonnil. Use it for custom fixed-step game rules.
2. `simulation` runs once before backend physics. Use it to decide variable-step motion and set physics inputs.
3. `presentation` runs once after backend physics has copied results into components. Use it for logic that needs the completed physics pose.

`WorldEvents.Update` remains once per advancing frame before all systems; `WorldEvents.FixedUpdate` publishes before each tick's fixed systems. The renderer also flushes presentation changes, evaluates transform constraints, and updates cameras late in the frame. A headless `World.update(deltaTime:)` runs the system phases in order, without simulating backend physics or evaluating renderer-only constraints. <doc:fixed-step-simulation-and-interpolation> covers the opt-in clock and <doc:running-fixed-step-simulation> provides three complete kinematic examples.

The default phase is `simulation`. Declare ordering with ``SpriteUI/SystemDependency`` rather than relying on an unrelated feature's installation order. For example, this optional presentation system samples positions after the motion system above:

```swift
// Fragment: add beside SceneVelocity and SceneMotionSystem from the preceding example.
struct PositionSamples: Component {
    var positions: [Entity.ID: SIMD2<Float>]
}

@MainActor
struct PositionSamplingSystem: System {
    static var phase: SystemPhase { .presentation }
    static var dependencies: [SystemDependency] { [.after(SceneMotionSystem.self)] }

    init(world: World) {}

    mutating func update(context: UpdateContext) {
        let query = EntityQuery(where: .has(SceneVelocity.self))
        let samples = context.entities(matching: query).map { ($0.id, $0.scenePosition) }
        context.world.resources.set(
            PositionSamples(positions: Dictionary(uniqueKeysWithValues: samples))
        )
    }
}
```

Install both types with `try world.systems.add(...)` in setup. A dependency orders systems that are already installed; it does not install the target. All fixed simulation systems precede variable simulation systems, which precede presentation systems. Cycles and constraints that contradict phase order throw ``SpriteUI/SystemSchedulingError`` and preserve the previous schedule. Without a stronger constraint, the scheduler retains installation order.

``SpriteUI/SystemCollection`` exposes the resolved `types` order, enablement, and removal. Adding a system during a frame schedules it for the next frame. Removing or disabling a system that has not yet run takes effect immediately. `registerSystem()` applies to subsequently created worlds, while `world.systems.add` applies to one world.

## Use the scene clock consistently

`context.deltaTime` in variable systems is elapsed display-frame scene time after `world.timeScale` is applied. Their `unscaledDeltaTime` is the supplied elapsed time before that multiplier. Fixed systems instead receive the constant configured `stepDuration`, an unscaled delta of `stepDuration / world.timeScale`, and a nonnil `fixedTick: UInt64?`. The context also exposes `interpolationAlpha`; variable systems keep a nil fixed tick and their original frame deltas. Movement measured in points per second needs one multiplication by delta time; force-producing APIs that already integrate elapsed time should receive it directly.

Paused worlds and a zero time scale skip ordinary simulation. Using `unscaledDeltaTime` inside a system does not make that system run while paused. Keep menus and other UI that must remain responsive in the app's UI lifecycle.

The renderer caps its ordinary frame interval at 1/15 second to limit a large jump after a stall. Opt into a separate fixed clock with `world.fixedStep = FixedStepConfiguration()`; its raw-delta clamp applies before time scaling and its bounded catch-up preserves fractional debt while dropping whole excess ticks. Headless callers choose their own valid elapsed intervals; a zero delta still delivers the world update event. Fixed systems do not change SpriteKit physics or actions into deterministic fixed-step simulation, and reproducible custom rules still need controlled input, ordering, and random state.

For input consumed by fixed rules, retain a caller-owned `FixedInputBuffer` and call `consume()` once per tick. This preserves press and release transitions between ticks while held values persist. Explicitly call `input.cancelAll()` and/or `buffer.reset()` on pause or scene exit; pausing a world does not own its input buffer. Follow <doc:fixed-step-simulation-and-interpolation> for cancellation revision and overflow behavior.

## Keep model and presented coordinates distinct

``SpriteUI/Transform`` holds parent-relative translation, counterclockwise rotation in radians, scale, and z position. `position` is local; `scenePosition` includes the ancestor hierarchy. A `nil` reference in the relative-transform methods means scene space.

Use `setPosition(_:relativeTo:)` to express a destination in scene or another entity's space. Use `convert(position:to:)` for points and `convert(direction:to:)` for vectors; a direction does not include translation. ``SpriteUI/AffineTransform2D`` retains shear that nested rotations and nonuniform scales can produce. Conversion can be unavailable for unrelated worlds or singular reference transforms, and writes validate before mutating.

Opted-in kinematic `TransformInterpolationComponent` presentation blends previous and current fixed local poses with one fixed tick of latency. `entity.presentation`, displayed hit testing, and attachment projection follow this displayed pose, while model/physics queries and snapshots stay canonical. Teleports outside fixed ticks snap automatically; inside a fixed tick, call the component’s `reset()`. Reactivation and reparenting invalidate history.

During `withAnimation`, components immediately contain their target values. ``SpriteUI/PresentationValues`` exposes what the renderer currently shows; its `position` is still parent-relative. Use presented conversions for a pointer that must follow visible artwork, and model transforms for game rules that intentionally use authoritative destinations. The model collision queries described in <doc:gameplay-and-movement> do not use the in-between animation pose.

## Give gestures an interaction shape and an owner

Add ``SpriteUI/InputTargetComponent`` to an entity or an ancestor to opt its subtree into targeted gestures. The nearest component wins, so a child with `isEnabled: false` can opt out. Provide an explicit ``SpriteUI/CollisionComponent`` when the touch region should differ from artwork or remain stable as artwork changes. A collider does not require a physics body.

The displayed hit-test path prefers explicit collision geometry, then physics or controller geometry, and uses visual bounds or paths as a fallback. A collider ancestor owns implicit descendant visual hits; a child with its own collider remains an independent candidate. Displayed masks clip gameplay hit testing.

This complete view makes the circle follow the drag location. It intentionally places the circle's center under the pointer; a game that needs an unchanged grab offset can store the offset at drag start.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct DragScene: View {
    var body: some View {
        GameView { content in
            let token = Entity(components: [
                ShapeComponent(.circle(radius: 24), fill: .cyan),
                CollisionComponent(shape: .circle(radius: 28)),
                InputTargetComponent()
            ])
            content.add(token)
        }
        .frame(minWidth: 320, minHeight: 240)
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    guard let point = value.convertIfAvailable(
                        value.location, to: .scene
                    ) else { return }
                    // A singular parent rejects this move and leaves the pose unchanged.
                    try? value.entity.setPosition(point, relativeTo: nil)
                }
        )
    }
}
```

``SpriteUI/EntityTargetValue`` carries the captured entity and the underlying gesture value. Its conversions use displayed transforms and the current camera. Attach the gesture to the `GameView` or a wrapper containing exactly one `GameView`. `targetedToEntity(_:)` selects a specific hierarchy owner; `targetedToEntity(where:)` selects the nearest matching ancestor.

For automatic dragging, rotation, uniform scaling, grab-offset preservation, and parent-local constraints, add `ManipulationComponent` and follow <doc:manipulating-entities>. That path installs GameView gestures automatically and also exposes programmatic sessions for accessible controls.

## Respect capture validity

Targets are captured from the gesture's starting pointer rather than a global last-hit entity. Removal, disabling, cancellation, activation/reuse, or reparenting that changes the resolved target cancels delivery. Gestures that cannot identify a starting point are delivered only for an unambiguous contact. These rules keep two fingers or two views from accidentally sharing a target.

Keep immediate changes in the handler. If an asynchronous task resumes later, check that the entity still belongs to the intended world and is active, and use an app-owned interaction generation if the same entity can be reused. A retained gesture value is not a permanent authorization to mutate a recycled entity. Prefer `convertIfAvailable` over the nonoptional conversion helpers when the host may have disappeared; a fallback zero is not a meaningful pointer location.

Interactive attachments reserve their UI rectangle, and explicit debug picking suppresses entity-targeted game input. Arbitrary ancestor SwiftUI gestures still follow SwiftUI's normal arbitration; these safeguards do not disable every gesture in your app. Use ``SpriteUI/AttachmentContext`` for actions launched from attachment controls, as shown in <doc:rendering-and-resources>.

## See also

- <doc:fixed-step-simulation-and-interpolation>

- <doc:entity-and-scene-lifecycle>
- <doc:gameplay-and-movement>
- <doc:saving-and-debugging>
