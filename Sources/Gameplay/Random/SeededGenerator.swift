/// A fast, seedable random number generator (xoshiro256**).
///
/// The same seed always produces the same sequence, on every device, which makes
/// replays, procedural levels and tests reproducible. It works with all of Swift's
/// random APIs:
///
/// ```swift
/// var rng = SeededGenerator(seed: 42)
/// let roll = Int.random(in: 1...6, using: &rng)
/// let card = deck.randomElement(using: &rng)
/// ```
///
/// Its state is `Codable`, so a game can save it and resume the exact same sequence.
/// It is not cryptographically secure; use `SystemRandomNumberGenerator` for secrets.
public struct SeededGenerator: RandomNumberGenerator, Hashable, Codable, Sendable {
    private var s0, s1, s2, s3: UInt64

    /// A generator whose sequence is fixed by `seed`.
    public init(seed: UInt64) {
        // Expand the seed with SplitMix64, as xoshiro's authors recommend,
        // so similar seeds still give unrelated sequences.
        var mixer = SplitMix64(state: seed)
        s0 = mixer.next()
        s1 = mixer.next()
        s2 = mixer.next()
        s3 = mixer.next()
    }

    /// A generator with a fresh, unpredictable seed.
    public init() {
        var system = SystemRandomNumberGenerator()
        self.init(seed: system.next())
    }

    public mutating func next() -> UInt64 {
        let result = rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = rotl(s3, 45)
        return result
    }

    /// A new generator seeded from this one, for an independent stream.
    ///
    /// Give each enemy or level chunk its own split so adding draws in one place
    /// doesn't change what happens in another.
    public mutating func split() -> SeededGenerator {
        SeededGenerator(seed: next())
    }

    private func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    /// A uniform value in `0..<1` with 53 bits of precision.
    ///
    /// Unlike `Double.random(in:using:)`, its algorithm is fixed by this package,
    /// so seeded results stay the same across Swift releases.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// `true` with the given probability, from 0 (never) to 1 (always).
    ///
    /// ```swift
    /// if rng.chance(0.25) { dropLoot() }
    /// ```
    public mutating func chance(_ probability: Double) -> Bool {
        nextUnit() < probability
    }
}
