import Foundation
import SpriteUI
import Testing
import simd
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsInputTests {
    @Test(arguments: [
        ("w", SIMD2<Float>(0, 1)), ("up", SIMD2<Float>(0, 1)),
        ("s", SIMD2<Float>(0, -1)), ("down", SIMD2<Float>(0, -1)),
        ("a", SIMD2<Float>(-1, 0)), ("left", SIMD2<Float>(-1, 0)),
        ("d", SIMD2<Float>(1, 0)), ("right", SIMD2<Float>(1, 0)),
    ])
    func keyboardDirectionsBridgeSynchronously(key: String, direction: SIMD2<Float>) {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.input.setValue(.button(true), for: .key(key), device: .keyboard)
        #expect(game.moveInput == direction)
        controls.input.setValue(.button(false), for: .key(key), device: .keyboard)
        #expect(game.moveInput == .zero)
    }

    @Test func keyboardAliasesRemainIndependentAndDiagonalsAreNormalized() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.input.setValues([(.key("w"), .button(true)), (.key("up"), .button(true))], device: .keyboard)
        controls.input.setValue(.button(false), for: .key("w"), device: .keyboard)
        #expect(game.moveInput == SIMD2<Float>(0, 1))
        controls.input.setValue(.button(true), for: .key("d"), device: .keyboard)
        #expect(abs(simd_length(game.moveInput) - 1) < 0.001)
        #expect(game.moveInput.x > 0 && game.moveInput.y > 0)
        controls.input.setValue(.button(true), for: .key("left"), device: .keyboard)
        #expect(game.moveInput == SIMD2<Float>(0, 1))
    }

    @Test func fireKeysPreserveAimAndTapToWalkRoute() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.aimStick([0, 1], pressed: false)
        game.destination = [80, 100]
        game.playerRoute = [[40, 50], [80, 100]]
        controls.input.setValue(.button(true), for: .key("f"), device: .keyboard)
        #expect(game.isFiring && game.aimInput == SIMD2<Float>(0, 1))
        #expect(game.destination == SIMD2<Float>(80, 100))
        #expect(game.playerRoute == [SIMD2<Float>(40, 50), [80, 100]])
        controls.aimStick(.zero, pressed: false)
        #expect(game.isFiring && game.aimInput == .zero)
        controls.input.setValue(.button(true), for: .key("space"), device: .keyboard)
        controls.input.setValue(.button(false), for: .key("f"), device: .keyboard)
        #expect(game.isFiring)
        controls.input.setValue(.button(false), for: .key("space"), device: .keyboard)
        #expect(!game.isFiring)
        #expect(game.destination == SIMD2<Float>(80, 100))
        // An idle context synchronization must not send a fresh movement command.
        controls.synchronizeContext()
        #expect(game.playerRoute.count == 2)
    }

    @Test func touchSticksUseIndependentSourcesAndCenterFire() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.moveStick([0.6, 0])
        controls.aimStick(.zero, pressed: true)
        #expect(game.moveInput == SIMD2<Float>(0.6, 0))
        #expect(game.isFiring && game.aimInput == .zero)
        controls.aimStick([0, 0.8], pressed: true)
        controls.input.cancel(device: DemoBotsInput.moveDevice)
        #expect(game.moveInput == .zero)
        #expect(game.isFiring && game.aimInput == SIMD2<Float>(0, 0.8))
        controls.moveStick(.zero)
        controls.moveStick([-1, 0])
        controls.aimStick(.zero, pressed: false)
        #expect(game.moveInput == SIMD2<Float>(-1, 0))
        #expect(!game.isFiring && game.aimInput == .zero)
    }

    @Test func disconnectFallsBackToOtherMovementSourcesAndGatesReconnect() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let device = InputDevice.controller(UUID())
        controls.input.setValue(.axis2D([-1, 0]), for: .gamepadAxis(.leftStick), device: device)
        controls.moveStick([0.6, 0])
        #expect(game.moveInput == SIMD2<Float>(-1, 0))
        controls.input.cancel(device: device)
        #expect(game.moveInput == SIMD2<Float>(0.6, 0))
        controls.input.setValue(.axis2D([-1, 0]), for: .gamepadAxis(.leftStick), device: device)
        #expect(game.moveInput == SIMD2<Float>(0.6, 0))
        controls.input.setValue(.axis2D(.zero), for: .gamepadAxis(.leftStick), device: device)
        controls.input.setValue(.axis2D([-1, 0]), for: .gamepadAxis(.leftStick), device: device)
        #expect(game.moveInput == SIMD2<Float>(-1, 0))
        controls.input.setValue(.button(true), for: .key("d"), device: .keyboard)
        #expect(game.moveInput == SIMD2<Float>(1, 0))
        controls.input.setValue(.button(false), for: .key("d"), device: .keyboard)
        #expect(game.moveInput == SIMD2<Float>(-1, 0))
    }

    @Test func aimDisconnectFallsBackWithoutReleasingAnotherFireSource() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let device = InputDevice.controller(UUID())
        controls.input.setValue(.axis2D([0.75, 0]), for: .gamepadAxis(.rightStick), device: device)
        #expect(game.aimInput.x > 0 && game.isFiring)
        controls.aimStick([0, 1], pressed: true)
        #expect(game.aimInput == SIMD2<Float>(0, 1))
        controls.input.cancel(device: DemoBotsInput.aimDevice)
        #expect(game.aimInput.x > 0 && game.aimInput.y == 0 && game.isFiring)
        controls.input.setValue(.button(true), for: .key("f"), device: .keyboard)
        controls.input.cancel(device: device)
        #expect(game.aimInput == .zero && game.isFiring)
        controls.input.setValue(.button(false), for: .key("f"), device: .keyboard)
        #expect(!game.isFiring)
    }

    @Test(arguments: [
        (InputControl.gamepadButton(.south), InputValue.button(true)),
        (.gamepadAxis(.rightTrigger), .axis(1)),
    ])
    func controllerFireUsesTheSharedAction(control: InputControl, value: InputValue) {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let device = InputDevice.controller(UUID())
        controls.input.setValue(value, for: control, device: device)
        #expect(game.isFiring && game.aimInput == .zero)
        controls.input.cancel(device: device)
        #expect(!game.isFiring)
    }

    @Test func controllerDpadAndStickDeadZones() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let device = InputDevice.controller(UUID())
        controls.input.setValues([
            (.gamepadAxis(.leftStick), .axis2D([0.05, 0])),
            (.gamepadAxis(.rightStick), .axis2D([0, 0.05])),
        ], device: device)
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        controls.input.setValue(.axis2D([0, -1]), for: .gamepadAxis(.dpad), device: device)
        #expect(game.moveInput == SIMD2<Float>(0, -1))
    }

    @Test(arguments: ["p", "escape"])
    func pauseAndResumeRequireHeldSourcesToReturnToNeutral(key: String) {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.input.setValue(.button(true), for: .key("w"), device: .keyboard)
        controls.aimStick([0, 1], pressed: true)
        controls.input.setValue(.button(true), for: .key(key), device: .keyboard)
        #expect(game.phase == .paused && world.isPaused)
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        controls.input.setValue(.button(true), for: .key(key), device: .keyboard)
        #expect(game.phase == .paused)
        controls.input.setValue(.button(false), for: .key(key), device: .keyboard)
        controls.input.setValue(.button(true), for: .key(key), device: .keyboard)
        #expect(game.phase == .playing && !world.isPaused)
        controls.input.setValue(.button(true), for: .key("w"), device: .keyboard)
        controls.aimStick([0, 1], pressed: true)
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        controls.input.setValue(.button(false), for: .key("w"), device: .keyboard)
        controls.input.setValue(.button(true), for: .key("w"), device: .keyboard)
        controls.aimStick(.zero, pressed: false)
        controls.aimStick([0, 1], pressed: true)
        #expect(game.moveInput == SIMD2<Float>(0, 1))
        #expect(game.aimInput == SIMD2<Float>(0, 1) && game.isFiring)
    }

    @Test func inspectionRoutesPauseAndEscapeToTheDebugger() {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game) { world.isPaused.toggle() }
        controls.input.setValue(.button(true), for: .key("i"), device: .keyboard)
        #expect(game.isInspecting && world.isPaused)
        controls.input.setValues([(.key("w"), .button(true)), (.key("f"), .button(true))], device: .keyboard)
        controls.moveStick([1, 0]); controls.aimStick([0, 1], pressed: true)
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        controls.input.setValue(.button(true), for: .key("p"), device: .keyboard)
        #expect(game.isInspecting && game.phase == .playing && !world.isPaused)
        controls.input.setValue(.button(true), for: .key("escape"), device: .keyboard)
        #expect(!game.isInspecting && game.phase == .playing && !world.isPaused)
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        controls.input.setValue(.button(true), for: .key("w"), device: .keyboard)
        #expect(game.moveInput == .zero)
        controls.input.setValue(.button(false), for: .key("w"), device: .keyboard)
        controls.input.setValue(.button(true), for: .key("w"), device: .keyboard)
        #expect(game.moveInput == SIMD2<Float>(0, 1))
    }

    @Test func hudAndControllerMenuUseTheSamePauseActionAndInspectionRestoresPauseMenu() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.togglePause()
        #expect(game.phase == .paused)
        controls.toggleInspection()
        #expect(game.isInspecting)
        controls.toggleInspection()
        #expect(!game.isInspecting && game.phase == .paused)
        let device = InputDevice.controller(UUID())
        controls.input.setValue(.button(true), for: .gamepadButton(.menu), device: device)
        #expect(game.phase == .playing)
        controls.input.setValue(.button(false), for: .gamepadButton(.menu), device: device)
        controls.input.setValue(.button(true), for: .gamepadButton(.menu), device: device)
        #expect(game.phase == .paused)
    }

    @Test func contextChangesDiscardShortcutsQueuedByThePreviousContext() {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.input.setValues([
            (.key("i"), .button(true)),
            (.key("p"), .button(true)),
        ], device: .keyboard)
        #expect(game.isInspecting && game.phase == .playing && world.isPaused)
    }

    @Test(arguments: [InputControl.key("return"), InputControl.gamepadButton(.south)])
    func menuConfirmStartsTheSelectedHomeLevel(control: InputControl) {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        game.home()
        let controls = DemoBotsInput(game: game)
        controls.selectedLevel = 2
        let device: InputDevice = control == .key("return") ? .keyboard : .controller(UUID())
        controls.input.setValue(.button(true), for: control, device: device)
        #expect(game.phase == .playing && game.levelNumber == 2 && !world.isPaused)
        #expect(!game.isFiring)
    }

    @Test(arguments: [false, true])
    func southConfirmStartsOrResumesWithoutFiringUntilReleased(fromHome: Bool) {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        if fromHome { game.home() } else { game.pause() }
        let controls = DemoBotsInput(game: game)
        let device = InputDevice.controller(UUID())
        controls.input.setValue(.button(true), for: .gamepadButton(.south), device: device)
        #expect(game.phase == .playing && !world.isPaused && !game.isFiring)
        controls.input.setValue(.button(true), for: .gamepadButton(.south), device: device)
        #expect(!game.isFiring && !controls.input.value(for: DemoBotsInput.fire).isPressed)
        controls.input.setValue(.button(false), for: .gamepadButton(.south), device: device)
        controls.input.setValue(.button(true), for: .gamepadButton(.south), device: device)
        #expect(game.isFiring)
    }

    @Test(arguments: [(true, 1, 2), (true, 3, 3), (false, 2, 2)])
    func resultConfirmAdvancesOrReplaysTheAppropriateLevel(won: Bool, level: Int, expected: Int) {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        game.levelNumber = level
        game.finish(won: won)
        let controls = DemoBotsInput(game: game)
        controls.input.setValue(.button(true), for: .key("return"), device: .keyboard)
        #expect(game.phase == .playing && game.levelNumber == expected)
        #expect(!game.isFiring)
    }

    @Test func homeLevelSelectionUsesArrowsAndDpadWithoutRepeatingOrCarryingMovement() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        game.home()
        let controls = DemoBotsInput(game: game)
        controls.input.setValue(.button(true), for: .key("left"), device: .keyboard)
        #expect(controls.selectedLevel == 1)
        controls.input.setValue(.button(false), for: .key("left"), device: .keyboard)
        controls.input.setValue(.button(true), for: .key("right"), device: .keyboard)
        #expect(controls.selectedLevel == 2)
        controls.input.setValue(.button(true), for: .key("right"), device: .keyboard)
        #expect(controls.selectedLevel == 2)
        controls.input.setValue(.button(false), for: .key("right"), device: .keyboard)
        controls.input.setValue(.button(true), for: .key("right"), device: .keyboard)
        #expect(controls.selectedLevel == 3)
        controls.input.setValue(.button(false), for: .key("right"), device: .keyboard)
        controls.input.setValue(.button(true), for: .key("right"), device: .keyboard)
        #expect(controls.selectedLevel == 3)
        controls.input.setValue(.button(false), for: .key("right"), device: .keyboard)
        let device = InputDevice.controller(UUID())
        controls.input.setValue(.axis2D([-1, 0]), for: .gamepadAxis(.dpad), device: device)
        #expect(controls.selectedLevel == 2)
        controls.input.setValue(.axis2D([-1, 0]), for: .gamepadAxis(.dpad), device: device)
        #expect(controls.selectedLevel == 2)
        controls.input.setValue(.axis2D([0, -1]), for: .gamepadAxis(.dpad), device: device)
        controls.input.setValue(.axis2D([-1, 0]), for: .gamepadAxis(.dpad), device: device)
        #expect(controls.selectedLevel == 1)
        controls.confirmSelection()
        #expect(game.phase == .playing && game.levelNumber == 1 && game.moveInput == .zero)
        controls.input.setValue(.axis2D([-1, 0]), for: .gamepadAxis(.dpad), device: device)
        #expect(game.moveInput == .zero)
        controls.input.setValue(.axis2D(.zero), for: .gamepadAxis(.dpad), device: device)
        controls.input.setValue(.axis2D([-1, 0]), for: .gamepadAxis(.dpad), device: device)
        #expect(game.moveInput == SIMD2<Float>(-1, 0))
    }

    @Test func homeAndLifecyclePauseSuppressHeldInputUntilReleased() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.moveStick([1, 0]); controls.aimStick([0, 1], pressed: true)
        controls.suspend()
        #expect(game.phase == .paused && game.moveInput == .zero && !game.isFiring)
        controls.togglePause()
        #expect(game.phase == .playing && game.moveInput == .zero && game.aimInput == .zero)
        controls.home()
        controls.moveStick([-1, 0]); controls.aimStick([1, 0], pressed: true)
        #expect(game.phase == .home && game.moveInput == .zero && !game.isFiring)
        controls.start(level: 1)
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        controls.moveStick(.zero); controls.moveStick([-1, 0])
        #expect(game.moveInput == SIMD2<Float>(-1, 0))
        controls.start(level: 1)
        controls.moveStick([-1, 0])
        #expect(game.moveInput == .zero)
    }
}
