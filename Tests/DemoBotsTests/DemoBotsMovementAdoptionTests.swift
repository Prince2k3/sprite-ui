import SpriteUI
import Testing
import simd
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsMovementAdoptionTests {
    @Test func botAdvancesPastTheFirstCornerToItsDestination() {
        let (game, world, player, bot) = DemoBotsIntegrationTests().fixture()
        player.position = [-400, -400]
        bot.position = [0, 0]
        let goal = SIMD2<Float>(220, 180)
        bot.components[BotComponent.self]?.route = [[0, 0], [100, 0], [100, 180], goal]
        bot.components[BotComponent.self]?.decisionDelay = 60
        bot.components[BotComponent.self]?.attackCooldown = 60
        bot.components[SteeringComponent.self]?.maxSpeed = 100
        bot.components[SteeringComponent.self]?.maxForce = 1000
        bot.components[SteeringComponent.self]?.goals = [.group("navigation", [])]
        for _ in 0..<900 { world.update(deltaTime: 1 / 60) }
        #expect(game.phase == .playing)
        #expect(simd_distance(bot.position, goal) < 10)
        #expect(bot.components[BotComponent.self]?.route.count == 1)
    }

    @Test func cornersAreNotSkippedUntilTheFollowingLegIsClear() {
        let game = DemoBotsSession()
        let wall = PolygonObstacle(BoundingBox(min: [90, 80], max: [110, 240]))
        let navigation = BotNavigation(bounds: BoundingBox(min: .zero, max: [400, 400]), obstacles: [wall])
        var route: [SIMD2<Float>] = [[64, 54], [136, 54], [200, 160]]
        #expect(navigation.isWalkable([58, 60]))
        #expect(!navigation.isClear(from: [58, 60], to: route[1]))
        game.advanceRoute(&route, from: [58, 60], navigation: navigation)
        #expect(route.count == 3)
        game.advanceRoute(&route, from: [64, 54], navigation: navigation)
        #expect(route == [[136, 54], [200, 160]])
    }

    @Test func controlledActorCompletesATightRouteAroundAWall() {
        let (game, world, player, bot) = DemoBotsIntegrationTests().fixture()
        let box = BoundingBox(min: SIMD2<Float>.zero, max: [400, 400])
        let wallBox = BoundingBox(min: [90, 80], max: [110, 240])
        let wall = Entity(components: CollisionComponent(shape: .rectangle(size: wallBox.size), filter: .init(group: BotCollisionGroups.walls)))
        wall.position = wallBox.center; world.addEntity(wall)
        let navigation = BotNavigation(bounds: box, obstacles: [PolygonObstacle(wallBox)])
        game.navigation = navigation; player.position = [350, 350]; bot.position = [40, 160]
        let goal = SIMD2<Float>(200, 160)
        bot.components[BotComponent.self]?.route = navigation.path(from: bot.position, to: goal)
        bot.components[BotComponent.self]?.decisionDelay = 60
        bot.components[BotComponent.self]?.attackCooldown = 60
        bot.components[SteeringComponent.self]?.maxSpeed = 100
        bot.components[SteeringComponent.self]?.maxForce = 1000
        bot.components[SteeringComponent.self]?.goals = [.group("navigation", [])]
        for _ in 0..<900 { world.update(deltaTime: 1 / 60) }
        #expect(simd_distance(bot.position, goal) < 10)
        #expect(game.phase == .playing)
    }

    @Test func tinyPlannerMarginRecoveryUsesTheCharacterSweep() {
        let (game, world, player, _) = DemoBotsIntegrationTests().fixture()
        let wallBox = BoundingBox(min: [59, -100], max: [61, 100])
        let wall = Entity(components: CollisionComponent(shape: .rectangle(size: wallBox.size), filter: .init(group: BotCollisionGroups.walls)))
        wall.position = wallBox.center; world.addEntity(wall)
        let navigation = BotNavigation(bounds: BoundingBox(min: [-500, -500], max: [500, 500]), obstacles: [PolygonObstacle(wallBox)])
        player.position = [33.99, 0]
        #expect(!navigation.isWalkable(player.scenePosition))
        #expect(game.recoverNavigationStart(player, navigation: navigation))
        #expect(navigation.isWalkable(player.scenePosition))
        #expect(simd_distance(player.scenePosition, [33.99, 0]) < 2)
        #expect(!navigation.path(from: player.scenePosition, to: [-100, 0]).isEmpty)
        player.position = [60, 0]
        #expect(!game.recoverNavigationStart(player, navigation: navigation))
        #expect(player.position == SIMD2<Float>(60, 0))
    }

    @Test func restartingInstantiatesAnUnmodifiedCachedLevel() throws {
        let game = DemoBotsSession(), world = World(); game.attach(to: world); game.start()
        let level = try #require(world.entities.first { $0.components.has(SceneComponent.self) })
        let marker = try #require(level.findEntity(named: "transporter_coordinate"))
        let point = marker.position
        marker.position += [200, 300]; level.isEnabled = false
        game.start()
        let replacement = try #require(world.entities.first { $0.components.has(SceneComponent.self) })
        #expect(replacement !== level && replacement.id != level.id)
        #expect(replacement.isEnabled && level.world == nil)
        #expect(replacement.findEntity(named: "transporter_coordinate")?.position == point)
        #expect(game.player?.position == point)
        #expect(game.phase == .playing)
    }

    @Test func scaledSimulationTimeIsSharedWithSteeringAndStateMachines() {
        let (game, world, player, bot) = DemoBotsIntegrationTests().fixture()
        world.timeScale = 3
        game.playerCharge.invulnerability = 0.75
        bot.components[BotComponent.self]?.attackCooldown = 2
        let time = game.remainingTime
        let stateTime = player.timeInState(BotMode.self)
        world.update(deltaTime: 0.04)
        #expect(abs(game.remainingTime - (time - 0.12)) < 0.00001)
        #expect(abs(game.playerCharge.invulnerability - 0.63) < 0.00001)
        #expect(abs(bot.components[BotComponent.self]!.attackCooldown - 1.88) < 0.00001)
        #expect(abs(player.timeInState(BotMode.self) - stateTime - 0.12) < 0.00001)
    }
}
