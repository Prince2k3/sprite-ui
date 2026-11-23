import Foundation

/// Something that produces random values with a particular shape.
///
/// Draw with any generator; pass a ``SeededGenerator`` for reproducible results.
public protocol RandomDistribution<Value> {
    associatedtype Value
    mutating func next(using generator: inout some RandomNumberGenerator) -> Value
}

extension RandomDistribution {
    /// Draws using the system's generator.
    public mutating func next() -> Value {
        var generator = SystemRandomNumberGenerator()
        return next(using: &generator)
    }
}

// MARK: - Gaussian

/// A bell curve: values cluster around `mean`, and about 68% land within one
/// `standardDeviation` of it.
///
/// ```swift
/// let spread = GaussianDistribution(mean: 0, standardDeviation: 40)
/// enemy.position.x = Float(spread.next(using: &rng))
///
/// // Or keep values in a range, centered on it.
/// var damage = GaussianDistribution(in: 10...20)
/// ```
public struct GaussianDistribution: RandomDistribution, Hashable, Codable, Sendable {
    public var mean: Double
    public var standardDeviation: Double
    /// Values outside this range are clamped to it.
    public var range: ClosedRange<Double>?

    public init(mean: Double = 0, standardDeviation: Double = 1) {
        precondition(standardDeviation >= 0, "The standard deviation can't be negative.")
        self.mean = mean
        self.standardDeviation = standardDeviation
    }

    /// Centered on `range`, with nearly all values (±3σ) inside it; the rare rest are clamped.
    public init(in range: ClosedRange<Double>) {
        self.init(mean: (range.lowerBound + range.upperBound) / 2,
                  standardDeviation: (range.upperBound - range.lowerBound) / 6)
        self.range = range
    }

    public func next(using generator: inout some RandomNumberGenerator) -> Double {
        // Box–Muller. 1 - u keeps the log's argument in (0, 1].
        let u1 = 1 - generator.nextUnit()
        let u2 = generator.nextUnit()
        let normal = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        let value = mean + standardDeviation * normal
        guard let range else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Shuffle bag

/// Hands out every element once, in random order, before any repeats.
///
/// Feels fairer than pure randomness: no long droughts, no streaks. When the bag
/// empties it refills and reshuffles, and never gives the same element twice in a row
/// across a refill.
///
/// ```swift
/// var pieces = ShuffleBag(Tetromino.allCases)
/// let next = pieces.next(using: &rng)
/// ```
public struct ShuffleBag<Element>: RandomDistribution {
    public let elements: [Element]
    /// Indices still in the bag; drawn from the end.
    private var remaining: [Int] = []
    private var lastDrawn: Int?

    public init(_ elements: some Sequence<Element>) {
        self.elements = Array(elements)
        precondition(!self.elements.isEmpty, "A shuffle bag needs at least one element.")
    }

    /// How many draws are left before the bag refills.
    public var remainingCount: Int { remaining.count }

    public mutating func next(using generator: inout some RandomNumberGenerator) -> Element {
        if remaining.isEmpty {
            remaining = Array(elements.indices)
            shuffle(&remaining, using: &generator)
            if remaining.count > 1, remaining.last == lastDrawn {
                remaining.swapAt(0, remaining.count - 1)
            }
        }
        let index = remaining.removeLast()
        lastDrawn = index
        return elements[index]
    }
}

extension ShuffleBag: Sendable where Element: Sendable {}
extension ShuffleBag: Equatable where Element: Equatable {}
extension ShuffleBag: Hashable where Element: Hashable {}
extension ShuffleBag: Codable where Element: Codable {}

// MARK: - Weighted

/// Picks elements in proportion to their weights.
///
/// ```swift
/// let loot = WeightedDistribution([.common: 70, .rare: 25, .legendary: 5])
/// let drop = loot.next(using: &rng)
/// ```
///
/// Weights don't need to add up to anything in particular. An element with weight 0
/// is never picked.
public struct WeightedDistribution<Element>: RandomDistribution {
    public let elements: [Element]
    public let weights: [Double]
    /// Running totals of `weights`.
    private let cumulative: [Double]

    public init(_ pairs: KeyValuePairs<Element, Double>) {
        self.init(pairs.map { ($0.key, $0.value) })
    }

    public init(_ pairs: [(Element, Double)]) {
        elements = pairs.map(\.0)
        weights = pairs.map(\.1)
        precondition(weights.allSatisfy { $0 >= 0 && $0.isFinite }, "Weights must be finite and not negative.")
        var total = 0.0
        cumulative = weights.map { total += $0; return total }
        precondition(total > 0, "At least one weight must be greater than zero.")
    }

    /// The chance of drawing the element at `index`, from 0 to 1.
    public func probability(at index: Int) -> Double {
        weights[index] / cumulative.last!
    }

    public func next(using generator: inout some RandomNumberGenerator) -> Element {
        let target = generator.nextUnit() * cumulative.last!
        // First running total above the target; zero weights never qualify.
        var low = 0, high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] > target { high = mid } else { low = mid + 1 }
        }
        return elements[low]
    }
}

extension WeightedDistribution: Sendable where Element: Sendable {}

// MARK: - Shuffling

/// Fisher–Yates with ``nextUnit()``-style bounded draws, so seeded shuffles are
/// stable across Swift releases (unlike `shuffled(using:)`).
func shuffle<T>(_ array: inout [T], using generator: inout some RandomNumberGenerator) {
    guard array.count > 1 else { return }
    for i in stride(from: array.count - 1, to: 0, by: -1) {
        let j = Int(generator.nextBelow(UInt64(i + 1)))
        array.swapAt(i, j)
    }
}

extension RandomNumberGenerator {
    /// A uniform integer in `0..<bound`, without modulo bias (Lemire's method).
    mutating func nextBelow(_ bound: UInt64) -> UInt64 {
        precondition(bound > 0)
        var (high, low) = next().multipliedFullWidth(by: bound)
        if low < bound {
            let threshold = (0 &- bound) % bound
            while low < threshold {
                (high, low) = next().multipliedFullWidth(by: bound)
            }
        }
        return high
    }
}

extension Sequence {
    /// The elements in a random order that a ``SeededGenerator`` reproduces exactly,
    /// across Swift releases.
    public func stableShuffled(using generator: inout some RandomNumberGenerator) -> [Element] {
        var result = Array(self)
        shuffle(&result, using: &generator)
        return result
    }
}
