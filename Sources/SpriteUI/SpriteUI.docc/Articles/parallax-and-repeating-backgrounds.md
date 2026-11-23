# Parallax and repeating backgrounds

Move decorative sprite artwork relative to each camera while preserving the shared world's model-space anchors.

## Overview

Use ``SpriteUI/ParallaxComponent`` for depth and ``SpriteUI/RepeatingBackgroundComponent`` for continuous backgrounds. Each affects only its entity's own ``SpriteUI/SpriteComponent`` drawing. They work separately or together. Children, entity transforms, physics bodies, camera nodes, audio, and attachment anchors retain their ordinary world-space behavior. Follow <doc:building-a-parallax-landscape> for three complete `ContentView.swift` replacements with procedural images and no external assets.

## Choose a scroll factor

The artwork's scene-space offset is `(cameraPosition - referencePosition) * (1 - scrollFactor)`, independently on x and y. A factor of one gives ordinary world scrolling. Zero follows camera translation, and values between zero and one give slower apparent motion. Finite negative factors and factors above one are supported. Disabled parallax or invalid, nonfinite offset results produce zero displacement. The default factor is `[0.5, 0.5]` and the reference position defaults to zero.

This complete helper creates a mountain layer that scrolls horizontally at 45% of normal world speed. Its vertical factor stays one so its height remains tied to the ground. Supply a seamless image made in code or loaded through your resource library.

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

The selected camera's presented position includes shake. Zoom and rotation behave normally: factor zero locks translation, and does not cancel zoom or rotation. Use ordinary SwiftUI overlays for a screen-fixed interface.

## Repeat artwork with a bounded budget

Choose `.horizontal`, `.vertical`, or `.both` on `RepeatingBackgroundComponent.axes`; the default is `.both`. The tile period is the sprite's presented size, so the texture's opposite edges should join along each repeating axis. Nonrepeating axes retain a single sprite extent. Empty axes or disabling repetition restores one sprite; any enabled parallax still applies.

The renderer covers the selected camera's visible region after zoom, rotation, and the entity's inverse transform. It wraps tile phase near the camera, including at negative and large coordinates. Tiles reuse the source sprite's texture, material, tint, and opacity. They are pooled drawings, without duplicate entities or physics bodies.

`maximumTileCount` defaults to 1,024 per camera, with a hard ceiling of 16,384. A required tile count above the budget omits that background's artwork instead of drawing partial coverage. Invalid, zero, or nonfinite sprite geometry also omits repeated artwork. Prefer larger tiles over a large budget for wide or zoomed-out views. Disabling repetition returns the ordinary single sprite.

## Keep interaction and labels in model space

An owner with enabled parallax or active repetition is decorative and excluded from presentation picking. Give interactive content its own ordinary child entity or sibling. A child's sprite does not inherit its parent's background shift or tile repetition, and can retain ordinary input targeting.

``SpriteUI/AttachmentComponent`` stays at its model-space anchor. It does not follow shifted artwork and is not duplicated for each tile. In split screen, its default nil `viewportID` still projects the same anchor through every viewport. See <doc:viewports-and-split-screen> for scoped labels and <doc:render-layers-and-camera-visibility> for visibility gates and camera masks, which continue to apply.

Both background components support Codable snapshots and cloning through the component registry. Saving or querying an entity observes its model transform, rather than a camera-specific drawing offset.

## Share one landscape between cameras

Retain two camera entities and supply their IDs to one `GameView(viewports:)`. Each pass computes its own background offsets and tile coverage. Changing one camera's position or zoom does not change the other camera or advance simulation again. A single viewport can use the same world and camera IDs when split mode is turned off.

The demo's Parallax tab uses deterministic RGBA images for stars, mountains, and ground. Choose a layer, change its factor, and move or zoom either camera independently. Disable Repeat to expose the original finite artwork; restore it to fill the view again. Split switches between one and two camera regions without recreating the landscape.

The cyan child and Model anchor label remain at the mountain entity's model origin while its artwork shifts. A readout compares the three landscape entities and two children with their original local positions after each presentation callback. It should show zero of five anchors changed. Update and frame counters count real events from the one shared world; frame completion is not a GPU-pass count. This demonstrates anchor stability and does not replace renderer or physics tests.

## See also

- <doc:building-a-parallax-landscape>
- <doc:viewports-and-split-screen>
- <doc:render-layers-and-camera-visibility>
- <doc:rendering-and-resources>
