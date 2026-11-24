# Bounded rendering and read-only presentation

Control render-target quality and publish completed game frames without adding another simulation or input host.

## Opt into one retained Metal host

``SpriteUI/GameView`` accepts `rendering: GameRenderConfiguration? = nil`, `renderMonitor: GameRenderMonitor? = nil`, and `presentation: GamePresentationSource? = nil` after `viewports:` and before the remaining host options, in both initializers. Supplying any of these options selects Metal. That selection lasts for the host's lifetime: changing quality or later passing nil never switches clock drivers. Existing `GameView` calls with all three nil and no viewports keep the legacy SKView path. A nonnil `viewports` array also selects Metal; an empty array uses an automatic full-canvas viewport.

Keep the `GameView` identity stable when updating quality. The main-world backend has one observer; do not attach two `GameView` hosts to the same `World`. Use ``SpriteUI/GamePresentationView`` for additional views of an existing frame. Follow <doc:bounding-rendering-and-sharing-presentation> for three standalone stages.

## Bound the render plan

``SpriteUI/GameRenderConfiguration`` is `Hashable`, `Codable`, and `Sendable`. Its initializer accepts:

| Argument | Default | Meaning |
| --- | --- | --- |
| `resolutionScale` | `1` | Requested fraction of native drawable resolution, clamped to `0.1...1` |
| `preferredFramesPerSecond` | `60` | Requested cadence, clamped to `15...240`; the engine caps stale frame deltas at 1/15 second |
| `maximumRenderPixels` | `16_777_216` | Aggregate pixel budget, clamped to `64...268_435_456`, for the canvas, all pane targets, and three presentation buffers when publishing |
| `maximumTextureDimension` | `8192` | Per-target dimension limit, clamped to `1...16384` |
| `adaptsToSystemPressure` | `false` | Opt into native thermal and low-power caps |

The planner can reduce effective resolution below the requested scale to fit its pixel and dimension limits. Budget the canvas plus every pane target, including overlapping panes, and the source's three-buffer pool. This is a bounded render-plan reservation, not a limit on global GPU memory or a measurement of actual allocations. SpriteKit/Metal SDK caches, drawable storage, other resources, and in-flight buffers can add memory beyond the plan. Nonfinite resolution scales normalize to 1, and decoding applies the same validation as the initializer. Resolution does not resize the scene's logical points, cameras, input coordinates, safe areas, reserved regions, or attachment anchors. SwiftUI attachments stay at native resolution and are excluded from published game pixels.

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

## Resolve pressure deterministically

``SpriteUI/GameRenderEnvironment`` takes `thermalState` (`.nominal`, `.fair`, `.serious`, or `.critical`, default `.nominal`) and `isLowPowerModeEnabled` (default false). `configuration.resolved(in:)` makes the policy independently inspectable. With adaptation enabled, serious pressure caps scale at 0.75 and FPS at 30; critical caps scale at 0.5 and FPS at 20. Low-power mode caps FPS at 30. Combined caps take the stricter value and never raise the requested scale or frame rate. Nominal and fair add no pressure cap. With adaptation disabled, pressure does not alter the request.

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

A constructed environment is a policy fixture. The live host queries native system pressure; it does not infer Duo hardware, folding posture, thermal state, or low-power mode from model names or fixed screen dimensions.

## Observe only the statistics you need

Retain an observable ``SpriteUI/GameRenderMonitor`` and pass it as `renderMonitor:`. Its read-only `latest: GameRenderStatistics?` is nil until statistics are available. Passing nil avoids SwiftUI statistics updates. `monitor.isEnabled = false` retains the latest snapshot while stopping new recordings; `monitor.clear()` discards it. `showsStatistics` remains the separate native overlay option.

| `GameRenderStatistics` field | Meaning |
| --- | --- |
| `logicalSize` | Canvas size in points (`CGSize`) |
| `drawableSize` | Planned drawable size in pixels (`CGSize`) |
| `renderedViewportCount` | Viewports actually rendered |
| `renderPixels` | Aggregate pixels reserved by the bounded render plan |
| `estimatedRenderTargetBytes` | `4 * renderPixels`, an RGBA target reservation estimate, not actual global GPU allocation |
| `effectiveResolutionScale` | Scale after pressure, dimension, and budget limits |
| `preferredFramesPerSecond` | Effective requested cadence, not measured achieved FPS |
| `frameNumber` | Primary rendering frame number |
| `presentationFrameCount` | Published presentation-frame count |
| `droppedPresentationFrames` | Mirror publications skipped when no safe buffer can be reused |

