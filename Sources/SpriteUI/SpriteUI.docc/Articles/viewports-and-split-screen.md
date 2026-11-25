# Show two players' cameras in one game view

Two players can share a level while looking at different parts of it. Each needs a camera, but the ball between them should still bounce once and the game clock should still advance once.

A viewport is a rectangle that shows the world through a camera. Give one ``SpriteUI/GameView`` several viewports to draw the same world in different regions. Physics, actions, camera following, and audio update once per display frame, then each camera draws its view.

## Put two cameras side by side

Create camera entities once and retain them. Each ``SpriteUI/GameViewport`` names a camera by entity ID and gives its region a stable string ID.

This example shows one beacon through two cameras placed on either side of it. Both panes observe the same entity rather than copies of it.

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

Viewport frames use fractions of the host's size with a top-left origin. The left pane starts at x 0 and takes half the width; the right starts at x 0.5. Y increases downward here, unlike world coordinates where positive y points up. Use `.full` for the entire surface.

Changing the array on the same `GameView` changes the layout without recreating players or cameras. Removing a pane does not remove its camera from the world. Empty or invalid regions are omitted, and duplicate IDs keep their first declaration. A pane naming a missing or inactive camera is also omitted. A nil camera uses the active camera, or the origin if there is none.

## Add a minimap above the player views

Append a small viewport using a zoomed-out camera. Later declarations draw in front of earlier ones, so the map can overlap a player view.

Set `isInteractive: false` when the map is only for looking. Its rectangle blocks world input beneath it; taps do not pass through to the obscured player view. Decorative SwiftUI borders should use `.allowsHitTesting(false)` so they do not intercept gestures themselves.

Use `content.viewport(at:)` to find the frontmost interactive pane at a view point. It returns nil in gaps and over a noninteractive map. Viewports do not assign devices to players; use <doc:player-input-sessions-and-feedback> for that.

## Use the camera where a gesture began

A tap or drag's ``SpriteUI/EntityTargetValue`` supplies `viewportID`. A drag keeps its starting pane even if the finger crosses the split, so its coordinate mapping does not jump to the other camera. Contacts from different panes cannot combine into one manipulation.

For a new interaction, find its pane before converting the point. For a marker, project through the intended camera and check that the result falls inside its pane.

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

These view points are relative to the whole game host, with y increasing downward. Scene points use y upward. The conversion helpers return nil for invalid pane IDs or cameras. Projection alone does not clip a custom overlay; the marker helper checks the pane rectangle for that reason.

Once a drag has captured a pane, conversions may extend outside its rectangle to keep the drag continuous. That does not make the outside area a place to begin another interaction. Layout and camera changes cancel captured input rather than continuing with a changed mapping.

Prefer the helpers that take a viewport ID. The older `scenePoint(fromView:)` returns zero outside interactive regions, but zero is also a real scene position. The older `viewPoint` uses the first resolved pane.

## Show a name in both panes and a selection in one

A world label often belongs in every view, while a selection belongs only to the player who tapped it. Set `AttachmentComponent.viewportID` for a pane-specific label; leave it nil to project the same anchor into every eligible pane.

This view gives the shared player a name in both panes and a selection label only in P1.

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

Each projection is clipped to its own pane and has separate SwiftUI state. `AttachmentContext` identifies the pane for the attachment builder. Interactive attachments work only inside interactive panes; a label cannot turn a noninteractive minimap into a control surface. Name labels default to noninteractive, allowing taps to reach the game beneath them.

Keep selection state associated with the gesture's pane ID. Two players may select the same entity without needing duplicate game entities.

## Change layouts while keeping the game

Retain the `GameView`, cameras, players, and input hub when switching between one and two panes. Apply `.gameInput(hub)` once and use each player's controller in their movement rule. Release app-owned virtual buttons when changing layout, losing app activity, or leaving the view; the native host cancels its own captured input.

Camera follow and shake update once per frame for all cameras. If the same camera appears in several differently sized panes, its first pane determines the size used for follow bounds. Use separate cameras when framing needs to differ. The active world camera remains the one primary audio listener.

Each pane adds drawing work and an offscreen texture, even though it adds no simulation. Passing a viewport array selects the Metal host; an empty array selects one full-size automatic-camera pane. See <doc:bounded-rendering-and-read-only-presentation> for quality controls and mirrors that reuse completed pixels. Host suspension pauses the display driver and avoids catching up background time on return.

Continue with [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-viewports-03.swift) for a complete split-screen scene. To show detailed sprites in one pane and map icons in another, read <doc:render-layers-and-camera-visibility>.

## See also

- <doc:parallax-and-repeating-backgrounds>
- <doc:player-input-sessions-and-feedback>
- <doc:systems-and-input>
- <doc:rendering-and-resources>
- <doc:saving-and-debugging>
