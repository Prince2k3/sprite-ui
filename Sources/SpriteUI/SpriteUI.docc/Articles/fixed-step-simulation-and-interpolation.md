# Run game rules at a steady pace and smooth their motion

A sprite moving across the screen should follow the same game rule whether the display draws 30 or 120 frames per second. You may also want a quick tap between updates to fire a shot rather than disappear before the game reads it.

A fixed-step world runs your rules in equal time intervals, called ticks. Drawing can happen more or less often. SpriteUI can smooth eligible sprite motion between ticks and keep input transitions until a tick consumes them.

## Move a sprite in equal time steps

Set `world.fixedStep`, then put the movement system in `.fixedSimulation`. Both are needed: enabling the clock does not move existing systems into that phase. Without a fixed configuration, a world keeps its usual variable-step behavior.

This view moves the cyan square at 80 points per scaled second, using 60 ticks per second. Each update multiplies the speed by the tick's duration.

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

Each display frame can run zero, one, or several fixed ticks. `WorldEvents.Update` arrives first, then each tick publishes `WorldEvents.FixedUpdate` and runs fixed systems. Ordinary `.simulation` systems still run once per frame. Native physics and actions keep their display-frame lifecycle, followed by `.presentation` systems after physics results return to components.

Choose one place to own movement. Applying it in both a frame callback and a fixed system moves the sprite twice. <doc:systems-and-input> explains system ordering and coordinate spaces.

## Catch up after a slow frame

The default ``SpriteUI/FixedStepConfiguration`` requests 60 ticks per scaled second, permits eight catch-up ticks in a frame, and accepts at most 0.25 seconds of raw elapsed time before applying `world.timeScale`. Replace the configuration to change those settings.

If a frame takes longer, the clock runs several ticks of the same duration. If the work exceeds the catch-up limit, it drops excess whole ticks and keeps the remaining fraction for drawing. For example, a 0.1-second frame at 60 Hz needs six ticks; a limit of two executes two and drops four. This prevents one late frame from demanding an ever-growing queue of simulation work.

Inspect `world.fixedStepState` after fixed processing, such as from a presentation system. `ticksThisFrame` reports work just done, `interpolationAlpha` reports the remaining fraction, and `droppedTime` reports scaled time discarded in this frame. `tick` and `simulationTime` count executed work over the world's lifetime; neither includes dropped ticks. Sum `droppedTime` yourself if you want a total.

Fixed systems receive a constant scaled `deltaTime` and a `fixedTick`. Slow motion changes how often ticks happen in real time. Their unscaled delta is `stepDuration / world.timeScale`; variable systems keep their frame deltas.

## Smooth the artwork between ticks

Add `TransformInterpolationComponent(isEnabled: true)` to a sprite moved by your fixed rules. The renderer blends its previous and current local transforms using the leftover fraction of a tick. This makes low-frequency movement look smoother, at the cost of displaying it one tick behind the simulation.

Position, scale, and z position blend linearly; rotation takes the shortest arc. The entity's stored transform still holds the simulation state. `entity.presentation` reports the displayed pose, which also guides presentation hit testing, targeted gesture conversion, and attachment projection. Model and physics queries continue using their own geometry.

For a teleport inside a fixed tick, reset interpolation after setting the new position so the sprite jumps rather than sliding across the gap.

```swift
import SpriteUI

@MainActor
func teleportDuringFixedTick(_ entity: Entity, to position: SIMD2<Float>) {
    entity.position = position
    entity.components[TransformInterpolationComponent.self]?.reset()
}
```

Transform writes outside a fixed tick already snap the artwork and discard old history. Reactivation and reparenting also clear history, so reused entities do not blend from an old placement.

## Keep a quick tap until the next tick

Polling the current button value can miss a press and release between ticks. Retain a ``SpriteUI/FixedInputBuffer`` and call `consume()` once per tick. Give that one sample to every rule that needs input during the tick.

The sample contains held values and transitions. `wasPressed` catches a whole tap between ticks; a later catch-up tick keeps held values without repeating that tap. This helper extracts movement and fire information from one sample.

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

The buffer defaults to 256 events. If it fills, it drops the oldest event and reports `didOverflow`; held values remain current, but some transitions were lost. Cancellation discards stale queued edges and is distinct from a normal release.

## Discard old commands when pausing

Pausing the world does not clear a caller-owned input buffer. Disable input, cancel held controls, and reset the buffer before resuming later. This helper also prevents late samples from accumulating while paused.

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

Use the same cleanup when the app becomes inactive or the view disappears, and release virtual controls to neutral. Pause, time-scale or configuration changes, root disablement, and host suspension reset clock debt and interpolation history. Lifetime counters keep increasing; background time is not replayed on return.

Use `GameRenderConfiguration(preferredFramesPerSecond:)` to request a drawing cadence independently. Changing that request does not change the fixed frequency or rebuild the world. [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-fixed-step-03.swift) uses 20 Hz rules to make the difference between stepped and smoothed motion easy to see.

## Limits to keep in mind

Interpolation is for kinematic artwork owned by fixed game logic. Physics-related subtrees, cameras, character controllers, transform constraints, and active native transform animations cannot also use it. The fixed clock does not turn SpriteKit physics or actions into a fixed-tick solver, or guarantee a deterministic world.

`world.update(deltaTime:)` runs system phases without native physics or renderer interpolation. A paused renderer debug step advances one fixed tick but still has a separate native backend operation. Reproducible runs also require stable input, random state, system ordering, and algorithms.

Continue with <doc:input-recording-and-replay> when you need to reproduce a sequence of commands.

## See also

- <doc:input-actions-and-controllers>
- <doc:rendering-and-resources>
- <doc:saving-and-debugging>
