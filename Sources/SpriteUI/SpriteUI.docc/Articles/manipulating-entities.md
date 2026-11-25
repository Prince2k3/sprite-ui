# Letting the player move a token

In a puzzle, the player may need to drag a token, turn it, and resize it to fit a space. The same actions should also work from buttons. Give the token a set of allowed operations, then let gestures and controls use those rules.

## Make the token interactive

Add ``SpriteUI/InputTargetComponent`` so the token can be picked and ``SpriteUI/ManipulationComponent`` so it accepts transform changes. ``SpriteUI/GameView`` installs the gestures on its game surface; this approach needs no `.gesture` modifier.

On iOS, use pan, pinch, and rotation. On macOS, use pointer dragging and trackpad magnification and rotation. The buttons in this example offer another way to rotate and scale.

The scene owner keeps the token, renderer, and event subscriptions together. Status text follows the interaction, while the buttons begin and finish short manipulation sessions.

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

`operations` defaults to `.all`. For a token that should only slide, set it to `.translation`. Changing the manipulation component's `isEnabled` turns these operations off without hiding the token or changing its input-target component.

The retained subscriptions keep the status messages arriving. Their weak captures let the scene owner go away when the view releases it. ``SpriteUI/ManipulationEvents`` reports `Began`, `Changed`, `Ended`, and `Cancelled` after the corresponding state is committed.

## Keep a piece on a rail

A puzzle piece may need to move along a tilted rail instead of following the pointer freely. Put it under a parent that represents the rail, then constrain translation in that parent's coordinates.

Here, `.x` keeps the child's starting local y position. The grid snaps in 20-point steps from the parent origin, and the limits keep the child's origin between the ends of the rail.

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

The parent can rotate and scale without changing the meaning of the child's local x axis. Scene-space dragging is converted into parent coordinates before the lock, snapping, and limits apply.

Translation limits constrain the entity's origin, so large artwork can still extend past the rail. Rotation snapping uses radians measured from local zero.

`scaleRange` defaults to `0.25...4` and limits the absolute local scale values. A scale gesture applies one multiplier to both axes, preserving aspect ratio and reflection. Parent scaling is separate from this local limit.

## Use the same rules from a button or custom tool

The first example calls `beginManipulation(of:at:operations:)` because it already knows the token. ``SpriteUI/SpriteRenderer`` also offers `beginManipulation(at:operations:)` to pick at a scene point. Picking starts with the frontmost input target and looks for its nearest manipulation owner.

Both return an optional ``SpriteUI/ManipulationSession``. The `at:` anchor is in scene coordinates. For the stationary token, `token.scenePosition` supplies that point. When following animated artwork, project the displayed local origin with `renderer.viewPoint(from: .zero, relativeTo: entity)`, then convert it with `renderer.scenePoint(fromView:)`.

A session begins from the displayed pose and preserves the grab offset. Its `update` values are cumulative from the start: scene-space translation, parent-local counterclockwise rotation in radians, and a uniform scale factor. A total movement of 40 points uses `[40, 0]` on the latest sample rather than adding another 40 points each time.

Request only the operation a button changes. The rotation buttons therefore avoid snapping translation. A custom tool retains its session across samples, checks `isActive`, and finishes with `end()` or interrupts with `cancel()`. Cancellation keeps the current pose; implement undo separately if the puzzle needs it. `cancelManipulations()` ends the renderer's sessions before a reset or exit.

## Release a token with a physics body

During capture, native physics bodies in the token's subtree are temporarily static. Their `PhysicsBodyComponent.isDynamic` values stay unchanged. Ending or cancelling restores native dynamics using the configured body properties, including edits made during capture.

The default `physicsRelease: .stop` releases with zero linear and angular velocity. Gravity and contacts can move the token again immediately. Use `.restoreVelocity` to resume captured velocities. Gesture speed does not create a throw.

## Keep in mind

A failed begin returns `nil`; a rejected update returns `false`. Invalid limits, nonfinite values, nonpositive snap steps, or an impossible uniform scale are rejected without applying the proposed transform.

Let the session control the transform while it is active. Character controllers, transform constraints, dynamic-body ancestors, and joint-connected entities can conflict with manipulation and are rejected. Overlapping parent and child sessions are also rejected. Removal, activation or hierarchy changes, invalidated configuration, and interrupted input can cancel capture.

Placement does not sweep against colliders or prevent overlap. Use <doc:gameplay-and-movement> when the puzzle requires collision-aware movement. Interactive SwiftUI attachments and inspection controls reserve their own input areas.

Manipulation configuration can be cloned and saved as a registered Codable component. Active sessions, pointer state, temporary body suspension, and subscriptions must be recreated at runtime.

## Next lesson

Follow [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-manipulation-03.swift) to build the rail and physics examples in stages. Read <doc:systems-and-input> when a gesture should trigger a game rule rather than directly move the artwork.
