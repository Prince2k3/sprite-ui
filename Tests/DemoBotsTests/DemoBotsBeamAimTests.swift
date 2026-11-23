import SpriteUI
import Testing
import simd
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsBeamAimTests {
    private func endpoint(_ game: DemoBotsSession) throws -> SIMD2<Float> {
        let line = try #require(game.beamLines.first)
        let shape = try #require(line.components[ShapeComponent.self])
        guard case .path(let path) = shape.geometry, case .line(let end) = path.elements.last else {
            Issue.record("Expected a beam endpoint")
            return .zero
        }
        return end
    }

    @Test func assistedShotHitsNearbyWithoutReplacingFacingAndFallsBackWhenTargetLeaves() throws {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        bot.position = [120, 35]
        game.aim(.zero, firing: true)
        game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == bot.id)
        #expect(bot.components[BotComponent.self]!.corruption < 100)
        #expect(player.components[BotComponent.self]?.heading == 0)
        #expect(try endpoint(game) == bot.position + SIMD2<Float>(0, 50))

        bot.position = [400, 0]
        game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == nil)
        #expect(player.components[BotComponent.self]?.heading == 0)
        #expect(try endpoint(game) == player.position + SIMD2<Float>(300, 60))
    }

    @Test(arguments: [Float(0), .pi / 2, .pi, -.pi / 2])
    func untargetedCenterFirePreservesEveryFacingDirection(heading: Float) throws {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        bot.position = [400, 400]
        player.components[BotComponent.self]?.heading = heading
        game.aim(.zero, firing: true); game.beforeSteering(deltaTime: 0.01)
        let expected = player.position + SIMD2<Float>(0, 60) + SIMD2<Float>(cos(heading), sin(heading)) * 300
        #expect(simd_distance(try endpoint(game), expected) < 0.001)
        #expect(player.components[BotComponent.self]?.heading == heading)
        #expect(game.beamTargetID == nil)
    }

    @Test(arguments: [SIMD2<Float>(0, 150), [0, -150], [-150, 0]])
    func centerFireStillAssistsNearbyTargetsOutsideFacingDirection(position: SIMD2<Float>) {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        bot.position = position
        game.aim(.zero, firing: true); game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == bot.id)
        #expect(bot.components[BotComponent.self]!.corruption < 100)
        #expect(player.components[BotComponent.self]?.heading == 0)
        game.pause()
        #expect(game.beamTargetID == nil)
    }

    @Test func acquisitionFavorsAimOverACloserOffAxisBot() {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        bot.position = [200, 0]
        let offAxis = game.makeBot(kind: .ground, at: [20, 90], heading: 0)
        offAxis.components[BotComponent.self]?.isBad = true
        game.bots.append(offAxis)
        game.aim(.zero, firing: true)
        game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == bot.id)
        #expect(player.components[BotComponent.self]?.heading == 0)
        #expect(offAxis.components[BotComponent.self]?.corruption == 100)
    }

    @Test func heldLockDoesNotSwapWhenSimilarTargetsTradeDistances() {
        let (game, _, _, bot) = DemoBotsIntegrationTests().fixture()
        bot.position = [140, 15]
        let neighbor = game.makeBot(kind: .ground, at: [142, -15], heading: 0)
        neighbor.components[BotComponent.self]?.isBad = true; game.bots.append(neighbor)
        game.beam.active = true
        game.applyBeam(deltaTime: 0)
        #expect(game.beamTargetID == bot.id)
        neighbor.position = [138, -15]
        game.applyBeam(deltaTime: 0)
        #expect(game.beamTargetID == bot.id)
    }

    @Test func deliberateAimSwitchesTheLockAndSupportsAWiderAcquisitionCone() {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        let north = game.makeBot(kind: .ground, at: [0, 150], heading: 0)
        north.components[BotComponent.self]?.isBad = true; game.bots.append(north)
        game.aim(.zero, firing: true); game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == bot.id)
        game.aim([0, 1], firing: true); game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == north.id)
        #expect(abs(player.components[BotComponent.self]!.heading - .pi / 2) < 0.001)
        north.components[BotComponent.self]?.isBad = false
        bot.position = [75, 130] // 30 degrees from north, inside assistance.
        game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == bot.id)
    }

    @Test func deliberateAimCanSwitchBetweenTargetsInsideTheSameCone() {
        let (game, _, _, bot) = DemoBotsIntegrationTests().fixture()
        let direction = SIMD2<Float>(cos(.pi / 6), sin(.pi / 6))
        let neighbor = game.makeBot(kind: .ground, at: direction * 150, heading: 0)
        neighbor.components[BotComponent.self]?.isBad = true; game.bots.append(neighbor)
        game.aim(.zero, firing: true); game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == bot.id)
        game.aim(direction, firing: true); game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == neighbor.id)
    }

    @Test(arguments: ["wall", "cured", "behind"])
    func invalidTargetsReleaseTheLockAndUseFacingFallback(reason: String) throws {
        let (game, world, player, bot) = DemoBotsIntegrationTests().fixture()
        game.aim(reason == "behind" ? [1, 0] : .zero, firing: true)
        game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == bot.id)
        switch reason {
        case "wall":
            let wall = Entity(components: CollisionComponent(shape: .rectangle(size: [2, 200]), filter: .init(group: BotCollisionGroups.walls)))
            wall.position = [75, 0]; world.addEntity(wall)
        case "cured": bot.components[BotComponent.self]?.isBad = false
        default: bot.position = [-20, 0]
        }
        game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == nil)
        #expect(player.components[BotComponent.self]?.heading == 0)
        let end = try endpoint(game)
        #expect(abs(end.y - 60) < 0.001)
        #expect(abs(end.x - (reason == "wall" ? 74 : 300)) < 0.001)
    }

    @Test func tapToWalkUpdatesFacingUsedByUntargetedShots() throws {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        bot.position = [400, 0]
        game.destination = [0, 150]
        player.components[BotComponent.self]?.previousPosition = .zero
        player.position = [0, 10]
        game.resolveMovement(deltaTime: 1 / 60)
        #expect(abs(player.components[BotComponent.self]!.heading - .pi / 2) < 0.001)
        game.aim(.zero, firing: true); game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == nil)
        let end = try endpoint(game)
        #expect(abs(end.x - player.position.x) < 0.001)
        #expect(abs(end.y - player.position.y - 360) < 0.001)
        game.aim(.zero, firing: false); game.beforeSteering(deltaTime: 0.01)
        #expect(game.beamTargetID == nil && game.beamLines.allSatisfy { !$0.isEnabled })
    }
}
