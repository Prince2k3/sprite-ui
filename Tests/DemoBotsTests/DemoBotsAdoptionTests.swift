import Foundation
import SpriteKit
import SpriteUI
import Testing
import simd
@testable import DemoBotsGame

@MainActor @Suite(.serialized) struct DemoBotsAdoptionTests {
    private func body(of actor: Entity) throws -> Entity {
        try #require(actor.findEntity(named: "body"))
    }

    private func material(of actor: Entity) throws -> SpriteMaterial {
        try #require(try body(of: actor).components[SpriteComponent.self]).material
    }

    private func shape(of entity: Entity, renderer: SpriteRenderer) throws -> SKShapeNode {
        let node = try #require(renderer.node(for: entity))
        return try #require(node.children.compactMap { $0 as? SKShapeNode }.first)
    }

    private func path(of entity: Entity) throws -> VectorPath {
        let component = try #require(entity.components[ShapeComponent.self])
        guard case .path(let path) = component.geometry else {
            throw AdoptionTestError.expectedPath
        }
        return path
    }

    private enum AdoptionTestError: Error { case expectedPath }

    @Test(arguments: [BotKind.player, .ground, .flying])
    func cachedPrefabsOwnTheirHierarchyComponentsAndMaterialOverrides(kind: BotKind) throws {
        let first = BotPrefabs.make(kind: kind), second = BotPrefabs.make(kind: kind)
        var firstIDs: Set<Entity.ID> = [], secondIDs: Set<Entity.ID> = []
        first.visit { firstIDs.insert($0.id) }
        second.visit { secondIDs.insert($0.id) }
        #expect(firstIDs.isDisjoint(with: secondIDs))
        #expect(firstIDs.count == secondIDs.count && firstIDs.count > 1)
        #expect(first.world == nil && second.world == nil)
        #expect(first.components[AttachmentComponent.self]?.attachmentID == "bot-status")
        #expect(first.components[AttachmentComponent.self]?.sizing == .screen)
        #expect(first.components.has(CharacterControllerComponent.self))

        let firstBody = try body(of: first), secondBody = try body(of: second)
        #expect(firstBody !== secondBody)
        #expect(try material(of: first).shader == .spriteEffects)
        #expect(try material(of: first).shader == material(of: second).shader)
        first.position = [40, 80]
        first.components[SteeringComponent.self]?.maxSpeed = 17
        first.components[AttachmentComponent.self]?.isEnabled = false
        try firstBody.components[SpriteComponent.self]?.material.setParameter(.float(1), named: "a_flash")
        try firstBody.components[SpriteComponent.self]?.material.setParameter(.float(3), named: "a_outlineWidth")
        firstBody.position = [7, 9]

        for untouched in [second, BotPrefabs.make(kind: kind)] {
            #expect(untouched.position == .zero)
            #expect(untouched.components[SteeringComponent.self]?.maxSpeed == 210)
            #expect(untouched.components[AttachmentComponent.self]?.isEnabled == true)
            #expect(try body(of: untouched).position == SIMD2<Float>(0, 25))
            #expect(try material(of: untouched).parameter(named: "a_flash") == .float(0))
            #expect(try material(of: untouched).parameter(named: "a_outlineWidth") == .float(0))
            let shadow = try #require(untouched.findEntity(named: "shadow")?.components[SpriteComponent.self])
            #expect(shadow.imageName == (kind == .player ? "PlayerBotShadow" : "GroundBotShadow"))
        }
    }

