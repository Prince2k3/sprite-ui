@_spi(Backend) import ECSCore
import SpriteKit

@_exported import Gameplay

/// The shared collision outline, retained under its original physics API name.
public typealias PhysicsShape = CollisionShape

/// Makes an entity a rigid body that SpriteKit simulates, in place of setting
/// `SKNode.physicsBody` by hand.
///
/// Each frame the renderer pushes this component onto the node, SpriteKit steps the
/// simulation, and the results come back into the entity's ``ECSCore/Transform`` and
/// this component's ``velocity`` and ``angularVelocity``, so systems always read where
/// bodies are and how fast they move. Copying results back doesn't count as a change.
///
/// Setting ``velocity`` (or moving the entity) overrides the simulation for that frame.
/// To push a body instead, use ``ECSCore/Entity/applyImpulse(_:)``.
///
/// ```swift
/// let ball = Entity(components: PhysicsBodyComponent(shape: .circle(radius: 12), restitution: 0.8))
/// let floor = Entity(components: PhysicsBodyComponent(shape: .edgeChain([[-200, 0], [200, 0]])))
/// ```
///
/// Contacts are published as ``PhysicsEvents/ContactBegan`` and
/// ``PhysicsEvents/ContactEnded`` for bodies whose ``contactTestBitMask`` matches the
/// other's ``categoryBitMask``.
public struct PhysicsBodyComponent: Component, Equatable, Sendable, Codable {
    public var shape: PhysicsShape
    /// Whether forces, gravity and collisions move the body. Static bodies only get in the way.
    public var isDynamic: Bool
    /// Mass in kilograms. When `nil`, it comes from ``density`` and the shape's area.
    public var mass: Float?
    public var density: Float
    public var friction: Float
    /// Bounciness, from 0 (none) to 1 (keeps all its speed).
    public var restitution: Float
    public var linearDamping: Float
    public var angularDamping: Float
    public var affectedByGravity: Bool
    public var allowsRotation: Bool
    /// Checks for collisions between steps, for small fast bodies that would tunnel through walls.
    public var usesPreciseCollisionDetection: Bool

    /// The categories this body belongs to.
    public var categoryBitMask: UInt32
    /// The categories this body bounces off.
    public var collisionBitMask: UInt32
    /// The categories this body reports contacts with.
    public var contactTestBitMask: UInt32

    /// Points per second, in the parent's space. Updated by the simulation.
    public var velocity: SIMD2<Float>
    /// Radians per second, counterclockwise. Updated by the simulation.
    public var angularVelocity: Float

    public init(
        shape: PhysicsShape,
        isDynamic: Bool? = nil,
        mass: Float? = nil,
        density: Float = 1,
        friction: Float = 0.2,
        restitution: Float = 0.2,
        linearDamping: Float = 0.1,
        angularDamping: Float = 0.1,
        affectedByGravity: Bool = true,
        allowsRotation: Bool = true,
        usesPreciseCollisionDetection: Bool = false,
        categoryBitMask: UInt32 = .max,
        collisionBitMask: UInt32 = .max,
        contactTestBitMask: UInt32 = 0,
        velocity: SIMD2<Float> = .zero,
        angularVelocity: Float = 0
    ) {
        self.shape = shape
        self.isDynamic = isDynamic ?? !shape.isEdge
        self.mass = mass
        self.density = density
        self.friction = friction
        self.restitution = restitution
        self.linearDamping = linearDamping
        self.angularDamping = angularDamping
        self.affectedByGravity = affectedByGravity
        self.allowsRotation = allowsRotation
        self.usesPreciseCollisionDetection = usesPreciseCollisionDetection
        self.categoryBitMask = categoryBitMask
        self.collisionBitMask = collisionBitMask
        self.contactTestBitMask = contactTestBitMask
        self.velocity = velocity
        self.angularVelocity = angularVelocity
    }
}

/// Events the physics simulation publishes, from both entities involved. Subscribe on
/// either entity, or on the world for every contact.
public enum PhysicsEvents {
    /// Two bodies started touching. Published after the step's results are copied back.
    public struct ContactBegan: Event {
        public let entityA: Entity
        public let entityB: Entity
        /// Where they touched, in scene space.
        public let point: SIMD2<Float>
        /// The direction from A to B at the contact.
        public let normal: SIMD2<Float>
        /// How hard they hit, in newton-seconds.
        public let impulse: Float

        /// The entity in the contact that isn't `entity`.
        public func other(than entity: Entity) -> Entity {
            entity === entityA ? entityB : entityA
        }
    }

    /// Two bodies stopped touching.
    public struct ContactEnded: Event {
        public let entityA: Entity
        public let entityB: Entity

        public func other(than entity: Entity) -> Entity {
            entity === entityA ? entityB : entityA
        }
    }
}

extension Entity {
    private var physicsBody: SKPhysicsBody? {
        guard let renderer = world?.observer as? SpriteRenderer else { return nil }
        return renderer.node(for: self)?.physicsBody
    }

    /// Pushes this entity's physics body, in newton-seconds, changing its velocity at once.
    /// Does nothing until the entity is in a world shown by a ``SpriteRenderer``.
    public func applyImpulse(_ impulse: SIMD2<Float>) {
        physicsBody?.applyImpulse(CGVector(dx: CGFloat(impulse.x), dy: CGFloat(impulse.y)))
    }

