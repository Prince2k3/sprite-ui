@_spi(Backend) import ECSCore
import Foundation
import SpriteKit

/// A connection between two rigid bodies. Anchor coordinates are local to body A
/// (and body B for spring/limit anchorB). Pin, fixed and sliding use one shared
/// pivot, computed from body A's anchor when bound. Sliding axes are body-A-local
/// directions at binding; distances are scene points and angles are radians.
public enum PhysicsJointConstraint: Hashable, Codable, Sendable {
    case pin(anchor: SIMD2<Float> = .zero, angleLimits: ClosedRange<Float>? = nil, frictionTorque: Float = 0, rotationSpeed: Float = 0)
    case fixed(anchor: SIMD2<Float> = .zero)
    /// Zero frequency makes the connection rigid; positive values set stiffness in hertz.
    case spring(anchorA: SIMD2<Float> = .zero, anchorB: SIMD2<Float> = .zero, frequency: Float = 2, damping: Float = 0.2)
    case sliding(anchor: SIMD2<Float> = .zero, axis: SIMD2<Float> = [1, 0], distanceLimits: ClosedRange<Float>? = nil)
    case limit(anchorA: SIMD2<Float> = .zero, anchorB: SIMD2<Float> = .zero, maxLength: Float)

    /// Whether all coordinates/parameters are finite and physical magnitudes valid.
    public var isValid: Bool {
        func point(_ p: SIMD2<Float>) -> Bool { p.x.isFinite && p.y.isFinite }
        func range(_ r: ClosedRange<Float>?) -> Bool { r.map { $0.lowerBound.isFinite && $0.upperBound.isFinite } ?? true }
        switch self {
        case .pin(let anchor, let limits, let friction, let speed):
            return point(anchor) && range(limits) && friction.isFinite && friction >= 0 && speed.isFinite
        case .fixed(let anchor): return point(anchor)
        case .spring(let a, let b, let frequency, let damping):
            return point(a) && point(b) && frequency.isFinite && frequency >= 0 && damping.isFinite && damping >= 0
        case .sliding(let anchor, let axis, let limits):
            return point(anchor) && point(axis) && hypot(axis.x, axis.y).isFinite && hypot(axis.x, axis.y) > 0 && range(limits)
        case .limit(let a, let b, let length): return point(a) && point(b) && length.isFinite && length > 0
        }
    }

    // Only geometry changes capture a new rest frame. Tuning stiffness, motors
    // or limits keeps the original reference instead of rebinding a moving body.
    fileprivate var referenceGeometry: Self {
        switch self {
        case .pin(let a, _, _, _): .pin(anchor: a)
        case .fixed: self
        case .spring(let a, let b, _, _): .spring(anchorA: a, anchorB: b)
        case .sliding(let a, let axis, _): .sliding(anchor: a, axis: axis)
        case .limit(let a, let b, _): .limit(anchorA: a, anchorB: b, maxLength: 1)
        }
    }
}

/// Put this on a separate entity for each joint; bodies can have many connections.
/// Both referenced entities must have active PhysicsBodyComponents in the same
/// rendered scene, with at least one dynamic body. Missing/disabled bodies wait
/// until available. References are IDs, so World.snapshot/restore keeps links.
///
/// The first successful flush captures a rest frame. It survives body replacement,
/// disabling/re-enabling and snapshots, preserving spring rest lengths and angular
/// references. Changing endpoints/anchors captures a new frame; tuning parameters
/// does not. Call rebind() to deliberately use the bodies' current poses instead.
/// Joints support positive, unsheared transforms. Ancestor/descendant body pairs
/// are rejected. Rendering creates native joints after all pending bodies flush.
///
/// ```swift
/// let hinge = Entity(components: PhysicsJointComponent(
///     bodyA: pivot.id, bodyB: door.id, constraint: .pin()))
/// scene.addEntity(hinge)
/// ```
public struct PhysicsJointComponent: Component, Hashable, Codable, Sendable {
    public var bodyA: Entity.ID { didSet { if bodyA != oldValue { referencePose = nil } } }
    public var bodyB: Entity.ID { didSet { if bodyB != oldValue { referencePose = nil } } }
    public var constraint: PhysicsJointConstraint {
        didSet { if constraint.referenceGeometry != oldValue.referenceGeometry { referencePose = nil } }
    }
    public var isEnabled: Bool
    fileprivate var referencePose: JointReferencePose?

