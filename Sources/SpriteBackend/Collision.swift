import ECSCore
import Foundation
@_exported import Gameplay
import SpriteKit

/// Up to 32 named collision categories. Define app groups with `CollisionGroup(rawValue: 1 << n)`.
public struct CollisionGroup: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let `default` = Self(rawValue: 1)
    public static let all = Self(rawValue: .max)
    public static let none: Self = []
}

/// Membership and the categories an object can collide with. Query masks can
/// inspect objects independently of physical collision response.
public struct CollisionFilter: Hashable, Codable, Sendable {
    public var group: CollisionGroup
    public var mask: CollisionGroup
    public init(group: CollisionGroup = .default, mask: CollisionGroup = .all) { self.group = group; self.mask = mask }
    public func allows(_ other: Self) -> Bool { !group.intersection(other.mask).isEmpty && !other.group.intersection(mask).isEmpty }
}

/// An explicit local-space shape for queries and targeted input, including
/// invisible interaction areas. With a PhysicsBodyComponent, it also supplies
/// the simulated body's shape, offset and category/collision masks. Removing it
/// restores that body's original shape and masks. Disabling removes the body
/// and suppresses queries/input until re-enabled, keeping component velocities.
public struct CollisionComponent: Component, Hashable, Codable, Sendable {
    public var shape: CollisionShape
    public var offset: SIMD2<Float>
    public var filter: CollisionFilter
    public var isEnabled: Bool
    public init(shape: CollisionShape, offset: SIMD2<Float> = .zero, filter: CollisionFilter = .init(), isEnabled: Bool = true) {
        self.shape = shape; self.offset = offset; self.filter = filter; self.isEnabled = isEnabled
    }
}

/// Query categories and exclusions. A nil group inspects all matching targets,
/// including masks that disable physical response. Supply a group to also test
/// the target's collision mask. Exclusions contain exact entity IDs.
public struct CollisionQueryFilter: Hashable, Sendable {
    public var mask: CollisionGroup
    public var group: CollisionGroup?
    public var excluding: Set<Entity.ID>
    public init(mask: CollisionGroup = .all, group: CollisionGroup? = nil, excluding: Set<Entity.ID> = []) {
        self.mask = mask; self.group = group; self.excluding = excluding
    }
    func includes(_ entity: Entity, filter: CollisionFilter) -> Bool {
        !excluding.contains(entity.id) && !mask.intersection(filter.group).isEmpty &&
            (group.map { !$0.intersection(filter.mask).isEmpty } ?? true)
    }
}

/// Nearest returns at most one entity; all returns every hit in distance order.
public enum CollisionQueryMode: Sendable { case nearest, all }

/// A model-space query result expressed in scene coordinates. Normal is outward
/// from the target, with zero for initial interior/overlap hits. Distance is how
/// far the ray or moving shape traveled, and fraction is its segment fraction.
@MainActor
public struct CollisionHit {
    public let entity: Entity
    public let position: SIMD2<Float>
    public let normal: SIMD2<Float>
    public let distance: Float
    public let fraction: Float
    init(entity: Entity, geometry: CollisionGeometry.Hit) {
        self.entity = entity; position = geometry.position; normal = geometry.normal; distance = geometry.distance; fraction = geometry.fraction
    }
}

extension Entity {
    // Explicit colliders take precedence, including disabled/invalid ones, so
    // removing response never unexpectedly exposes a different fallback shape.
    var queryCollider: CollisionComponent? {
        if let component = components[CollisionComponent.self] { return component }
        guard let body = components[PhysicsBodyComponent.self] else { return nil }
        return CollisionComponent(shape: body.shape, filter: .init(group: .init(rawValue: body.categoryBitMask), mask: .init(rawValue: body.collisionBitMask)))
    }
}