    /// Pushes this entity's physics body over the next simulation step, in newtons.
    public func applyForce(_ force: SIMD2<Float>) {
        physicsBody?.applyForce(CGVector(dx: CGFloat(force.x), dy: CGFloat(force.y)))
    }

    /// Spins this entity's physics body, in newton-meter-seconds, counterclockwise.
    public func applyAngularImpulse(_ impulse: Float) {
        physicsBody?.applyAngularImpulse(CGFloat(impulse))
    }

    /// Spins this entity's physics body over the next simulation step, in newton-meters.
    public func applyTorque(_ torque: Float) {
        physicsBody?.applyTorque(CGFloat(torque))
    }
}

// MARK: - Renderer side

extension SpriteRenderer {
    /// The world's gravity in meters per second squared (SpriteKit uses 150 points per
    /// meter). Down by default.
    public var gravity: SIMD2<Float> {
        get { world.physics.gravity }
        set { world.physics.gravity = newValue }
    }

    static func makeBody(_ shape: PhysicsShape, offset: SIMD2<Float> = .zero) -> SKPhysicsBody {
        func path(_ points: [SIMD2<Float>], closed: Bool) -> CGPath {
            let path = CGMutablePath()
            let points = closed && points.count > 1 && points.first == points.last ? Array(points.dropLast()) : points
            path.addLines(between: points.map { CGPoint(x: CGFloat($0.x + offset.x), y: CGFloat($0.y + offset.y)) })
            if closed { path.closeSubpath() }
            return path
        }
        switch shape {
        case .circle(let radius):
            return SKPhysicsBody(circleOfRadius: CGFloat(radius), center: CGPoint(x: CGFloat(offset.x), y: CGFloat(offset.y)))
        case .rectangle(let size):
            return SKPhysicsBody(rectangleOf: CGSize(width: CGFloat(size.x), height: CGFloat(size.y)), center: CGPoint(x: CGFloat(offset.x), y: CGFloat(offset.y)))
        case .polygon(let points):
            let area = points.indices.reduce(0.0) { $0 + Double(points[$1].x) * Double(points[($1 + 1) % points.count].y) - Double(points[$1].y) * Double(points[($1 + 1) % points.count].x) }
            return SKPhysicsBody(polygonFrom: path(area < 0 ? Array(points.reversed()) : points, closed: true))
        case .edgeLoop(let points):
            return SKPhysicsBody(edgeLoopFrom: path(points, closed: true))
        case .edgeChain(let points):
            return SKPhysicsBody(edgeChainFrom: path(points, closed: false))
        }
    }

    static let physicsBinding = Binding<PhysicsBodyComponent>(
        apply: { new, old, node, animator in
            guard let entity = animator.renderer.world.entity(withID: animator.entityID) else { return }
            animator.renderer.applyPhysics(new, previous: old, entity: entity, node: node)
        }
    )

    func applyPhysics(_ model: PhysicsBodyComponent?, previous: PhysicsBodyComponent?, entity: Entity, node: SKNode) {
        defer { if node.physicsBody != nil { bodies.insert(entity.id) } else { bodies.remove(entity.id) } }
        let collider = entity.components[CollisionComponent.self]
        guard let model, collider?.isEnabled != false else {
            node.physicsBody = nil; physicsShapes[entity.id] = nil; return
        }
        let shape = collider?.shape ?? model.shape, offset = collider?.offset ?? .zero
        guard shape.isValid, offset.x.isFinite, offset.y.isFinite else {
            node.physicsBody = nil; physicsShapes[entity.id] = nil; return
        }
        let signature = PhysicsShapeConfiguration(shape: shape, offset: offset)
        let existing = node.physicsBody
        let rebuild = existing == nil || physicsShapes[entity.id] != signature
        if rebuild {
            node.physicsBody = Self.makeBody(shape, offset: offset)
            physicsShapes[entity.id] = signature
        }
        guard let body = node.physicsBody else { return }
        body.isDynamic = model.isDynamic && !shape.isEdge
        if let mass = model.mass { body.mass = CGFloat(mass) } else { body.density = CGFloat(model.density) }
        body.friction = CGFloat(model.friction); body.restitution = CGFloat(model.restitution)
        body.linearDamping = CGFloat(model.linearDamping); body.angularDamping = CGFloat(model.angularDamping)
        body.affectedByGravity = model.affectedByGravity; body.allowsRotation = model.allowsRotation
        body.usesPreciseCollisionDetection = model.usesPreciseCollisionDetection
        body.categoryBitMask = collider?.filter.group.rawValue ?? model.categoryBitMask
        body.collisionBitMask = collider?.filter.mask.rawValue ?? model.collisionBitMask
        body.contactTestBitMask = model.contactTestBitMask
        if let existing, rebuild {
            body.velocity = existing.velocity; body.angularVelocity = existing.angularVelocity
        }
        if existing == nil || previous?.velocity != model.velocity {
            body.velocity = CGVector(dx: CGFloat(model.velocity.x), dy: CGFloat(model.velocity.y))
        }
        if existing == nil || previous?.angularVelocity != model.angularVelocity { body.angularVelocity = CGFloat(model.angularVelocity) }
    }
}

struct PhysicsShapeConfiguration: Equatable { let shape: CollisionShape; let offset: SIMD2<Float> }
