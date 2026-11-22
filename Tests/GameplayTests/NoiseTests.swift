import Foundation
import Gameplay
import Testing

private let grid: [SIMD2<Double>] = (0..<20).flatMap { i in (0..<20).map { j in SIMD2(Double(i) * 0.137 - 1.3, Double(j) * 0.211 - 2.1) } }

@Suite struct NoiseTests {
    @Test func sameRecipeGivesSameField() {
        let a = Noise.perlin(frequency: 3, seed: 5), b = Noise.perlin(frequency: 3, seed: 5)
        #expect(grid.allSatisfy { a.value(at: $0) == b.value(at: $0) })
    }

    @Test func seedsChangeTheField() {
        let a = Noise.perlin(seed: 1), b = Noise.perlin(seed: 2)
        #expect(grid.contains { a.value(at: $0) != b.value(at: $0) })
    }

    @Test(arguments: [
        Noise.perlin(frequency: 2), .billow(frequency: 2), .ridged(frequency: 2),
        .voronoi(frequency: 3), .rings(frequency: 2), .stripes(frequency: 2), .checkerboard(squareSize: 0.3),
    ])
    func sourcesStayInRangeAndVary(_ noise: Noise) {
        let values = grid.map { noise.value(at: $0) }
        #expect(values.allSatisfy { (-1.0001...1.0001).contains($0) })
        #expect((values.max()! - values.min()!) > 0.5)
    }

    @Test func perlinIsSmooth() {
        let noise = Noise.perlin(frequency: 1, octaves: 1)
        for p in grid {
            #expect(abs(noise.value(at: p) - noise.value(at: p + [1e-4, 0])) < 1e-2)
        }
    }

    @Test func combinatorsDoWhatTheySay() {
        let a = Noise.perlin(seed: 1), b = Noise.billow(seed: 2)
        for p in grid.prefix(50) {
            let x = a.value(at: p), y = b.value(at: p)
            #expect((a + b).value(at: p) == x + y)
            #expect((a * b).value(at: p) == x * y)
            #expect(a.minimum(b).value(at: p) == min(x, y))
            #expect(a.maximum(b).value(at: p) == max(x, y))
            #expect((-a).value(at: p) == -x)
            #expect(a.absolute().value(at: p) == abs(x))
            #expect(a.remapped(scale: 2, bias: 0.5).value(at: p) == x * 2 + 0.5)
            #expect((0...0.2).contains(a.clamped(to: 0...0.2).value(at: p)))
            #expect(a.blended(with: b, by: .constant(-1)).value(at: p) == x)
            #expect(a.blended(with: b, by: .constant(1)).value(at: p) == y)
        }
    }

    @Test func terracesFlattenAtPeaks() {
        let peaks = [-1.0, 0, 1]
        #expect(Noise.constant(0).terraced(peaks: peaks).value(at: .zero) == 0)
        #expect(Noise.constant(-2).terraced(peaks: peaks).value(at: .zero) == -1)
        // Just above a peak stays close to it; just below the next drops toward the last.
        #expect(Noise.constant(0.1).terraced(peaks: peaks).value(at: .zero) < 0.02)
        #expect(Noise.constant(0.9).terraced(peaks: peaks).value(at: .zero) > 0.8)
    }

    @Test func transformsMoveTheField() {
        let base = Noise.perlin(seed: 4)
        let moved = base.transformed(translation: [2, 3])
        let scaled = base.transformed(scale: [2, 2])
        let turned = base.transformed(rotation: .pi / 2)
        for p in grid.prefix(30) {
            #expect(abs(moved.value(at: p + [2, 3]) - base.value(at: p)) < 1e-9)
            #expect(abs(scaled.value(at: p * 2) - base.value(at: p)) < 1e-9)
            #expect(abs(turned.value(at: [-p.y, p.x]) - base.value(at: p)) < 1e-9)
        }
    }

    @Test func turbulenceAndDisplacementWarp() {
        let base = Noise.stripes(frequency: 3)
        let rough = base.turbulent(frequency: 2, power: 0.2, seed: 1)
        let shifted = base.displaced(x: .constant(0.1), y: .constant(0))
        #expect(grid.contains { rough.value(at: $0) != base.value(at: $0) })
        for p in grid.prefix(30) {
            #expect(abs(shifted.value(at: p) - base.value(at: p + [0.1, 0])) < 1e-12)
        }
    }

    @Test func roundTripsThroughCodable() throws {
        let noise = Noise.perlin(frequency: 2, seed: 9)
            .blended(with: .ridged(seed: 3), by: .voronoi(frequency: 2))
            .terraced(peaks: [-0.5, 0.5])
            .turbulent(power: 0.05)
        let decoded = try JSONDecoder().decode(Noise.self, from: JSONEncoder().encode(noise))
        #expect(decoded == noise)
        #expect(grid.allSatisfy { decoded.value(at: $0) == noise.value(at: $0) })
    }

    @Test func farAwayPointsDontTrap() {
        let noise = Noise.perlin() + .voronoi()
        #expect(noise.value(at: [1e15, -1e15]).isFinite)
    }
}

@Suite struct NoiseMapTests {
    @Test func samplesTheGrid() {
        let noise = Noise.perlin(frequency: 3, seed: 2)
        let map = NoiseMap(noise, origin: [1, 2], size: [2, 4], sampleCount: [8, 16])
        #expect(map.values.count == 128)
        #expect(map[3, 5] == Float(noise.value(at: [1 + 3 * 0.25, 2 + 5 * 0.25])))
        #expect(map[-1, 0] == map[7, 0])
    }

    @Test func seamlessMapsWrap() {
        let map = NoiseMap(.perlin(frequency: 4, seed: 6), sampleCount: [64, 64], seamless: true)
        var edgeGap: Float = 0, interiorGap: Float = 0
        for row in 0..<64 {
            edgeGap = max(edgeGap, abs(map[63, row] - map[0, row]))
            edgeGap = max(edgeGap, abs(map[row, 63] - map[row, 0]))
            for column in 0..<63 {
                interiorGap = max(interiorGap, abs(map[column, row] - map[column + 1, row]))
                interiorGap = max(interiorGap, abs(map[row, column] - map[row, column + 1]))
            }
        }
        // Crossing the seam is no bigger a jump than crossing any other column.
        #expect(edgeGap <= interiorGap)
    }

    @Test func normalizeFillsTheRange() {
        var map = NoiseMap(.perlin(seed: 1), sampleCount: [32, 32])
        map.normalize(to: 0...1)
        #expect(abs(map.range.lowerBound) < 1e-6)
        #expect(abs(map.range.upperBound - 1) < 1e-6)
    }

    @Test func gradientBlendsBetweenStops() {
        let ramp = NoiseGradient([.init(1, [0, 0, 1, 1]), .init(0, [1, 0, 0, 1])])
        #expect(ramp.color(at: -5) == [1, 0, 0, 1])
        #expect(ramp.color(at: 0.5) == [0.5, 0, 0.5, 1])
        #expect(ramp.color(at: 9) == [0, 0, 1, 1])
    }

    @Test func pixelsPutTheTopRowFirst() {
        // Stripes turned a quarter turn depend on y: 1 at y = 0, -1 at y = 1.
        let field = Noise.stripes(frequency: 0.5).transformed(rotation: .pi / 2)
        let map = NoiseMap(field, size: [1, 2], sampleCount: [1, 2])
        #expect(map[0, 0] > 0.99 && map[0, 1] < -0.99)
        let pixels = map.rgbaPixels(using: .grayscale)
        #expect(pixels == [0, 0, 0, 255, 255, 255, 255, 255])
    }
}
