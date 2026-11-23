import Foundation

/// A solid polygon that units can't walk through.
///
/// The points can go either way around; they're stored counter-clockwise
/// (with y pointing up). The polygon may be concave but must not cross itself.
///
/// ```swift
/// let crate = PolygonObstacle(points: [[0, 0], [40, 0], [40, 40], [0, 40]])
/// crate.contains([20, 20])        // true
/// crate.distance(to: [50, 20])    // 10
/// let padded = crate.inflated(by: 12)  // what a unit of radius 12 must stay out of
/// ```
public struct PolygonObstacle: Hashable, Codable, Sendable {
    /// The corners, counter-clockwise.
    public private(set) var points: [SIMD2<Float>]

    /// Points closer than this to an edge count as on the edge.
    static let tolerance: Float = 1e-3

    /// A polygon through `points`, which needs at least three distinct corners.
    public init(points: [SIMD2<Float>]) {
        var cleaned: [SIMD2<Float>] = []
        for point in points where cleaned.last.map({ distanceSquared($0, point) > 1e-12 }) ?? true {
            cleaned.append(point)
        }
        if cleaned.count > 1, distanceSquared(cleaned[0], cleaned[cleaned.count - 1]) <= 1e-12 { cleaned.removeLast() }
        precondition(cleaned.count >= 3, "a polygon obstacle needs at least three corners")
        self.points = Self.signedArea(cleaned) < 0 ? cleaned.reversed() : cleaned
    }

    /// A rectangle filling `box`.
    public init(_ box: BoundingBox) {
        self.init(points: [box.min, [box.max.x, box.min.y], box.max, [box.min.x, box.max.y]])
    }

    /// A rectangle of `size` centered on `center`, turned `rotation` radians counter-clockwise.
    public init(center: SIMD2<Float>, size: SIMD2<Float>, rotation: Float = 0) {
        let half = size / 2
        let s = sin(rotation), c = cos(rotation)
        let corners: [SIMD2<Float>] = [[-half.x, -half.y], [half.x, -half.y], [half.x, half.y], [-half.x, half.y]]
        self.init(points: corners.map { (p: SIMD2<Float>) -> SIMD2<Float> in
            let x: Float = p.x * c - p.y * s
            let y: Float = p.x * s + p.y * c
            return center + SIMD2(x, y)
        })
    }

    /// Each edge as a pair of corners, counter-clockwise.
    public var edges: [(SIMD2<Float>, SIMD2<Float>)] {
        points.indices.map { (points[$0], points[($0 + 1) % points.count]) }
    }

    /// The smallest box around the polygon.
    public var boundingBox: BoundingBox {
        BoundingBox(min: points.dropFirst().reduce(points[0], pointwiseMin),
                    max: points.dropFirst().reduce(points[0], pointwiseMax))
    }

    /// The enclosed area.
    public var area: Float { Self.signedArea(points) }

    /// Whether the corner at `index` points outward. Units steer around these;
    /// inward corners are never on a shortest path.
    public func isConvex(at index: Int) -> Bool {
        let n = points.count
        return cross(points[index] - points[(index + n - 1) % n], points[(index + 1) % n] - points[index]) > 0
    }

    /// Whether `point` is strictly inside. Points on the edge are outside, so
    /// paths can slide along walls.
    public func contains(_ point: SIMD2<Float>) -> Bool {
        guard boundingBox.contains(point) else { return false }
        var inside = false
        for (a, b) in edges {
            if Self.segmentDistanceSquared(from: point, toSegment: a, b) <= Self.tolerance * Self.tolerance { return false }
            if (a.y > point.y) != (b.y > point.y) {
                let x = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if point.x < x { inside.toggle() }
            }
        }
        return inside
    }

    /// The point on the polygon's outline nearest to `point`.
    public func closestPoint(to point: SIMD2<Float>) -> SIMD2<Float> {
        var best = points[0]
        var bestDistance = Float.infinity
        for (a, b) in edges {
            let candidate = Self.closestPoint(to: point, onSegment: a, b)
            let d = distanceSquared(candidate, point)
            if d < bestDistance { best = candidate; bestDistance = d }
        }
        return best
    }

    /// How far `point` is from the outline: positive outside, negative inside.
    public func signedDistance(to point: SIMD2<Float>) -> Float {
        let d = magnitude(closestPoint(to: point) - point)
        return contains(point) ? -d : d
    }