extension World {
    /// Casts a finite segment through current model transforms. Works without a
    /// renderer and sees edits immediately. Ties are ordered by entity ID.
    /// - Complexity: O(n) candidate traversal, plus narrow-phase geometry and hit sorting.
    public func raycast(from start: SIMD2<Float>, to end: SIMD2<Float>, query: CollisionQueryMode = .nearest,
                        filter: CollisionQueryFilter = .init()) -> [CollisionHit] {
        queryColliders(filter: filter).compactMap { entity, shape in
            CollisionGeometry.raycast(from: start, to: end, against: shape).map { CollisionHit(entity: entity, geometry: $0) }
        }.ordered(query)
    }
    /// Finds all colliders touching a shape under a complete affine transform.
    /// Unlike gesture hit-testing, this reads model transforms, not animation presentation.
    /// - Complexity: O(n) candidate traversal, plus narrow-phase geometry and hit sorting.
    public func overlaps(shape: CollisionShape, transform: AffineTransform2D = .identity,
                         filter: CollisionQueryFilter = .init()) -> [CollisionHit] {
        let placed = collisionGeometry(shape: shape, matrix: transform)
        return queryColliders(filter: filter).compactMap { entity, target in
            CollisionGeometry.overlap(placed, target).map { CollisionHit(entity: entity, geometry: $0) }
        }.ordered(.all)
    }
    /// Translates a shape from its starting affine pose to a scene-space origin.
    /// Rotation/scale remain fixed. Continuous casts prevent tunneling through
    /// thin walls; contact tolerance is 0.00001 points. Initial overlaps return distance zero.
    /// - Complexity: O(n) candidate traversal, plus narrow-phase geometry and hit sorting.
    public func sweep(shape: CollisionShape, from start: AffineTransform2D, to end: SIMD2<Float>,
                      query: CollisionQueryMode = .nearest, filter: CollisionQueryFilter = .init()) -> [CollisionHit] {
        let placed = collisionGeometry(shape: shape, matrix: start)
        let delta = end - SIMD2(start.tx, start.ty)
        return queryColliders(filter: filter).compactMap { entity, target in
            CollisionGeometry.sweep(placed, by: delta, against: target).map { CollisionHit(entity: entity, geometry: $0) }
        }.ordered(query)
    }
    private func queryColliders(filter: CollisionQueryFilter) -> [(Entity, CollisionGeometry.Shape)] {
        allEntities.compactMap { entity in
            guard let collider = entity.queryCollider, collider.isEnabled,
                  filter.includes(entity, filter: collider.filter) else { return nil }
            let matrix = entity.sceneTransformMatrix * AffineTransform2D(tx: collider.offset.x, ty: collider.offset.y)
            return (entity, collisionGeometry(shape: collider.shape, matrix: matrix))
        }
    }
}

func collisionGeometry(shape: CollisionShape, matrix: AffineTransform2D) -> CollisionGeometry.Shape {
    .init(shape, position: [matrix.tx, matrix.ty], xAxis: [matrix.a, matrix.b], yAxis: [matrix.c, matrix.d])
}

private extension Array where Element == CollisionHit {
    func ordered(_ mode: CollisionQueryMode) -> Self {
        let sorted = sorted { $0.distance == $1.distance ? $0.entity.id < $1.entity.id : $0.distance < $1.distance }
        switch mode { case .all: return sorted; case .nearest: return Array(sorted.prefix(1)) }
    }
}

extension SpriteRenderer {
    static let collisionBinding = Binding<CollisionComponent>(apply: { _, _, node, animator in
        guard let entity = animator.renderer.world.entity(withID: animator.entityID) else { return }
        let body = entity.components[PhysicsBodyComponent.self]
        animator.renderer.applyPhysics(body, previous: body, entity: entity, node: node)
    })
    func displayedCollisionMatrix(for node: SKNode) -> AffineTransform2D {
        let origin = node.convert(CGPoint.zero, to: self)
        let x = node.convert(CGPoint(x: 1, y: 0), to: self), y = node.convert(CGPoint(x: 0, y: 1), to: self)
        return AffineTransform2D(a: Float(x.x - origin.x), b: Float(x.y - origin.y), c: Float(y.x - origin.x), d: Float(y.y - origin.y), tx: Float(origin.x), ty: Float(origin.y))
    }
}
