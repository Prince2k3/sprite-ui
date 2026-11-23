# Viewports and split screen

Present one simulated world through independent cameras, with viewport-aware input and SwiftUI attachments.

## Keep one world and one host

Pass a nonnil `[GameViewport]` to one ``SpriteUI/GameView``. The viewport host retains one ``SpriteUI/World``, one ``SpriteUI/SpriteRenderer``, and one native SpriteKit simulation driven by Metal. Each display tick updates the scene once, including physics, actions, camera following, and audio, then draws it through the resolved camera regions. Additional camera passes do not create additional worlds or simulation updates.

Each additional viewport adds an offscreen draw and a reusable texture. Camera draws finish sequentially to isolate SpriteKit's shared rendering state before composition. Keep the number of views small when budgeting rendering work; simulation still advances once.

The `viewports` parameter precedes `debug` in both `GameView` initializers, including the attachment-builder initializer. Omitting it, or passing nil, preserves the legacy SKView host. Passing an empty array selects the Metal host with one full-size automatic-camera viewport. Changing arrays on a stable `GameView` updates presentation without recreating entities. Changing host mode cancels captured input.

Follow <doc:sharing-a-world-between-viewports> for three complete app stages. <doc:player-input-sessions-and-feedback> explains device ownership; viewports do not automatically assign players or devices.

## Define stable regions and camera identities

``SpriteUI/GameViewport`` uses a string `id`, an optional camera `Entity.ID`, a ``SpriteUI/ViewportRect``, and `isInteractive`. Create camera entities once before computing viewport arrays. Recreating camera entities inside a SwiftUI `body` would produce new IDs on reevaluation. For independent framing, give each player its own camera entity and target.

This complete view places two cameras side by side. Both view the same beacon, from different positions. Changing viewport membership later does not remove the camera or any player from the world.

```swift
import SpriteUI
import SwiftUI

@MainActor
private final class CameraRig {
    let left = Entity(components: CameraComponent(smoothing: 0))
    let right = Entity(components: CameraComponent(smoothing: 0))

    var viewports: [GameViewport] {
        [GameViewport(id: "left", camera: left.id,
                      frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
         GameViewport(id: "right", camera: right.id,
                      frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))]
    }

    func install(in content: GameViewContent) {
        left.position = [-60, 0]
        right.position = [60, 0]
        content.add(left); content.add(right)
        content.add(Entity(components: SpriteComponent(color: .mint, size: [24, 48])))
    }
}

@MainActor
struct SplitScreenView: View {
    @State private var rig = CameraRig()
    var body: some View {
        GameView(viewports: rig.viewports) { rig.install(in: $0) }
            .frame(height: 360)
    }
}
```

Regions use normalized top-left coordinates: x increases rightward and y downward. `ViewportRect.full` covers the host. Rectangles intersect the 0...1 host bounds; invalid or nonpositive rectangles resolve to empty. `rect(in:)` converts a normalized region to points for a decorative SwiftUI frame. Empty or duplicate viewport IDs are ignored, with the first declaration for an ID winning.

The renderer's `resolvedViewports` excludes empty regions and explicit cameras that are missing, removed, inactive, or lack ``SpriteUI/CameraComponent``. A nil camera uses the world's active camera, or the origin when there is none. Declaration order controls overlap: the last viewport is frontmost.

Camera follow, bounds, and shake advance once per frame for all cameras. Follow bounds use the first declared viewport that references that camera and its point size. Reusing one camera in differently sized regions therefore uses the first region's size for follow bounds; use separate camera entities when framing must differ. The world's active camera remains the single primary audio listener. A minimap does not add an independent listener or replay sounds.

## Make overlays deliberately noninteractive

Append a small viewport with a third, zoomed-out camera and `isInteractive: false` for a minimap. It overlays earlier regions and blocks world input underneath its own rectangle. Noninteractive means a tap cannot fall through to an obscured player pane. Outside that rectangle, other player panes retain their own input. Decorative SwiftUI frames should use `.allowsHitTesting(false)` so they do not intercept gestures.

`renderer.viewport(at:interactiveOnly:)` finds the frontmost region. Its default interactive lookup returns nil over a noninteractive overlay, rather than searching the regions beneath it. Gaps also return nil. `GameViewContent.viewport(at:)` exposes the interactive lookup directly. Use these helpers to reject world interaction in gaps or maps before converting coordinates.

## Convert through the viewport that captured input

Targeted taps and gestures expose `EntityTargetValue.viewportID`. Input contacts latch their starting viewport, so crossing a split during a drag continues using that camera's mapping. Manipulation contacts cannot combine across viewports. Layout, camera, and host-mode changes cancel captured input; invalidating a captured camera also ends its usable mapping. Legacy values retain a nil viewport ID.

