import ECSCore
import Foundation
import Gameplay

/// A kinematic character moved explicitly with `moveCharacter(by:relativeTo:)`.
/// Uses its own convex local shape; no PhysicsBodyComponent is needed. Collision
/// response is bilateral: both this filter and the target mask must allow it.
/// Rotation/scale remain fixed during each move. Gravity, steps and platforms
/// are game policies. Do not also give the character a dynamic physics body.
/// A controller also supplies a query/input shape when neither an explicit
/// CollisionComponent nor a PhysicsBodyComponent is present.
///
/// ```swift
/// character.components.set(CharacterControllerComponent(shape: .circle(radius: 14)))
/// let result = try character.moveCharacter(by: velocity * deltaTime)
/// ```
public struct CharacterControllerComponent: Component, Hashable, Codable, Sendable {
    public var shape: CollisionShape
    public var offset: SIMD2<Float>
    public var filter: CollisionFilter
    /// Scene-space clearance retained at walls. Must be finite and positive.
    public var skinWidth: Float
    /// Maximum wall slides per move, in 1...64.
    public var maxSlides: Int
    /// Maximum penetration corrections per move, in 1...128. Unresolved overlap stops movement.
    public var maxRecoveryIterations: Int
    public var isEnabled: Bool

    public init(shape: CollisionShape, offset: SIMD2<Float> = .zero, filter: CollisionFilter = .init(),
                skinWidth: Float = 0.01, maxSlides: Int = 6, maxRecoveryIterations: Int = 12, isEnabled: Bool = true) {
        self.shape = shape; self.offset = offset; self.filter = filter; self.skinWidth = skinWidth
        self.maxSlides = maxSlides; self.maxRecoveryIterations = maxRecoveryIterations; self.isEnabled = isEnabled
    }
}

/// A rejected move leaves the character unchanged.
public enum CharacterMovementError: Error, Equatable, Sendable {
    case notInScene, missingController, disabledController, invalidConfiguration, dynamicPhysicsBody
}

/// A wall encountered during recovery or a sweep, in scene coordinates.
@MainActor public struct CharacterContact {
    public let entity: Entity
    public let position: SIMD2<Float>
    public let normal: SIMD2<Float>
    public let isRecovery: Bool
}

/// All vectors are scene-space. Displacement includes overlap recovery, which
/// is also reported separately. `remainingTranslation` is requested movement
/// that was blocked or left after the slide budget. Contacts do not publish
/// PhysicsEvents: this operation works synchronously, even without a renderer.
@MainActor public struct CharacterMovementResult {
    public let requestedTranslation: SIMD2<Float>
    public let displacement: SIMD2<Float>
    public let recoveryTranslation: SIMD2<Float>
    public let remainingTranslation: SIMD2<Float>
    public let contacts: [CharacterContact]
    /// Whether overlap remains after the bounded recovery/movement attempt.
    public let isOverlapping: Bool
}

