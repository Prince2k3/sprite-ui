import Foundation
@testable import ECSCore
import Testing

@MainActor @Suite struct InputControllerTests {
    private let move = InputAction("move", kind: .axis2D)
    private let fire = InputAction("fire")
    private let throttle = InputAction("throttle", kind: .axis)

    private func keyboardMap() -> InputActionMap {
        .init(name: "play", bindings: [
            .init(move, control: .key("w"), scale: [0, 1]),
            .init(move, control: .key("s"), scale: [0, -1]),
            .init(move, control: .key("a"), scale: [-1, 0]),
            .init(move, control: .key("d"), scale: [1, 0]),
            .init(fire, control: .key("space")),
            .init(fire, control: .gamepadButton(.south)),
            .init(move, control: .gamepadAxis(.leftStick), deadZone: 0.2),
            .init(move, control: .virtual("stick")),
            .init(throttle, control: .gamepadAxis(.rightTrigger), deadZone: 0.1)
        ])
    }

    @Test func buttonTransitionsIgnoreKeyRepeatsAndTokensAreRetained() {
        let input = InputController(contexts: [keyboardMap()])
        var events: [InputActionPhase] = []
        let token = input.observe(action: fire) { events.append($0.phase) }
        input.setValue(.button(true), for: .key(" "), device: .keyboard)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(input.value(for: fire) == .button(true))
        input.setValue(.button(false), for: .key("space"), device: .keyboard)
        #expect(events == [.pressed, .released])
        token.cancel()
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(events.count == 2)
    }

    @Test func tokenDeallocationEndsDelivery() {
        let input = InputController(contexts: [keyboardMap()])
        var count = 0
        var token: InputSubscription? = input.observe { _ in count += 1 }
        #expect(token != nil)
        token = nil
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(count == 0)
    }

    @Test func digitalAxesCancelOppositesAndNormalizeDiagonals() {
        let input = InputController(contexts: [keyboardMap()])
        input.setValue(.button(true), for: .key("W"), device: .keyboard)
        #expect(input.value(for: move).vector == [0, 1])
        input.setValue(.button(true), for: .key("s"), device: .keyboard)
        #expect(input.value(for: move).vector == .zero)
        input.setValues([(.key("s"), .button(false)), (.key("d"), .button(true))], device: .keyboard)
        let vector = input.value(for: move).vector
        #expect(abs(vector.x - 0.7071068) < 0.0001)
        #expect(abs(vector.y - 0.7071068) < 0.0001)
    }

    @Test func strongestDeviceWinsAndDisconnectPreservesAnotherDevice() {
        let input = InputController(contexts: [keyboardMap()])
        let pad = InputDevice.controller(UUID())
        input.setValue(.axis2D([0.6, 0]), for: .gamepadAxis(.leftStick), device: pad)
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        #expect(input.value(for: move).vector == [0, 1])
        input.cancel(device: .keyboard)
        #expect(abs(input.value(for: move).vector.x - 0.5) < 0.0001)
        input.cancel(device: pad)
        #expect(input.state(for: move).phase == .cancelled)
        #expect(!input.value(for: move).isPressed)
    }

    @Test func releasingOneFireBindingDoesNotReleaseAnother() {
        let input = InputController(contexts: [keyboardMap()])
        let pad = InputDevice.controller(UUID())
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        input.setValue(.button(true), for: .gamepadButton(.south), device: pad)
        input.setValue(.button(false), for: .key("space"), device: .keyboard)
        #expect(input.value(for: fire).isPressed)
        input.cancel(device: pad)
        #expect(!input.value(for: fire).isPressed)
    }

    @Test func radialDeadZonePreservesDirectionAndRescales() {
        let input = InputController(contexts: [keyboardMap()])
        let pad = InputDevice.controller(UUID())
        input.setValue(.axis2D([0.1, 0.1]), for: .gamepadAxis(.leftStick), device: pad)
        #expect(input.value(for: move).vector == .zero)
        input.setValue(.axis2D([0.36, 0.48]), for: .gamepadAxis(.leftStick), device: pad)
        let vector = input.value(for: move).vector
        #expect(abs(vector.x - 0.3) < 0.0001)
        #expect(abs(vector.y - 0.4) < 0.0001)
        input.setValue(.axis(0.55), for: .gamepadAxis(.rightTrigger), device: pad)
        #expect(abs(input.value(for: throttle).scalar - 0.5) < 0.0001)
    }

    @Test func contextSwitchCancelsAndRequiresNeutralBeforeReuse() {
        let input = InputController(contexts: [keyboardMap()])
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        input.setContexts([.init(name: "menu", bindings: [.init(fire, control: .key("w"))])])
        #expect(input.state(for: move).phase == .cancelled)
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        #expect(!input.value(for: fire).isPressed)
        input.setValue(.button(false), for: .key("w"), device: .keyboard)
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        #expect(input.value(for: fire).isPressed)
    }

