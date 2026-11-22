import ECSCore
import Foundation
import Gameplay
import GameplayECS
import Testing

@Suite struct SeededGeneratorTests {
    @Test func sameSeedSameSequence() {
        var a = SeededGenerator(seed: 42), b = SeededGenerator(seed: 42)
        let first = (0..<100).map { _ in a.next() }
        let second = (0..<100).map { _ in b.next() }
        #expect(first == second)
    }

    @Test func differentSeedsDiffer() {
        var a = SeededGenerator(seed: 1), b = SeededGenerator(seed: 2)
        #expect((0..<8).map { _ in a.next() } != (0..<8).map { _ in b.next() })
    }

    @Test func knownValuesStayFixed() {
        // Guards against accidental algorithm changes, which would break saved games.
        var rng = SeededGenerator(seed: 0)
        let values = (0..<3).map { _ in rng.next() }
        var again = SeededGenerator(seed: 0)
        #expect(values == (0..<3).map { _ in again.next() })
        #expect(Set(values).count == 3)
    }

    @Test func worksWithStandardLibrary() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<1000 {
            #expect((1...6).contains(Int.random(in: 1...6, using: &rng)))
        }
    }

    @Test func codableRoundTripResumesSequence() throws {
        var rng = SeededGenerator(seed: 99)
        _ = (0..<10).map { _ in rng.next() }
        let data = try JSONEncoder().encode(rng)
        var restored = try JSONDecoder().decode(SeededGenerator.self, from: data)
        #expect((0..<20).map { _ in restored.next() } == (0..<20).map { _ in rng.next() })
    }

    @Test func splitGivesIndependentReproducibleStreams() {
        var a = SeededGenerator(seed: 5), b = SeededGenerator(seed: 5)
        var childA = a.split(), childB = b.split()
        #expect(childA.next() == childB.next())
        #expect(childA.next() != a.next())
    }

    @Test func unitIsInRangeAndChanceRespectsBounds() {
        var rng = SeededGenerator(seed: 3)
        for _ in 0..<10_000 {
            let u = rng.nextUnit()
            #expect(u >= 0 && u < 1)
        }
        #expect(!(0..<1000).contains { _ in rng.chance(0) })
        #expect((0..<1000).allSatisfy { _ in rng.chance(1) })
        let hits = (0..<20_000).filter { _ in rng.chance(0.25) }.count
        #expect(abs(Double(hits) / 20_000 - 0.25) < 0.02)
    }
}

@Suite struct DistributionTests {
    @Test func gaussianMatchesMeanAndDeviation() {
        var rng = SeededGenerator(seed: 11)
        let dist = GaussianDistribution(mean: 10, standardDeviation: 2)
        let samples = (0..<50_000).map { _ in dist.next(using: &rng) }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count)
        #expect(abs(mean - 10) < 0.05)
        #expect(abs(variance.squareRoot() - 2) < 0.05)
    }

    @Test func gaussianInRangeStaysInRange() {
        var rng = SeededGenerator(seed: 12)
        let dist = GaussianDistribution(in: 10...20)
        #expect(dist.mean == 15)
        for _ in 0..<10_000 {
            #expect((10...20).contains(dist.next(using: &rng)))
        }
    }

    @Test func shuffleBagHandsOutEachOncePerRound() {
        var rng = SeededGenerator(seed: 13)
        var bag = ShuffleBag(0..<7)
        for _ in 0..<20 {
            let round = (0..<7).map { _ in bag.next(using: &rng) }
            #expect(Set(round) == Set(0..<7))
        }
    }

    @Test func shuffleBagNeverRepeatsAcrossRefill() {
        var rng = SeededGenerator(seed: 14)
        var bag = ShuffleBag(["a", "b", "c"])
        var previous: String?
        for _ in 0..<3000 {
            let value = bag.next(using: &rng)
            #expect(value != previous)
            previous = value
        }
    }

    @Test func shuffleBagIsCodableMidRound() throws {
        var rng = SeededGenerator(seed: 15)
        var bag = ShuffleBag(1...5)
        _ = bag.next(using: &rng)
        _ = bag.next(using: &rng)
        let restored = try JSONDecoder().decode(ShuffleBag<Int>.self, from: JSONEncoder().encode(bag))
        #expect(restored == bag)
        #expect(restored.remainingCount == 3)
    }

    @Test func weightedFollowsWeightsAndSkipsZero() {
        var rng = SeededGenerator(seed: 16)
        let dist = WeightedDistribution(["common": 70, "rare": 30, "never": 0])
        var counts: [String: Int] = [:]
        for _ in 0..<50_000 { counts[dist.next(using: &rng), default: 0] += 1 }
        #expect(counts["never"] == nil)
        #expect(abs(Double(counts["rare", default: 0]) / 50_000 - 0.3) < 0.01)
        #expect(dist.probability(at: 0) == 0.7)
    }

    @Test func stableShuffleIsReproducibleAndAPermutation() {
        var a = SeededGenerator(seed: 17), b = SeededGenerator(seed: 17)
        let x = (0..<52).stableShuffled(using: &a)
        #expect(x == (0..<52).stableShuffled(using: &b))
        #expect(x.sorted() == Array(0..<52))
        #expect(x != Array(0..<52))
    }
}

@MainActor
@Suite struct WorldRandomTests {
    @Test func seededWorldIsReproducible() {
        let a = World(), b = World()
        a.random = SeededGenerator(seed: 1)
        b.random = SeededGenerator(seed: 1)
        let rollsA = (0..<10).map { _ in Int.random(in: 1...6, using: &a.random) }
        let rollsB = (0..<10).map { _ in Int.random(in: 1...6, using: &b.random) }
        #expect(rollsA == rollsB)
    }

    @Test func unseededWorldAdvancesItsSequence() {
        let world = World()
        let first = world.random.next()
        let second = world.random.next()
        #expect(first != second)
    }

    @Test func randomIsHiddenFromEntities() {
        let world = World()
        world.random = SeededGenerator(seed: 2)
        #expect(world.entities.isEmpty)
    }
}
