# Give each local player their own controls

In a two-player game, pressing Fire on one pad should fire only that player's weapon. If someone hands the pad to the other player while holding Fire, the handoff should not fire another shot.

Use a ``SpriteUI/PlayerInputHub`` to keep track of devices and their owners. Each ``SpriteUI/PlayerInputSession`` has its own controller and action maps. Players can share the same definitions for move and fire while keeping their held values and press events separate.

## Start with two pads and two players

The model below creates two virtual pads, assigns one to each player, and counts fire presses separately. Call `pressAndRelease` from a SwiftUI button to try it without physical controllers.

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

Connect a virtual device before submitting its values. Send owned input through `hub.submit(_:device:)` so the hub can route it to the right player and remember which device they used. Writing directly to a session's controller bypasses that work.

A submission updates the listed controls together and leaves the others alone. Related controls on one pad should share its device identity; independent pads need different identities. Pass each player's `input` to their movement system as shown in <doc:input-actions-and-controllers>.

## Let players join and swap devices

Build a joining interface from `hub.devices`, `player.devices`, and `hub.owner(of:)`. Call `try hub.assign(device, to: player)` to give a connected device to a player in that hub. The same call transfers an already owned device. Handle errors in the joining interface so a failed assignment is visible.

Each device has at most one owner. A transfer removes its old input contribution and stops its feedback. Other devices belonging to the old player keep working. `unassign` releases ownership, `disconnect` removes a device, and `removePlayer` releases that player's devices.

A held button must be released before it can act for its new owner. A stick must return to its effective dead zone. The hub remembers samples even while a device is unassigned, so assigning a held pad cannot sneak in a new press. Newly connected controllers also establish a starting sample before acting.

Keep observer tokens alive while the interface needs them. Both device and action callbacks run synchronously on the main actor. Use an action subscription for one-shot presses, including taps that begin and end within one SwiftUI update; use polling for held movement.

## Bring in keyboard and controller input

Apply `.gameInput(hub, isActive: gameplayHasFocus)` to the game surface, using one active native host for the hub. It discovers controllers and supplies keyboard, pointer-button, and controller samples. Discovered controllers start unassigned; your joining policy chooses their players.

The hub's initial Keyboard and Pointer entries describe logical input routes. Their presence does not confirm attached hardware. Assign them when your game uses them. Controller identities last for a connection, so save binding preferences rather than treating those IDs as permanent player settings.

Retain the model in `@State`. Submit input and change ownership from interaction or lifecycle handlers rather than while SwiftUI evaluates `body`.

## Match the on-screen hint to the control being used

A player who switches from keyboard to gamepad should see a matching Fire hint. `player.activeDevice` follows the last owned device that sent meaningful input for a bound action. Stick noise inside a dead zone, repeated samples, and unrelated keys do not change it. Assignment alone does not change it either.

Use `player.prompt(for: action)` to obtain an ``SpriteUI/InputPrompt``. Show a SwiftUI `Label` when it has a `symbolName`, or text otherwise. The prompt follows the current effective bindings and the operating system's control labels and remapped symbols. It can fall back to another owned device that supports the action, or return nil if none does.

Device metadata can change without ownership changing. Using its presentations avoids hard-coding a particular controller's button names or offering a hint for a control that its profile lacks.

## Add controller feedback without depending on it

Call `player.playFeedback(.selection)` from an interaction handler. Other presets include `.impact`, `.success`, and `.failure`; ``SpriteUI/ControllerFeedback`` also lets you choose intensity, sharpness, and duration.

By default, feedback targets the last meaningful device. A keyboard action does not silently vibrate some other assigned controller. Pass an owned controller in `on:` when that is the intended target.

| Result | What the game can tell the player |
| --- | --- |
| `.accepted` | The backend scheduled feedback; physical vibration is not confirmed. |
| `.unsupported` | This device does not support controller feedback. |
| `.unavailable` | No eligible target or active backend is available, or input is disabled. |
| `.failed` | The backend could not play the request. |

Keep the interaction usable for every result. `supportsHaptics` helps describe capability, but a later request can still fail. `player.stopFeedback()` stops feedback; cancellation, device transfer, disconnection, and host teardown also stop affected feedback.

## Pause and leave the game

Disable the hub to suspend everyone, or disable one session to suspend one player. Focus loss cancels held input and feedback while retaining assignments. After input returns, controls must pass through neutral before acting again. Pausing the world by itself does not suspend these sessions.

Use `hub.cancelAll()` when leaving the surface. Sessions, assignments, device history, held values, and feedback engines are runtime state and stay out of world snapshots. Save action maps and preferences separately.

Continue with [the complete example](https://github.com/Prince2k3/sprite-ui/blob/main/Sources/SpriteUI/SpriteUI.docc/Resources/spriteui-player-sessions-03.swift) to practice joining and transfer. For a camera per player, read <doc:viewports-and-split-screen>.

## See also

- <doc:input-actions-and-controllers>
- <doc:saving-and-debugging>
