@_spi(Backend) import ECSCore
import Foundation
import SpriteKit
import SwiftUI

/// Particles drawn at the entity's transform, in place of `SKEmitterNode`.
///
/// An emitter does two things. While ``isEmitting`` is on, it streams ``birthRate``
/// particles a second, like smoke from a chimney. And ``burst(_:)`` throws out a number
/// of particles at once, for sparks or a puff of dust, whether or not it's streaming.
///
/// Particles live in the scene once they're born, so a moving emitter leaves a trail and
/// they don't jump when the entity turns.
///
/// ```swift
/// ship.components.set(ParticleEmitterComponent.smoke(color: .gray))     // a trail
/// crate.components[ParticleEmitterComponent.self]?.burst(30)              // on a hit
/// world.addEntity(.oneShot(particles: .sparks(), at: contact.point))     // and gone
/// ```
public struct ParticleEmitterComponent: Component, Equatable {
    /// How particles mix with what's behind them.
    public enum BlendMode: Hashable, Sendable {
        /// Ordinary see-through drawing.
        case alpha
        /// Adds light: overlapping particles glow brighter, for sparks and fire.
        case add
    }

    /// Name of an image in the asset catalog. With no `imageName` or `image`, particles
    /// are soft discs.
    public var imageName: String?
    /// Pixels made in code. Wins over `imageName`.
    public var image: SpriteImage?
    /// Each particle's size, in points, before ``scale``.
    public var particleSize: SIMD2<Float>
    public var color: Color
    public var blendMode: BlendMode

    /// Whether particles stream out at ``birthRate``.
    public var isEmitting: Bool
    /// Particles a second while ``isEmitting``.
    public var birthRate: Float

    /// Seconds each particle lives, give or take half of `lifetimeRange`.
    public var lifetime: Float
    public var lifetimeRange: Float
    /// Points a second each particle starts moving at, give or take half of `speedRange`.
    public var speed: Float
    public var speedRange: Float
    /// The direction particles leave in, in radians: 0 is right, π/2 up.
    public var angle: Float
    /// How far either way of ``angle`` a particle can go. 2π sends them every way.
    public var spread: Float
    /// Added to every particle's velocity each second, such as gravity.
    public var acceleration: SIMD2<Float>
    /// How far from the emitter's position particles can be born, in points.
    public var positionRange: SIMD2<Float>

    /// Starting size multiplier, give or take half of `scaleRange`.
    public var scale: Float
    public var scaleRange: Float
    /// Change in scale a second; negative shrinks.
    public var scaleSpeed: Float
    /// Starting opacity.
    public var alpha: Float
    /// Change in opacity a second; negative fades out.
    public var alphaSpeed: Float
    /// Spin, in radians a second, give or take half of `rotationSpeedRange`.
    public var rotationSpeed: Float
    public var rotationSpeedRange: Float

    /// Counts calls to ``burst(_:)``. The renderer throws out particles when it changes.
    public private(set) var burstID: Int = 0
    /// How many particles the latest burst threw out.
    public private(set) var burstCount: Int = 0

    public init(
        imageName: String? = nil,
        image: SpriteImage? = nil,
        particleSize: SIMD2<Float> = [8, 8],
        color: Color = .white,
        blendMode: BlendMode = .alpha,
        isEmitting: Bool = false,
        birthRate: Float = 30,
        lifetime: Float = 1,
        lifetimeRange: Float = 0,
        speed: Float = 100,
        speedRange: Float = 0,
        angle: Float = .pi / 2,
        spread: Float = 2 * .pi,
        acceleration: SIMD2<Float> = .zero,
        positionRange: SIMD2<Float> = .zero,
        scale: Float = 1,
        scaleRange: Float = 0,
        scaleSpeed: Float = 0,
        alpha: Float = 1,
        alphaSpeed: Float = 0,
        rotationSpeed: Float = 0,
        rotationSpeedRange: Float = 0
    ) {
        self.imageName = imageName
        self.image = image
        self.particleSize = particleSize
        self.color = color
        self.blendMode = blendMode
        self.isEmitting = isEmitting
        self.birthRate = birthRate
        self.lifetime = lifetime
        self.lifetimeRange = lifetimeRange
        self.speed = speed
        self.speedRange = speedRange
        self.angle = angle
        self.spread = spread
        self.acceleration = acceleration
        self.positionRange = positionRange
        self.scale = scale
        self.scaleRange = scaleRange
        self.scaleSpeed = scaleSpeed
        self.alpha = alpha
        self.alphaSpeed = alphaSpeed
        self.rotationSpeed = rotationSpeed
        self.rotationSpeedRange = rotationSpeedRange
    }

