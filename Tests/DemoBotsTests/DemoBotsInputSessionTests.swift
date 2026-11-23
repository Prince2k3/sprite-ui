@_spi(Backend) import ECSCore
import Foundation
import SpriteUI
import Testing
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsInputSessionTests {
    @MainActor private final class FeedbackRecorder: InputFeedbackProvider {
        var played: [(ControllerFeedback, InputDevice)] = []
        var stopped: [InputDevice] = []
        func play(_ feedback: ControllerFeedback, on device: InputDevice) -> InputFeedbackResult {
            played.append((feedback, device))
            return .accepted
        }
        func stop(for device: InputDevice) { stopped.append(device) }
    }

    private func connectController(to controls: DemoBotsInput, haptics: Bool = true) -> InputDevice {
        let device = InputDevice.controller(UUID())
        controls.hub.connect(.init(id: device, name: "Test controller", presentations: [
            .gamepadAxis(.leftStick): .init(label: "Move"),
            .gamepadButton(.south): .init(label: "A", symbolName: "a.circle"),
            .gamepadButton(.menu): .init(label: "Menu", symbolName: "line.3.horizontal.circle"),
        ], supportsHaptics: haptics))
        // A controller's first snapshot establishes its neutral baseline.
        controls.hub.submit([(.gamepadAxis(.leftStick), .axis2D(.zero)),
                             (.gamepadButton(.south), .button(false)),
                             (.gamepadButton(.menu), .button(false))], device: device)
        controls.hub.submit([(.gamepadAxis(.leftStick), .axis2D([0.5, 0]))], device: device)
        return device
    }

    @Test func registersAndAssignsAllLocalProducersToOnePlayer() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        #expect(controls.hub.players.count == 1)
        #expect(controls.input === controls.player.input)
        for device in [InputDevice.keyboard, .pointer, DemoBotsInput.moveDevice,
                       DemoBotsInput.aimDevice, DemoBotsInput.hudDevice] {
            #expect(controls.hub.owner(of: device) === controls.player)
            #expect(controls.player.devices.contains { $0.id == device })
        }
        controls.hub.submit([(.key("w"), .button(true))], device: .keyboard)
        #expect(game.moveInput == SIMD2<Float>(0, 1))
        controls.hub.submit([(.key("w"), .button(false))], device: .keyboard)
        controls.moveStick([0.6, 0])
        controls.aimStick([0, 0.8], pressed: true)
        #expect(game.moveInput == SIMD2<Float>(0.6, 0))
        #expect(game.aimInput == SIMD2<Float>(0, 0.8) && game.isFiring)
        #expect(controls.player.activeDevice?.id == DemoBotsInput.aimDevice)
        #expect(controls.prompt(for: DemoBotsInput.fire)?.label == "Aim + Debug")
        #expect(controls.prompt(for: DemoBotsInput.fire)?.symbolName == "bolt.fill")
    }

    @Test func retainedJoinPolicyAssignsNewControllersWithoutStealingClaimedOnes() throws {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let hub = PlayerInputHub()
        let other = hub.addPlayer(named: "Other")
        let claimed = InputDevice.controller(UUID())
        let unclaimed = InputDevice.controller(UUID())
        hub.connect(.init(id: claimed, name: "Claimed"))
        hub.connect(.init(id: unclaimed, name: "Unclaimed"))
        try hub.assign(claimed, to: other)
        let controls = DemoBotsInput(game: game, hub: hub)
        #expect(hub.owner(of: claimed) === other)
        #expect(hub.owner(of: unclaimed) === controls.player)
        let first = connectController(to: controls)
        let second = connectController(to: controls)
        #expect(hub.owner(of: first) === controls.player)
        #expect(hub.owner(of: second) === controls.player)
        try hub.assign(first, to: other)
        hub.connect(.init(id: first, name: "Remapped controller"))
        #expect(hub.owner(of: first) === other)
        hub.unassign(second)
        // Unassignment is deliberate; only a new connection should autojoin.
        #expect(hub.owner(of: second) == nil)
        hub.disconnect(second)
        hub.connect(.init(id: second, name: "Reconnected"))
        #expect(hub.owner(of: second) === controls.player)
    }

    @Test func controllerJoinAndMenuConfirmRequireNeutralBeforeFire() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        game.home()
        let controls = DemoBotsInput(game: game)
        controls.selectedLevel = 2
        let device = InputDevice.controller(UUID())
        controls.hub.connect(.init(id: device, name: "Held on connect"))
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(game.phase == .home)
        controls.hub.submit([(.gamepadButton(.south), .button(false))], device: device)
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(game.phase == .playing && game.levelNumber == 2 && !game.isFiring)
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(!game.isFiring)
        controls.hub.submit([(.gamepadButton(.south), .button(false))], device: device)
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(game.isFiring)
    }

    @Test func hubDisconnectPreservesVirtualMovementAndFire() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let device = connectController(to: controls)
        controls.moveStick([0.3, 0])
        controls.aimStick([0, 1], pressed: true)
        controls.hub.submit([(.gamepadAxis(.leftStick), .axis2D([-1, 0]))], device: device)
        #expect(game.moveInput == SIMD2<Float>(-1, 0))
        controls.hub.disconnect(device)
        #expect(game.moveInput == SIMD2<Float>(0.3, 0))
        #expect(game.aimInput == SIMD2<Float>(0, 1) && game.isFiring)
    }

    @Test func suspendPreservesAssignmentAndRequiresAControllerBaselineBeforeReuse() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let device = connectController(to: controls)
        controls.suspend()
        #expect(game.phase == .paused && game.moveInput == .zero && !game.isFiring)
        #expect(controls.hub.owner(of: device) === controls.player)
        controls.togglePause()
        #expect(game.phase == .playing)
        // Even a control absent from the pre-suspend sample must not turn a
        // held button on focus regain into a new fire press.
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(!game.isFiring && game.moveInput == .zero)
        controls.hub.submit([(.gamepadAxis(.leftStick), .axis2D(.zero)),
                             (.gamepadButton(.south), .button(false))], device: device)
        controls.hub.submit([(.gamepadAxis(.leftStick), .axis2D([1, 0])),
                             (.gamepadButton(.south), .button(true))], device: device)
        #expect(game.isFiring && game.moveInput == SIMD2<Float>(1, 0))
    }

    @Test func promptsFollowActiveDeviceRemappingAndMenuContext() {
        let (game, _, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let device = connectController(to: controls)
        #expect(controls.prompt(for: DemoBotsInput.fire)?.label == "A")
        #expect(controls.prompt(for: DemoBotsInput.fire)?.symbolName == "a.circle")
        #expect(controls.prompt(for: DemoBotsInput.pause)?.label == "Menu")
        controls.hub.connect(.init(id: device, name: "Remapped", presentations: [
            .gamepadButton(.south): .init(label: "Cross", symbolName: "xmark.circle"),
            .gamepadButton(.menu): .init(label: "Options"),
        ], hasRemappedElements: true))
        #expect(controls.prompt(for: DemoBotsInput.fire)?.label == "Cross")
        game.pause(); controls.synchronizeContext()
        #expect(controls.prompt(for: DemoBotsInput.fire) == nil)
        #expect(controls.prompt(for: DemoBotsInput.confirm)?.label == "Cross")
        controls.hub.submit([(.key("return"), .button(true))], device: .keyboard)
        #expect(game.phase == .playing && !game.isFiring)
        // A context transition may retain the previous active device; the next
        // meaningful keyboard action selects keyboard hints.
        controls.hub.submit([(.key("w"), .button(true))], device: .keyboard)
        #expect(controls.prompt(for: DemoBotsInput.fire)?.label == "F")
        #expect(controls.prompt(for: DemoBotsInput.pause)?.label == "P")
    }

    @Test func firstControllerPressCanProduceFeedbackInsideItsActionCallback() {
        let (game, _, player, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let recorder = FeedbackRecorder()
        #expect(controls.hub.attachBackend(owner: UUID(), feedbackProvider: recorder))
        let device = InputDevice.controller(UUID())
        controls.hub.connect(.init(id: device, name: "First press", supportsHaptics: true))
        controls.hub.submit([(.gamepadButton(.south), .button(false))], device: device)
        let token = controls.input.observe(action: DemoBotsInput.fire) { [weak controls] event in
            if event.phase == .pressed {
                game.damage(player, amount: 25)
                game.refreshHUD()
                controls?.synchronizeFeedback()
            }
        }
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(recorder.played.map(\.0) == [.impact])
        #expect(recorder.played.first?.1 == device)
        token.cancel()
    }

    @Test func repairsAndDamagePulseOnceWhileBeamDrainAndRechargeStaySilent() {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let recorder = FeedbackRecorder()
        #expect(controls.hub.attachBackend(owner: UUID(), feedbackProvider: recorder))
        let device = connectController(to: controls)
        game.cure(bot); game.refreshHUD(); controls.synchronizeFeedback()
        #expect(recorder.played.map(\.0) == [.selection])
        #expect(recorder.played.first?.1 == device)
        for _ in 0..<60 { controls.synchronizeFeedback() }
        game.beam.advance(pressed: true, deltaTime: 1)
        game.refreshHUD(); controls.synchronizeFeedback()
        #expect(recorder.played.count == 1)
        game.damage(player, amount: 100); game.refreshHUD(); controls.synchronizeFeedback()
        #expect(recorder.played.map(\.0) == [.selection, .impact])
        game.playerCharge.advance(0.25); game.refreshHUD(); controls.synchronizeFeedback()
        #expect(recorder.played.count == 2)
    }

    @Test(arguments: [false, true]) func terminalFeedbackTakesPrecedenceAndDoesNotRepeat(won: Bool) {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let recorder = FeedbackRecorder()
        #expect(controls.hub.attachBackend(owner: UUID(), feedbackProvider: recorder))
        _ = connectController(to: controls)
        if won { game.cure(bot) } else { game.damage(player, amount: 25) }
        game.finish(won: won)
        controls.synchronizeContext()
        for _ in 0..<60 { controls.synchronizeFeedback() }
        #expect(recorder.played.map(\.0) == [won ? .success : .failure])
        controls.start(level: 1)
        controls.synchronizeFeedback()
        #expect(recorder.played.count == 1)
    }

    @Test(arguments: ["pause", "inspect", "focus", "cancel"])
    func interruptionStopsFeedbackAndSuppressesStaleEvents(interruption: String) {
        let (game, _, player, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let recorder = FeedbackRecorder()
        #expect(controls.hub.attachBackend(owner: UUID(), feedbackProvider: recorder))
        let device = connectController(to: controls)
        game.damage(player, amount: 25); game.refreshHUD(); controls.synchronizeFeedback()
        #expect(recorder.played.count == 1)
        let stops = recorder.stopped.count
        switch interruption {
        case "pause": controls.togglePause()
        case "inspect": controls.toggleInspection()
        case "focus": controls.setInputActive(false)
        default: controls.hub.cancelAll()
        }
        #expect(recorder.stopped.count > stops)
        #expect(recorder.stopped.contains(device))
        controls.synchronizeFeedback()
        #expect(recorder.played.count == 1)
        if interruption == "inspect" {
            game.playerCharge.invulnerability = 0
            game.damage(player, amount: 25); game.refreshHUD(); controls.synchronizeFeedback()
            game.finish(won: false); controls.synchronizeContext()
            #expect(recorder.played.count == 1)
        }
        if interruption == "focus" {
            game.playerCharge.invulnerability = 0
            game.damage(player, amount: 25); game.refreshHUD()
            controls.setInputActive(true)
            controls.synchronizeFeedback()
            #expect(recorder.played.count == 1)
        }
    }

    @Test func checkpointRestoreRetainsOwnershipAndResetsHeldInputAndFeedback() throws {
        let game = DemoBotsSession()
        let world = World()
        game.attach(to: world)
        game.soundEnabled = false
        game.start()
        let controls = DemoBotsInput(game: game)
        let recorder = FeedbackRecorder()
        #expect(controls.hub.attachBackend(owner: UUID(), feedbackProvider: recorder))
        let device = connectController(to: controls)
        game.damage(try #require(game.player), amount: 25)
        game.refreshHUD(); controls.synchronizeFeedback()
        let checkpoint = try game.checkpointData()
        game.playerCharge = PlayerCharge()
        game.refreshHUD(); controls.synchronizeFeedback()
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(game.isFiring)
        let input = controls.input
        try game.restoreCheckpoint(data: checkpoint)
        controls.synchronizeContext()
        controls.synchronizeFeedback()
        #expect(game.phase == .paused && !game.isFiring)
        #expect(controls.input === input && controls.hub.owner(of: device) === controls.player)
        #expect(recorder.played.map(\.0) == [.impact])
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(game.phase == .paused)
        controls.hub.submit([(.gamepadButton(.south), .button(false))], device: device)
        controls.hub.submit([(.gamepadButton(.south), .button(true))], device: device)
        #expect(game.phase == .playing && !game.isFiring)
        controls.synchronizeFeedback()
        #expect(recorder.played.count == 1)
    }

    @Test(arguments: ["keyboard", "touch", "unsupported"])
    func feedbackNeverVibratesAnInactiveOrUnsupportedController(source: String) {
        let (game, _, player, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let recorder = FeedbackRecorder()
        #expect(controls.hub.attachBackend(owner: UUID(), feedbackProvider: recorder))
        _ = connectController(to: controls, haptics: source != "unsupported")
        if source == "keyboard" {
            controls.hub.submit([(.key("w"), .button(true))], device: .keyboard)
        } else if source == "touch" { controls.moveStick([0, 1]) }
        game.damage(player, amount: 25); game.refreshHUD(); controls.synchronizeFeedback()
        #expect(recorder.played.isEmpty)
    }
}
