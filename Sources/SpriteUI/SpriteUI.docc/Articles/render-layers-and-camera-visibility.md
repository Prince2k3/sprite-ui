# Render layers and camera visibility

Give the same simulated objects different artwork in a world view and an interactive map.

## Choose layers for presentation

``SpriteUI/RenderLayer`` is a `UInt64` option set. `.default` reserves bit zero, `.all` includes all 64 bits, and `.none` is empty. Define app-specific names using bits 1 through 63. Layers control presentation independently of collision categories, lighting masks, stencil masks, and z ordering.

``SpriteUI/VisibilityComponent`` defaults to `layers: .default` and `isVisible: true`. An entity **without** that component is unrestricted, equivalent to `.all` for the layer test. Adding a default component to a previously untagged container therefore changes its policy: it now gates the entire subtree to the default layer.

Every explicit ancestor must be visible and have at least one layer in common with the effective camera mask. A child cannot escape a hidden ancestor or an ancestor whose layers do not match. Ancestor checks are separate: an ancestor allowing both world and map art permits a child restricted to either one. An empty component layer set hides that entity and its descendants through every camera.

## Give one object separate artwork

Keep physics and simulation on a neutral parent. Put world art on a default-layer child and map art on another child. Both inherit the same physical position; no duplicate body or second simulation is necessary. The complete helper below creates this hierarchy. Keep its custom layer declaration once per app target.

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

Leaving the parent untagged is neutral. If it needs a visual hide switch, give it `VisibilityComponent(layers: [.default, .map])` or `.all`, then toggle `isVisible`. Setting its layers to `.default` would also hide its map child in a map-only camera. The eighth tutorial, <doc:presenting-a-world-with-render-layers>, walks through all three cases with complete runnable stages.

## Intersect camera and viewport masks

``SpriteUI/CameraComponent`` has a `cullingMask` default of `.all`. ``SpriteUI/GameViewport`` has an optional `cullingMask` default of nil. The effective mask is:

`camera.cullingMask.intersection(viewport.cullingMask ?? .all)`

A viewport restriction can narrow a camera's mask. It cannot add a layer excluded by that camera. A nil-camera viewport uses the active camera's mask, or `.all` at the origin if there is no active camera. Omitting the viewport API still applies the primary camera's visibility policy. See <doc:viewports-and-split-screen> for framing and coordinate conversion.

This complete helper creates two retained cameras and their side-by-side descriptors. Add both camera entities to the world before presenting these viewports. Retain the returned cameras rather than calling this helper on each view update.

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

With the restriction enabled, the right pane has an empty effective mask: map intersects world to produce `.none`. Even untagged entities are hidden when the camera mask is empty. Changing the map camera to `[.default, map]` then admits only default-layer art through the restricted pane. A pane with `isInteractive: false` can still show art, but this example deliberately leaves **both** panes interactive.

Use one `GameView(viewports: ...)` for the pair. It advances one world clock and one physics simulation, then presents the same world through both cameras. Keep the view and entity identities stable when changing masks.

## Hide visuals while gameplay continues

Visual hiding does not deactivate entities. Physics contacts, systems, model queries, actions, and audio continue. Use activation when gameplay itself should stop; use visibility when an object should keep participating while its presentation changes. Empty camera masks and hidden ancestors are also visual-only policies.

This helper hides a physical parent and its art, without changing its activation or physics components:

```swift
import SpriteUI

@MainActor
func setVisualHidden(_ hidden: Bool, object: Entity, renderer: SpriteRenderer,
                     viewportID: String) -> Bool {
    object.components.set(VisibilityComponent(layers: .all, isVisible: !hidden))
    return renderer.isVisible(object, inViewport: viewportID)
}
```

`renderer.isVisible(_:inViewport:)` checks activation, explicit visibility ancestors, the resolved pane's effective mask, and explicit native hiding. It is a policy query, **not** an on-screen, bounds, opacity, or pixel-occlusion test. Nil uses the primary camera policy; an unknown explicit viewport returns false. `renderer.visibilityMask(inViewport:)` returns nil for an invalid explicit pane. Noninteractive panes can still return true for visual visibility.

Snapshots and cloning preserve visibility values. Older camera snapshots without `cullingMask` decode to `.all`, and older viewport configuration retains its unrestricted default. An absent visibility component continues to be neutral.

## Select visible art and attach labels to it

Targeted gestures choose visible targets in the pane where input begins. A capture stays associated with that pane; hiding the captured target or excluding it with a camera mask cancels its interaction. Physics queries keep their existing behavior even when the same entities are visually hidden. For manual picking, pass the pane ID to `renderer.entities(at:filter:inViewport:)` or `renderer.inputTarget(at:filter:inViewport:)`.

``SpriteUI/VisibilityEvents/DidChange`` retains both `previousPolicy` and `policy`, with an increasing `revision`. A callback can immediately change visibility again, so use those immutable policies to describe the reported transition rather than assuming the live component still matches it. Existing captures stay cancelled after a hide/show cycle; policy edits that keep a presentation visible preserve its interaction and attachment state.

Put selection attachment anchors **under the selected art**, so that art's ancestors gate the label too. Scope `AttachmentComponent.viewportID` to the tapped pane. A nil attachment viewport projects into every eligible pane; it does not bypass the hierarchy's visibility rules. Hidden attachment controls do not reserve input regions. A noninteractive viewport never gains interaction from an attachment.

This complete helper creates a pane-scoped anchor only when the art is eligible in that pane. Define its `selected` template in the owning `GameView` attachment builder, as in the tutorial's final stage.

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

The demo's **Layers** tab combines these controls in a 280-point arena. Hide both objects, wait several seconds, and observe the actual bounce count and elapsed simulation. Reveal them to see their new positions. Select a world square and a map diamond, hide world squares, and check that only the corresponding label disappears. Contact totals depend on elapsed simulation; they are counted from events rather than estimated from the number of panes.

## See also

- <doc:parallax-and-repeating-backgrounds>
- <doc:presenting-a-world-with-render-layers>
- <doc:viewports-and-split-screen>
- <doc:entity-and-scene-lifecycle>
- <doc:rendering-and-resources>
