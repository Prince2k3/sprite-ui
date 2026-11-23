import Foundation

/// A 2D coherent noise field.
///
/// Start from a source such as ``perlin(frequency:octaves:persistence:lacunarity:seed:)``
/// and build on it: combine fields with `+`, `*`, ``minimum(_:)`` or
/// ``blended(with:by:)``, reshape values with ``remapped(scale:bias:)`` or
/// ``terraced(peaks:)``, and warp space with ``transformed(translation:scale:rotation:)``,
/// ``turbulent(frequency:power:roughness:seed:)`` or ``displaced(x:y:strength:)``.
///
/// A `Noise` is a plain value: the same recipe always gives the same field, and it
/// encodes to a small description rather than to samples. Sample it with
/// ``value(at:)`` or fill a ``NoiseMap``.
///
/// ```swift
/// let terrain = Noise.perlin(frequency: 2, seed: 7)
///     .blended(with: .ridged(frequency: 3, seed: 8), by: .perlin(frequency: 0.5, seed: 9))
///     .terraced(peaks: [-1, -0.2, 0.3, 1])
/// let height = terrain.value(at: [0.25, 0.75])
/// ```
public struct Noise: Hashable, Codable, Sendable {
    indirect enum Node: Hashable, Codable, Sendable {
        case perlin(frequency: Double, octaves: Int, persistence: Double, lacunarity: Double, seed: Int32)
        case billow(frequency: Double, octaves: Int, persistence: Double, lacunarity: Double, seed: Int32)
        case ridged(frequency: Double, octaves: Int, lacunarity: Double, seed: Int32)
        case voronoi(frequency: Double, displacement: Double, includesDistance: Bool, seed: Int32)
        case rings(frequency: Double)
        case stripes(frequency: Double)
        case checkerboard(squareSize: Double)
        case constant(Double)

        case add(Node, Node)
        case multiply(Node, Node)
        case minimum(Node, Node)
        case maximum(Node, Node)
        case blend(Node, Node, selector: Node)

        case absolute(Node)
        case invert(Node)
        case clamp(Node, lower: Double, upper: Double)
        case remap(Node, scale: Double, bias: Double)
        case terrace(Node, peaks: [Double])

        case transform(Node, translation: SIMD2<Double>, scale: SIMD2<Double>, rotation: Double)
        case turbulence(Node, frequency: Double, power: Double, roughness: Int, seed: Int32)
        case displace(Node, x: Node, y: Node, strength: Double)
    }

    let node: Node

    init(_ node: Node) {
        self.node = node
    }

    /// The field's value at `point`, roughly in -1...1 for the sources.
    public func value(at point: SIMD2<Double>) -> Double {
        node.value(point.x, point.y)
    }
}

// MARK: Sources

extension Noise {
    /// Smooth hills: fractal Perlin gradient noise.
    ///
    /// - Parameters:
    ///   - frequency: Features per unit at the first octave.
    ///   - octaves: Layers of finer detail added on top. More is rougher and slower.
    ///   - persistence: How much each octave counts compared with the one before.
    ///   - lacunarity: How much finer each octave is than the one before.
    public static func perlin(
        frequency: Double = 1, octaves: Int = 6, persistence: Double = 0.5, lacunarity: Double = 2, seed: Int32 = 0
    ) -> Noise {
        Noise(.perlin(frequency: frequency, octaves: max(octaves, 1), persistence: persistence, lacunarity: lacunarity, seed: seed))
    }

    /// Puffy, cloud-like lumps.
    public static func billow(
        frequency: Double = 1, octaves: Int = 6, persistence: Double = 0.5, lacunarity: Double = 2, seed: Int32 = 0
    ) -> Noise {
        Noise(.billow(frequency: frequency, octaves: max(octaves, 1), persistence: persistence, lacunarity: lacunarity, seed: seed))
    }

    /// Sharp ridges, like mountain ranges.
    public static func ridged(
        frequency: Double = 1, octaves: Int = 6, lacunarity: Double = 2, seed: Int32 = 0
    ) -> Noise {
        Noise(.ridged(frequency: frequency, octaves: max(octaves, 1), lacunarity: lacunarity, seed: seed))
    }

