@_spi(Backend) import ECSCore
import Foundation
import Gameplay

/// Where a steering behavior aims: a fixed scene point or another entity.
public enum SteeringTarget: Hashable, Codable, Sendable {
    case point(SIMD2<Float>)
    case entity(Entity.ID)
}

/// One thing a steered entity wants, in place of `GKGoal`.
public enum SteeringBehavior: Hashable, Codable, Sendable {
    /// Head straight for the target.
    case seek(SteeringTarget)
    /// Run from the target while it's within `panicDistance`.
    case flee(SteeringTarget, panicDistance: Float = .infinity)
    /// Head for the target and stop on it, slowing inside `slowingRadius`.
    /// `nil` uses the agent's braking distance.
    case arrive(SteeringTarget, slowingRadius: Float? = nil)
    /// Head for where another entity is going to be.
    case pursue(Entity.ID)
    /// Run from where another entity is going to be.
    case evade(Entity.ID, panicDistance: Float = .infinity)
    /// Drift about. The system updates the state each frame.
    case wander(Wander)
    /// Keep apart from steered neighbors in `categories` within `radius`.
    case separate(radius: Float, categories: SpatialCategories = .all)
    /// Match the heading of steered neighbors in `categories` within `radius`.
    case align(radius: Float, categories: SpatialCategories = .all)
    /// Move toward the center of steered neighbors in `categories` within `radius`.
    case cohere(radius: Float, categories: SpatialCategories = .all)
    /// Swerve around entities with a ``SteeringObstacleComponent``.
    case avoidObstacles(lookAhead: Float = 1)
    /// Turn back inside a scene-space box when within `margin` of its edge.
    case stayWithin(BoundingBox, margin: Float = 0)
    /// Travel along a path.
    case follow(SteeringPath, lookAhead: Float = 0.5)
}

/// A weighted behavior. Forces from all of an entity's goals are scaled by their
/// weights and added up.
public struct SteeringGoal: Hashable, Codable, Sendable {
    public var behavior: SteeringBehavior
    public var weight: Float

    public init(_ behavior: SteeringBehavior, weight: Float = 1) {
        self.behavior = behavior
        self.weight = weight
    }
}

/// Moves an entity by steering behaviors, in place of `GKAgent2D` and `GKBehavior`.
///
/// Add ``SteeringSystem`` to the world so it moves. Flocking goals
/// (`separate`, `align`, `cohere`) find neighbors with the spatial index, so give
/// flock members a ``SpatialIndexComponent`` and add ``SpatialIndexSystem`` too.
///
/// ```swift
/// boid.components.set(SteeringComponent(maxSpeed: 120, maxForce: 240, goals: [
///     SteeringGoal(.separate(radius: 25), weight: 1.5),
///     SteeringGoal(.align(radius: 50)),
///     SteeringGoal(.cohere(radius: 50)),
///     SteeringGoal(.wander(Wander()), weight: 0.3),
/// ]))
/// ```
///
/// Steered entities should be top-level, or under parents that only translate:
/// the system reads scene positions but moves the entity's own translation.
public struct SteeringComponent: Component, Hashable, Codable, Sendable {
    public var goals: [SteeringGoal]
    /// Points per second.
    public var velocity: SIMD2<Float>
    public var maxSpeed: Float
    public var maxForce: Float
    public var mass: Float
    /// How much room the entity takes up, for obstacle avoidance.
    public var radius: Float
    /// Whether to turn the entity to face where it's going. A rotation of 0 faces +x.
    public var orientsToVelocity: Bool

    public init(
        maxSpeed: Float,
        maxForce: Float,
        mass: Float = 1,
        radius: Float = 0,
        velocity: SIMD2<Float> = .zero,
        orientsToVelocity: Bool = false,
        goals: [SteeringGoal] = []
    ) {
        self.goals = goals
        self.velocity = velocity
        self.maxSpeed = maxSpeed
        self.maxForce = maxForce
        self.mass = mass
        self.radius = radius
        self.orientsToVelocity = orientsToVelocity
    }

    /// The pure agent this component describes, standing at `position`.
    public func agent(at position: SIMD2<Float>) -> SteeringAgent {
        SteeringAgent(
            position: position, velocity: velocity,
            maxSpeed: maxSpeed, maxForce: maxForce, mass: mass, radius: radius
        )
    }
}

/// Something for steered entities to go around.
public struct SteeringObstacleComponent: Component, Hashable, Codable, Sendable {
    public var radius: Float

    public init(radius: Float) {
        self.radius = radius
    }
}

/// Moves every entity with a ``SteeringComponent``.
///
/// Every entity's forces are worked out from where everyone was at the start of
/// the update, so the order entities are processed in doesn't matter.
///
/// ```swift
/// world.addSystem(SteeringSystem.self)
/// world.addSystem(SpatialIndexSystem.self)   // after, so the index has new positions
/// ```
public struct SteeringSystem: System {
    private static let steered = EntityQuery(where: .has(SteeringComponent.self))
    private static let obstacles = EntityQuery(where: .has(SteeringObstacleComponent.self))

