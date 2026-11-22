@_spi(Backend) import ECSCore
import Foundation

/// Sparks and a sound wherever the entity's physics body hits something hard enough.
///
/// The renderer watches ``PhysicsEvents/ContactBegan`` and, for each entity in the contact
/// that has this component, adds a ``Entity/oneShot(particles:count:sound:at:)`` effect
/// at the contact point. Soft touches below ``minimumImpulse`` do nothing, so a body
/// settling on the ground stays quiet.
///
/// ```swift
/// crate.components.set(ContactEffectComponent(
///     particles: .sparks(), count: 16,
///     sound: AudioComponent(named: "thud.wav"), minimumImpulse: 3
/// ))
/// ```
public struct ContactEffectComponent: Component, Equatable {
    public var particles: ParticleEmitterComponent?
    /// How many particles each hit throws out.
    public var count: Int
    public var sound: AudioComponent?
    /// The weakest hit, in newton-seconds, that sets the effect off.
    public var minimumImpulse: Float
    /// Whether harder hits throw out more particles and play louder: from the set count
    /// and about half volume at ``minimumImpulse``, up to twice the count and full volume
    /// at 4× it.
    public var scalesWithImpulse: Bool

    public init(
        particles: ParticleEmitterComponent? = .sparks(),
        count: Int = 16,
        sound: AudioComponent? = nil,
        minimumImpulse: Float = 1,
        scalesWithImpulse: Bool = true
    ) {
        self.particles = particles
        self.count = count
        self.sound = sound
        self.minimumImpulse = minimumImpulse
        self.scalesWithImpulse = scalesWithImpulse
    }

    /// The effect for a hit, or `nil` when it's too soft.
    @MainActor
    public func effect(for contact: PhysicsEvents.ContactBegan) -> Entity? {
        guard contact.impulse >= minimumImpulse, particles != nil || sound != nil else { return nil }
        var count = count
        var sound = sound
        if scalesWithImpulse {
            let strength = min(contact.impulse / max(minimumImpulse, 1e-3), 4)   // 1...4
            count = Int((Float(count) * (1 + (strength - 1) / 3)).rounded())        // 1× ... 2×
            sound?.volume *= min(0.4 + strength * 0.15, 1)
        }
        return .oneShot(particles: particles, count: count, sound: sound, at: contact.point)
    }
}

extension SpriteRenderer {
    /// Adds the effects of ``ContactEffectComponent``s for a contact.
    func addContactEffects(_ contact: PhysicsEvents.ContactBegan) {
        for entity in [contact.entityA, contact.entityB] {
            guard let effect = entity.components[ContactEffectComponent.self]?.effect(for: contact) else { continue }
            world.addEntity(effect)
        }
    }
}