    /// Throws out `count` particles at once.
    public mutating func burst(_ count: Int) {
        guard count > 0 else { return }
        burstID &+= 1
        burstCount = count
    }

    /// The longest any particle lives, in seconds.
    public var maximumLifetime: Float {
        max(0, lifetime + lifetimeRange / 2)
    }

    // MARK: Presets

    /// Bright, quick streaks that glow where they overlap and fall a little.
    public static func sparks(color: Color = .orange) -> Self {
        ParticleEmitterComponent(
            particleSize: [5, 5], color: color, blendMode: .add,
            lifetime: 0.4, lifetimeRange: 0.3, speed: 220, speedRange: 160,
            acceleration: [0, -400], scale: 1, scaleRange: 0.6, scaleSpeed: -1.8,
            alpha: 1, alphaSpeed: -2
        )
    }

    /// A slow cloud that grows and fades, for dust and smoke.
    public static func puff(color: Color = .gray) -> Self {
        ParticleEmitterComponent(
            particleSize: [14, 14], color: color,
            lifetime: 0.8, lifetimeRange: 0.4, speed: 50, speedRange: 40,
            positionRange: [10, 10], scale: 0.6, scaleRange: 0.4, scaleSpeed: 1,
            alpha: 0.7, alphaSpeed: -0.8
        )
    }

    /// A steady stream rising behind a moving entity.
    public static func smoke(color: Color = .gray) -> Self {
        var smoke = puff(color: color)
        smoke.isEmitting = true
        smoke.birthRate = 25
        smoke.speed = 30
        smoke.angle = .pi / 2
        smoke.spread = 0.6
        smoke.lifetime = 1.2
        return smoke
    }
}

// MARK: - Short-lived entities

/// Removes its entity after ``remaining`` seconds, for effects that clean up after themselves.
public struct LifetimeComponent: Component, Hashable, Codable, Sendable {
    /// Seconds left before the entity is removed.
    public var remaining: Float

    public init(_ seconds: Float) {
        remaining = seconds
    }
}

/// Counts down every ``LifetimeComponent`` and removes the entities whose time is up.
/// A ``SpriteRenderer`` adds it to its world.
public struct LifetimeSystem: System {
    private static let query = EntityQuery(where: .has(LifetimeComponent.self))

    public init(world: World) {}

    public mutating func update(context: UpdateContext) {
        let deltaTime = Float(context.deltaTime)
        var expired: [Entity] = []
        for entity in context.entities(matching: Self.query) {
            guard var lifetime = entity.components[LifetimeComponent.self] else { continue }
            lifetime.remaining -= deltaTime
            if lifetime.remaining <= 0 {
                expired.append(entity)
            } else {
                entity._setWithoutNotifying(lifetime)
            }
        }
        for entity in expired { entity.removeFromParent() }
    }
}

extension Entity {
    /// An entity at `position` that throws out `count` particles and plays `sound` once,
    /// then removes itself once both are done. Add it to the world.
    ///
    /// Use it for effects that outlive what caused them, such as a coin that disappears
    /// as it's collected.
    public static func oneShot(
        particles: ParticleEmitterComponent? = nil,
        count: Int = 24,
        sound: AudioComponent? = nil,
        at position: SIMD2<Float>
    ) -> Entity {
        let entity = Entity(name: "one-shot")
        entity.position = position
        var seconds: Float = 0.1
        if var particles {
            particles.burst(count)
            entity.components.set(particles)
            seconds = max(seconds, particles.maximumLifetime + 0.1)
        }
        if var sound {
            sound.play()
            entity.components.set(sound)
            seconds = max(seconds, (sound.duration ?? 1) + 0.1)
        }
        entity.components.set(LifetimeComponent(seconds))
        return entity
    }
}

// MARK: - Renderer support

extension SpriteRenderer {
    static let emitterNodeName = "__emitter"
    static let burstNodeName = "__burst"

