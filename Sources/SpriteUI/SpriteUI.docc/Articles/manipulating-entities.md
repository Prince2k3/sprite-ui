# Manipulating entities

Opt entities into automatic dragging, rotation, and uniform scaling, or drive the same interaction from accessible controls.

## Opt into GameView manipulation

Add both ``SpriteUI/InputTargetComponent`` and ``SpriteUI/ManipulationComponent`` to a visible entity. `InputTargetComponent` makes it pickable; `ManipulationComponent` declares which transform operations it accepts. ``SpriteUI/GameView`` automatically installs direct manipulation on its native game surface. No explicit `.gesture` modifier is needed.

On iOS, drag with a pan and use pinch and rotation for simultaneous changes. On macOS, drag with the pointer and use trackpad magnification and rotation. Provide buttons for users who cannot perform these gestures. Interactive SwiftUI attachments and inspection controls reserve their own input areas.

The following complete view includes an accessible alternative to rotation and scaling. The scene retains its event subscriptions, the buttons use the explicit renderer session API, and no frame system competes for the sprite's pose.

```swift
import Observation
import SpriteUI
import SwiftUI

@MainActor @Observable
final class ManipulationScene {
    let token = Entity(name: "token", components:
        SpriteComponent(color: .cyan, size: [48, 32]),
        InputTargetComponent(), ManipulationComponent())
    var status = "Drag, pinch, rotate, or use a button"
    private var renderer: SpriteRenderer?
    private var subscriptions: [EventSubscription] = []

    func install(in content: GameViewContent) {
        renderer = content.renderer
        content.add(token)
        subscriptions = [
            content.subscribe(to: ManipulationEvents.Began.self, on: token) { [weak self] _ in
                self?.status = "Began"
            },
            content.subscribe(to: ManipulationEvents.Changed.self, on: token) { [weak self] event in
                self?.status = "Changed: local x = \(event.transform.translation.x)"
            },
            content.subscribe(to: ManipulationEvents.Ended.self, on: token) { [weak self] _ in
                self?.status = "Ended"
            },
            content.subscribe(to: ManipulationEvents.Cancelled.self, on: token) { [weak self] event in
                self?.status = "Cancelled: \(event.reason.rawValue)"
            }
        ]
    }

    func adjust(rotation: Float = 0, scale: Float = 1) {
        guard let renderer else { return }
        let scenePoint = token.scenePosition
        let operations: ManipulationComponent.Operations = rotation == 0 ? .scale : .rotation
        guard let session = renderer.beginManipulation(
            of: token, at: scenePoint, operations: operations
        ) else {
            status = "The entity cannot begin manipulation"
            return
        }
        if session.update(translation: .zero, rotation: rotation, scale: scale) {
            session.end()
        } else {
            session.cancel()
        }
    }

    func cancel() { renderer?.cancelManipulations() }
}

@MainActor
struct ContentView: View {
    @State private var scene = ManipulationScene()

    var body: some View {
        VStack {
            GameView { scene.install(in: $0) }
                .frame(minWidth: 280, minHeight: 260)
            Text(scene.status).font(.caption)
            HStack {
                Button("Rotate left 15°") { scene.adjust(rotation: .pi / 12) }
                Button("Rotate right 15°") { scene.adjust(rotation: -.pi / 12) }
            }
            HStack {
                Button("Smaller") { scene.adjust(scale: 0.8) }
                Button("Larger") { scene.adjust(scale: 1.25) }
            }
        }
        .padding()
        .onDisappear { scene.cancel() }
    }
}
```

For a staged version with hierarchy constraints and a dynamic body, follow <doc:manipulating-sprites-with-gestures>.

## Choose operations and parent-local constraints

`operations` defaults to `.all`: translation, rotation, and scale. Set it to `.translation` for a drag-only entity, or combine operations in an option set. `isEnabled` disables manipulation without disabling rendering or changing `InputTargetComponent` pickability.

Translation bounds constrain the entity's origin in its parent's coordinates. Grid snapping measures from that parent's origin. `translationAxes = .x` locks the initial local y coordinate, even under a rotated or scaled parent. Bounds constrain the origin rather than every corner of the artwork. Rotation snapping uses radians measured from local zero.

