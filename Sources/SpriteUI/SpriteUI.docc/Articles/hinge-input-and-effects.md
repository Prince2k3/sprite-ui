# Hinge input and effects

Observe an optional live hinge for visual effects, or explicitly opt into a calibrated action with portable controls for every player.

## Read optional sensor data

``SpriteUI/GameHingeState`` is an ECSCore value conforming to `Hashable`, `Codable`, and `Sendable`. Its failable `init?(angle:status:)` takes a `Double` angle in radians and a status of `.unknown`, `.closed`, `.partiallyOpen`, or `.fullyOpen`. Nonfinite angles produce nil; finite angles clamp to `0...Double.pi`, including when decoded. `openness` is normalized to `0...1`. Status comes from the operating system: the library does not infer a posture from angle thresholds. A present value with `.unknown` status still carries a sensor reading; nil means the live sensor is unavailable.

`content.hingeState` and the attachment environment expose the last observed raw state, not a guarantee of a current action sample. Read `content.hingeState` in ``SpriteUI/GameView``'s `update:` closure to apply that telemetry to existing entities. This closure runs with SwiftUI updates, not as a simulation clock. Read `@Environment(\.gameHingeState)` inside attachment descendants. The host supplies that environment only within its attachment subtree; parents, siblings, and external overlays use `.onGameHingeChange` on the particular `GameView` instead. The callback accepts an optional value, including nil for unavailable data.

Retain a subscription to ``SpriteUI/GameHingeEvents``' `DidChange` event for scene-level observation. Its `scene`, `previous`, and `state` fields identify the scene and optional old/new readings. Genuine unavailability is observable as a transition to nil. An unchanged fresh sample can establish action currency without changing telemetry or delivering another `DidChange` event or value-change callback. Do not use event counts or callbacks to infer whether the action adapter has a current sample. Subscriptions have the same lifetime rules as other scene events.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct HingeReadout: View {
    @State private var hinge: GameHingeState?

    var body: some View {
        GameView { _ in }
            .onGameHingeChange { hinge = $0 }
            .overlay(alignment: .top) {
                if let hinge {
                    Text("Last observed angle: \(hinge.angle, specifier: "%.3f") rad")
                } else {
                    Text("Live hinge unavailable")
                }
            }
    }
}
```

Raw angle and openness are suitable for visual or audio effects. Keep cameras, HUD placement, and occlusion decisions driven by <doc:adaptive-game-surfaces>. A hinge angle does not identify usable display rectangles, and a reserved division does not prove that a hinge sensor exists. Accessory-display hosting remains unsupported.

## Availability and lifecycle

The native UIKit bridge uses `UIHingeInteraction` on iOS 27.1 or later when a hinge sensor is available. Older iOS, macOS, and nonhinged devices report nil. Native observation pauses for hidden or inactive hosts and retains the last known telemetry. Focus loss, inactive input scope, and app disable separately invalidate the action router's sample currency; the retained raw value can still be nonnil. On resume, the bridge re-enables `UIHingeInteraction` to request a current OS sample even if its angle is unchanged. A cached neutral reading cannot arm the action adapter. An `.unknown` status suspends actions without declaring the sensor unavailable; nil represents genuine unavailability and disconnects the native hinge device. Do not manufacture a closed or fully open sensor reading as a fallback, infer hardware from screen sizes, or save a last reading as though it were still live. Codable conformance permits value storage; it does not turn a restored value into a connected sensor.

Raw observation does not opt into gameplay input. Configure ``SpriteUI/HingeInputConfiguration`` explicitly on either `.gameInput(input, isActive: true, hinge: configuration)` or `.gameInput(hub, isActive: true, hinge: configuration)`. Both overloads default `hinge` to nil. Bind ``SpriteUI/InputControl``'s `.hinge` control to an action; samples originate on ``SpriteUI/InputDevice``'s `.hinge` device. Attach one input modifier to the intended game host.

## Calibrate a signed action

`HingeInputConfiguration(neutralAngle:activationAngle:deadZone:smoothing:)` defaults to `Double.pi`, `Double.pi / 2`, `Float(0.05)`, and `TimeInterval(0.08)`. Angles are radians. `value(for:)` accepts an optional `GameHingeState` and returns a signed, clamped scalar with its configured dead zone, rescaling the remaining magnitude to full scale. Nil, `.unknown` status, and equal neutral/activation endpoints produce zero. Raw observation still preserves an `.unknown` sample. Neutral maps to zero and the activation angle maps to positive full scale. Movement on the other side of neutral has the opposite sign, within the sensor's available range. With the default neutral at `.pi` and a sample range of `0...pi`, closing produces positive values only. Choose an interior neutral and a distinct activation angle when gameplay needs both signs.

Finite calibration angles clamp to `0...pi`, and the dead zone clamps to `0...0.99`. Nonfinite parameters use their defaults; negative smoothing also falls back to `0.08`.

The native adapter applies frame-rate-independent smoothing using monotonic real time. It does not use scene time or multiply a smoothing factor once per rendered frame. The pure configuration value conversion does not perform temporal smoothing. A zero smoothing duration gives an immediate response after rearming.

```swift
import SpriteUI
import SwiftUI

