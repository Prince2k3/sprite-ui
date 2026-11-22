import Foundation
import SpriteUI
import Testing
@testable import DemoBotsGame

@Suite struct DemoBotsMechanicsTests {
    @Test func beamHasAForcedCooldownEvenWhileHeld() {
        var beam = DebugBeam()
        beam.advance(pressed: true, deltaTime: 1)
        #expect(beam.active && beam.remaining == 1)
        beam.advance(pressed: true, deltaTime: 1)
        #expect(!beam.active && beam.cooling)
        beam.advance(pressed: true, deltaTime: 0.5)
        #expect(!beam.active && beam.remaining == 1)
        beam.advance(pressed: true, deltaTime: 0.5)
        #expect(!beam.cooling && beam.remaining == 2)
        beam.advance(pressed: true, deltaTime: 0.1)
        #expect(beam.active)
    }

    @Test func damageHasInvulnerabilityAndAutomaticRecovery() {
        var charge = PlayerCharge()
        let firstHit = charge.hit(25)
        #expect(firstHit)
        let repeatedHit = charge.hit(25)
        #expect(!repeatedHit)
        #expect(charge.value == 75)
        charge.advance(1)
        let fatalHit = charge.hit(100)
        #expect(fatalHit)
        #expect(charge.recharging)
        let protectedHit = charge.hit(100)
        #expect(!protectedHit)
        charge.advance(3)
        #expect(charge.value == 100 && !charge.recharging)
    }

    @Test func ruleSystemChoosesPatrolHuntAndFlee() {
        #expect(BotBrain.intent(for: .init(bad: true, corruption: 100, threatDistance: .infinity, targetDistance: 80)) == .hunt)
        #expect(BotBrain.intent(for: .init(bad: false, corruption: 0, threatDistance: 20, targetDistance: 80)) == .flee)
        #expect(BotBrain.intent(for: .init(bad: true, corruption: 20, threatDistance: 100, targetDistance: 80)) == .flee)
        #expect(BotBrain.intent(for: .init(bad: false, corruption: 0, threatDistance: 900, targetDistance: 80)) == .patrol)
    }

    @Test func originalConfigurationsAndAnimationFramesAreAvailable() throws {
        for level in 1...3 {
            let config = try BotLevelConfiguration.load(level)
            #expect(config.timeLimit > 0)
            #expect(config.taskBotConfigurations.contains { $0.startsBad })
            #expect(config.taskBotConfigurations.allSatisfy { !$0.goodPathNodeNames.isEmpty && !$0.badPathNodeNames.isEmpty })
        }
        #expect(try BotLevelConfiguration.load(1).taskBotConfigurations.count == 6)
        #expect(try BotLevelConfiguration.load(2).taskBotConfigurations.contains { $0.locomotion == .flying })
        for prefix in ["PlayerBotIdle", "PlayerBotWalk", "GroundBotBadWalk", "GroundBotGoodWalk", "FlyingBotBadWalk", "FlyingBotGoodWalk"] {
            #expect(DemoBotsResources.animations[prefix]?.count == 16)
        }
    }

    @Test func navigationRoutesAroundWallsAndPreventsTunneling() {
        let wall = PolygonObstacle(BoundingBox(min: [90, 40], max: [110, 200]))
        let navigation = BotNavigation(bounds: BoundingBox(min: .zero, max: [400, 400]), obstacles: [wall], radius: 15)
        let route = navigation.path(from: [40, 120], to: [200, 120])
        #expect(route.count > 2)
        for (a, b) in zip(route, route.dropFirst()) { #expect(navigation.isClear(from: a, to: b)) }
        let result = navigation.move(from: [40, 120], toward: [240, 120], radius: 15)
        #expect(result.x < 76)
        #expect(wall.signedDistance(to: result) >= 14.9)
    }
}

@MainActor @Suite(.serialized) struct DemoBotsIntegrationTests {
    func fixture() -> (DemoBotsSession, World, Entity, Entity) {
        let world = World()
        let game = DemoBotsSession()
        game.attach(to: world)
        game.soundEnabled = false
        game.start()
        // Keep the actual game's systems and match state, replacing only its
        // scenery and actors with a small, deterministic test arena.
        for entity in world.entities { entity.removeFromParent() }
        game.navigation = BotNavigation(bounds: BoundingBox(min: [-500, -500], max: [500, 500]), obstacles: [])
        let player = game.makeBot(kind: .player, at: .zero, heading: 0)
        player.enter(BotMode.active)
        let bot = game.makeBot(kind: .ground, at: [150, 0], heading: .pi)
        bot.components[BotComponent.self]?.isBad = true
        bot.components[BotComponent.self]?.corruption = 100
        bot.enter(BotMode.patrol)
        game.player = player; game.bots = [bot]; game.camera = nil; game.beamLines = []
        return (game, world, player, bot)
    }

    @Test func allThreeOriginalScenesLoadWithTheirPatrolMarkers() {
        let game = DemoBotsSession(); let world = World(); game.attach(to: world)
        for level in 1...3 {
            game.start(level: level)
            #expect(game.phase == .playing)
            #expect(game.player != nil)
            #expect(game.bots.count == game.totalBots)
            #expect(game.badBots > 0)
            #expect(game.navigation?.obstacles.isEmpty == false)
            #expect(game.bots.allSatisfy { $0.components[BotComponent.self]?.patrol.isEmpty == false })
        }
    }