The explicit conversion helpers return optional results for invalid viewport IDs or cameras. A latched scene conversion can extend outside its original rectangle, allowing a continuous drag across a border. Treat that as gesture continuity, not permission to start an interaction outside a viewport.

```swift
import SpriteUI
import Foundation

@MainActor
func scenePointForNewInteraction(_ point: CGPoint, content: GameViewContent) -> SIMD2<Float>? {
    guard let viewport = content.viewport(at: point) else { return nil }
    return content.scenePoint(fromView: point, inViewport: viewport.id)
}

@MainActor
func projectMarker(_ point: SIMD2<Float>, content: GameViewContent, viewportID: String) -> CGPoint? {
    guard let frame = content.renderer.viewportRect(id: viewportID),
          let projected = content.viewPoint(fromScene: point, inViewport: viewportID),
          frame.contains(projected) else { return nil }
    return projected
}
```

The renderer also offers `scenePoint(fromView:inViewport:)` and `viewPoint(from:relativeTo:inViewport:)`. Their view points are global within the game host, with a top-left origin; scene points use positive y upward. Entity-relative projection accepts local scene coordinates. Projection itself does not clip visibility; clip custom overlays to `viewportRect(id:)`, as in the marker example. Attachment projection handles its own viewport clipping.

When viewports are configured, the legacy `scenePoint(fromView:)` uses the frontmost interactive region and returns zero outside one. Zero is also a valid scene position, so it cannot signal whether a new interaction is allowed. Legacy `viewPoint` projects through the first resolved viewport. Prefer the explicit helpers for new viewport-aware code.

## Project labels everywhere or scope them to one pane

``SpriteUI/AttachmentComponent`` has an optional string `viewportID`. Nil is the default, including when decoding older saved components, and projects into every resolved viewport. A nonnil value limits that anchor to the matching region. ``SpriteUI/AttachmentContext`` identifies the projection's viewport, and attachment identities include it so separate projections have independent SwiftUI state.

This complete view gives one entity an all-viewport name and a P1-only selection label. It uses one set of view-scoped definitions; it does not duplicate the entity for the second camera.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct ViewportLabelsView: View {
    var body: some View {
        GameView(viewports: [
            GameViewport(id: "p1", frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            GameViewport(id: "p2", frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        ]) { content in
            let player = Entity(components: SpriteComponent(color: .cyan, size: [32, 32]))
            player.addChild(Entity(components: AttachmentComponent(id: "name", offset: [0, 28])))
            player.addChild(Entity(components:
                AttachmentComponent(id: "selected", offset: [0, -28], viewportID: "p1")))
            content.add(player)
        } attachments: {
            GameAttachment(id: "name") { Text("Shared player").font(.caption) }
            GameAttachment(id: "selected") { Text("Selected in P1").font(.caption).foregroundStyle(.yellow) }
        }
        .frame(height: 360)
    }
}
```

Each projection is clipped to its viewport. Interactive attachment hit regions apply within their own interactive viewport; projecting into a noninteractive minimap does not grant that map controls or reserve another player's region. Name labels default to noninteractive so entity taps can reach the underlying game surface. Use targeted gesture viewport IDs to keep per-player selection state separate even when both players select the same entity.

## Share a hub and inspect real simulation activity

Use one retained ``SpriteUI/PlayerInputHub`` for the game surface, two independently assigned virtual devices, and each session's controller in that player's movement system. Apply `.gameInput(hub)` once. Hardware joining stays an explicit application policy. Switching viewport layouts cancels native scene input; release or cancel app-owned virtual buttons separately to prevent stale held movement. Also release them when leaving the view or losing app activity.

The seventh tutorial and the demo's Viewports tab show actual world-update, presentation-completion, and contact-began counters. Each counter increments only from its corresponding event subscription; scene time sums actual update deltas. Compare continuity and elapsed simulation when switching layouts. Do not calculate expected updates or contacts from the number of panes, and do not assume a fixed display rate. Contact totals depend on physics and timing. A `RenderingEvents.DidUpdate` event marks presentation completion, not a separate GPU draw for every camera; validating native render passes requires observing the renderer itself.

App inactivity and disappearance pause the native display driver, and resume resets its frame clock to avoid background-time catch-up. Keep entity and camera IDs stable through these transitions. Use <doc:saving-and-debugging> for broader scene inspection.

## Filter artwork per camera

Use <doc:render-layers-and-camera-visibility> to choose world sprites or map icons from one shared hierarchy. Camera masks and optional viewport restrictions intersect; both panes can remain interactive. The eighth tutorial, <doc:presenting-a-world-with-render-layers>, adds visual hiding, continuing physics counters, and selection labels beneath the selected art.

## See also

- <doc:sharing-a-world-between-viewports>
- <doc:sharing-devices-between-players>
- <doc:systems-and-input>
- <doc:rendering-and-resources>