    @Test func damageFlashesOnlyTheVictimAndClearsOnTheSameNativeSprite() throws {
        let (game, world, player, bot) = DemoBotsIntegrationTests().fixture()
        let renderer = SpriteRenderer(world: world)
        let playerBody = try body(of: player)
        let node = try #require(renderer.node(for: playerBody))
        let sprite = try #require(node.children.compactMap { $0 as? SKSpriteNode }.first)
        game.damage(player, amount: 25)
        game.updateLook(player, info: try #require(player.components[BotComponent.self]), moving: false)
        game.updateLook(bot, info: try #require(bot.components[BotComponent.self]), moving: false)
        renderer.flush()
        #expect(try material(of: player).parameter(named: "a_flash") == .float(1))
        #expect(try material(of: bot).parameter(named: "a_flash") == .float(0))
        #expect(sprite.value(forAttributeNamed: "a_flash")?.floatValue == 1)

        game.beforeSteering(deltaTime: 0.6)
        game.updateLook(player, info: try #require(player.components[BotComponent.self]), moving: true)
        renderer.flush()
        #expect(player.components[BotComponent.self]?.hitFlash == 0)
        #expect(try material(of: player).parameter(named: "a_flash") == .float(0))
        #expect(sprite.value(forAttributeNamed: "a_flash")?.floatValue == 0)
        #expect(renderer.node(for: playerBody) === node && sprite.parent === node)
    }

    @Test func zappedOutlineIsLocalToTheTargetAndClearsWhenItsStateChanges() throws {
        let (game, _, player, bot) = DemoBotsIntegrationTests().fixture()
        bot.enter(BotMode.zapped)
        game.updateLook(bot, info: try #require(bot.components[BotComponent.self]), moving: false)
        guard case .float(let width) = try material(of: bot).parameter(named: "a_outlineWidth") else {
            Issue.record("The zapped body must expose the outline shader parameter")
            return
        }
        #expect(width > 0)
        #expect(try material(of: player).parameter(named: "a_outlineWidth") == .float(0))
        bot.enter(BotMode.patrol)
        game.updateLook(bot, info: try #require(bot.components[BotComponent.self]), moving: true)
        #expect(try material(of: bot).parameter(named: "a_outlineWidth") == .float(0))
    }

    @Test func routeEditsAndVisibilityChangesRetainGuideEntitiesAndNativeShapes() throws {
        let (game, world, player, bot) = DemoBotsIntegrationTests().fixture()
        let renderer = SpriteRenderer(world: world)
        game.showsPaths = true
        game.playerRoute = [[100, 0], [100, 100]]
        bot.components[BotComponent.self]?.route = [[200, 40], [250, 40]]
        game.redrawPaths(); renderer.flush()
        let guides = game.pathLines
        try #require(guides.count == 2)
        let nodes = try guides.map { try #require(renderer.node(for: $0)) }
        let shapes = try guides.map { try shape(of: $0, renderer: renderer) }
        #expect(try path(of: guides[0]).elements == [.move(to: player.scenePosition), .line(to: [100, 0]), .line(to: [100, 100])])
        #expect(try path(of: guides[1]).elements == [.move(to: bot.scenePosition), .line(to: [200, 40]), .line(to: [250, 40])])

        bot.position = [175, 20]
        bot.components[BotComponent.self]?.route = [[220, 60]]
        for _ in 0..<10 { game.redrawPaths(); renderer.flush() }
        #expect(try path(of: guides[1]).elements == [.move(to: [175, 20]), .line(to: [220, 60])])
        game.showsPaths = false; game.redrawPaths(); renderer.flush()
        #expect(guides.allSatisfy { !$0.isActive && $0.world === world })
        #expect(nodes.allSatisfy { $0.isHidden })
        game.showsPaths = true; game.redrawPaths(); renderer.flush()
        for index in guides.indices {
            #expect(game.pathLines[index] === guides[index] && guides[index].isActive)
            #expect(renderer.node(for: guides[index]) === nodes[index])
            #expect(try shape(of: guides[index], renderer: renderer) === shapes[index])
        }
        game.playerRoute = []; game.redrawPaths()
        #expect(!guides[0].isEnabled && guides[1].isEnabled)
    }

    @Test func expiredBurstsParkInThePoolAndReuseResetVisualsWithoutLifetimeRemoval() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let effects = try DemoBotsEffects(world: world)
        effects.burst(.puff(color: .red), count: 60, at: [20, 25], blast: true)
        let first = try #require(effects.particles.leasedEntities.first)
        let node = try #require(renderer.node(for: first))
        let ring = try #require(first.findEntity(named: "blast-radius"))
        #expect(ring.isEnabled)
        #expect(ring.components[ShapeComponent.self]?.geometry == .circle(radius: 145))
        first.rotation = 1.5; first.scale = [3, 2]
        effects.advance(2)
        world.update(deltaTime: 2)
        #expect(first.world === world && !first.isActive)
        #expect(effects.particles.leasedCount == 0)
        #expect(!first.components.has(LifetimeComponent.self))

        effects.burst(.sparks(color: .cyan), count: 7, at: [-40, 70])
        let reused = try #require(effects.particles.leasedEntities.first)
        renderer.flush()
        #expect(reused === first && renderer.node(for: reused) === node)
        #expect(reused.position == SIMD2<Float>(-40, 70) && reused.rotation == 0 && reused.scale == SIMD2<Float>(1, 1))
        let emitter = try #require(reused.components[ParticleEmitterComponent.self])
        #expect(emitter.color == .cyan && emitter.burstCount == 7)
        #expect(!ring.isEnabled && ring.components[ShapeComponent.self]?.opacity == 0)
        #expect(!reused.components.has(LifetimeComponent.self))
    }

    @Test func effectPoolsStayBoundedAtSaturationAndRecoverTheirCapacityAfterExpiry() throws {
        let world = World(), effects = try DemoBotsEffects(world: world)
        for _ in 0..<(effects.particles.capacity + 5) {
            effects.burst(.sparks(), count: 5, at: .zero)
        }
        for _ in 0..<(effects.captions.capacity + 5) {
            effects.caption("REPAIRED", color: .green, at: .zero)
        }
        #expect(effects.particles.leasedCount == effects.particles.capacity)
        #expect(effects.captions.leasedCount == effects.captions.capacity)
        let particleIDs = Set(effects.particles.leasedEntities.map(\.id))
        let captionIDs = Set(effects.captions.leasedEntities.map(\.id))
        #expect(effects.particles.totalCount == effects.particles.capacity)
        #expect(effects.captions.totalCount == effects.captions.capacity)
        effects.advance(10)
        #expect(effects.particles.leasedCount == 0 && effects.captions.leasedCount == 0)
        effects.burst(.sparks(), count: 1, at: [5, 6])
        effects.caption("NEW", color: .cyan, at: [5, 6])
        #expect(particleIDs.contains(try #require(effects.particles.leasedEntities.first).id))
        #expect(captionIDs.contains(try #require(effects.captions.leasedEntities.first).id))
        for container in [effects.particles.container, effects.captions.container] {
            container.visit { #expect(!$0.components.has(LifetimeComponent.self)) }
        }
    }

    @Test func composedCaptionPlaybackRisesScalesFadesAndResetsOnReuse() throws {
        let world = World(), renderer = SpriteRenderer(world: world)
        let effects = try DemoBotsEffects(world: world)
        let origin = SIMD2<Float>(20, 100)
        effects.caption("−25", color: .red, at: origin)
        let caption = try #require(effects.captions.leasedEntities.first)
        let node = try #require(renderer.node(for: caption))
        world.update(deltaTime: 0.3); effects.advance(0.3); renderer.flush()
        let text = try #require(caption.components[TextComponent.self])
        #expect(text.text == "−25" && text.color == .red)
        #expect(caption.position.x == origin.x && caption.position.y > origin.y && caption.position.y < origin.y + 48)
        #expect(caption.scale.x > 0.9 && caption.scale.x < 1.1)
        #expect(text.opacity > 0 && text.opacity < 1)
        effects.advance(1)
        #expect(!caption.isActive && caption.world === world)
        effects.caption("REPAIRED", color: .green, at: [-10, 40])
        let reused = try #require(effects.captions.leasedEntities.first)
        #expect(reused === caption && renderer.node(for: reused) === node)
        #expect(reused.position == SIMD2<Float>(-10, 40))
        #expect(reused.components[TextComponent.self]?.text == "REPAIRED")
        #expect(reused.components[TextComponent.self]?.color == .green)
        #expect(reused.components[TextComponent.self]?.opacity == 1)
        #expect(reused.scale == SIMD2<Float>(0.9, 0.9))
        world.update(deltaTime: 0.1)
        #expect(reused.position.y > 40 && reused.position.y < 88)
        #expect(reused.components[TextComponent.self]?.opacity ?? 0 > 0.8)
    }

    @Test func matchPauseFreezesEffectExpiryAndRestartReplacesTheOldPools() throws {
        let (game, world, _, bot) = DemoBotsIntegrationTests().fixture()
        let effects = try #require(game.effects)
        bot.components[BotComponent.self]?.decisionDelay = 100
        effects.burst(.sparks(), count: 5, at: .zero)
        effects.caption("PAUSE", color: .cyan, at: [0, 100])
        let particle = try #require(effects.particles.leasedEntities.first)
        let caption = try #require(effects.captions.leasedEntities.first)
        world.update(deltaTime: 0.2)
        game.pause()
        let position = caption.position, opacity = caption.components[TextComponent.self]?.opacity
        for _ in 0..<120 { world.update(deltaTime: 1 / 60) }
        #expect(particle.isActive && caption.isActive)
        #expect(caption.position == position && caption.components[TextComponent.self]?.opacity == opacity)
        game.resume()
        // Resume requests a fresh AI decision; keep this expiry check free of
        // new combat bursts that could immediately reacquire the old lease.
        bot.components[BotComponent.self]?.decisionDelay = 100
        for _ in 0..<72 { world.update(deltaTime: 1 / 60) }
        #expect(!particle.isActive && !caption.isActive)
        #expect(particle.world === world && caption.world === world)
        effects.caption("OLD MATCH", color: .red, at: .zero)
        game.start()
        #expect(game.phase == .playing)
        #expect(game.effects !== effects)
        #expect(effects.particles.container.world == nil && effects.captions.container.world == nil)
        #expect(particle.world == nil && caption.world == nil)
        #expect(game.effects?.particles.leasedCount == 0 && game.effects?.captions.leasedCount == 0)
    }

    @Test func reticleFollowsThePresentedTargetWithoutConstrainingTheCharacter() throws {
        let (game, world, _, bot) = DemoBotsIntegrationTests().fixture()
        let renderer = SpriteRenderer(world: world)
        game.beam.active = true; game.applyBeam(deltaTime: 0)
        let reticle = try #require(game.targetReticle)
        #expect(reticle.isActive && bot.components.has(CharacterControllerComponent.self))
        #expect(!reticle.components.has(CharacterControllerComponent.self))
        #expect(!bot.components.has(TransformConstraintComponent.self))
        let rules = try #require(reticle.components[TransformConstraintComponent.self])
        #expect(rules.constraints.count == 1)
        guard case .follow(.entity(let targetID), let offset, .scene, _) = rules.constraints.first?.behavior else {
            Issue.record("The reticle must follow the chosen bot in scene space")
            return
        }
        #expect(targetID == bot.id)
        renderer.flush()
        let targetNode = try #require(renderer.node(for: bot))
        // Model and presented positions deliberately differ, as during a native action.
        targetNode.position = CGPoint(x: 190, y: 30)
        renderer.didFinishUpdate()
        #expect(bot.position == SIMD2<Float>(150, 0))
        #expect(simd_distance(reticle.scenePosition, SIMD2<Float>(190, 30) + offset) < 0.001)
        #expect(reticle.transformConstraintStatuses == [.active])
        game.beam.active = false; game.applyBeam(deltaTime: 0)
        #expect(!reticle.isActive && reticle.transformConstraintStatuses == [.disabled])
        #expect(game.beamLines.allSatisfy { !$0.isEnabled })
    }

    @Test(arguments: ["target-lost", "inspection", "pause"])
    func losingTheTargetOrClearingPlayerInputDisablesTheReticle(action: String) throws {
        let (game, _, _, bot) = DemoBotsIntegrationTests().fixture()
        game.beam.active = true; game.applyBeam(deltaTime: 0)
        let reticle = try #require(game.targetReticle)
        #expect(reticle.isActive)
        switch action {
        case "target-lost":
            bot.components[BotComponent.self]?.isBad = false
            game.applyBeam(deltaTime: 0)
        case "inspection": game.beginInspection()
        default: game.pause()
        }
        #expect(!reticle.isEnabled)
        #expect(reticle.transformConstraintStatuses == [.disabled])
        if action != "target-lost" { #expect(game.beamLines.allSatisfy { !$0.isEnabled }) }
    }
}
