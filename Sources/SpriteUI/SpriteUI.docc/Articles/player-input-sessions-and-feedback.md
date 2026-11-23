# Player input sessions and feedback

Assign devices to local players, adapt prompts to meaningful input, and request capability-checked controller feedback.

## Give each player independent action state

Use one retained, main-actor ``SpriteUI/PlayerInputHub`` for the local game surface. Each ``SpriteUI/PlayerInputSession`` owns its own ``SpriteUI/InputController`` and context stack. Players can share action definitions and maps while keeping values and transitions independent. Pass the appropriate session's `input` to that player's movement system, as in <doc:input-actions-and-controllers>.

A hub starts with logical keyboard and pointer sources. These describe the host's coalesced input routes; their presence does not confirm that a physical keyboard or mouse is connected. Controllers discovered by the native host appear in `hub.devices` **unassigned**. Choose joining and transfer policy in your app; the host does not choose a player.

## Connect virtual producers and assign explicitly

This complete model creates two players and two virtual pads. Each pad begins with one owner. Call `pressAndRelease` from a button action to increment only that owner's counter. No physical hardware, native framework imports, or feedback provider is required.

```swift
import Foundation
import SpriteUI
import Observation

@MainActor @Observable
final class LocalPlayers {
    static let fire = InputAction("fire")
    let hub = PlayerInputHub()
    let padA = InputDevice.virtual("pad-a")
    let padB = InputDevice.virtual("pad-b")
    var presses: [UUID: Int] = [:]
    var deviceStatus = "Ready"
    @ObservationIgnored private var actions: [InputSubscription] = []
    @ObservationIgnored private var devices: InputDeviceSubscription?

    init() {
        let map = InputActionMap(name: "Play", bindings: [
            InputBinding(Self.fire, control: .virtual("fire")),
            InputBinding(Self.fire, control: .key("space")),
            InputBinding(Self.fire, control: .gamepadButton(.south))
        ])
        let first = hub.addPlayer(named: "P1", contexts: [map])
        let second = hub.addPlayer(named: "P2", contexts: [map])
        for (device, name, player) in [(padA, "Pad A", first), (padB, "Pad B", second)] {
            hub.connect(InputDeviceInfo(id: device, name: name, presentations: [
                .virtual("fire"): InputControlPresentation(label: "Fire on \(name)")
            ]))
            do { try hub.assign(device, to: player) }
            catch { deviceStatus = "Assignment failed: \(error)" }
        }
        for player in hub.players {
            let id = player.id
            actions.append(player.input.observe(action: Self.fire) { [weak self] event in
                if event.phase == .pressed { self?.presses[id, default: 0] += 1 }
            })
        }
        devices = hub.observe { [weak self] event in
            switch event {
            case .connected(let info): self?.deviceStatus = "Connected: \(info.name)"
            case .disconnected(let info): self?.deviceStatus = "Disconnected: \(info.name)"
            default: break
            }
        }
    }

    func pressAndRelease(_ device: InputDevice) {
        hub.submit([(.virtual("fire"), .button(true))], device: device)
        hub.submit([(.virtual("fire"), .button(false))], device: device)
    }

    func suspend() { hub.cancelAll() }
}
```

Connect a virtual producer before submitting its samples. Route owned devices through `hub.submit(_:device:)`; writing directly to a session's controller bypasses hub ownership and active-device tracking. A partial snapshot updates the listed controls atomically and leaves unlisted controls unchanged. Give independent pads different ``SpriteUI/InputDevice/virtual(_:)`` identities; related controls within one composite pad may share its identity.

Use `hub.owner(of:)`, `player.devices`, and `hub.devices` to build an assignment interface. Call `try hub.assign(device, to: player)` to assign or transfer a connected device to a player from the same hub. Handle assignment errors instead of silently ignoring them. `unassign` removes ownership; `disconnect` removes a producer. `removePlayer` also releases that player's devices. Controller identities last for a connection; do not save them as persistent player preferences.

## Transfer held controls safely

One device has at most one player owner. Transfer removes its old contribution and stops its feedback. The hub remembers unassigned raw samples so assigning a currently held device cannot create a surprise press for the new owner. New controller connections also establish a first-snapshot baseline.

