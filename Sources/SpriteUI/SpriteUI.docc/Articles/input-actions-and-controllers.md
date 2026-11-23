# Input actions and controllers

Resolve keyboard, pointer, controller, and on-screen controls into shared game actions.

## Define actions independently of devices

An ``SpriteUI/InputAction`` describes an intent such as move or fire. An ``SpriteUI/InputBinding`` maps a control to that intent, and an ``SpriteUI/InputActionMap`` groups bindings into a context. The main-actor, observable ``SpriteUI/InputController`` resolves those contexts and exposes values to SwiftUI and systems.

| Action kind | Resolved value | Typical use |
| --- | --- | --- |
| `.button` | `.button(Bool)` | Fire, jump, confirm |
| `.axis` | `.axis(Float)` in -1…1 | Steering or throttle |
| `.axis2D` | `.axis2D(SIMD2<Float>)` with magnitude at most 1 | Movement or aim |

Define actions once and reuse them in maps, systems, and observers. Action identity includes its name, kind, and press threshold. A different threshold creates a different action even if the name matches. A button's default threshold is 0.5; analog bindings press it when their processed magnitude reaches that threshold.

``SpriteUI/InputValue`` provides three convenient projections: `vector` returns two axes, `scalar` returns the x component, and `isPressed` tests for a nonzero resolved value. Buttons project to `[1, 0]` or zero. For axis actions, `isPressed` means nonzero, rather than a separate button threshold. Positive y points upward.

## Feed virtual controls and observe transitions

This complete session model needs no physical keyboard or gamepad. It combines two directions on one virtual pad and a separate virtual fire button. Call `setPad(right:up:)` with held directions, then call it with both arguments false to release. Call `setFire(held:)` on press and release.

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

Retain the ``SpriteUI/InputSubscription`` returned by `observe`; cancellation or deallocation ends delivery. Use weak captures when the owner retains the token. Omit the `action:` argument to observe all actions. Delivery is synchronous on the main actor, so keep callbacks short.

| Phase | Meaning |
| --- | --- |
| `.idle` | No transition has been recorded for this action |
| `.pressed` | The resolved value changed from neutral to nonzero |
| `.changed` | A nonzero value changed while remaining nonzero |
| `.released` | Normal input returned the action to neutral |
| `.cancelled` | Cancellation ended an active action |

`state(for:)` stores the **last transition**, not per-frame flags. A held action can keep `.pressed` for many frames; a released action can keep `.released`. Identical samples, including keyboard repeats, emit no additional events. Use a subscription for one-shot edges such as firing once. Poll `value(for:)` or `state(for:).isPressed` for continuous movement or automatic fire with a game-owned cooldown. Don't increment a score every frame just because the stored phase is `.pressed`.

## Poll held movement from a system

Pass the same controller used by your UI through an application-defined ``SpriteUI/Component``. `World` has no `input` property. This complete view moves a root-level sprite while the on-screen Right button is held. Present `InputMovementView()` from your app. The simulation reads held input every frame and multiplies speed by elapsed scene time exactly once.

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

Keep runtime controllers out of saved component data. Here, `cloned()` excludes the driver from clones; the component is not registered for Codable snapshots. Reattach a driver when spawning a controlled entity. For parented entities, choose an explicit coordinate space as described in <doc:systems-and-input>.

## Attach focused hardware input

Attach `.gameInput(input, isActive: true)` to the game surface, using the same retained instance as your systems and controls. The modifier owns the active focus used for keyboard, pointer-button, and GameController input. Activate only the intended game surface when several scenes share a window, and set `isActive` false while another interface owns input.

``SpriteUI/InputTargetComponent`` continues to opt an entity or subtree into targeted taps and drags. Action bindings do not require it. Disabling or removing the target component changes gesture eligibility; it does not disable movement or firing actions resolved by ``SpriteUI/InputController``. Use action contexts or `input.isEnabled` to control those actions independently.

The modifier automatically cancels its hardware sources when action focus is lost. Attach it directly to a `GameView`, or to a wrapper containing exactly one `GameView`, so it can bind the controller to a unique host. With that binding, host lifecycle or inspection cancellation clears both captured entity gestures and the controller’s active actions. A wrapper containing several game views does not provide a unique host; attach a modifier to each intended game surface instead.

Keys use lowercase characters or the names `up`, `down`, `left`, `right`, `space`, `escape`, `return`, and `tab`. Key spelling is canonicalized to lowercase, and a literal space becomes `space`. Pointer button 0 is primary and 1 is secondary. These bindings represent buttons, not pointer position or motion.