    /// Flat cells, each with its own value.
    ///
    /// - Parameters:
    ///   - displacement: How far apart the cells' values spread.
    ///   - includesDistance: Whether to add the distance to the cell's center, which
    ///     shades each cell from its middle out. Values then reach about -2...2.
    public static func voronoi(
        frequency: Double = 1, displacement: Double = 1, includesDistance: Bool = false, seed: Int32 = 0
    ) -> Noise {
        Noise(.voronoi(frequency: frequency, displacement: displacement, includesDistance: includesDistance, seed: seed))
    }

    /// Concentric rings around the origin.
    public static func rings(frequency: Double = 1) -> Noise {
        Noise(.rings(frequency: frequency))
    }

    /// Parallel bands across x.
    public static func stripes(frequency: Double = 1) -> Noise {
        Noise(.stripes(frequency: frequency))
    }

    /// Alternating squares of 1 and -1.
    public static func checkerboard(squareSize: Double = 1) -> Noise {
        Noise(.checkerboard(squareSize: squareSize))
    }

    /// The same value everywhere.
    public static func constant(_ value: Double) -> Noise {
        Noise(.constant(value))
    }
}

// MARK: Combining

extension Noise {
    public static func + (lhs: Noise, rhs: Noise) -> Noise { Noise(.add(lhs.node, rhs.node)) }
    public static func * (lhs: Noise, rhs: Noise) -> Noise { Noise(.multiply(lhs.node, rhs.node)) }
    /// Flips the field, so peaks become valleys.
    public static prefix func - (noise: Noise) -> Noise { Noise(.invert(noise.node)) }

    /// The lower of the two fields at each point.
    public func minimum(_ other: Noise) -> Noise { Noise(.minimum(node, other.node)) }
    /// The higher of the two fields at each point.
    public func maximum(_ other: Noise) -> Noise { Noise(.maximum(node, other.node)) }

    /// Fades from this field (where `selector` is -1) to `other` (where it's 1).
    public func blended(with other: Noise, by selector: Noise) -> Noise {
        Noise(.blend(node, other.node, selector: selector.node))
    }
}

// MARK: Reshaping values

extension Noise {
    /// Folds negative values up, which makes creases where the field crossed zero.
    public func absolute() -> Noise { Noise(.absolute(node)) }

    /// Holds values inside `range`.
    public func clamped(to range: ClosedRange<Double>) -> Noise {
        Noise(.clamp(node, lower: range.lowerBound, upper: range.upperBound))
    }

    /// Multiplies values by `scale`, then adds `bias`.
    public func remapped(scale: Double = 1, bias: Double = 0) -> Noise {
        Noise(.remap(node, scale: scale, bias: bias))
    }

    /// Turns slopes into steps that flatten out at each of `peaks`, like terraced
    /// hillsides.
    public func terraced(peaks: [Double]) -> Noise {
        Noise(.terrace(node, peaks: Array(Set(peaks)).sorted()))
    }
}

// MARK: Warping space

extension Noise {
    /// Moves, stretches and turns the field. A scale above 1 makes features bigger.
    public func transformed(
        translation: SIMD2<Double> = .zero, scale: SIMD2<Double> = [1, 1], rotation: Double = 0
    ) -> Noise {
        Noise(.transform(node, translation: translation, scale: scale, rotation: rotation))
    }

    /// Jostles each point by a random amount, roughening edges.
    ///
    /// - Parameters:
    ///   - power: How far points can move.
    ///   - roughness: Octaves in the jostling noise.
    public func turbulent(frequency: Double = 1, power: Double = 0.1, roughness: Int = 3, seed: Int32 = 0) -> Noise {
        Noise(.turbulence(node, frequency: frequency, power: power, roughness: max(roughness, 1), seed: seed))
    }

    /// Moves each point by `x` and `y` times `strength`.
    public func displaced(x: Noise, y: Noise, strength: Double = 1) -> Noise {
        Noise(.displace(node, x: x.node, y: y.node, strength: strength))
    }
}

// MARK: Evaluation