Use actual `WorldEvents.Update` deltas to inspect simulation time. Frame numbers, publication counts, and individual mirror redraws measure different work; none proves a separate world tick.

## Publish one existing pane or the full canvas

Retain an observable ``SpriteUI/GamePresentationSource``. `GamePresentationSource(viewportID: "left")` selects an existing pane by stable ID; `GamePresentationSource()` selects the composed full canvas. `viewportID` is an immutable choice. A source does not create a new camera or render a missing pane. Its read-only `isAvailable`, `pixelSize`, and `frameNumber` describe completed game pixels, independent of any external-display role.

One primary host owns the source's publisher lease. Multiple `GamePresentationView(source:)` consumers can share that source. A second host cannot take its publishing ownership while leased. The source uses a bounded pool of three private GPU buffers and publishes completed frames only. A buffer leased by unfinished GPU work is never overwritten or reused; if none is safe, publishing drops a mirror frame instead of blocking or advancing the world. The monitor exposes those drops.

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

`GamePresentationView` is a noninteractive, aspect-fit, read-only GPU presentation. It creates no `GameHost`, `SKScene`, world, physics session, or simulation clock, and routes no game input. Local mirrors work on iOS 18 and macOS 15. Hiding, detaching, or suspending the primary clears source availability; a mirror cannot keep simulation alive. Resume restarts the primary clock without background-time physics catch-up. There is no automatic secondary macOS window; an app may place a local presentation in its own window.

## Request an external display only where available

On iOS 27 or later, `.gameExternalDisplay(source, isEnabled: true, onAvailabilityChange:)` wraps `SwiftUI.ExternalNonInteractiveAccessory(isEnabled: .constant(isEnabled))`. The default `isEnabled` is true. The callback is `@MainActor (Bool) -> Void` and reports actual OS accessory availability. It is separate from `source.isAvailable`: a completed game frame does not prove an external role exists, and an available external role does not prove the primary has a completed frame.

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

This helper requests the general noninteractive external-display role. It does not grant Duo's outer camera-display role. `CameraCaptureAccessory` on Duo requires the full inner display and an active camera, and belongs only in camera apps. SpriteUI creates no camera capability and requests no camera permission for game presentation. Surface reservations and hinge input remain separate; see <doc:adaptive-game-surfaces> and <doc:hinge-input-and-effects>.

## Native verification checklist

The SVGs are schematic expected results. Record device, OS, observed values, and result for each check; source review and policy fixtures do not verify hardware behavior.

- On native Duo hardware, exercise Book and Tabletop postures, outer-display transitions, and rotation. Observe reported point geometry and source availability without inferring a general outer-display role. In a game app, do not activate a camera to force that role.
- Change quality and FPS while touching or manipulating an entity. Check point-space targeting, camera framing, and native-resolution attachments; quality changes must preserve the retained Metal clock driver.
- Add, remove, and resize local mirror consumers. Compare actual world-update deltas, simulation elapsed time, and physics contact progression at the same primary cadence. Mirror count must not multiply the world clock or route input.
- Hide or suspend the primary and verify that source availability clears. Resume and verify that elapsed time and physics do not catch up for the hidden interval. Check that quality and camera identity survive.
- Exercise pane and full-canvas sources, missing-pane unavailability, exclusive publisher ownership, pressure caps, tight budgets, and repeated resize. Observe bounded plan statistics and safe dropped mirror frames without treating them as measured global GPU allocation.
- Test the iOS 27 external accessory only when the OS reports it available. Check enable/disable, disconnect/reconnect, aspect fit, and independence from source availability. If no external role is available, explicitly record **external-display presentation unverified**; a working local mirror is not external-display evidence.

## See also

- <doc:bounding-rendering-and-sharing-presentation>
- <doc:viewports-and-split-screen>
- <doc:rendering-and-resources>
