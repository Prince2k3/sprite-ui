# Show world sprites in one camera and map icons in another

A comet might look like a large square in the game and a small diamond on the map. Both pictures should follow the same moving body. You do not need two comets, two physics bodies, or two movement rules.

Put the shared game object on a parent entity, then give it separate artwork children. Render layers tell each camera which artwork to show. They change presentation rather than collision or simulation.

## Give one moving object two pictures

The helper below gives a physical parent a cyan square for the world view and a mint diamond for the map. Both children inherit the same position.

```swift
import SpriteUI
import SwiftUI

private extension RenderLayer {
    static let map = RenderLayer(rawValue: 1 << 1)
}

@MainActor
func makeLayeredObject() -> Entity {
    let object = Entity(name: "Comet", components:
        PhysicsBodyComponent(shape: .circle(radius: 14), affectedByGravity: false,
                             velocity: [40, 30]))
    let square = Entity(components:
        SpriteComponent(color: .cyan, size: [28, 28]),
        VisibilityComponent(layers: .default))
    let diamond = Entity(components:
        SpriteComponent(color: .mint, size: [12, 12]),
        VisibilityComponent(layers: .map))
    diamond.rotation = .pi / 4
    object.addChild(square); object.addChild(diamond)
    return object
}
```

``SpriteUI/RenderLayer`` names groups of artwork. `.default` uses bit zero; define your own groups with bits 1 through 63. `.all` includes every group, and `.none` includes none. These groups are independent of collision categories, lighting masks, stencil masks, and drawing order.

A ``SpriteUI/VisibilityComponent`` places artwork in one or more layers. The square belongs to `.default` and the diamond to `.map`. The parent has no visibility component, so it does not restrict either child.

## Keep a parent's visibility broad enough for its children

Each ancestor with a visibility component also has to permit drawing. Hiding the parent hides both pictures; a child cannot override that. Restricting the parent to `.default` would also prevent the map diamond from appearing in a map-only camera.

For a shared hide switch, give the parent `VisibilityComponent(layers: [.default, .map])` or `.all`, then toggle `isVisible`. Adding a default visibility component is not neutral: its default layer is `.default`. Leaving the component absent is unrestricted. An empty layer set hides the entity and its descendants from all cameras.

## Choose what each camera sees

A camera's `cullingMask` selects permitted layers and defaults to `.all`. A viewport can narrow that selection further with its own mask. The final selection is their intersection, so a viewport cannot add something its camera excludes.

This helper creates separate world and map cameras. Add both cameras to the world once, retain them, and present the returned viewports in one `GameView`.

```swift
import SpriteUI

@MainActor
func makeLayerCameras(restrictMapToWorld: Bool) -> (cameras: [Entity], viewports: [GameViewport]) {
    let map = RenderLayer(rawValue: 1 << 1)
    let worldCamera = Entity(components: CameraComponent(smoothing: 0, cullingMask: .default))
    let mapCamera = Entity(components: CameraComponent(smoothing: 0, cullingMask: map))
    return ([worldCamera, mapCamera], [
        GameViewport(id: "world", camera: worldCamera.id,
                     frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
        GameViewport(id: "map", camera: mapCamera.id,
                     frame: .init(x: 0.5, y: 0, width: 0.5, height: 1),
                     cullingMask: restrictMapToWorld ? .default : nil)
    ])
}
```

Normally the left camera shows the square and the right shows the diamond. When `restrictMapToWorld` is true, the map camera allows only map art while its pane allows only default art. The intersection is empty, so that pane shows neither. Even untagged entities cannot appear through an empty camera mask.

Both panes remain interactive in this example. Visibility and `isInteractive` answer different questions: a noninteractive map can still show artwork. <doc:viewports-and-split-screen> explains framing and how a gesture keeps track of its starting camera.

## Hide the artwork while the object keeps moving

Visibility does not deactivate an entity. Its physics, contacts, systems, actions, audio, and model queries continue. Hide a comet, wait, then show it again: it should appear where its simulation has taken it. Use activation instead when gameplay itself should stop.

This helper hides the parent and its art without changing its physics or activation.

```swift
import SpriteUI

@MainActor
func setVisualHidden(_ hidden: Bool, object: Entity, renderer: SpriteRenderer,
                     viewportID: String) -> Bool {
    object.components.set(VisibilityComponent(layers: .all, isVisible: !hidden))
    return renderer.isVisible(object, inViewport: viewportID)
}
```

`renderer.isVisible(_:inViewport:)` answers whether activation, ancestor visibility, camera layers, and native hiding permit presentation. It does not tell you whether the entity is inside the screen bounds, opaque, or covered by another sprite. An unknown viewport returns false; nil uses the primary camera policy. `visibilityMask(inViewport:)` returns nil for an invalid pane.

Visibility values survive snapshots and cloning. Cameras saved before masks were added default to `.all`; an absent visibility component remains unrestricted.

## Attach selection labels to the picture that was tapped

Targeted gestures pick visible art in the pane where the interaction begins. Hiding that art or excluding it with a mask cancels its captured interaction. A hide/show cycle does not revive the old capture. Manual picking can use `renderer.entities(at:filter:inViewport:)` or `renderer.inputTarget(at:filter:inViewport:)` with the same pane ID.

Put a selection label under the chosen artwork child, then scope its `viewportID` to the tapped pane. The label inherits the art's visibility, so hiding world squares also hides their labels without removing map selections.

```swift
import SpriteUI

@MainActor
func addVisibleSelection(to art: Entity, renderer: SpriteRenderer, viewportID: String) -> Entity? {
    guard renderer.isVisible(art, inViewport: viewportID) else { return nil }
    let anchor = Entity(components:
        AttachmentComponent(id: "selected", offset: [0, -29], viewportID: viewportID))
    art.addChild(anchor)
    return anchor
}
```

Define the `selected` attachment template in the owning game view. Leaving an attachment's viewport nil projects it into every eligible pane, but does not bypass ancestor visibility. Hidden attachment controls reserve no input regions, and attachments cannot make a noninteractive pane interactive.

If you observe ``SpriteUI/VisibilityEvents/DidChange``, use the event's saved `previousPolicy` and `policy` to describe the change. Another callback may already have changed the live component again.

Continue with [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-render-layers-03.swift) to build the world-and-map scene. For camera-relative background artwork, read <doc:parallax-and-repeating-backgrounds>.

## See also

- <doc:entity-and-scene-lifecycle>
- <doc:rendering-and-resources>