This complete view places a child on a tilted, scaled parent rail. Dragging in scene space is converted to the parent's local axes before the lock, grid, and bounds apply.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct RailView: View {
    var body: some View {
        GameView { content in
            let parent = Entity(components: ShapeComponent(
                .rectangle(size: [220, 60]), fill: .mint.opacity(0.08), stroke: .mint
            ))
            parent.rotation = .pi / 6
            parent.scale = [1.1, 1.1]
            let child = Entity(components:
                SpriteComponent(color: .mint, size: [28, 28]),
                InputTargetComponent(),
                ManipulationComponent(
                    translationAxes: .x,
                    translationBounds: .init(min: [-100, -20], max: [100, 20]),
                    translationSnap: [20, 20],
                    rotationSnap: .pi / 12
                ))
            parent.addChild(child)
            content.add(parent)
        }
        .frame(minWidth: 320, minHeight: 280)
    }
}
```

`scaleRange` defaults to `0.25...4` and limits the absolute magnitudes of local scale components. A gesture applies one uniform multiplier, preserving aspect ratio and reflection; it does not independently clamp x and y. Inherited parent scaling is outside this local range. Nonfinite samples, nonpositive snap steps, invalid bounds, and configurations with no valid uniform scale are rejected without changing the transform.

## Drive a session programmatically

``SpriteUI/SpriteRenderer`` exposes `beginManipulation(at:operations:)` for picking at a scene-space point and `beginManipulation(of:at:operations:)` for a known entity. Both return an optional ``SpriteUI/ManipulationSession``. Automatic picking starts with the frontmost pickable hit and resolves the nearest ancestor with a manipulation component. The explicit overload is useful for tools and button actions.

Pass a scene-space anchor to the `at:` parameter. For a stationary demo entity, `let scenePoint = entity.scenePosition` uses the hierarchy-aware position. If an app needs an anchor from the currently presented artwork during animation, project its local origin with `renderer.viewPoint(from: .zero, relativeTo: entity)` and convert that view point with `renderer.scenePoint(fromView:)`. `beginManipulation` itself starts from the displayed pose, cancels conflicting transform playback, and keeps the pointer anchor so capture does not jump to a model pose or to the pointer center.

`session.update(translation:rotation:scale:)` takes cumulative values relative to capture start: scene-space pointer displacement, parent-local counterclockwise rotation in radians, and a uniform factor. Defaults are zero translation, zero rotation, and scale one. To move a total of 40 points, send `[40, 0]`; do not repeatedly add that displacement on every sample. Request only the channels a button changes so a rotation action does not unexpectedly snap translation.

Call `end()` for completion or `cancel()` for interruption. Cancellation releases capture at the current committed pose; it is not an undo operation. Keep a session alive across samples in a custom tool and check `isActive`; use `renderer.cancelManipulations()` to cancel all renderer sessions before a reset. A failed begin returns `nil`; a rejected update returns `false`.

## Observe lifecycle and respect ownership

``SpriteUI/ManipulationEvents`` publishes `Began`, `Changed`, `Ended`, and `Cancelled` from the manipulated entity. Every event carries `entity`, `initialTransform`, and the committed local `transform`; cancellation also carries a reason. Retain each ``SpriteUI/EventSubscription`` for as long as the interface observes it, and use weak captures when a scene owns the subscriptions. Callbacks see committed state and may update UI or request another interaction.

Removal, activation changes, hierarchy changes, invalidated configuration, and interrupted native input can cancel a capture. Simultaneous sessions on overlapping parent and child subtrees are rejected. Do not run a ticking system that writes the same entity transform while a session owns it. Entities driven by a character controller or transform constraints, entities under a dynamic-body ancestor, and entities connected by physics joints deliberately reject manipulation to avoid conflicting transform ownership.

## Hand physics back on release

Capturing an entity temporarily makes native physics bodies in its target subtree static. Their `PhysicsBodyComponent.isDynamic` configuration remains unchanged throughout capture; the temporary handoff is renderer state, never persisted component state. End and cancellation restore native dynamics according to the configured body properties while preserving application edits to those properties.

The default `physicsRelease: .stop` gives released bodies zero linear and angular velocity. Gravity and subsequent contacts can move them again immediately. Choose `.restoreVelocity` to resume with their captured velocities. Gesture speed does not produce a throw. Manipulation placement does not sweep against colliders or avoid overlap; use collision queries or character movement when placement must be collision-aware.

Manipulation configuration is Codable and participates in registered component save/restore and cloning. Active sessions, native body suspension, pointer state, and subscriptions are runtime state and are neither saved nor cloned.

## See also

- <doc:systems-and-input>
- <doc:gameplay-and-movement>
- <doc:saving-and-debugging>
- <doc:manipulating-sprites-with-gestures>
