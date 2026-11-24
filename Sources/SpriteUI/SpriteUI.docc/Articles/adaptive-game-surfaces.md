# Adaptive game surfaces

Fit cameras and controls around the safe area and reported reserved regions while retaining one world and its players.

## Read the host's geometry

``SpriteUI/GameSurfaceGeometry`` describes one ``SpriteUI/GameView`` in local points, with its origin at the top left, x increasing rightward, and y increasing downward. These coordinates differ from the world's positive-y-up coordinates. `displayScale` describes pixels per point; do not multiply surface frames by it when laying out SwiftUI content.

The initializer takes `size: CGSize`, `displayScale: CGFloat = 1`, `safeAreaInsets: GameSurfaceGeometry.Insets = .init()`, and `reservedRegions: [GameSurfaceGeometry.ReservedRegion] = []`. Nested `Insets(top:left:bottom:right:)` defaults each edge to zero. Each nested `ReservedRegion(id:kind:frame:isActive:)` has a string ID, an `.occlusion` or `.division` kind, a local `CGRect`, and `isActive` defaulting to true. A division reserves space just as an occlusion does; it does not imply an input device or a particular hardware model.

| Geometry | Meaning |
| --- | --- |
| `bounds` | The full surface rectangle |
| `safeBounds` | Bounds inset by the safe area; reserved regions may still cross it |
| `usableRegions(includingInactive: false)` | Rectangles remaining after subtracting active reserved frames from the safe area, in deterministic top-left order |
| `largestUsableRegion` | The largest remaining rectangle, or an empty rectangle when none remains |
| `rect(for:)` | The rectangle selected by a `GameSurfaceRegion` |
| `placement(of:anchor:includingInactive:)` | A fully fitting control rectangle, or nil when no usable rectangle can contain its entire size |

Inactive regions remain in `reservedRegions` with `isActive == false`. They do not reduce the default usable area. Pass `includingInactive: true` to usable-region or placement queries when you deliberately want to plan around them too. Usable indices describe the current geometry, not persistent physical panels; their deterministic order does not make an index a hardware identity.

This complete value example creates a book-like division without requiring a particular device:

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

The placement anchor is a normalized `SIMD2<Double>`, defaulting to `[0.5, 0.5]`; `[0, 0]` requests the top left and `[1, 1]` the bottom right. Placement selects a fitting location near that preference. It never shrinks a control or returns a partly fitting rectangle. Handle nil by hiding, simplifying, or moving controls outside the game surface. An empty surface can arrive before native layout completes.

## Observe one surface at a time

Apply `.onGameSurfaceChange` directly to the `GameView` whose geometry you need, before combining multiple hosts in a container. The callback reports that host's local geometry, including an initial empty value when layout has not completed. It does not aggregate several surfaces into a global coordinate system.

Read `content.surfaceGeometry` in `GameView`'s `update:` closure to observe geometry while updating existing entities. This is a SwiftUI-driven update, not a frame simulation callback. An attachment descendant can read `@Environment(\.gameSurfaceGeometry)` for the same live geometry. This environment value is supplied inside the host's attachment subtree; a parent, sibling, or ordinary external overlay must use the callback instead.

For world-owned observers, retain the subscription returned by `content.subscribe(to: GameSurfaceEvents.DidChange.self)`. ``SpriteUI/GameSurfaceEvents`` delivers `DidChange(scene:previous:geometry:)`: the presented world, previous geometry, and new geometry. The host publishes its coherent new geometry and cancels affected captures before event delivery. The first previous value may describe an empty surface. Do not infer which host changed from a device model or global screen size.

## Resolve camera frames inside a region

``SpriteUI/GameSurfaceRegion`` supports `.surface`, `.safeArea`, `.largestUsable`, and `.usable(Int)`. Pass a selector as ``SpriteUI/GameViewport``'s `region` argument. It defaults to `.surface`, preserving existing viewport behavior. The viewport's existing normalized `frame` resolves *within that selected rectangle*. `.safeArea` removes edge insets but does not subtract reserved frames; choose a usable selector when the camera must avoid them.

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

For two panes, use `.usable(0)` and `.usable(1)` with stable viewport IDs and camera entity IDs. An unavailable usable index resolves to an empty rectangle; its viewport disappears instead of falling back underneath a reserved region. Keep camera entities and players in the same world when a pane disappears. Do not key the whole `GameView` by geometry or rebuild cameras inside `body`.

