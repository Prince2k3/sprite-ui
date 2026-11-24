# Fixed-step simulation and interpolation

Advance custom game rules at a fixed cadence, smooth kinematic artwork between ticks, and preserve input transitions until simulation consumes them.

Follow <doc:running-fixed-step-simulation> for three complete, asset-free stages. They use pure kinematic entities and run on iOS 18 or macOS 15. <doc:systems-and-input> explains scheduling and coordinate spaces; <doc:rendering-and-resources> covers the renderer's other motion owners.

## Opt a world into fixed simulation

`world.fixedStep` is a `FixedStepConfiguration?` and defaults to `nil`. Existing worlds retain their variable-step behavior. Assign a configuration and explicitly place custom systems in `.fixedSimulation`; enabling the clock does not move existing systems into that phase.

``SpriteUI/FixedStepConfiguration`` is an immutable `Hashable`, `Codable`, and `Sendable` value. Replace the configuration to change its settings.

| Initializer parameter | Default | Meaning |
| --- | --- | --- |
| `stepsPerSecond` | `60` | Fixed simulation frequency in scaled scene time |
| `maximumCatchUpSteps` | `8` | Maximum ticks allowed in one advancing display frame |
| `maximumFrameDeltaTime` | `0.25` | Maximum raw elapsed seconds accepted before applying `world.timeScale` |

`stepDuration` is `1 / stepsPerSecond`. The initializer bounds frequency to `1...1000`, catch-up steps to `1...120`, and the frame interval to `0.001...10`; nonfinite frequency or frame-interval inputs use their defaults. Decoding applies the same normalization.

This complete view moves one kinematic sprite at 60 simulation ticks per scaled second. It needs no physics body, controller, actions, or assets.

```swift
import SpriteUI
import SwiftUI

struct FixedVelocity: Component {
    var pointsPerSecond: Float = 80
}

@MainActor
struct FixedMotionSystem: System {
    static var phase: SystemPhase { .fixedSimulation }
    private let query = EntityQuery(where: .has(FixedVelocity.self))

    init(world: World) {}

    func update(context: UpdateContext) {
        for entity in context.entities(matching: query) {
            guard let velocity = entity.components[FixedVelocity.self] else { continue }
            entity.position.x += velocity.pointsPerSecond * Float(context.deltaTime)
        }
    }
}

@MainActor
struct FixedMotionScene: View {
    @State private var status = "Preparing fixed simulation"

    var body: some View {
        VStack {
            GameView { content in
                content.world.fixedStep = FixedStepConfiguration(
                    stepsPerSecond: 60, maximumCatchUpSteps: 8,
                    maximumFrameDeltaTime: 0.25
                )
                content.add(Entity(components:
                    SpriteComponent(color: .cyan, size: [32, 32]), FixedVelocity()))
                do {
                    try content.world.systems.add(FixedMotionSystem.self)
                    status = "Fixed simulation ready"
                } catch {
                    status = "Could not schedule fixed motion: \(error)"
                }
            }
            .frame(height: 240)
            Text(status)
        }
    }
}
```

## Distinguish a frame from a tick

An advancing frame has this order:

1. `WorldEvents.Update` publishes once, before all systems. Its existing `world` and `deltaTime` payload is unchanged.
2. Zero or more fixed ticks run. Each publishes `WorldEvents.FixedUpdate` before its `.fixedSimulation` systems.
3. Legacy `.simulation` systems run once with the display-frame delta.
4. The backend advances native physics and actions through its existing display-frame lifecycle.
5. `.presentation` systems run once after backend physics results are copied into components, followed by the renderer's late presentation work.

Headless `world.update(deltaTime:)` runs the same system-phase order without native physics or renderer interpolation. A frame may advance no fixed tick, or several catch-up ticks. Cross-phase dependencies must respect `fixedSimulation`, then `simulation`, then `presentation`.

`WorldEvents.FixedUpdate` contains `world`, `deltaTime`, `unscaledDeltaTime`, and `tick: UInt64`. Fixed event handlers and fixed systems receive a constant scaled `deltaTime` equal to `stepDuration`. Their unscaled delta is `stepDuration / world.timeScale`, so slow motion changes how often ticks occur in wall time. `UpdateContext.fixedTick` is a `UInt64?`, populated for fixed systems and nil for variable systems. `UpdateContext.interpolationAlpha` exposes the frame's fractional remainder. Existing simulation and presentation systems retain their display-frame deltas; they do not receive a fixed delta just because the world enables the clock.

Use one owner for each game rule. Moving an entity in both the frame update event and a fixed system integrates movement twice.

## Bound catch-up and inspect the clock

The clock clamps raw elapsed time to `maximumFrameDeltaTime` before scaling it, accumulates scaled time, and runs at most `maximumCatchUpSteps`. If more whole ticks remain, it drops those whole ticks while preserving the fractional remainder for interpolation. A smaller render FPS can produce several simulation ticks in one frame without changing their duration.

Read ``SpriteUI/FixedStepState`` from `world.fixedStepState` after fixed processing, such as in a presentation system:

| Property | Interpretation |
| --- | --- |
| `tick` | Lifetime executed tick count (`UInt64`); dropped ticks do not increment it |
| `ticksThisFrame` | Ticks executed in the latest advancing frame |
| `interpolationAlpha` | Remaining fraction of a fixed step after tick processing |
| `droppedTime` | Scaled excess discarded **this frame**, including the raw-delta clamp and whole ticks beyond the catch-up budget |
| `simulationTime` | Sum of executed fixed tick durations across configuration changes |

