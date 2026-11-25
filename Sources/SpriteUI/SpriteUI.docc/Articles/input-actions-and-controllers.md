# Move a player with buttons, keys, or a controller

A player should move the same way whether someone holds an on-screen button, presses D, or pushes a stick. Write the movement rule once, then let each control supply a direction to it.

SpriteUI calls that shared intent an ``SpriteUI/InputAction``. A binding connects a control to an action, a map groups bindings for a part of your game, and an ``SpriteUI/InputController`` holds the resulting values. Start with actions such as move and fire rather than separate movement rules for each device.

## Turn a press into a game action

Use a button action for fire, an axis for steering, or a two-dimensional axis for movement. Axis values run from -1 to 1; movement vectors have a maximum length of 1. Positive y points up.

The session below defines move and fire once. Its virtual Right and Up controls share a pad, so holding both produces diagonal movement. Fire has its own control. Call the setters on both press and release.

```swift
import SpriteUI
import Observation

@MainActor
@Observable
final class ActionSession {
    static let move = InputAction("move", kind: .axis2D)
    static let fire = InputAction("fire")
    let input: InputController
    var fireCount = 0
    var lastTransition = "idle"
    private var subscription: InputSubscription?

    init() {
        input = InputController(contexts: [InputActionMap(name: "Play", bindings: [
            InputBinding(Self.move, control: .virtual("right"), scale: [1, 0]),
            InputBinding(Self.move, control: .virtual("up"), scale: [0, 1]),
            InputBinding(Self.fire, control: .virtual("fire"))
        ])])
        subscription = input.observe(action: Self.fire) { [weak self] event in
            self?.lastTransition = event.phase.rawValue
            if event.phase == .pressed { self?.fireCount += 1 }
        }
    }

    func setPad(right: Bool, up: Bool) {
        // Both controls belong to one composite producer and resolve atomically.
        input.setValues([
            (.virtual("right"), .button(right)),
            (.virtual("up"), .button(up))
        ], device: .virtual("pad"))
    }

    func setFire(held: Bool) {
        input.setValue(.button(held), for: .virtual("fire"),
                       device: .virtual("fire-button"))
    }

    func stopObserving() {
        subscription?.cancel()
        subscription = nil
    }
}
```

The fire subscription counts the moment firing begins. Keep its ``SpriteUI/InputSubscription`` for as long as you need callbacks; releasing or cancelling it stops delivery. The weak capture lets the session go away without being kept alive by its own callback. Callbacks run synchronously on the main actor, so keep the work short.

An action's stored phase describes its last transition. `.pressed` can remain there throughout a long hold. Subscribe when you need to fire once; poll `value(for:)` when you need to move continuously. Automatic fire should use the held value and your game's cooldown.

Normal release produces `.released`; interrupted input produces `.cancelled`. A changing held value produces `.changed`. Identical samples, including key repeats, do not produce another press.

## Move while a control is held

In this view, holding Right moves the cyan square. The same movement action also accepts WASD and a gamepad stick or d-pad. The system reads the direction each frame and multiplies speed by elapsed time once.

The view retains the controller in `@State`. An app-defined component passes that same instance to the player's system; `World` has no `input` property.

```swift
import SpriteUI
import SwiftUI

struct PlayerInput: Component {
    let controller: InputController

    // This runtime reference should not propagate to cloned entities.
    @MainActor func cloned() -> Self? { nil }
}

enum MovementActions {
    static let move = InputAction("move", kind: .axis2D)
    static let map = InputActionMap(name: "Play", bindings: [
        InputBinding(move, control: .virtual("right"), scale: [1, 0]),
        InputBinding(move, control: .key("d"), scale: [1, 0]),
        InputBinding(move, control: .key("a"), scale: [-1, 0]),
        InputBinding(move, control: .key("w"), scale: [0, 1]),
        InputBinding(move, control: .key("s"), scale: [0, -1]),
        InputBinding(move, control: .gamepadAxis(.leftStick), deadZone: 0.2),
        InputBinding(move, control: .gamepadAxis(.dpad))
    ])
}

@MainActor
struct PlayerInputSystem: System {
    private let query = EntityQuery(where: .has(PlayerInput.self))
    init(world: World) {}

    func update(context: UpdateContext) {
        for player in context.entities(matching: query) {
            guard let driver = player.components[PlayerInput.self] else { continue }
            let direction = driver.controller.value(for: MovementActions.move).vector
            player.position += direction * 100 * Float(context.deltaTime)
            player.position.x = min(max(player.position.x, -100), 100)
            player.position.y = min(max(player.position.y, -90), 90)
        }
    }
}

@MainActor
struct HoldRightStyle: ButtonStyle {
    let input: InputController

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(configuration.isPressed ? Color.cyan : Color.gray.opacity(0.2))
            .onChange(of: configuration.isPressed) { _, held in
                send(held)
            }
            .onDisappear { send(false) }
    }

    private func send(_ held: Bool) {
        input.setValue(.button(held), for: .virtual("right"),
                       device: .virtual("right-button"))
    }
}

@MainActor
struct InputMovementView: View {
    @State private var input = InputController(contexts: [MovementActions.map])
    @State private var status = "Preparing movement"

    var body: some View {
        VStack {
            GameView { content in
                let player = Entity(name: "player", components:
                    SpriteComponent(color: .cyan, size: [32, 32]),
                    PlayerInput(controller: input))
                content.add(player)
                do {
                    try content.world.systems.add(PlayerInputSystem.self)
                    status = "Hold Right, or focus the game area and use WASD"
                } catch {
                    status = "Could not schedule movement: \(error)"
                }
            }
            .frame(height: 240)
            .gameInput(input, isActive: input.isEnabled)
            Button("Hold Right") {}.buttonStyle(HoldRightStyle(input: input))
                .disabled(!input.isEnabled)
            Text("Move held: \(input.value(for: MovementActions.move).isPressed ? "yes" : "no")")
            Text(status)
        }
        .onDisappear { input.cancelAll() }
    }
}
```