extension Noise.Node {
    func value(_ x: Double, _ y: Double) -> Double {
        switch self {
        case let .perlin(frequency, octaves, persistence, lacunarity, seed):
            return fractal(x, y, frequency, octaves, persistence, lacunarity, seed) { $0 }
        case let .billow(frequency, octaves, persistence, lacunarity, seed):
            return fractal(x, y, frequency, octaves, persistence, lacunarity, seed) { 2 * abs($0) - 1 }
        case let .ridged(frequency, octaves, lacunarity, seed):
            // Each octave's crease is a ridge in 0...1; spread the sum back to -1...1.
            let sum = fractal(x, y, frequency, octaves, 0.5, lacunarity, seed) { n in
                let ridge = 1 - abs(n)
                return ridge * ridge
            }
            return 2 * sum - 1
        case let .voronoi(frequency, displacement, includesDistance, seed):
            return voronoiValue(x * frequency, y * frequency, displacement, includesDistance, seed)
        case let .rings(frequency):
            return triangle((x * x + y * y).squareRoot() * frequency)
        case let .stripes(frequency):
            return triangle(abs(x) * frequency)
        case let .checkerboard(squareSize):
            guard squareSize > 0 else { return 1 }
            let cell = Int((x / squareSize).rounded(.down)) &+ Int((y / squareSize).rounded(.down))
            return cell & 1 == 0 ? 1 : -1
        case let .constant(value):
            return value

        case let .add(a, b):
            return a.value(x, y) + b.value(x, y)
        case let .multiply(a, b):
            return a.value(x, y) * b.value(x, y)
        case let .minimum(a, b):
            return min(a.value(x, y), b.value(x, y))
        case let .maximum(a, b):
            return max(a.value(x, y), b.value(x, y))
        case let .blend(a, b, selector):
            let t = min(max((selector.value(x, y) + 1) / 2, 0), 1)
            return a.value(x, y) * (1 - t) + b.value(x, y) * t

        case let .absolute(a):
            return abs(a.value(x, y))
        case let .invert(a):
            return -a.value(x, y)
        case let .clamp(a, lower, upper):
            return min(max(a.value(x, y), lower), upper)
        case let .remap(a, scale, bias):
            return a.value(x, y) * scale + bias
        case let .terrace(a, peaks):
            return terraceValue(a.value(x, y), peaks)

        case let .transform(a, translation, scale, rotation):
            // Undo the transform on the point, so the field moves the stated way.
            var px = x - translation.x, py = y - translation.y
            if rotation != 0 {
                let c = cos(-rotation), s = sin(-rotation)
                (px, py) = (px * c - py * s, px * s + py * c)
            }
            return a.value(scale.x != 0 ? px / scale.x : 0, scale.y != 0 ? py / scale.y : 0)
        case let .turbulence(a, frequency, power, roughness, seed):
            let dx = fractal(x, y, frequency, roughness, 0.5, 2, seed) { $0 }
            let dy = fractal(x + 12.71, y + 31.17, frequency, roughness, 0.5, 2, seed &+ 7919) { $0 }
            return a.value(x + dx * power, y + dy * power)
        case let .displace(a, dx, dy, strength):
            return a.value(x + dx.value(x, y) * strength, y + dy.value(x, y) * strength)
        }
    }
}

/// Sums `octaves` layers of gradient noise, each `shape`d, and scales the total
/// back into the range of one layer.
private func fractal(
    _ x: Double, _ y: Double,
    _ frequency: Double, _ octaves: Int, _ persistence: Double, _ lacunarity: Double, _ seed: Int32,
    shape: (Double) -> Double
) -> Double {
    var total = 0.0, amplitude = 1.0, weight = 0.0, f = frequency
    for octave in 0..<octaves {
        total += shape(gradientNoise(x * f, y * f, seed &+ Int32(truncatingIfNeeded: octave))) * amplitude
        weight += amplitude
        amplitude *= persistence
        f *= lacunarity
    }
    return weight > 0 ? total / weight : 0
}

/// 1 at whole numbers, -1 halfway between, linear in between.
private func triangle(_ t: Double) -> Double {
    let f = t - t.rounded(.down)
    return 1 - 4 * min(f, 1 - f)
}