    /// How far `point` is from the polygon, 0 when inside.
    public func distance(to point: SIMD2<Float>) -> Float { max(0, signedDistance(to: point)) }

    /// The polygon grown outward by `radius`: the area a circle of that radius
    /// can't put its center without overlapping this one.
    ///
    /// Sharp outward corners are cut off square rather than drawn out to a long
    /// spike, so the result is never more than about `radius` × 1.5 past a corner.
    public func inflated(by radius: Float) -> PolygonObstacle {
        guard radius > 0 else { return self }
        let n = points.count
        var grown: [SIMD2<Float>] = []
        for i in 0..<n {
            let prev = points[(i + n - 1) % n], v = points[i], next = points[(i + 1) % n]
            let d1 = normalized(v - prev), d2 = normalized(next - v)
            // Outward normals of a counter-clockwise outline point right of each edge.
            let n1 = SIMD2(d1.y, -d1.x), n2 = SIMD2(d2.y, -d2.x)
            let turn = cross(d1, d2)
            let cosine = dot(n1, n2)
            if turn > 0, cosine < 0 {
                // Sharper than a right angle: cut the corner with a line that just
                // touches the circle around it.
                let m = normalized(n1 + n2)
                let s1 = (radius - radius * dot(n1, m)) / dot(d1, m)
                let s2 = (radius - radius * dot(n2, m)) / dot(-d2, m)
                grown.append(v + radius * n1 + s1 * d1)
                grown.append(v + radius * n2 - s2 * d2)
            } else {
                // Where the two pushed-out edges meet.
                grown.append(v + radius * (n1 + n2) / max(1 + cosine, 0.05))
            }
        }
        return PolygonObstacle(points: grown)
    }

    /// Whether the segment from `a` to `b` passes through the inside. Running
    /// along an edge or touching a corner doesn't count.
    public func intersects(segmentFrom a: SIMD2<Float>, to b: SIMD2<Float>) -> Bool {
        let box = boundingBox
        if max(a.x, b.x) < box.min.x || min(a.x, b.x) > box.max.x
            || max(a.y, b.y) < box.min.y || min(a.y, b.y) > box.max.y { return false }

        // Where the segment meets the outline, as fractions of the way from a to b.
        var stops: [Float] = [0, 1]
        let direction = b - a
        let lengthSquared = dot(direction, direction)
        for (c, d) in edges {
            if Self.crossesProperly(a, b, c, d) { return true }
            if lengthSquared > 0, Self.segmentDistanceSquared(from: c, toSegment: a, b) <= Self.tolerance * Self.tolerance {
                stops.append(dot(c - a, direction) / lengthSquared)
            }
        }
        stops.sort()
        for (t0, t1) in zip(stops, stops.dropFirst()) where t1 - t0 > 1e-6 {
            if contains(a + direction * ((t0 + t1) / 2)) { return true }
        }
        return false
    }

    // MARK: Geometry helpers

    static func signedArea(_ points: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for i in points.indices {
            sum += cross(points[i], points[(i + 1) % points.count])
        }
        return sum / 2
    }

    static func closestPoint(to p: SIMD2<Float>, onSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
        let ab = b - a
        let lengthSquared = dot(ab, ab)
        guard lengthSquared > 0 else { return a }
        return a + ab * min(max(dot(p - a, ab) / lengthSquared, 0), 1)
    }

    static func segmentDistanceSquared(from p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        distanceSquared(closestPoint(to: p, onSegment: a, b), p)
    }

    /// Whether segments ab and cd cross at a single point inside both. Touching
    /// at an end or overlapping along a line doesn't count.
    static func crossesProperly(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
        func side(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Int {
            let value = cross(q - p, r - p)
            // Scale the tolerance by the lengths involved so it means a distance.
            let scale = max(magnitude(q - p), 1e-6)
            return value > tolerance * scale ? 1 : value < -tolerance * scale ? -1 : 0
        }
        let s1 = side(a, b, c), s2 = side(a, b, d), s3 = side(c, d, a), s4 = side(c, d, b)
        return s1 * s2 < 0 && s3 * s4 < 0
    }
}

func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

func normalized(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let length = magnitude(v)
    return length > 0 ? v / length : .zero
}