    @Test func beamCuresABotAndCompletesTheLevel() {
        let (game, _, _, bot) = fixture()
        game.isFiring = true
        for _ in 0..<90 { game.beam.advance(pressed: true, deltaTime: 1 / 60); game.applyBeam(deltaTime: 1 / 60) }
        #expect(bot.components[BotComponent.self]?.isBad == false)
        game.afterSteering(deltaTime: 0)
        #expect(game.phase == .won)
    }

    @Test func beamIsVisibleFromTheOriginalSpawn() {
        let world = World(); let game = DemoBotsSession(); game.attach(to: world)
        game.start(level: 2)
        game.aim([0, -1], firing: true)
        for _ in 0..<20 { world.update(deltaTime: 1 / 60) }
        let lengths = game.beamLines.map { $0.components[SpriteComponent.self]?.size?.x ?? 0 }
        #expect(lengths.reduce(0, +) > 100)
    }

    @Test func beamCannotPassThroughAWallOrShootBehindItsAim() {
        let (game, world, player, bot) = fixture()
        game.beam.active = true
        let wall = Entity(components: CollisionComponent(shape: .rectangle(size: [15, 200]), filter: .init(group: BotCollisionGroups.walls)))
        wall.position = [75, 0]; world.addEntity(wall)
        #expect(!game.hasLineOfSight(from: player.position, to: bot.position))
        game.applyBeam(deltaTime: 1)
        #expect(bot.components[BotComponent.self]?.corruption == 100)
        wall.removeFromParent()
        #expect(game.hasLineOfSight(from: player.position, to: bot.position))
        player.components[BotComponent.self]?.heading = .pi
        game.applyBeam(deltaTime: 1)
        #expect(bot.components[BotComponent.self]?.corruption == 100)
    }

    @Test func emptyBeamStopsAtTheExactSceneQueryHit() {
        let (game, world, _, bot) = fixture()
        let wall = Entity(components: CollisionComponent(shape: .rectangle(size: [2, 200]), filter: .init(group: BotCollisionGroups.walls)))
        wall.position = [75, 0]; world.addEntity(wall)
        game.beamLines = (0..<4).map { _ in
            let line = Entity(components: SpriteComponent(color: .cyan, size: [1, 1]))
            world.addEntity(line); return line
        }
        game.beam.active = true
        game.applyBeam(deltaTime: 0.1)
        let last = game.beamLines[2]
        let length = last.components[SpriteComponent.self]!.size!.x
        let end = last.position + SIMD2<Float>(cos(last.rotation), sin(last.rotation)) * length / 2
        #expect(abs(end.x - 74) < 0.001 && abs(end.y - 60) < 0.001)
        #expect(bot.components[BotComponent.self]?.corruption == 100)
    }

    @Test func botsCanInfectAndFlyingCuresPropagate() {
        let (game, _, _, bot) = fixture()
        game.cure(bot)
        game.damage(bot, amount: 25)
        #expect(bot.components[BotComponent.self]?.isBad == false)
        game.damage(bot, amount: 25)
        #expect(bot.components[BotComponent.self]?.isBad == true)
        let flying = game.makeBot(kind: .flying, at: [200, 0], heading: 0)
        flying.components[BotComponent.self]?.isBad = true
        game.bots.append(flying)
        game.cure(flying)
        #expect(game.bots.allSatisfy { $0.components[BotComponent.self]?.isBad == false })
    }

    @Test func playerRechargesAndIsProtectedFromRepeatedDamage() {
        let (game, _, player, _) = fixture()
        game.damage(player, amount: 100)
        #expect(game.playerCharge.recharging)
        game.damage(player, amount: 100)
        game.playerCharge.advance(3)
        #expect(game.playerCharge.value == 100)
    }

    @Test func pausedMatchesFreezeTimeAndMotionAndCanResume() {
        let (game, world, player, _) = fixture()
        game.move([1, 0])
        world.update(deltaTime: 1 / 60)
        game.pause()
        #expect(world.isPaused)
        let effect = Entity(components: LifetimeComponent(0.1))
        world.addEntity(effect)
        let time = game.remainingTime; let position = player.position
        let stateTime = player.timeInState(BotMode.self)
        for _ in 0..<60 { world.update(deltaTime: 1 / 60) }
        #expect(game.remainingTime == time)
        #expect(player.position == position)
        #expect(player.timeInState(BotMode.self) == stateTime)
        #expect(effect.world === world)
        game.resume(); game.move([1, 0])
        for _ in 0..<15 { world.update(deltaTime: 1 / 60) }
        #expect(!world.isPaused)
        #expect(effect.world == nil)
        #expect(game.remainingTime < time)
        #expect(player.position.x > position.x)
    }

    @Test func timeExpiryLosesAndRestartResetsMatch() {
        let (game, _, _, _) = fixture()
        game.remainingTime = 0.001
        game.beforeSteering(deltaTime: 0.02)
        #expect(game.phase == .lost)
        game.start(level: 1)
        #expect(game.phase == .playing)
        #expect(game.secondsLeft == 180)
        #expect(game.charge == 100)
        #expect(game.beamFraction == 1)
    }
}
