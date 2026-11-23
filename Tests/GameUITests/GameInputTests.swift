import ECSCore
import Foundation
import GameController
@testable import GameUI
import SwiftUI
import Testing

@MainActor @Suite struct GameInputTests {
    let fire = InputAction("fire")
    let move = InputAction("move", kind: .axis2D)

    func fixture() -> (InputController, GameInputRouter) {
        let input = InputController(contexts: [.init(name: "play", bindings: [
            .init(fire, control: .key("space")), .init(fire, control: .pointerButton(0)),
            .init(fire, control: .gamepadButton(.south)), .init(fire, control: .virtual("fire")),
            .init(move, control: .gamepadAxis(.leftStick), deadZone: 0.2)
        ])])
        let router = GameInputRouter()
        router.configure(input); router.setActive(true)
        return (input, router)
    }

    @Test func modifierAcceptsAnExplicitScope() {
        let input = InputController()
        _ = Color.clear.gameInput(input)
        _ = Color.clear.gameInput(input, isActive: false)
    }

    @Test func keysUseCanonicalNamesAndLeaveUnboundShortcutsAlone() {
        let pairs: [(KeyEquivalent, String)] = [
            ("W", "w"), (.upArrow, "up"), (.downArrow, "down"), (.leftArrow, "left"),
            (.rightArrow, "right"), (.space, "space"), (.escape, "escape"), (.return, "return"), (.tab, "tab")
        ]
        for (key, expected) in pairs { #expect(GameInputRouter.canonicalKey(key) == expected) }
        let (input, router) = fixture()
        #expect(!router.key("q", pressed: true))
        #expect(!router.key("space", pressed: true, shortcut: true))
        #expect(!router.key("space", pressed: true, isRepeat: true))
        #expect(!input.value(for: fire).isPressed)
        #expect(router.key("space", pressed: true))
        #expect(router.key("space", pressed: true, isRepeat: true))
        #expect(input.value(for: fire).isPressed)
    }

    @Test func keyUpClearsAGatedSourceAfterItsBindingDisappears() {
        let (input, router) = fixture()
        let contexts = input.contexts
        router.key("space", pressed: true)
        input.setContexts([])
        #expect(!router.key("space", pressed: false))
        input.setContexts(contexts)
        #expect(router.key("space", pressed: true))
        #expect(input.value(for: fire).isPressed)
    }

    @Test func focusLossCancelsAndReleaseWhileInactiveClearsNeutralGate() {
        let (input, router) = fixture()
        router.key("space", pressed: true)
        router.setActive(false)
        #expect(input.state(for: fire).phase == .cancelled)
        router.setActive(true)
        router.key("space", pressed: true, isRepeat: true)
        #expect(!input.value(for: fire).isPressed)
        router.setActive(false)
        router.releaseKeys() // Physical keyboard reports all keys up after focus loss.
        router.setActive(true)
        router.key("space", pressed: true)
        #expect(input.value(for: fire).isPressed)
    }

    @Test func everyLifecycleConditionCancelsVirtualInput() {
        for condition in 0..<5 {
            let (input, router) = fixture()
            var availability = GameInputAvailability(visible: true, focused: true, sceneActive: true,
                                                     scopeActive: true, windowActive: true)
            input.setValue(.button(true), for: .virtual("fire"), device: .virtual("touch"))
            switch condition {
            case 0: availability.visible = false
            case 1: availability.focused = false
            case 2: availability.sceneActive = false
            case 3: availability.scopeActive = false
            default: availability.windowActive = false
            }
            router.setActive(availability.acceptsInput)
            #expect(input.state(for: fire).phase == .cancelled)
            router.setActive(true)
            input.setValue(.button(true), for: .virtual("fire"), device: .virtual("touch"))
            #expect(!input.value(for: fire).isPressed)
            input.setValue(.button(false), for: .virtual("fire"), device: .virtual("touch"))
            input.setValue(.button(true), for: .virtual("fire"), device: .virtual("touch"))
            #expect(input.value(for: fire).isPressed)
        }
    }

    @Test func disablingAndReplacingTheControllerCancelsAllContributions() {
        let (input, router) = fixture()
        router.key("space", pressed: true)
        input.isEnabled = false
        router.setActive(true)
        #expect(!router.isActive)
        #expect(!router.key("space", pressed: true))
        router.key("space", pressed: false)
        input.isEnabled = true
        router.setActive(true)
        router.key("space", pressed: true)
        #expect(input.value(for: fire).isPressed)
        router.key("space", pressed: false)
        input.setValue(.button(true), for: .virtual("fire"), device: .virtual("touch"))
        let replacement = InputController(contexts: input.contexts)
        router.configure(replacement)
        #expect(input.state(for: fire).phase == .cancelled)
        #expect(!replacement.value(for: fire).isPressed)
        router.setActive(false)
        replacement.setValue(.button(true), for: .virtual("fire"), device: .virtual("touch"))
        router.configure(InputController())
        #expect(replacement.state(for: fire).phase == .cancelled)
    }

    @Test func pointerReleaseAfterDeactivationOrRebindingStillClearsTheSource() {
        let (input, router) = fixture()
        let contexts = input.contexts
        router.pointer(0, pressed: true)
        #expect(input.value(for: fire).isPressed)
        router.setActive(false)
        input.setContexts([])
        router.pointer(0, pressed: false)
        input.setContexts(contexts)
        router.setActive(true)
        router.pointer(0, pressed: true)
        #expect(input.value(for: fire).isPressed)
    }

    @Test func gamepadActivationAndResumeWaitForNeutralInsideTheDeadZone() {
        let (input, router) = fixture()
        let adapter = GameControllerInput(router: router)
        let id = UUID()
        let stick = InputControl.gamepadAxis(.leftStick)
        adapter.route([(stick, .axis2D([0.8, 0]))], id: id)
        #expect(input.value(for: move).vector == .zero)
        adapter.route([(stick, .axis2D([0.1, 0]))], id: id)
        adapter.route([(stick, .axis2D([0.8, 0]))], id: id)
        #expect(input.value(for: move).vector.x > 0.7)
        router.setActive(false); adapter.suspend(); router.setActive(true)
        adapter.route([(stick, .axis2D([0.8, 0]))], id: id)
        #expect(!input.value(for: move).isPressed)
        adapter.route([(stick, .axis2D([0.1, 0]))], id: id)
        adapter.route([(stick, .axis2D([0.8, 0]))], id: id)
        #expect(input.value(for: move).vector.x > 0.7)
        let second = UUID()
        adapter.route([(stick, .axis2D([0.1, 0]))], id: second)
        adapter.route([(stick, .axis2D([0, 0.8]))], id: second)
        adapter.disconnect(id: id)
        #expect(input.value(for: move).vector.y > 0.7)
    }

    @Test func syntheticExtendedControllerMapsNativeElementsAndDisconnectIsIsolated() throws {
        let (input, router) = fixture()
        let adapter = GameControllerInput(router: router)
        adapter.start(refresh: {})
        defer { adapter.stop() }
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let pad = try #require(first.extendedGamepad)
        let secondPad = try #require(second.extendedGamepad)
        pad.valueChangedHandler = { _, _ in }
        first.physicalInputProfile.valueDidChangeHandler = { _, _ in }
        adapter.poll(controllers: [first, second])
        pad.buttonA.setValue(1)
        pad.buttonB.setValue(1); pad.buttonX.setValue(1); pad.buttonY.setValue(1)
        pad.leftShoulder.setValue(1); pad.rightShoulder.setValue(1)
        pad.leftThumbstick.setValueForXAxis(0.6, yAxis: -0.7)
        pad.rightThumbstick.setValueForXAxis(-0.4, yAxis: 0.5)
        pad.dpad.setValueForXAxis(-1, yAxis: 1)
        pad.leftTrigger.setValue(0.4); pad.rightTrigger.setValue(0.8)
        adapter.poll(controllers: [first, second])
        #expect(input.value(for: fire).isPressed)
        let values = Dictionary(uniqueKeysWithValues: GameControllerInput.values(from: first))
        for button in [GamepadButton.south, .east, .west, .north, .leftShoulder, .rightShoulder] {
            #expect(values[.gamepadButton(button)] == .button(true))
        }
        #expect(values[.gamepadAxis(.leftStick)] == .axis2D([0.6, -0.7]))
        #expect(values[.gamepadAxis(.rightStick)] == .axis2D([-0.4, 0.5]))
        #expect(values[.gamepadAxis(.dpad)] == .axis2D([-1, 1]))
        #expect(values[.gamepadAxis(.leftTrigger)] == .axis(0.4))
        #expect(values[.gamepadAxis(.rightTrigger)] == .axis(0.8))
        secondPad.buttonA.setValue(1)
        adapter.poll(controllers: [first, second])
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: first)
        #expect(input.value(for: fire).isPressed)
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: second)
        #expect(input.state(for: fire).phase == .cancelled)
        adapter.stop()
        #expect(pad.valueChangedHandler != nil)
        #expect(first.physicalInputProfile.valueDidChangeHandler != nil)
    }

    @Test func separatePollingHostsDoNotStealCallbacksOrCancelEachOther() throws {
        let (firstInput, firstRouter) = fixture()
        let (secondInput, secondRouter) = fixture()
        let first = GameControllerInput(router: firstRouter)
        let second = GameControllerInput(router: secondRouter)
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        pad.buttonA.pressedChangedHandler = { _, _, _ in }
        first.poll(controllers: [controller]); second.poll(controllers: [controller])
        pad.buttonA.setValue(1)
        first.poll(controllers: [controller]); second.poll(controllers: [controller])
        #expect(firstInput.value(for: fire).isPressed && secondInput.value(for: fire).isPressed)
        first.stop()
        #expect(!firstInput.value(for: fire).isPressed)
        #expect(secondInput.value(for: fire).isPressed)
        #expect(pad.buttonA.pressedChangedHandler != nil)
        second.stop()
    }

    @Test func uniqueHostBindingCancelsHeldActionsAndRejectsAmbiguousHosts() {
        let (input, _) = fixture()
        let session = GameInputSession()
        session.router.configure(input)
        let host = GameHost(), other = GameHost()
        let reference = GameHostReference(id: host.inputHostID, host: host)
        session.bind([reference])
        #expect(host.actionInput === input)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        host.cancelInputs()
        #expect(input.state(for: fire).phase == .cancelled)
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        #expect(!input.value(for: fire).isPressed)
        session.bind([reference, .init(id: other.inputHostID, host: other)])
        #expect(host.actionInput == nil && other.actionInput == nil)
        session.stop()
    }

    @Test func hostCancellationClearsContactsBeforeReentrantActionHandlers() {
        let (input, _) = fixture()
        let host = GameHost()
        host.actionInput = input
        let contact = host.beginInput(at: .zero)
        var observedClearedContacts = false
        let token = input.observe { event in
            if event.phase == .cancelled {
                observedClearedContacts = host.inputContacts.isEmpty
                host.cancelInputs()
            }
        }
        input.setValue(.button(true), for: .key("space"), device: .keyboard)
        host.cancelInputs()
        #expect(observedClearedContacts && host.inputContacts[contact] == nil)
        token.cancel()
    }

    @Test func stoppingAnUnfocusedSessionAlsoCancelsVirtualControls() {
        let (input, _) = fixture()
        let session = GameInputSession()
        session.router.configure(input)
        input.setValue(.button(true), for: .virtual("fire"), device: .virtual("touch"))
        session.stop()
        #expect(input.state(for: fire).phase == .cancelled)
    }

    @Test func lifecycleCancellationRejectsReentrantNativeInput() {
        let (input, router) = fixture()
        var acceptedReentrantPress = false
        let token = input.observe { event in
            if event.phase == .cancelled {
                acceptedReentrantPress = router.key("space", pressed: true)
                router.pointer(0, pressed: true)
            }
        }
        router.key("space", pressed: true)
        router.setActive(false)
        #expect(!acceptedReentrantPress && !input.value(for: fire).isPressed)
        token.cancel()
    }

    @Test func replacingInputRequiresHeldGamepadsToReturnToNeutralAgain() {
        let (input, router) = fixture()
        let adapter = GameControllerInput(router: router)
        let id = UUID()
        let control = InputControl.gamepadButton(.south)
        adapter.route([(control, .button(false))], id: id)
        adapter.route([(control, .button(true))], id: id)
        #expect(input.value(for: fire).isPressed)
        let replacement = InputController(contexts: input.contexts)
        router.configure(replacement)
        adapter.route([(control, .button(true))], id: id)
        #expect(!replacement.value(for: fire).isPressed)
        adapter.route([(control, .button(false))], id: id)
        adapter.route([(control, .button(true))], id: id)
        #expect(replacement.value(for: fire).isPressed)
    }

    @Test func replacementHonorsReentrantLifecycleAndNewerConfiguration() {
        let (input, router) = fixture()
        let replacement = InputController(contexts: input.contexts)
        let token = input.observe { event in
            if event.phase == .cancelled { router.setActive(false) }
        }
        router.key("space", pressed: true)
        router.configure(replacement)
        #expect(router.input === replacement && !router.isActive)
        #expect(!router.key("space", pressed: true))
        token.cancel()

        let (old, secondRouter) = fixture()
        secondRouter.key("space", pressed: true)
        let latest = InputController()
        let reentrant = old.observe { event in
            if event.phase == .cancelled { secondRouter.configure(latest) }
        }
        secondRouter.configure(replacement)
        #expect(secondRouter.input === latest)
        reentrant.cancel()
    }

    @Test func returningFromAnotherAppReconcilesAMissedMouseRelease() {
        let (input, router) = fixture()
        router.pointer(0, pressed: true)
        router.setActive(false)
        router.reconcilePointerButtons(pressed: [])
        router.setActive(true)
        router.pointer(0, pressed: true)
        #expect(input.value(for: fire).isPressed)
        router.setActive(false)
        router.reconcilePointerButtons(pressed: [0])
        router.setActive(true)
        router.pointer(0, pressed: true)
        #expect(!input.value(for: fire).isPressed)
        router.pointer(0, pressed: false)
        router.pointer(0, pressed: true)
        #expect(input.value(for: fire).isPressed)
    }

    @Test func pollingDoesNotRetainItsOwnerAndStopIsIdempotent() {
        let (_, router) = fixture()
        var adapter: GameControllerInput? = GameControllerInput(router: router)
        weak var owner = adapter
        adapter?.start(refresh: {})
        adapter?.stop(); adapter?.stop()
        adapter = nil
        #expect(owner == nil)
        var abandoned: GameControllerInput? = GameControllerInput(router: router)
        weak var abandonedOwner = abandoned
        abandoned?.start(refresh: {})
        abandoned = nil
        #expect(abandonedOwner == nil)
    }
}
