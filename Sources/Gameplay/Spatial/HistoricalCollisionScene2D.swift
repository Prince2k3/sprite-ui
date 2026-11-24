import Foundation

/// Invalid or excessive historical query data; queries never mutate a live scene.
public enum HistoricalCollisionError: Error, Equatable, Sendable { case invalidScene, invalidQuery, missingSource, unavailableTarget }

/// One inert affine hit proxy. Incarnation distinguishes a respawn from an older body with the same identity.
public struct HistoricalCollisionBody2D<ID: Hashable & Codable & Sendable>: Codable, Sendable {
    /// Application/network identity, independent of a local entity ID.
    public let id: ID
    /// Fresh body lifetime identifier; do not reuse it for a respawn.
    public let incarnation: UUID
    /// Local convex or edge geometry, bounded to 16 vertices and 10,000 units.
    public let shape: CollisionShape
    /// Scene-space origin and basis, including collider offset, rotation, and scale.
    public let position: SIMD2<Float>
    public let xAxis: SIMD2<Float>
    public let yAxis: SIMD2<Float>
    /// Whether the first ray intersection can be a hit rather than an obstruction.
    public let isTarget: Bool
    /// Whether this proxy obstructs rays, including proximity interaction sight lines.
    public let blocksRays: Bool
    /// Whether this proxy accepts center-distance proximity interactions.
    public let canInteract: Bool
    /// Creates an inert proxy; validate the complete scene before use or presentation.
    public init(id: ID, incarnation: UUID = UUID(), shape: CollisionShape, position: SIMD2<Float>,
                xAxis: SIMD2<Float> = [1, 0], yAxis: SIMD2<Float> = [0, 1],
                isTarget: Bool = true, blocksRays: Bool = true, canInteract: Bool = false) {
        self.id = id; self.incarnation = incarnation; self.shape = shape; self.position = position
        self.xAxis = xAxis; self.yAxis = yAxis; self.isTarget = isTarget; self.blocksRays = blocksRays; self.canInteract = canInteract
    }
    fileprivate var geometry: CollisionGeometry.Shape { .init(shape, position: position, xAxis: xAxis, yAxis: yAxis) }
}

/// A historical nearest intersection; it grants no permission to affect a current entity.
public struct HistoricalCollisionHit2D<ID: Hashable & Codable & Sendable>: Codable, Sendable {
    /// Identity and body lifetime that were present in the queried sample.
    public let id: ID
    public let incarnation: UUID
    /// Scene-space contact and distance from the historical source origin.
    public let position: SIMD2<Float>
    public let distance: Float
    /// Whether the proxy was a target rather than a blocker.
    public let isTarget: Bool
    fileprivate init(_ body: HistoricalCollisionBody2D<ID>, point: SIMD2<Float>, distance: Float, isTarget: Bool? = nil) {
        id = body.id; incarnation = body.incarnation; position = point; self.distance = distance; self.isTarget = isTarget ?? body.isTarget
    }
}

/// A bounded exact sample of inert collision proxies, independent of SpriteKit and ECS.
/// Queries use the historical source origin; clients cannot supply a remote muzzle position.
public struct HistoricalCollisionScene2D<ID: Hashable & Codable & Sendable & Comparable>: Codable, Sendable {
    /// At most 64 uniquely identified proxies. Store only data intended for the recipient.
    public let bodies: [HistoricalCollisionBody2D<ID>]
    /// Creates inert scene data. Validation is explicit and also performed by query methods.
    public init(bodies: [HistoricalCollisionBody2D<ID>]) { self.bodies = bodies }
    /// Validates bounded geometry, unique identities, finite coordinates, and nonsingular bases.
    public func validate() throws {
        guard bodies.count <= 64, Set(bodies.map(\.id)).count == bodies.count else { throw HistoricalCollisionError.invalidScene }
        for body in bodies {
            let vertices: [SIMD2<Float>]
            switch body.shape {
            case .circle(let r): guard r <= 10_000 else { throw HistoricalCollisionError.invalidScene }; vertices = []
            case .rectangle(let size): guard size.x <= 10_000, size.y <= 10_000 else { throw HistoricalCollisionError.invalidScene }; vertices = []
            case .polygon(let p), .edgeLoop(let p), .edgeChain(let p): vertices = p
            }
            guard vertices.count <= 16, vertices.allSatisfy({ bounded($0, limit: 10_000) }), body.shape.isValid,
                  bounded(body.position, limit: 1_000_000), bounded(body.xAxis, limit: 10_000), bounded(body.yAxis, limit: 10_000) else { throw HistoricalCollisionError.invalidScene }
            let determinant = body.xAxis.x * body.yAxis.y - body.xAxis.y * body.yAxis.x
            guard determinant.isFinite, abs(determinant) > 1e-8 else { throw HistoricalCollisionError.invalidScene }
        }
    }
    /// Returns the closest target/blocker along a finite unit direction, with identity-stable ties.
    public func raycast(from source: ID, direction: SIMD2<Float>, range: Float) throws -> HistoricalCollisionHit2D<ID>? {
        try validate()
        let norm = direction.x * direction.x + direction.y * direction.y
        guard bounded(direction, limit: 1), norm.isFinite, abs(norm - 1) <= 0.0001,
              range.isFinite, range > 0, range <= 10_000 else { throw HistoricalCollisionError.invalidQuery }
        guard let origin = bodies.first(where: { $0.id == source })?.position else { throw HistoricalCollisionError.missingSource }
        let end = origin + direction / sqrt(norm) * range
        var best: HistoricalCollisionHit2D<ID>?
        for body in bodies.sorted(by: { $0.id < $1.id }) where body.id != source && (body.isTarget || body.blocksRays) {
            if let hit = CollisionGeometry.raycast(from: origin, to: end, against: body.geometry), hit.distance < (best?.distance ?? .infinity) {
                best = .init(body, point: hit.position, distance: hit.distance)
            }
        }
        return best
    }
    /// Resolves an eligible target within center distance and an unobstructed historical sight line.
    /// A returned blocker has isTarget false; an out-of-range/ineligible target returns nil.
    public func interaction(from source: ID, with target: ID, range: Float) throws -> HistoricalCollisionHit2D<ID>? {
        try validate()
        guard range.isFinite, range > 0, range <= 10_000, source != target else { throw HistoricalCollisionError.invalidQuery }
        guard let origin = bodies.first(where: { $0.id == source })?.position else { throw HistoricalCollisionError.missingSource }
        guard let body = bodies.first(where: { $0.id == target }), body.canInteract else { return nil }
        let delta = body.position - origin, distance = sqrt(delta.x * delta.x + delta.y * delta.y)
        guard distance <= range else { return nil }
        var blocker: HistoricalCollisionHit2D<ID>?
        for wall in bodies.sorted(by: { $0.id < $1.id }) where wall.id != source && wall.id != target && wall.blocksRays {
            if let hit = CollisionGeometry.raycast(from: origin, to: body.position, against: wall.geometry), hit.distance < distance,
               hit.distance < (blocker?.distance ?? .infinity) {
                blocker = .init(wall, point: hit.position, distance: hit.distance, isTarget: false)
            }
        }
        return blocker ?? .init(body, point: body.position, distance: distance, isTarget: true)
    }
    private func bounded(_ point: SIMD2<Float>, limit: Float) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) <= limit && abs(point.y) <= limit
    }
}
