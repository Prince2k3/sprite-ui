import Foundation

/// A local-space collision outline, shared by scene queries and rigid bodies.
/// Polygons must be convex; either winding is accepted. Edge shapes have no inside.
public enum CollisionShape: Hashable, Codable, Sendable {
    case circle(radius: Float)
    case rectangle(size: SIMD2<Float>)
    case polygon([SIMD2<Float>])
    case edgeLoop([SIMD2<Float>])
    case edgeChain([SIMD2<Float>])

    /// Creates a closed rectangular boundary centered on the origin.
    public static func edgeLoop(rectangle size: SIMD2<Float>) -> Self {
        let h = size / 2
        return .edgeLoop([[-h.x, -h.y], [h.x, -h.y], [h.x, h.y], [-h.x, h.y]])
    }
    /// Whether this is a boundary rather than a filled shape.
    public var isEdge: Bool {
        switch self { case .edgeLoop, .edgeChain: true; default: false }
    }
    /// Whether dimensions are finite and positive and a polygon is convex.
    /// Invalid shapes are ignored by scene queries and the physics backend.
    /// - Complexity: O(v²) for polygons, O(v) for edges, O(1) otherwise.
    public var isValid: Bool {
        switch self {
        case .circle(let r): return r.isFinite && r > 0
        case .rectangle(let s): return s.x.isFinite && s.y.isFinite && s.x > 0 && s.y > 0
        case .polygon(let raw):
            let p = collisionVertices(raw)
            guard p.count >= 3, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), Set(p).count == p.count else { return false }
            let points = p.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
            let area = points.indices.reduce(0.0) { $0 + collisionCross(points[$1], points[($1 + 1) % points.count]) }
            guard area.isFinite, area != 0 else { return false }
            let sign = area > 0 ? 1.0 : -1.0
            for i in points.indices {
                let a = points[i], edge = points[(i + 1) % points.count] - a
                guard collisionDot(edge, edge) > 0 else { return false }
                for point in points where sign * collisionCross(edge, point - a) < -1e-12 { return false }
            }
            return true
        case .edgeLoop(let raw), .edgeChain(let raw):
            let p = isEdgeLoop ? collisionVertices(raw) : raw
            guard p.count >= (isEdgeLoop ? 3 : 2), p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            for i in 1..<p.count where p[i] == p[i - 1] { return false }
            return !isEdgeLoop || p.first != p.last
        }
    }
    private var isEdgeLoop: Bool { if case .edgeLoop = self { true } else { false } }
}

func collisionDot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a * b).sum() }
func collisionCross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }

// A repeated closing vertex is accepted for editor/exporter compatibility.
func collisionVertices(_ raw: [SIMD2<Float>]) -> [SIMD2<Float>] {
    if raw.count > 1, raw.first == raw.last { return Array(raw.dropLast()) }
    return raw
}
