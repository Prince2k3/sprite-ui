import Foundation

/// Backend-independent convex geometry. Ray intersections are analytic; sweeps
/// use support-mapped distance and conservative advancement, not sampled steps.
public enum CollisionGeometry {
    /// A shape under a complete affine transform, including reflections and shear.
    public struct Shape: Sendable {
        public var shape: CollisionShape
        public var position: SIMD2<Float>
        public var xAxis: SIMD2<Float>
        public var yAxis: SIMD2<Float>
        public init(_ shape: CollisionShape, position: SIMD2<Float> = .zero,
                    xAxis: SIMD2<Float> = [1, 0], yAxis: SIMD2<Float> = [0, 1]) {
            self.shape = shape; self.position = position; self.xAxis = xAxis; self.yAxis = yAxis
        }
    }
    /// A scene-space hit. Normal points outward from the target. Initial interior
    /// hits have a zero normal because no unique contact surface exists.
    public struct Hit: Sendable {
        public let position: SIMD2<Float>
        public let normal: SIMD2<Float>
        public let distance: Float
        public let fraction: Float
    }
    /// Tests a point, including boundaries within 0.00001 scene points.
    public static func contains(_ point: SIMD2<Float>, in target: Shape) -> Bool {
        guard finite(point), let target = Placed(target) else { return false }
        return target.pieces.contains { distance(.point(double(point)), $0).length <= tolerance }
    }
    /// Returns the first segment hit, including a distance-zero initial overlap.
    public static func raycast(from start: SIMD2<Float>, to end: SIMD2<Float>, against shape: Shape) -> Hit? {
        guard finite(start), finite(end), let placed = Placed(shape) else { return nil }
        let a = double(start), delta = double(end) - a
        guard length(delta).isFinite, length(delta) <= Double(Float.greatestFiniteMagnitude) else { return nil }
        let b = a + delta
        let rayBounds = (SIMD2(min(a.x, b.x), min(a.y, b.y)), SIMD2(max(a.x, b.x), max(a.y, b.y)))
        guard intersects(rayBounds, placed.bounds) else { return nil }
        if placed.pieces.contains(where: { distance(.point(a), $0).length <= tolerance }) {
            return hit(point: a, normal: .zero, fraction: 0, travel: length(delta))
        }
        guard length(delta) > 0 else { return nil }
        let localStart = placed.inverse(a), localDelta = placed.inverseDirection(delta)
        var best: (Double, SIMD2<Double>)?
        switch shape.shape {
        case .circle(let radius):
            let aa = collisionDot(localDelta, localDelta)
            let b = collisionDot(localStart, localDelta)
            let c = collisionDot(localStart, localStart) - Double(radius) * Double(radius)
            let disc = b * b - aa * c
            if disc >= 0, aa > 0 {
                let t = (-b - sqrt(disc)) / aa
                if t >= 0, t <= 1 { best = (t, unit(localStart + localDelta * t)) }
            }
        case .rectangle(let size): best = clip(localStart, localDelta, polygon: rectangle(size))
        case .polygon(let points): best = clip(localStart, localDelta, polygon: collisionVertices(points).map(double))
        case .edgeLoop(let raw), .edgeChain(let raw):
            let p = shape.shape.isClosed ? collisionVertices(raw) : raw
            let count = p.count - (shape.shape.isClosed ? 0 : 1)
            for i in 0..<count {
                let a = double(p[i]), b = double(p[(i + 1) % p.count])
                if let t = segment(localStart, localDelta, a, b), t >= 0, t <= 1, t < (best?.0 ?? .infinity) {
                    var normal = unit(SIMD2(-(b - a).y, (b - a).x))
                    if collisionDot(normal, localDelta) > 0 { normal = -normal }
                    best = (t, normal)
                }
            }
        }
        guard let (t, normal) = best else { return nil }
        return hit(point: a + delta * t, normal: placed.normal(normal), fraction: t, travel: length(delta))
    }
    /// Tests filled convex shapes or individual edges. Initial overlap positions
    /// are representative witness points; no penetration depth is computed.
    public static func overlap(_ query: Shape, _ target: Shape) -> Hit? {
        guard let a = Placed(query), let b = Placed(target), intersects(a.bounds, b.bounds) else { return nil }
        for first in a.pieces {
            for second in b.pieces {
                let d = distance(first, second)
                if d.length <= tolerance { return hit(point: d.b, normal: .zero, fraction: 0, travel: 0) }
            }
        }
        return nil
    }
    /// Sweeps a shape by a translation. Its orientation and scale remain fixed.
    /// Supports transformed circles (ellipses), convex polygons, and edge chains.
    public static func sweep(_ query: Shape, by translation: SIMD2<Float>, against target: Shape) -> Hit? {
        guard finite(translation), let a = Placed(query), let b = Placed(target) else { return nil }
        let delta = double(translation), travel = length(delta)
        guard travel.isFinite, travel <= Double(Float.greatestFiniteMagnitude) else { return nil }
        let movedBounds = (a.bounds.0 + delta, a.bounds.1 + delta)
        let swept = (SIMD2(min(a.bounds.0.x, movedBounds.0.x), min(a.bounds.0.y, movedBounds.0.y)),
                     SIMD2(max(a.bounds.1.x, movedBounds.1.x), max(a.bounds.1.y, movedBounds.1.y)))
        guard intersects(swept, b.bounds) else { return nil }
        var best: Hit?
        for first in a.pieces {
            for second in b.pieces {
                var fraction = 0.0, previousNormal = SIMD2<Double>.zero
                for _ in 0..<128 {
                    let d = distance(first.moved(delta * fraction), second)
                    if d.length <= tolerance {
                        let normal = fraction == 0 ? .zero : (d.length > 1e-10 ? unit(d.a - d.b) : previousNormal)
                        if let result = hit(point: d.b, normal: normal, fraction: fraction, travel: travel),
                           result.fraction < (best?.fraction ?? .infinity) { best = result }
                        break
                    }
                    let normal = unit(d.a - d.b)
                    let closing = -collisionDot(normal, delta)
                    guard closing > 1e-12 else { break }
                    let step = max(0, d.length - tolerance * 0.5) / closing
                    guard step.isFinite, step > 0, fraction + step <= 1 + 1e-12 else { break }
                    previousNormal = normal
                    fraction = min(1, fraction + step)
                }
            }
        }
        return best
    }

