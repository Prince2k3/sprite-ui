import ECSCore

/// Makes an entity a solid polygon: steered entities avoid it, and
/// ``ECSCore/World/obstacleGraph(bufferRadius:)`` routes paths around it,
/// in place of `GKPolygonObstacle` attached to a node.
///
/// The points are in the entity's own space, so moving, turning or scaling the
/// entity (or its ancestors) moves the obstacle with it.
///
/// ```swift
/// let wall = Entity()
/// wall.position = [0, 120]
/// wall.components.set(PolygonObstacleComponent(rectangle: [200, 20]))
/// ```
public struct PolygonObstacleComponent: Component, Hashable, Codable, Sendable {
    /// The outline in the entity's own space. At least three corners.
    public var points: [SIMD2<Float>]

    public init(points: [SIMD2<Float>]) {
        self.points = points
    }

    /// A rectangle of `size` centered on the entity.
    public init(rectangle size: SIMD2<Float>) {
        let half = size / 2
        self.init(points: [[-half.x, -half.y], [half.x, -half.y], [half.x, half.y], [-half.x, half.y]])
    }
}

extension Entity {
    /// This entity's ``PolygonObstacleComponent`` in scene space, or `nil` if it
    /// has none or the outline has fewer than three distinct corners.
    public var sceneObstacle: PolygonObstacle? {
        guard let outline = components[PolygonObstacleComponent.self] else { return nil }
        var chain: [Transform] = [transform]
        var current = parent
        while let ancestor = current {
            chain.append(ancestor.transform)
            current = ancestor.parent
        }
        let points = outline.points.map { point in chain.reduce(point) { $1.apply(to: $0) } }
        guard Set(points).count >= 3 else { return nil }
        return PolygonObstacle(points: points)
    }
}

extension World {
    private static let polygonObstacles = EntityQuery(where: .has(PolygonObstacleComponent.self))

    /// Every ``PolygonObstacleComponent`` in the world, in scene space, ordered
    /// by entity so the result is the same every time.
    public var polygonObstacles: [PolygonObstacle] {
        performQuery(Self.polygonObstacles)
            .sorted { $0.id < $1.id }
            .compactMap(\.sceneObstacle)
    }

    /// A graph around every ``PolygonObstacleComponent`` in the world, for units
    /// of radius `bufferRadius`, like `GKObstacleGraph(obstacles:bufferRadius:)`.
    ///
    /// It's a snapshot: make a new one after obstacles move, or set its
    /// ``ObstacleGraph/obstacles`` to ``polygonObstacles``.
    public func obstacleGraph(bufferRadius: Float) -> ObstacleGraph {
        ObstacleGraph(obstacles: polygonObstacles, bufferRadius: bufferRadius)
    }
}