    @Test func upperContextConsumesControlsButCanPassThemThrough() {
        let menu = InputAction("menu")
        let base = InputActionMap(name: "base", bindings: [.init(fire, control: .key("space"))])
        let upper = InputActionMap(name: "menu", bindings: [.init(menu, control: .key("space"))])
        let input = InputController(contexts: [base, upper])
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(input.value(for: menu).isPressed)
        #expect(!input.value(for: fire).isPressed)
        var pass = upper; pass.consumesInput = false
        input.setContexts([base, pass])
        input.setValue(.button(false), for: .key("space"), device: .keyboard)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(input.value(for: menu).isPressed && input.value(for: fire).isPressed)
    }

    @Test func upperContextShadowsSameActionEvenWithoutInput() {
        let base = InputActionMap(name: "base", bindings: [.init(fire, control: .key("space"))])
        let upper = InputActionMap(name: "menu", bindings: [.init(fire, control: .key("return"))])
        let input = InputController(contexts: [base, upper])
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(!input.value(for: fire).isPressed)
        input.setValue(.button(true), for: .key("return"), device: .keyboard)
        #expect(input.value(for: fire).isPressed)
    }

    @Test func rebindingCancelsAndOldBindingStopsWorking() {
        let input = InputController(contexts: [keyboardMap()])
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        input.setContexts([.init(name: "play", bindings: [.init(fire, control: .key("f"))])])
        #expect(input.state(for: fire).phase == .cancelled)
        input.setValue(.button(false), for: .key("space"), device: .keyboard)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(!input.value(for: fire).isPressed)
        input.setValue(.button(true), for: .key("f"), device: .keyboard)
        #expect(input.value(for: fire).isPressed)
    }

    @Test func identicalMapAssignmentDoesNotCancel() {
        let map = keyboardMap()
        let input = InputController(contexts: [map])
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        input.setContexts([map])
        #expect(input.value(for: move).vector == [0, 1])
    }

    @Test func disabledInputNeverCarriesHeldValuesAcrossReactivation() {
        let input = InputController(contexts: [keyboardMap()])
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        input.isEnabled = false
        #expect(input.state(for: fire).phase == .cancelled)
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        input.isEnabled = true
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        #expect(!input.value(for: move).isPressed)
        input.setValue(.button(false), for: .key("w"), device: .keyboard)
        input.setValue(.button(true), for: .key("w"), device: .keyboard)
        #expect(input.value(for: move).isPressed)
    }

    @Test func batchSnapshotsHaveNoIntermediateButtonTransitions() {
        let input = InputController(contexts: [keyboardMap()])
        var values: [InputValue] = []
        let token = input.observe(action: move) { values.append($0.value) }
        input.setValues([(.key("w"), .button(true)), (.key("s"), .button(true))], device: .keyboard)
        #expect(values.isEmpty)
        token.cancel()
    }

    @Test func invalidAxesAndConfigurationStayFinite() {
        let action = InputAction("invalid", kind: .axis2D, pressThreshold: .nan)
        #expect(action.pressThreshold == 0.5)
        let input = InputController(contexts: [.init(name: "test", bindings: [
            .init(action, control: .virtual("x"), scale: [.infinity, 1], deadZone: .nan)
        ])])
        input.setValue(.axis2D([.nan, .infinity]), for: .virtual("x"), device: .virtual("one"))
        #expect(input.value(for: action).vector == .zero)
        input.setValue(.axis2D([1, 1]), for: .virtual("x"), device: .virtual("one"))
        #expect(input.value(for: action).vector.x == 0)
        #expect(input.value(for: action).vector.y.isFinite)
    }

    @Test func analogButtonsUseThresholds() {
        let input = InputController(contexts: [.init(name: "test", bindings: [.init(fire, control: .gamepadAxis(.rightTrigger))])])
        let pad = InputDevice.controller(UUID())
        input.setValue(.axis(0.49), for: .gamepadAxis(.rightTrigger), device: pad)
        #expect(!input.value(for: fire).isPressed)
        input.setValue(.axis(0.5), for: .gamepadAxis(.rightTrigger), device: pad)
        #expect(input.value(for: fire).isPressed)
    }

    @Test func callbackMayChangeContextsAndCancelAnotherSubscription() {
        let input = InputController(contexts: [keyboardMap()])
        var events: [InputActionPhase] = []
        var later: InputSubscription?
        let first = input.observe(action: fire) { event in
            events.append(event.phase)
            if event.phase == .pressed { input.setContexts([]); later?.cancel() }
        }
        var unwanted = 0
        later = input.observe { _ in unwanted += 1 }
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(events == [.pressed, .cancelled])
        #expect(!input.value(for: fire).isPressed)
        #expect(unwanted == 0)
        first.cancel()
    }

    @Test func cancelledStickCanRearmInsideItsDeadZoneWithoutExactZero() {
        let input = InputController(contexts: [keyboardMap()])
        let pad = InputDevice.controller(UUID())
        input.setValue(.axis2D([0.8, 0]), for: .gamepadAxis(.leftStick), device: pad)
        input.cancelAll()
        input.setValue(.axis2D([0.7, 0]), for: .gamepadAxis(.leftStick), device: pad)
        #expect(!input.value(for: move).isPressed)
        input.setValue(.axis2D([0.03, 0.02]), for: .gamepadAxis(.leftStick), device: pad)
        #expect(!input.value(for: move).isPressed)
        input.setValue(.axis2D([0.8, 0]), for: .gamepadAxis(.leftStick), device: pad)
        #expect(input.value(for: move).isPressed)
    }