    private static let tolerance = 1e-5
    private static func double(_ p: SIMD2<Float>) -> SIMD2<Double> { [Double(p.x), Double(p.y)] }
    private static func finite(_ p: SIMD2<Float>) -> Bool { p.x.isFinite && p.y.isFinite }
    private static func length(_ p: SIMD2<Double>) -> Double { sqrt(collisionDot(p, p)) }
    private static func unit(_ p: SIMD2<Double>) -> SIMD2<Double> { let m = length(p); return m > 0 ? p / m : .zero }
    private static func hit(point: SIMD2<Double>, normal: SIMD2<Double>, fraction: Double, travel: Double) -> Hit? {
        let p = SIMD2<Float>(Float(point.x), Float(point.y))
        guard finite(p), fraction.isFinite else { return nil }
        return Hit(position: p, normal: [Float(normal.x), Float(normal.y)], distance: Float(travel * fraction), fraction: Float(fraction))
    }
    private static func rectangle(_ size: SIMD2<Float>) -> [SIMD2<Double>] {
        let h = double(size) / 2
        return [[-h.x, -h.y], [h.x, -h.y], [h.x, h.y], [-h.x, h.y]]
    }
    private static func intersects(_ a: (SIMD2<Double>, SIMD2<Double>), _ b: (SIMD2<Double>, SIMD2<Double>)) -> Bool {
        a.0.x <= b.1.x + tolerance && a.1.x + tolerance >= b.0.x && a.0.y <= b.1.y + tolerance && a.1.y + tolerance >= b.0.y
    }
    private static func clip(_ start: SIMD2<Double>, _ delta: SIMD2<Double>, polygon: [SIMD2<Double>]) -> (Double, SIMD2<Double>)? {
        let area = polygon.indices.reduce(0.0) { $0 + collisionCross(polygon[$1], polygon[($1 + 1) % polygon.count]) }
        let sign = area > 0 ? 1.0 : -1.0
        var enter = 0.0, exit = 1.0, normal = SIMD2<Double>.zero
        for i in polygon.indices {
            let a = polygon[i], edge = polygon[(i + 1) % polygon.count] - a
            let n = unit(SIMD2(edge.y, -edge.x) * sign)
            let gap = collisionDot(n, start - a), slope = collisionDot(n, delta)
            if abs(slope) < 1e-14 { if gap > 0 { return nil }; continue }
            let t = -gap / slope
            if slope < 0 { if t > enter { enter = t; normal = n } }
            else { exit = min(exit, t) }
            if enter > exit { return nil }
        }
        return enter >= 0 && enter <= 1 ? (enter, normal) : nil
    }
    private static func segment(_ p: SIMD2<Double>, _ delta: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double? {
        let edge = b - a, denominator = collisionCross(delta, edge)
        if abs(denominator) < 1e-14 {
            guard abs(collisionCross(a - p, delta)) < 1e-12 else { return nil }
            let length2 = collisionDot(delta, delta)
            guard length2 > 0 else { return nil }
            let x = collisionDot(a - p, delta) / length2, y = collisionDot(b - p, delta) / length2
            let first = max(0, min(x, y)), last = min(1, max(x, y))
            return first <= last ? first : nil
        }
        let t = collisionCross(a - p, edge) / denominator, u = collisionCross(a - p, delta) / denominator
        return u >= 0 && u <= 1 ? t : nil
    }

    private struct Placed {
        let source: Shape
        let x: SIMD2<Double>, y: SIMD2<Double>, origin: SIMD2<Double>
        let determinant: Double
        let pieces: [Primitive]
        let bounds: (SIMD2<Double>, SIMD2<Double>)
        init?(_ shape: Shape) {
            guard shape.shape.isValid, finite(shape.position), finite(shape.xAxis), finite(shape.yAxis) else { return nil }
            let x = double(shape.xAxis), y = double(shape.yAxis), origin = double(shape.position)
            source = shape; self.x = x; self.y = y; self.origin = origin
            determinant = collisionCross(x, y)
            guard determinant.isFinite, determinant != 0 else { return nil }
            func map(_ p: SIMD2<Double>) -> SIMD2<Double> { origin + x * p.x + y * p.y }
            switch shape.shape {
            case .circle(let radius): pieces = [.ellipse(origin, x * Double(radius), y * Double(radius))]
            case .rectangle(let size): pieces = [.polygon(rectangle(size).map(map))]
            case .polygon(let points): pieces = [.polygon(collisionVertices(points).map { map(double($0)) })]
            case .edgeLoop(let raw), .edgeChain(let raw):
                let points = shape.shape.isClosed ? collisionVertices(raw) : raw
                let count = points.count - (shape.shape.isClosed ? 0 : 1)
                pieces = (0..<count).map { .polygon([map(double(points[$0])), map(double(points[($0 + 1) % points.count]))]) }
            }
            let maxX = pieces.map { $0.support([1, 0]).x }.max()!, minX = pieces.map { $0.support([-1, 0]).x }.min()!
            let maxY = pieces.map { $0.support([0, 1]).y }.max()!, minY = pieces.map { $0.support([0, -1]).y }.min()!
            bounds = ([minX, minY], [maxX, maxY])
        }
        func inverseDirection(_ p: SIMD2<Double>) -> SIMD2<Double> { [collisionCross(p, y) / determinant, collisionCross(x, p) / determinant] }
        func inverse(_ p: SIMD2<Double>) -> SIMD2<Double> { inverseDirection(p - origin) }
        func normal(_ n: SIMD2<Double>) -> SIMD2<Double> { unit(SIMD2(y.y * n.x - x.y * n.y, -y.x * n.x + x.x * n.y) / determinant) }
    }
    private enum Primitive {
        case point(SIMD2<Double>)
        case ellipse(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)
        case polygon([SIMD2<Double>])
        func support(_ direction: SIMD2<Double>) -> SIMD2<Double> {
            switch self {
            case .point(let p): return p
            case .ellipse(let center, let x, let y):
                let local = unit(SIMD2(collisionDot(x, direction), collisionDot(y, direction)))
                return center + x * local.x + y * local.y
            case .polygon(let points): return points.max { collisionDot($0, direction) < collisionDot($1, direction) }!
            }
        }
        func moved(_ offset: SIMD2<Double>) -> Self {
            switch self { case .point(let p): .point(p + offset)
            case .ellipse(let c, let x, let y): .ellipse(c + offset, x, y)
            case .polygon(let p): .polygon(p.map { $0 + offset }) }
        }
    }
    private struct Vertex {
        let a: SIMD2<Double>, b: SIMD2<Double>
        var p: SIMD2<Double> { a - b }
    }
    private struct Distance {
        var simplex: [Vertex]
        var weights: [Double]
        var a: SIMD2<Double> { zip(simplex, weights).reduce(.zero) { $0 + $1.0.a * $1.1 } }
        var b: SIMD2<Double> { zip(simplex, weights).reduce(.zero) { $0 + $1.0.b * $1.1 } }
        var p: SIMD2<Double> { a - b }
        var length: Double { CollisionGeometry.length(p) }
    }
    private static func closest(_ simplex: [Vertex]) -> Distance {
        if simplex.count == 1 { return Distance(simplex: simplex, weights: [1]) }
        func edge(_ a: Vertex, _ b: Vertex) -> Distance {
            let d = b.p - a.p, n = collisionDot(d, d)
            let t = n > 0 ? min(1, max(0, -collisionDot(a.p, d) / n)) : 0
            if t == 0 { return Distance(simplex: [a], weights: [1]) }
            if t == 1 { return Distance(simplex: [b], weights: [1]) }
            return Distance(simplex: [a, b], weights: [1 - t, t])
        }
        if simplex.count == 2 { return edge(simplex[0], simplex[1]) }
        let a = simplex[0].p, b = simplex[1].p, c = simplex[2].p
        let area = collisionCross(b - a, c - a)
        if abs(area) > 1e-24 {
            let u = collisionCross(b, c) / area, v = collisionCross(c, a) / area, w = collisionCross(a, b) / area
            if min(u, min(v, w)) >= 0 { return Distance(simplex: simplex, weights: [u, v, w]) }
        }
        return [edge(simplex[0], simplex[1]), edge(simplex[1], simplex[2]), edge(simplex[2], simplex[0])].min { $0.length < $1.length }!
    }
    private static func distance(_ a: Primitive, _ b: Primitive) -> Distance {
        func support(_ d: SIMD2<Double>) -> Vertex { Vertex(a: a.support(d), b: b.support(-d)) }
        var result = closest([support([1, 0])])
        for _ in 0..<64 {
            let p = result.p, length2 = collisionDot(p, p)
            if length2 < 1e-24 { return result }
            let candidate = support(-p)
            let progress = length2 - collisionDot(p, candidate.p)
            if progress <= 1e-12 * max(1, length2) || result.simplex.contains(where: { length($0.p - candidate.p) < 1e-12 }) { return result }
            result = closest(result.simplex + [candidate])
        }
        return result
    }
}

private extension CollisionShape {
    var isClosed: Bool { if case .edgeLoop = self { true } else { false } }
}
