@_spi(Backend) import ECSCore
import Gameplay

/// Stores the world's generator on its root entity.
struct WorldRandomComponent: Component {
    var generator: SeededGenerator
}

extension World {
    /// The world's shared random generator.
    ///
    /// Unseeded by default. Seed it to make a run reproducible, and read it from
    /// systems so every draw comes from one stream:
    ///
    /// ```swift
    /// world.random = SeededGenerator(seed: 42)
    ///
    /// // In a system:
    /// let roll = Int.random(in: 1...6, using: &context.world.random)
    /// ```
    ///
    /// Save `world.random` with your game state to resume the same sequence later.
    public var random: SeededGenerator {
        get {
            if let stored = root.components[WorldRandomComponent.self] {
                return stored.generator
            }
            // Keep the default, so later draws continue its sequence.
            let generator = SeededGenerator()
            root._setWithoutNotifying(WorldRandomComponent(generator: generator))
            return generator
        }
        set {
            // Draws happen constantly; they aren't changes backends need to hear about.
            root._setWithoutNotifying(WorldRandomComponent(generator: newValue))
        }
    }
}
