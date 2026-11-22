/// An axis-aligned rectangle, in place of `GKQuad`.
///
/// `min` is the bottom-left corner and `max` the top-right, with +y up like the scene.
public struct BoundingBox: Hashable, Codable, Sendable, CustomStringConvertible {
    public var min: SIMD2<Float>
    public var max: SIMD2<Float>

    public init(min: SIMD2<Float>, max: SIMD2<Float>) {
        self.min = min
        self.max = max
    }

    /// A box of `size` centered on `center`.
    public init(center: SIMD2<Float>, size: SIMD2<Float>) {
        self.init(min: center - size / 2, max: center + size / 2)
    }

    /// The square that encloses a circle.
    public init(center: SIMD2<Float>, radius: Float) {
        self.init(min: center - radius, max: center + radius)
    }

    public var center: SIMD2<Float> { (min + max) / 2 }
    public var size: SIMD2<Float> { max - min }

    /// Whether `point` is inside, edges included.
    public func contains(_ point: SIMD2<Float>) -> Bool {
        all(point .>= min) && all(point .<= max)
    }

    /// Whether `other` is entirely inside this box.
    public func contains(_ other: BoundingBox) -> Bool {
        all(other.min .>= min) && all(other.max .<= max)
    }

    /// Whether the boxes overlap or touch.
    public func intersects(_ other: BoundingBox) -> Bool {
        all(other.min .<= max) && all(other.max .>= min)
    }

    /// Whether the box overlaps a circle.
    public func intersects(circleAt center: SIMD2<Float>, radius: Float) -> Bool {
        distanceSquared(to: center) <= radius * radius
    }

    /// The squared distance from `point` to the nearest point of the box; 0 inside it.
    public func distanceSquared(to point: SIMD2<Float>) -> Float {
        let clamped = simd_clamp(point, min, max)
        let delta = point - clamped
        return (delta * delta).sum()
    }

    /// The smallest box enclosing both.
    public func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }

    /// The four quarters: bottom-left, bottom-right, top-left, top-right.
    public var quadrants: [BoundingBox] {
        let mid = center
        return [
            BoundingBox(min: min, max: mid),
            BoundingBox(min: [mid.x, min.y], max: [max.x, mid.y]),
            BoundingBox(min: [min.x, mid.y], max: [mid.x, max.y]),
            BoundingBox(min: mid, max: max),
        ]
    }

    public var description: String { "[\(min.x), \(min.y)]…[\(max.x), \(max.y)]" }
}

@inline(__always)
func distanceSquared(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let delta = a - b
    return (delta * delta).sum()
}

@inline(__always)
private func simd_clamp(_ x: SIMD2<Float>, _ lo: SIMD2<Float>, _ hi: SIMD2<Float>) -> SIMD2<Float> {
    x.clamped(lowerBound: lo, upperBound: hi)
}

@inline(__always)
private func simd_min(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { pointwiseMin(a, b) }

@inline(__always)
private func simd_max(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { pointwiseMax(a, b) }
