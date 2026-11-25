# Adjust drawing quality and show a second copy of the game

A game might need a lower-resolution battery-saving mode and a small spectator preview beside its main view. Changing quality should keep the match in progress. The preview should show the match rather than start another simulation.

Use ``SpriteUI/GameRenderConfiguration`` to request drawing quality and ``SpriteUI/GamePresentationSource`` to share finished game pixels. A ``SpriteUI/GamePresentationView`` displays those pixels without taking input or running a world.

## Lower resolution without moving controls

Resolution scale changes how many pixels draw the game, not the logical size of its scene. Cameras, touch coordinates, safe areas, and attachment anchors stay in points. SwiftUI attachments retain native resolution.

This view requests 75% resolution and 30 frames per second. It also limits the render targets and allows lower settings under system pressure.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct BoundedArena: View {
    var body: some View {
        GameView(rendering: GameRenderConfiguration(
            resolutionScale: 0.75,
            preferredFramesPerSecond: 30,
            maximumRenderPixels: 4_000_000,
            maximumTextureDimension: 2048,
            adaptsToSystemPressure: true
        )) { content in
            content.add(Entity(components: SpriteComponent(color: .cyan, size: [40, 40])))
        }
        .frame(height: 300)
    }
}
```

`resolutionScale` defaults to 1 and accepts 0.1 through 1. `preferredFramesPerSecond` defaults to 60 and requests 15 through 240; the device determines the achieved rate. A lower drawing rate does not configure fixed simulation; see <doc:fixed-step-simulation-and-interpolation> for that.

`maximumRenderPixels` budgets the canvas, every pane target, and three presentation buffers when publishing. `maximumTextureDimension` limits each target's width and height. The planner can reduce resolution below the requested scale to fit both limits. Larger or overlapping viewports still consume target pixels.

Keep the `GameView` identity stable when changing settings. Rendering options select a Metal host for its lifetime, so quality changes keep the world and its clock. A plain view with no viewport, rendering, monitor, or presentation options keeps the SKView path.

## Let a warm device ask for less work

Set `adaptsToSystemPressure` to true to use the host's thermal and low-power information. Serious thermal pressure caps scale at 0.75 and cadence at 30 FPS; critical pressure caps them at 0.5 and 20 FPS. Low-power mode caps cadence at 30 FPS. Combined limits use the stricter request and never raise your chosen settings.

You can inspect that policy without heating a device. This helper asks how the configuration resolves under serious pressure.

```swift
import SpriteUI

func seriousPressureExample() -> GameRenderConfiguration {
    let requested = GameRenderConfiguration(
        resolutionScale: 1, preferredFramesPerSecond: 60,
        adaptsToSystemPressure: true
    )
    return requested.resolved(in: GameRenderEnvironment(
        thermalState: .serious, isLowPowerModeEnabled: false
    )) // 0.75 scale and 30 FPS, before render-plan limits.
}
```

The live host reads system pressure. A constructed ``SpriteUI/GameRenderEnvironment`` is useful for trying the policy; it is not a measurement of a device.

## Inspect the quality being used

Retain a ``SpriteUI/GameRenderMonitor`` and pass it to `renderMonitor:` when a settings screen needs statistics. Its `latest` value starts nil. `effectiveResolutionScale` and `drawableSize` show the result after limits; `logicalSize` remains the point size of the game.

`renderPixels` reports the planned target pixels, and `estimatedRenderTargetBytes` estimates their RGBA storage. `preferredFramesPerSecond` is the effective request rather than a measured frame rate. `renderedViewportCount`, frame numbers, and publication counts describe drawing work; use `WorldEvents.Update` deltas to inspect simulation time.

Pass nil when no screen needs monitor updates. Disabling a monitor retains its last snapshot; `clear()` removes it.

## Display finished frames in another view

Retain a presentation source and pass it to the main game view. Other views can then show that source. This example puts a smaller copy below the live game.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct LocalPresentation: View {
    @State private var source = GamePresentationSource()
    @State private var monitor = GameRenderMonitor()

    var body: some View {
        VStack {
            GameView(renderMonitor: monitor, presentation: source) { content in
                content.add(Entity(components: SpriteComponent(color: .orange, size: [40, 40])))
            }
            .frame(height: 260)
            GamePresentationView(source: source)
                .frame(height: 130)
            Text(source.isAvailable ? "Completed frame available" : "Waiting for the primary host")
        }
    }
}
```

`GamePresentationSource()` shares the composed canvas. Use `GamePresentationSource(viewportID: "left")` to share an existing pane instead. The choice is fixed for that source; it does not create a camera or draw a missing pane. `isAvailable`, `pixelSize`, and `frameNumber` describe its completed pixels.

A presentation view fits those pixels within its frame, keeps their aspect ratio, and accepts no game input. Several consumers can share one source. Attach only one primary game host to the world; additional game hosts are not a substitute for mirrors.

The source uses three GPU buffers. A buffer still in use is not overwritten. If none can be reused safely, the host skips a publication instead of blocking or advancing simulation. The monitor's `droppedPresentationFrames` reports these skips.

## Offer an optional external display

On supported iOS versions, `.gameExternalDisplay` requests the operating system's noninteractive external-display role. The example below keeps a local preview and reports whether the OS offers that role.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct OptionalExternalPresentation: View {
    @State private var source = GamePresentationSource()
    @State private var externalAvailable = false

    private var arena: some View {
        GameView(presentation: source) { content in
            content.add(Entity(components: SpriteComponent(color: .mint, size: [40, 40])))
        }
        .frame(height: 260)
    }

    var body: some View {
        VStack {
#if os(iOS) && !targetEnvironment(macCatalyst)
            if #available(iOS 27.0, *) {
                arena.gameExternalDisplay(source, isEnabled: true) {
                    externalAvailable = $0
                }
                Text(externalAvailable ? "OS external role available" : "OS external role unavailable")
            } else {
                arena
                Text("External accessory requires iOS 27")
            }
#else
            arena
            Text("Local presentation on macOS")
#endif
            GamePresentationView(source: source).frame(height: 130)
        }
    }
}
```

Treat external availability and source availability separately. A finished local frame does not mean an external role is available, and an available role still needs a completed source frame. Your game should continue locally when the role is unavailable.

## Limits to keep in mind

The pixel budget limits the render plan, not all GPU memory. SDK caches, drawable storage, other resources, and in-flight work can add memory beyond the estimate. Frame rate is a request, and the renderer caps stale frame deltas at 1/15 second.

Published frames contain game pixels, excluding SwiftUI attachments, HUDs, and menus. A mirror cannot keep a hidden or suspended primary running; source availability clears when the primary stops. Local presentation supports iOS 18 and macOS 15, and does not automatically create another macOS window.

The external helper requires iOS 27 and requests the general noninteractive accessory role. It does not grant Duo's outer camera-display role, which requires the full inner display and an active camera in a camera app. Game presentation requests no camera capability or permission. Use <doc:adaptive-game-surfaces> for layout and <doc:hinge-input-and-effects> for optional hinge input.

Continue with [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-rendering-03.swift) to build quality controls and a shared preview. For another camera angle rather than a copy of finished pixels, use <doc:viewports-and-split-screen>.

## See also

- <doc:rendering-and-resources>