Camera following and bounds clamping use the first assigned viewport's resolved point dimensions for that camera. If one camera appears in differently sized viewports, the first assignment determines its clamp size. Use separate stable cameras when panes need independent framing. See <doc:viewports-and-split-screen> for overlap, projection, and the shared simulation clock.

## Place HUDs and clip world labels

Use `placement(of:anchor:includingInactive:)` for floating HUDs. Give the control its requested size and position it at the returned rectangle's midpoint in an overlay matching the host's local bounds. A full fitting rectangle is required even if the requested anchor lies beside a division.

``SpriteUI/AttachmentComponent`` defaults `avoidsReservedRegions` to true. Attachments are clipped to `safeBounds` and clipped out of active reserved frames, in addition to their existing viewport clipping. This clips a label at its projected world anchor; it does not relocate the entity, shift its anchor, or move the entire label into a usable region. Set `avoidsReservedRegions: false` to opt out of this surface avoidance while retaining normal viewport clipping. A world label that must stay fully visible needs an app layout policy; use surface placement for an independent floating HUD.

## Release virtual controls when layout changes

An effective layout change—different `size`, `safeBounds`, or active `usableRegions()`—cancels captured pointer/touch input, manipulation sessions, and other native-routed input actions while preserving native `.hinge` input. Coordinate-space-only changes do not cancel or rearm the hinge, which is independent of pointer geometry; a simultaneous focus, scope, transition, or manual cancellation still requires physical neutral before hinge input resumes. Player sessions and device ownership survive. Attachment contexts are invalidated only for an actual layout change. Changes only to display scale or inactive-region metadata still publish geometry events without cancelling input or invalidating those contexts. A metadata change that leaves the effective layout unchanged does not require a release.

App-owned virtual controls must submit their own releases through the surface callback. Compare the previous and next `size`, `safeBounds`, and `usableRegions()`, release any held virtual samples on a difference, then store the new value. Comparing the entire geometry would also release on scale-only or inactive-metadata changes. Release on disappearance and loss of app activity too. Retain the same hub and sessions; reconnecting devices or replacing players is unnecessary. <doc:adapting-to-game-surfaces> implements this policy in a complete staged example.

DemoBots keeps its existing `main` viewport in `.largestUsable` and places HUD, menus, and whole virtual sticks within usable rectangles. Its **Display & performance** panel is available on home and pause; opening it immediately disables the existing `PlayerInputSession`, cancelling held gameplay input and gating late virtual-control samples. Closing it preserves the same home or paused phase and existing world pause state. Preset changes and optional read-only presentation retain the world, player, camera, input sessions, and rendering clock; render resolution does not change point-space layout. See <doc:bounded-rendering-and-read-only-presentation> for presets and presentation limits.

Library-level regression coverage uses simulated geometry changes during asynchronous level preparation, cancellation, and fades to assert retained entity IDs, player input sessions, and the shared clock. These fixtures do not verify native folding. For QA in the Duo simulator (and repeat on hardware before release), start open, hold movement/fire through Book and Tabletop changes and outer-display transitions, and check release/rearm behavior without an unintended phase or pause change. Switch display presets while paused, then restore a checkpoint after folding and check that Resume is still required. Record observations; simulator QA remains planned until main integration verifies it, and no physical-hardware session is claimed.

## Use reported regions and explicit previews

On UIKit with iOS 27.1, the native query includes inactive reserved regions and preserves each region's `isActive` value. It runs on native frames as well as layout passes, so activity changes are observed even without a bounds resize. On older supported iOS versions, including iOS 18, and on macOS, native adaptation uses bounds and safe-area insets without reserved-region reporting. Folds are represented only through the regions the host reports. Optional live hinge data and explicitly configured hinge actions are available separately; see <doc:hinge-input-and-effects>. Surface regions remain the layout source. Read-only local mirrors and the optional iOS 27 noninteractive external accessory are supported; see <doc:bounded-rendering-and-read-only-presentation>. That general external role does not grant Duo outer-display camera hosting, which requires the full inner display and an active camera in a camera app. Render resolution leaves this point geometry and native-resolution SwiftUI attachments unchanged. Do not infer folds from an Apple device name, screen-size table, or hypothetical hardware check.

`GameView(surfaceRegions:)` provides an explicit override for deterministic previews and demos. Nil uses native reporting; a nonnil array replaces the native reserved-region list rather than adding to it. An empty array explicitly suppresses native reserved regions. The override does not replace the actual host size, display scale, or safe-area insets. Construct synthetic frames in the host's own points, and restore nil for native behavior. Such fixtures demonstrate layout policy, not hardware detection.
