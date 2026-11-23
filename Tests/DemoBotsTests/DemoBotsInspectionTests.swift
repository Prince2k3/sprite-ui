@_spi(Backend) import ECSCore
import Foundation
import SpriteUI
import Testing
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsInspectionTests {
    @Test func closingInspectionCancelsQueuedAndPrimingFramesImmediately() throws {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        let renderer = SpriteRenderer(world: world)
        game.renderer = renderer
        game.pause(); game.beginInspection()
        let debug = SceneDebugController(options: [.statistics, .simulationControls])
        renderer.setDebugController(debug)
        renderer.update(0); renderer.didFinishUpdate()
        #expect(debug.stepFrame())
        renderer.update(0.02); renderer.didFinishUpdate() // Prime, without advancing match logic.
        #expect(debug.isStepPending && !world.isDebugStepping)
        let remaining = game.remainingTime
        game.endInspection()
        #expect(!debug.isAttached && !debug.isStepPending && renderer.debugController == nil)
        renderer.update(0.04); renderer.didSimulatePhysics(); renderer.didFinishUpdate()
        #expect(game.phase == .paused && world.isPaused)
        #expect(game.remainingTime == remaining && !world.isDebugStepping)
    }

    @Test(arguments: [(false, false), (false, true), (true, true)])
    func inspectionRestoresMatchPhasePauseAndRate(pauseMenu: Bool, wasPaused: Bool) {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        if pauseMenu { game.pause() }
        world.isPaused = wasPaused
        world.timeScale = 0.5

        game.beginInspection()
        #expect(game.isInspecting && game.phase == .playing && world.isPaused)
        world.timeScale = 0
        // Reopening must not overwrite the original saved state.
        game.beginInspection()
        world.isPaused = false
        game.endInspection()

        #expect(!game.isInspecting)
        #expect(game.phase == (pauseMenu ? .paused : .playing))
        #expect(world.isPaused == wasPaused)
        #expect(world.timeScale == 0.5)
        game.endInspection()
        #expect(world.isPaused == wasPaused && world.timeScale == 0.5)
    }

    @Test func inspectionClearsHeldInputAndRoutesButPreservesBotSteering() throws {
        let (game, world, player, bot) = DemoBotsIntegrationTests().fixture()
        game.renderer = SpriteRenderer(world: world, size: CGSize(width: 400, height: 400))
        game.move([1, 0])
        game.aim([0, 1], firing: true)
        // Establish a real, valid touch route before testing its suppression.
        game.sendPlayer(toView: CGPoint(x: 300, y: 200))
        #expect(game.destination == SIMD2<Float>(100, 0))
        #expect(!game.playerRoute.isEmpty)
        player.components[SteeringComponent.self]?.velocity = [80, 0]
        player.components[SteeringComponent.self]?.goals = [SteeringGoal(.seek(.point([100, 0])))]
        bot.components[SteeringComponent.self]?.velocity = [-40, 0]
        bot.components[SteeringComponent.self]?.goals = [SteeringGoal(.seek(.point([-100, 0])))]
        bot.components[BotComponent.self]?.route = [[150, 0], [-100, 0]]
        bot.components[BotComponent.self]?.decisionDelay = 10
        let botSteering = try #require(bot.components[SteeringComponent.self])
        let botRoute = try #require(bot.components[BotComponent.self]).route
        let beamLine = Entity(components: SpriteComponent(color: .cyan, size: [20, 3]))
        world.addEntity(beamLine)
        game.beamLines = [beamLine]

        game.beginInspection()
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        #expect(game.destination == nil && game.playerRoute.isEmpty)
        #expect(player.components[SteeringComponent.self]?.velocity == .zero)
        #expect(player.components[SteeringComponent.self]?.goals.isEmpty == true)
        #expect(beamLine.components[SpriteComponent.self]?.opacity == 0)
        #expect(bot.components[SteeringComponent.self] == botSteering)
        #expect(bot.components[BotComponent.self]?.route == botRoute)
        #expect(bot.components[BotComponent.self]?.decisionDelay == 0)

        game.move([-1, 0])
        game.aim([1, 0], firing: true)
        game.sendPlayer(toView: CGPoint(x: 100, y: 200))
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        #expect(game.destination == nil && game.playerRoute.isEmpty)
        game.endInspection()
        let position = player.position
        world.update(deltaTime: 1 / 60)
        #expect(player.position == position)
        #expect(game.moveInput == .zero && game.aimInput == .zero && !game.isFiring)
        #expect(!game.beam.active)
    }

    @Test(arguments: [0.0, 0.25, 3.0])
    func pauseMenuInspectionFreezesUntilACompleteDebugFrame(scale: Double) throws {
        let (game, world, player, bot) = DemoBotsIntegrationTests().fixture()
        game.pause()
        world.timeScale = scale
        game.beginInspection()
        let time = game.remainingTime
        let playerPosition = player.position
        let botPosition = bot.position
        let stateTime = player.timeInState(BotMode.self)
        let effect = Entity(components: LifetimeComponent(0.005))
        world.addEntity(effect)
        for _ in 0..<30 { world.update(deltaTime: 1 / 60) }
        #expect(game.remainingTime == time && player.position == playerPosition)
        #expect(bot.position == botPosition && player.timeInState(BotMode.self) == stateTime)
        #expect(effect.world === world)

        let frame = try #require(world.beginFrame(deltaTime: 1 / 60, debugStep: true))
        world.finishFrame(frame)
        #expect(abs(game.remainingTime - (time - 1 / 60)) < 0.00001)
        #expect(player.timeInState(BotMode.self) > stateTime)
        #expect(bot.state(BotMode.self) == .hunt && bot.position.x < botPosition.x)
        #expect(bot.components[BotComponent.self]?.decisionDelay == 0.3)
        #expect(effect.world == nil)
        #expect(player.position == playerPosition)
        #expect(game.phase == .playing && world.isPaused && !world.isDebugStepping)
        #expect(world.timeScale == scale)
        game.endInspection()
        #expect(game.phase == .paused && world.isPaused && world.timeScale == scale)
    }

    @Test(arguments: [false, true])
    func terminalDebugFrameSurvivesClosingInspection(won: Bool) throws {
        let (game, world, _, bot) = DemoBotsIntegrationTests().fixture()
        game.pause()
        world.timeScale = 0.5
        game.beginInspection()
        world.timeScale = 0
        if won { game.cure(bot) }
        else { game.remainingTime = 0.001 }

        let frame = try #require(world.beginFrame(deltaTime: 1 / 60, debugStep: true))
        world.finishFrame(frame)
        let terminal: DemoBotsPhase = won ? .won : .lost
        #expect(game.phase == terminal && world.isPaused)
        let message = game.message
        game.endInspection()
        #expect(!game.isInspecting && game.phase == terminal)
        #expect(world.isPaused && world.timeScale == 0.5)
        #expect(game.message == message)
        game.beginInspection()
        #expect(!game.isInspecting && game.phase == terminal)
    }

    @Test(arguments: ["pause", "home", "restart"])
    func matchActionsCancelInspectionAndRestoreRate(action: String) {
        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        world.timeScale = 0.5
        game.beginInspection()
        world.timeScale = 3
        world.isPaused = false
        switch action {
        case "pause": game.pause() // The same action used when the app backgrounds.
        case "home": game.home()
        default: game.start(level: 2)
        }
        #expect(!game.isInspecting && world.timeScale == 0.5)
        switch action {
        case "pause":
            #expect(game.phase == .paused && world.isPaused)
            game.resume()
            #expect(game.phase == .playing && !world.isPaused)
        case "home": #expect(game.phase == .home && world.isPaused)
        default:
            #expect(game.phase == .playing && !world.isPaused)
            #expect(game.levelNumber == 2 && game.bots.count == game.totalBots)
        }
        // A later tools dismissal must not resurrect the old match or settings.
        let phase = game.phase
        let paused = world.isPaused
        game.endInspection()
        #expect(game.phase == phase && world.isPaused == paused && world.timeScale == 0.5)
    }

    @Test func inspectionRejectsHomeUnattachedAndLoadingSessions() async throws {
        let unattached = DemoBotsSession()
        unattached.start()
        unattached.beginInspection()
        #expect(!unattached.isInspecting && unattached.phase == .home)

        let (game, world, _, _) = DemoBotsIntegrationTests().fixture()
        game.home()
        world.timeScale = 0.25
        game.beginInspection()
        #expect(!game.isInspecting && game.phase == .home)
        #expect(world.isPaused && world.timeScale == 0.25)

        game.start()
        let loading = Task { @MainActor in await game.prepareResources() }
        // Observe the real async preload rather than exposing a mutable loading flag.
        for _ in 0..<100 {
            if game.isLoadingResources { break }
            await Task.yield()
        }
        let observedLoading = game.isLoadingResources
        game.beginInspection()
        let enteredWhileLoading = game.isInspecting
        let pausedWhileLoading = world.isPaused
        await loading.value
        #expect(observedLoading)
        #expect(!enteredWhileLoading && !pausedWhileLoading)
        #expect(game.phase == .playing && !game.isLoadingResources)
    }
}