    public init(bodyA: Entity.ID, bodyB: Entity.ID, constraint: PhysicsJointConstraint, isEnabled: Bool = true) {
        self.bodyA = bodyA; self.bodyB = bodyB; self.constraint = constraint; self.isEnabled = isEnabled
    }

    /// Discards the saved rest frame. The next successful flush binds current poses.
    public mutating func rebind() { referencePose = nil }
}

/// The state from the renderer's last flush. Missing bodies can become available
/// later. Invalid models are kept for correction but never passed to SpriteKit.
public enum PhysicsJointStatus: Hashable, Sendable {
    case active, disabled, waitingForBodies, invalidBodies, invalidConfiguration, invalidTransform, notRendered
}

extension Entity {
    /// Nil without a joint component; otherwise the last resolved state. A world
    /// without a renderer reports notRendered. Component edits resolve at flush.
    public var physicsJointStatus: PhysicsJointStatus? {
        guard components[PhysicsJointComponent.self] != nil else { return nil }
        return (world?.observer as? SpriteRenderer)?.jointStatuses[id] ?? .notRendered
    }
}

private struct JointReferencePose: Hashable, Codable, Sendable {
    var a: AffineTransform2D
    var b: AffineTransform2D
    var space: Entity.ID? = nil
}

struct PhysicsJointEntry {
    let model: PhysicsJointComponent
    let joint: SKPhysicsJoint
}

extension SpriteRenderer {
    /// Authored attachment points in the current displayed poses. Shared pivots
    /// use the captured rest frame to recover body B's local attachment, matching
    /// native joint binding after bodies have moved or a prefab is relocated.
    func debugJointAnchors(for owner: Entity) -> (SIMD2<Float>, SIMD2<Float>)? {
        guard jointStatuses[owner.id] == .active, let model = jointEntries[owner.id]?.model,
              let a = world.entity(withID: model.bodyA), let b = world.entity(withID: model.bodyB),
              let nodeA = node(for: a), let nodeB = node(for: b), var reference = model.referencePose else { return nil }
        if let id = reference.space {
            guard let frame = world.entity(withID: id), let node = node(for: frame) else { return nil }
            let matrix = displayedCollisionMatrix(for: node)
            reference.a = matrix * reference.a; reference.b = matrix * reference.b
        }
        let localA: SIMD2<Float>, localB: SIMD2<Float>
        switch model.constraint {
        case .spring(let a, let b, _, _), .limit(let a, let b, _): localA = a; localB = b
        case .pin(let point, _, _, _), .fixed(let point), .sliding(let point, _, _):
            guard let inverse = reference.b.inverted() else { return nil }
            localA = point; localB = inverse.apply(to: reference.a.apply(to: point))
        }
        return (displayedCollisionMatrix(for: nodeA).apply(to: localA), displayedCollisionMatrix(for: nodeB).apply(to: localB))
    }

    /// Reconciles after all component bindings; native joints must never point at
    /// bodies that are still being created/replaced in dictionary iteration order.
    func synchronizePhysicsJoints() {
        let owners = world.allEntities.filter { $0.components.has(PhysicsJointComponent.self) }.sorted { $0.id < $1.id }
        let ids = Set(owners.map(\.id))
        for id in Array(jointEntries.keys) where !ids.contains(id) { removePhysicsJoint(id) }
        jointStatuses = jointStatuses.filter { ids.contains($0.key) }
        for owner in owners {
            guard var model = owner.components[PhysicsJointComponent.self] else { continue }
            func reject(_ status: PhysicsJointStatus) { removePhysicsJoint(owner.id); jointStatuses[owner.id] = status }
            guard owner.isActive, model.isEnabled else { reject(.disabled); continue }
            guard model.constraint.isValid else { reject(.invalidConfiguration); continue }
            guard model.bodyA != model.bodyB else { reject(.invalidBodies); continue }
            guard let a = world.entity(withID: model.bodyA), let b = world.entity(withID: model.bodyB), a.isActive, b.isActive,
                  let nodeA = node(for: a), let nodeB = node(for: b),
                  nodeA.scene === self, nodeB.scene === self,
                  let bodyA = nodeA.physicsBody, let bodyB = nodeB.physicsBody else { reject(.waitingForBodies); continue }
            guard bodyA.isDynamic || bodyB.isDynamic, !a.isDescendant(of: b), !b.isDescendant(of: a) else { reject(.invalidBodies); continue }
            let current = JointReferencePose(a: displayedCollisionMatrix(for: nodeA), b: displayedCollisionMatrix(for: nodeB))
            guard Self.jointTransform(current.a) != nil, Self.jointTransform(current.b) != nil else { reject(.invalidTransform); continue }
            if let existing = jointEntries[owner.id], existing.model == model,
               existing.joint.bodyA === bodyA, existing.joint.bodyB === bodyB { continue }
            removePhysicsJoint(owner.id)
            let storedReference = model.referencePose ?? current
            var reference = storedReference
            if let space = reference.space {
                guard let frame = world.entity(withID: space), frame.isActive, let frameNode = node(for: frame) else { reject(.waitingForBodies); continue }
                let matrix = displayedCollisionMatrix(for: frameNode)
                reference.a = matrix * reference.a; reference.b = matrix * reference.b
            }
            guard let localA = jointLocalTransform(reference.a, for: nodeA),
                  let localB = jointLocalTransform(reference.b, for: nodeB) else { reject(.invalidTransform); continue }
            guard let joint = makePhysicsJoint(model.constraint, bodyA: bodyA, bodyB: bodyB,
                                              nodeA: nodeA, nodeB: nodeB, localA: localA, localB: localB) else {
                reject(.invalidConfiguration); continue
            }
            model.referencePose = storedReference
            owner._setWithoutNotifying(model)
            jointEntries[owner.id] = PhysicsJointEntry(model: model, joint: joint)
            jointStatuses[owner.id] = .active
        }
    }