The button style sends a release when the button disappears, preventing movement from getting stuck. `.gameInput` connects focused hardware input to the controller used by the button and system.

The driver component contains a runtime reference. Its `cloned()` method excludes it from clones, and it stays out of Codable snapshots. Reattach a driver when spawning a controlled player. For movement under a transformed parent, choose the coordinate space described in <doc:systems-and-input>.

## Combine directions without increasing speed

Give all directions on one virtual pad the same device identity. Their values combine: Left and Right cancel, while Up and Right produce a diagonal. Separate devices compete by strength rather than adding together, so holding D while pushing the stick does not double the player's speed.

`setValues` applies the listed changes together. Unlisted controls keep their previous values, so send `.button(false)`, `.axis(0)`, or `.axis2D(.zero)` to release them.

Use binding `scale` to turn a digital press into a direction. A stick dead zone removes small movements near its center and rescales the remaining range. With a dead zone of 0.2, magnitude 0.2 becomes zero, 0.6 becomes 0.5, and 1 stays 1. The resolver limits the final movement vector to length 1, keeping diagonal speed consistent.

## Give menus their own controls

Space might fire during play and confirm a choice in a menu. Install the menu map above the play map while the menu is open. The upper map reserves its controls by default, so confirming does not also fire.

This helper also shows how to save a changed binding as a preference.

```swift
import SpriteUI
import Foundation

@MainActor
func configureInput(input: InputController, showMenu: Bool) throws -> Data {
    let fire = InputAction("fire")
    let confirm = InputAction("confirm")
    let play = InputActionMap(name: "Play", bindings: [
        InputBinding(fire, control: .key("space")),
        InputBinding(fire, control: .virtual("fire"))
    ])
    let menu = InputActionMap(name: "Menu", bindings: [
        InputBinding(confirm, control: .key("space"))
    ])
    input.setContexts(showMenu ? [play, menu] : [play])

    var rebound = play
    rebound.bindings[0].control = .key("f")
    // Save player preferences, not a temporary menu or held input state.
    return try JSONEncoder().encode([rebound])
}

@MainActor
func restoreInput(_ data: Data, into input: InputController) throws {
    let maps = try JSONDecoder().decode([InputActionMap].self, from: data)
    input.setContexts(maps)
}
```

Maps are ordered bottom to top. An upper map replaces lower bindings for the same action, even while no controls are held. Setting `consumesInput` to false lets lower maps use its controls for other actions; it still replaces bindings for the same action.

Use `setContexts(_:)` to replace maps. Different maps cancel active actions; identical maps leave input alone. Keep action definitions stable when restoring preferences: identity includes the name, kind, and press threshold. A button's default threshold is 0.5. `InputValue.isPressed` on an axis means nonzero rather than applying a separate button threshold.

## Release input when play stops

Set `input.isEnabled = false` when a pause interface takes control. Pausing the world stops simulation but does not stop input callbacks. Use `cancelAll()` when leaving a session, or `cancel(device:)` when one device loses ownership.

After cancellation, held controls must return to neutral before acting again. For a stick, the binding's dead zone can count as neutral. After rebinding, neutral must satisfy both the old and current bindings. Re-enabling input should therefore be followed by release and a fresh press, rather than carrying a held control into the next screen.

## Connect hardware to the game surface

Attach `.gameInput(input, isActive:)` directly to the intended `GameView`, or to a wrapper containing exactly one game view. Focus loss cancels hardware input. Set `isActive` false while another interface owns focus. ``SpriteUI/InputTargetComponent`` is for entity taps and drags; action bindings do not require it.

Key bindings accept lowercase characters and names such as `space`, `escape`, `return`, `tab`, and the arrow directions. Pointer bindings represent buttons: 0 is primary and 1 is secondary. They do not supply pointer position.

For gamepads, add **Game Controllers** in the app target's **Signing & Capabilities** and select **ExtendedGamepad** and **MicroGamepad**. The adapter uses Apple's [GameController framework](https://developer.apple.com/documentation/gamecontroller). Extended profiles provide supported sticks, triggers, d-pad, and buttons; micro profiles provide their supported buttons and d-pad. Missing controls remain neutral. Keep touch controls available where the app supports touch. Your app can also present Apple's `GCVirtualController`; once connected, its supported elements use the same bindings.

For a custom adapter, `handles(control:)` identifies controls used by the current maps. `isNeutral(_:for:)` tests a sample against those bindings, but does not submit it or clear a cancellation gate. Feed actual samples through `setValue` or `setValues` on the main actor.

For a complete movement scene, continue with <doc:controlling-a-player-with-input-actions>. When two players need separate controls, read <doc:player-input-sessions-and-feedback>.

## See also

- <doc:systems-and-input>
- <doc:entity-and-scene-lifecycle>
- <doc:saving-and-debugging>
