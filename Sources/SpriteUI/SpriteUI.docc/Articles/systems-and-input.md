# Moving entities and handling input

Suppose a ship should drift to the right while the player drags a separate token. The drift needs a rule that runs with game time. The drag needs a pointer location converted into the scene. Keeping those jobs separate makes both easier to follow.

## Turn speed into movement

Store a speed on each moving entity, then ask the world for entities that have it. A ``SpriteUI/System`` runs that rule; an ``SpriteUI/EntityQuery`` selects the matching entities.

This example uses scene coordinates so a rotated or scaled parent does not change the direction of travel. It calculates the destination in scene space, then asks the entity to convert that destination into its local position.

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

Install `SceneMotionSystem` in setup and add `SceneVelocity` to each entity it should move. The system multiplies points per second by `context.deltaTime` once. It records failed conversions in `MovementReport`, which another part of the game can inspect.

Queries reflect current membership and activation, so newly added movers join the rule and disabled ones stop moving. There is no separate list of movers to maintain.

## Read results after movement

A trail, camera hint, or UI marker may need positions after movement finishes. Systems have phases so you can choose when a rule runs:

| Phase | When it runs | A typical use |
| --- | --- | --- |
| `fixedSimulation` | Zero or more ticks before variable simulation, when a fixed clock is configured | Custom rules that need a constant time step |
| `simulation` | Once per advancing frame, before backend physics | Movement decisions and physics inputs |
| `presentation` | After backend physics has copied results into components | Reading the resulting poses |

The default is `simulation`. Here, `PositionSamplingSystem` runs in `presentation` and stores the movers' resulting scene positions.

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

Install both systems with `try world.systems.add(...)`. A ``SpriteUI/SystemDependency`` orders installed systems; it does not install another system for you. Phase order comes first. Cycles or dependencies that contradict it throw ``SpriteUI/SystemSchedulingError`` without replacing the working schedule.

For two systems in the same phase, declare their relationship when one needs the other's output. Otherwise installation order is retained. `world.systems.types` lets you inspect the resolved order.

## Use game time for game rules

In an ordinary frame system, `deltaTime` is elapsed scene time after `world.timeScale` is applied. `unscaledDeltaTime` is the elapsed time before that multiplier. A paused world or zero time scale skips ordinary simulation, so reading the unscaled value does not make a system run while paused. Keep responsive menus in SwiftUI.

For a constant step, configure `world.fixedStep`. Fixed systems receive its `stepDuration` and a `fixedTick`; variable systems still receive the frame's deltas. Follow <doc:fixed-step-simulation-and-interpolation> when you need this clock and smooth display between ticks.

Input can change more than once between fixed ticks. A caller-owned `FixedInputBuffer` preserves press and release transitions; call `consume()` once per tick. Cancel input and reset the buffer on pause or scene exit as appropriate for your game. Pausing the world does not clear that buffer for you.

## Convert a drag into a scene position

Give a draggable entity an ``SpriteUI/InputTargetComponent``. Add a ``SpriteUI/CollisionComponent`` when you want a touch area independent of the artwork. A collider can define input geometry without a physics body.

In this example, the touch circle is slightly larger than the visible circle. A targeted SwiftUI drag supplies the captured entity, and `convertIfAvailable` turns the pointer location into scene coordinates.

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

`setPosition(_:relativeTo: nil)` places the entity in scene space. This handler puts the circle's center under the pointer. To keep the original grab offset, store that offset when the drag begins, or use the automatic gestures in <doc:manipulating-entities>.

Attach the gesture to `GameView` or a wrapper containing exactly one `GameView`. ``SpriteUI/EntityTargetValue`` provides the captured entity and conversions through the current camera. `targetedToEntity(_:)` chooses a particular owner; `targetedToEntity(where:)` chooses the nearest matching ancestor.

An input-target component can make a whole subtree interactive. The nearest one wins, so a disabled input-target component on a child opts that child out. A collider on an ancestor owns visual hits from descendants without their own collider.

## Follow what the player can see

An entity's `position` is relative to its parent; `scenePosition` includes its ancestors. Relative conversion methods use `nil` for scene space. Use point conversions for locations and direction conversions for vectors, which should not include translation.

During animation, component transforms already contain the destination while the artwork may still be moving toward it. ``SpriteUI/PresentationValues`` describes the displayed pose. Targeted gesture conversions use displayed transforms so the pointer follows the artwork.

Fixed-step interpolation also changes only the displayed pose, trailing simulation by one fixed tick. Game collision queries and snapshots read model transforms. That difference explains why an animated sprite can be under a pointer while a model-space ray reports a different position.

## Keep in mind

This movement example assumes a moving entity does not have another moving entity as its ancestor. Queries do not promise hierarchy order. For such hierarchies, capture starting scene poses first, calculate destinations, then apply parents before children.

Conversions can fail for singular transforms or unrelated worlds. Use `convertIfAvailable` when the host may disappear. A failed position write leaves the pose unchanged.

Gesture capture can end when an entity leaves, is disabled, is reused, or changes its resolved owner. After awaiting work, check world membership and activation again; track an interaction generation if instances are reused. Interactive attachments reserve their UI areas, and debug picking suppresses targeted game input. Other SwiftUI gestures still use normal arbitration.

The renderer limits ordinary frame deltas to 1/15 second after stalls. Fixed clocks have separate catch-up limits; they do not turn SpriteKit physics or actions into deterministic fixed-step simulation. Advancing a world without a renderer runs system phases but does not simulate backend physics or renderer constraints.

## Next lesson

Read <doc:gameplay-and-movement> to choose between steering, route following, character movement, and physics. For dragging with rotation, scaling, and button alternatives, continue with <doc:manipulating-entities>.