    func removePhysicsJoint(_ id: Entity.ID) {
        if let entry = jointEntries.removeValue(forKey: id) { physicsWorld.remove(entry.joint) }
    }

    /// Call before replacing a body or detaching a node (SpriteKit can otherwise
    /// implicitly destroy joints while our cache still considers them installed).
    func removePhysicsJoints(involving ids: Set<Entity.ID>) {
        for (id, entry) in Array(jointEntries) where ids.contains(id) || ids.contains(entry.model.bodyA) || ids.contains(entry.model.bodyB) || entry.model.referencePose?.space.map({ ids.contains($0) }) == true {
            removePhysicsJoint(id)
            jointStatuses[id] = .waitingForBodies
        }
    }

    private static func jointTransform(_ matrix: AffineTransform2D) -> Transform? {
        guard matrix.inverted() != nil, let transform = try? Transform(matrix: matrix),
              transform.scale.x > 0, transform.scale.y > 0 else { return nil }
        return transform
    }

    private func jointLocalTransform(_ reference: AffineTransform2D, for node: SKNode) -> Transform? {
        guard Self.jointTransform(reference) != nil else { return nil }
        let parentMatrix = node.parent.map { displayedCollisionMatrix(for: $0) } ?? .identity
        guard let inverse = parentMatrix.inverted() else { return nil }
        return Self.jointTransform(inverse * reference)
    }

