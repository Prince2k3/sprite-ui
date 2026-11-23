import SpriteUI
import SwiftUI

/// A snapshot filter marker: guides, pooled effects and beam artwork are rebuilt.
struct DemoBotsTransient: Component {}

struct BotStatus: Equatable {
    var charge: Float
    var isBad: Bool
    var isPlayer: Bool
    var isRecharging: Bool
}

/// Capture the shared hierarchy once. Every instance owns its components and
/// playback while sharing immutable animation textures and shader resources.
@MainActor enum BotPrefabs {
    private static var templates: [BotKind: PrefabResource] = [:]

    static func make(kind: BotKind) -> Entity {
        if let template = templates[kind] { return template.instantiate() }
        let actor = Entity(components:
            SteeringComponent(maxSpeed: 210, maxForce: 900, radius: 25),
            SpatialIndexComponent(),
            CollisionComponent(shape: .circle(radius: 25), filter: .init(group: BotCollisionGroups.actors)),
            CharacterControllerComponent(shape: .circle(radius: 25), filter: .init(group: BotCollisionGroups.actors, mask: BotCollisionGroups.walls)),
            AttachmentComponent(id: "bot-status", offset: [0, 86], anchor: .bottom, sizing: .screen)
        )
        var sprite = SpriteComponent(imageName: "PlayerBot", size: [120, 120])
        sprite.material.shader = .spriteEffects
        let body = Entity(name: "body", components: sprite)
        body.position = [0, 25]; actor.addChild(body)
        let shadow = Entity(name: "shadow", components: SpriteComponent(
            imageName: kind == .player ? "PlayerBotShadow" : "GroundBotShadow", size: [80, 32], opacity: 0.6))
        shadow.position = [0, -8]; shadow.zPosition = -1; actor.addChild(shadow)
        let template = PrefabResource(root: actor, name: "\(kind.rawValue)-bot")
        templates[kind] = template
        return template.instantiate()
    }
}

/// Bounded cosmetic leases. Expiry releases to EntityPool rather than removing
/// the entity as LifetimeSystem would. Reuse cancels old particles and playback.
@MainActor final class DemoBotsEffects {
    let particles: EntityPool
    let captions: EntityPool
    private var expiry: [Entity.ID: Float] = [:]

    init(world: World) throws {
        let emitter = Entity(name: "impact", components: ParticleEmitterComponent.sparks())
        emitter.zPosition = 550
        let ring = Entity(name: "blast-radius", components: ShapeComponent(.circle(radius: 145),
            stroke: .red, lineWidth: 3, opacity: 0, blendMode: .add))
        ring.position = [0, -25]; ring.isEnabled = false; emitter.addChild(ring)
        particles = try EntityPool(prefab: PrefabResource(root: emitter), scene: world, capacity: 40, prewarm: 6,
            onAcquire: { entity in
                entity.transform = Transform(zPosition: 550)
                entity.components.set(ParticleEmitterComponent.sparks())
                if let ring = entity.findEntity(named: "blast-radius") {
                    ring.isEnabled = false
                    ring.components[ShapeComponent.self]?.opacity = 0
                }
            })
        let caption = Entity(name: "combat-caption", components: TextComponent("", font: .system(size: 20, weight: .bold)))
        captions = try EntityPool(prefab: PrefabResource(root: caption), scene: world, capacity: 16, prewarm: 3,
            onAcquire: { entity in
                entity.transform = Transform(zPosition: 650)
                entity.components.set(TextComponent("", font: .system(size: 20, weight: .bold)))
            })
        particles.container.name = "combat-particles"
        captions.container.name = "combat-captions"
        for pool in [particles, captions] { pool.container.components.set(DemoBotsTransient()) }
    }

    func burst(_ config: ParticleEmitterComponent, count: Int, at point: SIMD2<Float>, blast: Bool = false) {
        guard let entity = try? particles.acquire(configure: { entity in
            entity.position = point
            var config = config; config.burst(count); entity.components.set(config)
            if blast, let ring = entity.findEntity(named: "blast-radius") {
                ring.isEnabled = true
                ring.components[ShapeComponent.self]?.stroke = config.color
                ring.components[ShapeComponent.self]?.opacity = 1
            }
        }) else { return } // Saturation drops cosmetics, never gameplay.
        expiry[entity.id] = config.maximumLifetime + 0.2
        if blast, let ring = entity.findEntity(named: "blast-radius"),
           let fade = try? AnimationResource.fade(from: 1, to: 0, duration: 0.8) {
            _ = try? ring.playAnimation(fade)
        }
    }

    func caption(_ text: String, color: Color, at point: SIMD2<Float>) {
        guard let entity = try? captions.acquire(configure: { entity in
            entity.position = point
            entity.components[TextComponent.self]?.text = text
            entity.components[TextComponent.self]?.color = color
        }) else { return }
        // One composed timeline owns translation, scale and text opacity.
        if let rise = try? AnimationResource.move(from: point, to: point + [0, 48], duration: 0.9, curve: .easeOut),
           let fade = try? AnimationResource.fade(from: 1, to: 0, duration: 0.9),
           let scale = try? AnimationResource.scale(from: [0.9, 0.9], to: [1.1, 1.1], duration: 0.9),
           let clip = try? AnimationResource.group([rise, fade, scale]) {
            _ = try? entity.playAnimation(clip)
        }
        expiry[entity.id] = 1
    }

    func advance(_ dt: Float) {
        for pool in [particles, captions] {
            for entity in pool.leasedEntities {
                let remaining = (expiry[entity.id] ?? 0) - max(0, dt)
                if remaining <= 0 {
                    _ = try? pool.release(entity); expiry[entity.id] = nil
                } else { expiry[entity.id] = remaining }
            }
        }
    }
}