    public init(world: World) {}

    public mutating func update(context: UpdateContext) {
        let world = context.world
        let dt = Float(context.deltaTime)
        guard dt > 0 else { return }

        // Snapshot first, so every force sees the same moment.
        var members: [(entity: Entity, steering: SteeringComponent, agent: SteeringAgent)] = []
        var snapshot: [Entity.ID: SteeringAgent] = [:]
        for entity in context.entities(matching: Self.steered) {
            guard let steering = entity.components[SteeringComponent.self] else { continue }
            let agent = steering.agent(at: entity.scenePosition)
            members.append((entity, steering, agent))
            snapshot[entity.id] = agent
        }
        guard !members.isEmpty else { return }

        var obstacles: [CircleObstacle]?
        func allObstacles() -> [CircleObstacle] {
            if let obstacles { return obstacles }
            let found = context.entities(matching: Self.obstacles).compactMap { entity in
                entity.components[SteeringObstacleComponent.self].map {
                    CircleObstacle(center: entity.scenePosition, radius: $0.radius)
                }
            }
            obstacles = found
            return found
        }

        func position(of target: SteeringTarget) -> SIMD2<Float>? {
            switch target {
            case .point(let point): point
            case .entity(let id): snapshot[id]?.position ?? world.entity(withID: id)?.scenePosition
            }
        }

        func motion(of id: Entity.ID) -> (SIMD2<Float>, SIMD2<Float>)? {
            if let agent = snapshot[id] { return (agent.position, agent.velocity) }
            return world.entity(withID: id).map { ($0.scenePosition, .zero) }
        }

        func neighbors(of entity: Entity, _ agent: SteeringAgent, radius: Float, _ categories: SpatialCategories) -> [SteeringAgent] {
            world.entities(within: radius, of: agent.position, matching: categories).compactMap { other in
                other === entity ? nil : snapshot[other.id]
            }
        }

        var random = world.random
        var results: [(Entity, SteeringComponent, SteeringAgent)] = []
        results.reserveCapacity(members.count)

        for (entity, original, start) in members {
            var steering = original
            var total = SIMD2<Float>.zero
            for index in steering.goals.indices {
                let goal = steering.goals[index]
                guard goal.weight != 0 else { continue }
                let force: SIMD2<Float>
                switch goal.behavior {
                case .seek(let target):
                    force = position(of: target).map { Steering.seek(start, toward: $0) } ?? .zero
                case .flee(let target, let panic):
                    force = position(of: target).map { Steering.flee(start, from: $0, panicDistance: panic) } ?? .zero
                case .arrive(let target, let slowing):
                    force = position(of: target).map {
                        Steering.arrive(start, at: $0, slowingRadius: slowing ?? start.brakingDistance)
                    } ?? .zero
                case .pursue(let id):
                    force = motion(of: id).map { Steering.pursue(start, target: $0.0, moving: $0.1) } ?? .zero
                case .evade(let id, let panic):
                    force = motion(of: id).map {
                        Steering.evade(start, threat: $0.0, moving: $0.1, panicDistance: panic)
                    } ?? .zero
                case .wander(var wander):
                    force = wander.force(for: start, deltaTime: dt, using: &random)
                    steering.goals[index].behavior = .wander(wander)
                case .separate(let radius, let categories):
                    force = Steering.separate(start, from: neighbors(of: entity, start, radius: radius, categories).map(\.position))
                case .align(let radius, let categories):
                    force = Steering.align(start, with: neighbors(of: entity, start, radius: radius, categories).map(\.velocity))
                case .cohere(let radius, let categories):
                    force = Steering.cohere(start, with: neighbors(of: entity, start, radius: radius, categories).map(\.position))
                case .avoidObstacles(let lookAhead):
                    force = Steering.avoid(start, obstacles: allObstacles(), lookAhead: lookAhead)
                case .stayWithin(let bounds, let margin):
                    force = Steering.stay(start, within: bounds, margin: margin)
                case .follow(let path, let lookAhead):
                    force = Steering.follow(start, path: path, lookAhead: lookAhead)
                }
                total += force * goal.weight
            }

            var agent = start
            agent.apply(total, deltaTime: dt)
            steering.velocity = agent.velocity
            results.append((entity, steering, agent))
        }
        world.random = random

        for (entity, steering, agent) in results {
            let start = snapshot[entity.id]!.position
            var transform = entity.transform
            transform.translation += agent.position - start
            if steering.orientsToVelocity, let heading = agent.heading {
                transform.rotation = atan2(heading.y, heading.x)
            }
            entity.transform = transform
            // Velocity and wander state aren't drawn, so backends needn't hear of them.
            entity._setWithoutNotifying(steering)
        }
    }
}