    private func makePhysicsJoint(_ constraint: PhysicsJointConstraint, bodyA: SKPhysicsBody, bodyB: SKPhysicsBody,
                                  nodeA: SKNode, nodeB: SKNode, localA: Transform, localB: Transform) -> SKPhysicsJoint? {
        // SpriteKit captures rest lengths and angular references from native body
        // poses. Build at the saved frame, then restore the actual simulation pose
        // and velocities before any simulation/rendering can run.
        let savedA = (nodeA.position, nodeA.zRotation, nodeA.xScale, nodeA.yScale, bodyA.velocity, bodyA.angularVelocity, bodyA.isResting)
        let savedB = (nodeB.position, nodeB.zRotation, nodeB.xScale, nodeB.yScale, bodyB.velocity, bodyB.angularVelocity, bodyB.isResting)
        defer {
            nodeA.position = savedA.0; nodeA.zRotation = savedA.1; nodeA.xScale = savedA.2; nodeA.yScale = savedA.3
            nodeB.position = savedB.0; nodeB.zRotation = savedB.1; nodeB.xScale = savedB.2; nodeB.yScale = savedB.3
            bodyA.velocity = savedA.4; bodyA.angularVelocity = savedA.5
            bodyB.velocity = savedB.4; bodyB.angularVelocity = savedB.5
            bodyA.isResting = savedA.6; bodyB.isResting = savedB.6
        }
        func apply(_ t: Transform, to node: SKNode) {
            node.position = CGPoint(x: CGFloat(t.translation.x), y: CGFloat(t.translation.y)); node.zRotation = CGFloat(t.rotation)
            node.xScale = CGFloat(t.scale.x); node.yScale = CGFloat(t.scale.y)
        }
        apply(localA, to: nodeA); apply(localB, to: nodeB)
        func anchor(_ p: SIMD2<Float>, on node: SKNode) -> CGPoint { node.convert(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), to: self) }
        // Validate mapped coordinates too: finite local values can overflow a
        // native Float physics coordinate after scale/translation.
        let localAnchors: (SIMD2<Float>, SIMD2<Float>?)
        switch constraint {
        case .pin(let p, _, _, _), .fixed(let p), .sliding(let p, _, _): localAnchors = (p, nil)
        case .spring(let a, let b, _, _), .limit(let a, let b, _): localAnchors = (a, b)
        }
        let pointA = anchor(localAnchors.0, on: nodeA)
        let pointB = localAnchors.1.map { anchor($0, on: nodeB) }
        func finite(_ p: CGPoint) -> Bool { Float(p.x).isFinite && Float(p.y).isFinite }
        guard finite(pointA), pointB.map(finite) ?? true else { return nil }
        if let pointB {
            let delta = SIMD2<Float>(Float(pointB.x - pointA.x), Float(pointB.y - pointA.y))
            guard (delta.x * delta.x + delta.y * delta.y).isFinite else { return nil }
        }
        let joint: SKPhysicsJoint
        switch constraint {
        case .pin(let p, let limits, let friction, let speed):
            let pin = SKPhysicsJointPin.joint(withBodyA: bodyA, bodyB: bodyB, anchor: anchor(p, on: nodeA))
            pin.shouldEnableLimits = limits != nil
            if let limits { pin.lowerAngleLimit = CGFloat(limits.lowerBound); pin.upperAngleLimit = CGFloat(limits.upperBound) }
            pin.frictionTorque = CGFloat(friction); pin.rotationSpeed = CGFloat(speed); joint = pin
        case .fixed(let p): joint = SKPhysicsJointFixed.joint(withBodyA: bodyA, bodyB: bodyB, anchor: anchor(p, on: nodeA))
        case .spring(let a, let b, let frequency, let damping):
            let spring = SKPhysicsJointSpring.joint(withBodyA: bodyA, bodyB: bodyB, anchorA: anchor(a, on: nodeA), anchorB: anchor(b, on: nodeB))
            spring.frequency = CGFloat(frequency); spring.damping = CGFloat(damping); joint = spring
        case .sliding(let p, let axis, let limits):
            let matrix = displayedCollisionMatrix(for: nodeA)
            let dx = CGFloat(matrix.a) * CGFloat(axis.x) + CGFloat(matrix.c) * CGFloat(axis.y)
            let dy = CGFloat(matrix.b) * CGFloat(axis.x) + CGFloat(matrix.d) * CGFloat(axis.y)
            let length = hypot(dx, dy)
            guard length.isFinite, length > 0 else { return nil }
            let sliding = SKPhysicsJointSliding.joint(withBodyA: bodyA, bodyB: bodyB, anchor: anchor(p, on: nodeA), axis: CGVector(dx: dx / length, dy: dy / length))
            sliding.shouldEnableLimits = limits != nil
            if let limits { sliding.lowerDistanceLimit = CGFloat(limits.lowerBound); sliding.upperDistanceLimit = CGFloat(limits.upperBound) }
            joint = sliding
        case .limit(let a, let b, let length):
            let limit = SKPhysicsJointLimit.joint(withBodyA: bodyA, bodyB: bodyB, anchorA: anchor(a, on: nodeA), anchorB: anchor(b, on: nodeB))
            limit.maxLength = CGFloat(length); joint = limit
        }
        physicsWorld.add(joint)
        return joint
    }
}

extension PhysicsJointComponent: EntityReferencingComponent {
    @MainActor public mutating func remapEntityReferences(_ context: EntityReferenceRemapping) {
        var saved = referencePose
        let internalBodies = context.entity(for: bodyA) != nil && context.entity(for: bodyB) != nil
        bodyA = context.id(for: bodyA); bodyB = context.id(for: bodyB)
        if context.operation == .clone, internalBodies, let root = context.root, let reference = saved {
            let sourceFrame = reference.space.flatMap { context.sourceTransform(for: $0) } ?? (reference.space == nil ? .identity : nil)
            if let sourceFrame, let inverse = context.sourceRootTransform?.inverted() {
                saved = JointReferencePose(a: inverse * sourceFrame * reference.a, b: inverse * sourceFrame * reference.b, space: root.id)
            } else { saved = nil }
        } else if let space = saved?.space { saved?.space = context.id(for: space) }
        referencePose = saved
    }
}