After transfer, a held control must return to neutral before acting for the new owner. For an analog binding, neutral respects its effective dead zone; exact zero is unnecessary. Test this with the tutorial's Hold Fire toggle: press, transfer, release, then press again. The release clears the gate; it does not increment the new player's counter. Contributions from the old player's other devices remain available.

Retain tokens from `hub.observe` and `player.input.observe`; releasing or cancelling a token ends delivery. Device events describe connection, metadata updates, disconnection, assignment, and active-device changes. Callbacks run synchronously on the main actor. Use weak captures when the observing object retains its token. Count one-shot press edges in an action subscription, and poll held values in a simulation system.

## Attach the focused hardware host

Apply `.gameInput(hub, isActive: gameplayHasFocus)` to the game surface. Keep one active native host for a hub. The host discovers controllers and submits keyboard, pointer-button, and controller samples; ownership remains an application decision. Assign logical Keyboard or Pointer explicitly if your game uses them. System-reserved shortcuts and unsupported controls remain subject to the platform and controller profile.

Set `hub.isEnabled` to suspend input for every player, or `player.isEnabled` for one player. Use `hub.cancelAll()` when leaving the surface. Focus loss cancels held input and feedback while preserving assignments. Release held controls before actuating again after focus returns or input is re-enabled. Pausing the simulation alone does not suspend the input session.

In SwiftUI, retain the model in `@State`. Submit samples in button actions, `.onChange`, or lifecycle handlers. Do not submit input, request feedback, or change ownership while evaluating `body`. A `.onChange` reaction is useful for a held toggle; a subscription captures every action edge even when a press and release occur within a single SwiftUI update.

## Show prompts for the last meaningful device

`player.activeDevice` describes the last owned device to send a meaningful bound input. Neutral samples, identical repeats, unbound activity, and stick noise inside a bound dead zone do not take over the prompt. Assignment alone is not meaningful activity. When ownership is removed, the session can fall back to another previously used owned device.

Call `player.prompt(for: action)` when rendering an action hint. The returned ``SpriteUI/InputPrompt`` contains a label, an optional SF Symbols name, and the selected control and device. Render a `Label` when `symbolName` exists, otherwise plain text. A prompt can fall back to another owned device that expresses that action, or return `nil` when none does. It uses effective bindings rather than bindings shadowed by higher contexts.

``SpriteUI/InputDeviceInfo`` exposes control presentations, `supportsHaptics`, and `hasRemappedElements`. Native controller presentations follow the operating system's control labels and remapped symbol names. Use these presentations instead of hard-coding vendor button labels. Nonempty controller presentations also describe which controls are available; a prompt skips absent controls. Device metadata can update without changing ownership. The presentation is a hint, not a guarantee that every controller supports every action.

## Report feedback capability and outcome

Call `player.playFeedback(.selection)` from an interaction handler. Other presets are `.impact`, `.success`, and `.failure`; ``SpriteUI/ControllerFeedback`` also accepts intensity, sharpness, and duration. The default target is the player's last meaningful device. Keyboard or virtual activity does not silently vibrate a different assigned controller. To deliberately target an owned controller, pass its identity in `on:`.

| Result | Meaning |
| --- | --- |
| `.accepted` | The backend scheduled the request; this does not prove physical vibration |
| `.unsupported` | The selected owned device does not support controller feedback, including virtual pads and keyboard |
| `.unavailable` | No eligible owned target or active backend is available, or input is disabled |
| `.failed` | The backend could not play the request |

Display the returned ``SpriteUI/InputFeedbackResult`` and keep gameplay functional for every result. Call `player.stopFeedback()` to stop explicitly. Cancellation, transfer, disconnection, and native-host teardown stop affected feedback. `supportsHaptics` is capability metadata, not a promise that a later playback request will succeed.

Action maps and binding preferences can be saved. Sessions, assignments, active-device history, held samples, subscriptions, and feedback engines are runtime state and stay out of world snapshots.

## See also

- <doc:viewports-and-split-screen>
- <doc:sharing-a-world-between-viewports>
- <doc:sharing-devices-between-players>
- <doc:input-actions-and-controllers>
- <doc:saving-and-debugging>
