# Use a hinge for an effect or a game control

On a device with a physical hinge and a supported hinge sensor, opening or closing it can change the lighting or charge a move. Native hinge observation and controls require that hardware.

SpriteUI lets you observe the optional sensor for effects, then choose separately whether to connect it to a calibrated game action. Keep a button or slider available so the game works without hinge hardware.

## Check the hardware requirements

Native hinge input works only on devices with a physical hinge whose sensor is exposed by the operating system. SpriteUI's native adapter requires UIKit on iOS 27.1 or later. A supported OS version alone does not make a device hinge-capable.

On devices without that hardware, older iOS versions, and macOS, live hinge state is nil and no native hinge input device is available. The examples can still run using their sliders, buttons, or keyboard bindings. Those controls supply game-action values; they do not simulate a physical hinge sensor.

Use the reported availability rather than assuming that a device has a sensor. Resizing a window or showing a split-screen layout does not provide hinge data.

## Show the last observed angle

``SpriteUI/GameHingeState`` contains an angle in radians, normalized `openness` from 0 to 1, and an operating-system status. Nil means live hinge data is unavailable. A value with `.unknown` status still contains a reading, but does not establish a known posture.

This view shows the last observed angle, or an unavailable message when there is no reading.

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

Use raw angle or openness for visual and audio effects. Keep camera rectangles and HUD placement driven by <doc:adaptive-game-surfaces>: an angle cannot tell you which screen regions are usable, and a reserved division does not prove there is a sensor.

Apply `.onGameHingeChange` to the game view whose sensor state you need. The view's `update:` closure can also read `content.hingeState` when changing existing entities, while attachment descendants can read `@Environment(\.gameHingeState)`. That environment is supplied inside the attachment subtree, so external overlays use the callback.

For scene-owned observation, retain a subscription to ``SpriteUI/GameHingeEvents``' `DidChange` event. It supplies the scene and old and new optional states. These are change notifications, not a stream proving that every sample is fresh. An unchanged new reading can matter to the action adapter without delivering another change event.

## Map a bend to the same action as a slider

An effect reading does not automatically become gameplay input. Pass a ``SpriteUI/HingeInputConfiguration`` to `.gameInput` and bind `.hinge` to an action to enable that path. Without the configuration, hinge gameplay input stays off.

Calibration chooses a neutral angle and an angle that means full positive input. The default neutral is fully open at `Double.pi`; half open at `Double.pi / 2` means positive full scale. The default dead zone is 0.05, and smoothing takes 0.08 seconds.

This example binds hinge, Space, and a slider to one axis action. The readout shows the resolved action value, so you can try the control without a sensor.

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

The slider supplies virtual action values rather than sensor readings. It releases its own value on disappearance, inactivity, and meaningful surface-layout changes. It does not cancel the whole controller merely to release the slider, because that would also cancel hinge input. <doc:adaptive-game-surfaces> explains the layout comparison used here.

With the default calibration, closing produces positive values only. For both positive and negative movement, choose an interior neutral angle and a different activation angle. Motion to the other side of neutral then produces a negative value within the sensor's range. The dead zone removes and rescales small changes around neutral.

The native adapter smooths using elapsed real time, independently of the scene clock or frame rate. Set smoothing to zero for an immediate response after input is ready. Calling the configuration's `value(for:)` directly converts one reading; it does not perform temporal smoothing.

## Ask for neutral before allowing a new action

After connection, focus loss, cancellation, a configuration change, or an ownership handoff, the real sensor must send a fresh reading inside the calibrated neutral dead zone. Then moving away can act. An already bent device must not charge a move immediately on resume.

The neutral test uses the raw calibrated sample. A smoothed value drifting toward zero cannot arm the control. Neither can a cached neutral reading retained while the app was inactive. The native bridge requests a current sample on resume, even if its angle has not changed.

Layout changes alone preserve an already armed hinge action because it has no pointer-coordinate dependency. A simultaneous focus loss or other cancellation still requires fresh neutral. Angle changes do not determine layout; reported surface geometry does.

## Give the native hinge to a player

With a ``SpriteUI/PlayerInputHub``, the configured host announces `.hinge` only when the native sensor is available. It starts unassigned. Install a retained hub observer before the host starts, then choose an owner when `.connected` reports that device and call `try hub.assign(.hinge, to: player)`.

Transfer cancels the old player's held contribution and asks the new owner for calibrated neutral. Sessions survive host lifecycle changes; actual sensor loss disconnects the device. Reconnection gives your joining policy another opportunity to assign it. Do not call `hub.connect` to pretend native hardware is available.

Continue with [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-hinge-03.swift) for a scene with two players, transfer, and virtual sliders. <doc:player-input-sessions-and-feedback> explains general device ownership.

## Limits to keep in mind

Native observation uses `UIHingeInteraction` on UIKit with iOS 27.1 or later when a sensor is available. Older iOS, macOS, and devices without a sensor report nil. Hidden or inactive hosts pause observation and retain the last telemetry; a nonnil retained value is not proof of current action input. `.unknown` suspends actions without declaring the sensor unavailable; nil disconnects the native hinge device.

State angles stay within 0 through pi, with nonfinite angles rejected. Calibration clamps finite angles and dead zones to their supported ranges. Equal neutral and activation angles, nil readings, or unknown status produce zero action value. A saved reading is still just saved data, not a connected sensor. Hinge feedback is unsupported.

Hinge input does not grant access to an external or outer display. See <doc:bounded-rendering-and-read-only-presentation> for the separate presentation options and their platform limits.