extension Entity {
    /// Sweeps, stops and slides, first recovering initial overlaps. `nil` means
    /// scene space; another entity supplies the requested vector's coordinate
    /// space. Self and descendants are excluded from obstacles. Other characters
    /// are considered at their current poses, so sequential calls are ordered.
    /// Invalid configuration/conversion throws before changing any transforms.
    /// - Complexity: O((recovery iterations + slides) * scene colliders), plus convex geometry.
    @discardableResult
    public func moveCharacter(by translation: SIMD2<Float>, relativeTo reference: Entity? = nil) throws -> CharacterMovementResult {
        guard let world else { throw CharacterMovementError.notInScene }
        guard let controller = components[CharacterControllerComponent.self] else { throw CharacterMovementError.missingController }
        guard controller.isEnabled else { throw CharacterMovementError.disabledController }
        guard components[PhysicsBodyComponent.self]?.isDynamic != true else { throw CharacterMovementError.dynamicPhysicsBody }
        let start = sceneTransformMatrix
        guard controller.shape.isValid, !controller.shape.isEdge,
              controller.skinWidth.isFinite, controller.skinWidth > 0,
              (1...64).contains(controller.maxSlides), (1...128).contains(controller.maxRecoveryIterations),
              controller.offset.x.isFinite, controller.offset.y.isFinite,
              translation.x.isFinite, translation.y.isFinite else { throw CharacterMovementError.invalidConfiguration }
        guard start.inverted() != nil, (parent?.sceneTransformMatrix ?? .identity).inverted() != nil else { throw EntityTransformError.noninvertibleTransform }
        if let reference, reference.world !== world { throw EntityTransformError.differentWorlds }
        let requested = reference?.sceneTransformMatrix.apply(toDirection: translation) ?? translation
        guard requested.x.isFinite, requested.y.isFinite, hypot(requested.x, requested.y).isFinite else { throw EntityTransformError.nonfiniteTransform }
        var excluded: Set<Entity.ID> = []
        visit { excluded.insert($0.id) }
        let filter = CollisionQueryFilter(mask: controller.filter.mask, group: controller.filter.group, excluding: excluded)
        let targets = world.queryColliders(filter: filter).sorted { $0.0.id < $1.0.id }
        let origin = SIMD2(start.tx, start.ty)
        var position = origin, contacts: [CharacterContact] = []
        func pose(_ point: SIMD2<Float>) -> AffineTransform2D {
            var matrix = start; matrix.tx = point.x; matrix.ty = point.y
            return matrix * AffineTransform2D(tx: controller.offset.x, ty: controller.offset.y)
        }
        guard pose(origin).inverted() != nil else { throw EntityTransformError.nonfiniteTransform }
        func penetrations(at point: SIMD2<Float>) -> [(Entity, CollisionGeometry.Penetration)] {
            let query = collisionGeometry(shape: controller.shape, matrix: pose(point))
            return targets.compactMap { entity, target in
                CollisionGeometry.penetration(query, against: target).map { (entity, $0) }
            }
        }
        for _ in 0..<controller.maxRecoveryIterations {
            guard let (entity, penetration) = penetrations(at: position).max(by: { $0.1.depth < $1.1.depth }) else { break }
            position += penetration.normal * (penetration.depth + controller.skinWidth)
            contacts.append(CharacterContact(entity: entity, position: penetration.position, normal: penetration.normal, isRecovery: true))
        }
        let recovered = position - origin
        let finalQuery = collisionGeometry(shape: controller.shape, matrix: pose(position))
        let overlapping = targets.contains { CollisionGeometry.overlap(finalQuery, $0.1) != nil }
        var remaining = requested, planes: [SIMD2<Float>] = []
        if !overlapping {
            for _ in 0..<controller.maxSlides {
                let length = hypot(remaining.x, remaining.y)
                if length < 1e-6 { break }
                let query = collisionGeometry(shape: controller.shape, matrix: pose(position))
                let hits = targets.compactMap { entity, target -> (Entity, CollisionGeometry.Hit)? in
                    CollisionGeometry.sweep(query, by: remaining, against: target).map { (entity, $0) }
                }.sorted { $0.1.fraction == $1.1.fraction ? $0.0.id < $1.0.id : $0.1.fraction < $1.1.fraction }
                guard let (entity, hit) = hits.first else { position += remaining; remaining = .zero; break }
                contacts.append(CharacterContact(entity: entity, position: hit.position, normal: hit.normal, isRecovery: false))
                let approach = -(remaining.x * hit.normal.x + remaining.y * hit.normal.y)
                // A zero normal is an unresolved initial overlap, never permission
                // to advance through a collider.
                guard approach > 1e-7 else { break }
                let fraction = max(0, hit.fraction - controller.skinWidth / approach)
                position += remaining * fraction
                remaining *= 1 - fraction
                planes.append(hit.normal)
                // Clip against every encountered plane so a second wall cannot
                // redirect the character back through the first wall.
                let unclipped = remaining
                for _ in 0..<3 {
                    for normal in planes {
                        let inward = remaining.x * normal.x + remaining.y * normal.y
                        if inward < 0 { remaining -= normal * inward }
                    }
                }
                if planes.contains(where: { remaining.x * $0.x + remaining.y * $0.y < -1e-5 }) { remaining = .zero }
                if hypot(remaining.x - unclipped.x, remaining.y - unclipped.y) < 1e-7 { break }
            }
        }
        guard position.x.isFinite, position.y.isFinite else { throw EntityTransformError.nonfiniteTransform }
        let finalPose = collisionGeometry(shape: controller.shape, matrix: pose(position))
        let finalOverlap = targets.contains { CollisionGeometry.overlap(finalPose, $0.1) != nil }
        try setPosition(position, relativeTo: nil)
        return CharacterMovementResult(requestedTranslation: requested, displacement: position - origin,
                                       recoveryTranslation: recovered, remainingTranslation: requested - (position - origin - recovered),
                                       contacts: contacts, isOverlapping: finalOverlap)
    }
}