`droppedTime` is neither a cumulative total nor a count of dropped render frames. With a 60 Hz clock, a budget of two ticks, and a 0.1-second frame at time scale 1, four whole ticks are dropped and two execute. A fractional remainder, if present, survives. Sum `droppedTime` yourself if you need a lifetime metric. `simulationTime` excludes discarded time and can differ from accumulated variable-frame time.

Pause, changing the configuration or time scale, disabling the world root, and host suspension/resume reset clock debt and interpolation history. They do not rewind lifetime tick or simulation-time counters. No background interval is replayed on resume. A zero time scale freezes ordinary simulation. UI that must respond while paused belongs to SwiftUI's lifecycle.

With fixed stepping enabled, a paused debug step advances exactly one fixed tick. Its ordinary native physics frame remains a separate backend operation; it is not a fixed-tick SpriteKit physics solver.

## Interpolate only eligible kinematic artwork

Add `TransformInterpolationComponent(isEnabled: true)` to opt an entity into renderer interpolation. The component is `Codable` and registered with the core component registry. Stored transforms remain canonical, including in model queries and snapshots; interpolation history is runtime state.

The renderer blends the previous and current fixed **local** poses using `interpolationAlpha`: position, scale, and z position are linear, and rotation follows the shortest arc. This intentionally displays motion one fixed tick behind simulation. It does not predict the next pose. `entity.presentation` reads the displayed pose. Displayed hit testing, targeted gesture conversions, and attachment projection follow that pose; model and physics queries use their own canonical geometry.

Use pure kinematic entities whose transforms belong to fixed game logic. Native physics/body-related subtrees, cameras, character-controller or transform-constraint ownership, and active native transform animations reject interpolation. Do not combine the marker with competing native motion owners. SpriteKit physics and actions keep their existing per-display backend lifecycle; the fixed clock only schedules custom fixed systems. It provides neither deterministic native physics nor a guarantee that the complete world is deterministic. Reproducibility also depends on input ordering, random state, system ordering, and your algorithms.

### Snap teleports and lifecycle changes

Transform writes outside a fixed tick automatically snap and discard stale interpolation history. Reactivation and reparenting also invalidate history, so a recycled or moved hierarchy does not blend from its previous placement. Re-establish its intended canonical pose at those boundaries.

Inside a fixed tick, normal transform writes are motion samples. For a teleport, call the component's `reset()` through the component set to increment its revision and discard the pre-teleport pose:

```swift
import SpriteUI

@MainActor
func teleportDuringFixedTick(_ entity: Entity, to position: SIMD2<Float>) {
    entity.position = position
    entity.components[TransformInterpolationComponent.self]?.reset()
}
```

## Consume buffered input once per tick

Polling a controller's current value can miss a press and release that both occurred between ticks. Retain ``SpriteUI/FixedInputBuffer`` with `init(input: InputController, capacity: Int = 256)` and call `consume()` once per fixed tick. Share the resulting ``SpriteUI/FixedInputSample`` among that tick's game rules instead of draining the same buffer from multiple systems.

`sample.value(for:)` captures resolved held values. `events: [InputActionEvent]`, `wasPressed(_:)`, and `wasReleased(_:)` preserve transitions, including a complete tap between ticks. Consuming drains edges once; subsequent catch-up ticks keep held values without repeating edges. Cancellation is not a release. Controller cancellation advances a revision that discards stale queued edges even when the action was already released, and current held values remain authoritative. Capacity is bounded to `1...4096`; overflow drops the oldest event and sets `didOverflow` on the next sample. Reset or consumption clears that flag. Treat overflow as lost transition history, not lost held-state authority.

This complete helper consumes one sample and returns the resolved movement and tap information. Call it once from the owning fixed system, then distribute the result to other rules that need it.

```swift
import SpriteUI

enum FixedActions {
    static let move = InputAction("move", kind: .axis2D)
    static let fire = InputAction("fire")
}

@MainActor
func consumeFixedCommands(from buffer: FixedInputBuffer)
    -> (movement: SIMD2<Float>, fired: Bool, released: Bool, overflowed: Bool) {
    let sample = buffer.consume()
    return (sample.value(for: FixedActions.move).vector,
            sample.wasPressed(FixedActions.fire),
            sample.wasReleased(FixedActions.fire), sample.didOverflow)
}
```

The buffer is caller-owned and has no world-pause subscription. Explicitly discard pending input when pausing or leaving the scene. `buffer.reset()` drops edges without changing held values; `input.cancelAll()` cancels held sources and requires neutral before they can actuate again. This complete helper does both and gates late samples while paused:

```swift
import SpriteUI

@MainActor
func setFixedScenePaused(_ paused: Bool, world: World,
                         input: InputController, buffer: FixedInputBuffer) {
    input.isEnabled = false
    input.cancelAll()
    buffer.reset()
    world.isPaused = paused
    input.isEnabled = !paused
}
```

Apply the same cleanup on inactivity and disappearance. Release app-owned virtual controls to neutral before reusing them. Native focus cancellation clears controller transitions, but changing only `world.isPaused` does not cancel the buffer.

## Choose rendering cadence independently

Use `GameRenderConfiguration(preferredFramesPerSecond:)` on `GameView(rendering:)` for requested display cadence. Changing 30, 60, or 120 preferred FPS does not change the fixed frequency or rebuild the world. Actual display cadence depends on the device. The ordinary renderer frame-delta cap remains separate from the fixed clock's raw-delta clamp. The tutorial deliberately uses 20 Hz simulation so the unsmoothed and interpolated actors are easy to compare.

## See also

- <doc:input-recording-and-replay>
- <doc:running-input-replays>
- <doc:running-fixed-step-simulation>
- <doc:systems-and-input>
- <doc:input-actions-and-controllers>
- <doc:rendering-and-resources>
- <doc:saving-and-debugging>
