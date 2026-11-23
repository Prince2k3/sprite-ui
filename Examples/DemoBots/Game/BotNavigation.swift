import SpriteUI

/// A level's cached scene-space floor. The SDK owns visibility-graph routing;
/// the game rejects endpoints without clearance rather than truncating a route.
struct BotNavigation {
    var bounds: BoundingBox { didSet { rebuild() } }
    var obstacles: [PolygonObstacle] { didSet { rebuild() } }
    private(set) var padded: [PolygonObstacle]
    private var graph: ObstacleGraph
    let clearance: Float

    init(bounds: BoundingBox, obstacles: [PolygonObstacle], radius: Float = 25) {
        // DemoBots controllers use a 0.01-point skin. One extra point covers
        // that skin plus 0.99 of numerical/steering margin at path corners.
        clearance = max(0, radius) + 1
        self.bounds = bounds
        self.obstacles = obstacles
        graph = Self.makeGraph(bounds: bounds, obstacles: obstacles, clearance: clearance)
        padded = Array(graph.paddedObstacles.prefix(obstacles.count))
    }

    func isWalkable(_ point: SIMD2<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite &&
            BoundingBox(min: bounds.min + SIMD2(repeating: clearance),
                        max: bounds.max - SIMD2(repeating: clearance)).contains(point) &&
            graph.isWalkable(point)
    }

    func isClear(from start: SIMD2<Float>, to end: SIMD2<Float>) -> Bool {
        isWalkable(start) && isWalkable(end) &&
            !padded.contains { $0.intersects(segmentFrom: start, to: end) }
    }

    func path(from start: SIMD2<Float>, to end: SIMD2<Float>) -> [SIMD2<Float>] {
        // Do not allow the graph's trapped-start escape policy to turn an
        // off-floor start into an unchecked recovery/teleport segment.
        guard isWalkable(start), isWalkable(end) else { return [] }
        if start == end { return [start] }
        if isClear(from: start, to: end) { return [start, end] }
        guard let route = graph.findPath(from: start, to: end),
              route.first == start, route.last == end,
              zip(route, route.dropFirst()).allSatisfy({ isClear(from: $0.0, to: $0.1) }) else { return [] }
        return route
    }

    private mutating func rebuild() {
        graph = Self.makeGraph(bounds: bounds, obstacles: obstacles, clearance: clearance)
        padded = Array(graph.paddedObstacles.prefix(obstacles.count))
    }

    private static func makeGraph(bounds: BoundingBox, obstacles: [PolygonObstacle], clearance: Float) -> ObstacleGraph {
        // ObstacleGraph has no bounds. Four overlapping exterior walls keep
        // routes inside the board, with the same inward clearance as scenery.
        let span = max(bounds.size.x, bounds.size.y, 1)
        let lo = bounds.min, hi = bounds.max
        let walls = [
            BoundingBox(min: lo - SIMD2(repeating: span), max: [hi.x + span, lo.y]),
            BoundingBox(min: [lo.x - span, hi.y], max: hi + SIMD2(repeating: span)),
            BoundingBox(min: [lo.x - span, lo.y], max: [lo.x, hi.y]),
            BoundingBox(min: [hi.x, lo.y], max: [hi.x + span, hi.y]),
        ].map(PolygonObstacle.init)
        return ObstacleGraph(obstacles: obstacles + walls, bufferRadius: clearance)
    }
}