    static let particleBinding = Binding<ParticleEmitterComponent>(
        apply: { new, old, node, animator in
            let existing = node.childNode(withName: emitterNodeName) as? SKEmitterNode
            guard let emitter = new else {
                // Let what's already out finish; just stop making more.
                existing?.particleBirthRate = 0
                existing?.name = nil
                if let existing {
                    existing.run(.sequence([.wait(forDuration: TimeInterval(old?.maximumLifetime ?? 1)), .removeFromParent()]))
                }
                return
            }
            let scene = animator.renderer
            if emitter.isEmitting {
                let stream: SKEmitterNode
                if let existing {
                    stream = existing
                } else {
                    stream = SKEmitterNode()
                    stream.name = emitterNodeName
                    node.addChild(stream)
                }
                if existing == nil || old.map({ !$0.sameLook(as: emitter) }) ?? true {
                    configure(stream, emitter)
                }
                stream.targetNode = scene
                stream.particleBirthRate = CGFloat(max(emitter.birthRate, 0))
            } else if let existing {
                existing.particleBirthRate = 0
            }

            let isNewBurst = old.map { $0.burstID != emitter.burstID } ?? (emitter.burstID != 0)
            if isNewBurst, emitter.burstCount > 0 {
                let burst = SKEmitterNode()
                burst.name = burstNodeName
                configure(burst, emitter)
                burst.numParticlesToEmit = emitter.burstCount
                // All of them in about one frame.
                burst.particleBirthRate = CGFloat(emitter.burstCount) * 60
                burst.targetNode = scene
                node.addChild(burst)
                burst.run(.sequence([
                    .wait(forDuration: TimeInterval(emitter.maximumLifetime) + 0.2),
                    .removeFromParent(),
                ]))
            }
        }
    )

    /// Copies an emitter's look and motion onto a node.
    static func configure(_ node: SKEmitterNode, _ emitter: ParticleEmitterComponent) {
        node.particleTexture = particleTexture(emitter)
        node.particleSize = CGSize(width: CGFloat(emitter.particleSize.x), height: CGFloat(emitter.particleSize.y))
        node.particleColor = SKColor(emitter.color)
        node.particleColorBlendFactor = 1
        node.particleColorSequence = nil
        node.particleBlendMode = emitter.blendMode == .add ? .add : .alpha
        node.particleLifetime = CGFloat(emitter.lifetime)
        node.particleLifetimeRange = CGFloat(emitter.lifetimeRange)
        node.particleSpeed = CGFloat(emitter.speed)
        node.particleSpeedRange = CGFloat(emitter.speedRange)
        node.emissionAngle = CGFloat(emitter.angle)
        node.emissionAngleRange = CGFloat(emitter.spread)
        node.xAcceleration = CGFloat(emitter.acceleration.x)
        node.yAcceleration = CGFloat(emitter.acceleration.y)
        node.particlePositionRange = CGVector(dx: CGFloat(emitter.positionRange.x), dy: CGFloat(emitter.positionRange.y))
        node.particleScale = CGFloat(emitter.scale)
        node.particleScaleRange = CGFloat(emitter.scaleRange)
        node.particleScaleSpeed = CGFloat(emitter.scaleSpeed)
        node.particleAlpha = CGFloat(emitter.alpha)
        node.particleAlphaSpeed = CGFloat(emitter.alphaSpeed)
        node.particleRotationSpeed = CGFloat(emitter.rotationSpeed)
        node.particleRotationRange = CGFloat(emitter.rotationSpeedRange)
    }

    /// A white disc that fades out toward its edge.
    private static let softDisc: SpriteImage = {
        let size = 32
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Float(x) + 0.5) / Float(size) * 2 - 1
                let dy = (Float(y) + 0.5) / Float(size) * 2 - 1
                let t = max(0, 1 - (dx * dx + dy * dy).squareRoot())
                pixels[(y * size + x) * 4 + 3] = UInt8(min(1, t * 1.6) * 255)
            }
        }
        return SpriteImage(width: size, height: size, pixels: pixels)
    }()

    static func particleTexture(_ emitter: ParticleEmitterComponent) -> SKTexture? {
        if let image = emitter.image { return makeTexture(image) }
        if let name = emitter.imageName { return SKTexture(imageNamed: name) }
        return makeTexture(softDisc)
    }
}

private extension ParticleEmitterComponent {
    /// Equal apart from streaming and bursts, which don't need the node set up again.
    func sameLook(as other: Self) -> Bool {
        var a = self, b = other
        a.isEmitting = false; b.isEmitting = false
        a.birthRate = 0; b.birthRate = 0
        a.burstID = 0; b.burstID = 0
        a.burstCount = 0; b.burstCount = 0
        return a == b
    }
}

extension ParticleEmitterComponent {
    /// Copies emitter configuration without replaying an already requested burst.
    public func cloned() -> Self? {
        var copy = self; copy.burstID = 0; copy.burstCount = 0; return copy
    }
}