    @Test func vectorClampingPreservesDirectionInsteadOfClippingAxes() {
        let input = InputController(contexts: [keyboardMap()])
        input.setValue(.axis2D([2, 1]), for: .virtual("stick"), device: .virtual("one"))
        let vector = input.value(for: move).vector
        #expect(abs(vector.x - 0.8944272) < 0.0001)
        #expect(abs(vector.y - 0.4472136) < 0.0001)
    }

    @Test func supersededTransitionsCannotBecomeValidAgainDuringReentrantDelivery() {
        let input = InputController(contexts: [keyboardMap()])
        var reentered = false
        var received: [InputActionPhase] = []
        let first = input.observe(action: fire) { event in
            if event.phase == .pressed && !reentered {
                reentered = true
                input.setValue(.button(false), for: .key("space"), device: .keyboard)
                input.setValue(.button(true), for: .key("space"), device: .keyboard)
            }
        }
        let second = input.observe(action: fire) { received.append($0.phase) }
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(received == [.pressed])
        first.cancel(); second.cancel()
    }

    @Test func shadowedBindingsDoNotPreventStickNeutralRearming() {
        let lower = InputActionMap(name: "lower", bindings: [.init(move, control: .gamepadAxis(.leftStick))])
        let upper = InputActionMap(name: "upper", bindings: [.init(move, control: .gamepadAxis(.leftStick), deadZone: 0.2)])
        let input = InputController(contexts: [lower, upper])
        let pad = InputDevice.controller(UUID())
        input.setValue(.axis2D([0.8, 0]), for: .gamepadAxis(.leftStick), device: pad)
        input.cancelAll()
        input.setValue(.axis2D([0.03, 0.02]), for: .gamepadAxis(.leftStick), device: pad)
        input.setValue(.axis2D([0.8, 0]), for: .gamepadAxis(.leftStick), device: pad)
        #expect(input.value(for: move).isPressed)
    }

    @Test func independentlyCreatedNonfiniteMapsNormalizeToTheSameConfiguration() {
        func map() -> InputActionMap {
            .init(name: "same", bindings: [.init(move, control: .virtual("stick"), scale: [1, .nan], deadZone: .nan)])
        }
        let input = InputController(contexts: [map()])
        input.setValue(.axis2D([0.8, 0]), for: .virtual("stick"), device: .virtual("test"))
        input.setContexts([map()])
        #expect(input.value(for: move).vector == [0.8, 0])
        #expect(input.state(for: move).phase == .pressed)
    }

    @Test func equalStrengthProducersHaveStableArbitrationAndPointerButtonsResolve() {
        let input = InputController(contexts: [.init(name: "test", bindings: [
            .init(move, control: .virtual("stick")),
            .init(fire, control: .pointerButton(0))
        ])])
        input.setValue(.axis2D([-1, 0]), for: .virtual("stick"), device: .virtual("z"))
        input.setValue(.axis2D([0, 1]), for: .virtual("stick"), device: .virtual("a"))
        #expect(input.value(for: move).vector == [0, 1])
        input.cancel(device: .virtual("a"))
        #expect(input.value(for: move).vector == [-1, 0])
        input.setValue(.button(true), for: .pointerButton(0), device: .pointer)
        #expect(input.value(for: fire).isPressed)
        input.cancel(device: .pointer)
        #expect(input.state(for: fire).phase == .cancelled)
    }

    @Test func neutralDetectionUsesEffectiveButtonThresholdsAndAxisDeadzones() {
        let input = InputController(contexts: [.init(name: "test", bindings: [
            .init(fire, control: .gamepadAxis(.rightTrigger)),
            .init(move, control: .gamepadAxis(.leftStick), deadZone: 0.2)
        ])])
        #expect(input.isNeutral(.axis(0.1), for: .gamepadAxis(.rightTrigger)))
        #expect(!input.isNeutral(.axis(0.5), for: .gamepadAxis(.rightTrigger)))
        #expect(input.isNeutral(.axis2D([0.03, 0.02]), for: .gamepadAxis(.leftStick)))
        let pad = InputDevice.controller(UUID())
        input.setValue(.axis(1), for: .gamepadAxis(.rightTrigger), device: pad)
        input.cancelAll()
        input.setValue(.axis(0.1), for: .gamepadAxis(.rightTrigger), device: pad)
        input.setValue(.axis(1), for: .gamepadAxis(.rightTrigger), device: pad)
        #expect(input.value(for: fire).isPressed)
    }

    @Test func mapsRoundTripAndUnknownActionsAreIdle() throws {
        let original = keyboardMap()
        let copy = try JSONDecoder().decode(InputActionMap.self, from: JSONEncoder().encode(original))
        #expect(copy == original)
        let input = InputController(contexts: [copy])
        #expect(input.state(for: InputAction("missing")).phase == .idle)
        #expect(input.handles(control: .key("W")))
        #expect(!input.handles(control: .key("q")))
    }
}