private func terraceValue(_ value: Double, _ peaks: [Double]) -> Double {
    guard peaks.count > 1 else { return peaks.first ?? value }
    if value <= peaks[0] { return peaks[0] }
    if value >= peaks[peaks.count - 1] { return peaks[peaks.count - 1] }
    var i = 1
    while peaks[i] < value { i += 1 }
    let low = peaks[i - 1], high = peaks[i]
    var t = (value - low) / (high - low)
    t *= t   // flat just above each peak, steep just below the next
    return low + (high - low) * t
}

// MARK: Primitives

/// Mixes a lattice point and a seed into 32 well-scrambled bits.
@inline(__always)
func latticeHash(_ x: Int, _ y: Int, _ seed: Int32) -> UInt32 {
    var h = UInt32(bitPattern: seed) &* 0x9E37_79B9
    h ^= UInt32(truncatingIfNeeded: x) &* 0x85EB_CA6B
    h = (h << 13) | (h >> 19)
    h ^= UInt32(truncatingIfNeeded: y) &* 0xC2B2_AE35
    h ^= h >> 16
    h &*= 0x7FEB_352D
    h ^= h >> 15
    h &*= 0x846C_A68B
    h ^= h >> 16
    return h
}

/// One layer of 2D Perlin gradient noise, in -1...1.
func gradientNoise(_ x: Double, _ y: Double, _ seed: Int32) -> Double {
    let fx = x.rounded(.down), fy = y.rounded(.down)
    // Wrap far-off coordinates instead of trapping; the pattern just repeats.
    let ix = Int(fx.truncatingRemainder(dividingBy: 1_073_741_824))
    let iy = Int(fy.truncatingRemainder(dividingBy: 1_073_741_824))
    let dx = x - fx, dy = y - fy

    @inline(__always) func corner(_ cx: Int, _ cy: Int, _ ox: Double, _ oy: Double) -> Double {
        // Eight evenly spaced unit gradients.
        switch latticeHash(cx, cy, seed) & 7 {
        case 0: return ox
        case 1: return -ox
        case 2: return oy
        case 3: return -oy
        case 4: return (ox + oy) * 0.7071067811865476
        case 5: return (ox - oy) * 0.7071067811865476
        case 6: return (-ox + oy) * 0.7071067811865476
        default: return (-ox - oy) * 0.7071067811865476
        }
    }

    let n00 = corner(ix, iy, dx, dy)
    let n10 = corner(ix &+ 1, iy, dx - 1, dy)
    let n01 = corner(ix, iy &+ 1, dx, dy - 1)
    let n11 = corner(ix &+ 1, iy &+ 1, dx - 1, dy - 1)

    let u = fade(dx), v = fade(dy)
    let bottom = n00 + (n10 - n00) * u
    let top = n01 + (n11 - n01) * u
    // Unit gradients peak at √½; stretch to fill -1...1.
    return min(max((bottom + (top - bottom) * v) * 1.4142135623730951, -1), 1)
}

@inline(__always)
private func fade(_ t: Double) -> Double {
    t * t * t * (t * (t * 6 - 15) + 10)
}

private func voronoiValue(_ x: Double, _ y: Double, _ displacement: Double, _ includesDistance: Bool, _ seed: Int32) -> Double {
    let cx = Int(x.rounded(.down).truncatingRemainder(dividingBy: 1_073_741_824))
    let cy = Int(y.rounded(.down).truncatingRemainder(dividingBy: 1_073_741_824))
    let baseX = x.rounded(.down), baseY = y.rounded(.down)
    var best = Double.infinity, bestCell = (0, 0)
    for oy in -1...1 {
        for ox in -1...1 {
            let h = latticeHash(cx &+ ox, cy &+ oy, seed)
            // Each cell's center sits somewhere random inside it.
            let px = baseX + Double(ox) + Double(h & 0xFFFF) / 65536
            let py = baseY + Double(oy) + Double(h >> 16) / 65536
            let d = (px - x) * (px - x) + (py - y) * (py - y)
            if d < best {
                best = d
                bestCell = (cx &+ ox, cy &+ oy)
            }
        }
    }
    let cellValue = Double(latticeHash(bestCell.0, bestCell.1, seed &+ 1)) / Double(UInt32.max) * 2 - 1
    var value = cellValue * displacement
    if includesDistance { value += min(best.squareRoot(), 1) * 2 - 1 }
    return value
}
