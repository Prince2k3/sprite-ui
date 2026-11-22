@_spi(Backend) import ECSCore
import Foundation
import Gameplay

/// Moves an entity through a list of scene positions at a steady speed.
///
/// Usually set with ``ECSCore/Entity/follow(_:speed:orientsToPath:)``. Add
/// ``PathFollowSystem`` to the world so it moves. When the last waypoint is reached
/// the component is removed and ``PathEvents/DidFinish`` is published.
public struct PathComponent: Component, Hashable, Codable, Sendable {
    /// The positions to visit, in order.
    public var waypoints: [SIMD2<Float>]
    /// Points per second.
    public var speed: Float
    /// Whether to turn the entity to face where it's going. A rotation of 0 faces +x.
    public var orientsToPath: Bool
    /// The waypoint the entity is heading to.
    public internal(set) var nextIndex: Int = 0

    public init(waypoints: [SIMD2<Float>], speed: Float, orientsToPath: Bool = false) {
        self.waypoints = waypoints
        self.speed = speed
        self.orientsToPath = orientsToPath
    }

    /// The waypoints not yet reached.
    public var remainingWaypoints: ArraySlice<SIMD2<Float>> {
        waypoints[min(nextIndex, waypoints.count)...]
    }
}

/// Events published from an entity following a path.
public enum PathEvents {
    /// The entity reached the last waypoint of its path.
    public struct DidFinish: Event {
        public let entity: Entity
    }
}

extension Entity {
    /// Starts moving the entity through `waypoints`, replacing any path it was on.
    ///
    /// ```swift
    /// if let path = grid.findPath(from: start, to: goal) {
    ///     enemy.follow(space.positions(along: grid.smoothed(path)), speed: 120)
    /// }
    /// ```
    public func follow(_ waypoints: [SIMD2<Float>], speed: Float, orientsToPath: Bool = false) {
        components.set(PathComponent(waypoints: waypoints, speed: speed, orientsToPath: orientsToPath))
    }

    /// Stops the entity where it is. No ``PathEvents/DidFinish`` is published.
    public func stopFollowingPath() {
        components.remove(PathComponent.self)
    }

    /// Whether the entity is moving along a path.
    public var isFollowingPath: Bool { components[PathComponent.self] != nil }
}

/// Moves every entity with a ``PathComponent`` along its waypoints.
///
/// ```swift
/// PathFollowSystem.registerSystem()       // every new world
/// world.addSystem(PathFollowSystem.self)  // or just this one
/// ```
public struct PathFollowSystem: System {
    private static let query = EntityQuery(where: .has(PathComponent.self))

    public init(world: World) {}

    public mutating func update(context: UpdateContext) {
        for entity in context.entities(matching: Self.query) {
            guard var path = entity.components[PathComponent.self] else { continue }
            var position = entity.position
            var budget = path.speed * Float(context.deltaTime)
            var heading: SIMD2<Float>?

            // Spend this frame's distance, carrying any leftover past each waypoint
            // so speed stays steady around corners.
            while path.nextIndex < path.waypoints.count {
                let target = path.waypoints[path.nextIndex]
                let delta = target - position
                let distance = (delta * delta).sum().squareRoot()
                if distance > 0 { heading = delta / distance }
                if distance <= budget {
                    position = target
                    budget -= distance
                    path.nextIndex += 1
                } else {
                    position += delta / distance * budget
                    break
                }
            }

            var transform = entity.transform
            transform.translation = position
            if path.orientsToPath, let heading {
                transform.rotation = atan2(heading.y, heading.x)
            }
            entity.transform = transform

            if path.nextIndex >= path.waypoints.count {
                entity.components.remove(PathComponent.self)
                context.world.publish(PathEvents.DidFinish(entity: entity), from: entity)
            } else {
                // Progress along the path isn't something the renderer draws.
                entity._setWithoutNotifying(path)
            }
        }
    }
}