The gamepad adapter uses Apple’s [GameController framework](https://developer.apple.com/documentation/gamecontroller) to discover connected controllers and sample their profiles. Vendor-neutral aliases such as `.south` and `.east` feed logical game-action values through your bindings. The adapter supports **extended and micro gamepad profiles**. Extended profiles supply `.leftStick`, `.rightStick`, `.dpad`, `.leftTrigger`, `.rightTrigger`, and their supported buttons. Micro profiles supply their supported buttons and d-pad; unavailable buttons and axes report neutral values. Bind sticks and the d-pad to `.axis2D` actions; triggers can drive `.axis` or thresholded `.button` actions. A controller is identified by `.controller(UUID)`, so disconnecting one producer need not discard another producer's input.

Use `handles(control:)` when writing a custom host adapter to determine whether an installed context binds a control and leave unrelated shortcuts to the surrounding interface. Custom adapters and virtual controls feed `setValue(_:for:device:)` or `setValues(_:device:)` on the main actor. For activation baseline gates, `input.isNeutral(value, for: control)` checks a sample against current effective bindings, including scale, dead zones, and button thresholds. An unbound control is neutral only at zero. This helper does not submit a sample or clear a cancellation gate; send the actual sample through `setValue` or `setValues`.

## Configure GameController support in your app

In the app target’s **Signing & Capabilities** pane, add **Game Controllers**, enable support for controller interaction, and select the profiles your app supports. For this adapter, select **ExtendedGamepad** and **MicroGamepad**. This sets [`GCSupportsControllerUserInteraction`](https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportscontrolleruserinteraction) to `true`; the [`GCSupportedGameControllers`](https://developer.apple.com/documentation/bundleresources/information-property-list/gcsupportedgamecontrollers) array contains dictionaries whose `ProfileName` values are `ExtendedGamepad` and `MicroGamepad`. Apple’s [GameController overview](https://developer.apple.com/documentation/gamecontroller) describes this setup.

Keep controller use optional for a touch-capable app. The tutorial’s on-screen controls work without a connected controller; declaring support does not require players to own physical hardware.

On supported platforms, an app can also create and connect Apple’s native [`GCVirtualController`](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller). Its underlying `GCController` is handled automatically by the adapter once connected, using the supported profile elements and the same action bindings. Your app owns the native controller’s configuration, presentation, and lifetime; `.gameInput` does not present a virtual-controller overlay.

These examples have not been tested with physical controller hardware.

## Understand scaling and multiple devices

Digital directions use binding `scale`, for example `[-1, 0]` for left and `[0, 1]` for up. Dead zones are radial and rescaled: with a dead zone of 0.2, a magnitude of 0.2 resolves to zero, 0.6 resolves to 0.5, and 1 stays 1. Binding scale is applied after dead-zone processing, with each scale component clamped to -1…1. Nonfinite sample components become neutral and values are bounded to their supported range. Installed map configuration is normalized to finite values before map equality is checked, so equivalent normalized maps do not repeatedly cancel input.

The resolver sums bindings **within each device**, then clamps scalars to -1…1 and normalizes vectors whose magnitude exceeds 1. Opposing keyboard directions cancel, and keyboard diagonals move at the same maximum speed as a single direction. It then chooses the strongest resolved device contribution, using a stable device order for exact ties. Keyboard and stick values do not add together to increase speed.

Give the buttons comprising one directional pad the **same virtual device**, such as `.virtual("screen-controls")`, so Up plus Right composes into a diagonal and Left plus Right cancels. Each button still sends its own control value and releases only that control. Use distinct device identities for independent producers, such as two separate sticks or a pad and a fire button. `setPad` above demonstrates atomic changes to a composite producer. Contributions from separate devices compete by strength rather than summing.

`setValues` applies all listed changes before resolving once. **Unlisted controls retain their samples**; send explicit neutral values to release them. Send `.button(false)`, `.axis(0)`, or `.axis2D(.zero)` as appropriate. This also makes scripted input and tests possible without hardware.

## Stack contexts, rebind, and persist maps

Contexts are installed **bottom to top**. In `[play, menu]`, `menu` has priority. The upper map shadows the same action identity completely, even if none of its controls are held. By default, `consumesInput` also reserves every bound control from lower maps, including controls that are currently neutral. Setting it false permits lower maps to use those controls for other actions; it does not disable same-action shadowing.

This complete helper creates a menu that takes Space away from Fire, then demonstrates replacing bindings and encoding maps. Keep stable action definitions when restoring user bindings.

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

`contexts` is read-only externally; use `setContexts(_:)` to replace or rebind the stack. Replacing different maps cancels active actions and gates their held sources. Assigning identical maps leaves input undisturbed. Maps, bindings, actions, controls, and values are Codable; save binding preferences rather than the runtime controller or its current held state. Validate imported preferences against the actions and controls your game supports.

## Cancel safely across lifecycle changes

Set `input.isEnabled = false` to cancel held actions when opening a pause interface. Re-enable it when gameplay is ready. Pausing a world alone stops simulation, so also manage input if held gameplay controls must be discarded. The SwiftUI UI and input subscriptions have a separate lifecycle from world frames.

Use `cancelAll()` when abandoning a session, or `cancel(device:)` when one producer loses ownership. Cancellation gates affected held sources **until each source sends neutral**. For analog input, neutral can be inside the effective bound dead zone; an exact zero sample is not required. A button binding can also be neutral below its press threshold. When a control has several effective bindings, it must be neutral for all of them. After rebinding, a cancelled source must be neutral under both its bindings at cancellation and its current effective bindings. Re-enabling, restoring focus, or installing a new map must not turn a still-held key into a new press. Release the key or on-screen button, or return the stick to neutral, then actuate again. Virtual controls should send neutral on release and disappearance; custom adapters must also handle interrupted interactions and device loss.

For a hands-on implementation, follow <doc:controlling-a-player-with-input-actions>. It includes on-screen buttons, system-driven 2D movement, an action-state readout, and optional hardware bindings.

## See also

- <doc:systems-and-input>
- <doc:entity-and-scene-lifecycle>
- <doc:saving-and-debugging>
