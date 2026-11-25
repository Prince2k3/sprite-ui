# Keep the game and its controls in usable screen space

A fire button can fit beside the game in one window and land under a reserved part of the display after a resize or fold. The camera may need a different rectangle too. Adjust those placements while keeping the current world, players, and cameras alive.

``SpriteUI/GameSurfaceGeometry`` describes the host's size, safe-area insets, and reported reserved regions. Use it to choose where the game draws and where a whole control can fit.

These layout features work on devices without hinges too. Measuring a fold angle or using folding as a game control is separate: native hinge input requires a physical hinge with an OS-supported sensor. See <doc:hinge-input-and-effects> for hardware requirements and controls for other devices.

## Find room for a whole control

Surface geometry uses local points with a top-left origin: x goes right and y goes down. World coordinates use y upward. `displayScale` describes pixels per point; do not multiply the geometry by it for SwiftUI layout.

Start with `safeBounds` to avoid edge insets. Use `usableRegions()` to subtract active reserved rectangles as well. A reserved region can describe an occlusion or a division; both reserve space. `largestUsableRegion` gives the largest remaining rectangle.

This example describes a surface with a narrow center division and asks for a 120-by-44-point control near the bottom right.

```swift
import SpriteUI
import Foundation

func exampleSurface() -> GameSurfaceGeometry {
    GameSurfaceGeometry(
        size: CGSize(width: 600, height: 360),
        displayScale: 2,
        safeAreaInsets: .init(top: 12, left: 8, bottom: 12, right: 8),
        reservedRegions: [
            .init(id: "demo-spine", kind: .division,
                  frame: CGRect(x: 290, y: 0, width: 20, height: 360)),
            .init(id: "inactive-overlay", kind: .occlusion,
                  frame: CGRect(x: 8, y: 12, width: 80, height: 40), isActive: false)
        ]
    )
}

func controlFrame(in geometry: GameSurfaceGeometry) -> CGRect? {
    geometry.placement(of: CGSize(width: 120, height: 44), anchor: [1, 1])
}
```

`placement(of:anchor:)` returns a rectangle that fits the entire requested control, or nil if none fits. It chooses a location near the normalized anchor: `[0, 0]` is top left and `[1, 1]` is bottom right. Position the control at the returned rectangle's midpoint in an overlay matching the game host's bounds.

If placement returns nil, simplify or hide the control, or move it outside the game surface. Placement does not shrink it. Geometry can also be empty before native layout finishes.

Inactive reserved regions remain available as metadata but do not remove usable space by default. Pass `includingInactive: true` when planning around them is intentional.

## Keep the camera inside an available region

Give a ``SpriteUI/GameViewport`` a `region` selector. `.surface` uses the full host, `.safeArea` removes edge insets, and `.largestUsable` avoids both insets and active reserved regions. The viewport's normalized `frame` is then resolved inside that rectangle.

This view keeps its camera in the largest usable area.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct AdaptiveArena: View {
    var body: some View {
        GameView(viewports: [
            GameViewport(id: "play", region: .largestUsable)
        ]) { content in
            content.add(Entity(components: SpriteComponent(color: .cyan, size: [32, 32])))
        }
        .frame(height: 320)
    }
}
```

For two panes, use `.usable(0)` and `.usable(1)` with stable viewport and camera IDs. An unavailable index makes its pane disappear rather than drawing under a reserved area. Those indices describe the current geometry, not permanent physical panel identities.

Retain cameras and players even when their panes disappear. Recreating cameras in `body`, or giving the entire game view a new identity for each geometry, would discard state that a layout change should preserve. Separate cameras allow independent framing; when one camera is reused, its first viewport determines follow-bound dimensions. See <doc:viewports-and-split-screen> for the rest of the camera layout.

## Respond to the surface that changed

Apply `.onGameSurfaceChange` directly to the `GameView` you are laying out. Store the reported value for ordinary SwiftUI overlays. The callback describes that host only, and can initially report empty geometry.

Inside a game view's `update:` closure, read `content.surfaceGeometry` when adjusting existing entities. That closure follows SwiftUI updates rather than simulation frames. Attachment descendants can read `@Environment(\.gameSurfaceGeometry)`; the environment is supplied within the attachment subtree, so external overlays use the callback instead.

For scene-owned logic, retain a subscription to ``SpriteUI/GameSurfaceEvents``' `DidChange` event. It supplies the scene, previous geometry, and new geometry after the host has applied the layout and cancelled affected captures.

## Choose whether a label should clip or move

Floating HUD controls can use `placement` to stay fully visible. A world label has a different job: it stays at its projected entity anchor.

By default, ``SpriteUI/AttachmentComponent`` clips labels to safe bounds, away from active reserved regions, and within their viewport. This can cut off a label; it does not move the anchor or relocate the whole label. Use an independent HUD if it must always fit. Setting `avoidsReservedRegions: false` skips surface avoidance while keeping viewport clipping.

## Release held virtual controls after a layout change

When the size, safe bounds, or active usable regions change, the native host cancels affected touch and pointer captures, manipulation, and other routed actions. Player sessions and device ownership survive.

Your app still owns its virtual controls. In the surface callback, compare the previous and new `size`, `safeBounds`, and `usableRegions()`. On a difference, submit neutral values for held virtual controls before storing the new geometry. Also release them on disappearance and app inactivity. A scale-only change or inactive-region metadata change does not require this release.

Coordinate changes preserve native hinge input because it does not depend on pointer positions. A simultaneous focus loss, input-blocking transition, or manual cancellation still applies the hinge's neutral requirement. [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-surfaces-03.swift) shows the geometry comparison and virtual-control release in a complete scene.

## Try alternate layouts and use native reports

Use `GameView(surfaceRegions:)` for previews. Nil uses native reporting; an array replaces the reserved-region list, and an empty array suppresses it. Define frames in the actual host's points. The override leaves host size, scale, and safe-area insets alone, so restore nil when returning to native behavior.

On UIKit with iOS 27.1, native reporting includes active and inactive reserved regions and notices activity changes without a resize. Older supported iOS versions and macOS use bounds and safe-area insets without native reserved-region reporting. A preview division demonstrates a layout; it does not detect hardware or prove a hinge sensor exists. Use reported geometry rather than device names or screen-size tables.

Continue with <doc:hinge-input-and-effects> if folding should also affect gameplay. For drawing quality and optional mirrors, read <doc:bounded-rendering-and-read-only-presentation>; changing pixel resolution leaves this point-space layout unchanged.
