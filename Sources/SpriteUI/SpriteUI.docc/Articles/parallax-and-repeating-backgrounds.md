# Make distant scenery scroll slowly and repeat

As the player runs, nearby ground should sweep past while distant mountains move more slowly. A long level also needs scenery that continues beyond a single image.

``SpriteUI/ParallaxComponent`` changes how fast a sprite's artwork appears to move with the camera. ``SpriteUI/RepeatingBackgroundComponent`` tiles that artwork to fill the view. Add either one, or combine them, without moving the entity's stored position.

## Build a slow-moving mountain layer

This helper makes a mountain image scroll horizontally at 45% of normal world speed and repeat across the camera view. Its vertical factor remains 1, so the mountain height stays tied to the ground. Supply an image whose left and right edges join cleanly.

```swift
import SpriteUI

@MainActor
func mountainBackground(image: SpriteImage) -> Entity {
    Entity(name: "Mountains", components:
        SpriteComponent(image: image, size: [256, 256]),
        ParallaxComponent(scrollFactor: [0.45, 1], referencePosition: .zero),
        RepeatingBackgroundComponent(axes: .horizontal, maximumTileCount: 256))
}
```

A scroll factor of 1 gives normal world scrolling. A factor of 0 follows camera translation, making the artwork appear stationary as the camera moves. Values between them suggest distance. Choose x and y factors separately; the default is `[0.5, 0.5]`.

The camera-relative offset is `(cameraPosition - referencePosition) * (1 - scrollFactor)`. `referencePosition` defaults to zero. Finite negative factors and factors above 1 are also supported if you want reversed or faster apparent movement. Camera shake contributes to this position.

Parallax changes translation only. Zoom and rotation still affect the artwork. Use a SwiftUI overlay for an interface that must stay fixed on the screen.

## Repeat a seamless image across the view

Choose `.horizontal`, `.vertical`, or `.both` for the repeating axes. A tile's period is the sprite's presented size, so image edges must match along each repeating axis. An axis that does not repeat retains the single sprite's extent.

The renderer covers the camera's visible region after zoom, rotation, and the entity transform. It wraps the pattern near that camera, including at negative and large coordinates. Tiles share the source texture, material, tint, and opacity; they are drawings rather than duplicate entities or physics bodies.

Turn repetition off to reveal the original finite sprite. Parallax can remain on, so you can inspect the image's movement separately from tiling.

## Keep gameplay objects separate from decorative artwork

Both effects apply only to the owner's own ``SpriteUI/SpriteComponent``. They do not shift its children, physics body, audio, attachment anchors, or stored transform. A child sprite remains at its ordinary world position even while the parent's mountain artwork scrolls elsewhere.

An owner with enabled parallax or active repetition is excluded from presentation picking. Give interactive scenery its own ordinary child or sibling. A world label attached to the background stays at the model anchor and is not copied onto every tile; for a label that follows a game object, attach it to that object instead.

Saving, cloning, and model queries also see the stored transform. Both background components support Codable snapshots through the component registry. Camera layers and visibility still apply; see <doc:render-layers-and-camera-visibility>.

## Let each camera see its own depth

In split screen, each camera computes its own parallax offset and tile coverage. Moving or zooming one camera changes that pane's scenery without moving the other camera or running simulation again. Keep both cameras and the landscape in one world and pass their IDs to `GameView(viewports:)`.

Attachment anchors still project from the same model position. Scope labels to a pane when needed, as described in <doc:viewports-and-split-screen>.

## Limits to keep in mind

`maximumTileCount` defaults to 1,024 per camera, with a ceiling of 16,384. If filling a view requires more than the budget, that background's artwork is omitted rather than partially covered. Prefer larger tiles when a wide or zoomed-out view needs too many. Invalid, zero, or nonfinite geometry also omits repeated artwork; invalid parallax offsets use zero displacement.

Continue with [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-parallax-03.swift) to build stars, mountains, and ground from procedural images and compare them through two cameras.

## See also

- <doc:rendering-and-resources>
