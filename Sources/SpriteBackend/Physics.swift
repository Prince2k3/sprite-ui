@_spi(Backend) import ECSCore
import SpriteKit

/// The outline of a ``PhysicsBodyComponent``, in the entity's own space.
public enum PhysicsShape: Hashable, Sendable, Codable {
    case circle(radius: Float)
    /// A rectangle of `size` centered on the entity.
    case rectangle(size: SIMD2<Float>)
    /// A convex polygon, counterclockwise.
    case polygon([SIMD2<Float>])
    /// A closed outline with no inside, such as the walls of a room. Always static.
    case edgeLoop([SIMD2<Float>])
    /// An open run of edges, such as the ground. Always static.
    case edgeChain([SIMD2<Float>])

    /// The outline of a rectangle of `size` centered on the entity, as an edge loop.
    public static func edgeLoop(rectangle size: SIMD2<Float>) -> PhysicsShape {
        let half = size / 2
        return .edgeLoop([[-half.x, -half.y], [half.x, -half.y], [half.x, half.y], [-half.x, half.y]])
    }

    var isEdge: Bool {
        switch self {
        case .edgeLoop, .edgeChain: true
        default: false
        }
    }
}

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
        get { [Float(physicsWorld.gravity.dx), Float(physicsWorld.gravity.dy)] }
        set { physicsWorld.gravity = CGVector(dx: CGFloat(newValue.x), dy: CGFloat(newValue.y)) }
    }

    static func makeBody(_ shape: PhysicsShape) -> SKPhysicsBody {
        func path(_ points: [SIMD2<Float>], closed: Bool) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
            if closed { path.closeSubpath() }
            return path
        }
        switch shape {
        case .circle(let radius):
            return SKPhysicsBody(circleOfRadius: CGFloat(radius))
        case .rectangle(let size):
            return SKPhysicsBody(rectangleOf: CGSize(width: CGFloat(size.x), height: CGFloat(size.y)))
        case .polygon(let points):
            return SKPhysicsBody(polygonFrom: path(points, closed: true))
        case .edgeLoop(let points):
            return SKPhysicsBody(edgeLoopFrom: path(points, closed: true))
        case .edgeChain(let points):
            return SKPhysicsBody(edgeChainFrom: path(points, closed: false))
        }
    }

    static let physicsBinding = Binding<PhysicsBodyComponent>(
        apply: { new, old, node, _ in
            guard let new else {
                node.physicsBody = nil
                return
            }
            var old = old
            if old?.shape != new.shape || node.physicsBody == nil {
                let previous = node.physicsBody
                node.physicsBody = makeBody(new.shape)
                if let previous, old != nil {
                    // A new shape keeps the body's motion.
                    node.physicsBody?.velocity = previous.velocity
                    node.physicsBody?.angularVelocity = previous.angularVelocity
                }
                old = nil
            }
            guard let body = node.physicsBody else { return }

            body.isDynamic = new.isDynamic
            if let mass = new.mass {
                body.mass = CGFloat(mass)
            } else {
                body.density = CGFloat(new.density)
            }
            body.friction = CGFloat(new.friction)
            body.restitution = CGFloat(new.restitution)
            body.linearDamping = CGFloat(new.linearDamping)
            body.angularDamping = CGFloat(new.angularDamping)
            body.affectedByGravity = new.affectedByGravity
            body.allowsRotation = new.allowsRotation
            body.usesPreciseCollisionDetection = new.usesPreciseCollisionDetection
            body.categoryBitMask = new.categoryBitMask
            body.collisionBitMask = new.collisionBitMask
            body.contactTestBitMask = new.contactTestBitMask
            // Velocity is written only when the model changed it, so copied-back values
            // don't fight the simulation.
            if old?.velocity != new.velocity {
                body.velocity = CGVector(dx: CGFloat(new.velocity.x), dy: CGFloat(new.velocity.y))
            }
            if old?.angularVelocity != new.angularVelocity {
                body.angularVelocity = CGFloat(new.angularVelocity)
            }
        }
    )
}