@MainActor
struct CalibratedHingeInput: View {
    private static let bend = InputAction("bend", kind: .axis)
    @State private var input = InputController(contexts: [
        InputActionMap(name: "Play", bindings: [
            InputBinding(bend, control: .hinge),
            InputBinding(bend, control: .key("space")),
            InputBinding(bend, control: .virtual("bend"))
        ])
    ])
    @State private var slider: Double = 0
    @State private var surface = GameSurfaceGeometry(size: .zero)
    @Environment(\.scenePhase) private var scenePhase
    private let pad = InputDevice.virtual("bend-slider")

    var body: some View {
        VStack {
            GameView { _ in }
                .onGameSurfaceChange { next in
                    if surface.size != next.size || surface.safeBounds != next.safeBounds
                        || surface.usableRegions() != next.usableRegions() {
                        releaseSlider()
                    }
                    surface = next
                }
                .gameInput(input, hinge: HingeInputConfiguration())
                .frame(height: 240)
            Slider(value: $slider, in: -1...1)
                .accessibilityLabel("Virtual bend action")
                .onChange(of: slider) { _, value in
                    input.setValue(.axis(Float(value)), for: .virtual("bend"),
                                   device: pad)
                }
            Text("Bend: \(input.value(for: Self.bend).scalar, specifier: "%.2f")")
        }
        .onAppear { releaseSlider() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase != .active { releaseSlider() }
        }
        .onDisappear { releaseSlider() }
    }

    private func releaseSlider() {
        slider = 0
        input.setValue(.axis(0), for: .virtual("bend"), device: pad)
    }
}
```

The slider and Space binding drive the same action as the native hinge. They do not create sensor readings or announce a hinge device. This example explicitly resets its own virtual slider on appearance, disappearance, inactivity, and effective layout changes. The surface callback compares only `size`, `safeBounds`, and active `usableRegions()` before submitting zero on the app-owned virtual pad. It does not call `input.cancelAll()`, which would also cancel the hinge. Do not wait for an action's `.cancelled` event to release a virtual control: a held hinge can keep the shared action active, with a `.changed` phase instead. <doc:adapting-to-game-surfaces> explains the same geometry comparison and release policy.

## Return to neutral before acting

The adapter requires a current raw calibrated zero before it arms. After focus, scope, or app disable/resume, retained telemetry is not current until a fresh OS sample arrives, even when its value matches the cached neutral. This requirement applies to initial connection, reconnection, resume after focus or scope loss, input-blocking transitions, manual cancellation, configuration changes, and ownership handoff. A nonneutral first reading cannot automatically press an action. Return the real sensor to the configured neutral dead zone, then move again to act. A smoothed value approaching zero is insufficient: rearming uses the unsmoothed calibrated sample.

When the host hides, becomes inactive, loses input focus or scope, blocks input for a transition, or receives manual cancellation, held native hinge input is cancelled. Resuming never replays a held bend. Player sessions remain intact through these lifecycle changes. Raw observation may retain the last effect value while native observation is paused; it does not bypass the action adapter's fresh-sample or neutral requirements.

Coordinate-space-only changes preserve native hinge input and its armed state. A resize, safe-area change, or change to usable surface regions cancels affected pointer/touch captures, manipulation, and other native-routed actions while excluding `.hinge` from that cancellation. The hinge has no pointer-coordinate dependency. Moving from fully open to partially open can therefore keep driving an already armed action as the surface layout changes, without requiring another neutral reading. A simultaneous focus, scope, transition, or other cancellation still applies its normal neutral gate. Pure angle changes never drive layout; reported surface geometry remains its source.

## Assign the native device to a player

A ``SpriteUI/PlayerInputHub`` announces `.hinge` only when the native sensor is available and a nonnil configuration opts into it. The backend leaves the device unassigned. Your app chooses a player explicitly, for example in a retained `hub.observe` handler for `.connected(let info)` when `info.id == .hinge`, then calls `try hub.assign(.hinge, to: player)`. Install the handler before the host starts its input adapter. Do not call `hub.connect` to invent native availability.

Transfer uses exclusive ownership and cancellation. The old player's held action cancels and the new player must observe calibrated neutral before receiving a bend. Session identity survives host lifecycle changes; physical sensor loss disconnects the device. A reconnect is a new connection opportunity for your app's assignment policy. Hinge feedback is unsupported; do not assume an angle sensor supplies haptics.

Follow <doc:controlling-a-scene-with-hinge-input> for three complete stages, including a two-player connection handler, transfer control, and virtual sliders that work without hinge hardware. See <doc:player-input-sessions-and-feedback> for general device ownership and feedback rules.
