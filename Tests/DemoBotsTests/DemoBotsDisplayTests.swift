import SpriteUI
import Testing
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsDisplayTests {
    @Test func defaultsDoNotRequestPresentationOrPublishStatistics() {
        let settings = DemoBotsDisplaySettings()
        #expect(settings.quality == .balanced)
        #expect(!settings.showsPreview && !settings.externalEnabled && !settings.externalAvailable)
        #expect(settings.presentation == nil)
        #expect(settings.monitor.latest == nil)
        #expect(!settings.source.isAvailable && settings.source.frameNumber == 0)
        #expect(settings.source.viewportID == DemoBotsSurfaceLayout.viewportID)
    }

    @Test(arguments: DemoBotsDisplaySettings.Quality.allCases)
    func qualityPresetsHaveExplicitPressureAdaptiveLimits(quality: DemoBotsDisplaySettings.Quality) {
        let settings = DemoBotsDisplaySettings()
        settings.quality = quality
        let expected: GameRenderConfiguration
        switch quality {
        case .balanced:
            expected = .init(resolutionScale: 1, preferredFramesPerSecond: 60,
                             maximumRenderPixels: 16_777_216, adaptsToSystemPressure: true)
        case .batterySaver:
            expected = .init(resolutionScale: 0.75, preferredFramesPerSecond: 30,
                             maximumRenderPixels: 8_388_608, adaptsToSystemPressure: true)
        case .highRefresh:
            expected = .init(resolutionScale: 1, preferredFramesPerSecond: 120,
                             maximumRenderPixels: 16_777_216, adaptsToSystemPressure: true)
        }
        #expect(settings.configuration == expected)
        #expect(settings.configuration.resolved(in: .init()) == expected)
    }

    @Test func togglesShareOneExclusiveViewportSourceAndRetainState() {
        let settings = DemoBotsDisplaySettings(), other = DemoBotsDisplaySettings()
        let source = settings.source, monitor = settings.monitor
        #expect(source !== other.source && monitor !== other.monitor)
        for quality in DemoBotsDisplaySettings.Quality.allCases {
            settings.quality = quality
            let configuration = settings.configuration
            for (preview, external) in [(true, false), (true, true), (false, true), (false, false)] {
                settings.showsPreview = preview
                settings.externalEnabled = external
                for available in [true, false] {
                    settings.externalAvailable = available
                    #expect(settings.presentation === ((preview || external) ? source : nil))
                    #expect(settings.source === source && settings.monitor === monitor)
                    #expect(settings.configuration == configuration && settings.quality == quality)
                    #expect(source.viewportID == DemoBotsSurfaceLayout.viewportID)
                    #expect(!source.isAvailable && source.frameNumber == 0 && monitor.latest == nil)
                    #expect(other.presentation == nil && other.quality == .balanced)
                }
            }
        }
    }

    @Test(arguments: DemoBotsDisplaySettings.Quality.allCases)
    func pressureResolutionOnlyLowersSelectedCaps(quality: DemoBotsDisplaySettings.Quality) {
        let settings = DemoBotsDisplaySettings()
        settings.quality = quality
        let requested = settings.configuration
        for (thermal, scaleCap, fpsCap) in [
            (GameRenderEnvironment.ThermalState.nominal, 1.0, 240),
            (.fair, 1.0, 240), (.serious, 0.75, 30), (.critical, 0.5, 20),
        ] {
            for lowPower in [false, true] {
                let environment = GameRenderEnvironment(thermalState: thermal, isLowPowerModeEnabled: lowPower)
                let resolved = requested.resolved(in: environment)
                #expect(resolved.resolutionScale == min(requested.resolutionScale, scaleCap))
                #expect(resolved.preferredFramesPerSecond == min(requested.preferredFramesPerSecond,
                                                               lowPower ? min(fpsCap, 30) : fpsCap))
                #expect(resolved.maximumRenderPixels == requested.maximumRenderPixels)
                #expect(resolved.maximumTextureDimension == requested.maximumTextureDimension)
                #expect(resolved.adaptsToSystemPressure)
                #expect(resolved.resolved(in: environment) == resolved)
                #expect(settings.configuration == requested)
            }
        }
    }

    @Test(arguments: [false, true])
    func overlayDeactivationCancelsActionsAndRetainsSessionUntilNeutral(direct: Bool) {
        let (game, world, player, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        let hub = controls.hub, session = controls.player, input = controls.input
        let phase = game.phase, remaining = game.remainingTime, paused = world.isPaused
        let timeScale = world.timeScale, revision = controls.surfaceInputRevision
        let contexts = input.contexts
        func send(_ values: [(InputControl, InputValue)]) {
            if direct { input.setValues(values, device: .keyboard) }
            else { hub.submit(values, device: .keyboard) }
        }
        send([(.key("w"), .button(true)), (.key("f"), .button(true))])
        #expect(game.moveInput == SIMD2<Float>(0, 1) && game.isFiring)
        controls.setInputActive(false)
        #expect(!session.isEnabled)
        #expect(game.moveInput == .zero && !game.isFiring)
        // Fresh controls arriving before SwiftUI updates the native scope must also be gated.
        send([(.key("d"), .button(true)), (.key("space"), .button(true))])
        #expect(input.value(for: DemoBotsInput.move).vector == .zero)
        #expect(!input.value(for: DemoBotsInput.fire).isPressed)
        #expect(game.moveInput == .zero && !game.isFiring)
        controls.setInputActive(true)
        send([(.key("w"), .button(true)), (.key("f"), .button(true)),
              (.key("d"), .button(true)), (.key("space"), .button(true))])
        #expect(session.isEnabled && game.moveInput == .zero && !game.isFiring)
        #expect(input.value(for: DemoBotsInput.move).vector == .zero)
        #expect(!input.value(for: DemoBotsInput.fire).isPressed)
        send([(.key("w"), .button(false)), (.key("f"), .button(false)),
              (.key("d"), .button(false)), (.key("space"), .button(false))])
        send([(.key("w"), .button(true)), (.key("f"), .button(true))])
        #expect(game.moveInput == SIMD2<Float>(0, 1) && game.isFiring)
        #expect(controls.hub === hub && controls.player === session && controls.input === input)
        #expect(hub.isEnabled && hub.players.count == 1)
        for device in [InputDevice.keyboard, .pointer, DemoBotsInput.moveDevice,
                       DemoBotsInput.aimDevice, DemoBotsInput.hudDevice] {
            #expect(hub.owner(of: device) === session)
        }
        #expect(game.world === world && game.player === player)
        #expect(game.phase == phase && game.remainingTime == remaining)
        #expect(world.isPaused == paused && world.timeScale == timeScale)
        #expect(input.contexts == contexts && controls.surfaceInputRevision == revision)
    }

    @Test(arguments: [false, true])
    func overlayBlocksFreshHomeSelectionAndConfirmUntilRelease(direct: Bool) {
        let game = DemoBotsSession(), controls = DemoBotsInput(game: game)
        let input = controls.input
        func send(_ values: [(InputControl, InputValue)]) {
            if direct { input.setValues(values, device: .keyboard) }
            else { controls.hub.submit(values, device: .keyboard) }
        }
        controls.setInputActive(false)
        send([(.key("right"), .button(true)), (.key("return"), .button(true))])
        #expect(game.phase == .home && controls.selectedLevel == 1)
        #expect(input.value(for: DemoBotsInput.selectLevel).scalar == 0)
        #expect(!input.value(for: DemoBotsInput.confirm).isPressed)
        controls.setInputActive(true)
        send([(.key("right"), .button(true)), (.key("return"), .button(true))])
        #expect(game.phase == .home && controls.selectedLevel == 1)
        #expect(input.value(for: DemoBotsInput.selectLevel).scalar == 0)
        #expect(!input.value(for: DemoBotsInput.confirm).isPressed)
        send([(.key("right"), .button(false)), (.key("return"), .button(false))])
        send([(.key("right"), .button(true))])
        #expect(game.phase == .home && controls.selectedLevel == 2)
    }

    @Test(arguments: [false, true])
    func overlayBlocksPauseMenuConfirmUntilNeutral(direct: Bool) {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        let controls = DemoBotsInput(game: game)
        controls.togglePause()
        #expect(game.phase == .paused && world.isPaused)
        func confirm(_ pressed: Bool) {
            if direct { controls.input.setValue(.button(pressed), for: .key("return"), device: .keyboard) }
            else { controls.hub.submit([(.key("return"), .button(pressed))], device: .keyboard) }
        }
        controls.setInputActive(false)
        confirm(true)
        #expect(!controls.input.value(for: DemoBotsInput.confirm).isPressed)
        #expect(game.phase == .paused && world.isPaused)
        controls.setInputActive(true)
        confirm(true)
        #expect(!controls.input.value(for: DemoBotsInput.confirm).isPressed)
        #expect(game.phase == .paused && world.isPaused)
        confirm(false)
        confirm(true)
        #expect(game.phase == .playing && !world.isPaused)
    }
}
